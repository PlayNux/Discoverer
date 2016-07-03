/*
* Copyright (c) 2011 Marlin Developers (http://launchpad.net/marlin)
* Copyright (c) 2015-2016 elementary LLC (http://launchpad.net/pantheon-files)
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public
* License as published by the Free Software Foundation; either
* version 3 of the License, or (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* General Public License for more details.
*
* You should have received a copy of the GNU General Public
* License along with this program; if not, write to the
* Free Software Foundation, Inc., 59 Temple Place - Suite 330,
* Boston, MA 02111-1307, USA.
*
* Authored by: ammonkey <am.monkeyd@gmail.com>
*/

namespace Marlin.View {

public class PropertiesWindow : AbstractPropertiesDialog {
    private Granite.Widgets.ImgEventBox evbox;
    private Granite.Widgets.XsEntry perm_code;
    private bool perm_code_should_update = true;
    private Gtk.Label l_perm;

    private Gtk.ListStore store_users;
    private Gtk.ListStore store_groups;
    private Gtk.ListStore store_apps;

    private uint count;
    private GLib.List<GOF.File> files;
    private GOF.File goffile;

    public FM.AbstractDirectoryView view {get; private set;}
    public Gtk.Entry entry {get; private set;}
    private string original_name {
        get {
            return view.original_name;
        }

        set {
            view.original_name = value;
        }
    }

    private string proposed_name {
        get {
            return view.proposed_name;
        }

        set {
            view.proposed_name = value;
        }
    }

    private Mutex mutex;
    private GLib.List<Marlin.DeepCount>? deep_count_directories = null;

    private Gee.Set<string>? mimes;
    private ValueLabel contains_value;
    private ValueLabel resolution_value;
    private ValueLabel size_value;
    private ValueLabel type_value;
    private KeyLabel contains_key_label;
    private KeyLabel type_key_label;
    private string ftype; /* common type */
    private Gtk.Spinner spinner;
    private int size_warning = 0;
    private uint64 total_size = 0;

    private uint timeout_perm = 0;
    private GLib.Cancellable? cancellable;

    private bool files_contain_a_directory;

    private uint _uncounted_folders = 0;
    private uint selected_folders = 0;
    private uint selected_files = 0;
    private signal void uncounted_folders_changed ();

    private Gtk.Grid perm_grid;
    private int owner_perm_code = 0;
    private int group_perm_code = 0;
    private int everyone_perm_code = 0;

    private enum AppsColumn {
        APP_INFO,
        LABEL,
        ICON
    }

    private enum PermissionType {
        USER,
        GROUP,
        OTHER
    }

    private enum PermissionValue {
        READ = (1<<0),
        WRITE = (1<<1),
        EXE = (1<<2)
    }

    private Posix.mode_t[,] vfs_perms = {
        { Posix.S_IRUSR, Posix.S_IWUSR, Posix.S_IXUSR },
        { Posix.S_IRGRP, Posix.S_IWGRP, Posix.S_IXGRP },
        { Posix.S_IROTH, Posix.S_IWOTH, Posix.S_IXOTH }
    };

    private uint uncounted_folders {
        get {
            return _uncounted_folders;
        }

        set {
            _uncounted_folders = value;
            uncounted_folders_changed ();
        }
    }

    private uint folder_count = 0; /* Count of folders current NOT including top level (selected) folders (to match OverlayBar)*/
    private uint file_count; /* Count of files current including top level (selected) files other than folders */

    public PropertiesWindow (GLib.List<GOF.File> _files, FM.AbstractDirectoryView _view, Gtk.Window parent) {
        base (_("Properties"), parent);

        if (_files == null) {
            critical ("Properties Window constructor called with null file list");
            return;
        }

        if (_view == null) {
            critical ("Properties Window constructor called with null Directory View");
            return;
        }

        view = _view;

        /* Connect signal before creating any DeepCount directories */
        this.destroy.connect (() => {
            foreach (var dir in deep_count_directories)
                dir.cancel ();
        });

        /* The properties window may outlive the passed-in file object
           lifetimes. The objects must be referenced as a precaution.

           GLib.List.copy() would not guarantee valid references: because it
           does a shallow copy (copying the pointer values only) the objects'
           memory may be freed even while this code is using it. */
        foreach (GOF.File file in _files) {
            /* prepend(G) is declared "owned G", so ref() will be called once
               on the unowned foreach value. */
            files.prepend (file);
        }

        count = files.length();

        if (count < 1 ) {
            critical ("Properties Window constructor called with empty file list");
            return;
        }

        if (!(files.data is GOF.File)) {
            critical ("Properties Window constructor called with invalid file data (1)");
            return;
        }

        mimes = new Gee.HashSet<string> ();
        foreach (var gof in files) {
            if (!(gof is GOF.File)) {
                critical ("Properties Window constructor called with invalid file data (2)");
                return;
            }

            var ftype = gof.get_ftype ();
            if (ftype != null) {
                mimes.add (ftype);
            }

            if (gof.is_directory) {
                files_contain_a_directory = true;
            }
        }

        goffile = (GOF.File) files.data;
        construct_info_panel (goffile);
        cancellable = new GLib.Cancellable ();

        update_selection_size (); /* Start counting first to get number of selected files and folders */    
        build_header_box ();

        /* Permissions */
        /* Don't show permissions for uri scheme trash and archives */
        if (!(count == 1 && !goffile.location.is_native () && !goffile.is_remote_uri_scheme ())) {
            construct_perm_panel ();
            add_section (stack, _("Permissions"), PanelType.PERMISSIONS.to_string (), perm_grid);
            if (!goffile.can_set_permissions ()) {
                foreach (var widget in perm_grid.get_children ()) {
                    widget.set_sensitive (false);
                }
            }
        }

        /* Preview */
        if (count == 1 && goffile.flags != 0) {
            /* Retrieve the low quality (existent) thumbnail.
             * This will be shown to prevent resizing the properties window
             * when the large preview is retrieved.
             */
            Gdk.Pixbuf small_preview;

            if (view.is_in_recent ()) {
                small_preview = goffile.get_icon_pixbuf (256, true, GOF.FileIconFlags.NONE);
            } else {
                small_preview = goffile.get_icon_pixbuf (256, true, GOF.FileIconFlags.USE_THUMBNAILS);
            }

            /* Request the creation of the large thumbnail */
            Marlin.Thumbnailer.get ().queue_file (goffile, null, /* LARGE */ true);
            var preview_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            construct_preview_panel (preview_box, small_preview);
            add_section (stack, _("Preview"), PanelType.PREVIEW.to_string (), preview_box);
        }

        show_all ();
        update_widgets_state ();
    }

