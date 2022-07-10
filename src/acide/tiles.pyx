# tiles.pyx
#
# Copyright 2022 Gilles Coissac
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
"""

"""
import asyncio
import time
from typing import Any, Callable, Union, Optional, NoReturn, Sequence, Tuple

import gi
gi.require_version('Graphene', '1.0')
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, GLib, Graphene

import blosc
cimport cython

from acide import format_size
from acide.types import TypedGrid
from acide.async import Scheduler, Priority
from acide.measure import Measurable, Unit
from acide.types import BufferProtocol, Rectangle
# from acide cimport gbytes


BLOSC_MAX_BYTES_CHUNK = 2**31


cdef class Timer():
    cdef double start, time
    cdef unicode name

    def __cinit__(self, name="unknown"):
        self.name = name
        self.start = time.clock_gettime_ns(time.CLOCK_PROCESS_CPUTIME_ID)

    cpdef stop(self):
        self.time = (
            time.clock_gettime_ns(time.CLOCK_PROCESS_CPUTIME_ID) -\
            self.start
        )
        # print(
        #     f"BENCHMARK({self.name}): {self.time} μs "
        #     f"| {self.time / 1000000000:.3f} sec\n"
        # )


cdef object gdk_memory_format_mapping():
    mapping = dict()
    cdef int size
    for _enum in Gdk.MemoryFormat.__enum_values__.values():
        size = _enum.value_nick.count("8")
        size += _enum.value_nick.count("16") * 2
        size += _enum.value_nick.count("32") * 4
        mapping[_enum] = size
    return mapping
gdk_memory_format_sizes = gdk_memory_format_mapping()


