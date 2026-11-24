--[[
The home screen, in two parts:

  TODAY ──────────────────────────────────────────
  ╭ clock, date, progress ╮ ╭ weather ╮
  ╭ to-do        ╮ ╭ calendar: month + next events ╮
  READING ────────────────────────────────────────
  ╭ long reads: unread pieces, newest first        ╮
  ╭ quote of the day ╮ ╭ news: your topics         ╮
  ☰ Menu          Updated 2:12 PM · 87%      Refresh

Productivity cards use the sans face, reading cards the serif face.
Landscape puts the two parts side by side. Everything scales with the screen.
--]]
local Font = require("core.font")
local W = require("core.ui.widgets")

local Dashboard = {}
Dashboard.__index = Dashboard

local DEG = "\194\176"
local DOT = " \194\183 "
local UP, DOWN = "\226\150\178", "\226\150\188" -- ▲ ▼
local BOX, CHECKED = "\226\152\144", "\226\152\145" -- ☐ ☑


function Dashboard.new(app)
    return setmetatable({ app = app, fullscreen = true, refresh_mode = "full", targets = {} }, Dashboard)
end

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------

local function fmt_num(x, decimals)
    local s = string.format("%." .. (decimals or 2) .. "f", x)
    local int, frac = s:match("^(%-?%d+)(.*)$")
    int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^(%-?),", "%1")
    return int .. frac
end
Dashboard.fmt_num = fmt_num

local function right(c, font, s, xr, y, color) c:text(font, s, xr - font:width(s), y, color) end