    private void update_size_value () {
        size_value.label = format_size ((int64) total_size);
        contains_value.label = get_contains_value (folder_count, file_count);

        if (size_warning > 0) {
            var size_warning_image = new Gtk.Image.from_icon_name ("help-info-symbolic", Gtk.IconSize.MENU);
            size_warning_image.halign = Gtk.Align.START;
            size_warning_image.hexpand = true;
            size_warning_image.tooltip_markup = "<b>" + _("Actual Size Could Be Larger") + "</b>" + "\n" + ngettext ("%i file could not be read due to permissions or other errors.", "%i files could not be read due to permissions or other errors.", (ulong) size_warning).printf (size_warning);
            info_grid.attach_next_to (size_warning_image, size_value, Gtk.PositionType.RIGHT);
            info_grid.show_all ();
        }
    }

    private void update_selection_size () {
        total_size = 0;
        uncounted_folders = 0;
        selected_folders = 0;
        selected_files = 0;
        folder_count = 0;
        file_count = 0;
        size_warning = 0;

        deep_count_directories = null;

        foreach (GOF.File gof in files) {
            if (gof.is_root_network_folder ()) {
                size_value.label = _("unknown");
                continue;
            }
            if (gof.is_directory) {
                mutex.lock ();
                uncounted_folders++; /* this gets decremented by DeepCount*/
                mutex.unlock ();

                selected_folders++;
                var d = new Marlin.DeepCount (gof.location); /* Starts counting on creation */
                deep_count_directories.prepend (d);

                d.finished.connect (() => {
                    mutex.lock ();
                    deep_count_directories.remove (d);

                    total_size += d.total_size;
                    size_warning = d.file_not_read;
                    if (file_count + uncounted_folders == size_warning)
                        size_value.label = _("unknown");

                    folder_count += d.dirs_count;
                    file_count += d.files_count;
                    uncounted_folders--; /* triggers signal which updates description when reaches zero */
                    mutex.unlock ();
                });

            } else {
                selected_files++;
            }

            mutex.lock ();
            total_size += PropertiesWindow.file_real_size (gof);
            mutex.unlock ();
        }

        if (uncounted_folders > 0) {/* possible race condition - uncounted_folders could have been decremented? */
            spinner.start ();
            uncounted_folders_changed.connect (() => {
                if (uncounted_folders == 0) {
                    spinner.hide ();
                    spinner.stop ();
                    update_size_value ();
                }
            });
        } else {
            update_size_value ();
        }
    }

    private void rename_file (GOF.File file, string new_name) {
        /* Only rename if name actually changed */
        original_name = file.info.get_name ();

        if (new_name != "") {
            if (new_name != original_name) {
                proposed_name = new_name;
                view.set_file_display_name (file.location, new_name, after_rename);
            }
        } else {
            reset_entry_text ();
        }
    }

    private void after_rename (GLib.File original_file, GLib.File? new_location) {
        if (new_location != null) {
            reset_entry_text (new_location.get_basename ());
            goffile = GOF.File.@get (new_location);
            files.first ().data = goffile;
        } else {
            reset_entry_text ();  //resets entry to old name
        }
    }

    public void reset_entry_text (string? new_name = null) {
        if (new_name != null) {
            original_name = new_name;
        }

        entry.set_text (original_name);
    }

    private void build_header_box () {
        /* create some widgets first (may be hidden by update_selection_size ()) */
        var file_pix = goffile.get_icon_pixbuf (48, false, GOF.FileIconFlags.NONE);
        var file_icon = new Gtk.Image.from_pixbuf (file_pix);
        overlay_emblems (file_icon, goffile.emblems_list);

        /* Build header box */
        if (count > 1 || (count == 1 && !goffile.is_writable ())) {
            var label = new Gtk.Label (get_selected_label (selected_folders, selected_files));
            label.halign = Gtk.Align.START;
            header_title = label;
        } else if (count == 1 && goffile.is_writable ()) {
            entry = new Gtk.Entry ();
            original_name = goffile.info.get_name ();
            reset_entry_text ();

            entry.activate.connect (() => {
                rename_file (goffile, entry.get_text ());
            });

            entry.focus_out_event.connect (() => {
                rename_file (goffile, entry.get_text ());
                return false;
            });
            header_title = entry;
        }

        create_header_title ();
    }

