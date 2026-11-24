--[[
Your Telegram bot as the to-do list's remote control. The Kindle asks
Telegram for new messages (getUpdates) when it wakes and every couple of
minutes while it's on, and answers each one (sendMessage). No server needed.

The bot token lives in /mnt/us/daily/config.lua (telegram_token = "...").
The first chat that messages the bot has to be confirmed on the Kindle;
after that, messages from anyone else are ignored.
--]]
local json = require("core.json")
local log = require("core.log")

local Telegram = {}
Telegram.__index = Telegram

local API = "https://api.telegram.org/bot%s/%s"

function Telegram.new(app, token)
    return setmetatable({ app = app, token = token }, Telegram)
end

function Telegram:url(method, query)
    local base = (self.app.config.telegram_api or API):format(self.token, method)
    return query and (base .. "?" .. query) or base
end

function Telegram:send(chat_id, text)
    local res, err = self.app.http:request({ url = self:url("sendMessage"), method = "POST", timeout = 30,
        body = { chat_id = chat_id, text = text, disable_web_page_preview = true } })
    if not res or res.status ~= 200 then log.warn("telegram send failed:", err or (res and res.status)) end
end

--- Fetch and handle new messages. Inside a UI task.
-- Returns number of changes, or nil + error.
function Telegram:poll()
    local todo = self.app.todo
    local tg = todo.telegram
    local q = "timeout=0&allowed_updates=%5B%22message%22%5D"
    if tg.offset then q = q .. "&offset=" .. tg.offset end
    local res, err = self.app.http:request({ url = self:url("getUpdates", q), method = "GET", timeout = 30 })
    if not res then return nil, err end
    local j = res.json
    if res.status == 401 or res.status == 404 then return nil, "Telegram rejected the bot token" end
    if not (j and j.ok == true and type(j.result) == "table") then return nil, "Telegram: HTTP " .. tostring(res.status) end
    local changes = 0
    for _, u in ipairs(j.result) do
        if type(u.update_id) == "number" then tg.offset = u.update_id + 1 end
        local m = u.message
        local text = type(m) == "table" and m.text
        local chat = type(m) == "table" and type(m.chat) == "table" and m.chat
        if type(text) == "string" and chat and type(chat.id) == "number" then
            if not tg.chat_id then
                -- not paired yet: remember the request, the Kindle asks to confirm
                local name = (type(m.from) == "table" and (m.from.username and ("@" .. m.from.username) or m.from.first_name))
                    or tostring(chat.id)
                self.pending = { chat_id = chat.id, name = tostring(name), text = text }
            elseif chat.id == tg.chat_id then
                local reply = todo:command(text)
                changes = changes + 1
                self:send(chat.id, reply)
            end
        end
    end
    todo:save()
    return changes
end

--- Called when the user confirms pairing on the Kindle (inside a task).
function Telegram:pair(p)
    local todo = self.app.todo
    todo.telegram.chat_id, todo.telegram.chat_name = p.chat_id, p.name
    todo:save()
    self:send(p.chat_id, "Paired with your Kindle \226\156\147\n\n" .. todo:command(p.text == "/start" and "help" or p.text))
end

return Telegram
