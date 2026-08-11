local Screen = {}
Screen.__index = Screen

local DEFAULT_BACKGROUND = colors and colors.black or 32768
local DEFAULT_FOREGROUND = colors and colors.white or 1
local COLOR_GRAY = colors and colors.gray or 128

local function color_to_blit(color)
    if colors and colors.toBlit then
        return colors.toBlit(color)
    end

    local value = color
    local index = 0
    while value and value > 1 do
        value = value / 2
        index = index + 1
    end
    return ("0123456789abcdef"):sub(index + 1, index + 1)
end

local function clamp(value, min_value, max_value)
    value = tonumber(value) or min_value
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
end

local function ordered(a, b)
    if a <= b then
        return a, b
    end
    return b, a
end

local function rounded(value)
    value = tonumber(value) or 0
    return math.floor(value + 0.5)
end

local function find_monitor(side)
    if side and peripheral and peripheral.wrap then
        local wrapped = peripheral.wrap(side)
        if wrapped and wrapped.getSize and wrapped.setTextColor then
            return wrapped, side
        end
        return nil, "MonitorNotFound"
    end

    if peripheral and peripheral.getNames and peripheral.getType and peripheral.wrap then
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "monitor" then
                local wrapped = peripheral.wrap(name)
                if wrapped and wrapped.getSize and wrapped.setTextColor then
                    return wrapped, name
                end
            end
        end
    end

    if peripheral and peripheral.find then
        local monitor = peripheral.find("monitor")
        if monitor then
            return monitor, "monitor"
        end
    end

    if term and term.current then
        return term.current(), "term"
    end

    return nil, "NoScreenAvailable"
end

local function make_cell(fg, bg, char)
    return {
        char = char or " ",
        fg = fg or DEFAULT_FOREGROUND,
        bg = bg or DEFAULT_BACKGROUND,
    }
end

local function new_buffer(width, height, fg, bg)
    local buffer = {}
    for y = 1, height do
        buffer[y] = {}
        for x = 1, width do
            buffer[y][x] = make_cell(fg, bg)
        end
    end
    return buffer
end

function Screen.new(target, options)
    options = options or {}

    local self = setmetatable({}, Screen)
    self.target = target
    self.side = options.side or "screen"
    self.text_scale = options.text_scale or 0.5
    self.fg = options.fg or DEFAULT_FOREGROUND
    self.bg = options.bg or DEFAULT_BACKGROUND

    if self.target.setTextScale then
        self.target.setTextScale(self.text_scale)
    end

    self.width, self.height = self.target.getSize()
    self.is_color = not self.target.isColor or self.target.isColor()
    self.is_colour = self.is_color
    self.buffer = new_buffer(self.width, self.height, self.fg, self.bg)
    self.dirty = true

    if self.target.setTextColor then self.target.setTextColor(self.fg) end
    if self.target.setBackgroundColor then self.target.setBackgroundColor(self.bg) end

    return self
end

function Screen:init()
    self:clear(self.bg)
    self:present()
    return self
end

function Screen:shutdown()
    self:clear(self.bg)
    self:present()
    return true
end

function Screen:get_size()
    self.width, self.height = self.target.getSize()
    return self.width, self.height
end

function Screen:resize_if_needed()
    local width, height = self.target.getSize()
    if width ~= self.width or height ~= self.height then
        self.width = width
        self.height = height
        self.buffer = new_buffer(width, height, self.fg, self.bg)
        self.dirty = true
        return true
    end
    return false
end

function Screen:set_colors(fg, bg)
    if fg then self.fg = fg end
    if bg then self.bg = bg end
    return self
end

function Screen:set_palette(color, r, g, b)
    if not self.target.setPaletteColor then
        return false, "PaletteUnsupported"
    end
    self.target.setPaletteColor(color, r, g, b)
    return true
end

function Screen:clear(bg)
    bg = bg or self.bg
    self:resize_if_needed()
    self.buffer = new_buffer(self.width, self.height, self.fg, bg)
    self.dirty = true
    return self
end

function Screen:plot(x, y, char, fg, bg)
    self:resize_if_needed()
    x = math.floor(tonumber(x) or 0)
    y = math.floor(tonumber(y) or 0)
    if x < 1 or y < 1 or x > self.width or y > self.height then
        return false
    end

    self.buffer[y][x] = make_cell(fg or self.fg, bg or self.bg, char or " ")
    self.dirty = true
    return true
end

function Screen:write(x, y, text, fg, bg)
    text = tostring(text or "")
    for i = 1, #text do
        self:plot(x + i - 1, y, text:sub(i, i), fg, bg)
    end
    return self
end

