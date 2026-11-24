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
local app = {
    clock = Clock.new(330, function() return 1795509720 end),
    settings = {}, save_settings = function() end,
    device = { battery = function() return 80 end },
    data = { brief = brief, base_url = function() return "" end },
}
local dash = require("daily.dashboard").new(app)
dash.ui = { set_dirty = function() end }
local c = Canvas.new(1072, 1448)
dash:draw(c)
assert(#dash.targets.stories == 5, "dashboard stories")
local png = c:to_png()
assert(#png > 1000 and png:sub(2, 4) == "PNG", "png")
assert(require("core.qr").encode("https://example.com/" .. string.rep("a", 150)).size == 53, "qr v9")
-- error handling through LuaJIT's internal unwinder (LUAJIT_NO_UNWIND)
local ok, err = pcall(function() error("expected") end)
assert(not ok and tostring(err):find("expected"), "pcall/error")
print("ARM smoke test OK")
