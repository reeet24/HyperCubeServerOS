local gui = {}

local DEFAULT_REFRESH_RATE = 4

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

local function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function uptime()
    return string.format("%.1fs", os.clock())
end

local function count_processes(process_api)
    local result = process_api and process_api.list and process_api.list()
    if result and result.result then
        return #result.result, result.result
    end
    return 0, {}
end

local function service_title(service)
    return tostring(service and service.manifest and service.manifest.title or service and service.id or "?")
end

local function get_scroll(state, view)
    state.scroll = state.scroll or {}
    return state.scroll[view] or 0
end

local function set_scroll(state, view, value, max_scroll)
    state.scroll = state.scroll or {}
    state.scroll[view] = clamp(value or 0, 0, math.max(0, max_scroll or 0))
end

local function scroll_state(state, view, delta, max_scroll)
    set_scroll(state, view, get_scroll(state, view) + delta, max_scroll)
end

local function draw_scroll_hint(screen, width, y, height, scroll, max_scroll)
    if max_scroll <= 0 or height < 3 then
        return
    end
    local track = math.max(1, height - 2)
    local marker_y = y + 1 + math.floor((scroll / max_scroll) * (track - 1))
    screen:write(width - 2, y + 1, "^", C.yellow, C.black)
    screen:write(width - 2, marker_y, "#", C.white, C.black)
    screen:write(width - 2, y + height - 2, "v", C.yellow, C.black)
end

local function draw_header(screen, system, width, height)
    height = height or 3
    screen:rect(1, 1, width, height, C.blue)
    screen:write(2, 1, system.name or "HyperCube User Server", C.yellow, C.blue)
    screen:write(math.max(1, width - 14), 1, "RUNNING", C.green, C.blue)
    if height >= 2 then
        screen:write(2, 2, system.subtitle or "User Service Host", C.white, C.blue)
    end
end