function Screen:blit(x, y, text, fg_map, bg_map)
    text = tostring(text or "")
    fg_map = tostring(fg_map or color_to_blit(self.fg):rep(#text))
    bg_map = tostring(bg_map or color_to_blit(self.bg):rep(#text))

    for i = 1, #text do
        local fg = colors and colors.fromBlit and colors.fromBlit(fg_map:sub(i, i)) or self.fg
        local bg = colors and colors.fromBlit and colors.fromBlit(bg_map:sub(i, i)) or self.bg
        self:plot(x + i - 1, y, text:sub(i, i), fg, bg)
    end
    return self
end

function Screen:fill(x, y, width, height, char, fg, bg)
    char = char or " "
    width = math.max(0, math.floor(tonumber(width) or 0))
    height = math.max(0, math.floor(tonumber(height) or 0))

    for row = y, y + height - 1 do
        for col = x, x + width - 1 do
            self:plot(col, row, char, fg, bg)
        end
    end
    return self
end

function Screen:rect(x, y, width, height, bg)
    return self:fill(x, y, width, height, " ", self.fg, bg or self.bg)
end

function Screen:hline(x1, x2, y, char, fg, bg)
    self:resize_if_needed()
    y = math.floor(tonumber(y) or 0)
    if y < 1 or y > self.height then
        return self
    end
    x1, x2 = ordered(math.floor(tonumber(x1) or 0), math.floor(tonumber(x2) or 0))
    x1 = math.max(1, x1)
    x2 = math.min(self.width, x2)
    if x2 < x1 then
        return self
    end
    char = char or " "
    fg = fg or self.fg
    bg = bg or self.bg
    for x = x1, x2 do
        self.buffer[y][x] = make_cell(fg, bg, char)
    end
    self.dirty = true
    return self
end

function Screen:line(x1, y1, x2, y2, char, fg, bg)
    x1 = math.floor(tonumber(x1) or 0)
    y1 = math.floor(tonumber(y1) or 0)
    x2 = math.floor(tonumber(x2) or 0)
    y2 = math.floor(tonumber(y2) or 0)
    char = char or " "
    local dx = math.abs(x2 - x1)
    local sx = x1 < x2 and 1 or -1
    local dy = -math.abs(y2 - y1)
    local sy = y1 < y2 and 1 or -1
    local err = dx + dy
    while true do
        self:plot(x1, y1, char, fg, bg)
        if x1 == x2 and y1 == y2 then
            break
        end
        local e2 = 2 * err
        if e2 >= dy then
            err = err + dy
            x1 = x1 + sx
        end
        if e2 <= dx then
            err = err + dx
            y1 = y1 + sy
        end
    end
    return self
end

local function edge_intersections(y, points)
    local xs = {}
    for i = 1, #points do
        local a = points[i]
        local b = points[i == #points and 1 or i + 1]
        local y1, y2 = a.y, b.y
        if y1 ~= y2 then
            local min_y, max_y = ordered(y1, y2)
            if y >= min_y and y < max_y then
                local t = (y - y1) / (y2 - y1)
                xs[#xs + 1] = a.x + t * (b.x - a.x)
            end
        end
    end
    table.sort(xs)
    return xs
end

function Screen:poly(points, char, fg, bg)
    if type(points) ~= "table" or #points < 3 then
        return self
    end
    self:resize_if_needed()
    local normalized = {}
    local min_y = self.height
    local max_y = 1
    for _, point in ipairs(points) do
        local x = tonumber(point.x or point[1]) or 0
        local y = tonumber(point.y or point[2]) or 0
        normalized[#normalized + 1] = { x = x, y = y }
        min_y = math.min(min_y, math.floor(y))
        max_y = math.max(max_y, math.ceil(y))
    end
    min_y = math.max(1, min_y)
    max_y = math.min(self.height, max_y)
    for y = min_y, max_y do
        local xs = edge_intersections(y + 0.5, normalized)
        for i = 1, #xs - 1, 2 do
            self:hline(rounded(xs[i]), rounded(xs[i + 1]), y, char, fg, bg)
        end
    end
    return self
end

function Screen:tri(x1, y1, x2, y2, x3, y3, bg, fg, char)
    return self:poly({
        { x = x1, y = y1 },
        { x = x2, y = y2 },
        { x = x3, y = y3 },
    }, char or " ", fg or self.fg, bg or self.bg)
end

function Screen:quad(x1, y1, x2, y2, x3, y3, x4, y4, bg, fg, char)
    return self:poly({
        { x = x1, y = y1 },
        { x = x2, y = y2 },
        { x = x3, y = y3 },
        { x = x4, y = y4 },
    }, char or " ", fg or self.fg, bg or self.bg)
end

function Screen:border(x, y, width, height, fg, bg)
    if width < 2 or height < 2 then
        return self
    end

    self:write(x, y, "+" .. string.rep("-", width - 2) .. "+", fg, bg)
    self:write(x, y + height - 1, "+" .. string.rep("-", width - 2) .. "+", fg, bg)
    for row = y + 1, y + height - 2 do
        self:plot(x, row, "|", fg, bg)
        self:plot(x + width - 1, row, "|", fg, bg)
    end
    return self
end

function Screen:center(y, text, fg, bg)
    text = tostring(text or "")
    local x = math.floor((self.width - #text) / 2) + 1
    return self:write(math.max(1, x), y, text, fg, bg)
end

function Screen:button(id, x, y, width, label, options)
    options = options or {}
    local bg = options.bg or COLOR_GRAY or self.bg
    local fg = options.fg or DEFAULT_FOREGROUND or self.fg
    local text = tostring(label or id or "")
    local padded = " " .. text .. " "
    width = math.max(width or #padded, #padded)
    local start = x + math.floor((width - #text) / 2)

    self:rect(x, y, width, 1, bg)
    self:write(start, y, text, fg, bg)

    return {
        id = id,
        x = x,
        y = y,
        width = width,
        height = 1,
        contains = function(_, tx, ty)
            return tx >= x and tx < x + width and ty == y
        end,
    }
end

function Screen:present()
    self:resize_if_needed()

    if self.target.setCursorBlink then
        self.target.setCursorBlink(false)
    end

    for y = 1, self.height do
        local text = {}
        local fg = {}
        local bg = {}
        for x = 1, self.width do
            local cell = self.buffer[y][x]
            text[x] = cell.char
            fg[x] = color_to_blit(cell.fg)
            bg[x] = color_to_blit(cell.bg)
        end

        self.target.setCursorPos(1, y)
        if self.target.blit then
            self.target.blit(table.concat(text), table.concat(fg), table.concat(bg))
        else
            for x = 1, self.width do
                local cell = self.buffer[y][x]
                self.target.setCursorPos(x, y)
                self.target.setTextColor(cell.fg)
                self.target.setBackgroundColor(cell.bg)
                self.target.write(cell.char)
            end
        end
    end

    self.dirty = false
    return self
end

function Screen:pull_event(timeout)
    local timer_id
    if timeout and os.startTimer then
        timer_id = os.startTimer(timeout)
    end

    local function cancel_timer()
        if timer_id and os.cancelTimer then
            os.cancelTimer(timer_id)
        end
        timer_id = nil
    end

    local function pull_raw()
        if os.pullEventRaw then
            return { os.pullEventRaw() }
        elseif os.pullEvent then
            return { os.pullEvent() }
        end
        return nil
    end

    while true do
        local event = pull_raw()
        if not event then
            cancel_timer()
            return nil, "EventsUnavailable"
        end

        if event[1] == "timer" then
            if event[2] == timer_id then
                return nil, "Timeout"
            end
        elseif event[1] == "rednet_message" and self.defer_rednet then
            cancel_timer()
            return {
                type = "rednet_message",
                sender = event[2],
                message = event[3],
                protocol = event[4],
                raw = event,
            }
        elseif event[1] == "monitor_touch" and (self.side == "monitor" or event[2] == self.side) then
            cancel_timer()
            return {
                type = "touch",
                side = event[2],
                x = clamp(event[3], 1, self.width),
                y = clamp(event[4], 1, self.height),
                raw = event,
            }
        elseif event[1] == "mouse_click" then
            cancel_timer()
            return {
                type = "touch",
                button = event[2],
                x = clamp(event[3], 1, self.width),
                y = clamp(event[4], 1, self.height),
                raw = event,
            }
        elseif event[1] == "mouse_drag" then
            cancel_timer()
            return {
                type = "drag",
                button = event[2],
                x = clamp(event[3], 1, self.width),
                y = clamp(event[4], 1, self.height),
                raw = event,
            }
        elseif event[1] == "mouse_up" then
            cancel_timer()
            return {
                type = "mouse_up",
                button = event[2],
                x = clamp(event[3], 1, self.width),
                y = clamp(event[4], 1, self.height),
                raw = event,
            }
        elseif event[1] == "mouse_scroll" then
            cancel_timer()
            return {
                type = "scroll",
                direction = event[2],
                x = clamp(event[3], 1, self.width),
                y = clamp(event[4], 1, self.height),
                raw = event,
            }
        elseif event[1] == "term_resize" or event[1] == "monitor_resize" then
            cancel_timer()
            self:resize_if_needed()
            return {
                type = "resize",
                width = self.width,
                height = self.height,
                raw = event,
            }
        elseif event[1] ~= "terminate" then
            cancel_timer()
            return {
                type = event[1],
                raw = event,
            }
        end
    end
end

local driver = {
    name = "screen",
    version = "0.1.0",
}

function driver.init(context)
    local options = context and context.screen or {}
    local target, side_or_err = find_monitor(options.side)
    if not target then
        return nil, side_or_err
    end

    local screen = Screen.new(target, {
        side = side_or_err,
        text_scale = options.text_scale,
        fg = options.fg,
        bg = options.bg,
    })
    return screen:init()
end

function driver.shutdown(instance)
    if instance and instance.shutdown then
        return instance:shutdown()
    end
    return true
end

driver.Screen = Screen
driver.new = Screen.new

return driver
