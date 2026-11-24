--[[
The home screen: a grid of cards.

  ┌──────────────────────────┬───────────────────┐
  │ 2:12 PM                  │ 26°            ☁  │
  │ TUESDAY                  │ PARTLY CLOUDY     │
  │ 24 NOVEMBER 2026         │ feels 25° ↑27 ↓12 │
  │ day ▓▓▓▓░░ month ▓▓▓▓▓░  │ AQI 212 …         │
  ├──────────────────────────┴───────────────────┤
  │ NEWS  [AI][Design][India][World][Stocks]     │
  │ 1 Headline …                                 │
  │ Nifty 25,350 ▼1.75%  Sensex …              › │
  ├──────────────────────────┬───────────────────┤
  │ ARTICLE OF THE DAY       │ TO-DO · 3 LEFT    │
  ├──────────────────────────┼───────────────────┤
  │ NOVEMBER 2026 (month)    │ TODAY (agenda)    │
  └──────────────────────────┴───────────────────┘
  ☰ Menu        Updated 2:12 PM · 87%      Refresh

Landscape puts the cards in two columns. Everything scales with the screen.
--]]
local Font = require("core.font")
local W = require("core.ui.widgets")

local Dashboard = {}
Dashboard.__index = Dashboard

local DEG = "\194\176"
local DOT = " \194\183 "
local UP, DOWN = "\226\150\178", "\226\150\188" -- ▲ ▼
local BOX, CHECKED = "\226\152\144", "\226\152\145" -- ☐ ☑

local SHORT = { ai = "AI", content_design = "Design", india = "India", world = "World", markets = "Stocks" }

function Dashboard.new(app)
    return setmetatable({ app = app, fullscreen = true, refresh_mode = "full", targets = {} }, Dashboard)
end

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------

function Dashboard:categories()
    local b = self.app.data.brief
    return b and b.categories or {}
end

function Dashboard:current_index()
    local id = self.app.settings.tab
    for i, c in ipairs(self:categories()) do if c.id == id then return i end end
    return 1
end

