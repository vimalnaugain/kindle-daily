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

test("dashboard and articles draw on every Kindle size and orientation", function()
    local App = require("daily.app")
    local Canvas = require("core.canvas")
    for _, size in ipairs({ { 600, 800, 167 }, { 758, 1024, 212 }, { 1072, 1448, 300 }, { 1236, 1648, 300 },
                            { 1264, 1680, 300 }, { 1448, 1072, 300 } }) do
        local home = make_home("size", { emulator = { screen_width = size[1], screen_height = size[2], dpi = size[3] } })
        -- reuse the cached edition from the end-to-end test
        os.execute(string.format("cp %s/e2e/data/brief.json %s/e2e/data/weather.lua %s/data/ 2>/dev/null", OUT, OUT, home))
        local cfg = util.load_table(home .. "/config.lua")
        cfg.data_dir = home .. "/data"
        local app = App.new({ root = root, home = home, device = "emulator", config = cfg })
        local dash = require("daily.dashboard").new(app)
        dash.ui = app.ui
        local c = Canvas.new(size[1], size[2])
        dash:draw(c)
        assert(#(dash.targets.stories or {}) == 5, "five stories at " .. size[1] .. "x" .. size[2])
        for i, r in ipairs(dash.targets.stories) do
            assert(r.y + r.h <= size[2], "story " .. i .. " fits")
        end
        for ci, cat in ipairs(app.data.brief.categories) do
            for si = 1, #cat.stories do
                local art = require("daily.article").new(app, cat, si)
                art.ui = app.ui
                art:draw(c)
                assert(#art.pages >= 2, "article has pages")
            end
            if ci > 1 then break end
        end
    end
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
