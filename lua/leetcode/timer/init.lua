---@class lc.Timer
---@field elapsed integer seconds elapsed
---@field running boolean
---@field _timer uv.uv_timer_t|nil
---@field _callbacks table<string, function[]>
local Timer = {}
Timer.__index = Timer

---@return lc.Timer
function Timer:new()
    return setmetatable({
        elapsed = 0,
        running = false,
        _timer = nil,
        _callbacks = { tick = {}, state = {} },
    }, self)
end

---@param event string
---@param cb function
function Timer:on(event, cb)
    if not self._callbacks[event] then
        self._callbacks[event] = {}
    end
    table.insert(self._callbacks[event], cb)
end

---@private
---@param event string
function Timer:_emit(event)
    for _, cb in ipairs(self._callbacks[event] or {}) do
        pcall(cb, self)
    end
end

---@return string formatted "MM:SS" or "HH:MM:SS"
function Timer:format()
    local s = self.elapsed
    local h = math.floor(s / 3600)
    local m = math.floor((s % 3600) / 60)
    local sec = s % 60
    if h > 0 then
        return ("%d:%02d:%02d"):format(h, m, sec)
    end
    return ("%02d:%02d"):format(m, sec)
end

function Timer:start()
    if self.running then
        return
    end
    self.running = true

    self._timer = vim.loop.new_timer()
    self._timer:start(
        1000,
        1000,
        vim.schedule_wrap(function()
            if not self.running then
                return
            end
            self.elapsed = self.elapsed + 1
            self:_emit("tick")
        end)
    )

    self:_emit("state")
end

function Timer:stop()
    if not self.running then
        return
    end
    self.running = false

    if self._timer then
        if self._timer:is_active() then
            self._timer:stop()
        end
        self._timer:close()
        self._timer = nil
    end

    self:_emit("state")
end

function Timer:toggle()
    if self.running then
        self:stop()
    else
        self:start()
    end
end

function Timer:reset()
    self:stop()
    self.elapsed = 0
    self:_emit("tick")
    self:_emit("state")
end

return Timer
