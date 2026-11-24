--[[
Smoke test for the cross-compiled Kindle binary, run in CI under qemu-arm:
  qemu-arm build/kindle/daily tests/arm_smoke.lua
Checks the static LuaJIT (JIT and FFI) and the built-in tomecore module run
Daily's code on ARM: fonts, JSON, layout, and drawing the dashboard.
--]]
package.path = "./?.lua;" .. package.path
local core = require("tomecore")
assert(type(core.monotonic_ms()) == "number", "tomecore clock")
assert(jit and jit.arch == "arm", "expected ARM LuaJIT, got " .. tostring(jit and jit.arch))
print("LuaJIT", jit.version, jit.arch, "JIT", jit.status() and "on" or "off")

local Font = require("core.font"); Font.set_dir("fonts")
local Canvas = require("core.canvas")
local json = require("core.json")
local util = require("core.util")
local Data = require("daily.data")
local Clock = require("daily.clock")

local brief = Data.strip_nulls(assert(json.decode(util.read_file("tests/fixtures/site/brief.json"))))
assert(#brief.categories == 5, "brief")
-- a minimal app for the dashboard to draw
local clock = Clock.new(330, function() return 1795509720 end)
local app = {
    clock = clock, config = {},
    settings = {}, save_settings = function() end,
    device = { battery = function() return 80 end },
    data = setmetatable({ brief = brief, calendar = {}, read = {}, dir = "/tmp" }, { __index = Data }),
    todo = require("daily.todo").new("/tmp/daily_arm_todo.lua", clock),
}
app.todo:command("buy milk tomorrow")
app.data.app = app
app.settings.topics = { brief.categories[1].id }
app.data.read_path = "/tmp/daily_arm_read.lua"
local Cal = require("daily.calendar")
app.data.calendar = Cal.occurrences(Cal.parse(util.read_file("tests/fixtures/calendar.ics"), clock.offset),
    clock, clock:day(), clock:day() + 30)
app.data.calendar_configured = #app.data.calendar > 0
local dash = require("daily.dashboard").new(app)
dash.ui = { set_dirty = function() end }
local c = Canvas.new(1072, 1448)
dash:draw(c)
assert(#dash.targets > 10, "dashboard tap targets")
assert(dash.cards and dash.cards.todo and dash.cards.calendar and dash.cards.reads, "cards")
assert(#dash.read_rows >= 1, "long reads drawn")
local png = c:to_png()
assert(#png > 1000 and png:sub(2, 4) == "PNG", "png")
assert(require("core.qr").encode("https://example.com/" .. string.rep("a", 150)).size == 53, "qr v9")
-- error handling through LuaJIT's internal unwinder (LUAJIT_NO_UNWIND)
local ok, err = pcall(function() error("expected") end)
assert(not ok and tostring(err):find("expected"), "pcall/error")
print("ARM smoke test OK")
