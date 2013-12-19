/*
   Copyright (C) 2013 Paweł Forysiuk <tuxator@o2.pl>

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2.1 of the License, or (at your option) any later version.

   See the file COPYING for the full license text.
*/

using Gtk;
using Midori;
using WebKit;
using Sqlite;

namespace ClipNotes {
        Midori.Database database;
        unowned Sqlite.Database db;
        Gtk.ListStore notes_list_store;
        int64 last_used_id;

        void note_add_new (string title, string? uri, string note_content)
        {
            GLib.DateTime time = new DateTime.now_local ();
            string sqlcmd = "INSERT INTO `notes` (`uri`, `title`, `note_content`, `tstamp` ) VALUES (:uri, :title, :note_content, :tstamp);";
            Sqlite.Statement stmt;
            int64 id;
            if (db.prepare_v2 (sqlcmd, -1, out stmt) != Sqlite.OK)
                critical (_("Failed to add new note to database (prepare): %s"), db.errmsg);
            stmt.bind_text (stmt.bind_parameter_index (":uri"), uri);
            stmt.bind_text (stmt.bind_parameter_index (":title"), title);
            stmt.bind_text (stmt.bind_parameter_index (":note_content"), note_content);
            stmt.bind_int64 (stmt.bind_parameter_index (":tstamp"), time.to_unix ());
            id = db.last_insert_rowid ();

            if (stmt.step () != Sqlite.DONE)
                critical (_("Failed to add new note to database: %s"), db.errmsg);
            else
                append_note (id, uri, title, note_content);
        }

        void note_delete (int64 id)
        {
            string sqlcmd = "DELETE FROM `notes` WHERE id= :id;";
            Sqlite.Statement stmt;
            if (db.prepare_v2 (sqlcmd, -1, out stmt) != Sqlite.OK)
                critical (_("Failed to remove from notes database (prepare): %s"), db.errmsg);
            stmt.bind_int64 (stmt.bind_parameter_index (":id"), id);
            if (stmt.step () != Sqlite.DONE)
                critical (_("Failed to remove from notes database: %s"), db.errmsg);
            else
                remove_note (id);
        }

        void note_rename (int64 id, string new_title)
        {
            string sqlcmd = "UPDATE `notes` SET title= :title WHERE id = :id;";
            Sqlite.Statement stmt;
            if (db.prepare_v2 (sqlcmd, -1, out stmt) != Sqlite.OK)
                critical (_("Failed to rename notes (prepare): %s"), db.errmsg);
            stmt.bind_int64 (stmt.bind_parameter_index (":id"), id);
            stmt.bind_text (stmt.bind_parameter_index (":title"), new_title);
            if (stmt.step () != Sqlite.DONE)
                critical (_("Failed to rename notes: %s"), db.errmsg);
        }

        string note_get_content_by_id (int64 id)
        {
            string sqlcmd = "SELECT note_content FROM notes WHERE id = :id";
            Sqlite.Statement stmt;
            if (db.prepare_v2 (sqlcmd, -1, out stmt, null) != Sqlite.OK)
                critical (_("Failed to select from notes database: %s"), db.errmsg);
                stmt.bind_int64 (stmt.bind_parameter_index (":id"), id);
            int result = stmt.step ();
            string? content = null;
            if (result == Sqlite.ROW)
                content = stmt.column_text (0);
            return content ?? "";
        }

        void note_update (int64 id, string new_content)
        {
            string sqlcmd = "UPDATE `notes` SET note_content = :content WHERE id = :id;";
            Sqlite.Statement stmt;
            if (db.prepare_v2 (sqlcmd, -1, out stmt) != Sqlite.OK)
                critical (_("Failed to update notes database (prepare): %s"), db.errmsg);
            stmt.bind_int64 (stmt.bind_parameter_index (":id"), id);
            stmt.bind_text (stmt.bind_parameter_index (":content"), new_content);
            if (stmt.step () != Sqlite.DONE)
                critical (_("Failed to update notes database: %s"), db.errmsg);
        }

        void append_note (int64 id, string? uri, string title, string note_content)
        {
            Gtk.TreeIter iter;
            notes_list_store.append (out iter);
            notes_list_store.set (iter, 0, id);
            notes_list_store.set (iter, 1, uri);
            notes_list_store.set (iter, 2, title);
            notes_list_store.set (iter, 3, note_content);
         }

         void remove_note (int64 id)
         {
            Gtk.TreeIter iter;
            if (notes_list_store.iter_children (out iter, null)) {
                do {
                    int64 iter_id;
                    notes_list_store.get (iter, 0, out iter_id);
                    if (id == iter_id) {
                        notes_list_store.remove (iter);
                    }

                } while (notes_list_store.iter_next (ref iter));
            }
         }

        private class Sidebar : Gtk.VBox, Midori.Viewable {
        Gtk.Toolbar? toolbar = null;
        Gtk.Label note_label;
        Gtk.TreeView notes_tree_view;
        Gtk.TextView note_text_view = new Gtk.TextView ();

        public unowned string get_stock_id () {
            return Gtk.STOCK_EDIT;
        }

