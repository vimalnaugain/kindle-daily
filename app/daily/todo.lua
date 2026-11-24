--[[
The to-do list, kept on the Kindle (data/todo.lua). Changed from Telegram
(daily/telegram.lua) or by tapping items on the dashboard.

Commands (Telegram messages, any case):
  buy milk                    add (any text that isn't a command)
  add buy milk / todo …       add
  call bank tomorrow          a trailing today / tomorrow / weekday sets a due day
  done 2 | done milk          tick off by number (as in `list`) or by words
  undo                        undo the last change
  del 2 | remove 2            delete
  list                        the open items, numbered
  clear done                  remove ticked-off items
  help
--]]
local util = require("core.util")

local Todo = {}
Todo.__index = Todo

local DONE_KEEP = 24 * 3600 -- ticked items stay visible for a day

function Todo.new(path, clock)
    local self = setmetatable({ path = path, clock = clock }, Todo)
    local t = util.load_table(path) or {}
    self.items = t.items or {}
    self.next_id = t.next_id or 1
    self.history = t.history or {}
    self.telegram = t.telegram or {} -- chat_id, chat_name, offset
    return self
end

function Todo:save()
    util.save_table(self.path, { items = self.items, next_id = self.next_id,
        history = self.history, telegram = self.telegram })
end

function Todo:_remember(op, item)
    self.history[#self.history + 1] = { op = op, item = util.deep_copy(item) }
    while #self.history > 30 do table.remove(self.history, 1) end
end

--- Open items first (oldest first), then items ticked off in the last day.
function Todo:open()
    local out = {}
    for _, it in ipairs(self.items) do if not it.done then out[#out + 1] = it end end
    return out
end

function Todo:recently_done()
    local now, out = self.clock:now(), {}
    for _, it in ipairs(self.items) do
        if it.done and now - (it.done_at or 0) < DONE_KEEP then out[#out + 1] = it end
    end
    return out
end

--- Drop ticked items older than a day (called on refresh).
function Todo:tidy()
    local now, keep = self.clock:now(), {}
    for _, it in ipairs(self.items) do
        if not (it.done and now - (it.done_at or 0) >= DONE_KEEP) then keep[#keep + 1] = it end
    end
    if #keep ~= #self.items then self.items = keep; self:save() end
end

function Todo:add(text, due)
    local it = { id = self.next_id, text = text, due = due, created = self.clock:now() }
    self.next_id = self.next_id + 1
    self.items[#self.items + 1] = it
    self:_remember("add", it)
    self:save()
    return it
end

function Todo:find(id)
    for i, it in ipairs(self.items) do if it.id == id then return it, i end end
end

function Todo:set_done(it, done)
    self:_remember("set", it)
    it.done = done or nil
    it.done_at = done and self.clock:now() or nil
    self:save()
end

function Todo:toggle(id)
    local it = self:find(id)
    if it then self:set_done(it, not it.done) end
    return it
end

function Todo:remove(it)
    local _, i = self:find(it.id)
    if not i then return end
    self:_remember("remove", it)
    table.remove(self.items, i)
    self:save()
end

function Todo:undo()
    local h = table.remove(self.history)
    if not h then return nil end
    local it, i = self:find(h.item.id)
    if h.op == "add" then
        if i then table.remove(self.items, i) end
    elseif h.op == "set" then
        if it then it.done, it.done_at = h.item.done, h.item.done_at end
    elseif h.op == "remove" then
        self.items[#self.items + 1] = h.item
        table.sort(self.items, function(a, b) return a.id < b.id end)
    end
    self:save()
    return h
end

------------------------------------------------------------------------------
-- Due days
------------------------------------------------------------------------------

local WEEKDAYS = { sunday = 0, sun = 0, monday = 1, mon = 1, tuesday = 2, tue = 2, tues = 2,
    wednesday = 3, wed = 3, thursday = 4, thu = 4, thurs = 4, friday = 5, fri = 5, saturday = 6, sat = 6 }

--- "call bank tomorrow" -> "call bank", due day number
function Todo:split_due(text)
    local today = self.clock:day()
    local body, word = text:match("^(.-)%s+(%a+)$")
    if not body or body == "" then return text end
    word = word:lower()
    if word == "today" or word == "tonight" then return body, today end
    if word == "tomorrow" or word == "tmrw" then return body, today + 1 end
    local wd = WEEKDAYS[word]
    if wd then
        local cur = (today + 4) % 7
        return body, today + (wd - cur) % 7
    end
    return text
end

--- "today", "tomorrow", "Fri 28", "overdue"
function Todo:due_label(it)
    if not it.due then return nil end
    local today = self.clock:day()
    if it.due < today then return "overdue" end
    if it.due == today then return "today" end
    if it.due == today + 1 then return "tomorrow" end
    local t = self.clock:day_start(it.due) + 43200
    return self.clock:weekday(t):sub(1, 3) .. " " .. self.clock:parts(t).day
end

------------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------------

function Todo:list_text()
    local open = self:open()
    if #open == 0 then return "Nothing on your list. Send me something to add." end
    local lines = { string.format("To-do (%d):", #open) }
    for i, it in ipairs(open) do
        local due = self:due_label(it)
        lines[#lines + 1] = string.format("%d. %s%s", i, it.text, due and (" (" .. due .. ")") or "")
    end
    return table.concat(lines, "\n")
end

local HELP = table.concat({
    "Send anything to add it to your list.",
    "  add buy milk  (or just: buy milk)",
    "  call bank tomorrow  (today, tomorrow or a weekday sets the day)",
    "  done 2  /  done milk",
    "  undo",
    "  del 2",
    "  list",
    "  clear done",
}, "\n")

--- Pick an open item by number or by words.
function Todo:pick(arg)
    local open = self:open()
    local n = tonumber(arg)
    if n then return open[n] end
    local q = arg:lower()
    for _, it in ipairs(open) do if it.text:lower():find(q, 1, true) then return it end end
end

--- Apply one message; returns the reply text.
function Todo:command(msg)
    local text = util.trim((msg or ""):gsub("^/", ""))
    if text == "" then return HELP end
    local word, rest = text:match("^(%S+)%s*(.*)$")
    local cmd = word:lower():gsub("@.*$", "")
    if cmd == "start" or cmd == "help" then return HELP end
    if cmd == "list" or cmd == "ls" or cmd == "todo" and rest == "" then return self:list_text() end
    if cmd == "undo" then
        local h = self:undo()
        if not h then return "Nothing to undo." end
        return "Undone. " .. self:list_text()
    end
    if (cmd == "clear" and rest:lower() == "done") or cmd == "cleardone" then
        local n = 0
        for i = #self.items, 1, -1 do
            if self.items[i].done then self:remove(self.items[i]); n = n + 1 end
        end
        return n == 0 and "No ticked-off items." or string.format("Cleared %d item%s.", n, n == 1 and "" or "s")
    end
    if cmd == "done" or cmd == "did" or cmd == "tick" or cmd == "check" then
        local it = rest ~= "" and self:pick(rest)
        if not it then return "Which one? Send `list` for the numbers." end
        self:set_done(it, true)
        return "\226\156\147 " .. it.text .. "\n\n" .. self:list_text()
    end
    if cmd == "del" or cmd == "delete" or cmd == "remove" or cmd == "rm" then
        local it = rest ~= "" and self:pick(rest)
        if not it then return "Which one? Send `list` for the numbers." end
        self:remove(it)
        return "Removed: " .. it.text
    end
    local body = text
    if cmd == "add" or cmd == "todo" then body = rest end
    if body == "" then return HELP end
    local what, due = self:split_due(body)
    local it = self:add(what, due)
    local label = self:due_label(it)
    return string.format("Added: %s%s (%d open)", it.text, label and (", " .. label) or "", #self:open())
end

return Todo
