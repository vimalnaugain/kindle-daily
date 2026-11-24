--[[
Updates over Wi-Fi, ported from Tome. Reads app/latest.json from the Daily
site (version, file, sha256), downloads the package into <home>/update,
checks its SHA-256, then restarts Daily; the launcher installs it
(platform/kindle/daily.sh). A package left in <home>/update is installed the
next time Daily starts.

Automatic: once a day the app checks, downloads a newer version in the
background and offers to restart (App:auto_update).
--]]
local util = require("core.util")
local log = require("core.log")

local Updater = {}


local function parse_version(v)
    local a, b, c = tostring(v or ""):match("^(%d+)%.(%d+)%.(%d+)")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) }
end

--- true if version a is newer than b
function Updater.newer(a, b)
    local va, vb = parse_version(a), parse_version(b)
    if not va then return false end
    if not vb then return true end
    for i = 1, 3 do
        if va[i] ~= vb[i] then return va[i] > vb[i] end
    end
    return false
end

local function sha256(path)
    local p = io.popen("sha256sum " .. util.shell_quote(path) .. " 2>/dev/null")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    return out:match("^(%x+)")
end

--- Ask the update page what's new. Must run inside an app task.
-- Returns info {version, url, sha256, size} or nil, err
function Updater.check(app)
    local url = app.config.update_url or (app.data:base_url() .. "app/latest.json")
    local res, err = app.http:request({ url = url, method = "GET", timeout = 60 })
    if not res then return nil, err end
    local ok_status = res.status == 200 or (res.status == 0 and url:match("^file:")) -- tests use files
    if not ok_status or type(res.json) ~= "table" then
        return nil, string.format("Update page returned HTTP %d", res.status)
    end
    local info = res.json
    if not parse_version(info.version) or type(info.file) ~= "string" or type(info.sha256) ~= "string" then
        return nil, "Update page has unexpected content"
    end
    info.url = url:gsub("[^/]*$", "") .. info.file
    return info
end

--- Download and verify. Returns path or nil, err. Must run inside an app task.
function Updater.download(app, info)
    local dir = app.home_dir .. "/update"
    util.mkdir_p(dir)
    local part = dir .. "/download.part"
    os.remove(part)
    local res, err = app.http:request({ url = info.url, method = "GET", timeout = 900, output_file = part })
    if not res then os.remove(part); return nil, err end
    if res.status ~= 200 and not (res.status == 0 and info.url:match("^file:")) then
        os.remove(part); return nil, string.format("Download failed (HTTP %d)", res.status)
    end
    local got = sha256(part)
    if got and got:lower() ~= info.sha256:lower() then
        os.remove(part)
        return nil, "The download is damaged (checksum mismatch). Try again."
    end
    if not got then log.warn("updater: sha256sum not available; relying on HTTPS") end
    local final = dir .. "/daily-update.kpkg"
    os.remove(final)
    assert(os.rename(part, final))
    return final
end

--- Is an update already downloaded and waiting? -> version or nil
function Updater.pending(app)
    return util.file_exists(app.home_dir .. "/update/daily-update.kpkg") and (app.data.state.update_ready or "?") or nil
end

--- Menu flow: check, ask, download, restart.
function Updater.run(app)
    local progress
    local task
    progress = app:show_progress({ title = "Software update", text = "Checking for updates\226\128\166",
        on_cancel = function() if task then task.cancel() end end })
    task = app:run_task(function()
        local info, err = Updater.check(app)
        if not info then
            progress:close()
            if err ~= "cancelled" then app:notify("Couldn't check for updates:\n" .. tostring(err), 6000) end
            return
        end
        if not Updater.newer(info.version, app.version) then
            progress:close()
            app:notify("Daily is up to date (version " .. app.version .. ").", 4000)
            return
        end
        progress:close()
        app:confirm({ title = "Update available",
            text = string.format("Version %s is available (you have %s). Download it (%.1f MB) and restart Daily?",
                info.version, app.version, (info.size or 0) / 1048576),
            ok_text = "Update", on_ok = function()
                local p2
                local t2
                p2 = app:show_progress({ title = "Software update", text = "Downloading " .. info.version .. "\226\128\166",
                    on_cancel = function() if t2 then t2.cancel() end end })
                t2 = app:run_task(function()
                    local path, derr = Updater.download(app, info)
                    p2:close()
                    if not path then
                        if derr ~= "cancelled" then app:notify("Update failed:\n" .. tostring(derr), 6000) end
                        return
                    end
                    log.info("updater: downloaded", info.version, "- restarting")
                    app:notify("Installing the update. Daily will restart\226\128\166", 1500)
                    app.ui:schedule(1200, function() app:quit(85) end)
                end)
            end })
    end)
end

return Updater
