--[[
Application shell: device, screen, settings, refreshing, sleep.
Built on Tome's runtime (core/): the same screen, touch, HTTP and power
handling, with a dashboard instead of a library.
--]]
local UI = require("core.ui.manager")
local W = require("core.ui.widgets")
local Http = require("core.http")
local Font = require("core.font")
local util = require("core.util")
local log = require("core.log")
local Clock = require("daily.clock")
local Data = require("daily.data")
local Weather = require("daily.weather")

local App = {}
App.__index = App

function App.new(opts)
    local self = setmetatable({}, App)
    self.root = opts.root or "."
    self.home_dir = opts.home or self.root
    local v = util.read_file(self.root .. "/VERSION")
    self.version = v and util.trim(v) or "dev"
    self.config = opts.config or {}
    local cfg = self.config
    Font.set_dir(self.root .. "/fonts")

    local kind = opts.device or cfg.device
    if not kind then kind = require("core.device.kindle").detect() and "kindle" or "emulator" end
    if kind == "kindle" then
        local kc = cfg.kindle or {}
        if kc.flash_every == nil then kc.flash_every = 20 end -- a dashboard redraws often: flash less
        self.device = require("core.device.kindle").new(kc)
    else
        self.device = require("core.device.emulator").new(cfg.emulator or {})
    end
    self.data_dir = cfg.data_dir or (self.root .. "/data")
    util.mkdir_p(self.data_dir)
    self.settings_path = self.data_dir .. "/settings.lua"
    self.settings = util.load_table(self.settings_path) or {}
    local now_fn = opts.now_fn
    if cfg.fake_now then now_fn = function() return cfg.fake_now end end -- screenshots and tests
    self.clock = Clock.new(cfg.utc_offset_minutes or 330, now_fn)
    self.ui = UI.new(self.device)
    if self.settings.rotation and self.settings.rotation ~= 0 then self.ui:set_rotation(self.settings.rotation) end
    self.http = Http.new({ curl = cfg.curl, ca_bundle = cfg.ca_bundle, tmp_dir = cfg.tmp_dir or "/tmp",
        user_agent = "Daily/" .. self.version })
    self.data = Data.new(self)
    self:_setup_power()
    return self
end

function App:save_settings() util.save_table(self.settings_path, self.settings) end

function App:city()
    local name = self.settings.city or self.config.city or "Delhi"
    if type(self.config.city) == "table" and not self.settings.city then return self.config.city end
    for _, c in ipairs(Weather.CITIES) do if c.name == name then return c end end
    return Weather.CITIES[1]
end

------------------------------------------------------------------------------
-- Screens
------------------------------------------------------------------------------

function App:open_story(cat_index, story_index)
    local cat = self.data.brief and self.data.brief.categories[cat_index]
    if not (cat and cat.stories and cat.stories[story_index]) then return end
    self.ui:show(require("daily.article").new(self, cat, story_index))
end

function App:show_text(title, text)
    return self.ui:show(W.TextViewer.new({ title = title, text = text }))
end