    private string? get_common_ftype () {
        string? ftype = null;
        if (files == null)
            return null;

        foreach (GOF.File gof in files) {
            var gof_ftype = gof.get_ftype ();
            if (ftype == null && gof != null) {
                ftype = gof_ftype;
                continue;
            }
            if (ftype != gof_ftype)
                return null;
        }

        return ftype;
    }

    private bool got_common_location () {
        File? loc = null;
        foreach (GOF.File gof in files) {
            if (loc == null && gof != null) {
                if (gof.directory == null)
                    return false;
                loc = gof.directory;
                continue;
            }
            if (!loc.equal (gof.directory))
                return false;
        }

        return true;
    }

    private GLib.File? get_parent_loc (string path) {
        var loc = File.new_for_path (path);
        return loc.get_parent ();
    }

    private string? get_common_trash_orig () {
        File loc = null;
        string path = null;

        foreach (GOF.File gof in files) {
            if (loc == null && gof != null) {
                loc = get_parent_loc (gof.info.get_attribute_byte_string (FileAttribute.TRASH_ORIG_PATH));
                continue;
            }
            if (gof != null && !loc.equal (get_parent_loc (gof.info.get_attribute_byte_string (FileAttribute.TRASH_ORIG_PATH))))
                return null;
        }

        if (loc == null)
            path = "/";
        else
            path = loc.get_parse_name();

        return path;
    }

    private string filetype (GOF.File file) {
        ftype = get_common_ftype ();
        if (ftype != null) {
            return ftype;
        } else {
            /* show list of mimetypes only if we got a default application in common */
            if (view.get_default_app () != null && !goffile.is_directory) {
                string str = null;
                foreach (var mime in mimes) {
                    (str == null) ? str = mime : str = string.join (", ", str, mime);
                }
                return str;
            }
        }
        return _("Unknown");
    }

    private string resolution (GOF.File file) {
        /* get image size in pixels using an asynchronous method to stop the interface blocking on
         * large images. */
        if (file.width > 0) { /* resolution has already been determined */
            return goffile.width.to_string () +" × " + goffile.height.to_string () + " px";
        } else {
            /* Async function will update info when resolution determined */
            get_resolution.begin (file);
            return _("Loading…");
        }
    }

    private string location (GOF.File file) {
        if (view.is_in_recent ()) {
            string original_location = file.get_display_target_uri ().replace ("%20", " ");
            string file_name = file.get_display_name ().replace ("%20", " ");
            string location_folder = original_location.slice (0, -(file_name.length)).replace ("%20", " ");
            string location_name = location_folder.slice (7, -1);

            return "<a href=\"" + Markup.escape_text (location_folder) + "\">" + Markup.escape_text (location_name) + "</a>";
        } else {
            return "<a href=\"" + Markup.escape_text (file.directory.get_uri ()) + "\">" + Markup.escape_text (file.directory.get_parse_name ()) + "</a>";
        }
    }

    private string original_location (GOF.File file) {
        /* print orig location of trashed files */
        if (file.info.get_attribute_byte_string (FileAttribute.TRASH_ORIG_PATH) != null) {
            var trash_orig_loc = get_common_trash_orig ();
            if (trash_orig_loc != null) {
                return "<a href=\"" + get_parent_loc (file.info.get_attribute_byte_string (FileAttribute.TRASH_ORIG_PATH)).get_uri () + "\">" + trash_orig_loc + "</a>";
            }
        }
        return _("Unknown");
    }

    private async void get_resolution (GOF.File goffile) {
        GLib.FileInputStream? stream = null;
        GLib.File file = goffile.location;
        string resolution = _("Could not be determined");

        try {
            stream = yield file.read_async (0, cancellable);
            if (stream == null) {
                error ("Could not read image file's size data");
            } else {
                var pixbuf = yield new Gdk.Pixbuf.from_stream_async (stream, cancellable);
                goffile.width = pixbuf.get_width ();
                goffile.height = pixbuf.get_height ();
                resolution = goffile.width.to_string () +" × " + goffile.height.to_string () + " px";
            }
        } catch (Error e) {
            warning ("Error loading image resolution in PropertiesWindow: %s", e.message);
        }
        try {
            stream.close ();
        } catch (GLib.Error e) {
            debug ("Error closing stream in get_resolution: %s", e.message);
        }

        resolution_value.label = resolution;
    }

