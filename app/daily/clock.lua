--[[
Local time without relying on the Kindle's TZ setup: UTC epoch from the
system clock plus a fixed offset (India: +5:30, no daylight saving).
--]]
local Clock = {}
Clock.__index = Clock

local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August",
    "September", "October", "November", "December" }
Clock.DAYS, Clock.MONTHS = DAYS, MONTHS

function Clock.new(offset_minutes, now_fn)
    return setmetatable({ offset = (offset_minutes or 330) * 60, now_fn = now_fn or os.time }, Clock)
end

function Clock:now() return self.now_fn() end

--- Broken-down local time for epoch t (default: now).
function Clock:parts(t)
    return os.date("!*t", (t or self:now()) + self.offset)
end

function Clock:hm(t)
    local p = self:parts(t)
    return string.format("%02d:%02d", p.hour, p.min)
end

function Clock:date_key(t)
    local p = self:parts(t)
    return string.format("%04d-%02d-%02d", p.year, p.month, p.day)
end

function Clock:weekday(t) return DAYS[self:parts(t).wday] end

function Clock:day_month(t)
    local p = self:parts(t)
    return string.format("%d %s", p.day, MONTHS[p.month])
end

function Clock:short_date(t)
    local p = self:parts(t)
    return string.format("%d %s", p.day, MONTHS[p.month]:sub(1, 3))
end

--- Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
local function days_from_civil(y, m, d)
    y = m <= 2 and y - 1 or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

Clock.days_from_civil = days_from_civil

--- Days since 1970-01-01 -> y, m, d
function Clock.civil_from_days(z)
    z = z + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    return (m <= 2) and y + 1 or y, m, d
end

--- Local day number (days since 1970-01-01 in local time) of epoch t.
function Clock:day(t) return math.floor(((t or self:now()) + self.offset) / 86400) end

--- Epoch of local midnight starting local day number `day`.
function Clock:day_start(day) return day * 86400 - self.offset end

--- 12-hour time: "12:21", "PM"
function Clock:hm12(t)
    local p = self:parts(t)
    local h = p.hour % 12
    if h == 0 then h = 12 end
    return string.format("%d:%02d", h, p.min), p.hour < 12 and "AM" or "PM"
end

function Clock.days_in_month(y, m)
    return days_from_civil(m == 12 and y + 1 or y, m == 12 and 1 or m + 1, 1) - days_from_civil(y, m, 1)
end

--- "2026-11-24T08:59:50Z" (UTC) -> epoch. "2026-11-24T14:00" (no zone) is
-- taken as local time (Open-Meteo with a timezone parameter).
function Clock:parse_iso(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, sec, z = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):?(%d*)(Z?)")
    if not y then
        y, mo, d = s:match("^(%d+)-(%d+)-(%d+)$")
        if not y then return nil end
        h, mi, sec, z = 0, 0, 0, ""
    end
    local t = days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
        + tonumber(h) * 3600 + tonumber(mi) * 60 + (tonumber(sec) or 0)
    if z ~= "Z" then t = t - self.offset end
    return t
end

--- "just now", "5 min ago", "3 h ago", "yesterday", "4 days ago"
function Clock:ago(t, now)
    if not t then return "never" end
    local s = (now or self:now()) - t
    if s < 90 then return "just now" end
    if s < 3600 then return string.format("%d min ago", math.floor(s / 60 + 0.5)) end
    if s < 86400 then return string.format("%d h ago", math.floor(s / 3600 + 0.5)) end
    local days = math.floor(s / 86400 + 0.5)
    return days <= 1 and "yesterday" or string.format("%d days ago", days)
end

return Clock
