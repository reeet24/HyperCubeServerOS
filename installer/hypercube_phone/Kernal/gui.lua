local app_manager = require("Kernal.services.app_manager")

local gui = {}
local DEFAULT_REFRESH_RATE = 10
local MIN_REFRESH_RATE = 1
local MAX_REFRESH_RATE = 30

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
    purple = colors and colors.purple or 1024,
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

local function center_x(width, text)
    return math.max(1, math.floor((width - #tostring(text)) / 2) + 1)
end

local function time_label()
    if textutils and textutils.formatTime and os.time then
        return textutils.formatTime(os.time(), false)
    end
    return string.format("%.0fs", os.clock())
end

local function network_summary(tphone)
    local network = tphone.network and tphone.network:summary() or nil
    if not network then
        return "Offline"
    end
    if network.server_id then
        return "HyperNet #" .. tostring(network.server_id)
    end
    return tostring(network.status or "offline")
end

local function draw_wallpaper(screen, width, height)
    screen:clear(C.black)
    for y = 1, height do
        local bg = C.blue
        if y > height * 0.35 then bg = C.purple end
        if y > height * 0.70 then bg = C.black end
        screen:rect(1, y, width, 1, bg)
    end
end

local function draw_status_bar(screen, tphone, width)
    screen:rect(1, 1, width, 1, C.black)
    screen:write(2, 1, time_label(), C.white, C.black)
    local right = network_summary(tphone)
    if tphone.dev_mode then
        right = "DEV " .. right
    end
    screen:write(math.max(1, width - #right - 1), 1, right, C.white, C.black)

    local notch_w = math.min(12, math.max(6, math.floor(width / 4)))
    local notch_x = center_x(width, string.rep(" ", notch_w))
    screen:rect(notch_x, 1, notch_w, 1, C.black)
end

local function draw_title(screen, tphone, width)
    screen:write(center_x(width, tphone.name or "HyperCube"), 3, tphone.name or "HyperCube", C.white, C.blue)
    if width >= 24 then
        screen:write(center_x(width, tphone.subtitle or "Tesserac TPhone"), 4, tphone.subtitle or "Tesserac TPhone", C.lightGray, C.blue)
    end
end

local function draw_home_indicator(screen, width, height)
    local w = math.min(16, math.max(8, math.floor(width / 3)))
    screen:rect(center_x(width, string.rep(" ", w)), height, w, 1, C.lightGray)
end

local find_app

local function app_render_mode(app)
    local mode = app and app.manifest and app.manifest.render_mode or "window"
    mode = tostring(mode or "window"):lower():gsub("_", "-")
    if mode == "fullscreen" or mode == "full-screen" then
        return "exclusive"
    elseif mode == "borderless" then
        return "borderless-exclusive"
    elseif mode == "exclusive" or mode == "borderless-exclusive" then
        return mode
    end
    return "window"
end

local function clamp_refresh_rate(value)
    value = tonumber(value) or DEFAULT_REFRESH_RATE
    if value < MIN_REFRESH_RATE then
        return MIN_REFRESH_RATE
    end
    if value > MAX_REFRESH_RATE then
        return MAX_REFRESH_RATE
    end
    return value
end

local function app_refresh_rate(app)
    local manifest = app and app.manifest or {}
    return clamp_refresh_rate(manifest.refresh_rate or manifest.fps or manifest.frame_rate)
end

local function current_refresh_rate(state)
    local app = find_app(state, state.active_app)
    return app_refresh_rate(app)
end

local function frame_snapshot(state)
    state.frame = state.frame or {
        now = os.clock(),
        last = os.clock(),
        dt = 0,
        count = 0,
        refresh_rate = DEFAULT_REFRESH_RATE,
        interval = 1 / DEFAULT_REFRESH_RATE,
    }
    return {
        now = state.frame.now,
        last = state.frame.last,
        dt = state.frame.dt,
        count = state.frame.count,
        refresh_rate = state.frame.refresh_rate,
        interval = state.frame.interval,
    }
end

local function advance_frame(state)
    local current = os.clock()
    state.frame = state.frame or {
        now = current,
        last = current,
        dt = 0,
        count = 0,
        refresh_rate = DEFAULT_REFRESH_RATE,
        interval = 1 / DEFAULT_REFRESH_RATE,
    }
    local rate = current_refresh_rate(state)
    state.frame.last = state.frame.now or current
    state.frame.now = current
    state.frame.dt = math.max(0, current - state.frame.last)
    state.frame.count = (state.frame.count or 0) + 1
    state.frame.refresh_rate = rate
    state.frame.interval = 1 / rate
    return state.frame
end

local function draw_app_icon(screen, app)
    local manifest = app.manifest
    local bg = manifest.color or C.gray
    local label = truncate(manifest.label or manifest.id, app.w)
    screen:rect(app.x, app.y, app.w, app.h, bg)
    screen:write(app.x + math.floor((app.w - #label) / 2), app.y, label, C.white, bg)
    screen:write(app.x, app.y + app.h, truncate(manifest.title, app.w), C.white, C.black)
end

local function app_hit(app, x, y)
    return x >= app.x and x < app.x + app.w and y >= app.y and y <= app.y + app.h
end

local function home_grid_metrics(width, height)
    local compact = width < 32 or height < 22
    local icon_w = compact and 5 or 7
    local icon_h = compact and 1 or 3
    local gap = compact and 1 or 2
    local row_step = compact and 3 or 5
    local start_y = compact and 5 or 7
    local side_padding = compact and 2 or 4
    local cols = math.max(2, math.floor((width - side_padding) / (icon_w + gap)))
    cols = math.min(cols, compact and 5 or 4)
    local bottom_limit = math.max(start_y, height - 6)
    local rows = math.max(1, math.floor((bottom_limit - start_y) / row_step) + 1)
    return {
        compact = compact,
        icon_w = icon_w,
        icon_h = icon_h,
        gap = gap,
        row_step = row_step,
        start_y = start_y,
        cols = cols,
        rows = rows,
        capacity = math.max(1, cols * rows),
    }
end

local function clamp_page(page, page_count)
    page = math.floor(tonumber(page) or 1)
    page_count = math.max(1, math.floor(tonumber(page_count) or 1))
    if page < 1 then
        return 1
    end
    if page > page_count then
        return page_count
    end
    return page
end

local function layout_apps(width, height, installed, page)
    local icons = {}
    local metrics = home_grid_metrics(width, height)
    local cols = metrics.cols
    local page_count = math.max(1, math.ceil(#(installed or {}) / metrics.capacity))
    page = clamp_page(page, page_count)
    local first = (page - 1) * metrics.capacity + 1
    local last = math.min(#(installed or {}), first + metrics.capacity - 1)
    local total_w = cols * metrics.icon_w + (cols - 1) * metrics.gap
    local start_x = math.max(2, math.floor((width - total_w) / 2) + 1)

    for i = first, last do
        local app = installed[i]
        local local_index = i - first
        local col = local_index % cols
        local row = math.floor(local_index / cols)
        icons[#icons + 1] = {
            app = app,
            id = app.manifest.id,
            x = start_x + col * (metrics.icon_w + metrics.gap),
            y = metrics.start_y + row * metrics.row_step,
            w = metrics.icon_w,
            h = metrics.icon_h,
            manifest = app.manifest,
        }
    end

    return icons, page, page_count
end

local function dock_order(app)
    local id = app and app.manifest and app.manifest.id
    local priority = {
        appstore = 1,
        messages = 2,
        banking = 3,
        browser = 4,
        settings = 5,
    }
    return priority[id] or 50
end

local function draw_dock(screen, width, height, installed)
    local dock_y = math.max(2, height - 4)
    local dock_w = math.min(width - 4, 32)
    local dock_x = center_x(width, string.rep(" ", dock_w))
    local dock_apps = {}
    for _, app in ipairs(installed or {}) do
        if app.manifest.dock then
            dock_apps[#dock_apps + 1] = app
        end
    end
    table.sort(dock_apps, function(a, b)
        local ao = dock_order(a)
        local bo = dock_order(b)
        if ao ~= bo then
            return ao < bo
        end
        return tostring(a.manifest.id) < tostring(b.manifest.id)
    end)
    local max_dock = width >= 30 and 4 or 3
    while #dock_apps > max_dock do
        dock_apps[#dock_apps] = nil
    end

    screen:rect(dock_x, dock_y, dock_w, 3, C.gray)
    local buttons = {}
    if #dock_apps == 0 then
        return buttons
    end

    local gap = 1
    local button_w = math.max(5, math.floor((dock_w - 4 - (gap * (#dock_apps - 1))) / #dock_apps))
    local x = dock_x + 2
    for _, app in ipairs(dock_apps) do
        buttons[app.manifest.id] = screen:button(app.manifest.id, x, dock_y + 1, button_w, app.manifest.label, {
            fg = C.white,
            bg = app.manifest.color or C.black,
        })
        x = x + button_w + gap
    end
    return buttons
end

local function draw_home_pager(screen, state, width, height)
    local page = state.home_page or 1
    local page_count = state.home_page_count or 1
    if page_count <= 1 then
        return {}
    end

    local buttons = {}
    local label = tostring(page) .. "/" .. tostring(page_count)
    local y = math.max(2, height - 6)
    screen:write(center_x(width, label), y, label, C.white, C.black)
    buttons.home_prev_page = screen:button("home_prev_page", 2, y, 3, "<", {
        fg = C.white,
        bg = page > 1 and C.blue or C.gray,
    })
    buttons.home_next_page = screen:button("home_next_page", math.max(1, width - 4), y, 3, ">", {
        fg = C.white,
        bg = page < page_count and C.blue or C.gray,
    })
    return buttons
end

local function set_home_page(state, page)
    state.home_page = clamp_page(page, state.home_page_count or 1)
    return state.home_page
end

local function move_home_page(state, delta)
    delta = tonumber(delta) or 0
    return set_home_page(state, (state.home_page or 1) + delta)
end

function find_app(state, id)
    for _, app in ipairs(state.installed_apps or {}) do
        if app.manifest.id == id then
            return app
        end
    end
    return nil
end

local function render_home(tphone, state)
    local screen = tphone.screen
    local width, height = screen:get_size()
    draw_wallpaper(screen, width, height)
    draw_status_bar(screen, tphone, width)
    draw_title(screen, tphone, width)

    state.apps, state.home_page, state.home_page_count = layout_apps(width, height, state.installed_apps, state.home_page)
    for _, app in ipairs(state.apps) do
        draw_app_icon(screen, app)
    end

    state.buttons = draw_dock(screen, width, height, state.installed_apps)
    local pager_buttons = draw_home_pager(screen, state, width, height)
    for id, button in pairs(pager_buttons) do
        state.buttons[id] = button
    end
    draw_home_indicator(screen, width, height)
    screen:present()
end

local function draw_app_panel(screen, tphone, title, width, height)
    draw_wallpaper(screen, width, height)
    draw_status_bar(screen, tphone, width)
    screen:rect(2, 3, width - 2, height - 4, C.black)
    screen:border(2, 3, width - 2, height - 4, C.lightGray, C.black)
    screen:write(4, 3, " " .. truncate(title, width - 12) .. " ", C.yellow, C.black)
    local back = screen:button("home", 4, height - 2, 8, "Home", { fg = C.white, bg = C.blue })
    draw_home_indicator(screen, width, height)
    return {
        home = back,
    }
end

local function draw_exclusive_bar(screen, tphone, title, width)
    screen:rect(1, 1, width, 1, C.black)
    local buttons = {
        home = screen:button("home", 1, 1, math.min(6, width), "Home", { fg = C.white, bg = C.blue }),
    }
    local label = truncate(title or tphone.name or "App", math.max(1, width - 18))
    if width > 14 then
        screen:write(8, 1, label, C.yellow, C.black)
    end
    local right = time_label()
    if width > #right + 1 then
        screen:write(width - #right, 1, right, C.white, C.black)
    end
    return buttons
end

local function app_layout_for_mode(screen, tphone, state, app, mode, width, height)
    if mode == "exclusive" then
        state.buttons = draw_exclusive_bar(screen, tphone, app.manifest.title, width)
        return {
            x = 1,
            y = 2,
            width = width,
            height = math.max(1, height - 1),
        }
    elseif mode == "borderless-exclusive" then
        local now_clock = os.clock()
        local chrome_visible = (state.borderless_chrome_until or 0) > now_clock
        state.borderless_chrome_visible = chrome_visible
        if chrome_visible then
            state.buttons = draw_exclusive_bar(screen, tphone, app.manifest.title, width)
            return {
                x = 1,
                y = 2,
                width = width,
                height = math.max(1, height - 1),
            }
        end
        state.buttons = {}
        return {
            x = 1,
            y = 1,
            width = width,
            height = height,
        }
    end

    state.buttons = draw_app_panel(screen, tphone, app.manifest.title, width, height)
    return {
        x = 4,
        y = 5,
        width = math.max(1, width - 6),
        height = math.max(1, height - 8),
    }
end

local function render_app(tphone, state)
    local screen = tphone.screen
    local width, height = screen:get_size()
    local app = find_app(state, state.active_app)
    if not app then
        state.active_app = nil
        return render_home(tphone, state)
    end

    local mode = app_render_mode(app)
    screen:clear(C.black)
    local layout = app_layout_for_mode(screen, tphone, state, app, mode, width, height)
    state.app_buttons = {}

    local ctx = {
        x = layout.x,
        y = layout.y,
        width = layout.width,
        height = layout.height,
        render_mode = mode,
        active = true,
        frame = frame_snapshot(state),
        buttons = state.app_buttons,
        state = state.app_state[app.manifest.id] or {},
    }
    state.app_state[app.manifest.id] = ctx.state

    if type(app.render) == "function" then
        local ok, err = pcall(app.render, ctx)
        if not ok then
            screen:write(ctx.x, ctx.y, "App crashed:", C.red, C.black)
            screen:write(ctx.x, ctx.y + 1, truncate(err, ctx.width), C.lightGray, C.black)
        end
    else
        screen:write(ctx.x, ctx.y, "This app has no renderer.", C.lightGray, C.black)
    end

    for id, button in pairs(state.app_buttons) do
        if state.buttons[id] == nil then
            state.buttons[id] = button
        end
    end

    screen:present()
end

function gui.render(tphone, state)
    state = state or {}
    if state.active_app then
        render_app(tphone, state)
    else
        render_home(tphone, state)
    end
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

local function hit_app(apps, x, y)
    for _, app in ipairs(apps or {}) do
        if app_hit(app, x, y) then
            return app.id
        end
    end
    return nil
end

local function set_active_app(tphone, state, app_id)
    if state.active_app == app_id then
        return
    end

    local previous = find_app(state, state.active_app)
    if previous and type(previous.on_pause) == "function" then
        local pause_ctx = {
            active = false,
            state = state.app_state[previous.manifest.id] or {},
        }
        state.app_state[previous.manifest.id] = pause_ctx.state
        local ok, err = pcall(previous.on_pause, pause_ctx)
        if not ok and tphone.logger then
            tphone.logger.warn("app pause failed " .. tostring(previous.manifest.id) .. ": " .. tostring(err), tphone.root_context)
        end
    end

    state.active_app = app_id
    state.borderless_chrome_until = 0
    state.borderless_chrome_visible = false

    local current = find_app(state, state.active_app)
    if current and type(current.on_resume) == "function" then
        local resume_ctx = {
            active = true,
            state = state.app_state[current.manifest.id] or {},
        }
        state.app_state[current.manifest.id] = resume_ctx.state
        local ok, err = pcall(current.on_resume, resume_ctx)
        if not ok and tphone.logger then
            tphone.logger.warn("app resume failed " .. tostring(current.manifest.id) .. ": " .. tostring(err), tphone.root_context)
        end
    end
end

local function reveal_borderless_chrome(state)
    state.borderless_chrome_until = os.clock() + 4
    state.borderless_chrome_visible = true
end

local function should_reveal_borderless(state, event)
    if not state.active_app then
        return false
    end
    if event.type == "touch" then
        return event.y <= 1
    end
    if event.type == "scroll" then
        return event.y <= 2 and tonumber(event.direction or 0) > 0
    end
    return false
end

local function dispatch_app_touch(tphone, state, button_id, event)
    local app = find_app(state, state.active_app)
    if not app or type(app.on_touch) ~= "function" then
        return false
    end

    local ctx = {
        button_id = button_id,
        event = event,
        active = true,
        render_mode = app_render_mode(app),
        frame = frame_snapshot(state),
        state = state.app_state[app.manifest.id] or {},
    }
    state.app_state[app.manifest.id] = ctx.state
    local ok, consumed_or_err = pcall(app.on_touch, ctx)
    if not ok and tphone.logger then
        tphone.logger.warn("app touch failed " .. tostring(app.manifest.id) .. ": " .. tostring(consumed_or_err), tphone.root_context)
        return false
    end
    return consumed_or_err == true
end

local function dispatch_app_key(tphone, state, event)
    local app = find_app(state, state.active_app)
    if not app or type(app.on_key) ~= "function" then
        return false
    end

    local ctx = {
        event = event,
        active = true,
        render_mode = app_render_mode(app),
        frame = frame_snapshot(state),
        state = state.app_state[app.manifest.id] or {},
    }
    state.app_state[app.manifest.id] = ctx.state
    local ok, consumed_or_err = pcall(app.on_key, ctx)
    if not ok then
        if tphone.logger then
            tphone.logger.warn("app key failed " .. tostring(app.manifest.id) .. ": " .. tostring(consumed_or_err), tphone.root_context)
        end
        return false
    end
    return consumed_or_err == true
end

local function dispatch_app_tick(tphone, state)
    local app = find_app(state, state.active_app)
    if not app or type(app.on_tick) ~= "function" then
        return false
    end

    local ctx = {
        active = true,
        render_mode = app_render_mode(app),
        frame = frame_snapshot(state),
        state = state.app_state[app.manifest.id] or {},
    }
    state.app_state[app.manifest.id] = ctx.state
    local ok, consumed_or_err = pcall(app.on_tick, ctx)
    if not ok then
        if tphone.logger then
            tphone.logger.warn("app tick failed " .. tostring(app.manifest.id) .. ": " .. tostring(consumed_or_err), tphone.root_context)
        end
        return false
    end
    return consumed_or_err == true
end

function gui.run(tphone)
    local screen = tphone.screen
    if not screen then
        print("HyperCube is running, but no screen driver is available.")
        return false, "ScreenUnavailable"
    end

    local state = {
        active_app = nil,
        installed_apps = app_manager.load_all(tphone),
        app_state = {},
        apps = {},
        buttons = {},
        app_buttons = {},
        home_page = 1,
        home_page_count = 1,
        borderless_chrome_until = 0,
        borderless_chrome_visible = false,
        running = true,
    }
    if tphone.identity and tphone.tesseracid and tphone.tesseracid.save_local then
        tphone.tesseracid.save_local(tphone.identity)
    end

    tphone.logger.info("tphone gui started", tphone.root_context)
    advance_frame(state)
    gui.render(tphone, state)
    local next_frame = os.clock() + (state.frame and state.frame.interval or (1 / DEFAULT_REFRESH_RATE))

    while state.running do
        if tphone.apps_dirty then
            state.installed_apps = app_manager.load_all(tphone)
            tphone.apps_dirty = false
            state.needs_render = true
        end
        local timeout = math.max(0, next_frame - os.clock())
        local event = screen:pull_event(timeout)
        if event and event.type == "touch" then
            local active = find_app(state, state.active_app)
            if active and app_render_mode(active) == "borderless-exclusive" and not state.borderless_chrome_visible and should_reveal_borderless(state, event) then
                reveal_borderless_chrome(state)
                state.needs_render = true
            else
                local button_id = hit_button(state.buttons, event.x, event.y)
                if button_id == "home" then
                    set_active_app(tphone, state, nil)
                    state.needs_render = true
                elseif not state.active_app and button_id == "home_prev_page" then
                    move_home_page(state, -1)
                    state.needs_render = true
                elseif not state.active_app and button_id == "home_next_page" then
                    move_home_page(state, 1)
                    state.needs_render = true
                elseif button_id then
                    if state.active_app then
                        if dispatch_app_touch(tphone, state, button_id, event) then
                            state.needs_render = true
                        end
                    else
                        set_active_app(tphone, state, button_id)
                        state.needs_render = true
                    end
                elseif state.active_app then
                    if dispatch_app_touch(tphone, state, nil, event) then
                        state.needs_render = true
                    end
                else
                    local app_id = hit_app(state.apps, event.x, event.y)
                    if app_id then
                        set_active_app(tphone, state, app_id)
                        state.needs_render = true
                    end
                end
            end
        elseif event and event.type == "scroll" then
            local active = find_app(state, state.active_app)
            if active and app_render_mode(active) == "borderless-exclusive" and not state.borderless_chrome_visible and should_reveal_borderless(state, event) then
                reveal_borderless_chrome(state)
                state.needs_render = true
            elseif state.active_app then
                if dispatch_app_touch(tphone, state, nil, event) then
                    state.needs_render = true
                end
            else
                move_home_page(state, tonumber(event.direction or 0) > 0 and 1 or -1)
                state.needs_render = true
            end
        elseif event and (event.type == "key" or event.type == "key_up" or event.type == "char" or event.type == "paste") and keys then
            if state.active_app and dispatch_app_key(tphone, state, event) then
                state.needs_render = true
            else
                local key = event.raw and event.raw[2]
                if event.type == "key_up" then
                    -- Apps use key_up for chords; the launcher has no key-up action.
                elseif key == keys.backspace or key == keys.home then
                    set_active_app(tphone, state, nil)
                    state.needs_render = true
                elseif not state.active_app and (key == keys.right or key == keys.down or (keys.pageDown and key == keys.pageDown)) then
                    move_home_page(state, 1)
                    state.needs_render = true
                elseif not state.active_app and (key == keys.left or key == keys.up or (keys.pageUp and key == keys.pageUp)) then
                    move_home_page(state, -1)
                    state.needs_render = true
                end
            end
        elseif event and event.type == "resize" then
            state.needs_render = true
        end

        if os.clock() >= next_frame then
            advance_frame(state)
            dispatch_app_tick(tphone, state)
            gui.render(tphone, state)
            next_frame = os.clock() + (state.frame and state.frame.interval or (1 / DEFAULT_REFRESH_RATE))
            state.needs_render = false
        end
    end

    tphone.shutdown("gui")
    return true
end

return gui