        public unowned string get_label () {
            return _("Notes");
        }

        public Gtk.Widget get_toolbar () {
            if (toolbar == null) {
                toolbar = new Gtk.Toolbar ();
                var new_note_button = new Gtk.ToolButton.from_stock (Gtk.STOCK_EDIT);
                new_note_button.label = _("New Note");
                new_note_button.tooltip_text = _("Creates a new empty note, urelated to opened pages");
                new_note_button.use_underline  = true;
                new_note_button.is_important = true;
                new_note_button.show ();
                new_note_button.clicked.connect (() => {
                    note_add_new (_("New note"), null, "");
                });
                toolbar.insert (new_note_button, -1);
            } // if (toolbar != null)
            return toolbar;
        } // get_toolbar

        public Sidebar () {
            Gtk.TreeViewColumn column;

            notes_list_store = new Gtk.ListStore (4, typeof (int64), typeof (string), typeof (string), typeof (string));
            notes_tree_view = new Gtk.TreeView.with_model (notes_list_store);
            notes_tree_view.headers_visible = true;
            notes_tree_view.button_release_event.connect (button_released);

            column = new Gtk.TreeViewColumn ();
            Gtk.CellRendererText renderer_title = new Gtk.CellRendererText ();
            column.set_title (_("Notes"));
            column.pack_start (renderer_title, true);
            column.set_cell_data_func (renderer_title, on_renderer_note_title);
            notes_tree_view.append_column (column);

            if (database != null && !database.first_use) {
                string sqlcmd = "SELECT id, uri, title, note_content FROM notes ORDER BY title ASC";
                Sqlite.Statement stmt;
                if (db.prepare_v2 (sqlcmd, -1, out stmt, null) != Sqlite.OK)
                    critical (_("Failed to select from notes database (prepare): %s"), db.errmsg);
                int result = stmt.step ();
                if (!(result == Sqlite.DONE || result == Sqlite.ROW)) {
                    critical (_("Failed to select from notes database: %s"), db.errmsg ());
                }

                while (result == Sqlite.ROW) {
                    int64 id = stmt.column_int64 (0);
                    string? uri = stmt.column_text (1);
                    string title = stmt.column_text (2);
                    string note_content = stmt.column_text (3);

                    append_note (id, uri, title, note_content);

                    result = stmt.step ();
                }
            }

            notes_tree_view.show ();
            pack_start (notes_tree_view, false, false, 0);

            note_label = new Gtk.Label (null);
            note_label.show ();
            pack_start (note_label, false, false, 0);

            note_text_view.set_wrap_mode (Gtk.WrapMode.WORD);
            note_text_view.show ();
            note_text_view.focus_out_event.connect (focus_lost);
            pack_start (note_text_view, true, true, 0);
        } // Sidebar()

        bool focus_lost (Gdk.EventFocus event) {
            Gtk.TreePath? path;
            notes_tree_view.get_cursor (out path, null);
            return_val_if_fail (path != null, false);
            Gtk.TreeIter iter;
            if (notes_list_store.get_iter (out iter, path)) {
                int64 id;
                notes_list_store.get (iter, 0, out id);
                if (last_used_id == id) {
                    string note_content = note_text_view.buffer.text;
                    note_update (id, note_content);
                }
            }
            return false;
        }

        private void on_renderer_note_title (Gtk.CellLayout column, Gtk.CellRenderer renderer,
            Gtk.TreeModel model, Gtk.TreeIter iter) {

            string note_title;
            model.get (iter, 2, out note_title);
            renderer.set ("text", note_title,
                "ellipsize", Pango.EllipsizeMode.END);
        } // on_renderer_note_title

        bool button_released (Gdk.EventButton event) {
            if (event.button == 1)
                return show_note_content (event);
            if (event.button == 3)
                return show_popup_menu (event);
            return false;
        }

        bool show_note_content (Gdk.EventButton? event) {
            Gtk.TreeIter iter;
            if (notes_tree_view.get_selection ().get_selected (null, out iter)) {
                int64 id;
                string uri;
                string label = "";
                notes_list_store.get (iter, 0, out id);
                notes_list_store.get (iter, 1, out uri);

                if (uri != null) {
                    label = _("Note clipped from: <a href=\"%s\">%s</a>").printf (uri, uri);
                }

                if (last_used_id != id) {
                    note_label.set_markup (label);
                    note_text_view.buffer.text = note_get_content_by_id (id);
                    last_used_id = id;
                }

                return true;
            } else {
                note_label.set_markup ("");
                note_text_view.buffer.text = "";
            }
            return false;
        }

