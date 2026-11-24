--[[
Everything the dashboard shows, cached on the Kindle so it works offline:

  data/brief.json    today's news edition (from the morning job's site)
  data/weather.lua   weather + air quality, with the time it was fetched
  data/state.lua     when things were last checked

refresh() runs inside a UI task: HTTP calls yield, so the screen stays live.
--]]
local util = require("core.util")
local json = require("core.json")
local log = require("core.log")
local UI = require("core.ui.manager")
local Weather = require("daily.weather")

local Data = {}
Data.__index = Data

--- json.null -> nil in objects, false in arrays (keeps ipairs working).
local function strip_nulls(v)
    if type(v) ~= "table" then return v end
    local n = #v
    for k, x in pairs(v) do
        if x == json.null then
            if type(k) == "number" and k <= n then v[k] = false else v[k] = nil end
        else
            strip_nulls(x)
        end
    end
    return v
end
Data.strip_nulls = strip_nulls

local WEATHER_MAX_AGE = 30 * 60   -- seconds
local BRIEF_CHECK_EVERY = 30 * 60

function Data.new(app)
    local self = setmetatable({ app = app }, Data)
    self.dir = app.data_dir
    self.brief_path = self.dir .. "/brief.json"
    self.weather_path = self.dir .. "/weather.lua"
    self.state_path = self.dir .. "/state.lua"
    self.state = util.load_table(self.state_path) or {}
    self.last_ok = self.state.last_ok
    self.brief = self:_load_brief()
    local w = util.load_table(self.weather_path)
    if w and w.data then self.weather, self.weather_at = w.data, w.at end
    return self
end

function Data:_load_brief()
    local raw = util.read_file(self.brief_path)
    if not raw then return nil end
    local ok, b = pcall(json.decode, raw)
    if ok and type(b) == "table" and type(b.categories) == "table" then return strip_nulls(b) end
    log.warn("cached brief is unreadable; ignoring it")
end

function Data:_save_state() util.save_table(self.state_path, self.state) end

function Data:base_url()
    local u = self.app.config.brief_url or "https://vimalnaugain.github.io/kindle-daily/"
    return u:sub(-1) == "/" and u or u .. "/"
end

--- GET returning decoded JSON, or nil + error.
function Data:_get_json(url, timeout)
    local res, err = self.app.http:request({ url = url, method = "GET", timeout = timeout or 30 })
    if not res then return nil, err end
    if res.status ~= 200 and res.status ~= 0 then return nil, "HTTP " .. res.status end
    local ok, j = pcall(json.decode, res.body)
    if not ok or type(j) ~= "table" then return nil, "bad JSON" end
    return strip_nulls(j), nil, res.body
end

--- New edition? Checks the small index.json first, downloads brief.json only
-- when its version changed. Returns "updated" | "unchanged" | nil, err
function Data:refresh_brief(force)
    local now = self.app.clock:now()
    if not force and self.state.brief_checked and now - self.state.brief_checked < BRIEF_CHECK_EVERY
        and self.brief and self.brief.date == self.app.clock:date_key() then
        return "unchanged"
    end
    local base = self:base_url()
    local index, err = self:_get_json(base .. "index.json", 30)
    if not index then return nil, err end
    self.state.brief_checked = now
    self:_save_state()
    if self.brief and index.version and index.version == self.brief.version then return "unchanged" end
    local brief, err2, raw = self:_get_json(base .. "brief.json", 90)
    if not brief then return nil, err2 end
    if type(brief.categories) ~= "table" then return nil, "unexpected brief format" end
    util.write_file(self.brief_path .. ".tmp", raw)
    os.rename(self.brief_path .. ".tmp", self.brief_path)
    self.brief = brief
    log.info("new edition", brief.date, brief.version)
    return "updated"
end

function Data:weather_stale()
    return not self.weather_at or self.app.clock:now() - self.weather_at > WEATHER_MAX_AGE
end

function Data:refresh_weather(force)
    if not force and not self:weather_stale() then return "unchanged" end
    local city = self.app:city()
    local cfg = self.app.config
    local f_url, a_url = Weather.urls(city, cfg.timezone or "Asia/Kolkata")
    f_url, a_url = cfg.weather_url or f_url, cfg.air_quality_url or a_url -- tests point these at files
    local forecast, err = self:_get_json(f_url, 30)
    if not forecast then return nil, err end
    local air = self:_get_json(a_url, 30) -- optional
    local w = Weather.summarize(forecast, air, self.app.clock)
    if not w then return nil, "unexpected weather format" end
    w.city = city.name
    self.weather, self.weather_at = w, self.app.clock:now()
    util.save_table(self.weather_path, { data = w, at = self.weather_at })
    return "updated"
end

local function is_network_error(err)
    return type(err) == "string" and (err:find("network error", 1, true) or err:find("curl exit", 1, true)) ~= nil
end

--- Refresh news and weather. Turns Wi-Fi on and retries once if the first
-- attempt fails for lack of a network. Returns a short status string.
function Data:refresh(force)
    self.refreshing = true
    local results = {}
    local function run()
        local b, berr = self:refresh_brief(force)
        local w, werr = self:refresh_weather(force)
        results = { brief = b, brief_err = berr, weather = w, weather_err = werr }
        return (b or w) ~= nil, berr or werr
    end
    local any, err = run()
    if not any and is_network_error(err) and self.app.device.is_kindle then
        log.info("offline: turning Wi-Fi on and retrying")
        self.app.device:wifi_enable()
        local t0 = self.app.device:monotonic_ms()
        UI.await(function() return self.app.device:monotonic_ms() - t0 > 15000 end)
        any, err = run()
    end
    self.refreshing = false
    self.last_attempt = self.app.clock:now()
    if any then
        self.last_ok = self.last_attempt
        self.state.last_ok = self.last_ok
        self:_save_state()
        self.last_error = (results.brief_err or results.weather_err)
    else
        self.last_error = err
    end
    if results.brief_err then log.warn("brief:", results.brief_err) end
    if results.weather_err then log.warn("weather:", results.weather_err) end
    return results
end

return Data
