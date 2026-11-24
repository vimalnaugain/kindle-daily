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
local Todo = require("daily.todo")

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
    self.todo = Todo.new(self.data_dir .. "/todo.lua", self.clock)
    if type(cfg.telegram_token) == "string" and cfg.telegram_token:match("^%d+:[%w_-]+$") then
        self.telegram = require("daily.telegram").new(self, cfg.telegram_token)
    end
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

------------------------------------------------------------------------------
-- Reading: long reads, news, quote
------------------------------------------------------------------------------

function App:open_read(index)
    local list = self.data:unread()
    if not list[index] then return end
    self.ui:show(require("daily.article").new(self, { title = "Long reads", stories = list }, index, { reads = true }))
end

--- Every long read in the pool: unread first. Tap to read, hold to mark read / unread.
function App:show_reads()
    local view
    local function build()
        local list, rows = {}, {}
        for _, r in ipairs(self.data:unread()) do list[#list + 1] = r end
        for _, r in ipairs(self.data.brief and self.data.brief.reads or {}) do
            if self.data:is_read(r) then list[#list + 1] = r end
        end
        for i, r in ipairs(list) do
            local read = self.data:is_read(r)
            rows[#rows + 1] = {
                text = (read and "\u{2713} " or "") .. r.title,
                subtext = string.format("%s \u{00B7} %d min%s", r.source, r.minutes or 0, read and " \u{00B7} read" or ""),
                callback = function()
                    self.ui:show(require("daily.article").new(self, { title = "Long reads", stories = list }, i, { reads = true }))
                end,
                hold_callback = function() self.data:set_read(r, not read); view:set_items(build()) end,
            }
        end
        if #rows == 0 then rows[1] = { text = "No long reads yet. They arrive with the morning edition.", callback = function() end } end
        return rows
    end
    view = self.ui:show(W.ListView.new({ title = "Long reads  (hold: mark read)", items = build() }))
    view.on_show_again = function() view:set_items(build()) end
    view.on_close = function() self.ui:set_dirty("full") end
end

function App:open_news(index)
    local list = self.data:news()
    if not list[index] then return end
    self.ui:show(require("daily.article").new(self, { title = "News", stories = list }, index))
end

function App:show_news()
    local list = self.data:news()
    local rows = {}
    for i, s in ipairs(list) do
        rows[#rows + 1] = { text = s.title,
            subtext = string.format("%s \u{00B7} %s%s", s.topic or "", s.source or "",
                (s.has_text and (s.minutes or 0) > 0) and (" \u{00B7} " .. s.minutes .. " min") or ""),
            callback = function() self:open_news(i) end }
    end
    if #rows == 0 then rows[1] = { text = "Pick news topics first: Menu > News topics.", callback = function() self:choose_topics() end } end
    self.ui:show(W.ListView.new({ title = string.format("News (%d)", #list), items = rows }))
end

--- Pick news topics: tap to switch each on or off.
function App:choose_topics()
    local cats = self.data.brief and self.data.brief.categories or {}
    if #cats == 0 then
        self:notify("Topics appear once the first edition has downloaded.", 3000)
        return
    end
    local view
    local function picked()
        local set = {}
        for _, id in ipairs(self.settings.topics or {}) do set[id] = true end
        return set
    end
    local function build()
        local set, rows = picked(), {}
        for _, c in ipairs(cats) do
            rows[#rows + 1] = { text = (set[c.id] and "\u{2611}  " or "\u{2610}  ") .. c.title,
                subtext = string.format("%d stories today", #(c.stories or {})),
                callback = function()
                    local s2 = picked()
                    s2[c.id] = not s2[c.id] or nil
                    local list = {}
                    for _, cc in ipairs(cats) do if s2[cc.id] then list[#list + 1] = cc.id end end
                    self.settings.topics = list
                    self:save_settings()
                    view:set_items(build())
                end }
        end
        return rows
    end
    view = self.ui:show(W.ListView.new({ title = "News topics  (tap to pick)", items = build() }))
    view.on_close = function()
        self.ui:set_dirty("full")
        -- download the texts of newly picked topics
        self.ui:spawn(function() self.data:fetch_texts(); self.ui:set_dirty("partial") end)
    end
end

function App:show_quote()
    local q = self.data.brief and self.data.brief.quote
    if not q then return end
    self:show_text("Quote of the day", string.format("%s\n\n**\u{2014} %s**, %s\n\n*From Project Gutenberg's free library: %s*",
        q.text, q.book, q.author, q.url or ""))
end

function App:open_article_of_the_day()
    local a = self.data.brief and self.data.brief.article
    if not a then return end
    local cat = { title = "Article of the day", stories = { a } }
    self.ui:show(require("daily.article").new(self, cat, 1))
end

--- Full to-do list: tap to tick off, long-press to delete.
function App:show_todo()
    local view
    local build
    local function delete(it)
        self:confirm({ title = "Delete?", text = it.text, ok_text = "Delete", on_ok = function()
            self.todo:remove(it); view:set_items(build())
        end })
    end
    build = function()
        local rows = { { text = "+  Add a to-do", bold = true, callback = function()
            self:add_todo(function() view:set_items(build()) end)
        end } }
        for _, it in ipairs(self.todo:open()) do
            rows[#rows + 1] = { text = "\u{2610}  " .. it.text, subtext = self.todo:due_label(it),
                callback = function() self.todo:set_done(it, true); view:set_items(build()) end,
                hold_callback = function() delete(it) end }
        end
        local done = self.todo:recently_done()
        for _, it in ipairs(done) do
            rows[#rows + 1] = { text = "\u{2611}  " .. it.text, subtext = "done \u{00B7} tap to undo",
                callback = function() self.todo:set_done(it, false); view:set_items(build()) end,
                hold_callback = function() delete(it) end }
        end
        if #done > 0 then
            rows[#rows + 1] = { text = "Clear ticked-off items", callback = function()
                for _, it in ipairs(done) do self.todo:remove(it) end
                view:set_items(build())
            end }
        end
        if #rows == 1 then
            rows[2] = { text = self.telegram and "Nothing to do. Add one here or message your bot."
                or "Nothing to do. Add one here (or set up Telegram in config.lua).", callback = function() end }
        end
        return rows
    end
    view = self.ui:show(W.ListView.new({ title = "To-do  (tap: tick off, hold: delete)", items = build() }))
    view.on_close = function() if self.dashboard then self.ui:set_dirty("full") end end
end

function App:agenda_text()
    if not self.data.calendar_configured then
        return "## Google Calendar\n\nIn Google Calendar on a computer: Settings > your calendar > "
            .. "**Secret address in iCal format**. Copy it into /mnt/us/daily/config.lua:\n\n"
            .. "calendar_url = \"https://calendar.google.com/calendar/ical/…/basic.ics\""
    end
    local out, last_day = {}, nil
    local now = self.clock:now()
    for _, o in ipairs(self.data.calendar or {}) do
        if o.finish > now or (o.all_day and self.clock:day(o.start) >= self.clock:day()) then
            local d = self.clock:day(o.start)
            if d ~= last_day then
                if #out > 40 then break end
                local t = self.clock:day_start(d) + 43200
                local label = d == self.clock:day() and "Today" or (d == self.clock:day() + 1 and "Tomorrow")
                    or (self.clock:weekday(t) .. ", " .. self.clock:day_month(t))
                out[#out + 1] = "## " .. label
                last_day = d
            end
            local when = "All day"
            if not o.all_day then
                local a, ap = self.clock:hm12(o.start)
                local b, bp = self.clock:hm12(o.finish)
                when = a .. (ap ~= bp and (" " .. ap) or "") .. " \u{2013} " .. b .. " " .. bp
            end
            out[#out + 1] = "- **" .. when .. "**  " .. o.title
        end
    end
    if #out == 0 then return "Nothing in the next six weeks." end
    return table.concat(out, "\n")
end

function App:show_agenda() self:show_text("Calendar", self:agenda_text()) end

------------------------------------------------------------------------------
-- Telegram
------------------------------------------------------------------------------

--- Inside a task: fetch and apply new Telegram messages.
function App:poll_telegram_now()
    if not self.telegram or self.telegram_busy then return 0 end
    self.telegram_busy = true
    local n, err = self.telegram:poll()
    self.telegram_busy = false
    if n and n > 0 then self.ui:set_dirty("partial") end
    local p = self.telegram.pending
    if p and not self.pairing_shown then
        self.pairing_shown = true
        self.ui:show(W.Dialog.new({ title = "Pair with Telegram?",
            text = string.format("%s messaged your bot: \"%s\"\n\nPair this chat? Only it will be able to change your to-do list.",
                p.name, p.text:sub(1, 60)),
            buttons = {
                { text = "Not now", callback = function() self.telegram.pending = nil; self.pairing_shown = false end },
                { text = "Pair", primary = true, callback = function()
                    self.telegram.pending = nil
                    self.pairing_shown = false
                    self.ui:spawn(function() self.telegram:pair(p); self.ui:set_dirty("partial") end)
                end },
            } }))
    end
    return n, err
end

function App:poll_telegram()
    if not self.telegram or self.data.refreshing then return end
    self.ui:spawn(function() self:poll_telegram_now() end, function(err) log.warn("telegram:", err) end)
end

function App:show_weather()
    self:show_text("Weather", Weather.details(self.data.weather, self:city().name))
end

function App:show_menu()
    local items = {
        { text = "Refresh now", callback = function() self:refresh(true) end },
        { text = "Add a to-do", callback = function() self:add_todo() end },
        { text = function()
            local n = #(self.settings.topics or {})
            return "News topics" .. (n > 0 and (" (" .. n .. " picked)") or " (none)")
        end, callback = function() self:choose_topics() end },
        { text = "All long reads", callback = function() self:show_reads() end },
        { text = function() return "City: " .. self:city().name end, callback = function() self:choose_city() end },
        { text = function()
            return "Article text: " .. ({ s = "Small", m = "Medium", l = "Large" })[self.settings.article_size or "m"]
        end, callback = function() self:choose_text_size() end },
        { text = function()
            local m = self:sleep_minutes()
            return "Auto sleep: " .. (m > 0 and (m .. " minutes") or "never")
        end, callback = function() self:choose_sleep() end },
        { text = function()
            local p = require("daily.updater").pending(self)
            return p and ("Install update " .. p .. " (restart)") or ("Check for updates (" .. self.version .. ")")
        end, callback = function()
            if require("daily.updater").pending(self) then self:quit(85) else require("daily.updater").run(self) end
        end },
        { text = "About", callback = function() self:show_about() end },
        { text = "Exit to Kindle", callback = function() self:quit() end },
    }
    self.ui:show(W.Menu.new({ title = "Daily", items = items }))
end

-- The small dialog API the updater (from Tome) uses.
function App:notify(text, ms)
    return self.ui:show(W.Dialog.new({ text = text, timeout_ms = ms or 2500 }))
end

function App:confirm(opts)
    return self.ui:show(W.Dialog.new({ title = opts.title, text = opts.text, buttons = {
        { text = opts.cancel_text or "Cancel", callback = opts.on_cancel },
        { text = opts.ok_text or "OK", primary = true, callback = opts.on_ok },
    } }))
end

function App:show_progress(opts)
    local dlg = W.Dialog.new({ title = opts.title, text = opts.text or "Working\u{2026}", dismissable = false,
        buttons = { { text = "Cancel", callback = function() if opts.on_cancel then opts.on_cancel() end end } } })
    self.ui:show(dlg)
    return { set_text = function(_, t) dlg:set_text(t) end, close = function() self.ui:close(dlg) end }
end

function App:run_task(fn, on_error) return self.ui:spawn(fn, on_error) end

--- Once a day: look for a new version, download it in the background, then
-- offer to restart. Declined updates install the next time Daily starts.
-- Inside a task.
function App:auto_update()
    if self.config.auto_update == false or self.version == "dev" then return end
    local Updater = require("daily.updater")
    local state, now = self.data.state, self.clock:now()
    if Updater.pending(self) then return end
    if state.update_checked and now - state.update_checked < 20 * 3600 then return end
    local info = Updater.check(self)
    state.update_checked = now
    self.data:_save_state()
    if not info or not Updater.newer(info.version, self.version) then return end
    log.info("update", info.version, "available: downloading")
    local path, err = Updater.download(self, info)
    if not path then log.warn("update download failed:", err); return end
    state.update_ready = info.version
    self.data:_save_state()
    self.ui:show(W.Dialog.new({ title = "Update ready",
        text = string.format("Daily %s is downloaded (you have %s). Restart now to install it?\n\n"
            .. "If you choose Later, it installs the next time you open Daily.", info.version, self.version),
        buttons = {
            { text = "Later" },
            { text = "Restart", primary = true, callback = function() self:quit(85) end },
        } }))
end

------------------------------------------------------------------------------
-- To-do on the Kindle
------------------------------------------------------------------------------

function App:add_todo(after)
    local Keyboard = require("core.ui.keyboard")
    self.ui:show(Keyboard.new({
        title = "Add to-do", ok_text = "Add", hint = "e.g. buy milk, call bank tomorrow",
        chips = { { text = "Today", insert = "today" }, { text = "Tomorrow", insert = "tomorrow" } },
        on_done = function(text)
            local what, due = self.todo:split_due(text)
            self.todo:add(what, due)
            self.ui:set_dirty("full")
            if after then after() end
        end,
    }))
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
        if self.data.last_ok == self.data.last_attempt then self:auto_update() end
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
    elseif self.telegram and math.floor(now / 60) % 2 == 0 then
        self:poll_telegram() -- to-dos from your phone, every 2 minutes
    end
    if math.floor(now / 60) % 60 == 0 then self.todo:tidy() end
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