function Dashboard:select(i)
    local cats = self:categories()
    if #cats == 0 then return end
    self.app.settings.tab = cats[((i - 1) % #cats) + 1].id
    self.app:save_settings()
    self.ui:set_dirty("partial")
end

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
        pad = px(22), gap = px(14), inner = px(20),
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
    }
end

--- Card frame with a small upper-case label. Returns the content rect.
function Dashboard:card(c, m, r, label, label_right)
    c:rect(r.x, r.y, r.w, r.h, 0, m.border)
    local x, y, w = r.x + m.inner, r.y + m.inner, r.w - 2 * m.inner
    if label then
        local base = y + m.label.ascent
        c:text(m.label, label:upper(), x, base, 60)
        if label_right then right(c, m.label, label_right, x + w, base, 60) end
        y = y + m.label.line_height + m.px(10)
    end
    return { x = x, y = y, w = w, h = r.y + r.h - m.inner - y }
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
    local big = (b.h >= m.px(300)) and m.clock or m.big
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

function Dashboard:_markets_line(c, m, x, y, w)
    local mk = self.app.data.brief and self.app.data.brief.markets
    if not (mk and mk.indices and #mk.indices > 0) then return 0 end
    local h = m.body.line_height + m.px(10)
    local base = y + m.body.ascent + m.px(4)
    local gap = m.px(26)
    local cx = x
    for _, ix in ipairs(mk.indices) do
        local name = ix.name:gsub("^Nifty 50$", "Nifty"):gsub("^Nifty Bank$", "Bank")
        local pct = ix.change_pct or 0
        local parts = { { m.small, name .. " " }, { m.bodyb, fmt_num(ix.price, 0) .. " " },
            { m.body, string.format("%s%.2f%%", pct >= 0 and UP or DOWN, math.abs(pct)) } }
        local need = 0
        for _, p in ipairs(parts) do need = need + p[1]:width(p[2]) end
        if cx + need > x + w - m.px(30) then break end
        for _, p in ipairs(parts) do cx = c:text(p[1], p[2], cx, base) end
        cx = cx + gap
    end
    right(c, m.h2, "\226\128\186", x + w, base)
    add_target(self, { x = x - m.inner, y = y - m.px(6), w = w + 2 * m.inner, h = h + m.px(12) },
        function() self.app:show_markets() end)
    return h
end

function Dashboard:_news(c, m, r)
    local cats = self:categories()
    c:rect(r.x, r.y, r.w, r.h, 0, m.border)
    local x, w = r.x + m.inner, r.w - 2 * m.inner
    local y = r.y + m.inner
    -- label and tabs
    local lab = "NEWS"
    c:text(m.label, lab, x, y + (m.px(44) + m.label.ascent - m.label.descent) / 2, 60)
    local tx = x + m.label:width(lab) + m.px(20)
    local th = m.px(44)
    if #cats > 0 then
        local cur = self:current_index()
        local tw = (x + w - tx) / #cats
        for i, cat in ipairs(cats) do
            local x1, x2 = math.floor(tx + (i - 1) * tw), math.floor(tx + i * tw)
            local label = W.fit(m.bodyb, cat.short or SHORT[cat.id] or cat.title, x2 - x1 - m.px(8))
            local base = y + (th + m.bodyb.ascent - m.bodyb.descent) / 2
            if i == cur then
                c:fill_rect(x1, y, x2 - x1, th, 0)
                c:text(m.bodyb, label, x1 + (x2 - x1 - m.bodyb:width(label)) / 2, base, 255)
            else
                c:rect(x1, y, x2 - x1, th, 0, m.hair)
                c:text(m.bodyb, label, x1 + (x2 - x1 - m.bodyb:width(label)) / 2, base, 0)
            end
            add_target(self, { x = x1, y = y - m.px(8), w = x2 - x1, h = th + m.px(16) }, function()
                if i ~= self:current_index() then self:select(i) end
            end)
        end
    end
    y = y + th + m.px(14)
    -- markets along the bottom
    local bottom = r.y + r.h - m.inner
    local mh = m.body.line_height + m.px(10)
    local has_markets = self.app.data.brief and self.app.data.brief.markets
        and self.app.data.brief.markets.indices and #self.app.data.brief.markets.indices > 0
    if has_markets then
        bottom = bottom - mh - m.px(8)
        c:fill_rect(x, bottom + m.px(4), w, m.hair, 0)
        self:_markets_line(c, m, x, bottom + m.px(10), w)
    end
    if #cats == 0 then
        local lines = wrap_n(m.body, "No news yet. The morning edition downloads when the Kindle is on Wi-Fi.", w, 3)
        for i, l in ipairs(lines) do c:text(m.body, l, x, y + i * m.body.line_height, 80) end
        return
    end
    local stories = cats[self:current_index()].stories or {}
    local num_w = m.h2:width("5") + m.px(18)
    local text_w = w - num_w
    for i, s in ipairs(stories) do
        local lines = wrap_n(m.headline, s.title, text_w, 2)
        local need = #lines * m.headline.line_height + m.small.line_height + m.px(8)
        if y + need > bottom then
            -- one line left? squeeze the headline into it
            lines = { W.fit(m.headline, s.title, text_w) }
            need = m.headline.line_height + m.small.line_height + m.px(8)
            if y + need > bottom then break end
        end
        local top = y
        local base = y + m.headline.ascent
        c:text(m.h2, tostring(i), x, base)
        for _, l in ipairs(lines) do
            c:text(m.headline, l, x + num_w, base)
            base = base + m.headline.line_height
        end
        local meta = { s.source }
        meta[#meta + 1] = (s.text and (s.minutes or 0) > 0) and (s.minutes .. " min read") or "summary only"
        if s.also_in and #s.also_in > 0 then meta[#meta + 1] = string.format("+%d", #s.also_in) end
        c:text(m.small, W.fit(m.small, table.concat(meta, DOT), text_w), x + num_w,
            base - m.headline.ascent + m.small.ascent - m.px(2), 90)
        y = top + need
        local idx = i
        add_target(self, { x = r.x, y = top - m.px(4), w = r.w, h = need },
            function() self.app:open_story(self:current_index(), idx) end)
    end
end

function Dashboard:_article(c, m, r)
    local a = self.app.data.brief and self.app.data.brief.article
    local b = self:card(c, m, r, "Article of the day", a and a.source and a.source:upper() or nil)
    if not a then
        local lines = wrap_n(m.body, "A free long read arrives with each morning's edition.", b.w, 3)
        for i, l in ipairs(lines) do c:text(m.body, l, b.x, b.y + i * m.body.line_height, 80) end
        return
    end
    add_target(self, r, function() self.app:open_article_of_the_day() end)
    local bottom = b.y + b.h
    local foot = (a.text and a.minutes and a.minutes > 0) and (a.minutes .. " min read \226\128\186") or "Read \226\128\186"
    bottom = bottom - m.small.line_height
    right(c, m.bodyb, foot, b.x + b.w, b.y + b.h - m.px(2))
    local y = b.y
    for _, l in ipairs(wrap_n(m.title, a.title, b.w, 2)) do
        y = y + m.title.line_height
        c:text(m.title, l, b.x, y - m.title.descent)
    end
    if a.description and a.description ~= "" then
        y = y + m.italic.line_height
        c:text(m.italic, W.fit(m.italic, a.description, b.w), b.x, y - m.italic.descent, 50)
    end
    y = y + m.px(8)
    local n = math.floor((bottom - y) / m.serif.line_height)
    if n > 0 then
        for _, l in ipairs(wrap_n(m.serif, a.summary or "", b.w, n)) do
            y = y + m.serif.line_height
            c:text(m.serif, l, b.x, y - m.serif.descent)
        end
    end
end

function Dashboard:_todo(c, m, r)
    local todo = self.app.todo
    local open, done = todo:open(), todo:recently_done()
    local b = self:card(c, m, r, "To-do", #open > 0 and (#open .. " LEFT") or nil)
    add_target(self, { x = r.x, y = r.y, w = r.w, h = b.y - r.y }, function() self.app:show_todo() end)
    if #open == 0 and #done == 0 then
        local msg = self.app.telegram and "All clear. Message your Telegram bot to add something."
            or "Add telegram_token to config.lua to send to-dos from your phone."
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

function Dashboard:_month(c, m, r)
    local clock = self.app.clock
    local p = clock:parts()
    local b = self:card(c, m, r, clock.MONTHS[p.month] .. " " .. p.year)
    add_target(self, r, function() self.app:show_agenda() end)
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

function Dashboard:_agenda(c, m, r)
    local clock, data = self.app.clock, self.app.data
    local b = self:card(c, m, r, "Today", data.calendar_configured and clock:short_date():upper() or nil)
    add_target(self, r, function() self.app:show_agenda() end)
    if not data.calendar_configured then
        local lines = wrap_n(m.body, "Add your Google Calendar's secret iCal address to config.lua (calendar_url).",
            b.w, math.max(1, math.floor(b.h / m.body.line_height)))
        for i, l in ipairs(lines) do c:text(m.body, l, b.x, b.y + i * m.body.line_height - m.body.descent, 80) end
        return
    end
    local now, today = clock:now(), clock:day()
    local items = {}
    local tomorrow_header = false
    for _, o in ipairs(data.calendar or {}) do
        local d = clock:day(o.start)
        local ongoing = o.start < now and o.finish > now
        if (d == today and (o.finish > now or o.all_day)) or ongoing then
            items[#items + 1] = o
        elseif d == today + 1 then
            if not tomorrow_header then items[#items + 1] = { header = "TOMORROW" }; tomorrow_header = true end
            items[#items + 1] = o
        end
    end
    if #items == 0 or items[1].header then
        table.insert(items, 1, { note = "Nothing else today" })
    end
    local rh = m.body.line_height + m.px(6)
    local y = b.y
    local tw = m.bodyb:width("10:30 PM") + m.px(14)
    for _, it in ipairs(items) do
        if y + rh > b.y + b.h + m.px(4) then break end
        local base = y + m.body.ascent
        if it.header then
            c:text(m.label, it.header, b.x, base, 60)
        elseif it.note then
            c:text(m.body, it.note, b.x, base, 100)
        else
            local t
            if it.all_day then t = "All day" else
                local hm, ampm = clock:hm12(it.start)
                t = hm .. " " .. ampm
            end
            c:text(m.bodyb, t, b.x, base)
            c:text(m.body, W.fit(m.body, it.title, b.w - tw), b.x + tw, base)
        end
        y = y + rh
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

--- Card rectangles for the canvas size.
function Dashboard:layout(c, m)
    local P, G = m.pad, m.gap
    local footer_h = m.body.line_height + m.px(22)
    local W_, H = c.w - 2 * P, c.h - 2 * P - footer_h
    local L = { footer = c.h - P - footer_h + m.px(8) }
    local function rect(x, y, w, h) return { x = math.floor(x), y = math.floor(y), w = math.floor(w), h = math.floor(h) } end
    if m.portrait then
        local avail = H - 4 * G
        local h1, h2, h3 = avail * 0.245, avail * 0.30, avail * 0.215
        local h4 = avail - h1 - h2 - h3
        local y = P
        local split = W_ * 0.56
        L.clock = rect(P, y, split - G / 2, h1)
        L.weather = rect(P + split + G / 2, y, W_ - split - G / 2, h1)
        y = y + h1 + G
        L.news = rect(P, y, W_, h2)
        y = y + h2 + G
        L.article = rect(P, y, split - G / 2, h3)
        L.todo = rect(P + split + G / 2, y, W_ - split - G / 2, h3)
        y = y + h3 + G
        L.month = rect(P, y, split - G / 2, h4)
        L.agenda = rect(P + split + G / 2, y, W_ - split - G / 2, h4)
    else
        local lw = W_ * 0.40
        local rx, rw = P + lw + G, W_ - lw - G
        local avail = H - 2 * G
        L.clock = rect(P, P, lw, avail * 0.33)
        L.weather = rect(P, P + avail * 0.33 + G, lw, avail * 0.27)
        L.month = rect(P, P + avail * 0.60 + 2 * G, lw, avail * 0.40)
        L.news = rect(rx, P, rw, avail * 0.46)
        local y = P + avail * 0.46 + G
        L.article = rect(rx, y, rw * 0.55 - G / 2, avail * 0.30)
        L.todo = rect(rx + rw * 0.55 + G / 2, y, rw * 0.45 - G / 2, avail * 0.30)
        L.agenda = rect(rx, y + avail * 0.30 + G, rw, avail * 0.24)
    end
    return L
end

function Dashboard:draw(c)
    local m = self:metrics(c)
    self.targets = {}
    c:fill_rect(0, 0, c.w, c.h, 255)
    local L = self:layout(c, m)
    self.cards = L
    local function safe(fn, r)
        local ok, err = pcall(fn, self, c, m, r)
        if not ok then
            require("core.log").error("card failed:", err)
            c:text(m.small, "(could not draw this card)", r.x + m.inner, r.y + r.h / 2, 120)
        end
    end
    safe(self._clock, L.clock)
    safe(self._weather, L.weather)
    safe(self._news, L.news)
    safe(self._article, L.article)
    safe(self._todo, L.todo)
    safe(self._month, L.month)
    safe(self._agenda, L.agenda)
    self:_footer(c, m, L.footer)
end

function Dashboard:handle(ev)
    if ev.type == "tap" then
        -- later targets are more specific (rows inside cards): check them first
        for i = #self.targets, 1, -1 do
            local t = self.targets[i]
            if W.inside(ev, t.r) then t.fn(); return true end
        end
    elseif ev.type == "swipe" then
        if ev.dir == "left" then self:select(self:current_index() + 1)
        elseif ev.dir == "right" then self:select(self:current_index() - 1) end
    elseif ev.type == "key" then
        if ev.key == "next" then self:select(self:current_index() + 1)
        elseif ev.key == "prev" then self:select(self:current_index() - 1)
        elseif ev.key == "menu" then self.app:show_menu() end
    end
    return true
end

return Dashboard