    private void construct_info_panel (GOF.File file) {
        /* Have to have these separate as size call is async */
        var size_key_label = new KeyLabel (_("Size:"));

        spinner = new Gtk.Spinner ();
        spinner.halign = Gtk.Align.START;

        size_value = new ValueLabel ("");

        type_key_label = new KeyLabel (_("Type:"));
        type_value = new ValueLabel ("");

        contains_key_label = new KeyLabel (_("Contains:"));
        contains_value = new ValueLabel ("");

        info_grid.attach (size_key_label, 0, 1, 1, 1);
        info_grid.attach_next_to (spinner, size_key_label, Gtk.PositionType.RIGHT);
        info_grid.attach_next_to (size_value, size_key_label, Gtk.PositionType.RIGHT);
        info_grid.attach (type_key_label, 0, 2, 1, 1);
        info_grid.attach_next_to (type_value, type_key_label, Gtk.PositionType.RIGHT, 3, 1);
        info_grid.attach (contains_key_label, 0, 3, 1, 1);
        info_grid.attach_next_to (contains_value, contains_key_label, Gtk.PositionType.RIGHT, 3, 1);

        int n = 4;

        if (count == 1) {
            var time_created = file.get_formated_time (FileAttribute.TIME_CREATED);
            if (time_created != null) {
                var key_label = new KeyLabel (_("Created:"));
                var value_label = new ValueLabel (time_created);
                info_grid.attach (key_label, 0, n, 1, 1);
                info_grid.attach_next_to (value_label, key_label, Gtk.PositionType.RIGHT, 3, 1);
                n++;
            }

            if (file.formated_modified != null) {
                var key_label = new KeyLabel (_("Modified:"));
                var value_label = new ValueLabel (file.formated_modified);
                info_grid.attach (key_label, 0, n, 1, 1);
                info_grid.attach_next_to (value_label, key_label, Gtk.PositionType.RIGHT, 3, 1);
                n++;
            }

            var time_last_access = file.get_formated_time (FileAttribute.TIME_ACCESS);
            if (time_last_access != null) {
                var key_label = new KeyLabel (_("Last Access:"));
                var value_label = new ValueLabel (time_last_access);
                info_grid.attach (key_label, 0, n, 1, 1);
                info_grid.attach_next_to (value_label, key_label, Gtk.PositionType.RIGHT, 3, 1);
                n++;
            }
        }

        if (count == 1 && file.is_trashed ()) {
            var deletion_date = file.info.get_attribute_as_string ("trash::deletion-date");
            if (deletion_date != null) {
                var key_label = new KeyLabel (_("Deleted:"));
                var value_label = new ValueLabel (deletion_date);
                info_grid.attach (key_label, 0, n, 1, 1);
                info_grid.attach_next_to (value_label, key_label, Gtk.PositionType.RIGHT, 3, 1);
                n++;
            }
        }

        var ftype = filetype (file);

        var mimetype_key = new KeyLabel (_("Mimetype:"));
        var mimetype_value = new ValueLabel (ftype);
        info_grid.attach (mimetype_key, 0, n, 1, 1);
        info_grid.attach_next_to (mimetype_value, mimetype_key, Gtk.PositionType.RIGHT, 3, 1);
        n++;

        if (count == 1 && "image" in ftype) {
            var resolution_key = new KeyLabel (_("Resolution:"));
            resolution_value = new ValueLabel (resolution (file));
            info_grid.attach (resolution_key, 0, n, 1, 1);
            info_grid.attach_next_to (resolution_value, resolution_key, Gtk.PositionType.RIGHT, 3, 1);
            n++;
        }

        if (got_common_location ()) {
            var location_key = new KeyLabel (_("Location:"));
            var location_value = new ValueLabel (location (file));
            location_value.ellipsize = Pango.EllipsizeMode.MIDDLE;
            location_value.max_width_chars = 32;
            info_grid.attach (location_key, 0, n, 1, 1);
            info_grid.attach_next_to (location_value, location_key, Gtk.PositionType.RIGHT, 3, 1);
            n++;
        }

        if (count == 1 && file.info.get_is_symlink ()) {
            var key_label = new KeyLabel (_("Target:"));
            var value_label = new ValueLabel (file.info.get_symlink_target());
            info_grid.attach (key_label, 0, n, 1, 1);
            info_grid.attach_next_to (value_label, key_label, Gtk.PositionType.RIGHT, 3, 1);
            n++;
        }

        if (file.is_trashed ()) {
            var key_label = new KeyLabel (_("Original Location:"));
            var value_label = new ValueLabel (original_location (file));
            info_grid.attach (key_label, 0, n, 1, 1);
            info_grid.attach_next_to (value_label, key_label, Gtk.PositionType.RIGHT, 3, 1);
            n++;
        }

        /* Open with */
        if (view.get_default_app () != null && !goffile.is_directory) {
            Gtk.TreeIter iter;

            AppInfo default_app = view.get_default_app ();
            store_apps = new Gtk.ListStore (3, typeof (AppInfo), typeof (string), typeof (Icon));
            unowned List<AppInfo> apps = view.get_open_with_apps ();
            foreach (var app in apps) {
                store_apps.append (out iter);
                store_apps.set (iter,
                                AppsColumn.APP_INFO, app,
                                AppsColumn.LABEL, app.get_name (),
                                AppsColumn.ICON, ensure_icon (app));
            }
            store_apps.append (out iter);
            store_apps.set (iter,
                            AppsColumn.LABEL, _("Other Application…"));
            store_apps.prepend (out iter);
            store_apps.set (iter,
                            AppsColumn.APP_INFO, default_app,
                            AppsColumn.LABEL, default_app.get_name (),
                            AppsColumn.ICON, ensure_icon (default_app));

            var renderer = new Gtk.CellRendererText ();
            var pix_renderer = new Gtk.CellRendererPixbuf ();

            var combo = new Gtk.ComboBox.with_model ((Gtk.TreeModel) store_apps);
            combo.active = 0;
            combo.valign = Gtk.Align.CENTER;
            combo.pack_start (pix_renderer, false);
            combo.pack_start (renderer, true);
            combo.add_attribute (renderer, "text", AppsColumn.LABEL);
            combo.add_attribute (pix_renderer, "gicon", AppsColumn.ICON);

            combo.changed.connect (combo_open_with_changed);

            var key_label = new KeyLabel (_("Open with:"));

            info_grid.attach (key_label, 0, n, 1, 1);
            info_grid.attach_next_to (combo, key_label, Gtk.PositionType.RIGHT);
        }

        /* Device Usage */
        if (should_show_device_usage ()) {
            try {
                var info = goffile.get_target_location ().query_filesystem_info ("filesystem::*");
                create_storage_bar (info, n);
            } catch (Error e) {
                warning ("error: %s", e.message);
            }
        }
    }

