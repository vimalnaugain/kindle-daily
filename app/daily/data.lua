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
local Cal = require("daily.calendar")

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
    util.mkdir_p(self.dir .. "/news")
    util.mkdir_p(self.dir .. "/reads")
    self.read_path = self.dir .. "/read.lua"
    self.read = util.load_table(self.read_path) or {} -- long reads you've marked read: id -> time
    self.calendar_path = self.dir .. "/calendar.lua"
    self.calendar_configured = #self:calendar_urls() > 0
    local cal = util.load_table(self.calendar_path)
    if cal and self.calendar_configured then self.calendar, self.calendar_at = cal.events, cal.at end
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

------------------------------------------------------------------------------
-- Full texts: news for the topics you picked, long reads you haven't read
------------------------------------------------------------------------------

--- Topics you picked (Menu > News topics), in the edition's order.
function Data:topics()
    local picked = {}
    for _, id in ipairs(self.app.settings.topics or {}) do picked[id] = true end
    local out = {}
    for _, c in ipairs(self.brief and self.brief.categories or {}) do
        if picked[c.id] then out[#out + 1] = c end
    end
    return out
end

--- Stories of the picked topics, without repeats, best first per topic.
function Data:news()
    local out, seen = {}, {}
    for _, c in ipairs(self:topics()) do
        for _, s in ipairs(c.stories or {}) do
            local key = s.id or s.url
            if not seen[key] then
                seen[key] = true
                s.topic = c.short or c.title
                s.topic_id = c.id
                out[#out + 1] = s
            end
        end
    end
    return out
end

function Data:_news_path(cat_id) return self.dir .. "/news/" .. cat_id .. ".json" end
function Data:_read_path(id) return self.dir .. "/reads/" .. id .. ".json" end

--- The full text of a story or long read, from the cache (nil if not downloaded).
function Data:text_of(item)
    if not item then return nil end
    if item.text then return item.text end
    if item.topic_id then
        local cache = self.news_cache or {}
        self.news_cache = cache
        local c = cache[item.topic_id]
        if not c then
            local raw = util.read_file(self:_news_path(item.topic_id))
            local ok, j = pcall(json.decode, raw or "")
            c = ok and type(j) == "table" and j.texts or {}
            cache[item.topic_id] = c
        end
        return type(c[item.id]) == "string" and c[item.id] or nil
    end
    local raw = util.read_file(self:_read_path(item.id))
    local ok, j = pcall(json.decode, raw or "")
    return ok and type(j) == "table" and type(j.text) == "string" and j.text or nil
end

function Data:is_read(r) return self.read[r.id] ~= nil end

function Data:set_read(r, read)
    self.read[r.id] = read and self.app.clock:now() or nil
    util.save_table(self.read_path, self.read)
end

--- Long reads you haven't read, newest first; and how many you have.
function Data:unread()
    local out = {}
    for _, r in ipairs(self.brief and self.brief.reads or {}) do
        if not self:is_read(r) then out[#out + 1] = r end
    end
    return out
end

--- Download the texts we don't have yet: picked topics (when the edition or
-- the topics changed) and unread long reads. Inside a task.
function Data:fetch_texts()
    if not self.brief then return end
    local base = self:base_url()
    local version = self.brief.version or ""
    self.state.news_texts = self.state.news_texts or {}
    for _, c in ipairs(self:topics()) do
        if self.state.news_texts[c.id] ~= version or not util.file_exists(self:_news_path(c.id)) then
            local _, err, raw = self:_get_json(base .. "news/" .. c.id .. ".json", 90)
            if raw then
                util.write_file(self:_news_path(c.id), raw)
                self.state.news_texts[c.id] = version
                if self.news_cache then self.news_cache[c.id] = nil end
            else
                log.warn("news texts", c.id, err)
            end
        end
    end
    local keep = {}
    for _, r in ipairs(self.brief.reads or {}) do keep[r.id .. ".json"] = true end
    for _, r in ipairs(self:unread()) do
        if not util.file_exists(self:_read_path(r.id)) then
            local _, err, raw = self:_get_json(base .. "reads/" .. r.id .. ".json", 90)
            if raw then util.write_file(self:_read_path(r.id), raw) else log.warn("read text", r.id, err) end
        end
    end
    -- forget texts that left the pool, and read-marks for them
    for _, e in ipairs(util.list_dir(self.dir .. "/reads")) do
        if not keep[e.name] then os.remove(self.dir .. "/reads/" .. e.name) end
    end
    local still = {}
    for _, r in ipairs(self.brief.reads or {}) do still[r.id] = true end
    local changed = false
    for id in pairs(self.read) do if not still[id] then self.read[id] = nil; changed = true end end
    if changed then util.save_table(self.read_path, self.read) end
    self:_save_state()
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

function Data:calendar_urls()
    local c = self.app.config.calendar_urls or self.app.config.calendar_url
    if type(c) == "string" then c = { c } end
    local out = {}
    for _, u in ipairs(c or {}) do
        if type(u) == "string" and u ~= "" then out[#out + 1] = (u:gsub("^webcal://", "https://")) end
    end
    return out
end

--- Download the calendars (hourly) and work out the next six weeks' events.
function Data:refresh_calendar(force)
    local urls = self:calendar_urls()
    if #urls == 0 then return "unchanged" end
    local clock = self.app.clock
    if not force and self.calendar_at and clock:now() - self.calendar_at < 3600
        and clock:day(self.calendar_at) == clock:day() then
        return "unchanged"
    end
    local today = clock:day()
    local events = {}
    for _, url in ipairs(urls) do
        local res, err = self.app.http:request({ url = url, method = "GET", timeout = 90 })
        if not res then return nil, err end
        if res.status ~= 200 and res.status ~= 0 then return nil, "calendar: HTTP " .. res.status end
        if not res.body:find("BEGIN:VCALENDAR", 1, true) then return nil, "calendar: not an iCal file" end
        local parsed = Cal.parse(res.body, clock.offset)
        for _, o in ipairs(Cal.occurrences(parsed, clock, today - 1, today + 41)) do events[#events + 1] = o end
    end
    table.sort(events, function(a, b) return a.start < b.start end)
    self.calendar, self.calendar_at = events, clock:now()
    util.save_table(self.calendar_path, { events = events, at = self.calendar_at })
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
        local c, cerr = self:refresh_calendar(force)
        if b then self:fetch_texts() end
        results = { brief = b, brief_err = berr, weather = w, weather_err = werr, calendar = c, calendar_err = cerr }
        if self.app.telegram then
            local n, terr = self.app:poll_telegram_now()
            results.telegram, results.telegram_err = n, terr
        end
        return (b or w or c) ~= nil, berr or werr or cerr
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
    if results.calendar_err then log.warn("calendar:", results.calendar_err) end
    if results.telegram_err then log.warn("telegram:", results.telegram_err) end
    return results
end

return Data