        bool show_popup_menu (Gdk.EventButton? event) {
            Gtk.TreeIter iter;
            if (notes_tree_view.get_selection ().get_selected (null, out iter)) {

                var menu = new Gtk.Menu ();

                var menuitem = new Gtk.ImageMenuItem.with_label (_("Rename note"));
                var image = new Gtk.Image.from_stock (Gtk.STOCK_EDIT, Gtk.IconSize.MENU);
                menuitem.always_show_image = true;
                menuitem.set_image (image);
                menuitem.activate.connect (() => {
                    int64 id;
                    string title;
                    notes_list_store.get (iter, 0, out id);
                    notes_list_store.get (iter, 2, out title);

                    var dialog = new Gtk.Dialog. with_buttons (_("Rename note"), null,
                        Gtk.DialogFlags.DESTROY_WITH_PARENT, Gtk.Stock.CANCEL, Gtk.ResponseType.CANCEL,
                        Gtk.Stock.OK, Gtk.ResponseType.OK);
                    Gtk.Box content = (Gtk.Box) dialog.get_content_area ();
                    dialog.set_default_response (Gtk.ResponseType.OK);
                    dialog.resizable = false;
                    dialog.icon_name = Gtk.STOCK_EDIT;

                    var entry = new Gtk.Entry ();
                    entry.text = title;
                    entry.activates_default = true;
                    content.add (entry);
                    content.show_all ();

                    int response = dialog.run ();
                    dialog.hide ();
                    if (response == Gtk.ResponseType.OK) {
                        string new_title = entry.text;
                        if (entry.text != null && new_title != title) {
                            note_rename (id, new_title);
                            notes_list_store.set (iter, 2, new_title);
                        }
                    }
                    dialog.destroy ();

                });
                menu.append (menuitem);


                menuitem = new Gtk.ImageMenuItem.with_label (_("Copy note to clipboard"));
                image = new Gtk.Image.from_stock (Gtk.STOCK_COPY, Gtk.IconSize.MENU);
                menuitem.always_show_image = true;
                menuitem.set_image (image);
                menuitem.activate.connect (() => {
                    int64 id;
                    string note_content;
                    notes_list_store.get (iter, 0, out id);
                    note_content = note_get_content_by_id (id);
                    get_clipboard (Gdk.SELECTION_CLIPBOARD).set_text (note_content, -1);
                });
                menu.append (menuitem);


                menuitem = new Gtk.ImageMenuItem.with_label (_("Remove note"));
                image = new Gtk.Image.from_stock (Gtk.STOCK_DELETE, Gtk.IconSize.MENU);
                menuitem.always_show_image = true;
                menuitem.set_image (image);
                menuitem.activate.connect (() => {
                    int64 id;
                    notes_list_store.get (iter, 0, out id);
                    note_delete (id);
                });
                menu.append (menuitem);

                menu.show_all ();
                Katze.widget_popup (notes_tree_view, menu, null, Katze.MenuPos.CURSOR);
                return true;
            }
            return false;
        }
    } // Sidebar

    private class Manager : Midori.Extension {
        internal GLib.List<Gtk.Widget> widgets;

        void tab_added (Midori.Browser browser, Midori.Tab tab) {

            tab.context_menu.connect (add_menu_items);

        } // tab_added



        void add_menu_items (Midori.Tab tab, WebKit.HitTestResult hit_test_result, Midori.ContextAction menu) {
            if ((hit_test_result.context & WebKit.HitTestResultContext.SELECTION) == 0)
                return;

            var view = tab as Midori.View;
            var action = new Gtk.Action ("Notes", _("Copy selection as note"), null, null);
            action.activate.connect ((action)=> {
                if (view.has_selection () == true)
                {
                    string selected_text = view.get_selected_text ();
                    string uri = view.get_display_uri ();
                    string title = view.get_display_title ();
                    note_add_new (title, uri, selected_text);
                }
            });

            menu.add (action);
        } // add_menu_items

        void browser_added (Midori.Browser browser) {
            var viewable = new Sidebar ();
            viewable.show ();
            browser.panel.append_page (viewable);
            widgets.append (viewable);

            foreach (var tab in browser.get_tabs ())
                tab_added (browser, tab);

            browser.add_tab.connect (tab_added);
        } // browser_added

        void activated (Midori.App app) {
            widgets = new GLib.List<Gtk.Widget> ();
            app.add_browser.connect (browser_added);
            foreach (var browser in app.get_browsers ())
                browser_added (browser);

            string config_path = this.get_config_dir ();
            if (config_path != null) {
                string db_path = GLib.Path.build_path (Path.DIR_SEPARATOR_S, config_path, "notes.db");
                try {
                    database = new Midori.Database (db_path);
                } catch (Midori.DatabaseError schema_error) {
                    error (schema_error.message);
                }
                db = database.db;
            }
        } // activated

        void deactivated () {
            var app = get_app ();
            app.add_browser.disconnect (browser_added);
            foreach (var widget in widgets)
                widget.destroy ();
        } // deactivated

        internal Manager () {
            GLib.Object (name: _("Notes"),
                         description: _("Save text clips from websites as notes"),
                         version: "0.1" + Midori.VERSION_SUFFIX,
                         authors: "Paweł Forysiuk");

            this.activate.connect (activated);
            this.deactivate.connect (deactivated);
        } // Manager ()
    } // Manager : Midori.Extension
} // namespace Clipnotes

public Midori.Extension extension_init () {
    return new ClipNotes.Manager ();
}