    private bool should_show_device_usage () {
        if (files_contain_a_directory)
            return true;
        if (count == 1) {
            if (goffile.can_unmount ())
                return true;
            var rootfs_loc = File.new_for_uri ("file:///");
            if (goffile.get_target_location ().equal (rootfs_loc))
                return true;
        }

        return false;
    }

    private void toggle_button_add_label (Gtk.ToggleButton btn, string str) {
        var l_read = new Gtk.Label ("<span size='small'>"+ str + "</span>");
        l_read.set_use_markup (true);
        btn.add (l_read);
    }

    private void update_perm_codes (PermissionType pt, int val, int mult) {
        switch (pt) {
        case PermissionType.USER:
            owner_perm_code += mult*val;
            break;
        case PermissionType.GROUP:
            group_perm_code += mult*val;
            break;
        case PermissionType.OTHER:
            everyone_perm_code += mult*val;
            break;
        }
    }

    private void action_toggled_read (Gtk.ToggleButton btn) {
        unowned PermissionType pt = btn.get_data ("permissiontype");
        int mult = 1;

        reset_and_cancel_perm_timeout ();
        if (!btn.get_active ())
            mult = -1;
        update_perm_codes (pt, 4, mult);
        if (perm_code_should_update)
            perm_code.set_text ("%d%d%d".printf (owner_perm_code, group_perm_code, everyone_perm_code));
    }

    private void action_toggled_write (Gtk.ToggleButton btn) {
        unowned PermissionType pt = btn.get_data ("permissiontype");
        int mult = 1;

        reset_and_cancel_perm_timeout ();
        if (!btn.get_active ())
            mult = -1;
        update_perm_codes (pt, 2, mult);
        if (perm_code_should_update)
            perm_code.set_text ("%d%d%d".printf(owner_perm_code, group_perm_code, everyone_perm_code));
    }

    private void action_toggled_execute (Gtk.ToggleButton btn) {
        unowned PermissionType pt = btn.get_data ("permissiontype");
        int mult = 1;

        reset_and_cancel_perm_timeout ();
        if (!btn.get_active ())
            mult = -1;
        update_perm_codes (pt, 1, mult);
        if (perm_code_should_update)
            perm_code.set_text ("%d%d%d".printf(owner_perm_code, group_perm_code, everyone_perm_code));
    }

    private Gtk.Box create_perm_choice (PermissionType pt) {
        Gtk.Box hbox;

        hbox = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        hbox.homogeneous = true;
        hbox.get_style_context ().add_class (Gtk.STYLE_CLASS_LINKED);
        var btn_read = new Gtk.ToggleButton ();
        toggle_button_add_label (btn_read, _("Read"));
        btn_read.set_data ("permissiontype", pt);
        btn_read.toggled.connect (action_toggled_read);
        var btn_write = new Gtk.ToggleButton ();
        toggle_button_add_label (btn_write, _("Write"));
        btn_write.set_data ("permissiontype", pt);
        btn_write.toggled.connect (action_toggled_write);
        var btn_exe = new Gtk.ToggleButton ();
        toggle_button_add_label (btn_exe, _("Execute"));
        btn_exe.set_data ("permissiontype", pt);
        btn_exe.toggled.connect (action_toggled_execute);
        hbox.pack_start (btn_read);
        hbox.pack_start (btn_write);
        hbox.pack_start (btn_exe);

        return hbox;
    }

    private uint32 get_perm_from_chmod_unit (uint32 vfs_perm, int nb,
                                             int chmod, PermissionType pt) {
        if (nb > 7 || nb < 0)
            critical ("erroned chmod code %d %d", chmod, nb);

        int[] chmod_types = { 4, 2, 1};

        int i = 0;
        for (; i<3; i++) {
            int div = nb / chmod_types[i];
            int modulo = nb % chmod_types[i];
            if (div >= 1)
                vfs_perm |= vfs_perms[pt,i];
            nb = modulo;
        }

        return vfs_perm;
    }

    private uint32 chmod_to_vfs (int chmod) {
        uint32 vfs_perm = 0;

        /* user */
        vfs_perm = get_perm_from_chmod_unit (vfs_perm, (int) chmod / 100,
                                             chmod, PermissionType.USER);
        /* group */
        vfs_perm = get_perm_from_chmod_unit (vfs_perm, (int) (chmod / 10) % 10,
                                             chmod, PermissionType.GROUP);
        /* other */
        vfs_perm = get_perm_from_chmod_unit (vfs_perm, (int) chmod % 10,
                                             chmod, PermissionType.OTHER);

        return vfs_perm;
    }

    private void update_permission_type_buttons (Gtk.Box hbox, uint32 permissions, PermissionType pt) {
        int i=0;
        foreach (var widget in hbox.get_children ()) {
            Gtk.ToggleButton btn = (Gtk.ToggleButton) widget;
            ((permissions & vfs_perms[pt, i]) != 0) ? btn.active = true : btn.active = false;
            i++;
        }
    }

