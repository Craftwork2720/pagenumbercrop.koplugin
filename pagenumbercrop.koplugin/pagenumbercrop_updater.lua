--[[--
Checks GitHub Releases for a newer version of this plugin, and offers to
download and install it.

Adapted from xray.koplugin's OTA updater
(https://github.com/ultimatejimmy/xray.koplugin), simplified for a
single-purpose plugin with no per-user config/API keys to preserve across
updates, and using KOReader's own gettext/T() instead of a custom
localization module.

@module koplugin.PageNumberCrop.Updater
--]]--

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local GITHUB_OWNER = "Craftwork2720"
local GITHUB_REPO = "pagenumbercrop.koplugin"
-- Name of the .zip asset attached to each GitHub Release. The release
-- workflow must upload the plugin folder zipped under this exact name.
local ASSET_NAME = "pagenumbercrop.koplugin.zip"
-- Cache validity time in seconds, so repeated checks in the same session (or
-- within the same hour) don't keep hitting the GitHub API. 0 disables it.
local CACHE_TTL = 3600

local M = {}

-- Plugin directory, resolved from this file's own path (…/pagenumbercrop.koplugin/pagenumbercrop_updater.lua).
local _plugin_dir = (debug.getinfo(1, "S").source or ""):match("^@(.+)/[^/]+$")
    or "/mnt/us/extensions/pagenumbercrop.koplugin"

local function _apiUrl()
    return string.format("https://api.github.com/repos/%s/%s/releases/latest",
        GITHUB_OWNER, GITHUB_REPO)
end

local function _cacheFile()
    local ok, DS = pcall(require, "datastorage")
    if ok and DS then
        return DS:getSettingsDir() .. "/pagenumbercrop_update_cache.json"
    end
    return "/tmp/pagenumbercrop_update_cache.json"
end

-- ---------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------

local function _loadCache()
    if CACHE_TTL <= 0 then return nil end
    local fh = io.open(_cacheFile(), "r")
    if not fh then return nil end
    local raw = fh:read("*a")
    fh:close()
    local ok_j, json = pcall(require, "json")
    if not ok_j then return nil end
    local ok_d, data = pcall(json.decode, raw)
    if not ok_d or type(data) ~= "table" then return nil end
    if (os.time() - (data.timestamp or 0)) > CACHE_TTL then return nil end
    return data.payload
end

local function _saveCache(payload)
    if CACHE_TTL <= 0 then return end
    local ok_j, json = pcall(require, "json")
    if not ok_j then return end
    local ok_e, encoded = pcall(json.encode, { timestamp = os.time(), payload = payload })
    if not ok_e then return end
    local fh = io.open(_cacheFile(), "w")
    if fh then
        fh:write(encoded)
        fh:close()
    end
end

local function _clearCache()
    pcall(os.remove, _cacheFile())
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function _currentVersion()
    local ok, meta = pcall(dofile, _plugin_dir .. "/_meta.lua")
    if ok and type(meta) == "table" and meta.version then
        return meta.version
    end
    return "0.0.0"
end

-- Numeric dotted-version comparison (e.g. "1.2.10" > "1.2.9"). Non-numeric
-- suffixes (like "-beta") are ignored for ordering purposes.
local function _versionLessThan(a, b)
    local function parts(v)
        local t_parts = {}
        for n in (v or ""):gmatch("(%d+)") do
            t_parts[#t_parts + 1] = tonumber(n)
        end
        return t_parts
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, math.max(#pa, #pb) do
        local va, vb = pa[i] or 0, pb[i] or 0
        if va < vb then return true end
        if va > vb then return false end
    end
    return false
end

local function _toast(msg, timeout)
    local w = InfoMessage:new{ text = msg, timeout = timeout or 4 }
    UIManager:show(w)
    return w
end

local function _closeWidget(w)
    if w then UIManager:close(w) end
end

-- ---------------------------------------------------------------------------
-- HTTP (mirrors KOReader's own socketutil-based pattern)
-- ---------------------------------------------------------------------------

local function _httpGet(url)
    local ok_su, socketutil = pcall(require, "socketutil")
    local http = require("socket/http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    if ok_su then
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end
    local chunks = {}
    local code, headers, status = socket.skip(1, http.request{
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = "PageNumberCrop-Updater/1.0",
            ["Accept"] = "application/vnd.github.v3+json",
        },
        sink = ltn12.sink.table(chunks),
        redirect = true,
    })
    if ok_su then socketutil:reset_timeout() end
    if ok_su and (code == socketutil.TIMEOUT_CODE or code == socketutil.SSL_HANDSHAKE_CODE
            or code == socketutil.SINK_TIMEOUT_CODE) then
        return nil, "timeout (" .. tostring(code) .. ")"
    end
    if headers == nil then
        return nil, "network error (" .. tostring(code or status) .. ")"
    end
    if code == 200 then
        return table.concat(chunks)
    end
    return nil, string.format("HTTP %s", tostring(code))
end

local function _httpGetToFile(url, dest_path)
    local ok_su, socketutil = pcall(require, "socketutil")
    local http = require("socket/http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local fh, err_open = io.open(dest_path, "wb")
    if not fh then
        return nil, "Could not create file: " .. tostring(err_open)
    end
    if ok_su then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    end
    local code, headers, status = socket.skip(1, http.request{
        url = url,
        method = "GET",
        headers = { ["User-Agent"] = "PageNumberCrop-Updater/1.0" },
        sink = ltn12.sink.file(fh),
        redirect = true,
    })
    if ok_su then socketutil:reset_timeout() end
    if ok_su and (code == socketutil.TIMEOUT_CODE or code == socketutil.SSL_HANDSHAKE_CODE
            or code == socketutil.SINK_TIMEOUT_CODE) then
        pcall(os.remove, dest_path)
        return nil, "timeout (" .. tostring(code) .. ")"
    end
    if headers == nil then
        pcall(os.remove, dest_path)
        return nil, "network error (" .. tostring(code or status) .. ")"
    end
    if code == 200 then return true end
    pcall(os.remove, dest_path)
    return nil, string.format("HTTP %s", tostring(code))
end

-- ---------------------------------------------------------------------------
-- Release JSON parsing
-- ---------------------------------------------------------------------------

local function _parseRelease(body)
    local ok_j, json = pcall(require, "json")
    if not ok_j then
        return nil, "json module not available"
    end
    local ok_d, data = pcall(json.decode, body)
    if not ok_d or type(data) ~= "table" then
        return nil, "JSON parse error: " .. tostring(data)
    end
    if data.message and not data.tag_name then
        return nil, "GitHub API error: " .. tostring(data.message)
    end
    local tag = data.tag_name
    if not tag then return nil, "tag_name missing from API response" end

    local download_url = nil
    for _, asset in ipairs(data.assets or {}) do
        if type(asset.name) == "string" and asset.name == ASSET_NAME then
            download_url = asset.browser_download_url
            break
        end
    end

    return {
        version = tag:match("v?(.*)"),
        download_url = download_url,
        html_url = data.html_url,
    }
end

-- ---------------------------------------------------------------------------
-- Unzip / install
-- ---------------------------------------------------------------------------

local function _unzip(zip_path, dest_dir)
    local cmd = string.format("unzip -o -q %q -d %q", zip_path, dest_dir)
    local ret = os.execute(cmd)
    if ret ~= 0 and ret ~= true then
        return nil, "unzip failed (exit " .. tostring(ret) .. ")"
    end
    return true
end

local function _tmpZipPath()
    local ok, DS = pcall(require, "datastorage")
    if ok and DS then
        return DS:getSettingsDir() .. "/pagenumbercrop_update.zip"
    end
    return "/tmp/pagenumbercrop_update.zip"
end

local function _applyUpdate(download_url, new_version)
    local tmp_zip = _tmpZipPath()
    -- The release zip contains the "pagenumbercrop.koplugin" folder itself,
    -- so it's extracted one level up (into the plugins directory), the same
    -- way it was originally installed.
    local parent_dir = _plugin_dir:match("^(.+)/[^/]+$") or _plugin_dir
    local progress_msg = _toast(T(_("Downloading update %1…"), new_version), 120)

    local function doDownloadAndInstall()
        local dl_ok, dl_err = _httpGetToFile(download_url, tmp_zip)
        if not dl_ok then
            return { success = false, stage = "download", err = dl_err }
        end
        local uz_ok, uz_err = _unzip(tmp_zip, parent_dir)
        os.remove(tmp_zip)
        if not uz_ok then
            return { success = false, stage = "unzip", err = uz_err }
        end
        return { success = true }
    end

    local function handleInstallResult(result)
        _closeWidget(progress_msg)
        if not result or not result.success then
            local stage = result and result.stage or "unknown"
            local err = result and result.err or "unknown error"
            logger.err("PageNumberCrop updater: failed at", stage, "-", err)
            _toast(stage == "download"
                and T(_("Download failed: %1"), tostring(err))
                or T(_("Could not install update: %1"), tostring(err)))
            return
        end
        _clearCache()
        UIManager:show(ConfirmBox:new{
            text = T(_("Page Number Crop was updated to %1.\nRestart KOReader now to use the new version?"), new_version),
            ok_text = _("Restart"),
            cancel_text = _("Later"),
            ok_callback = function() UIManager:restartKOReader() end,
        })
    end

    local ok_tr, Trapper = pcall(require, "ui/trapper")
    if ok_tr and Trapper and Trapper.dismissableRunInSubprocess then
        local completed, result = Trapper:dismissableRunInSubprocess(
            doDownloadAndInstall, progress_msg, function(res) handleInstallResult(res) end)
        if completed and result then
            UIManager:scheduleIn(0.2, function() handleInstallResult(result) end)
        elseif completed == false then
            _closeWidget(progress_msg)
            pcall(os.remove, tmp_zip)
            _toast(_("Update cancelled."))
        end
    else
        UIManager:scheduleIn(0.3, function() handleInstallResult(doDownloadAndInstall()) end)
    end
end

-- ---------------------------------------------------------------------------
-- Version check
-- ---------------------------------------------------------------------------

-- @param use_cache when false, always hit the API (a manual check must see
--   the real latest release, not a cached one). A fresh result is still saved
--   to the cache either way, so background checks keep benefiting from it.
local function _doFetch(use_cache)
    if use_cache ~= false then
        local cached = _loadCache()
        if cached then
            logger.info("PageNumberCrop updater: using cached release info")
            return cached
        end
    end
    local body, err = _httpGet(_apiUrl())
    if not body then return { error = err } end
    local release, parse_err = _parseRelease(body)
    if not release then return { error = "parse error: " .. tostring(parse_err) } end
    _saveCache(release)
    return release
end

local function _showUpdateDialog(release, current, silent)
    local latest = release.version
    if not _versionLessThan(current, latest) then
        logger.info("PageNumberCrop updater: up to date (" .. current .. ")")
        if not silent then
            _toast(T(_("Page Number Crop is up to date (%1)."), current))
        end
        return
    end
    logger.info("PageNumberCrop updater: new version available:", latest)
    local header = T(_("A new version of Page Number Crop is available: %1 (you have %2)."), latest, current)

    if not release.download_url then
        UIManager:show(ConfirmBox:new{
            text = header .. "\n\n" ..
                _("No downloadable update asset was found; open the release page instead?"),
            ok_text = _("Open in browser"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                local Device = require("device")
                if Device:canOpenLink() then
                    Device:openLink(release.html_url or string.format(
                        "https://github.com/%s/%s/releases/latest", GITHUB_OWNER, GITHUB_REPO))
                end
            end,
        })
        return
    end

    UIManager:show(ConfirmBox:new{
        text = header .. "\n\n" .. _("Download and install now?"),
        ok_text = _("Update"),
        cancel_text = _("Cancel"),
        ok_callback = function() _applyUpdate(release.download_url, latest) end,
    })
end

--- Checks for updates and always shows a result (checking/up-to-date/error/
--- available), for use from an explicit user action (a menu tap).
function M.checkForUpdates()
    local current = _currentVersion()
    local checking_msg = _toast(_("Checking for updates…"), 15)

    local function handleCheckResult(release)
        _closeWidget(checking_msg)
        if not release then
            _toast(_("Could not check for updates."))
            return
        end
        if release.error then
            logger.err("PageNumberCrop updater: check error:", release.error)
            _toast(T(_("Could not check for updates: %1"), tostring(release.error)))
            return
        end
        _showUpdateDialog(release, current, false)
    end

    local function run()
        local ok_tr, Trapper = pcall(require, "ui/trapper")
        if ok_tr and Trapper and Trapper.dismissableRunInSubprocess then
            local completed, result = Trapper:dismissableRunInSubprocess(
                function() return _doFetch(false) end, checking_msg,
                function(res) handleCheckResult(res) end)
            if completed and result then
                UIManager:scheduleIn(0.2, function() handleCheckResult(result) end)
            elseif completed == false then
                _closeWidget(checking_msg)
                _toast(_("Update check cancelled."))
            end
        else
            UIManager:scheduleIn(0.3, function() handleCheckResult(_doFetch(false)) end)
        end
    end

    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(run)
    else
        run()
    end
end

--- Checks for updates with no "checking…" UI, and only shows a dialog if a
--- newer version is actually available. Meant for an occasional background
--- check (e.g. weekly), never called directly from a menu tap. Silently does
--- nothing when offline, rather than prompting the user to connect.
function M.checkSilentForUpdates()
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and NetworkMgr.isConnected and not NetworkMgr:isConnected() then
        return
    end
    local current = _currentVersion()
    local release = _doFetch()
    if release and not release.error then
        _showUpdateDialog(release, current, true)
    end
end

return M
