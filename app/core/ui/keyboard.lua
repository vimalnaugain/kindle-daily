--[[
On-screen keyboard for short text: a title bar, the text being typed, a few
optional quick buttons (e.g. "Today", "Tomorrow"), and a QWERTY keyboard
with a numbers/symbols layer.

Keyboard.new{ title, text = "", hint, ok_text = "Add", chips = { {text=, insert=} },
              on_done = function(text) end, on_cancel = function() end }

Each key press redraws the screen: e-ink is slow, so keys are big and the
layout never moves.
--]]
local Font = require("core.font")
local W = require("core.ui.widgets")

local Keyboard = {}
Keyboard.__index = Keyboard

local SHIFT, BACK, SYM, ABC, SPACE, DONE = "\226\135\167", "\226\140\171", "123", "ABC", " ", "DONE"
-- ⇧ and ⌫ may be missing from the fonts: draw labels for them instead
local LABEL = { [SHIFT] = "Shift", [BACK] = "Del", [SPACE] = "space" }

local LETTERS = {
    { "q", "w", "e", "r", "t", "y", "u", "i", "o", "p" },
    { "a", "s", "d", "f", "g", "h", "j", "k", "l" },
    { SHIFT, "z", "x", "c", "v", "b", "n", "m", BACK },
    { SYM, ",", SPACE, ".", DONE },
}
local SYMBOLS = {
    { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" },
    { "-", "/", ":", ";", "(", ")", "\226\130\185", "&", "@" },
    { "#", "%", "'", "\"", "?", "!", "+", "=", BACK },
    { ABC, ",", SPACE, ".", DONE },
}
-- relative widths of the special keys
local WIDE = { [SHIFT] = 1.5, [BACK] = 1.5, [SYM] = 1.5, [ABC] = 1.5, [SPACE] = 5, [DONE] = 2 }

function Keyboard.new(opts)
    return setmetatable({ title = opts.title or "Type", text = opts.text or "", hint = opts.hint,
        ok_text = opts.ok_text or "Done", chips = opts.chips or {}, on_done = opts.on_done,
        on_cancel = opts.on_cancel, shift = true, layer = "letters", max_len = opts.max_len or 200,
        fullscreen = true, refresh_mode = "full", close_refresh = "full" }, Keyboard)
end

function Keyboard:_k(c)
    return c.h >= c.w and math.min(c.w / 1072, c.h / 1448) or math.min(c.w / 1448, c.h / 1072)
end

function Keyboard:draw(c)
    local k = self:_k(c)
    local function px(n) return math.max(1, math.floor(n * k + 0.5)) end
    local title_f = Font.get("sans", "b", px(34))
    local input_f = Font.get("sans", "r", px(40))
    local key_f = Font.get("sans", "r", px(40))
    local small_f = Font.get("sans", "b", px(28))
    local hint_f = Font.get("sans", "r", px(26))
    c:fill_rect(0, 0, c.w, c.h, 255)
    self.targets = {}
    local pad = px(36)

    -- title bar: [Cancel]  title  [Add]
    local bar_h = px(110)
    local base = (bar_h + title_f.ascent - title_f.descent) / 2
    c:text(title_f, self.title, (c.w - title_f:width(self.title)) / 2, base)
    c:text(small_f, "Cancel", pad, base)
    self.targets[#self.targets + 1] = { r = { x = 0, y = 0, w = pad * 2 + small_f:width("Cancel"), h = bar_h }, key = "cancel" }
    local ok_w = small_f:width(self.ok_text) + px(40)
    local ok_r = { x = c.w - pad - ok_w, y = px(22), w = ok_w, h = bar_h - px(44) }
    W.draw_button(c, ok_r, self.ok_text, small_f, true, px(3))
    self.targets[#self.targets + 1] = { r = { x = ok_r.x - px(20), y = 0, w = c.w - ok_r.x + px(20), h = bar_h }, key = DONE }
    c:fill_rect(0, bar_h - px(3), c.w, px(3), 0)

    -- the text, wrapped, with a cursor
    local y = bar_h + pad
    local box_h = input_f.line_height * 3 + px(30)
    c:rect(pad, y, c.w - 2 * pad, box_h, 0, px(3))
    local lines = W.wrap(input_f, self.text, c.w - 2 * pad - px(40))
    while #lines > 3 do table.remove(lines, 1) end
    if self.text == "" and self.hint then
        c:text(hint_f, W.fit(hint_f, self.hint, c.w - 2 * pad - px(40)), pad + px(20), y + px(15) + input_f.ascent, 140)
        c:fill_rect(pad + px(20), y + px(15), px(4), input_f.line_height, 0)
    else
        local ly = y + px(15)
        for i, l in ipairs(lines) do
            local x = c:text(input_f, l, pad + px(20), ly + input_f.ascent)
            if i == #lines then c:fill_rect(x + px(4), ly, px(4), input_f.line_height, 0) end
            ly = ly + input_f.line_height
        end
    end
    y = y + box_h + px(24)

    -- quick buttons
    if #self.chips > 0 then
        local x = pad
        local ch = px(76)
        for _, chip in ipairs(self.chips) do
            local w = small_f:width(chip.text) + px(48)
            local r = { x = x, y = y, w = w, h = ch }
            W.draw_button(c, r, chip.text, small_f, false, px(3))
            self.targets[#self.targets + 1] = { r = r, chip = chip }
            x = x + w + px(20)
        end
        y = y + ch + px(24)
    end

    -- keys, anchored to the bottom of the screen
    local rows = self.layer == "letters" and LETTERS or SYMBOLS
    local gap = px(10)
    local key_h = math.min(px(130), math.floor((c.h - y - pad) / #rows) - gap)
    local top = c.h - pad - #rows * (key_h + gap)
    for ri, row in ipairs(rows) do
        local units = 0
        for _, key in ipairs(row) do units = units + (WIDE[key] or 1) end
        local unit = (c.w - 2 * pad - (#row - 1) * gap) / math.max(units, 10)
        local row_w = units * unit + (#row - 1) * gap
        local x = pad + (c.w - 2 * pad - row_w) / 2
        local ky = top + (ri - 1) * (key_h + gap)
        for _, key in ipairs(row) do
            local w = (WIDE[key] or 1) * unit
            local r = { x = math.floor(x), y = math.floor(ky), w = math.floor(w), h = key_h }
            local label = LABEL[key] or (key == DONE and self.ok_text) or key
            if self.layer == "letters" and self.shift and #key == 1 then label = key:upper() end
            local special = key == SHIFT or key == BACK or key == SYM or key == ABC or key == DONE
            local inverted = key == DONE or (key == SHIFT and self.shift)
            local f = special and small_f or key_f
            c:fill_rect(r.x, r.y, r.w, r.h, inverted and 0 or (special and 225 or 255))
            c:rect(r.x, r.y, r.w, r.h, 0, px(2))
            c:text(f, label, r.x + (r.w - f:width(label)) / 2, r.y + (r.h + f.ascent - f.descent) / 2, inverted and 255 or 0)
            self.targets[#self.targets + 1] = { r = r, key = key }
            x = x + w + gap
        end
    end
end

function Keyboard:press(key)
    if key == "cancel" then
        self.ui:close(self)
        if self.on_cancel then self.on_cancel() end
    elseif key == DONE then
        local text = self.text:gsub("^%s+", ""):gsub("%s+$", "")
        self.ui:close(self)
        if text ~= "" and self.on_done then self.on_done(text) end
    elseif key == BACK then
        self.text = self.text:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
        if self.text == "" then self.shift = true end
    elseif key == SHIFT then
        self.shift = not self.shift
    elseif key == SYM then
        self.layer = "symbols"
    elseif key == ABC then
        self.layer = "letters"
    elseif #self.text < self.max_len then
        local ch = key
        if self.layer == "letters" and self.shift and #key == 1 then ch = key:upper() end
        self.text = self.text .. ch
        if self.layer == "letters" then self.shift = false end
        -- back to letters after a space or punctuation from the symbol layer
        if self.layer == "symbols" and (ch == " " or ch == "," or ch == ".") then self.layer = "letters" end
    end
    if self.ui then self.ui:set_dirty("partial") end
end

function Keyboard:handle(ev)
    if ev.type == "tap" then
        for _, t in ipairs(self.targets or {}) do
            if W.inside(ev, t.r) then
                if t.chip then
                    local s = self.text:gsub("%s+$", "")
                    self.text = (s == "" and "" or s .. " ") .. t.chip.insert
                    self.ui:set_dirty("partial")
                else
                    self:press(t.key)
                end
                return true
            end
        end
    elseif ev.type == "key" and ev.key == "back" then
        self:press("cancel")
    end
    return true
end

return Keyboard