    private void update_perm_grid_toggle_states (uint32 permissions) {
        Gtk.Box hbox;

        /* update USR row */
        hbox = (Gtk.Box) perm_grid.get_child_at (1,3);
        update_permission_type_buttons (hbox, permissions, PermissionType.USER);

        /* update GRP row */
        hbox = (Gtk.Box) perm_grid.get_child_at (1,4);
        update_permission_type_buttons (hbox, permissions, PermissionType.GROUP);

        /* update OTHER row */
        hbox = (Gtk.Box) perm_grid.get_child_at (1,5);
        update_permission_type_buttons (hbox, permissions, PermissionType.OTHER);
    }

    private bool is_chmod_code (string str) {
        try {
            var regex = new Regex ("^[0-7]{3}$");
            if (regex.match (str))
                return true;
        } catch (RegexError e) {
            assert_not_reached ();
        }

        return false;
    }

    private void reset_and_cancel_perm_timeout () {
        if (cancellable != null) {
            cancellable.cancel ();
            cancellable.reset ();
        }
        if (timeout_perm != 0) {
            Source.remove (timeout_perm);
            timeout_perm = 0;
        }
    }

    private async void file_set_attributes (GOF.File file, string attr,
                                            uint32 val, Cancellable? _cancellable = null) {
        FileInfo info = new FileInfo ();

        /**TODO** use marlin jobs*/

        try {
            info.set_attribute_uint32 (attr, val);
            yield file.location.set_attributes_async (info,
                                                      FileQueryInfoFlags.NONE,
                                                      Priority.DEFAULT,
                                                      _cancellable, null);
        } catch (Error e) {
            warning ("Could not set file attribute %s: %s", attr, e.message);
        }
    }

    private void entry_changed () {
        var str = perm_code.get_text ();
        if (is_chmod_code (str)) {
            reset_and_cancel_perm_timeout ();
            timeout_perm = Timeout.add (60, () => {
                uint32 perm = chmod_to_vfs (int.parse (str));
                perm_code_should_update = false;
                update_perm_grid_toggle_states (perm);
                perm_code_should_update = true;
                int n = 0;
                foreach (GOF.File gof in files) {
                    if (gof.can_set_permissions() && gof.permissions != perm) {
                        gof.permissions = perm;
                        /* update permission label once */
                        if (n<1)
                            l_perm.set_text (goffile.get_permissions_as_string ());
                        /* real update permissions */
                        file_set_attributes.begin (gof, FileAttribute.UNIX_MODE, perm, cancellable);
                        n++;
                    } else {
                        warning ("can't change permission on %s", gof.uri);
                    }
                        /**TODO** add a list of permissions set errors in the property dialog.*/
                }
                timeout_perm = 0;

                return false;
            });
        }
    }

    private void combo_owner_changed (Gtk.ComboBox combo) {
        Gtk.TreeIter iter;
        string user;
        int uid;

        if (!combo.get_active_iter(out iter))
            return;

        store_users.get (iter, 0, out user);

        if (!goffile.can_set_owner ()) {
            critical ("error can't set user");
            return;
        }

        if (!Eel.get_user_id_from_user_name (user, out uid)
            && !Eel.get_id_from_digit_string (user, out uid)) {
            critical ("user doesn t exit");
        }

        if (uid == goffile.uid)
            return;

        foreach (GOF.File gof in files)
            file_set_attributes.begin (gof, FileAttribute.UNIX_UID, uid);
    }

    private void combo_group_changed (Gtk.ComboBox combo) {
        Gtk.TreeIter iter;
        string group;
        int gid;

        if (!combo.get_active_iter(out iter))
            return;

        store_groups.get (iter, 0, out group);

        if (!goffile.can_set_group ()) {
            critical ("error can't set group");
            return;
        }

        /* match gid from name */
        if (!Eel.get_group_id_from_group_name (group, out gid)
            && !Eel.get_id_from_digit_string (group, out gid)) {
            critical ("group doesn t exit");
            return;
        }

        if (gid == goffile.gid)
            return;

        foreach (GOF.File gof in files)
            file_set_attributes.begin (gof, FileAttribute.UNIX_GID, gid);
    }

    private Gtk.Grid construct_perm_panel () {
        perm_grid = new Gtk.Grid ();
        perm_grid.column_spacing = 6;
        perm_grid.row_spacing = 6;
        perm_grid.halign = Gtk.Align.CENTER;

        Gtk.Widget key_label;
        Gtk.Widget value_label;
        Gtk.Box value_hlabel;

        key_label = new Gtk.Label (_("Owner:"));
        key_label.halign = Gtk.Align.END;
        perm_grid.attach (key_label, 0, 1, 1, 1);
        value_label = create_owner_choice ();
        perm_grid.attach (value_label, 1, 1, 2, 1);

        key_label = new Gtk.Label (_("Group:"));
        key_label.halign = Gtk.Align.END;
        perm_grid.attach (key_label, 0, 2, 1, 1);
        value_label = create_group_choice ();
        perm_grid.attach (value_label, 1, 2, 2, 1);

        /* make a separator with margins */
        key_label.margin_bottom = 12;
        value_label.margin_bottom = 12;

        key_label = new KeyLabel (_("Owner:"));
        value_hlabel = create_perm_choice (PermissionType.USER);
        perm_grid.attach (key_label, 0, 3, 1, 1);
        perm_grid.attach (value_hlabel, 1, 3, 2, 1);
        key_label = new KeyLabel (_("Group:"));
        value_hlabel = create_perm_choice (PermissionType.GROUP);
        perm_grid.attach (key_label, 0, 4, 1, 1);
        perm_grid.attach (value_hlabel, 1, 4, 2, 1);
        key_label = new KeyLabel (_("Everyone:"));
        value_hlabel = create_perm_choice (PermissionType.OTHER);
        perm_grid.attach (key_label, 0, 5, 1, 1);
        perm_grid.attach (value_hlabel, 1, 5, 2, 1);

        perm_code = new Granite.Widgets.XsEntry ();
        perm_code.set_text ("000");
        perm_code.set_max_length (3);
        perm_code.set_size_request (35, -1);

        l_perm = new Gtk.Label (goffile.get_permissions_as_string ());

        perm_grid.attach (l_perm, 1, 6, 1, 1);
        perm_grid.attach (perm_code, 2, 6, 1, 1);

        update_perm_grid_toggle_states (goffile.permissions);

        perm_code.changed.connect (entry_changed);
        return perm_grid;
    }

