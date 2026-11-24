--[[
App tests (desktop LuaJIT, needs native/tomecore.so: `make -C native`).

    luajit tests/run_tests.lua

Uses tests/fixtures: a real edition from the morning job and Open-Meteo
shaped weather. The emulator screenshots go to tests/out/.
--]]
local root = arg[0]:match("^(.*)/tests/[^/]+$") or "."
if root:sub(1, 1) ~= "/" then -- absolute, for file:// URLs
    local p = io.popen("cd " .. root .. " && pwd")
    root = p:read("*l")
    p:close()
end
package.path = root .. "/?.lua;" .. package.path
package.cpath = root .. "/native/?.so;" .. package.cpath

local util = require("core.util")
local json = require("core.json")
local Font = require("core.font")
Font.set_dir(root .. "/fonts")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print("ok   " .. name)
    else failed = failed + 1; print("FAIL " .. name .. "\n" .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local FIX = root .. "/tests/fixtures"
-- 2026-11-24 14:12 IST
local NOW = 1795509720
local OUT = root .. "/tests/out"
util.mkdir_p(OUT)

local Clock = require("daily.clock")
local Weather = require("daily.weather")
local Data = require("daily.data")

test("clock: local time, dates, ISO parsing, 'ago'", function()
    local c = Clock.new(330, function() return NOW end)
    eq(c:hm(), "14:12")
    eq(c:date_key(), "2026-11-24")
    eq(c:weekday(), "Tuesday")
    eq(c:day_month(), "24 November")
    eq(c:parse_iso("2026-11-24T08:42:00Z"), NOW)
    eq(c:parse_iso("2026-11-24T14:12"), NOW, "local time without zone")
    eq(c:parse_iso("2026-11-24"), NOW - (14 * 3600 + 12 * 60), "local midnight")
    eq(c:ago(NOW - 30), "just now")
    eq(c:ago(NOW - 600), "10 min ago")
    eq(c:ago(NOW - 3 * 3600), "3 h ago")
    eq(c:hm(c:parse_iso("2026-03-01T00:30:00Z")), "06:00", "leap-year-safe date maths")
end)

test("weather: summary, nulls, AQI and next hours", function()
    local c = Clock.new(330, function() return NOW end)
    local f = Data.strip_nulls(json.decode(util.read_file(FIX .. "/forecast.json")))
    local a = Data.strip_nulls(json.decode(util.read_file(FIX .. "/air.json")))
    local w = Weather.summarize(f, a, c)
    eq(w.temp, 26); eq(w.feels, 25); eq(w.label, "Partly cloudy")
    eq(w.max, 27); eq(w.min, 12)
    eq(w.aqi, 212); eq(w.aqi_label, "Very unhealthy")
    eq(w.hours[1].hour, 14); eq(#w.hours, 6)
    eq(w.rain_from, 16)
    eq(w.days[2].rain, nil, "null in an array stays empty")
    assert(Weather.details(w, "Delhi"):find("AQI 212", 1, true))
    eq(Weather.summarize({}, nil, c), nil)
    eq(Weather.aqi_label(42), "Good")
end)

test("strip_nulls keeps arrays iterable", function()
    local t = Data.strip_nulls(json.decode('{"a":null,"b":[1,null,3],"c":{"d":null}}'))
    eq(t.a, nil); eq(#t.b, 3); eq(t.b[2], false); eq(t.c.d, nil)
end)

-- A whole app in the emulator, fed from fixture files.
local function make_home(name, extra)
    local home = OUT .. "/" .. name
    os.execute("rm -rf " .. home)
    util.mkdir_p(home .. "/data")
    local cfg = {
        brief_url = "file://" .. FIX .. "/site/",
        weather_url = "file://" .. FIX .. "/forecast.json",
        air_quality_url = "file://" .. FIX .. "/air.json",
        fake_now = NOW, sleep_after_minutes = 0,
        emulator = { out_dir = home .. "/shots" },
    }
    for k, v in pairs(extra or {}) do cfg[k] = v end
    util.save_table(home .. "/config.lua", cfg)
    return home
end

local function run_app(home, script)
    util.write_file(home .. "/script.txt", script)
    local cmd = string.format("cd %s && timeout 120 luajit main.lua --home %s --script %s/script.txt --out %s/shots 2>&1",
        root, home, home, home)
    local p = io.popen(cmd)
    local log = p:read("*a")
    p:close()
    return log
end

test("app: downloads the edition and weather, then works offline", function()
    local home = make_home("e2e")
    local log = run_app(home, "idle\nshot dashboard\ntap 536 560\nwait 100\nshot article\nkey next\nshot article2\nquit\n")
    assert(not log:find("ERROR", 1, true), log)
    assert(util.file_exists(home .. "/data/brief.json"), "edition cached")
    assert(util.file_exists(home .. "/data/weather.lua"), "weather cached")
    for _, s in ipairs({ "dashboard", "article", "article2" }) do
        assert(util.file_exists(home .. "/shots/" .. s .. ".png"), s)
    end
    -- offline: sources gone, the cache still shows the news
    local cfg = util.load_table(home .. "/config.lua")
    cfg.brief_url, cfg.weather_url = "file:///nonexistent/", "file:///nonexistent.json"
    util.save_table(home .. "/config.lua", cfg)
    log = run_app(home, "idle\nshot offline\nquit\n")
    assert(util.file_exists(home .. "/shots/offline.png"))
end)

test("app: menu, markets, weather and the sleep screen", function()
    local home = make_home("screens")
    local log = run_app(home, table.concat({
        "idle", "tap 500 340", "wait 100", "shot markets", "key back",
        "tap 900 200", "wait 100", "shot weather", "key back",
        "tap 90 1410", "wait 100", "shot menu", "key back",
        "sleep", "wait 200", "shot sleep", "quit" }, "\n") .. "\n")
    assert(not log:find("ERROR", 1, true), log)
    for _, s in ipairs({ "markets", "weather", "menu", "sleep" }) do
        assert(util.file_exists(home .. "/shots/" .. s .. ".png"), s)
    end
end)

test("dashboard cards fit every Kindle size and orientation", function()
    local App = require("daily.app")
    local Canvas = require("core.canvas")
    for _, size in ipairs({ { 600, 800, 167 }, { 758, 1024, 212 }, { 1072, 1448, 300 }, { 1236, 1648, 300 },
                            { 1264, 1680, 300 }, { 1448, 1072, 300 }, { 1024, 758, 212 } }) do
        local home = make_home("size", { emulator = { screen_width = size[1], screen_height = size[2], dpi = size[3] },
            calendar_url = "file://" .. FIX .. "/calendar.ics" })
        os.execute(string.format("cp %s/e2e/data/brief.json %s/e2e/data/weather.lua %s/data/ 2>/dev/null", OUT, OUT, home))
        local cfg = util.load_table(home .. "/config.lua")
        cfg.data_dir = home .. "/data"
        local app = App.new({ root = root, home = home, device = "emulator", config = cfg })
        app.data:refresh_calendar(true)
        for i = 1, 9 do app.todo:add("Item number " .. i .. " with a fairly long description") end
        local dash = require("daily.dashboard").new(app)
        dash.ui = app.ui
        local c = Canvas.new(size[1], size[2])
        dash:draw(c)
        local tag = size[1] .. "x" .. size[2]
        local names = {}
        for name, r in pairs(dash.cards) do
            if name ~= "footer" then
                names[#names + 1] = name
                assert(r.x >= 0 and r.y >= 0 and r.x + r.w <= size[1] and r.y + r.h <= size[2], name .. " inside at " .. tag)
            end
        end
        assert(#names == 7, "seven cards")
        for i = 1, #names do
            for j = i + 1, #names do
                local a, b = dash.cards[names[i]], dash.cards[names[j]]
                local overlap = a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
                assert(not overlap, names[i] .. " overlaps " .. names[j] .. " at " .. tag)
            end
        end
        assert(#dash.targets > 10, "tap targets at " .. tag)
        util.write_file(OUT .. "/size-" .. tag .. ".png", c:to_png())
        -- every story and the article of the day open and paginate
        local cat = app.data.brief.categories[1]
        for si = 1, #cat.stories do
            local art = require("daily.article").new(app, cat, si)
            art.ui = app.ui
            art:draw(c)
            assert(#art.pages >= 2, "article has pages")
        end
    end
end)

test("calendar: repeats, exceptions, moved and cancelled events, time zones", function()
    local Cal = require("daily.calendar")
    local c = Clock.new(330, function() return NOW end)
    local p = Cal.parse(util.read_file(FIX .. "/calendar.ics"), c.offset)
    local occ = Cal.occurrences(p, c, c:day(), c:day() + 20)
    local function find(title, day_offset)
        for _, o in ipairs(occ) do
            if o.title == title and c:day(o.start) == c:day() + day_offset then return o end
        end
    end
    eq(c:hm(find("Design review, Q4", 0).start), "16:30", "escaped comma, local TZID")
    eq(c:hm(find("Standup", 0).start), "09:00", "UTC time")
    eq(find("Standup", 2), nil, "EXDATE")
    eq(c:hm(find("Standup (moved)", 3).start), "09:30", "moved occurrence")
    eq(find("Standup", 3), nil, "original of the moved occurrence")
    eq(find("Standup", 4), nil, "no standup on Saturday")
    assert(find("Mom's birthday", 1).all_day, "yearly all-day")
    assert(find("Evening walk", 7), "daily since 2015")
    eq(c:day_month(find("Book club", 14).start), "8 December", "2nd Tuesday")
    eq(c:hm(find("Call with NY", 0).start), "19:30", "other time zone")
    for _, o in ipairs(occ) do assert(o.title ~= "Cancelled thing", "cancelled event shown") end
end)

test("to-do: commands, due days, undo", function()
    local c = Clock.new(330, function() return NOW end)
    local path = OUT .. "/todo-test.lua"
    os.remove(path)
    local t = require("daily.todo").new(path, c)
    eq(t:command("buy milk"), "Added: buy milk (1 open)")
    eq(t:command("add call bank tomorrow"), "Added: call bank, tomorrow (2 open)")
    eq(t:command("/todo renew passport fri"), "Added: renew passport, Fri 27 (3 open)")
    assert(t:command("list"):find("2. call bank (tomorrow)", 1, true))
    assert(t:command("done 1"):find("buy milk", 1, true))
    eq(#t:open(), 2)
    assert(t:command("done passport"))
    eq(#t:open(), 1)
    t:command("undo")
    eq(#t:open(), 2, "undo re-opens")
    eq(t:command("del 9"), "Which one? Send `list` for the numbers.")
    assert(t:command("help"):find("done 2", 1, true))
    eq(t:command("clear done"), "Cleared 1 item.")
    -- saved and reloaded
    local t2 = require("daily.todo").new(path, c)
    eq(#t2:open(), 2)
end)

test("telegram: pairing, commands, replies, ignores strangers", function()
    local Telegram = require("daily.telegram")
    local c = Clock.new(330, function() return NOW end)
    local path = OUT .. "/todo-tg.lua"
    os.remove(path)
    local sent, updates = {}, {}
    local app = { config = {}, todo = require("daily.todo").new(path, c) }
    app.http = { request = function(_, req)
        if req.url:find("getUpdates", 1, true) then
            local off = tonumber(req.url:match("offset=(%d+)") or 0)
            local res = {}
            for _, u in ipairs(updates) do if u.update_id >= off then res[#res + 1] = u end end
            return { status = 200, json = { ok = true, result = res }, body = "" }
        end
        sent[#sent + 1] = req.body
        return { status = 200, json = { ok = true }, body = "" }
    end }
    local tg = Telegram.new(app, "123:abc")
    local function msg(id, chat, text) updates[#updates + 1] = { update_id = id,
        message = { text = text, chat = { id = chat }, from = { username = "vimal" } } } end
    msg(1, 42, "/start")
    tg:poll()
    assert(tg.pending and tg.pending.chat_id == 42 and tg.pending.name == "@vimal", "pairing request")
    eq(#sent, 0, "nothing sent before pairing")
    tg:pair(tg.pending)
    eq(app.todo.telegram.chat_id, 42)
    assert(sent[1].text:find("Paired", 1, true))
    msg(2, 42, "buy milk")
    msg(3, 99, "add spam")
    msg(4, 42, "list")
    eq(tg:poll(), 2)
    eq(#app.todo:open(), 1, "stranger ignored")
    eq(sent[2].chat_id, 42)
    eq(sent[2].text, "Added: buy milk (1 open)")
    assert(sent[3].text:find("1. buy milk", 1, true))
    eq(app.todo.telegram.offset, 5, "acknowledged")
    eq(tg:poll(), 0, "no repeats")
end)

local function new_app(name, extra)
    local home = make_home(name, extra)
    os.execute(string.format("cp %s/e2e/data/brief.json %s/e2e/data/weather.lua %s/data/ 2>/dev/null", OUT, OUT, home))
    local cfg = util.load_table(home .. "/config.lua")
    cfg.data_dir = home .. "/data"
    local app = require("daily.app").new({ root = root, home = home, device = "emulator", config = cfg })
    app.dashboard = app.ui:show(require("daily.dashboard").new(app))
    return app, home
end

local function draw_top(app)
    local c = require("core.canvas").new(app.device.width, app.device.height)
    app.ui:top():draw(c)
    return c
end

local function tap_key(app, key)
    local kb = app.ui:top()
    draw_top(app)
    for _, t in ipairs(kb.targets) do
        if t.key == key or (t.chip and t.chip.text == key) then
            kb:handle({ type = "tap", x = t.r.x + t.r.w / 2, y = t.r.y + t.r.h / 2 })
            return
        end
    end
    error("no key " .. key)
end

test("to-do: add one on the Kindle with the on-screen keyboard", function()
    local app = new_app("keyboard")
    local dash = app.dashboard
    draw_top(app)
    -- the "+ ADD" corner of the to-do card opens the keyboard
    local r = dash.cards.todo
    dash:handle({ type = "tap", x = r.x + r.w - 30, y = r.y + 25 })
    local kb = app.ui:top()
    assert(kb.title == "Add to-do", "keyboard open")
    for _, ch in ipairs({ "c", "a", "l", "l", " ", "b", "a", "n", "k" }) do tap_key(app, ch) end
    eq(kb.text, "Call bank", "auto capital, then lower case")
    tap_key(app, "\226\140\171") -- backspace
    tap_key(app, "k")
    tap_key(app, "123"); tap_key(app, "2"); tap_key(app, "ABC")
    eq(kb.text, "Call bank2")
    tap_key(app, "\226\140\171")
    tap_key(app, "Tomorrow")
    util.write_file(OUT .. "/keyboard.png", draw_top(app):to_png())
    tap_key(app, "DONE")
    local open = app.todo:open()
    eq(#open, 1)
    eq(open[1].text, "Call bank")
    eq(app.todo:due_label(open[1]), "tomorrow")
    assert(app.ui:top() == dash, "keyboard closed")
    -- the full list: add row first, tap ticks off, hold deletes
    app:show_todo()
    local view = app.ui:top()
    eq(view.items[1].text, "+  Add a to-do")
    view.items[2].callback(view.items[2])
    eq(#app.todo:open(), 0, "ticked off")
end)

test("updates: checks once a day, downloads, verifies, asks to restart", function()
    local site = OUT .. "/update-site"
    os.execute("rm -rf " .. site)
    util.mkdir_p(site)
    util.write_file(site .. "/daily-latest.kpkg", "fake package contents")
    local p = io.popen("sha256sum " .. site .. "/daily-latest.kpkg")
    local sum = p:read("*a"):match("^(%x+)")
    p:close()
    util.write_file(site .. "/latest.json", json.encode({ version = "9.9.9", file = "daily-latest.kpkg", sha256 = sum, size = 21 }))
    local app, home = new_app("updates", { update_url = "file://" .. site .. "/latest.json" })
    app.version = "0.2.0"
    local Updater = require("daily.updater")
    assert(Updater.newer("0.10.0", "0.9.9") and not Updater.newer("0.2.0", "0.2.0"))
    app:auto_update()
    assert(util.file_exists(home .. "/update/daily-update.kpkg"), "downloaded")
    eq(Updater.pending(app), "9.9.9")
    local dlg = app.ui:top()
    eq(dlg.title, "Update ready")
    dlg.buttons[2].callback()
    eq(app.exit_code, 85, "asks the launcher to install")
    -- a damaged download is refused
    util.write_file(site .. "/latest.json", json.encode({ version = "9.9.10", file = "daily-latest.kpkg", sha256 = string.rep("0", 64) }))
    os.remove(home .. "/update/daily-update.kpkg")
    app.data.state.update_checked = nil
    app:auto_update()
    assert(not util.file_exists(home .. "/update/daily-update.kpkg"), "checksum mismatch rejected")
    -- and it only checks once a day
    util.write_file(site .. "/latest.json", "not json")
    app:auto_update()
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
