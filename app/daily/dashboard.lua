--[[
The home screen:

  07:42                                   ☀ 24°
  Tuesday, 25 November              Haze · feels 26°
                                     ↑29° ↓15° · rain 10%
                                     AQI 212 · Very unhealthy
  ───────────────────────────────────────────────
  Nifty 50 25,349.65 ▼1.75%   Sensex 82,435.99 ▼1.77%   …
  ───────────────────────────────────────────────
  [ AI ][ Design ][ India ][ World ][ Stocks ]
  1  Headline that may wrap over two
     or three lines
     The Verge · 11 min · +2 sources
  2  …
  ───────────────────────────────────────────────
  ☰ Menu          Updated 07:40 · 87%          Refresh

Sizes scale with the screen, so it works from the 6" Basic to the Oasis.
--]]
local Font = require("core.font")
local W = require("core.ui.widgets")

local Dashboard = {}
Dashboard.__index = Dashboard

local DEG = "\194\176"
local DOT = " \194\183 "
local UP, DOWN = "\226\150\178", "\226\150\188" -- ▲ ▼

-- Short tab labels for the categories the morning job publishes.
local SHORT = { ai = "AI", content_design = "Design", india = "India", world = "World", markets = "Stocks" }

function Dashboard.new(app)
    return setmetatable({ app = app, fullscreen = true, refresh_mode = "full", targets = {} }, Dashboard)
end

function Dashboard:categories()
    local b = self.app.data.brief
    return b and b.categories or {}
end

function Dashboard:current_index()
    local cats = self:categories()
    local id = self.app.settings.tab
    for i, c in ipairs(cats) do if c.id == id then return i end end
    return 1
end