    private bool selection_can_set_owner () {
        foreach (GOF.File gof in files)
            if (!gof.can_set_owner ())
                return false;

        return true;
    }

    private string? get_common_owner () {
        int uid = -1;
        if (files == null)
            return null;

        foreach (GOF.File gof in files){
            if (uid == -1 && gof != null) {
                uid = gof.uid;
                continue;
            }
            if (gof != null && uid != gof.uid)
                return null;
        }

        return goffile.info.get_attribute_string (FileAttribute.OWNER_USER);
    }

    private bool selection_can_set_group () {
        foreach (GOF.File gof in files)
            if (!gof.can_set_group ())
                return false;

        return true;
    }

    private string? get_common_group () {
        int gid = -1;
        if (files == null)
            return null;

        foreach (GOF.File gof in files) {
            if (gid == -1 && gof != null) {
                gid = gof.gid;
                continue;
            }
            if (gof != null && gid != gof.gid)
                return null;
        }

        return goffile.info.get_attribute_string (FileAttribute.OWNER_GROUP);
    }

    private Gtk.Widget create_owner_choice () {
        Gtk.Widget choice;
        choice = null;

        if (selection_can_set_owner ()) {
            GLib.List<string> users;
            Gtk.TreeIter iter;

            store_users = new Gtk.ListStore (1, typeof (string));
            users = Eel.get_user_names();
            int owner_index = -1;
            int i = 0;
            foreach (var user in users) {
                if (user == goffile.owner) {
                    owner_index = i;
                }
                store_users.append(out iter);
                store_users.set(iter, 0, user);
                i++;
            }

            /* If ower is not known, we prepend it.
             * It happens when the owner has no matching identifier in the password file.
             */
            if (owner_index == -1) {
                store_users.prepend (out iter);
                store_users.set (iter, 0, goffile.owner);
            }

            var combo = new Gtk.ComboBox.with_model ((Gtk.TreeModel) store_users);
            var renderer = new Gtk.CellRendererText ();
            combo.pack_start (renderer, true);
            combo.add_attribute (renderer, "text", 0);
            if (owner_index == -1)
                combo.set_active (0);
            else
                combo.set_active (owner_index);

            combo.changed.connect (combo_owner_changed);

            choice = (Gtk.Widget) combo;
        } else {
            string? common_owner = get_common_owner ();
            if (common_owner == null)
                common_owner = "--";
            choice = (Gtk.Widget) new Gtk.Label (common_owner);
            choice.set_halign (Gtk.Align.START);
        }

        choice.set_valign (Gtk.Align.CENTER);

        return choice;
    }

    private Gtk.Widget create_group_choice () {
        Gtk.Widget choice;

        if (selection_can_set_group ()) {
            GLib.List<string> groups;
            Gtk.TreeIter iter;

            store_groups = new Gtk.ListStore (1, typeof (string));
            groups = goffile.get_settable_group_names ();
            int group_index = -1;
            int i = 0;
            foreach (var group in groups) {
                if (group == goffile.group) {
                    group_index = i;
                }
                store_groups.append (out iter);
                store_groups.set (iter, 0, group);
                i++;
            }

            /* If ower is not known, we prepend it.
             * It happens when the owner has no matching identifier in the password file.
             */
            if (group_index == -1) {
                store_groups.prepend (out iter);
                store_groups.set (iter, 0, goffile.owner);
            }

            var combo = new Gtk.ComboBox.with_model ((Gtk.TreeModel) store_groups);
            var renderer = new Gtk.CellRendererText ();
            combo.pack_start (renderer, true);
            combo.add_attribute (renderer, "text", 0);

            if (group_index == -1)
                combo.set_active (0);
            else
                combo.set_active (group_index);

            combo.changed.connect (combo_group_changed);

            choice = (Gtk.Widget) combo;
        } else {
            string? common_group = get_common_group ();
            if (common_group == null)
                common_group = "--";
            choice = (Gtk.Widget) new Gtk.Label (common_group);
            choice.set_halign (Gtk.Align.START);
        }

        choice.set_valign (Gtk.Align.CENTER);

        return choice;
    }

    private void construct_preview_panel (Gtk.Box box, Gdk.Pixbuf? small_preview) {
        evbox = new Granite.Widgets.ImgEventBox (Gtk.Orientation.HORIZONTAL);
        if (small_preview != null)
            evbox.set_from_pixbuf (small_preview);
        box.pack_start (evbox, false, true, 0);

        goffile.icon_changed.connect (() => {
            var large_preview_path = goffile.get_preview_path ();
            if (large_preview_path != null)
                try {
                    var large_preview = new Gdk.Pixbuf.from_file (large_preview_path);
                    evbox.set_from_pixbuf (large_preview);
                } catch (Error e) {
                    warning (e.message);
                }
        });
    }

