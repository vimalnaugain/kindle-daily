--[[
Google Calendar (or any iCalendar feed) from its private "secret address in
iCal format": no login, no API key. The link stays on the Kindle.

Cal.parse(text)                     -> { events = {...}, tz = {TZID = offset seconds} }
Cal.occurrences(parsed, clock, from_day, to_day)
                                    -> sorted { title, start, finish, all_day }

Repeating events: DAILY, WEEKLY (BYDAY), MONTHLY (BYMONTHDAY or BYDAY like
2TU / -1FR), YEARLY, with INTERVAL, COUNT, UNTIL, EXDATE, and edited single
occurrences (RECURRENCE-ID). Time zones use their standard offset (no DST
switches), which is exact for India.
--]]
local Clock = require("daily.clock")

local Cal = {}

local WD = { SU = 0, MO = 1, TU = 2, WE = 3, TH = 4, FR = 5, SA = 6 }

local function unescape(s)
    return (s:gsub("\\[nN]", " "):gsub("\\([,;\\])", "%1"))
end

local function parse_offset(s) -- "+0530" -> seconds
    local sign, h, m = (s or ""):match("([+-])(%d%d)(%d%d)")
    if not sign then return nil end
    local v = tonumber(h) * 3600 + tonumber(m) * 60
    return sign == "-" and -v or v
end

