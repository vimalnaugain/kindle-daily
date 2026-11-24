--[[
Reads one story: headline, source and time, then the full text in a serif
face, page by page. The last page has a QR code for the original article
and a button to the next story in the category.
--]]
local Font = require("core.font")
local Layout = require("core.layout")
local W = require("core.ui.widgets")
local qr = require("core.qr")

local Article = {}
Article.__index = Article

local DOT = " \194\183 "
local SIZES = { s = 34, m = 40, l = 46 }

--- cat: category from the brief; index: story number in it.
--- opts.reads: these are long reads (adds "Mark as read" on the last page)
function Article.new(app, cat, index, opts)
    opts = opts or {}
    return setmetatable({ app = app, cat = cat, index = index, page = 1, reads = opts.reads,
        fullscreen = true, refresh_mode = "full", close_refresh = "full" }, Article)
end

function Article:story() return self.cat.stories[self.index] end

function Article:on_resize() self.pages = nil end

function Article:_k(c)
    local portrait = c.h >= c.w
    return portrait and math.min(c.w / 1072, c.h / 1448) or math.min(c.w / 1448, c.h / 1072)
end

function Article:_blocks()
    local s = self:story()
    local clock = self.app.clock
    local blocks = {}
    blocks[#blocks + 1] = { kind = "h", level = 1, runs = { { text = s.title or "", style = "b" } }, text = s.title or "" }
    local meta = { s.source }
    local t = clock:parse_iso(s.published)
    if t then meta[#meta + 1] = clock:short_date(t) .. ", " .. clock:hm(t) end
    local text = self.app.data and self.app.data.text_of and self.app.data:text_of(s) or s.text
    if text and (s.minutes or 0) > 0 then meta[#meta + 1] = s.minutes .. " min read" end
    if s.also_in and #s.also_in > 0 then
        local names = { unpack(s.also_in, 1, math.min(2, #s.also_in)) }
        local more = #s.also_in - #names
        meta[#meta + 1] = "also in " .. table.concat(names, ", ") .. (more > 0 and string.format(" and %d more", more) or "")
    end
    local m = table.concat(meta, DOT)
    blocks[#blocks + 1] = { kind = "p", runs = { { text = m, style = "i" } }, text = m }
    local body
    if text then
        body = text
    else
        local why = s.has_text
            and "The full text downloads at the next refresh when the Kindle is online."
            or "Only the headline and summary could be saved for this story."
        body = (s.summary ~= nil and s.summary ~= "" and (s.summary .. "\n\n") or "")
            .. "*" .. why .. " Scan the code on the last page to read it on your phone.*"
    end
    local function norm(x) return (x or ""):gsub("[%W_]+", ""):lower() end
    local title_key = norm(s.title)
    for _, b in ipairs(W.TextViewer.to_blocks(body)) do
        -- some sites repeat the headline inside the article: skip it
        if not (b.kind == "h" and norm(b.text) == title_key) then blocks[#blocks + 1] = b end
    end
    return blocks
end

function Article:_paginate(c)
    if self.pages then return self.pages end
    local k = self:_k(c)
    local px = function(n) return math.max(1, math.floor(n * k + 0.5)) end
    self.bar_h = px(110)
    local size = px(SIZES[self.app.settings.article_size or "m"] or 40)
    self.layout = Layout.new({
        width = c.w, height = c.h, margin_x = px(70), margin_top = self.bar_h + px(30),
        margin_bottom = self.bar_h + px(20), font_size = size, face = "serif",
        line_spacing = 1.3, justify = false, indent = false, paragraph_gap = 0.7,
    })
    local pages = self.layout:paginate({ blocks = self:_blocks() })
    pages[#pages + 1] = { qr_page = true }
    self.pages = pages
    self.page = math.min(self.page, #pages)
    return pages
end

function Article:_bar(c, k)
    local px = function(n) return math.max(1, math.floor(n * k + 0.5)) end
    local f = Font.get("sans", "b", px(30))
    local h = self.bar_h
    local base = (h + f.ascent - f.descent) / 2
    local x_label = "\195\151"
    local title = string.format("%s  \194\183  %d of %d", self.cat.title, self.index, #self.cat.stories)
    c:text(f, W.fit(f, title, c.w - h - px(70)), px(44), base)
    c:text(Font.get("sans", "b", px(46)), x_label, c.w - h / 2 - px(14), base + px(4))
    self.close_rect = { x = c.w - h - px(20), y = 0, w = h + px(20), h = h }
    c:fill_rect(0, h - px(3), c.w, px(3), 0)
end

function Article:_footer(c, k)
    local px = function(n) return math.max(1, math.floor(n * k + 0.5)) end
    local f = Font.get("sans", "r", px(26))
    local y = c.h - self.bar_h
    c:fill_rect(0, y, c.w, px(2), 0)
    local base = y + (self.bar_h + f.ascent - f.descent) / 2
    local label = string.format("%d / %d", self.page, #self.pages)
    c:text(f, label, (c.w - f:width(label)) / 2, base)
    if self.page > 1 then c:text(f, "\226\151\128 Back", px(44), base) end
    local right = self.page < #self.pages and "Next \226\150\182" or (self:_next() and (self.reads and "Next read \226\150\182" or "Next story \226\150\182") or "Done")
    c:text(Font.get("sans", "b", px(26)), right, c.w - px(44) - Font.get("sans", "b", px(26)):width(right), base)
end

function Article:_next()
    return self.cat.stories[self.index + 1] and self.index + 1 or nil
end

function Article:_draw_qr_page(c, k)
    local px = function(n) return math.max(1, math.floor(n * k + 0.5)) end
    local s = self:story()
    local h1 = Font.get("sans", "b", px(36))
    local small = Font.get("sans", "r", px(24))
    local y = self.bar_h + px(90)
    local msg = "Read the original on your phone"
    c:text(h1, msg, (c.w - h1:width(msg)) / 2, y)
    local ok, m = pcall(qr.encode, s.url or "")
    local size = px(420)
    if ok and m then
        qr.draw(c, m, math.floor((c.w - size) / 2), y + px(40), size)
    else
        local note = "Link too long for a QR code"
        c:text(small, note, (c.w - small:width(note)) / 2, y + px(200))
    end
    local yy = y + px(40) + size + px(60)
    for _, l in ipairs(W.wrap(small, s.url or "", c.w - px(160))) do
        c:text(small, l, (c.w - small:width(l)) / 2, yy, 70)
        yy = yy + small.line_height
    end
    self.read_rect = nil
    if self.reads then
        local read = self.app.data:is_read(s)
        local f = Font.get("sans", "b", px(30))
        local label = read and "\u{2713} Marked as read \u{00B7} tap to undo" or "\u{2713}  Mark as read"
        local bw = f:width(label) + px(80)
        local r = { x = math.floor((c.w - bw) / 2), y = yy + px(30), w = bw, h = px(90) }
        W.draw_button(c, r, label, f, not read, px(3))
        self.read_rect = r
        yy = r.y + r.h
    end
    local nxt = self:_next()
    if nxt then
        local f = Font.get("serif", "b", px(32))
        local label = Font.get("sans", "r", px(24))
        yy = yy + px(50)
        c:fill_rect(px(70), yy, c.w - px(140), px(2), 0)
        yy = yy + px(50)
        c:text(label, self.reads and "NEXT READ" or "NEXT STORY", px(70), yy, 70)
        yy = yy + f.line_height
        for i, l in ipairs(W.wrap(f, self.cat.stories[nxt].title or "", c.w - px(140))) do
            if i > 3 then break end
            c:text(f, l, px(70), yy)
            yy = yy + f.line_height
        end
    end
end

function Article:draw(c)
    local pages = self:_paginate(c)
    local k = self:_k(c)
    c:fill_rect(0, 0, c.w, c.h, 255)
    self:_bar(c, k)
    local p = pages[self.page]
    if p.qr_page then self:_draw_qr_page(c, k) else self.layout:draw(c, p) end
    self:_footer(c, k)
end

function Article:_turn(d)
    local n = self.pages and #self.pages or 1
    local p = self.page + d
    if p > n then
        local nxt = self:_next()
        if nxt then
            self.index, self.page, self.pages = nxt, 1, nil
            self.ui:set_dirty("full")
        else
            self.ui:close(self)
        end
        return
    end
    p = math.max(1, p)
    if p ~= self.page then self.page = p; self.ui:set_dirty("partial") end
end

function Article:handle(ev)
    if ev.type == "tap" then
        if self.close_rect and W.inside(ev, self.close_rect) then self.ui:close(self); return true end
        if self.read_rect and self.pages and self.pages[self.page] and self.pages[self.page].qr_page
            and W.inside(ev, self.read_rect) then
            local s = self:story()
            self.app.data:set_read(s, not self.app.data:is_read(s))
            self.ui:set_dirty("partial")
            return true
        end
        if ev.x < self.ui.device.width / 3 then self:_turn(-1) else self:_turn(1) end
    elseif ev.type == "swipe" then
        if ev.dir == "left" then self:_turn(1) elseif ev.dir == "right" then self:_turn(-1)
        elseif ev.dir == "down" then self.ui:close(self) end
    elseif ev.type == "key" then
        if ev.key == "next" or ev.key == "down" then self:_turn(1)
        elseif ev.key == "prev" or ev.key == "up" then self:_turn(-1)
        elseif ev.key == "back" or ev.key == "menu" then self.ui:close(self) end
    end
    return true
end

return Article