cdef class Tile(_CMeasurable):
    """A :class:`Tile` is a part of a larger graphic object.
    :class:`Tile` implements the :class:`Measurable` interface.

    :class:`Tile` are pats of :class:`TilesGrid` which represent a view of
    a graphic object too large to be kept in memory in a monolithic uncompressed
    form. Original graphic surface should be cut down in equally sized Tiles
    grouped in a :class:`TilesGrid`. Corresponding pixels buffer area
    for each :class:`Tile` should be passed to the :meth:`compress` method.
    The idea is that graphic object could provide those buffers in an async
    way to manage priority and memory preserving the responsiveness of application.

    :class:`Tile` will only kept buffer in a compressed form.

    A :class:`Tile` is rectangular and are defined by the :obj:`rect` argument,
    which could be in whatever unit of measure choosen by the implementation,
    and defined the position and size relative to the original graphic surface.

    Compressions are done by the `Blosc Library <http://python-blosc.blosc.org/tutorial.html>`_ .

    Args:
        rect: A four length Sequence of numbers or a :class:`Graphen.Rect`
              describing the origin and size of the Tile. If set to None,
              rect will be initialized at (0, 0, 0, 0), default to None .
    """
    blosc.set_releasegil(True)
    blosc.set_nthreads(blosc.detect_number_of_cores() - 2)

    @property
    def u(self) -> int:
        """An :class:`int` as the size in bytes of the origin uncompressed
        buffer (read only)."""
        return self._u

    @property
    def z(self) -> int:
        """An :class:`int` as the size in bytes of the Tile's compressed
        buffer (read only)."""
        return self._z

    @property
    def r(self) -> float:
        """A :class:`float` as the ratio of compression of
        the Tile's buffer (read only)."""
        return self._r

    def __cinit__(self, *args, **kwargs):
        self._u = 0
        self._z = 0
        self._r = 0
        self.buffer = None
        self.u_shape = 0
        self.u_itemsize = 0
        self._size = (0, 0)

    def __dealloc__(self):
        self.buffer = None

    cpdef invalidate(self):
        """invalidate the compressed internal buffer (deallocate).
        After this call *self.buffer* will be set to *None*.
        """
        self.buffer = None
        self._u = self._z = self._r = 0

    cpdef compress_async(
        self,
        buffer: BufferProtocol,
        size: Sequence[int, int],
        format: Gdk.MemoryFormat,
    ):
        """Compress the given :obj:`buffer` in the :class:`Tile` asynchroniously.
        """
        return self._compress_async(buffer, size, format)

    async def _compress_async(self, buffer, size, format):
        try:
            self.compress(buffer, size, format)
        except asyncio.CancelledError:
            pass # TODO
        finally:
            pass

    cpdef compress(
        self,
        buffer: BufferProtocol,
        size: Sequence[int, int],
        format: Gdk.MemoryFormat,
    ):
        """Compress the given :obj:`buffer` in the :class:`Tile`'s own buffer.
        Blosc has a maximum blocksize of 2**31 bytes = 2Gb, larger arrays must
        be chunked by slicing.

        Args:
            buffer: A one dmensional c-contigous buffer to compress.
            size: A two lenght :class:`Sequence` of :class:`int` (width, height)
                  describing the pixmap size in pixel behind the buffer.
            format: a member of enumeration :class:`Gdk.MemoryFormat`
                    describing formats that pixmap data have in memory.

        Raises:
            TypeError: if :obj:`buffer` doesn't implement the *buffer protocol*,
                       are not c-contigous or have more than one dimension.
            ValueError: if there is a missmatch between :obj:`buffer`'s lenght
                        and given pixmap size for memory format or if
                        buffer's lenght is larger than blosc's maximum blocksize.
        """
        cdef Py_buffer view
        cdef Py_buffer* p_view = &view
        cdef char* ptr

        if not test_sequence(size, (int, int)):
            raise TypeError(
                f"size should be a 2 length sequence of int not {size}"
            )

        if isinstance(buffer, memoryview):
            p_view = PyMemoryView_GET_BUFFER(buffer)
        elif PyObject_CheckBuffer(buffer):
            PyObject_GetBuffer(buffer, p_view, PyBUF_SIMPLE)
        else:
            raise TypeError(
                "Argument buffer should be either a memoryview"
                "or an object implementing the buffer protocol"
                "and data should be contigous in memory"
            )

        if not PyBuffer_IsContiguous(p_view, b'C'):
            raise TypeError("buffer should be c-contigous in memory")

        if p_view.ndim <> 1:
            raise TypeError("buffer should only have one dimension")

        # Sanity check between size and buffer size
        self.format_size = gdk_memory_format_sizes.get(format, 0)
        if size[0] * size[1] * self.format_size  <> \
            p_view.len:
            raise ValueError(
                "Missmatch between buffer's lenght and pixmap"
                f" size for {format}"
            )

        # blosc limit
        if p_view.len > BLOSC_MAX_BYTES_CHUNK:
            raise ValueError(
                f"Buffer size to large to be compressed, maximum size is "
                f"{format_size(BLOSC_MAX_BYTES_CHUNK)}, given buffer have "
                f"{format_size(p_view.len)}."
            )

        self._size = tuple(size)
        self._u = p_view.len
        self.u_shape = p_view.shape[0]
        self.u_itemsize = p_view.itemsize

        # we don't care of the buffer format,
        # buffer will be compressed as bytes in buffer
        # and we have itemsize and a Gdk.MemoryFormat to carry
        # buffer's items type info.
        # self.u_format = <bytes> p_view.format
        self.u_format = b'B'  # unsigned char
        ptr = <char*> p_view.buf

        # TODO: self._size & Measurable.get_pixmap_rect()

        self.buffer = blosc.compress_ptr(
            <Py_ssize_t> &ptr[0],
            p_view.len,
            typesize=p_view.itemsize,
            clevel=9,
            shuffle=blosc.SHUFFLE,
            cname='blosclz',
        )
        self._z = len(self.buffer)
        self._r = self._u / float(self._z)
        PyBuffer_Release(p_view)

    cpdef _dump_props(self):
        return (
            f"{_CMeasurable._dump_props(self)}, "
            #f"u:{format_size(self._u)}, z:{format_size(self._z)}, "
            #f"r:{self._r:.1f}, "
            f"_size:{self._size}"
        )

    def __str__(self):
        return f"Tile({self._dump_props()})"