--- Unfolded content lines -> list of { name, params = {}, value }
local function lines(text)
    local out = {}
    for raw in (text:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
        if raw:match("^[ \t]") and #out > 0 then
            out[#out] = out[#out] .. raw:sub(2)
        elseif raw ~= "" then
            out[#out + 1] = raw
        end
    end
    local props = {}
    for _, l in ipairs(out) do
        local head, value = l:match("^([^:]+):(.*)$")
        if head then
            local name, rest = head:match("^([^;]+)(.*)$")
            local params = {}
            for k, v in rest:gmatch(";([^=;]+)=([^;]+)") do params[k:upper()] = v:gsub('^"(.*)"$', "%1") end
            props[#props + 1] = { name = name:upper(), params = params, value = value }
        end
    end
    return props
end

--- A DTSTART/DTEND/EXDATE value -> epoch, all_day. tz: TZID -> offset.
local function parse_time(value, params, tz, local_offset)
    local y, m, d = value:match("^(%d%d%d%d)(%d%d)(%d%d)")
    if not y then return nil end
    local days = Clock.days_from_civil(tonumber(y), tonumber(m), tonumber(d))
    local hh, mm, ss, z = value:match("T(%d%d)(%d%d)(%d%d)(Z?)")
    if not hh or params.VALUE == "DATE" then
        return days * 86400 - local_offset, true
    end
    local t = days * 86400 + tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss)
    if z == "Z" then return t, false end
    local off = params.TZID and tz[params.TZID]
    return t - (off or local_offset), false
end

local function parse_duration(s) -- "PT1H30M", "P1D"
    if not s then return nil end
    local sign = s:sub(1, 1) == "-" and -1 or 1
    local w = tonumber(s:match("(%d+)W")) or 0
    local d = tonumber(s:match("(%d+)D")) or 0
    local h = tonumber(s:match("T.-(%d+)H")) or 0
    local m = tonumber(s:match("T.-(%d+)M")) or 0
    local sec = tonumber(s:match("T.-(%d+)S")) or 0
    return sign * (w * 604800 + d * 86400 + h * 3600 + m * 60 + sec)
end

local function parse_rrule(v)
    local r = {}
    for k, val in v:gmatch("([^=;]+)=([^;]+)") do r[k:upper()] = val end
    r.INTERVAL = tonumber(r.INTERVAL) or 1
    r.COUNT = tonumber(r.COUNT)
    if r.BYDAY then
        local list = {}
        for item in r.BYDAY:gmatch("[^,]+") do
            local n, day = item:match("^([+-]?%d*)(%a%a)$")
            if day and WD[day:upper()] then list[#list + 1] = { n = tonumber(n), wd = WD[day:upper()] } end
        end
        r.BYDAY = list
    end
    if r.BYMONTHDAY then
        local list = {}
        for n in r.BYMONTHDAY:gmatch("-?%d+") do list[#list + 1] = tonumber(n) end
        r.BYMONTHDAY = list
    end
    return r
end

--- iCalendar text -> parsed calendar. local_offset: seconds east of UTC.
function Cal.parse(text, local_offset)
    local_offset = local_offset or 0
    local props = lines(text or "")
    -- time zones first: TZID -> standard offset
    local tz, cur_tz, in_std = {}, nil, false
    for _, p in ipairs(props) do
        if p.name == "BEGIN" and p.value == "VTIMEZONE" then cur_tz = nil
        elseif p.name == "TZID" and not in_std then cur_tz = p.value
        elseif p.name == "BEGIN" and (p.value == "STANDARD" or p.value == "DAYLIGHT") then in_std = p.value
        elseif p.name == "END" and (p.value == "STANDARD" or p.value == "DAYLIGHT") then in_std = false
        elseif p.name == "TZOFFSETTO" and cur_tz and (in_std == "STANDARD" or not tz[cur_tz]) then
            tz[cur_tz] = parse_offset(p.value)
        end
    end
    local events, ev = {}, nil
    for _, p in ipairs(props) do
        if p.name == "BEGIN" and p.value == "VEVENT" then
            ev = { exdates = {} }
        elseif p.name == "END" and p.value == "VEVENT" and ev then
            if ev.start and ev.status ~= "CANCELLED" then events[#events + 1] = ev
            elseif ev.start and ev.recurrence_id then events[#events + 1] = ev end -- cancelled single occurrence
            ev = nil
        elseif ev then
            if p.name == "SUMMARY" then ev.title = unescape(p.value)
            elseif p.name == "UID" then ev.uid = p.value
            elseif p.name == "STATUS" then ev.status = p.value:upper()
            elseif p.name == "DTSTART" then ev.start, ev.all_day = parse_time(p.value, p.params, tz, local_offset)
            elseif p.name == "DTEND" then ev.finish = parse_time(p.value, p.params, tz, local_offset)
            elseif p.name == "DURATION" then ev.duration = parse_duration(p.value)
            elseif p.name == "RRULE" then ev.rrule = parse_rrule(p.value)
            elseif p.name == "RECURRENCE-ID" then ev.recurrence_id = parse_time(p.value, p.params, tz, local_offset)
            elseif p.name == "EXDATE" then
                for v in p.value:gmatch("[^,]+") do
                    local t = parse_time(v, p.params, tz, local_offset)
                    if t then ev.exdates[t] = true end
                end
            end
        end
    end
    for _, e in ipairs(events) do
        e.length = (e.finish and e.finish - e.start) or e.duration or (e.all_day and 86400 or 0)
        e.title = e.title or "(no title)"
    end
    return { events = events, tz = tz }
end

------------------------------------------------------------------------------
-- Repeats, worked out on local calendar days
------------------------------------------------------------------------------

--- Local days on which a repeating event starts, between day0 (its first
-- day) and last_day. Stops at COUNT / UNTIL.
local function repeat_days(r, day0, from_day, last_day, until_day)
    local days = {}
    local limit = until_day and math.min(last_day, until_day) or last_day
    local count = 0
    local function take(d)
        if d < day0 then return true end
        if d > limit then return false end
        count = count + 1
        if r.COUNT and count > r.COUNT then return false end
        days[#days + 1] = d
        return true
    end
    local freq, iv = r.FREQ, r.INTERVAL
    local guard = 0
    if freq == "DAILY" then
        local d = day0
        if from_day > day0 then -- jump to the window (old daily events)
            local k = math.floor((from_day - day0) / iv)
            d, count = day0 + k * iv, k
        end
        while d <= limit and guard < 5000 do
            guard = guard + 1
            if not take(d) then break end
            d = d + iv
        end
    elseif freq == "WEEKLY" then
        local wd0 = (day0 + 4) % 7 -- 1970-01-01 was a Thursday; 0 = Sunday
        local wds = {}
        for _, b in ipairs(r.BYDAY or {}) do wds[#wds + 1] = b.wd end
        if #wds == 0 then wds = { wd0 } end
        table.sort(wds)
        local week = day0 - wd0
        local k = math.floor((from_day - week) / (7 * iv)) - 1
        if k > 0 then week, count = week + k * 7 * iv, k * #wds end
        local go = true
        while go and week <= limit and guard < 2000 do
            guard = guard + 1
            for _, wd in ipairs(wds) do
                if not take(week + wd) then go = false; break end
            end
            week = week + 7 * iv
        end
    elseif freq == "MONTHLY" or freq == "YEARLY" then
        local y, m, d0 = Clock.civil_from_days(day0)
        local step = freq == "MONTHLY" and iv or 12 * iv
        local go = true
        while go and guard < 1000 do
            guard = guard + 1
            local dim = Clock.days_in_month(y, m)
            local first = Clock.days_from_civil(y, m, 1)
            if first > limit then break end
            local cands = {}
            if freq == "MONTHLY" and r.BYDAY and #r.BYDAY > 0 then
                for _, b in ipairs(r.BYDAY) do
                    local hits = {}
                    for dd = 1, dim do
                        if (first + dd - 1 + 4) % 7 == b.wd then hits[#hits + 1] = first + dd - 1 end
                    end
                    if b.n and b.n ~= 0 then
                        local pick = b.n > 0 and hits[b.n] or hits[#hits + b.n + 1]
                        if pick then cands[#cands + 1] = pick end
                    else
                        for _, h in ipairs(hits) do cands[#cands + 1] = h end
                    end
                end
            elseif freq == "MONTHLY" and r.BYMONTHDAY then
                for _, n in ipairs(r.BYMONTHDAY) do
                    local dd = n > 0 and n or dim + n + 1
                    if dd >= 1 and dd <= dim then cands[#cands + 1] = first + dd - 1 end
                end
            elseif d0 <= dim then
                cands[1] = first + d0 - 1 -- same day of the month (skips months without it)
            end
            table.sort(cands)
            for _, c in ipairs(cands) do
                if not take(c) then go = false; break end
            end
            m = m + step
            while m > 12 do m = m - 12; y = y + 1 end
        end
    end
    return days
end

--- Occurrences overlapping local days [from_day, to_day], sorted by start.
function Cal.occurrences(parsed, clock, from_day, to_day)
    local out = {}
    local from_t, to_t = clock:day_start(from_day), clock:day_start(to_day + 1)
    -- edited / cancelled single occurrences, by UID and original start
    local overrides = {}
    for _, e in ipairs(parsed.events) do
        if e.recurrence_id and e.uid then
            overrides[e.uid] = overrides[e.uid] or {}
            overrides[e.uid][e.recurrence_id] = e
        end
    end
    local function add(e, start)
        local finish = start + math.max(e.length, 0)
        if finish > from_t and start < to_t or (start >= from_t and start < to_t) then
            out[#out + 1] = { title = e.title, start = start, finish = finish, all_day = e.all_day }
        end
    end
    for _, e in ipairs(parsed.events) do
        if e.recurrence_id then
            if e.status ~= "CANCELLED" then add(e, e.start) end
        elseif e.rrule and e.rrule.FREQ then
            local sod = (e.start + clock.offset) % 86400
            local day0 = clock:day(e.start)
            local until_day = e.rrule.UNTIL and clock:day(select(1, parse_time(e.rrule.UNTIL, {}, {}, clock.offset)) or 0)
            local lookback = math.ceil(e.length / 86400) + 1
            for _, d in ipairs(repeat_days(e.rrule, day0, from_day - lookback, to_day, until_day)) do
                if d >= from_day - lookback then
                    local start = d * 86400 + sod - clock.offset
                    local ov = e.uid and overrides[e.uid] and overrides[e.uid][start]
                    if not e.exdates[start] and not ov then add(e, start) end
                end
            end
        else
            add(e, e.start)
        end
    end
    table.sort(out, function(a, b)
        if a.start ~= b.start then return a.start < b.start end
        return a.title < b.title
    end)
    return out
end

return Cal