local function draw_status(screen, system, width, y, height)
    height = math.max(3, height or 8)
    local process_count = count_processes(system.process)
    local network = system.network and system.network.summary and system.network:summary() or nil
    local network_line = "Network: offline"
    if network then
        network_line = "Network: " .. tostring(network.status) .. " " .. tostring(network.mode)
        if network.server_id then
            network_line = network_line .. " #" .. tostring(network.server_id)
        end
    end

    screen:border(2, y, width - 2, height, C.lightGray, C.black)
    screen:write(4, y, " System ", C.yellow, C.black)
    local rows = {
        "Uptime: " .. uptime(),
        "Processes: " .. tostring(process_count),
        "Services: " .. tostring(#(system.services or {})),
        "Screen: " .. tostring(screen.width) .. "x" .. tostring(screen.height),
        network_line,
        "Account: " .. tostring(system.identity and (system.identity.username or system.identity.tesserac_id) or "not signed in"),
    }
    for i = 1, math.min(#rows, height - 2) do
        screen:write(4, y + i, truncate(rows[i], width - 6), C.white, C.black)
    end
end

local function draw_logs(screen, system, state, width, y, height)
    screen:border(2, y, width - 2, height, C.lightGray, C.black)
    screen:write(4, y, " Logs ", C.yellow, C.black)

    local lines = system.logger and system.logger.lines and system.logger.lines() or {}
    local visible = math.max(1, height - 2)
    local max_scroll = math.max(0, #lines - visible)
    local scroll = state.scroll.logs
    if scroll == nil then
        scroll = max_scroll
    end
    scroll = clamp(scroll, 0, max_scroll)
    set_scroll(state, "logs", scroll, max_scroll)
    state.max_scroll.logs = max_scroll

    local row = y + 1
    for i = scroll + 1, math.min(#lines, scroll + visible) do
        screen:write(4, row, truncate(lines[i], width - 6), C.lightGray, C.black)
        row = row + 1
        if row >= y + height then
            break
        end
    end
    if #lines == 0 then
        screen:write(4, y + 1, "No log lines yet.", C.lightGray, C.black)
    end
    draw_scroll_hint(screen, width, y, height, scroll, max_scroll)
end

local function draw_processes(screen, system, state, width, y, height)
    screen:border(2, y, width - 2, height, C.lightGray, C.black)
    screen:write(4, y, " Processes ", C.yellow, C.black)

    local _, processes = count_processes(system.process)
    local visible = math.max(1, height - 2)
    local max_scroll = math.max(0, #processes - visible)
    local scroll = clamp(get_scroll(state, "processes"), 0, max_scroll)
    set_scroll(state, "processes", scroll, max_scroll)
    state.max_scroll.processes = max_scroll

    local row = y + 1
    for i = scroll + 1, math.min(#processes, scroll + visible) do
        local process = processes[i]
        local line = string.format("%s  %s  %s", tostring(process.pid), process.status or "?", process.name or "?")
        screen:write(4, row, truncate(line, width - 6), C.lightGray, C.black)
        row = row + 1
        if row >= y + height then
            break
        end
    end
    draw_scroll_hint(screen, width, y, height, scroll, max_scroll)
end

local function draw_services(screen, system, state, width, y, height)
    screen:border(2, y, width - 2, height, C.lightGray, C.black)
    screen:write(4, y, " User Services ", C.yellow, C.black)

    local buttons = {}
    local services = system.services or {}
    local visible = math.max(1, height - 3)
    local max_scroll = math.max(0, #services - visible)
    local scroll = clamp(get_scroll(state, "services"), 0, max_scroll)
    set_scroll(state, "services", scroll, max_scroll)
    state.max_scroll.services = max_scroll

    buttons.services_refresh = screen:button("services_refresh", math.max(4, width - 13), y, 10, "Refresh", {
        fg = C.white,
        bg = C.blue,
    })

    local row = y + 1
    for i = scroll + 1, math.min(#services, scroll + visible) do
        local service = services[i]
        local id = "service_" .. tostring(i)
        local status = service.pid and ("pid " .. tostring(service.pid)) or "ui only"
        local label = truncate(service_title(service) .. "  " .. status, width - 8)
        buttons[id] = screen:button(id, 4, row, math.max(8, width - 6), label, {
            fg = C.white,
            bg = C.gray,
        })
        row = row + 1
        if row >= y + height then
            break
        end
    end

    if #services == 0 then
        screen:write(4, y + 1, "Add folders under user_services/<id>.", C.lightGray, C.black)
    elseif state.service_message then
        screen:write(4, y + height - 1, truncate(state.service_message, width - 6), state.service_error and C.red or C.orange, C.black)
    end
    draw_scroll_hint(screen, width, y, height, scroll, max_scroll)
    return buttons
end

local function draw_footer(screen, width, height, active_view)
    local buttons = {}
    local y = height
    screen:rect(1, y, width, 1, C.gray)

    if width < 58 then
        buttons.refresh = screen:button("refresh", 1, y, 3, "R", { fg = C.white, bg = C.blue })
        buttons.logs = screen:button("logs", 5, y, 3, "L", {
            fg = active_view == "logs" and C.black or C.white,
            bg = active_view == "logs" and C.yellow or C.gray,
        })
        buttons.processes = screen:button("processes", 9, y, 3, "P", {
            fg = active_view == "processes" and C.black or C.white,
            bg = active_view == "processes" and C.yellow or C.gray,
        })
        buttons.services = screen:button("services", 13, y, 3, "S", {
            fg = active_view == "services" and C.black or C.white,
            bg = active_view == "services" and C.yellow or C.gray,
        })
        buttons.shutdown = screen:button("shutdown", math.max(1, width - 2), y, 3, "X", { fg = C.white, bg = C.red })
        return buttons
    end

    buttons.refresh = screen:button("refresh", 2, y, 10, "Refresh", { fg = C.white, bg = C.blue })
    buttons.logs = screen:button("logs", 13, y, 8, "Logs", {
        fg = active_view == "logs" and C.black or C.white,
        bg = active_view == "logs" and C.yellow or C.gray,
    })
    buttons.processes = screen:button("processes", 22, y, 12, "Processes", {
        fg = active_view == "processes" and C.black or C.white,
        bg = active_view == "processes" and C.yellow or C.gray,
    })
    buttons.services = screen:button("services", 35, y, 10, "Services", {
        fg = active_view == "services" and C.black or C.white,
        bg = active_view == "services" and C.yellow or C.gray,
    })
    buttons.shutdown = screen:button("shutdown", width - 7, y, 8, "Shutdown", { fg = C.white, bg = C.red })
    return buttons
end

local function hit_button(buttons, x, y)
    for id, button in pairs(buttons or {}) do
        if button:contains(x, y) then
            return id
        end
    end
    return nil
end

function gui.render(system, state)
    state = state or {}
    local screen = system.screen
    if not screen then
        return nil, "ScreenUnavailable"
    end

    local width, height = screen:get_size()
    state.view = state.view or "logs"
    state.scroll = state.scroll or {}
    state.max_scroll = state.max_scroll or {}
    state.panel_buttons = {}

    screen:clear(C.black)
    local header_height = height <= 12 and 2 or 3
    local status_y = header_height + 2
    local status_height = height <= 12 and 3 or (height <= 16 and 5 or 8)
    local panel_y = status_y + status_height + 1
    local panel_height = math.max(1, height - panel_y)

    draw_header(screen, system, width, header_height)
    draw_status(screen, system, width, status_y, status_height)

    if state.view == "processes" then
        draw_processes(screen, system, state, width, panel_y, panel_height)
    elseif state.view == "services" then
        state.panel_buttons = draw_services(screen, system, state, width, panel_y, panel_height)
    else
        state.view = "logs"
        draw_logs(screen, system, state, width, panel_y, panel_height)
    end

    state.buttons = draw_footer(screen, width, height, state.view)
    for id, button in pairs(state.panel_buttons or {}) do
        state.buttons[id] = button
    end
    screen:present()
    return true
end

function gui.run(system)
    if not system.screen then
        print("UserServer running without screen.")
        return false, "ScreenUnavailable"
    end
    system.screen.defer_rednet = true

    local state = {
        view = "logs",
        buttons = {},
        panel_buttons = {},
        scroll = {},
        max_scroll = {},
        running = true,
    }

    if system.logger then
        system.logger.info("gui started", system.root_context)
    end
    gui.render(system, state)

    local frame_interval = 1 / DEFAULT_REFRESH_RATE
    local next_frame = os.clock() + frame_interval

    while state.running do
        system.scheduler.tick({ type = "tick" })
        if system.service_manager and system.service_manager.audit_services then
            system.service_manager.audit_services(system)
        end
        local timeout = math.max(0, next_frame - os.clock())
        local event = system.screen:pull_event(timeout)
        if event and event.type == "touch" then
            local id = hit_button(state.buttons, event.x, event.y)
            if id == "shutdown" then
                state.running = false
            elseif id == "logs" then
                state.view = "logs"
            elseif id == "processes" then
                state.view = "processes"
            elseif id == "services" then
                state.view = "services"
            elseif id == "refresh" then
                if system.logger then
                    system.logger.info("gui refreshed", system.root_context)
                end
            elseif id == "services_refresh" then
                system.services = system.service_manager.scan(system.service_root)
                state.service_message = "Services refreshed"
                state.service_error = false
            else
                local index = id and tonumber(tostring(id):match("^service_(%d+)$"))
                if index and system.services and system.services[index] then
                    local ok, result = system.service_manager.run_ui(system, system.services[index])
                    state.service_message = ok and ("Opened " .. service_title(system.services[index])) or ("UI failed: " .. tostring(result))
                    state.service_error = not ok
                end
            end
            state.needs_render = true
        elseif event and event.type == "scroll" then
            scroll_state(state, state.view or "logs", event.direction or 0, state.max_scroll[state.view or "logs"] or 0)
            state.needs_render = true
        elseif event and event.type == "key" and keys then
            local key = event.raw and event.raw[2]
            if key == keys.q then
                state.running = false
            elseif key == keys.l then
                state.view = "logs"
                state.needs_render = true
            elseif key == keys.p then
                state.view = "processes"
                state.needs_render = true
            elseif key == keys.s then
                state.view = "services"
                state.needs_render = true
            elseif key == keys.r then
                if state.view == "services" then
                    system.services = system.service_manager.scan(system.service_root)
                    state.service_message = "Services refreshed"
                    state.service_error = false
                end
                state.needs_render = true
            elseif key == keys.up then
                scroll_state(state, state.view or "logs", -1, state.max_scroll[state.view or "logs"] or 0)
                state.needs_render = true
            elseif key == keys.down then
                scroll_state(state, state.view or "logs", 1, state.max_scroll[state.view or "logs"] or 0)
                state.needs_render = true
            elseif key == keys.pageUp then
                scroll_state(state, state.view or "logs", -5, state.max_scroll[state.view or "logs"] or 0)
                state.needs_render = true
            elseif key == keys.pageDown then
                scroll_state(state, state.view or "logs", 5, state.max_scroll[state.view or "logs"] or 0)
                state.needs_render = true
            end
        elseif event and event.type == "resize" then
            state.needs_render = true
        end

        if os.clock() >= next_frame or state.needs_render then
            gui.render(system, state)
            next_frame = os.clock() + frame_interval
            state.needs_render = false
        end
    end

    return system.shutdown("gui")
end

return gui
