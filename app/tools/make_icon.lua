--[[
Draws Daily's 250x250 library icon (a folded newspaper with a rising sun)
as a PNG with the app's own canvas and fonts. Usage: luajit tools/make_icon.lua out.png
--]]
package.path = "./?.lua;" .. package.path
local Canvas = require("core.canvas")
local Font = require("core.font")
Font.set_dir("fonts")

local c = Canvas.new(250, 250)
c:fill_rect(0, 0, 250, 250, 255)
-- sun rising behind the paper
for y = 20, 110 do
    for x = 60, 190 do
        local dx, dy = x - 125, y - 110
        local d = math.sqrt(dx * dx + dy * dy)
        if d <= 58 then c:fill_rect(x, y, 1, 1, d > 52 and 0 or 120) end
    end
end
for i = 0, 6 do
    local a = math.pi * (0.1 + i * 0.8 / 6)
    for r = 66, 86 do
        c:fill_rect(math.floor(125 - math.cos(a) * r), math.floor(110 - math.sin(a) * r), 4, 4, 0)
    end
end
-- the paper
c:fill_rect(30, 105, 190, 125, 255)
c:rect(30, 105, 190, 125, 0, 5)
local f = Font.get("serif", "b", 46)
local t = "DAILY"
c:text(f, t, 125 - f:width(t) / 2, 152)
c:fill_rect(48, 164, 154, 4, 0)
for i = 0, 3 do
    c:fill_rect(48, 178 + i * 12, 70, 5, 90)
    c:fill_rect(132, 178 + i * 12, 70, 5, 90)
end
local out = assert(io.open(arg[1] or "daily-icon.png", "wb"))
out:write(c:to_png())
out:close()
