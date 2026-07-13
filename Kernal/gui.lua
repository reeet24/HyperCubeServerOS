local gui = {}

local C = {
    black = colors and colors.black or 32768,
    white = colors and colors.white or 1,
    gray = colors and colors.gray or 128,
    lightGray = colors and colors.lightGray or 256,
    blue = colors and colors.blue or 2048,
    cyan = colors and colors.cyan or 8192,
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

local function count_processes(process_api)
    local result = process_api and process_api.list and process_api.list()
    if result and result.result then
        return #result.result, result.result
    end
    return 0, {}
end

local function uptime()
    return string.format("%.1fs", os.clock())
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

    local marker_y = y + 1
    local track = math.max(1, height - 2)
    if max_scroll > 0 then
        marker_y = y + 1 + math.floor((scroll / max_scroll) * (track - 1))
    end
    screen:write(width - 2, y + 1, "^", C.yellow, C.black)
    screen:write(width - 2, marker_y, "#", C.white, C.black)
    screen:write(width - 2, y + height - 2, "v", C.yellow, C.black)
end

local function draw_header(screen, width, height)
    height = height or 3
    screen:rect(1, 1, width, height, C.blue)
    screen:write(2, 1, screen.title or "HyperCubeServer", C.yellow, C.blue)
    screen:write(math.max(1, width - 14), 1, "RUNNING", C.green, C.blue)
    if height >= 2 then
        screen:write(2, 2, screen.subtitle or "Tesserac Server OS", C.white, C.blue)
    end
end

local function draw_status(screen, hypercube, width, y, height)
    height = math.max(3, height or 8)
    local process_count = count_processes(hypercube.process)
    local network = hypercube.network and hypercube.network:summary() or nil
    local database = hypercube.database and hypercube.database:summary() or nil
    local network_line = "Network: offline"
    local database_line = "Database: unavailable"
    local identity_line = "TesseracID: not signed in"
    if network then
        network_line = "Network: " .. tostring(network.status) .. " " .. tostring(network.mode)
        if network.server_id then
            network_line = network_line .. " #" .. tostring(network.server_id)
        elseif network.client_count and network.client_count > 0 then
            network_line = network_line .. " clients=" .. tostring(network.client_count)
        end
    end
    if database then
        database_line = "Database: " .. tostring(database.status) .. " drives=" .. tostring(database.drives)
        if database.groups and database.shards_per_group then
            database_line = database_line .. " groups=" .. tostring(database.groups) .. "x" .. tostring(database.shards_per_group)
        end
    end
    if hypercube.identity then
        identity_line = "TesseracID: " .. tostring(hypercube.identity.username or hypercube.identity.tesserac_id)
    end

    screen:border(2, y, width - 2, height, C.lightGray, C.black)
    screen:write(4, y, " System ", C.yellow, C.black)
    local rows = {
        "Uptime: " .. uptime(),
        "Processes: " .. tostring(process_count),
        "Screen: " .. tostring(screen.width) .. "x" .. tostring(screen.height),
        network_line,
        database_line,
        identity_line,
    }
    for i = 1, math.min(#rows, height - 2) do
        screen:write(4, y + i, truncate(rows[i], width - 6), C.white, C.black)
    end
end

local function draw_logs(screen, hypercube, state, width, y, height)
    screen:border(2, y, width - 2, height, C.lightGray, C.black)
    screen:write(4, y, " Logs ", C.yellow, C.black)

    local lines = hypercube.logger.lines()
    local visible = math.max(1, height - 2)
    local max_scroll = math.max(0, #lines - visible)
    state.scroll = state.scroll or {}
    local scroll = state.scroll.logs
    if scroll == nil then
        scroll = max_scroll
    end
    scroll = clamp(scroll, 0, max_scroll)
    set_scroll(state, "logs", scroll, max_scroll)
    state.max_scroll.logs = max_scroll
    local start = scroll + 1
    local finish = math.min(#lines, start + visible - 1)
    local row = y + 1

    for i = start, finish do
        screen:write(4, row, truncate(lines[i], width - 6), C.lightGray, C.black)
        row = row + 1
        if row >= y + height then
            break
        end
    end
    draw_scroll_hint(screen, width, y, height, scroll, max_scroll)
end

local function draw_processes(screen, hypercube, state, width, y, height)
    screen:border(2, y, width - 2, height, C.lightGray, C.black)
    screen:write(4, y, " Processes ", C.yellow, C.black)

    local _, processes = count_processes(hypercube.process)
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

local function draw_installer(screen, hypercube, state, width, y, height)
    screen:border(2, y, width - 2, height, C.lightGray, C.black)
    screen:write(4, y, " HyperCube Installer ", C.yellow, C.black)

    local rows = {}
    local row_buttons = {}
    local function add_text(text, fg)
        table.insert(rows, { type = "text", text = text, fg = fg or C.white })
    end
    local function add_spacer()
        table.insert(rows, { type = "spacer" })
    end
    local function add_buttons(defs)
        table.insert(rows, { type = "buttons", buttons = defs })
    end

    if not hypercube.installer then
        add_text("Installer service unavailable.", C.red)
        state.max_scroll.installer = 0
        return {}
    end

    local selected, drives = hypercube.installer:selected_drive()
    local source_profile = hypercube.installer.source_profile and hypercube.installer:source_profile() or { device = "TPhone" }
    local image_status = fs and fs.exists and fs.exists("installer/hypercube_phone") and "ready" or "missing"
    image_status = fs and fs.exists and fs.exists(hypercube.installer.source) and "ready" or "missing"
    add_text("Image: " .. tostring(hypercube.installer.source) .. " (" .. image_status .. ")", image_status == "ready" and C.green or C.red)
    add_text("Device: " .. tostring(source_profile.device or "TPhone"), C.white)
    add_text("Detected drives: " .. tostring(#drives), C.white)

    if selected then
        add_text("Selected: " .. tostring(selected.name), C.white)
        add_text("Mount: " .. tostring(selected.mount), C.lightGray)
        add_text("Disk ID: " .. tostring(selected.id or "unknown"), C.lightGray)
    else
        add_text("Insert a disk into a drive to install HyperCube.", C.orange)
    end

    add_spacer()
    add_buttons({
        {
            id = "installer_phone",
            x = 4,
            width = 10,
            label = "Phone",
            fg = source_profile.device == "TPhone" and C.black or C.white,
            bg = source_profile.device == "TPhone" and C.yellow or C.gray,
        },
        {
            id = "installer_turtle",
            x = 16,
            width = 10,
            label = "Turtle",
            fg = source_profile.device == "Turtle" and C.black or C.white,
            bg = source_profile.device == "Turtle" and C.yellow or C.gray,
        },
        {
            id = "installer_business_phone",
            x = 28,
            width = 12,
            label = "Business",
            fg = source_profile.device == "TBusinessPhone" and C.black or C.white,
            bg = source_profile.device == "TBusinessPhone" and C.yellow or C.gray,
        },
    })
    add_spacer()
    add_buttons({
        {
            id = "installer_next",
            x = 4,
            width = 12,
            label = "Next Drive",
            fg = C.white,
            bg = C.gray,
        },
        {
            id = "installer_install",
            x = 18,
            width = 14,
            label = "Install",
            fg = C.white,
            bg = selected and C.green or C.gray,
        },
    })

    add_spacer()
    local result = hypercube.installer.last_result
    if result then
        if result.ok then
            add_text("ROM installed to " .. tostring(result.mount), C.green)
            add_text(tostring(result.rom or "hypercube.rom") .. " files=" .. tostring(result.packed_files or "?"), C.lightGray)
        else
            add_text("Install failed: " .. tostring(result.error), C.red)
        end
    else
        add_text("Installs startup.lua + obfuscated HyperCube ROM.", C.lightGray)
    end

    local visible = math.max(1, height - 2)
    local max_scroll = math.max(0, #rows - visible)
    local scroll = clamp(get_scroll(state, "installer"), 0, max_scroll)
    set_scroll(state, "installer", scroll, max_scroll)
    state.max_scroll.installer = max_scroll

    local row = y + 1
    for i = scroll + 1, math.min(#rows, scroll + visible) do
        local item = rows[i]
        if item.type == "text" then
            screen:write(4, row, truncate(item.text, width - 6), item.fg, C.black)
        elseif item.type == "buttons" then
            for _, def in ipairs(item.buttons) do
                if def.x + def.width - 1 <= width - 2 then
                    row_buttons[def.id] = screen:button(def.id, def.x, row, def.width, def.label, {
                        fg = def.fg,
                        bg = def.bg,
                    })
                end
            end
        end
        row = row + 1
        if row >= y + height then
            break
        end
    end

    draw_scroll_hint(screen, width, y, height, scroll, max_scroll)
    return row_buttons
end

local function create_screen_manager(default_screen)
    local manager = {
        active = default_screen,
        screens = {},
        order = {},
    }

    function manager:define(id, definition)
        id = tostring(id or "")
        if id == "" or type(definition) ~= "table" then
            return self
        end
        if not self.screens[id] then
            self.order[#self.order + 1] = id
        end
        definition.id = id
        self.screens[id] = definition
        if not self.active then
            self.active = id
        end
        return self
    end

    function manager:set(id)
        if self.screens[id] then
            self.active = id
            return true
        end
        return false, "ScreenNotFound"
    end

    function manager:current()
        return self.screens[self.active], self.active
    end

    function manager:render(ctx)
        local screen = self.screens[self.active]
        if screen and screen.render then
            return screen.render(ctx)
        end
        return false, "ScreenRendererMissing"
    end

    function manager:touch(ctx)
        local screen = self.screens[self.active]
        if screen and screen.on_touch then
            return screen.on_touch(ctx) == true
        end
        return false
    end

    return manager
end

local function ensure_screen_manager(state, hypercube)
    if state.screens then
        return state.screens
    end
    local screens = create_screen_manager(state.view or "logs")
    screens:define("logs", {
        render = function(ctx)
            draw_logs(ctx.screen, hypercube, ctx.state, ctx.width, ctx.y, ctx.height)
        end,
    })
    screens:define("processes", {
        render = function(ctx)
            draw_processes(ctx.screen, hypercube, ctx.state, ctx.width, ctx.y, ctx.height)
        end,
    })
    screens:define("installer", {
        render = function(ctx)
            ctx.state.panel_buttons = draw_installer(ctx.screen, hypercube, ctx.state, ctx.width, ctx.y, ctx.height)
        end,
        on_touch = function(ctx)
            local id = ctx.button_id
            if id == "installer_next" and hypercube.installer then
                hypercube.installer:select_next()
                hypercube.logger.info("installer selected next drive", hypercube.root_context)
                return true
            elseif id == "installer_phone" and hypercube.installer and hypercube.installer.set_source then
                hypercube.installer:set_source("phone")
                hypercube.logger.info("installer source set phone", hypercube.root_context)
                return true
            elseif id == "installer_turtle" and hypercube.installer and hypercube.installer.set_source then
                hypercube.installer:set_source("turtle")
                hypercube.logger.info("installer source set turtle", hypercube.root_context)
                return true
            elseif id == "installer_business_phone" and hypercube.installer and hypercube.installer.set_source then
                hypercube.installer:set_source("business_phone")
                hypercube.logger.info("installer source set business phone", hypercube.root_context)
                return true
            elseif id == "installer_install" and hypercube.installer then
                local ok, result = hypercube.installer:install()
                if ok then
                    hypercube.logger.info("installed HyperCube to " .. tostring(result.mount), hypercube.root_context)
                else
                    hypercube.logger.warn("installer failed: " .. tostring(result), hypercube.root_context)
                end
                return true
            end
            return false
        end,
    })
    state.screens = screens
    return screens
end

local function draw_footer(screen, width, height, active_view)
    local buttons = {}
    local y = height
    screen:rect(1, y, width, 1, C.gray)

    if width < 46 then
        buttons.refresh = screen:button("refresh", 1, y, 3, "R", {
            fg = C.white,
            bg = C.blue,
        })
        buttons.logs = screen:button("logs", 5, y, 3, "L", {
            fg = active_view == "logs" and C.black or C.white,
            bg = active_view == "logs" and C.yellow or C.gray,
        })
        buttons.processes = screen:button("processes", 9, y, 3, "P", {
            fg = active_view == "processes" and C.black or C.white,
            bg = active_view == "processes" and C.yellow or C.gray,
        })
        buttons.installer = screen:button("installer", 13, y, 3, "I", {
            fg = active_view == "installer" and C.black or C.white,
            bg = active_view == "installer" and C.yellow or C.gray,
        })
        buttons.shutdown = screen:button("shutdown", math.max(1, width - 2), y, 3, "X", {
            fg = C.white,
            bg = C.red,
        })
        return buttons
    end

    buttons.refresh = screen:button("refresh", 2, y, 10, "Refresh", {
        fg = C.white,
        bg = C.blue,
    })
    buttons.logs = screen:button("logs", 13, y, 8, "Logs", {
        fg = active_view == "logs" and C.black or C.white,
        bg = active_view == "logs" and C.yellow or C.gray,
    })
    buttons.processes = screen:button("processes", 22, y, 12, "Processes", {
        fg = active_view == "processes" and C.black or C.white,
        bg = active_view == "processes" and C.yellow or C.gray,
    })
    buttons.installer = screen:button("installer", 35, y, 11, "Installer", {
        fg = active_view == "installer" and C.black or C.white,
        bg = active_view == "installer" and C.yellow or C.gray,
    })
    buttons.shutdown = screen:button("shutdown", math.max(47, width - 11), y, 10, "Shutdown", {
        fg = C.white,
        bg = C.red,
    })

    return buttons
end

function gui.render(hypercube, state)
    state = state or {}
    local screen = hypercube.screen
    if not screen then
        return nil, "ScreenUnavailable"
    end

    local width, height = screen:get_size()
    local screens = ensure_screen_manager(state, hypercube)
    local _, view = screens:current()
    state.view = view or "logs"
    state.max_scroll = state.max_scroll or {}
    screen.title = hypercube.name
    screen.subtitle = hypercube.subtitle
    screen:clear(C.black)

    local header_height = height <= 12 and 2 or 3
    local status_y = header_height + 2
    local status_height = height <= 12 and 3 or (height <= 16 and 5 or 8)
    local panel_y = status_y + status_height + 1
    local panel_height = math.max(1, height - panel_y)

    draw_header(screen, width, header_height)
    draw_status(screen, hypercube, width, status_y, status_height)
    state.panel_buttons = {}

    screens:render({
        screen = screen,
        state = state,
        width = width,
        y = panel_y,
        height = panel_height,
    })

    state.buttons = draw_footer(screen, width, height, state.view)
    for id, button in pairs(state.panel_buttons or {}) do
        state.buttons[id] = button
    end
    screen:present()
    return true
end

local function hit_button(buttons, x, y)
    for id, button in pairs(buttons or {}) do
        if button:contains(x, y) then
            return id
        end
    end
    return nil
end

function gui.run(hypercube)
    local screen = hypercube.screen
    if not screen then
        print("HyperCubeServer is running, but no screen driver is available.")
        return false, "ScreenUnavailable"
    end
    screen.defer_rednet = true

    local state = {
        view = "logs",
        buttons = {},
        scroll = {},
        max_scroll = {},
        running = true,
        last_announce = 0,
    }

    hypercube.logger.info("gui started", hypercube.root_context)
    gui.render(hypercube, state)

    while state.running do
        local screens = ensure_screen_manager(state, hypercube)
        if hypercube.network and hypercube.network.mode == "server" then
            hypercube.network:poll(0.05)
            if hypercube.network.announce and os.clock() - state.last_announce >= 5 then
                hypercube.network:announce()
                state.last_announce = os.clock()
            end
        end
        if hypercube.database then
            hypercube.database:refresh()
        end

        local event = screen:pull_event(1)
        if event and event.type == "touch" then
            local id = hit_button(state.buttons, event.x, event.y)
            if id == "shutdown" then
                hypercube.logger.info("gui shutdown requested", hypercube.root_context)
                state.running = false
            elseif id == "logs" then
                screens:set("logs")
                state.view = "logs"
            elseif id == "processes" then
                screens:set("processes")
                state.view = "processes"
            elseif id == "installer" then
                screens:set("installer")
                state.view = "installer"
            elseif id and screens:touch({
                button_id = id,
                state = state,
                event = event,
            }) then
                local _, active = screens:current()
                state.view = active or state.view
            elseif id == "refresh" then
                hypercube.logger.info("gui refreshed", hypercube.root_context)
            end
            gui.render(hypercube, state)
        elseif event and event.type == "scroll" then
            local direction = event.direction or 0
            scroll_state(state, state.view or "logs", direction, state.max_scroll[state.view or "logs"] or 0)
            gui.render(hypercube, state)
        elseif event and event.type == "key" and keys then
            local key = event.raw and event.raw[2]
            if key == keys.q then
                state.running = false
            elseif key == keys.l then
                screens:set("logs")
                state.view = "logs"
                gui.render(hypercube, state)
            elseif key == keys.p then
                screens:set("processes")
                state.view = "processes"
                gui.render(hypercube, state)
            elseif key == keys.i then
                screens:set("installer")
                state.view = "installer"
                gui.render(hypercube, state)
            elseif key == keys.up then
                scroll_state(state, state.view or "logs", -1, state.max_scroll[state.view or "logs"] or 0)
                gui.render(hypercube, state)
            elseif key == keys.down then
                scroll_state(state, state.view or "logs", 1, state.max_scroll[state.view or "logs"] or 0)
                gui.render(hypercube, state)
            elseif key == keys.pageUp then
                scroll_state(state, state.view or "logs", -5, state.max_scroll[state.view or "logs"] or 0)
                gui.render(hypercube, state)
            elseif key == keys.pageDown then
                scroll_state(state, state.view or "logs", 5, state.max_scroll[state.view or "logs"] or 0)
                gui.render(hypercube, state)
            end
        elseif not event then
            gui.render(hypercube, state)
        elseif event.type == "resize" then
            gui.render(hypercube, state)
        end
    end

    hypercube.shutdown("gui")
    return true
end

return gui