local function add_target(self, r, fn) self.targets[#self.targets + 1] = { r = r, fn = fn } end

--- Wrap to at most n lines, ellipsis on the last.
local function wrap_n(font, text, w, n)
    local lines = W.wrap(font, text or "", w)
    if #lines > n then
        local keep = {}
        for i = 1, n - 1 do keep[i] = lines[i] end
        keep[n] = W.fit(font, table.concat(lines, " ", n), w)
        return keep
    end
    return lines
end

function Dashboard:metrics(c)
    local portrait = c.h >= c.w
    local k = portrait and math.min(c.w / 1072, c.h / 1448) or math.min(c.w / 1448, c.h / 1072)
    local function px(n) return math.max(1, math.floor(n * k + 0.5)) end
    return {
        k = k, px = px, portrait = portrait,
        pad = px(22), gap = px(16), inner = px(22), radius = px(16), track = px(2),
        border = math.max(2, px(2.5)), hair = math.max(1, px(1.5)),
        clock = Font.get("sans", "b", px(128)),
        big = Font.get("sans", "b", px(96)),
        icon = Font.get("sans", "r", px(64)),
        h1 = Font.get("sans", "b", px(36)),
        h2 = Font.get("sans", "b", px(30)),
        body = Font.get("sans", "r", px(26)),
        bodyb = Font.get("sans", "b", px(26)),
        small = Font.get("sans", "r", px(22)),
        label = Font.get("sans", "b", px(22)),
        headline = Font.get("serif", "b", px(30)),
        title = Font.get("serif", "b", px(34)),
        serif = Font.get("serif", "r", px(26)),
        italic = Font.get("serif", "i", px(26)),
        section = Font.get("sans", "b", px(24)),
        rtitle = Font.get("serif", "b", px(28)),
        quote = Font.get("serif", "i", px(28)),
    }
end

--- A rounded rectangle outline.
local function rrect(c, r, rad, t)
    local x, y, w, h = r.x, r.y, r.w, r.h
    c:fill_rect(x + rad, y, w - 2 * rad, t, 0)
    c:fill_rect(x + rad, y + h - t, w - 2 * rad, t, 0)
    c:fill_rect(x, y + rad, t, h - 2 * rad, 0)
    c:fill_rect(x + w - t, y + rad, t, h - 2 * rad, 0)
    local steps = math.max(8, rad * 2)
    for i = 0, steps do
        local a = (math.pi / 2) * i / steps
        local dx, dy = math.floor((1 - math.cos(a)) * rad), math.floor((1 - math.sin(a)) * rad)
        c:fill_rect(x + dx, y + dy, t, t, 0)                     -- top left
        c:fill_rect(x + w - t - dx, y + dy, t, t, 0)             -- top right
        c:fill_rect(x + dx, y + h - t - dy, t, t, 0)             -- bottom left
        c:fill_rect(x + w - t - dx, y + h - t - dy, t, t, 0)     -- bottom right
    end
end
Dashboard.rrect = rrect

--- Upper-case label with a little letter spacing. Returns the x after it.
local function spaced(c, font, s, x, y, color, sp)
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        x = c:text(font, ch, x, y, color) + sp
    end
    return x
end
local function spaced_width(font, s, sp)
    local w = 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do w = w + font:width(ch) + sp end
    return w
end

--- Card frame with a small label. Returns the content rect.
function Dashboard:card(c, m, r, label, label_right)
    rrect(c, r, m.radius, m.border)
    local x, y, w = r.x + m.inner, r.y + m.inner, r.w - 2 * m.inner
    if label then
        local base = y + m.label.ascent
        spaced(c, m.label, label:upper(), x, base, 70, m.track)
        if label_right and label_right ~= "" then
            local lw = spaced_width(m.label, label_right, m.track)
            spaced(c, m.label, label_right, x + w - lw, base, 70, m.track)
        end
        y = y + m.label.line_height + m.px(12)
    end
    return { x = x, y = y, w = w, h = r.y + r.h - m.inner - y }
end

--- "TODAY ─────" section heading. Returns the y below it.
function Dashboard:section(c, m, x, y, w, title)
    local base = y + m.section.ascent
    local x2 = spaced(c, m.section, title, x + m.px(4), base, 0, m.px(3))
    c:fill_rect(x2 + m.px(12), base - math.floor(m.section.ascent * 0.35), x + w - x2 - m.px(12), m.hair, 0)
    return y + m.section.line_height + m.px(10)
end

------------------------------------------------------------------------------
-- Cards
------------------------------------------------------------------------------

function Dashboard:_clock(c, m, r)
    local clock = self.app.clock
    local b = self:card(c, m, r)
    local p = clock:parts()
    local bottom = b.y + b.h
    -- the time: as big as the card allows (96 or 128 px at Paperwhite size)
    local big = (b.h >= m.px(330)) and m.clock or m.big
    local base = b.y + big.ascent - m.px(8)
    if self.sleep_mode then
        c:text(big, tostring(p.day), b.x, base)
    else
        local t, ampm = clock:hm12()
        local x = c:text(big, t, b.x, base)
        c:text(m.h2, ampm, x + m.px(12), base)
    end
    local y = base + m.px(14) + m.h1.ascent
    c:text(m.h1, clock:weekday():upper(), b.x, y)
    y = y + m.body.line_height
    c:text(m.body, string.format("%d %s %d", p.day, clock.MONTHS[p.month]:upper(), p.year), b.x, y, 40)
    -- progress through the day, month and year: as many rows as fit
    local cfg = self.app.config
    local d0, d1 = (cfg.day_starts_at or 7) * 60, (cfg.day_ends_at or 23) * 60
    local mins = p.hour * 60 + p.min
    local dim = clock.days_in_month(p.year, p.month)
    local diy = clock.days_from_civil(p.year + 1, 1, 1) - clock.days_from_civil(p.year, 1, 1)
    local yday = clock:day() - clock.days_from_civil(p.year, 1, 1) + 1
    local rows = {
        { "DAY", math.max(0, math.min(1, (mins - d0) / (d1 - d0))) },
        { string.format("MONTH %d/%d", p.day, dim), p.day / dim },
        { string.format("YEAR %d/%d", yday, diy), yday / diy },
    }
    local rh = m.small.line_height + m.px(2)
    local top = y + m.body.descent + m.px(12)
    local fit = math.floor((bottom - top) / rh)
    if fit < 3 then table.remove(rows, 2) end
    if fit < 2 then table.remove(rows, 1) end
    if fit < 1 then return end
    top = bottom - #rows * rh
    local lw = m.small:width("MONTH 30/31") + m.px(16)
    local pw = m.small:width("100%") + m.px(8)
    for i, row in ipairs(rows) do
        local base2 = top + (i - 1) * rh + m.small.ascent
        c:text(m.small, row[1], b.x, base2, 70)
        local bx, bw, bh = b.x + lw, b.w - lw - pw, math.max(3, m.px(7))
        local by = math.floor(base2 - m.small.ascent / 2 - bh / 2)
        c:fill_rect(bx, by, bw, bh, 215)
        c:fill_rect(bx, by, math.floor(bw * row[2]), bh, 0)
        right(c, m.small, string.format("%d%%", math.floor(row[2] * 100 + 0.5)), b.x + b.w, base2, 70)
    end
end

function Dashboard:_weather(c, m, r)
    local w = self.app.data.weather
    local b = self:card(c, m, r)
    add_target(self, r, function() self.app:show_weather() end)
    if not (w and w.temp) then
        local lines = wrap_n(m.body, "Weather appears once the Kindle is online.", b.w, 4)
        for i, l in ipairs(lines) do c:text(m.body, l, b.x, b.y + i * m.body.line_height, 80) end
        return
    end
    local base = b.y + m.big.ascent - m.px(6)
    c:text(m.big, w.temp .. DEG, b.x, base)
    right(c, m.icon, w.icon or "", b.x + b.w, base - m.px(8))
    local y = base + m.big.descent + m.h2.ascent + m.px(6)
    c:text(m.h2, W.fit(m.h2, (w.label or ""):upper(), b.w), b.x, y)
    local lines = {}
    lines[#lines + 1] = { m.small, string.format("FEELS %s%s%s\226\134\145%s%s \226\134\147%s%s",
        w.feels or "?", DEG, DOT, w.max or "?", DEG, w.min or "?", DEG) }
    if w.aqi then lines[#lines + 1] = { w.aqi > 150 and m.bodyb or m.body, "AQI " .. w.aqi .. DOT .. (w.aqi_label or "") } end
    if w.rain_from then lines[#lines + 1] = { m.body, string.format("Rain likely from %s", self:_hour(w.rain_from)) }
    elseif (w.rain or 0) > 0 then lines[#lines + 1] = { m.body, "Chance of rain " .. w.rain .. "%" } end
    local hours = {}
    for i = 2, math.min(4, #(w.hours or {})) do
        local h = w.hours[i]
        hours[#hours + 1] = self:_hour(h.hour) .. " " .. (h.temp or "?") .. DEG
    end
    if #hours > 0 then lines[#lines + 1] = { m.small, table.concat(hours, "  ") } end
    local bottom = r.y + r.h - m.inner
    for _, l in ipairs(lines) do
        y = y + l[1].line_height + m.px(2)
        if y > bottom then break end
        c:text(l[1], W.fit(l[1], l[2], b.w), b.x, y, l[1] == m.small and 60 or 0)
    end
end

function Dashboard:_hour(h)
    local h12 = h % 12
    return (h12 == 0 and 12 or h12) .. (h < 12 and "am" or "pm")
end

function Dashboard:_reads(c, m, r)
    local data = self.app.data
    local unread = data:unread()
    self.read_rows = {}
    local b = self:card(c, m, r, "Long reads", #unread > 0 and (#unread .. " UNREAD") or nil)
    add_target(self, { x = r.x, y = r.y, w = r.w, h = b.y - r.y }, function() self.app:show_reads() end)
    if #unread == 0 then
        local msg = (data.brief and data.brief.reads and #data.brief.reads > 0)
            and "You've read them all. New pieces arrive every morning."
            or "Great long reads arrive with the morning edition."
        for i, l in ipairs(wrap_n(m.serif, msg, b.w, 2)) do c:text(m.serif, l, b.x, b.y + i * m.serif.line_height, 80) end
        return
    end
    local rh = m.rtitle.line_height + m.small.line_height + m.px(10)
    local n = math.max(1, math.floor((b.h + m.px(10)) / rh))
    local more = #unread - n
    for i = 1, math.min(n, #unread) do
        local it = unread[i]
        local top = b.y + (i - 1) * rh
        local base = top + m.rtitle.ascent
        local tail = (i == n and more > 0) and string.format("  +%d more \u{203A}", more) or ""
        c:text(m.rtitle, W.fit(m.rtitle, it.title, b.w), b.x, base)
        local meta = it.source .. DOT .. it.minutes .. " min" .. (it.label and (DOT .. it.label) or "")
        local my = base + m.rtitle.descent + m.small.ascent + m.px(2)
        c:text(m.small, W.fit(m.small, meta, b.w - m.small:width(tail)), b.x, my, 90)
        if tail ~= "" then right(c, m.small, tail, b.x + b.w, my, 60) end
        if i < math.min(n, #unread) then c:fill_rect(b.x, top + rh - m.px(5), b.w, m.hair, 200) end
        local idx = i
        local row = { x = r.x, y = top - m.px(4), w = r.w, h = rh }
        add_target(self, row, function() self.app:open_read(idx) end)
        self.read_rows[#self.read_rows + 1] = { r = row, item = it }
    end
end

function Dashboard:_quote(c, m, r)
    local q = self.app.data.brief and self.app.data.brief.quote
    local b = self:card(c, m, r, "Quote of the day")
    if not q then
        for i, l in ipairs(wrap_n(m.serif, "A passage from a classic book arrives each morning.", b.w, 3)) do
            c:text(m.serif, l, b.x, b.y + i * m.serif.line_height, 80)
        end
        return
    end
    add_target(self, r, function() self.app:show_quote() end)
    local attr_h = m.small.line_height * 2 + m.px(6)
    local n = math.max(1, math.floor((b.h - attr_h) / m.quote.line_height))
    local lines = wrap_n(m.quote, "\u{201C}" .. q.text .. "\u{201D}", b.w, n)
    local y = b.y
    for _, l in ipairs(lines) do
        y = y + m.quote.line_height
        c:text(m.quote, l, b.x, y - m.quote.descent)
    end
    local ay = b.y + b.h - m.small.line_height - m.px(2)
    c:text(m.bodyb, W.fit(m.bodyb, "\u{2014} " .. q.book, b.w), b.x, ay)
    c:text(m.small, W.fit(m.small, q.author, b.w), b.x + m.bodyb:width("\u{2014} "), ay + m.small.line_height + m.px(2), 80)
end

function Dashboard:_news(c, m, r)
    local data = self.app.data
    local topics = data:topics()
    local names = {}
    for _, t in ipairs(topics) do names[#names + 1] = (t.short or t.title):upper() end
    local b = self:card(c, m, r, "News", #topics > 0 and "TOPICS \u{203A}" or nil)
    add_target(self, { x = r.x, y = r.y, w = r.w, h = b.y - r.y }, function() self.app:choose_topics() end)
    if #topics == 0 then
        local lines = wrap_n(m.serif, "Pick the news topics you want to see.", b.w, 3)
        local y = b.y
        for _, l in ipairs(lines) do y = y + m.serif.line_height; c:text(m.serif, l, b.x, y - m.serif.descent, 60) end
        local f = m.bodyb
        local label = "Choose topics \u{203A}"
        local br = { x = b.x, y = y + m.px(16), w = f:width(label) + m.px(40), h = f.line_height + m.px(20) }
        W.draw_button(c, br, label, f, true, m.border)
        add_target(self, r, function() self.app:choose_topics() end)
        return
    end
    local news = data:news()
    c:text(m.small, W.fit(m.small, table.concat(names, " \u{00B7} "), b.w), b.x, b.y + m.small.ascent - m.px(4), 90)
    local y = b.y + m.small.line_height + m.px(4)
    local foot = string.format("All %d stories \u{203A}", #news)
    local bottom = b.y + b.h - m.small.line_height - m.px(4)
    for i, s in ipairs(news) do
        local lines = wrap_n(m.rtitle, s.title, b.w, 2)
        local need = #lines * m.rtitle.line_height + m.px(10)
        if y + need > bottom then
            lines = { W.fit(m.rtitle, s.title, b.w) }
            need = m.rtitle.line_height + m.px(10)
            if y + need > bottom then break end
        end
        local top = y
        for _, l in ipairs(lines) do
            y = y + m.rtitle.line_height
            c:text(m.rtitle, l, b.x, y - m.rtitle.descent)
        end
        y = y + m.px(10)
        local idx = i
        add_target(self, { x = r.x, y = top - m.px(4), w = r.w, h = need }, function() self.app:open_news(idx) end)
    end
    right(c, m.bodyb, foot, b.x + b.w, b.y + b.h - m.px(2))
    add_target(self, { x = r.x, y = bottom, w = r.w, h = r.y + r.h - bottom }, function() self.app:show_news() end)
end

function Dashboard:_todo(c, m, r)
    local todo = self.app.todo
    local open, done = todo:open(), todo:recently_done()
    local b = self:card(c, m, r, #open > 0 and ("To-do \u{00B7} " .. #open) or "To-do", self.sleep_mode and "" or "+ ADD")
    add_target(self, { x = r.x, y = r.y, w = r.w, h = b.y - r.y }, function() self.app:show_todo() end)
    local add_w = m.label:width("+ ADD") + 2 * m.inner
    add_target(self, { x = r.x + r.w - add_w - m.px(10), y = r.y, w = add_w + m.px(10), h = b.y - r.y + m.px(6) },
        function() self.app:add_todo() end)
    if #open == 0 and #done == 0 then
        local msg = self.app.telegram and "All clear. Tap + Add, or message your Telegram bot."
            or "All clear. Tap + Add to write one here."
        local lines = wrap_n(m.body, msg, b.w, math.max(1, math.floor(b.h / m.body.line_height)))
        for i, l in ipairs(lines) do c:text(m.body, l, b.x, b.y + i * m.body.line_height - m.body.descent, 80) end
        return
    end
    local rh = m.body.line_height + m.px(10)
    local rows = math.floor(b.h / rh)
    local list = {}
    for _, it in ipairs(open) do list[#list + 1] = it end
    for _, it in ipairs(done) do list[#list + 1] = it end
    local more = #list - rows
    if more > 0 then rows = rows - 1 end
    local box_w = m.body:width(BOX) + m.px(12)
    for i = 1, math.min(rows, #list) do
        local it = list[i]
        local top = b.y + (i - 1) * rh
        local base = top + (rh + m.body.ascent - m.body.descent) / 2
        local color = it.done and 140 or 0
        c:text(m.body, it.done and CHECKED or BOX, b.x, base, color)
        local due = not it.done and todo:due_label(it)
        local dw = due and (m.small:width(due) + m.px(10)) or 0
        local font = it.done and m.body or m.body
        c:text(font, W.fit(font, it.text, b.w - box_w - dw), b.x + box_w, base, color)
        if it.done then
            local tw = math.min(font:width(it.text), b.w - box_w - dw)
            c:fill_rect(b.x + box_w, base - math.floor(font.ascent * 0.35), tw, m.hair, color)
        end
        if due then right(c, m.small, due, b.x + b.w, base, due == "overdue" and 0 or 90) end
        local id = it.id
        add_target(self, { x = r.x, y = top, w = r.w, h = rh }, function()
            todo:toggle(id)
            self.ui:set_dirty("partial")
        end)
    end
    if more > 0 then
        local base = b.y + rows * rh + (rh + m.small.ascent) / 2
        c:text(m.small, string.format("+%d more \226\128\186", more + 1), b.x + box_w, base, 70)
        add_target(self, { x = r.x, y = b.y + rows * rh, w = r.w, h = rh }, function() self.app:show_todo() end)
    end
end

function Dashboard:_calendar(c, m, r)
    local clock = self.app.clock
    local p = clock:parts()
    local b = self:card(c, m, r, clock.MONTHS[p.month] .. " " .. p.year)
    add_target(self, r, function() self.app:show_agenda() end)
    -- next events along the bottom, the month above them
    local ev_h = (m.body.line_height + m.px(4)) * 2 + m.px(12)
    self:_agenda_list(c, m, { x = b.x, y = b.y + b.h - ev_h + m.px(12), w = b.w, h = ev_h - m.px(12) })
    c:fill_rect(b.x, b.y + b.h - ev_h + m.px(2), b.w, m.hair, 200)
    b = { x = b.x, y = b.y, w = b.w, h = b.h - ev_h }
    local busy = {}
    for _, o in ipairs(self.app.data.calendar or {}) do busy[clock:day(o.start)] = true end
    local first = clock.days_from_civil(p.year, p.month, 1)
    local dim = clock.days_in_month(p.year, p.month)
    local lead = (first + 3) % 7 -- Monday first: 1970-01-01 was a Thursday
    local nrows = math.ceil((lead + dim) / 7)
    local cw = b.w / 7
    local head_h = m.small.line_height
    for i, d in ipairs({ "M", "T", "W", "T", "F", "S", "S" }) do
        c:text(m.small, d, b.x + (i - 0.5) * cw - m.small:width(d) / 2, b.y + m.small.ascent, 90)
    end
    local today = clock:day()
    -- small screens: show from this week on, as many weeks as fit
    local first_row = 0
    local min_rh = m.small.line_height + m.px(2)
    local fit = math.max(1, math.floor((b.h - head_h) / min_rh))
    if fit < nrows then
        first_row = math.min(math.floor((lead + p.day - 1) / 7), nrows - fit)
        nrows = fit
    end
    local rh = (b.h - head_h) / nrows
    local font = rh >= m.bodyb.line_height + m.px(6) and m.bodyb or m.small
    for dd = 1, dim do
        local cell = lead + dd - 1
        local row = math.floor(cell / 7) - first_row
        if row < 0 or row >= nrows then goto continue end
        local cx = b.x + (cell % 7 + 0.5) * cw
        local cy = b.y + head_h + (row + 0.5) * rh
        local s = tostring(dd)
        local day = first + dd - 1
        local base = cy + (font.ascent - font.descent) / 2 - m.px(2)
        if day == today then
            local rad = math.max(4, math.floor(math.min(cw, rh) / 2) - 1)
            for yy = -rad, rad do
                local half = math.floor(math.sqrt(rad * rad - yy * yy))
                c:fill_rect(cx - half, cy + yy - m.px(2), 2 * half, 1, 0)
            end
            c:text(font, s, cx - font:width(s) / 2, base, 255)
        else
            c:text(font, s, cx - font:width(s) / 2, base, day < today and 150 or 0)
        end
        if busy[day] and day ~= today then
            local dot = math.max(3, m.px(6))
            c:fill_rect(cx - dot / 2, math.min(base + m.px(5), cy + rh / 2 - dot), dot, dot, 0)
        end
        ::continue::
    end
end

--- Today's remaining events, then tomorrow's, in rect r (no card).
function Dashboard:_agenda_list(c, m, r)
    local clock, data = self.app.clock, self.app.data
    if not data.calendar_configured then
        c:text(m.small, W.fit(m.small, "Add Google Calendar in config.lua", r.w), r.x, r.y + m.small.ascent, 100)
        return
    end
    local now, today = clock:now(), clock:day()
    local items = {}
    for _, o in ipairs(data.calendar or {}) do
        local d = clock:day(o.start)
        if (d == today and (o.finish > now or o.all_day)) or (o.start < now and o.finish > now) then
            items[#items + 1] = { o = o, when = nil }
        elseif d == today + 1 then
            items[#items + 1] = { o = o, tomorrow = true }
        end
    end
    if #items == 0 then
        c:text(m.body, "Nothing else today or tomorrow", r.x, r.y + m.body.ascent, 100)
        return
    end
    local rh = m.body.line_height + m.px(4)
    local function label(it)
        local o = it.o
        local t = o.all_day and "All day" or (function() local hm, ap = clock:hm12(o.start); return hm .. " " .. ap end)()
        return it.tomorrow and ("Tmrw " .. t) or t
    end
    local tw = 0
    for _, it in ipairs(items) do tw = math.max(tw, m.bodyb:width(label(it))) end
    tw = tw + m.px(16)
    for i, it in ipairs(items) do
        local base = r.y + (i - 1) * rh + m.body.ascent
        if base + m.body.descent > r.y + r.h + m.px(4) then break end
        local o = it.o
        c:text(m.bodyb, label(it), r.x, base)
        c:text(m.body, W.fit(m.body, o.title, r.w - tw), r.x + tw, base)
    end
end

function Dashboard:status_text()
    local d, clock = self.app.data, self.app.clock
    local parts = {}
    local function at(t) local hm, ap = clock:hm12(t); return hm .. " " .. ap end
    if self.sleep_mode then
        parts[#parts + 1] = "Asleep" .. (d.last_ok and (" \194\183 updated " .. at(d.last_ok)) or "")
    elseif d.refreshing then
        parts[#parts + 1] = "Updating\226\128\166"
    elseif d.last_error and (not d.last_ok or (d.last_attempt or 0) > d.last_ok) then
        parts[#parts + 1] = "Offline" .. (d.last_ok and (" \194\183 updated " .. at(d.last_ok)) or "")
    elseif d.last_ok then
        parts[#parts + 1] = "Updated " .. at(d.last_ok)
    end
    local b = d.brief
    if b and b.date and b.date ~= clock:date_key() then
        local t = clock:parse_iso(b.date)
        parts[#parts + 1] = "news of " .. (t and clock:short_date(t + 6 * 3600) or b.date)
    end
    local bat = self.app.device:battery()
    if bat then parts[#parts + 1] = bat .. "%" end
    return table.concat(parts, DOT)
end

function Dashboard:_footer(c, m, top)
    local h = c.h - top
    local base = top + (h + m.body.ascent - m.body.descent) / 2
    local menu, refresh = "\226\152\176 Menu", "Refresh"
    if self.sleep_mode then menu, refresh = "", "" end
    c:text(m.bodyb, menu, m.pad, base)
    right(c, m.bodyb, refresh, c.w - m.pad, base)
    local left = m.pad + m.bodyb:width(menu) + m.px(20)
    local rgt = c.w - m.pad - m.bodyb:width(refresh) - m.px(20)
    local status = W.fit(m.small, self:status_text(), rgt - left)
    c:text(m.small, status, left + (rgt - left - m.small:width(status)) / 2, base, 60)
    add_target(self, { x = 0, y = top - m.px(6), w = left, h = h + m.px(6) }, function() self.app:show_menu() end)
    add_target(self, { x = rgt, y = top - m.px(6), w = c.w - rgt, h = h + m.px(6) }, function() self.app:refresh(true) end)
end

------------------------------------------------------------------------------
-- Layout
------------------------------------------------------------------------------

--- Card rectangles for the canvas size: { name = rect }, sections, footer.
function Dashboard:layout(c, m)
    local P, G = m.pad, m.gap
    local footer_h = m.body.line_height + m.px(22)
    local SL = m.section.line_height + m.px(10)
    local L = { footer = c.h - P - footer_h + m.px(8), sections = {} }
    local function rect(x, y, w, h) return { x = math.floor(x), y = math.floor(y), w = math.floor(w), h = math.floor(h) } end
    local function split(r, frac)
        local w1 = (r.w - G) * frac
        return rect(r.x, r.y, w1, r.h), rect(r.x + w1 + G, r.y, r.w - w1 - G, r.h)
    end
    local W_ = c.w - 2 * P
    local H = L.footer - m.px(8) - P
    if m.portrait then
        local avail = H - 2 * SL - 3 * G
        local h1, h2, h3 = avail * 0.215, avail * 0.29, avail * 0.20
        local h4 = avail - h1 - h2 - h3
        local y = P
        L.sections[#L.sections + 1] = { x = P, y = y, w = W_, title = "TODAY" }
        y = y + SL
        L.clock, L.weather = split(rect(P, y, W_, h1), 0.56)
        y = y + h1 + G
        L.todo, L.calendar = split(rect(P, y, W_, h2), 0.46)
        y = y + h2 + G
        L.sections[#L.sections + 1] = { x = P, y = y, w = W_, title = "READING" }
        y = y + SL
        L.reads = rect(P, y, W_, h3)
        y = y + h3 + G
        L.quote, L.news = split(rect(P, y, W_, h4), 0.46)
    else
        local lw = (W_ - 2 * G) * 0.5
        local rx, rw = P + lw + 2 * G, W_ - lw - 2 * G
        local avail = H - SL - G
        L.sections[#L.sections + 1] = { x = P, y = P, w = lw, title = "TODAY" }
        L.sections[#L.sections + 1] = { x = rx, y = P, w = rw, title = "READING" }
        local y = P + SL
        L.clock, L.weather = split(rect(P, y, lw, avail * 0.40), 0.56)
        L.todo, L.calendar = split(rect(P, y + avail * 0.40 + G, lw, avail * 0.60), 0.46)
        L.reads = rect(rx, y, rw, avail * 0.36)
        L.quote, L.news = split(rect(rx, y + avail * 0.36 + G, rw, avail * 0.64), 0.46)
    end
    return L
end

function Dashboard:draw(c)
    local m = self:metrics(c)
    self.targets = {}
    c:fill_rect(0, 0, c.w, c.h, 255)
    local L = self:layout(c, m)
    self.cards = {}
    for _, name in ipairs({ "clock", "weather", "todo", "calendar", "reads", "quote", "news" }) do
        self.cards[name] = L[name]
    end
    for _, sct in ipairs(L.sections) do self:section(c, m, sct.x, sct.y, sct.w, sct.title) end
    local function safe(fn, r)
        local ok, err = pcall(fn, self, c, m, r)
        if not ok then
            require("core.log").error("card failed:", err)
            c:text(m.small, "(could not draw this card)", r.x + m.inner, r.y + r.h / 2, 120)
        end
    end
    safe(self._clock, L.clock)
    safe(self._weather, L.weather)
    safe(self._todo, L.todo)
    safe(self._calendar, L.calendar)
    safe(self._reads, L.reads)
    safe(self._quote, L.quote)
    safe(self._news, L.news)
    self:_footer(c, m, L.footer)
end

function Dashboard:handle(ev)
    if ev.type == "tap" then
        -- later targets are more specific (rows inside cards): check them first
        for i = #self.targets, 1, -1 do
            local t = self.targets[i]
            if W.inside(ev, t.r) then t.fn(); return true end
        end
    elseif ev.type == "hold" then
        -- long-press a long read: mark it read
        for _, row in ipairs(self.read_rows or {}) do
            if W.inside(ev, row.r) then
                self.app.data:set_read(row.item, true)
                self.app:notify("Marked as read: " .. row.item.title, 1500)
                self.ui:set_dirty("partial")
                break
            end
        end
    elseif ev.type == "key" and ev.key == "menu" then
        self.app:show_menu()
    end
    return true
end

return Dashboard