cdef class TilesGrid(TypedGrid):
    """
    A :class:`acide.types.TypedGrid` specialized in :class:`Tile` type. The overall
    TilesGrid represent the entire pixmap of a large Graphic object for
    a given scale factor.

    A :class:`TilesGrid` could also be a view of another :class:`TilesGrid` by
    slicing the latter, this view could be sliced again. Base :class:`TilesGrid`
    are kept in reference throughout slices (see: :class:`acide.types.TypedGrid`).

    Args:
        shape: A two lenght sequence of int describing the grid dimension,
               like (width, height), those integers are limited to a maximum
               value of *65535* (2 bytes unsigned int) by the implementation.

        format: a member of enumeration :class:`Gdk.MemoryFormat`
                describing formats that pixmap data will have in memory.
    """

    @property
    def u(self) -> int:
        """An :class:`int` as the size in bytes of the origin uncompressed
        buffer (read only)."""
        return self._u

    @property
    def z(self) -> int:
        """An :class:`int` as the size in bytes of the Tile's compressed
        buffer (read only)."""
        return self._z

    @property
    def r(self) -> float:
        """A :class:`float` as the ratio of compression of
        the Tile's buffer (read only)."""
        return self._r

    def __cinit__(
        self, shape=None, format=Gdk.MemoryFormat.R8G8B8, *args, **kwargs
    ):
        #TODO: all tiles should have same properties, shape, pixel format,...
        self.pytype = Tile
        self._u = 0
        self._z = 0
        self._r = 0
        self.memory_format = format
        self.compute_extents()

    def __init__(
        self,
        shape: Optional[Sequence[int]]=None,
        format: Gdk.MemoryFormat=Gdk.MemoryFormat.R8G8B8,
    ):
        pass

    cpdef invalidate(self):
        """Call :meth:`Tile.invalidate` on each :class:`Tile` in this Grid.
        """
        cdef Py_ssize_t x, y
        cdef object tile
        for x in range(self.view.shape[0]):
            for y in range(self.view.shape[1]):
                tile = self._ref.items[self.view[x, y]]
                if tile is not None:
                    (<Tile> tile).invalidate()

    cpdef compress(self, pixbuff_cb: Callable[[Graphene.Rect], BufferProtocol]):
        """Compress all Tiles in this Grid that have not yet a valid internal buffer.

        Args:
            pixbuff_cb: a callback function to retrieve parts of a pixmap in
                        the form pixbuff_cb(rect: Graphene.Rect) -> BufferProtocol
        """
        #TODO: make it async
        cdef Py_ssize_t x, y
        cdef object tile
        self._u = self._z = 0
        for x in range(self.view.shape[0]):
            for y in range(self.view.shape[1]):
                tile = self._ref.items[self.view[x, y]]
                if tile is not None:
                    if (<Tile> tile).buffer is None:
                        _T = Timer("pixbuff_cb")
                        buffer, size = pixbuff_cb((<Tile> tile).rect)
                        _T.stop()
                        _T = Timer("Tile.compress()")
                        (<Tile> tile).compress(
                            buffer=buffer,
                            size=size,
                            format=self.memory_format
                        )
                        _T.stop()
                    self._u += (<Tile> tile)._u
                    self._z += (<Tile> tile)._z
        if self._z <> 0:
            self._r = self._u / float(self._z)

    cdef compute_extents(self):
        cdef Extents_s tl, br
        if self.view is not None:
            try:
                tl = (<Tile?> self.getitem_at(0, 0)).get_extents()
                br = (<Tile?> self[-1, -1]).get_extents()
            except TypeError:
                self.extents = Extents_s(0, 0, 0, 0)
            else:
                self.extents = Extents_s(tl.x0, tl.y0, br.x1, br.y1)
        else:
            self.extents = Extents_s(0, 0, 0, 0)

    cdef bint contains_point(self, double x, double y):
        return x >= self.extents.x0 and x < self.extents.x1 and \
               y >= self.extents.y0 and y < self.extents.y1

    cdef bint contains_extents(
        self, double x0, double y0, double x1, double y1
    ):
        return self.contains_point(x0, y0) and self.contains_point(x1, y1)

    cpdef get_tile_indices(self, double x, double y):
        """Returns indices for the :class:`Tile` containing the point at
        (x, y) coordinates.

        If the point(x, y) lies outside the :class:`Measurable`
        this :class:`TilesGrid` belong to, indices for the nearest
        :class:`Tile` will be return.

        Args:
            x, y: coordinates express in unit of measure for
                  the :class:`Measurable` this :class:`TilesGrid` belong to.

        Returns:
            indices as an int tuple(x, y) where to find the Tile or None
            if this :class:`TilesGrid` is empty.
        """
        if self.view is not None:
            x = self.extents.x0 if x < self.extents.x0 else x
            y = self.extents.y0 if y < self.extents.y0 else y
            return (
                <Py_ssize_t> cmin(
                    self.view.shape[0],
                    self.view.shape[0] * (x / self.extents.x1)
                ),
                <Py_ssize_t> cmin(
                    self.view.shape[1],
                    self.view.shape[1] * (y / self.extents.y1)
                )
            )
        else:
            return None

    cdef stats(self):
        cdef Py_ssize_t x, y
        self._u = self._z = 0
        for x in range(self.view.shape[0]):
            for y in range(self.view.shape[1]):
                tile = self._ref.items[self.view[x, y]]
                if tile is not None:
                    self._u += (<Tile>tile)._u
                    self._z += (<Tile>tile)._z
        if self._z <> 0:
            self._r = self._u / float(self._z)

    def __str__(self):
        self.stats()
        return (
            f"{self.__class__.__name__}@({id(self)}):\n"
            f"{super().__str__()}\n"
            f"extents: ({self.extents.x0:.1f}, {self.extents.y0:.1f}, "
            f"{self.extents.x1:.1f}, {self.extents.y1:.1f})\n"
            f"u:{format_size(self._u)}, z:{format_size(self._z)}, r:{self._r:.1f}"
        )