function App:markets_text()
    local mk = self.data.brief and self.data.brief.markets
    if not mk then return "No market data in today's edition." end
    local function line(q)
        local arrow = (q.change_pct or 0) >= 0 and "\226\150\178" or "\226\150\188"
        local price = string.format("%.2f", q.price)
        local int, frac = price:match("^(%d+)(%.%d+)$")
        if int then price = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "") .. frac end
        return string.format("- **%s** %s  %s %.2f%%", q.name, price, arrow, math.abs(q.change_pct or 0))
    end
    local out = { "## Indices" }
    for _, q in ipairs(mk.indices or {}) do out[#out + 1] = line(q) end
    if mk.gainers and #mk.gainers > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "## Top gainers (Nifty 50)"
        for _, q in ipairs(mk.gainers) do out[#out + 1] = line(q) end
    end
    if mk.losers and #mk.losers > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "## Top losers (Nifty 50)"
        for _, q in ipairs(mk.losers) do out[#out + 1] = line(q) end
    end
    out[#out + 1] = ""
    if mk.as_of then
        out[#out + 1] = "Prices at the close of " .. self.clock:weekday(mk.as_of) .. ", "
            .. self.clock:day_month(mk.as_of) .. ". Data: Yahoo Finance."
    end
    return table.concat(out, "\n")
end

function App:show_markets() self:show_text("Markets", self:markets_text()) end

function App:show_weather()
    self:show_text("Weather", Weather.details(self.data.weather, self:city().name))
end

function App:show_menu()
    local items = {
        { text = "Refresh now", callback = function() self:refresh(true) end },
        { text = function() return "City: " .. self:city().name end, callback = function() self:choose_city() end },
        { text = function()
            return "Article text: " .. ({ s = "Small", m = "Medium", l = "Large" })[self.settings.article_size or "m"]
        end, callback = function() self:choose_text_size() end },
        { text = function()
            local m = self:sleep_minutes()
            return "Auto sleep: " .. (m > 0 and (m .. " minutes") or "never")
        end, callback = function() self:choose_sleep() end },
        { text = "About", callback = function() self:show_about() end },
        { text = "Exit to Kindle", callback = function() self:quit() end },
    }
    self.ui:show(W.Menu.new({ title = "Daily", items = items }))
end

function App:choose(title, items, on_choose)
    local view
    local rows = {}
    for _, it in ipairs(items) do
        rows[#rows + 1] = { text = it.text, marked = it.marked, callback = function()
            self.ui:close(view)
            on_choose(it.value)
        end }
    end
    view = self.ui:show(W.ListView.new({ title = title, items = rows }))
end

function App:choose_city()
    local items = {}
    for _, c in ipairs(Weather.CITIES) do items[#items + 1] = { text = c.name, value = c.name, marked = c.name == self:city().name } end
    self:choose("City for weather", items, function(name)
        self.settings.city = name
        self:save_settings()
        self.data.weather_at = nil
        self:refresh(false)
    end)
end

function App:choose_text_size()
    local items = { { text = "Small", value = "s" }, { text = "Medium", value = "m" }, { text = "Large", value = "l" } }
    self:choose("Article text", items, function(v) self.settings.article_size = v; self:save_settings() end)
end

function App:sleep_minutes()
    return self.settings.sleep_after_minutes or self.config.sleep_after_minutes or 10
end

function App:choose_sleep()
    local items = {}
    for _, m in ipairs({ 5, 10, 15, 30, 60 }) do items[#items + 1] = { text = m .. " minutes", value = m } end
    items[#items + 1] = { text = "Never (keep the screen on)", value = 0 }
    self:choose("Auto sleep", items, function(m) self.settings.sleep_after_minutes = m; self:save_settings() end)
end

function App:show_about()
    local b = self.data.brief
    self:show_text("About", table.concat({
        "## Daily " .. self.version,
        "A morning dashboard for your Kindle: news, markets and weather.",
        "",
        "News: " .. self.data:base_url() .. "brief.json",
        "Edition: " .. (b and (b.date .. ", built " .. (b.generated_at or "?")) or "none yet"),
        "Weather: Open-Meteo.com, for " .. self:city().name,
        "",
        "Built on Tome's runtime (MIT licence).",
    }, "\n"))
end

------------------------------------------------------------------------------
-- Refreshing
------------------------------------------------------------------------------

--- Fetch news and weather in the background. force: ignore the caches.
function App:refresh(force)
    if self.data.refreshing then return end
    self.data.refreshing = true
    self.ui:set_dirty("partial")
    self.ui:spawn(function()
        local r = self.data:refresh(force)
        if r.brief == "updated" then self.ui:set_dirty("full") else self.ui:set_dirty("partial") end
    end, function(err)
        self.data.refreshing = false
        self.data.last_error = tostring(err)
        log.error("refresh failed:", err)
        self.ui:set_dirty("partial")
    end)
end

--- Every minute: redraw the clock; every 30 minutes: refresh.
function App:_tick()
    local now = self.clock:now()
    local secs = now % 60
    self.ui:schedule((60 - secs) * 1000 + 200, function() self:_tick() end, true)
    if self.ui.sleeping then return end
    if self.ui:top() == self.dashboard then self.ui:set_dirty("partial") end
    if not self.data.refreshing and (not self.data.last_attempt or now - self.data.last_attempt >= 30 * 60) then
        self:refresh(false)
    end
end

------------------------------------------------------------------------------
-- Sleep: today's dashboard stays on the screen while the Kindle sleeps
------------------------------------------------------------------------------

function App:draw_sleep_screen()
    local d = self.device
    local Canvas = require("core.canvas")
    local c = Canvas.new(d.phys_w or d.width, d.phys_h or d.height)
    local dash = require("daily.dashboard").new(self)
    dash.ui = self.ui
    dash.sleep_mode = true
    dash:draw(c)
    d:show_physical(c)
end

function App:on_sleep()
    if self.ui.sleeping then return end
    self.ui.sleeping = true
    log.info("going to sleep")
    if self.device.special_offers then
        if os.getenv("AWESOME_STOPPED") == "yes" then os.execute("killall -CONT awesome") end
        return
    end
    local ok, err = pcall(self.draw_sleep_screen, self)
    if not ok then log.error("sleep screen failed:", err) end
end

function App:on_wake()
    if not self.ui.sleeping then return end
    self.ui.sleeping = false
    self.device:prevent_sleep(true)
    self.ui.last_input_ms = self.device:monotonic_ms()
    if self.device.special_offers and os.getenv("AWESOME_STOPPED") == "yes" then
        os.execute("killall -STOP awesome")
        self.ui:schedule(2500, function() self.ui:set_dirty("full") end)
    end
    self.ui:set_dirty("full")
    -- back from sleep: news and weather are probably stale
    if not self.data.last_attempt or self.clock:now() - self.data.last_attempt > 10 * 60 then
        self:refresh(false)
    end
end

function App:_setup_power()
    local ui, d = self.ui, self.device
    ui.power_handler = function(ev)
        if ev.event == "sleep" then self:on_sleep()
        elseif ev.event == "wake" then self:on_wake()
        elseif ev.event == "button" and not ui.sleeping then
            ui:schedule(1500, function()
                if not ui.sleeping and d.suspend then d:suspend() end
            end)
        end
    end
    ui.last_input_ms = d:monotonic_ms()
    ui.idle_check = function()
        local minutes = self:sleep_minutes()
        if minutes <= 0 or ui.sleeping or #ui.tasks > 0 then return end
        local now = d:monotonic_ms()
        if now - ui.last_input_ms > minutes * 60000 then
            ui.last_input_ms = now
            log.info("idle for", minutes, "minutes: suspending")
            if d.suspend then d:suspend() end
        end
    end
end

function App:quit(exit_code)
    self.exit_code = exit_code
    self.ui:quit()
end

function App:run()
    self.device:prevent_sleep(true)
    self.dashboard = self.ui:show(require("daily.dashboard").new(self))
    self:refresh(false)
    self:_tick()
    local ok, err = xpcall(function() self.ui:run() end, debug.traceback)
    if not ok then log.error("fatal:", err) end
    self:save_settings()
    self.device:close()
    return ok
end

return App
