# -*- coding: utf-8 -*-
# main.py
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

import sys

import gi

gi.require_version('Gtk', '4.0')
gi.require_version("Gdk", "4.0")
gi.require_version('Adw', '1')

from gi.repository import Adw, Gio, GLib, Gtk, Gdk

import fitz
from acide.ui.surface import GraphicSurface
from acide.ui.window import AboutDialog, AcideWindow
from acide import format_size

#TODO: * Look at GtkUIManager
#      * Logging
#      * A console widget to redirect logging
#      * typing function
#

class AcideApplication(Adw.Application):
    """The main application singleton class."""

    def __init__(self):
        super().__init__(application_id='io.github.gravures.acide',
                         flags=Gio.ApplicationFlags.FLAGS_NONE)
        self._surface = None
        self.document = None
        self.texture = None

    def load_pdf(self):
        self.document = fitz.open("/home/gilles/PDF/FLIGHT_TEST5.pdf")
        self.page = self.document.load_page(0)
        self.texture = self.get_page_texture(self.page)
        print(fitz.TOOLS.mupdf_warnings())

    def do_startup(self):
        """This function is called when the application is first started.
        All initialization should be done here, to prevent doing
        duplicate work in case another window is opened.
        """
        Gtk.Application.do_startup(self)
        actions = [
            ("quit", self.on_quit_action, ['<primary>q']),
            ("about", self.on_about_action, None),
            ('preferences', self.on_preferences_action, None),
        ]
        for action in actions:
            self.create_action(*action)

    def do_activate(self):
        """Called when the application is activated.

        This function is called when the user requests
        a new window to be opened. We only allow a single window
        and raise any existing ones Windows are associated
        with the application. when the last one is closed
        the application shuts down.
        """
        win = self.props.active_window  #TODO: look 4 this
        if not win:
            win = AcideWindow(application=self)

        self._setup_theme(win)
        # self.load_pdf()
        self._setup_surface()
        self.pdf_surface.queue_draw()
        win.set_default_size(1100, 700)
        win.present_with_time(Gdk.CURRENT_TIME)

    def _setup_surface(self):
        win = self.props.active_window
        self.pdf_surface = GraphicSurface()
        win.scrolled_window.set_child(self.pdf_surface)

    def _setup_theme(self, window):
        sc = window.get_style_context()
        sm = self.get_style_manager()
        css = Gtk.CssProvider.new()
        sc.remove_provider_for_display(window.get_display(), css)
        sm.set_color_scheme(Adw.ColorScheme.DEFAULT)
        # sm.set_color_scheme(Adw.ColorScheme.FORCE_DARK)

    def on_quit_action(self, action, param):
        # self.config.win_height, self.config.win_width = self.window.get_size()
        # self.config.win_x, self.config.win_y = self.window.get_position()
        # self.config.save()
        if self.document:
            self.document.close()

        windows = self.get_windows()
        for window in windows:
            window.destroy()
        self.quit()

    def on_about_action(self, widget, _):
        """Callback for the app.about action."""
        about = AboutDialog(self.props.active_window)
        about.present()

    def on_preferences_action(self, widget, _):
        """Callback for the app.preferences action."""
        print('app.preferences action activated')

    def create_action(self, name, callback, shortcuts=None):
        """Add an application action.

        Args:
            name: the name of the action
            callback: the function to be called when the action is
              activated
            shortcuts: an optional list of accelerators
        """
        action = Gio.SimpleAction.new(name, None)
        action.connect("activate", callback)
        self.add_action(action)
        if shortcuts:
            self.set_accels_for_action(f"app.{name}", shortcuts)


def main(version):
    """The application's entry point."""
    app = AcideApplication()
    return app.run(sys.argv)