cdef class Clip():
    """A simple structure to hold a rendered region
    returned by a :class:`SuperTile`.
    """

    def __cinit__(self, x=0, y=0, w=0, h=0):
        self._x = x
        self._y = y
        self._w = w
        self._h = h
        self._texture = None

    def __init__(self, x: float =0, y: float =0, w: int =0, h: int =0):
        pass

    @property
    def x(self):
        """origin of the rendered region"""
        return self._x

    @property
    def y(self):
        """origin of the rendered region"""
        return self._y

    @property
    def w(self):
        """width of the rendered region"""
        return self._w

    @property
    def h(self):
        """height of the rendered region"""
        return self._h

    @property
    def texture(self):
        """A :class:`Gdk.Texture` holding the pixmap"""
        return self._texture


cdef class SuperTile(TilesGrid):
    """A two by two :class:`TilesGrid`.

    A :class:`SuperTile` is a [2,2] view of a :class:`TilesGrid`.
    The goal is to agregate the subTile's compressed buffer of this view
    in an uncompressed one available as a :class:`Gdk.Texture`
    by accessing its :attr:`SuperTile.texture` property.

    Args:
        grid: a :class:`TilesGrid` that this SuperTile will refer to.
    """

    def __cinit__(self, grid, *args, **kwargs):
        #TODO: make SuperTile size parametrable
        if grid is None or not isinstance(grid, TilesGrid):
            raise TypeError("grid should be a TilesGrid instance")
        self._ref = grid
        self.memory_format = (<TilesGrid> grid).memory_format
        self.slice_ref(slice(0, 2, 1), slice(0, 2, 1))
        self.is_valid = False
        self.buffer = None
        self._clip = Clip.__new__(Clip)
        self.compute_extents()

    def __init__(self, grid: TilesGrid):
        pass

    cpdef move_to(self, int x, int y):
        """Move this :class:`SuperTile` onto its base :class:`TilesGrid`.

        This method always keep the :class:`SuperTile`
        fully contained in its base :class:`TilesGrid`.

        Args:
         x, y: indices for the top-left :class:`Tile` relatif
               to the :attr:`TilesGrid.base` :class:`TilesGrid`.
        """
        cdef int w, h
        w, h = self._ref.view.shape
        x = (x - 1) if x >= (w - 1) else x
        y = (y - 1) if y >= (h - 1) else y
        if self._ref.view[x, y] != self.view[0, 0]:
            self.slice_ref(slice(x, x + 2, 1), slice(y, y + 2, 1))
            self.compute_extents()
            self._clip._x = self.extents.x0  # x * self._clip._w
            self._clip._y = self.extents.y0  # y * self._clip._h
            self.buffer = None
            self.invalidate()

    cpdef invalidate(self):
        """Mark the content of the internal uncompressed buffer as invalid.

        After this call the content of the internal buffer will be
        recomputed with the next access to :attr:`SuperTiles.texture`.
        """
        self._clip._texture = None
        self.glib_bytes = None
        self.buffer = None
        self.is_valid = False

    cdef int allocate_buffer(self):
        """Allocate self.buffer to host offscreen image
        of the resulting union of compressed subtiles."""
        cdef Tile tile0, tile1, tile2, tile3
        cdef Py_ssize_t sh
        try:
            tile0 = <Tile?> self.getitem_at(0,0)
            tile1 = <Tile?> self.getitem_at(1,0)
            tile2 = <Tile?> self.getitem_at(0,1)
            tile3 = <Tile?> self.getitem_at(1,1)
        except TypeError:
            self.msg = "Invalid Tiles to allocate buffer's SuperTile"
            return -1

        if tile0.buffer and tile1.buffer and \
           tile2.buffer and tile3.buffer:
            sh = tile0.u_shape + tile1.u_shape + \
                 tile2.u_shape + tile3.u_shape
            try:
                self.buffer = Carray.__new__(
                    Carray,
                    shape=(sh,),
                    itemsize=tile0.u_itemsize,
                    format=tile0.u_format,
                    mode='c',
                    allocate_buffer=True,
                )
            except MemoryError as m:
                self.msg = (
                    f"{m}: "
                    f"shape({sh},), "
                    f"itemsize: {tile0.u_itemsize}, format: {tile0.u_format}, "
                    f"memory: {format_size(sh * tile0.u_itemsize)}"
                )
                return -3
            self._clip._w = tile0._size[0] + tile1._size[0]
            self._clip._h = tile0._size[1] + tile2._size[1]
            self._z = tile0._z + tile1._z + tile2._z + tile3._z
            self._u = tile0._u + tile1._u + tile2._u + tile3._u
            self._r = self._u / float(self._z)
            return 1
        else:
            self.msg = "Invalid Tile's buffer to allocate buffer's SuperTile"
            return -2

    cdef int fill_buffer(self):
        """Actually decompress the subtiles buffers in the SuperTile.buffer."""
        _T = Timer("decompress buffers")
        cdef Carray buffer_west
        cdef Carray buffer_east
        cdef Py_ssize_t w_buf, rows, x_in, x_out, y
        cdef Tile tile0, tile1, tile2, tile3
        cdef bint isvalid
        try:
            tile0 = <Tile?> self.getitem_at(0,0)
            tile1 = <Tile?> self.getitem_at(1,0)
            tile2 = <Tile?> self.getitem_at(0,1)
            tile3 = <Tile?> self.getitem_at(1,1)
        except TypeError:
            self.msg = "Invalid Tiles to fill buffer"
            return -1

        # is it safe for pixmap's buffer to be merged ?
        isvalid = (tile0._size[0] == tile2._size[0]) and \
                  (tile1._size[0] == tile3._size[0]) and \
                  (tile0._size[1] == tile1._size[1]) and \
                  (tile2._size[1] == tile3._size[1])

        if self.buffer and isvalid:
            try:
                buffer_west = Carray.__new__(
                    Carray,
                    shape=(tile0.u_shape + tile2.u_shape,),
                    itemsize=tile0.u_itemsize,
                    format=tile0.u_format,
                    mode='c',
                    allocate_buffer=True,
                )
                buffer_east = Carray.__new__(
                    Carray,
                    shape=(tile1.u_shape + tile3.u_shape,),
                    itemsize=tile1.u_itemsize,
                    format=tile1.u_format,
                    mode='c',
                    allocate_buffer=True,
                )
            except MemoryError:
                self.msg = "can´t allocate temporary buffers"
                return -3

            # decompress tiles in two temporary buffers
            blosc.decompress_ptr(
                tile0.buffer,
                address=<Py_ssize_t> &buffer_west.data[0],
            )
            blosc.decompress_ptr(
                tile2.buffer,
                address=<Py_ssize_t> &buffer_west.data[tile0.u_shape],
            )
            blosc.decompress_ptr(
                tile1.buffer,
                address=<Py_ssize_t> &buffer_east.data[0],
            )
            blosc.decompress_ptr(
                tile3.buffer,
                address=<Py_ssize_t> &buffer_east.data[tile1.u_shape],
            )
            _T.stop()

            # fusion of the east and west buffers
            _T = Timer("merge_side_buffers")
            rows = tile0._size[1] + tile2._size[1]
            SuperTile.merge_side_buffers(
                buffer_west, buffer_east, self.buffer,
                rows, tile0._size[0] * tile0.format_size,
                tile1._size[0] * tile0.format_size
            )
            _T.stop()
            return 1
        else:
            self.msg = "Invalid buffer or Tile's format to fill buffer"
            return -2

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @staticmethod
    cdef void merge_side_buffers(
        const uc8[:] west, const uc8[:] east, uc8[:] buffer,
        Py_ssize_t rows, Py_ssize_t west_width, Py_ssize_t east_width
    ) nogil:
        cdef Py_ssize_t x_in, x_out, y
        cdef Py_ssize_t buf_width = east_width + west_width
        for y in range(rows):
            # copy west
            x_in = west_width * y
            x_out = buf_width * y
            buffer[x_out:x_out + west_width] = west[x_in:x_in + west_width]
            # copy east
            x_in = east_width * y
            x_out += west_width
            buffer[x_out:x_out + east_width] = east[x_in:x_in + east_width]

    cpdef render_texture(self):
        cdef int ret
        if not self.is_valid:
            if self.buffer is None:
                _T = Timer("allocate_buffer")
                ret = self.allocate_buffer()
                _T.stop()
                if ret < 0:
                    raise MemoryError(f"{self.msg}")
            if self.fill_buffer() > 0:
                _T = Timer("glib.bytes")
                #FIXME: here data is copied 2 times !!!
                self.glib_bytes = GLib.Bytes.new_take(
                    PyBytes_FromObject(self.buffer)
                )
                _T.stop()
                _T = Timer("Gdk.Texture")
                self._clip._texture = Gdk.MemoryTexture.new(
                    self._clip._w,
                    self._clip._h,
                    self.memory_format,
                    self.glib_bytes,
                    3 * self._clip._w,
                )
                _T.stop()
                self.is_valid = True
            else:
                self.invalidate()

    @property
    def clip(self) -> Clip:
        """A :class:`Clip` holding a :class:`Gdk.Texture` filled with
        the uncompressed data buffer of the subtiles (read only)."""
        return self._clip

    def __str__(self):
        return (
            f"{super().__str__()}\n"
            f"validity: {self.is_valid}\n"
            f"buffer: {self.buffer}\n"
            f"texture: {self._clip._texture}"
        )


