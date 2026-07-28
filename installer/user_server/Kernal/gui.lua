local gui = {}

local C = {
    black = colors and colors.black or 32768,
    white = colors and colors.white or 1,
    gray = colors and colors.gray or 128,
    lightGray = colors and colors.lightGray or 256,
    blue = colors and colors.blue or 2048,
    green = colors and colors.green or 32,
    red = colors and colors.red or 16384,
    yellow = colors and colors.yellow or 16,
    orange = colors and colors.orange or 2,
}

local function truncate(text, width)
    text = tostring(text or "")
    if #text <= width then
        return text
    end
    if width <= 3 then
        return text:sub(1, width)
    end
    return text:sub(1, width - 3) .. "..."
end

local function service_title(service)
    return tostring(service and service.manifest and service.manifest.title or service and service.id or "?")
end

local function draw(system, state)
    local screen = system.screen
    local width, height = screen:get_size()
    screen:clear(C.black)
    screen:rect(1, 1, width, 2, C.blue)
    screen:write(2, 1, "HyperCube User Server", C.yellow, C.blue)
    screen:write(2, 2, "Services: " .. tostring(#(system.services or {})), C.white, C.blue)

    state.buttons = {}
    local row = 4
    for index, service in ipairs(system.services or {}) do
        if row >= height - 1 then
            break
        end
        local id = "service_" .. tostring(index)
        local title = service_title(service)
        local status = service.pid and ("pid " .. tostring(service.pid)) or "no daemon"
        state.buttons[id] = screen:button(id, 2, row, math.max(8, width - 3), truncate(title .. "  " .. status, width - 5), {
            fg = C.white,
            bg = C.gray,
        })
        row = row + 2
    end

    if #(system.services or {}) == 0 then
        screen:write(2, 4, "Add folders under user_services/<id>.", C.lightGray, C.black)
    end

    if state.message then
        screen:write(2, height - 1, truncate(state.message, width - 2), state.error and C.red or C.orange, C.black)
    else
        screen:write(2, height - 1, "Touch service to open UI. Q shuts down.", C.lightGray, C.black)
    end
    screen:present()
end

local function hit(buttons, x, y)
    for id, button in pairs(buttons or {}) do
        if button:contains(x, y) then
            return id
        end
    end
    return nil
end

function gui.run(system)
    if not system.screen then
        print("UserServer running without screen.")
        return false, "ScreenUnavailable"
    end

    local state = {
        buttons = {},
        running = true,
    }
    draw(system, state)

    while state.running do
        system.scheduler.tick({ type = "tick" })
        local event = system.screen:pull_event(0.1)
        if event and event.type == "touch" then
            local id = hit(state.buttons, event.x, event.y)
            local index = id and tonumber(id:match("^service_(%d+)$"))
            if index and system.services[index] then
                local ok, result = system.service_manager.run_ui(system, system.services[index])
                state.message = ok and ("Opened " .. service_title(system.services[index])) or ("UI failed: " .. tostring(result))
                state.error = not ok
                draw(system, state)
            end
        elseif event and event.type == "key" and keys then
            local key = event.raw and event.raw[2]
            if key == keys.q then
                state.running = false
            elseif key == keys.r then
                system.services = system.service_manager.scan(system.service_root)
                state.message = "Services refreshed"
                state.error = false
                draw(system, state)
            end
        elseif event and event.type == "resize" then
            draw(system, state)
        end
    end

    return system.shutdown("gui")
end

return gui
