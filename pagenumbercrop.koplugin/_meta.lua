local _ = require("gettext")
return {
    fullname = _("Page number crop"),
    description = _([[Crops the bottom strip of PDF/DjVu pages, to remove printed page numbers.]]),    
    -- Bump this on every release; the updater compares it against the
    -- "tag_name" of the latest GitHub Release (see pagenumbercrop_updater.lua).
    version = "1.0.0",
}