@cython.final
cdef class TilesPool():
    """An helper Class for :class:`acide.graphic.Graphic` to manage
    its :class:`Tile`.

    :meth:`TilesPool.__init__` could be safely call more than once. This is
    needed because :class:`TilesPool` could be instancied before the
    viewport widget is realized by Gtk and therefore will lack valid viewport's
    properties to be correctly initialized.

    Args:
        graphic: the :class:`acide.graphic.Graphic` holding ths
                 :class:`TilesPool`
        viewport: the rendering widget for :obj:`graphic`, should
                  implement :class:`acide.measure.Measurable`
        mem_format: a enum's member of :class:`Gdk.MemoryFormat`
        pixbuf_cb: a callback function to retrieve parts of a pixmap in
                   the form pixbuff_cb(rect: Graphene.Rect) -> BufferProtocol
    """

    def __cinit__(self, graphic, viewport, scales, mem_format, pixbuff_cb):
        if (
            not isinstance(graphic, Measurable) or \
            not isinstance(viewport, Measurable)
        ):
            raise TypeError(
                "graphic and viewport parameters should implement"
                " the Measurable interface"
            )
        self.graphic = graphic
        self.viewport = viewport
        self.memory_format = mem_format
        self.pixbuff_cb = pixbuff_cb
        self.scheduler = Scheduler.new()

    def __init__(
        self,
        graphic: Measurable,
        viewport: Measurable,
        scales: Sequence[int],
        mem_format: Gdk.MemoryFormat,
        pixbuff_cb: Callable[[Graphene.Rect], BufferProtocol],
    ):
        _T = Timer("TilesPool init")
        self.current = -1
        self.stack = []
        self.validate_scales(scales)

        for scl in scales:
            if self.make_tiles_grid(scale=int(scl)) > 0:
                # viewport.size could be (0, 0)
                # if widget is not yet realized
                # so be prepared to this
                self.current += 1
                self.init_tiles_grid(
                    <TilesGrid> self.stack[self.current], int(scl)
                )
            else:
                self.stack = []
                break
        self.depth = len(self.stack)
        # keep current at -1 so 1st call to set_rendering()
        # could initialize the render_tile
        self.current = -1
        _T.stop()

    cdef validate_scales(self, list scales):
        try:
            for scl in scales:
                assert (int(scl) > 0)
        except Exception:
            raise ValueError(
                f"scales should be a Sequence of value interpretable as"
                f"int > 0"
            )
        scales.sort()

    cdef int make_tiles_grid(self, unsigned int scale):
        cdef double vw, vh, gw, gh, trs
        cdef int width, height
        vw, vh = self.viewport.size
        trs = self.viewport.get_transform(self.graphic.unit)
        if vw!=0 and vh!=0:
            gw, gh = self.graphic.size
            gw *= scale
            gh *= scale
            width = cimax(2, ciceil(gw / (vw * trs)))
            height = cimax(2, ciceil(gh / (vh * trs)))
            self.stack.append(
                TilesGrid(
                    shape=(width, height),
                    format=self.memory_format
                )
            )
            return 1
        return 0

    cdef init_tiles_grid(self, TilesGrid tg, unsigned int scale):
        cdef int sw, sh, x, y
        cdef double w, h, wt, ht
        sw, sh = tg.view.shape
        w, h = self.graphic.size
        wt = w / sw
        ht = h / sh
        for x in range(sw):
            for y in range(sh):
                tg[x, y] = Tile(
                    rect=(wt * x, ht * y, wt, ht),
                    unit=self.graphic.unit,
                    dpi=self.graphic.dpi * scale,
                )
        tg.compute_extents()

    async def run_tasks(self):
        """Run scheduled Tasks concurently respecting there priority."""
        await self.scheduler.wait()

    def schedule_compression(self):
        for tile in self.render_tile:
            self.scheduler.schedule(
                tile.compress_async(), priority=Priority.HIGHEST
            )

    cpdef set_rendering(self, double x, double y, int depth=0):
        """Setup the rendering :class:`SuperTile` so the point
        at :obj:`(x, y)` will fit in its region.

        This method is usually called by a :class:`acide.graphic.Graphic`
        before requesting rendering with :meth:`render`.

        Args:
            x, y: coordinates express in the unit of measure of
                    the :class:`acide.graphic.Graphic`
            depth: a positive integer as an index of scales given at
                   :class:`TilesPool` initialzation

        Returns:
            a :class:`Clip` holding the :class:`Gdk.Tetxure`
        """
        cdef int i, j

        if depth != self.current:
            # FIXME: should we invalidate TilesGrid? or
            # keep all compressed buffer or an in beetween
            # (<TilesGrid> self.stack[self.current]).invalidate()
            self.current = depth
            # (<TilesGrid> self.stack[self.current]).compress(self.pixbuff_cb)
            self.invalid_render = self.render_tile # FIXME
            self.render_tile = SuperTile(self.stack[self.current])

        i, j = self.stack[self.current].get_tile_indices(x, y)
        self.render_tile.move_to(i, j)
        return self.render_tile._clip

    cpdef after_render_cb(self): #TODO async cb
        if self.invalid_render is not None:
            self.invalid_render.invalidate()
            self.invalid_render = None

    cpdef render(self):
        # TODO: make it async
        self.render_tile.render_texture()

    cpdef int memory_print(self):
        cdef int mem = 0
        if self.render_tile is not None:
            mem += self.render_tile._u * 2  # cause of gbytes
        if self.invalid_render is not None:
            mem += self.invalid_render._u * 2  # cause of gbytes
        for tg in self.stack:
            (<TilesGrid> tg).stats()
            mem += (<TilesGrid> tg)._z
        return mem