function Dashboard:select(i)
    local cats = self:categories()
    if #cats == 0 then return end
    i = ((i - 1) % #cats) + 1
    self.app.settings.tab = cats[i].id
    self.app:save_settings()
    self.ui:set_dirty("partial")
end

--- Fonts and spacing for the canvas size (designed at 1072x1448, 300 dpi).
function Dashboard:metrics(c)
    local portrait = c.h >= c.w
    local k = portrait and math.min(c.w / 1072, c.h / 1448) or math.min(c.w / 1448, c.h / 1072)
    local function px(n) return math.max(1, math.floor(n * k + 0.5)) end
    return {
        px = px,
        pad = px(44),
        clock = Font.get("sans", "b", px(128)),
        temp = Font.get("sans", "b", px(96)),
        icon = Font.get("sans", "r", px(64)),
        h1 = Font.get("sans", "b", px(36)),
        body = Font.get("sans", "r", px(28)),
        bodyb = Font.get("sans", "b", px(28)),
        small = Font.get("sans", "r", px(24)),
        tab = Font.get("sans", "b", px(28)),
        num = Font.get("sans", "b", px(40)),
        headline = Font.get("serif", "b", px(34)),
        line = math.max(2, px(3)),
        hair = math.max(1, px(1.5)),
    }
end

local function right_text(c, font, s, xr, y, color)
    c:text(font, s, xr - font:width(s), y, color)
end

local function fmt_num(x)
    local s = string.format("%.2f", x)
    local int, frac = s:match("^(%-?%d+)(%.%d+)$")
    int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^(%-?),", "%1")
    return int .. frac
end

local function change(q)
    local pct = q.change_pct or 0
    return string.format("%s%.2f%%", pct >= 0 and UP or DOWN, math.abs(pct))
end

------------------------------------------------------------------------------

function Dashboard:_header(c, m, y)
    local app = self.app
    local clock = app.clock
    local pad = m.pad
    -- left: time and date (asleep: the day of the month instead of the time)
    local big = self.sleep_mode and tostring(clock:parts().day) or clock:hm()
    local base = y + m.clock.ascent
    c:text(m.clock, big, pad, base)
    local date_y = base + m.h1.line_height + m.px(8)
    local date = self.sleep_mode and (clock:weekday() .. ", " .. clock.MONTHS[clock:parts().month])
        or (clock:weekday() .. ", " .. clock:day_month())
    c:text(m.h1, date, pad, date_y)
    local left_w = math.max(m.clock:width(big), m.h1:width(date))
    local bottom = date_y + m.h1.descent

    -- right: weather
    local w = app.data.weather
    local xr = c.w - pad
    local maxw = c.w - 2 * pad - left_w - m.px(40)
    local ry = base
    if w and w.temp then
        local t = w.temp .. DEG
        local tw = m.temp:width(t)
        c:text(m.temp, t, xr - tw, ry)
        local iw = m.icon:width(w.icon or "")
        c:text(m.icon, w.icon or "", xr - tw - m.px(16) - iw, ry - m.px(10))
        local lines = {}
        lines[#lines + 1] = { m.body, w.label .. (w.feels and (DOT .. "feels " .. w.feels .. DEG) or "") }
        local l2 = (w.max and w.min) and string.format("%s%d%s %s%d%s", "\226\134\145", w.max, DEG, "\226\134\147", w.min, DEG) or ""
        if w.rain_from then l2 = l2 .. DOT .. string.format("rain from %02d:00", w.rain_from)
        elseif (w.rain or 0) > 0 then l2 = l2 .. DOT .. "rain " .. w.rain .. "%" end
        lines[#lines + 1] = { m.body, l2 }
        if w.aqi then
            lines[#lines + 1] = { w.aqi > 150 and m.bodyb or m.body, "AQI " .. w.aqi .. DOT .. (w.aqi_label or "") }
        end
        for _, l in ipairs(lines) do
            ry = ry + l[1].line_height
            right_text(c, l[1], W.fit(l[1], l[2], maxw), xr, ry)
        end
    else
        ry = ry + m.body.line_height
        right_text(c, m.small, W.fit(m.small, "Weather loads when online", maxw), xr, ry)
    end
    self.targets.weather = { x = c.w - pad - maxw, y = y, w = maxw + pad, h = ry - y + m.px(10) }
    return math.max(bottom, ry + m.body.descent) + m.px(24)
end

function Dashboard:_markets(c, m, y)
    local mk = self.app.data.brief and self.app.data.brief.markets
    if not (mk and mk.indices and #mk.indices > 0) then return y end
    local h = m.body.line_height + m.px(28)
    local function render(short)
        local parts = {}
        for _, ix in ipairs(mk.indices) do
            local name = short and (ix.name:gsub("^Nifty 50$", "Nifty"):gsub("^Nifty Bank$", "Bank")) or ix.name
            local price = short and (fmt_num(math.floor(ix.price + 0.5)):gsub("%.%d+$", "")) or fmt_num(ix.price)
            parts[#parts + 1] = { name .. " ", price .. " ", change(ix) }
        end
        return parts
    end
    local avail = c.w - 2 * m.pad - m.px(30)
    local gap = m.px(36)
    local parts
    for _, short in ipairs({ false, true }) do
        parts = render(short)
        local total = 0
        for _, p in ipairs(parts) do total = total + m.small:width(p[1]) + m.bodyb:width(p[2]) + m.body:width(p[3]) + gap end
        if total - gap <= avail then break end
    end
    local x, base = m.pad, y + (h + m.body.ascent - m.body.descent) / 2
    for _, p in ipairs(parts) do
        if x > c.w - m.pad - m.px(60) then break end
        x = c:text(m.small, p[1], x, base)
        x = c:text(m.bodyb, p[2], x, base)
        x = c:text(m.body, p[3], x, base) + gap
    end
    right_text(c, m.h1, "\226\128\186", c.w - m.pad, base) -- ›
    self.targets.markets = { x = 0, y = y, w = c.w, h = h }
    c:fill_rect(m.pad, y + h, c.w - 2 * m.pad, m.hair, 0)
    return y + h + m.hair
end

function Dashboard:_tabs(c, m, y)
    local cats = self:categories()
    if #cats == 0 then return y end
    local cur = self:current_index()
    local h = m.tab.line_height + m.px(34)
    local x0, wtot = m.pad, c.w - 2 * m.pad
    self.targets.tabs = {}
    for i, cat in ipairs(cats) do
        local x1 = x0 + math.floor((i - 1) * wtot / #cats)
        local x2 = x0 + math.floor(i * wtot / #cats)
        local label = W.fit(m.tab, cat.short or SHORT[cat.id] or cat.title, x2 - x1 - m.px(12))
        local base = y + (h + m.tab.ascent - m.tab.descent) / 2
        if i == cur then
            c:fill_rect(x1, y, x2 - x1, h, 0)
            c:text(m.tab, label, x1 + (x2 - x1 - m.tab:width(label)) / 2, base, 255)
        else
            c:rect(x1, y, x2 - x1, h, 0, m.hair)
            c:text(m.tab, label, x1 + (x2 - x1 - m.tab:width(label)) / 2, base, 0)
        end
        self.targets.tabs[i] = { x = x1, y = y, w = x2 - x1, h = h }
    end
    return y + h + m.px(18)
end

function Dashboard:_stories(c, m, y, bottom)
    local cats = self:categories()
    self.targets.stories = {}
    if #cats == 0 then
        local msg = "No news yet. The morning edition downloads automatically when the Kindle is on Wi-Fi."
        local lines = W.wrap(m.body, msg, c.w - 4 * m.pad)
        local yy = y + (bottom - y) / 3
        for _, l in ipairs(lines) do
            c:text(m.body, l, (c.w - m.body:width(l)) / 2, yy)
            yy = yy + m.body.line_height
        end
        return
    end
    local cat = cats[self:current_index()]
    local stories = cat.stories or {}
    local slots = math.max(5, #stories)
    local item_h = math.floor((bottom - y) / slots)
    local num_w = m.num:width("5") + m.px(26)
    local text_x = m.pad + num_w
    local text_w = c.w - text_x - m.pad
    local meta_h = m.small.line_height
    local max_lines = math.max(1, math.min(4, math.floor((item_h - meta_h - m.px(26)) / m.headline.line_height)))
    for i, s in ipairs(stories) do
        local top = y + (i - 1) * item_h
        local lines = W.wrap(m.headline, s.title or "", text_w)
        if #lines > max_lines then
            local keep = {}
            for j = 1, max_lines - 1 do keep[j] = lines[j] end
            keep[max_lines] = W.fit(m.headline, table.concat(lines, " ", max_lines), text_w)
            lines = keep
        end
        local block_h = #lines * m.headline.line_height + meta_h
        local yy = top + math.floor((item_h - block_h) / 2) + m.headline.ascent
        c:text(m.num, tostring(i), m.pad, yy + (m.num.ascent - m.headline.ascent) / 2)
        for _, l in ipairs(lines) do
            c:text(m.headline, l, text_x, yy)
            yy = yy + m.headline.line_height
        end
        local meta = { s.source }
        if s.text and s.minutes and s.minutes > 0 then meta[#meta + 1] = s.minutes .. " min read"
        else meta[#meta + 1] = "summary only" end
        if s.also_in and #s.also_in > 0 then
            meta[#meta + 1] = string.format("+%d source%s", #s.also_in, #s.also_in > 1 and "s" or "")
        end
        c:text(m.small, W.fit(m.small, table.concat(meta, DOT), text_w), text_x, yy - m.headline.descent + m.px(6), 90)
        if i < #stories then c:fill_rect(text_x, top + item_h - 1, text_w, m.hair, 170) end
        self.targets.stories[i] = { x = 0, y = top, w = c.w, h = item_h }
    end
end

function Dashboard:status_text()
    local app, d, clock = self.app, self.app.data, self.app.clock
    local parts = {}
    if self.sleep_mode then
        parts[#parts + 1] = "Asleep" .. (d.last_ok and (" \194\183 updated " .. clock:hm(d.last_ok)) or "")
    elseif d.refreshing then
        parts[#parts + 1] = "Updating\226\128\166"
    elseif d.last_error and (not d.last_ok or d.last_attempt > d.last_ok) then
        parts[#parts + 1] = "Offline" .. (d.last_ok and (" \194\183 updated " .. clock:hm(d.last_ok)) or "")
    elseif d.last_ok then
        parts[#parts + 1] = "Updated " .. clock:hm(d.last_ok)
    end
    local b = d.brief
    if b and b.date and b.date ~= clock:date_key() then
        local t = clock:parse_iso(b.date)
        parts[#parts + 1] = "news of " .. (t and clock:short_date(t + 6 * 3600) or b.date)
    end
    local bat = app.device:battery()
    if bat then parts[#parts + 1] = bat .. "%" end
    return table.concat(parts, DOT)
end

function Dashboard:_footer(c, m, top)
    c:fill_rect(0, top, c.w, m.line, 0)
    local h = c.h - top
    local base = top + (h + m.body.ascent - m.body.descent) / 2
    local menu, refresh = "\226\152\176 Menu", "Refresh"
    if self.sleep_mode then menu, refresh = "", "" end
    c:text(m.bodyb, menu, m.pad, base)
    right_text(c, m.bodyb, refresh, c.w - m.pad, base)
    local left = m.pad + m.bodyb:width(menu) + m.px(20)
    local right = c.w - m.pad - m.bodyb:width(refresh) - m.px(20)
    local status = W.fit(m.small, self:status_text(), right - left)
    c:text(m.small, status, left + (right - left - m.small:width(status)) / 2, base, 60)
    self.targets.menu = { x = 0, y = top, w = left, h = h }
    self.targets.refresh = { x = right, y = top, w = c.w - right, h = h }
end

function Dashboard:draw(c)
    local m = self:metrics(c)
    self.targets = {}
    c:fill_rect(0, 0, c.w, c.h, 255)
    local y = self:_header(c, m, m.pad)
    c:fill_rect(0, y, c.w, m.line, 0)
    y = self:_markets(c, m, y + m.line)
    y = self:_tabs(c, m, y + m.px(22))
    local footer_h = m.body.line_height + m.px(40)
    self:_stories(c, m, y, c.h - footer_h - m.px(6))
    self:_footer(c, m, c.h - footer_h)
end

function Dashboard:handle(ev)
    local t = self.targets
    if ev.type == "tap" then
        local function hit(r) return r and W.inside(ev, r) end
        if hit(t.menu) then self.app:show_menu(); return true end
        if hit(t.refresh) then self.app:refresh(true); return true end
        for i, r in ipairs(t.tabs or {}) do
            if hit(r) then if i ~= self:current_index() then self:select(i) end; return true end
        end
        for i, r in ipairs(t.stories or {}) do
            if hit(r) then self.app:open_story(self:current_index(), i); return true end
        end
        if hit(t.markets) then self.app:show_markets(); return true end
        if hit(t.weather) then self.app:show_weather(); return true end
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