    private Icon ensure_icon (AppInfo app) {
        Icon icon = app.get_icon ();
        if (icon == null)
            icon = new ThemedIcon ("application-x-executable");

        return icon;
    }

    private void combo_open_with_changed (Gtk.ComboBox combo) {
        Gtk.TreeIter iter;
        string app_label;
        AppInfo? app;

        if (!combo.get_active_iter (out iter))
            return;

        store_apps.get (iter,
                        AppsColumn.LABEL, out app_label,
                        AppsColumn.APP_INFO, out app);

        if (app == null) {
            var app_chosen = Marlin.MimeActions.choose_app_for_glib_file (goffile.location, this);
            if (app_chosen != null) {
                store_apps.prepend (out iter);
                store_apps.set (iter,
                                AppsColumn.APP_INFO, app_chosen,
                                AppsColumn.LABEL, app_chosen.get_name (),
                                AppsColumn.ICON, ensure_icon (app_chosen));
                combo.set_active (0);
            }
        } else {
            try {
                foreach (var mime in mimes)
                    app.set_as_default_for_type (mime);

            } catch (Error e) {
                critical ("Couldn't set as default: %s", e.message);
            }
        }
    }

    public static uint64 file_real_size (GOF.File gof) {
        if (!gof.is_connected)
            return 0;

        uint64 file_size = gof.size;
        if (gof.location is GLib.File) {
            try {
                var info = gof.location.query_info (FileAttribute.STANDARD_ALLOCATED_SIZE, FileQueryInfoFlags.NONE);
                uint64 allocated_size = info.get_attribute_uint64 (FileAttribute.STANDARD_ALLOCATED_SIZE);
                /* Check for sparse file, allocated size will be smaller, for normal files allocated size
                 * includes overhead size so we don't use it for those here
                 */
                if (allocated_size > 0 && allocated_size < file_size && !gof.is_directory)
                    file_size = allocated_size;
            } catch (Error err) {
                debug ("%s", err.message);
                gof.is_connected = false;
            }
        }
        return file_size;
    }

    private string get_contains_value (uint folders, uint files) {
        string txt = "";
        if (folders > 0) {
            if (folders > 1) {
                if (files > 0) {
                    if (files > 1) {
                        txt = _("%u subfolders and %u files").printf (folders, files);
                    } else {
                        txt = _("%u subfolders and %u file").printf (folders,files);
                    }
                } else {
                    txt = _("%u subfolders").printf (folders);
                }
            } else {
                if (files > 0) {
                    if (files > 1) {
                        txt = _("%u subfolder and %u files").printf (folders, files);
                    } else {
                        txt = _("%u subfolder and %u file").printf (folders, files);
                    }
                } else {
                    txt = _("%u folder").printf (folders);
                }
            }
        } else {
            if (files > 0) {
                if (files > 1) {
                    txt = _("%u files").printf (files);
                } else {
                    txt = _("%u file").printf (files);
                }
            }
        }

        return txt;
    }

    private string get_selected_label (uint folders, uint files) {
        string txt = "";
        uint total = folders + files;

        if (folders > 0) {
            if (folders > 1) {
                if (files > 0) {
                    if (files > 1) {
                        txt = _("%u selected items (%u folders and %u files)").printf (total, folders, files);
                    } else {
                        txt = _("%u selected items (%u folders and %u file)").printf (total, folders, files);
                    }
                } else {
                    txt = _("%u folders").printf (folders);
                }
            } else {
                if (files > 0) {
                    if (files > 1) {
                        txt = _("%u selected items (%u folder and %u files)").printf (total, folders,files);
                    } else {
                        txt = _("%u selected items (%u folder and %u file)").printf (total, folders,files);
                    }
                } else {
                    txt = _("%u folder").printf (folders); /* displayed for background folder*/
                }
            }
        } else {
            if (files > 0) {
                if (files > 1) {
                    txt = _("%u files").printf (files);
                } else {
                    txt = _("%u file").printf (files); /* should not be displayed - entry instead */
                }
            }
        }

        /* The selection should never be empty */
        return txt;
    }

    /** Hide certain widgets under certain conditions **/
    private void update_widgets_state () {
        if (uncounted_folders == 0) {
            spinner.hide ();
        }

        if (count > 1) {
            type_key_label.hide ();
            type_value.hide ();
        } else {
            if (ftype != null) {
                type_value.label = goffile.formated_type;
            }
        }

        if ((header_title is Gtk.Entry) && !view.is_in_recent ()) {
            int start_offset= 0, end_offset = -1;

            Marlin.get_rename_region (goffile.info.get_name (), out start_offset, out end_offset, goffile.is_folder ());
            (header_title as Gtk.Entry).select_region (start_offset, end_offset);
        }

        /* Only show 'contains' label when only folders selected - otherwise could be ambiguous whether
         * the "contained files" counted are only in the subfolders or not.*/
        /* Only show 'contains' label when folders selected are not empty */
        if (count > selected_folders || contains_value.get_text ().length < 1) {
            contains_key_label.hide ();
            contains_value.hide ();
        } else { /* Make sure it shows otherwise (may have been hidden by previous call)*/
            contains_key_label.show ();
            contains_value.show ();
        }
    }
}
}
