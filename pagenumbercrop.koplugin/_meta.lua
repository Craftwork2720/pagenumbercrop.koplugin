local _ = require("gettext")
return {
    fullname = _("Page number crop"),
    description = _([[Crops the bottom strip of PDF/DjVu pages, to remove printed page numbers. Optionally skips cropping almost-blank pages.]]),
    -- Bump this on every release; the updater compares it against the
    -- "tag_name" of the latest GitHub Release (see pagenumbercrop_updater.lua).
    version = "1.1.0",
}
