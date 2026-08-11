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
}

local function truncate(text, width)
    text = tostring(text or "")
    width = math.max(0, tonumber(width) or 0)
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

local function is_business(tphone)
    return tostring(tphone and tphone.device or "") == "TBusinessDesktop"
end

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

local function find_app(state, id)
    for _, app in ipairs(state.installed_apps or {}) do
        if app.manifest.id == id then
            return app
        end
    end
    return nil
end

local function current_refresh_rate(state)
    local max_rate = DEFAULT_REFRESH_RATE
    for _, window in ipairs(state.windows or {}) do
        if not window.minimized then
            max_rate = math.max(max_rate, app_refresh_rate(find_app(state, window.app_id)))
        end
    end
    return max_rate
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

local function dock_order(app)
    local id = app and app.manifest and app.manifest.id
    local priority = {
        appstore = 1,
        messages = 2,
        banking = 3,
        browser = 4,
        files = 5,
        word = 6,
        settings = 7,
    }
    return priority[id] or 50
end

local function draw_wallpaper(screen, width, height)
    screen:clear(C.black)
    for y = 1, height do
        local bg = C.cyan
        if y > height * 0.28 then bg = C.blue end
        if y > height * 0.68 then bg = C.gray end
        screen:rect(1, y, width, 1, bg)
    end
end

local function draw_menu_bar(screen, tphone, width)
    screen:rect(1, 1, width, 1, C.white)
    local product = is_business(tphone) and "Business Desktop" or "Desktop"
    local right = network_summary(tphone) .. "  " .. time_label()
    if tphone.dev_mode then
        right = "DEV  " .. right
    end
    local left_width = width
    if width > #right + 4 then
        left_width = width - #right - 3
    end
    screen:write(2, 1, truncate("HyperCube " .. product, math.max(1, left_width - 1)), C.black, C.white)
    if width > #right + 2 then
        screen:write(width - #right, 1, right, C.black, C.white)
    end
end

local function home_grid_metrics(width, height)
    local icon_w = width < 34 and 5 or 7
    local icon_h = width < 34 and 1 or 3
    local gap = width < 34 and 1 or 2
    local row_step = width < 34 and 3 or 5
    local start_y = 4
    local cols = math.max(2, math.min(4, math.floor((width - 4) / (icon_w + gap))))
    local rows = math.max(1, math.floor((math.max(start_y, height - 7) - start_y) / row_step) + 1)
    return {
        icon_w = icon_w,
        icon_h = icon_h,
        gap = gap,
        row_step = row_step,
        start_y = start_y,
        cols = cols,
        capacity = math.max(1, cols * rows),
    }
end

local function clamp_page(page, page_count)
    page = math.floor(tonumber(page) or 1)
    page_count = math.max(1, math.floor(tonumber(page_count) or 1))
    return math.max(1, math.min(page, page_count))
end

local function layout_apps(width, height, installed, page)
    local icons = {}
    local metrics = home_grid_metrics(width, height)
    local page_count = math.max(1, math.ceil(#(installed or {}) / metrics.capacity))
    page = clamp_page(page, page_count)
    local first = (page - 1) * metrics.capacity + 1
    local last = math.min(#(installed or {}), first + metrics.capacity - 1)
    local total_w = metrics.cols * metrics.icon_w + (metrics.cols - 1) * metrics.gap
    local start_x = math.max(2, math.floor((width - total_w) / 2) + 1)

    for i = first, last do
        local app = installed[i]
        local local_index = i - first
        local col = local_index % metrics.cols
        local row = math.floor(local_index / metrics.cols)
        icons[#icons + 1] = {
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

local function draw_app_icon(screen, item)
    local bg = item.manifest.color or C.gray
    local label = truncate(item.manifest.label or item.id, item.w)
    screen:rect(item.x, item.y, item.w, item.h, bg)
    screen:write(item.x + math.floor((item.w - #label) / 2), item.y, label, C.white, bg)
    screen:write(item.x, item.y + item.h, truncate(item.manifest.title, item.w), C.white, C.black)
end

local function app_hit(item, x, y)
    return x >= item.x and x < item.x + item.w and y >= item.y and y <= item.y + item.h
end

local function hit_app(apps, x, y)
    for _, app in ipairs(apps or {}) do
        if app_hit(app, x, y) then
            return app.id
        end
    end
    return nil
end

local function draw_dock(screen, width, height, installed, windows)
    local dock_y = height
    local dock_w = math.min(width - 4, math.max(18, math.floor(width * 0.72)))
    local dock_x = center_x(width, string.rep(" ", dock_w))
    local dock_apps = {}
    for _, app in ipairs(installed or {}) do
        if app.manifest.dock then
            dock_apps[#dock_apps + 1] = app
        end
    end
    if #dock_apps == 0 then
        for _, app in ipairs(installed or {}) do
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
    local max_dock = math.max(3, math.min(8, math.floor((dock_w - 2) / 7)))
    while #dock_apps > max_dock do
        dock_apps[#dock_apps] = nil
    end

    screen:rect(dock_x, dock_y, dock_w, 1, C.lightGray)
    local buttons = {}
    local button_w = #dock_apps > 0 and math.max(5, math.floor((dock_w - 2) / #dock_apps)) or 5
    local x = dock_x + 1
    for _, app in ipairs(dock_apps) do
        local open = false
        for _, window in ipairs(windows or {}) do
            if window.app_id == app.manifest.id then
                open = true
                break
            end
        end
        local label = truncate((open and "*" or "") .. (app.manifest.label or app.manifest.id), button_w)
        buttons["dock_" .. app.manifest.id] = screen:button("dock_" .. app.manifest.id, x, dock_y, button_w, label, {
            fg = C.white,
            bg = app.manifest.color or C.blue,
        })
        x = x + button_w
    end
    return buttons
end

local function draw_home_pager(screen, state, width, height)
    if (state.home_page_count or 1) <= 1 then
        return {}
    end
    local y = math.max(2, height - 6)
    local label = tostring(state.home_page or 1) .. "/" .. tostring(state.home_page_count or 1)
    screen:write(center_x(width, label), y, label, C.white, C.black)
    return {
        home_prev_page = screen:button("home_prev_page", 2, y, 3, "<", { fg = C.white, bg = C.blue }),
        home_next_page = screen:button("home_next_page", math.max(1, width - 4), y, 3, ">", { fg = C.white, bg = C.blue }),
    }
end

local function find_window(state, window_id)
    for _, window in ipairs(state.windows or {}) do
        if window.id == window_id then
            return window
        end
    end
    return nil
end

local function find_window_for_app(state, app_id)
    for _, window in ipairs(state.windows or {}) do
        if window.app_id == app_id and not window.popup then
            return window
        end
    end
    return nil
end

local function window_bounds(window, width, height)
    if window.fullscreen then
        return 1, 2, width, math.max(5, height - 2)
    end
    return window.x, window.y, window.w, window.h
end

local function clamp_window(window, width, height)
    if not window or window.fullscreen then
        return
    end
    window.w = math.max(18, math.min(tonumber(window.w) or 30, math.max(18, width - 2)))
    window.h = math.max(7, math.min(tonumber(window.h) or 12, math.max(7, height - 3)))
    window.x = math.max(1, math.min(tonumber(window.x) or 2, math.max(1, width - window.w + 1)))
    window.y = math.max(2, math.min(tonumber(window.y) or 3, math.max(2, height - window.h)))
end

local function window_content_rect(window, width, height)
    local x, y, w, h = window_bounds(window, width, height)
    return {
        x = x + 1,
        y = y + 2,
        width = math.max(1, w - 2),
        height = math.max(1, h - 3),
    }
end

local function hit_window(state, x, y, width, height)
    for index = #(state.windows or {}), 1, -1 do
        local window = state.windows[index]
        if not window.minimized then
            local wx, wy, ww, wh = window_bounds(window, width, height)
            if x >= wx and x < wx + ww and y >= wy and y < wy + wh then
                return window
            end
        end
    end
    return nil
end

local function bring_front(tphone, state, window)
    if not window then
        return false
    end
    local previous = find_window(state, state.active_window_id)
    if previous and previous.id ~= window.id then
        local previous_app = find_app(state, previous.app_id)
        if previous_app and type(previous_app.on_pause) == "function" then
            local ctx = { active = false, desktop = true, window = previous, state = state.app_state[previous.app_id] or {} }
            state.app_state[previous.app_id] = ctx.state
            pcall(previous_app.on_pause, ctx)
        end
    end
    for index, item in ipairs(state.windows or {}) do
        if item.id == window.id then
            table.remove(state.windows, index)
            break
        end
    end
    state.windows[#state.windows + 1] = window
    window.minimized = false
    state.active_window_id = window.id
    state.active_app = window.app_id

    local app = find_app(state, window.app_id)
    if app and type(app.on_resume) == "function" then
        local launch = state.app_launch and state.app_launch[window.app_id] or nil
        local ctx = {
            active = true,
            desktop = true,
            window = window,
            state = state.app_state[window.app_id] or {},
            launch = launch,
            open_file = launch and launch.open_file or nil,
        }
        state.app_state[window.app_id] = ctx.state
        local ok, err = pcall(app.on_resume, ctx)
        if not ok and tphone.logger then
            tphone.logger.warn("app resume failed " .. tostring(window.app_id) .. ": " .. tostring(err), tphone.root_context)
        end
    end
    return true
end

local function open_app(tphone, state, app_id, launch)
    local app = find_app(state, app_id)
    if not app then
        return false, "AppNotFound"
    end
    state.app_launch = state.app_launch or {}
    if launch then
        state.app_launch[app_id] = launch
    end
    local window = find_window_for_app(state, app_id)
    if not window then
        local width, height = tphone.screen:get_size()
        local offset = (#(state.windows or {}) % 4) * 2
        state.next_window_id = (state.next_window_id or 0) + 1
        window = {
            id = state.next_window_id,
            app_id = app_id,
            x = 3 + offset,
            y = 3 + offset,
            w = math.max(20, math.min(width - 4, math.floor(width * 0.72))),
            h = math.max(8, math.min(height - 5, math.floor(height * 0.70))),
            minimized = false,
            fullscreen = app_render_mode(app) == "borderless-exclusive",
            title = app.manifest.title,
        }
        clamp_window(window, width, height)
        state.windows[#state.windows + 1] = window
    end
    return bring_front(tphone, state, window)
end

local function open_popup(tphone, state, app_id, kind, options)
    local app = find_app(state, app_id)
    if not app then
        return false, "AppNotFound"
    end
    options = options or {}
    local width, height = tphone.screen:get_size()
    local parent = find_window(state, state.active_window_id)
    if not parent or parent.app_id ~= app_id then
        parent = find_window_for_app(state, app_id)
    end
    state.next_window_id = (state.next_window_id or 0) + 1
    local popup_w = math.max(18, math.min(tonumber(options.width) or 30, math.max(18, width - 2)))
    local popup_h = math.max(6, math.min(tonumber(options.height) or 12, math.max(6, height - 3)))
    local x = tonumber(options.x)
    local y = tonumber(options.y)
    if not x or not y then
        if parent then
            local px, py, pw = window_bounds(parent, width, height)
            x = px + math.max(1, math.floor((pw - popup_w) / 2))
            y = py + 2
        else
            x = math.max(1, math.floor((width - popup_w) / 2) + 1)
            y = math.max(2, math.floor((height - popup_h) / 2) + 1)
        end
    end
    local window = {
        id = state.next_window_id,
        app_id = app_id,
        x = x,
        y = y,
        w = popup_w,
        h = popup_h,
        minimized = false,
        fullscreen = false,
        popup = true,
        popup_kind = tostring(kind or "popup"),
        popup_data = type(options.data) == "table" and options.data or {},
        parent_id = parent and parent.id or nil,
        title = tostring(options.title or "") ~= "" and tostring(options.title) or tostring(kind or "Popup"),
    }
    clamp_window(window, width, height)
    state.windows[#state.windows + 1] = window
    return bring_front(tphone, state, window)
end

local function close_window(tphone, state, window)
    if not window then
        return false
    end
    local app = find_app(state, window.app_id)
    if app and type(app.on_pause) == "function" then
        local ctx = { active = false, desktop = true, window = window, state = state.app_state[window.app_id] or {} }
        state.app_state[window.app_id] = ctx.state
        pcall(app.on_pause, ctx)
    end
    if app and type(app.on_close) == "function" then
        local ctx = { active = false, desktop = true, window = window, state = state.app_state[window.app_id] or {} }
        state.app_state[window.app_id] = ctx.state
        pcall(app.on_close, ctx)
    end
    for index, item in ipairs(state.windows or {}) do
        if item.id == window.id then
            table.remove(state.windows, index)
            break
        end
    end
    local top = state.windows[#state.windows]
    state.active_window_id = top and top.id or nil
    state.active_app = top and top.app_id or nil
    return true
end

local function resize_window(window, delta_w, delta_h, screen_width, screen_height)
    if not window or window.fullscreen then
        return false
    end
    window.w = (window.w or 30) + (tonumber(delta_w) or 0)
    window.h = (window.h or 12) + (tonumber(delta_h) or 0)
    clamp_window(window, screen_width, screen_height)
    return true
end

local function app_context(state, window, layout, active)
    return {
        x = layout.x,
        y = layout.y,
        width = layout.width,
        height = layout.height,
        render_mode = window.fullscreen and "fullscreen-window" or "desktop-window",
        desktop = true,
        active = active == true,
        window = {
            id = window.id,
            app_id = window.app_id,
            fullscreen = window.fullscreen == true,
            minimized = window.minimized == true,
            popup = window.popup == true,
            popup_kind = window.popup_kind,
            popup_data = window.popup_data or {},
            parent_id = window.parent_id,
            width = layout.width,
            height = layout.height,
        },
        frame = frame_snapshot(state),
        buttons = {},
        state = state.app_state[window.app_id] or {},
    }
end

local function register_window_button(state, id, button, meta)
    state.buttons[id] = button
    state.button_map[id] = meta
    state.button_order = state.button_order or {}
    state.button_order[#state.button_order + 1] = id
end

local function draw_window(tphone, state, window, width, height)
    local screen = tphone.screen
    local app = find_app(state, window.app_id)
    if not app or window.minimized then
        return
    end
    clamp_window(window, width, height)
    local wx, wy, ww, wh = window_bounds(window, width, height)
    local active = state.active_window_id == window.id
    local title_bg = active and C.white or C.lightGray
    local title_fg = C.black
    local body_bg = C.black

    screen:rect(wx, wy, ww, wh, body_bg)
    screen:border(wx, wy, ww, wh, active and C.white or C.lightGray, body_bg)
    screen:rect(wx + 1, wy, math.max(1, ww - 2), 1, title_bg)

    local prefix = "wm_" .. tostring(window.id) .. "_"
    register_window_button(state, prefix .. "close", screen:button(prefix .. "close", wx + 1, wy, 1, "x", { fg = C.red, bg = title_bg }), { kind = "wm", action = "close", window = window.id })
    local title_x = wx + 3
    if not window.popup then
        register_window_button(state, prefix .. "min", screen:button(prefix .. "min", wx + 3, wy, 1, "_", { fg = C.yellow, bg = title_bg }), { kind = "wm", action = "minimize", window = window.id })
        register_window_button(state, prefix .. "full", screen:button(prefix .. "full", wx + 5, wy, 2, window.fullscreen and "w" or "[]", { fg = C.green, bg = title_bg }), { kind = "wm", action = "fullscreen", window = window.id })
        register_window_button(state, prefix .. "small", screen:button(prefix .. "small", wx + 8, wy, 1, "-", { fg = C.black, bg = title_bg }), { kind = "wm", action = "shrink", window = window.id })
        register_window_button(state, prefix .. "large", screen:button(prefix .. "large", wx + 10, wy, 1, "+", { fg = C.black, bg = title_bg }), { kind = "wm", action = "grow", window = window.id })
        title_x = wx + 12
    end
    if ww > (title_x - wx + 2) then
        register_window_button(state, prefix .. "focus", screen:button(prefix .. "focus", title_x, wy, math.max(1, wx + ww - title_x - 1), "", { fg = title_fg, bg = title_bg }), { kind = "wm", action = "focus", window = window.id })
    end
    screen:write(title_x, wy, truncate(window.title or app.manifest.title or window.app_id, math.max(1, wx + ww - title_x - 1)), title_fg, title_bg)

    local layout = window_content_rect(window, width, height)
    local ctx = app_context(state, window, layout, active)
    state.app_state[window.app_id] = ctx.state
    if type(app.render) == "function" then
        local ok, err = pcall(app.render, ctx)
        if not ok then
            screen:write(layout.x, layout.y, "App crashed:", C.red, C.black)
            screen:write(layout.x, layout.y + 1, truncate(err, layout.width), C.lightGray, C.black)
        end
    else
        screen:write(layout.x, layout.y, "This app has no renderer.", C.lightGray, C.black)
    end

    for id, button in pairs(ctx.buttons) do
        local mapped = prefix .. "app_" .. tostring(id)
        register_window_button(state, mapped, button, { kind = "app", button_id = id, window = window.id })
    end
end

local function render_desktop(tphone, state)
    local screen = tphone.screen
    local width, height = screen:get_size()
    state.buttons = {}
    state.button_map = {}
    state.button_order = {}

    draw_wallpaper(screen, width, height)
    draw_menu_bar(screen, tphone, width)
    state.apps, state.home_page, state.home_page_count = layout_apps(width, height, state.installed_apps, state.home_page)
    for _, app in ipairs(state.apps) do
        draw_app_icon(screen, app)
    end

    local pager = draw_home_pager(screen, state, width, height)
    for id, button in pairs(pager) do
        state.buttons[id] = button
        state.button_map[id] = { kind = "pager", action = id }
        state.button_order[#state.button_order + 1] = id
    end

    for _, window in ipairs(state.windows or {}) do
        draw_window(tphone, state, window, width, height)
    end

    local dock = draw_dock(screen, width, height, state.installed_apps, state.windows)
    for id, button in pairs(dock) do
        state.buttons[id] = button
        state.button_map[id] = { kind = "dock", app_id = tostring(id):gsub("^dock_", "") }
        state.button_order[#state.button_order + 1] = id
    end
    screen:present()
end

function gui.render(tphone, state)
    render_desktop(tphone, state or {})
    return true
end

local function hit_button(buttons, order, x, y)
    if order then
        for index = #order, 1, -1 do
            local id = order[index]
            local button = buttons and buttons[id] or nil
            if button and button:contains(x, y) then
                return id
            end
        end
    end
    for id, button in pairs(buttons or {}) do
        if button:contains(x, y) then
            return id
        end
    end
    return nil
end

local function dispatch_touch(tphone, state, window, button_id, event)
    local app = window and find_app(state, window.app_id)
    if not app or type(app.on_touch) ~= "function" then
        return false
    end
    local width, height = tphone.screen:get_size()
    local layout = window_content_rect(window, width, height)
    local ctx = app_context(state, window, layout, state.active_window_id == window.id)
    ctx.button_id = button_id
    ctx.event = event
    state.app_state[window.app_id] = ctx.state
    local ok, consumed_or_err = pcall(app.on_touch, ctx)
    if not ok and tphone.logger then
        tphone.logger.warn("app touch failed " .. tostring(window.app_id) .. ": " .. tostring(consumed_or_err), tphone.root_context)
        return false
    end
    return consumed_or_err == true
end

local function dispatch_key(tphone, state, event)
    local window = find_window(state, state.active_window_id)
    local app = window and find_app(state, window.app_id)
    if not app or window.minimized or type(app.on_key) ~= "function" then
        return false
    end
    local width, height = tphone.screen:get_size()
    local layout = window_content_rect(window, width, height)
    local ctx = app_context(state, window, layout, true)
    ctx.event = event
    state.app_state[window.app_id] = ctx.state
    local ok, consumed_or_err = pcall(app.on_key, ctx)
    if not ok and tphone.logger then
        tphone.logger.warn("app key failed " .. tostring(window.app_id) .. ": " .. tostring(consumed_or_err), tphone.root_context)
        return false
    end
    return consumed_or_err == true
end

local function dispatch_ticks(tphone, state)
    for _, window in ipairs(state.windows or {}) do
        local app = find_app(state, window.app_id)
        if app and not window.minimized and type(app.on_tick) == "function" then
            local width, height = tphone.screen:get_size()
            local layout = window_content_rect(window, width, height)
            local ctx = app_context(state, window, layout, state.active_window_id == window.id)
            state.app_state[window.app_id] = ctx.state
            local ok, err = pcall(app.on_tick, ctx)
            if not ok and tphone.logger then
                tphone.logger.warn("app tick failed " .. tostring(window.app_id) .. ": " .. tostring(err), tphone.root_context)
            end
        end
    end
end

local function apply_window_action(tphone, state, action, window)
    if not window then
        return false
    end
    local width, height = tphone.screen:get_size()
    if action == "focus" then
        return bring_front(tphone, state, window)
    elseif action == "close" then
        return close_window(tphone, state, window)
    elseif action == "minimize" then
        window.minimized = true
        local top = state.windows[#state.windows]
        if top and top.id == window.id then
            state.active_window_id = nil
            state.active_app = nil
            for index = #state.windows, 1, -1 do
                if not state.windows[index].minimized then
                    bring_front(tphone, state, state.windows[index])
                    break
                end
            end
        end
        return true
    elseif action == "fullscreen" then
        bring_front(tphone, state, window)
        window.fullscreen = not window.fullscreen
        return true
    elseif action == "restore" then
        window.minimized = false
        window.fullscreen = false
        return bring_front(tphone, state, window)
    elseif action == "grow" then
        bring_front(tphone, state, window)
        return resize_window(window, 6, 3, width, height)
    elseif action == "shrink" then
        bring_front(tphone, state, window)
        return resize_window(window, -6, -3, width, height)
    end
    return false
end

local function file_extension(path)
    return tostring(path or ""):match("%.([^%./]+)$")
end

local function handle_shell_request(tphone, state)
    local request = tphone.shell_request
    if type(request) ~= "table" then
        return false
    end
    tphone.shell_request = nil
    if request.type == "open_file" then
        local ext = tostring(file_extension(request.path) or ""):lower()
        if ext == "txt" then
            open_app(tphone, state, "word", { open_file = request.path })
            return true
        end
    elseif request.type == "window" then
        if request.action == "open_popup" then
            return open_popup(tphone, state, request.app_id, request.kind, request)
        end
        local active = find_window(state, state.active_window_id)
        local window = active and active.app_id == request.app_id and active or find_window_for_app(state, request.app_id)
        if request.action == "set_title" and window then
            window.title = tostring(request.title or "")
            return true
        end
        return apply_window_action(tphone, state, request.action, window)
    end
    return false
end

local function move_home_page(state, delta)
    state.home_page = clamp_page((state.home_page or 1) + (tonumber(delta) or 0), state.home_page_count or 1)
end

local function handle_button(tphone, state, id, event)
    local meta = state.button_map and state.button_map[id] or nil
    if not meta then
        return false
    end
    if meta.kind == "dock" then
        open_app(tphone, state, meta.app_id)
        return true
    elseif meta.kind == "pager" then
        move_home_page(state, meta.action == "home_next_page" and 1 or -1)
        return true
    elseif meta.kind == "wm" then
        return apply_window_action(tphone, state, meta.action, find_window(state, meta.window))
    elseif meta.kind == "app" then
        local window = find_window(state, meta.window)
        bring_front(tphone, state, window)
        return dispatch_touch(tphone, state, window, meta.button_id, event)
    end
    return false
end

function gui.run(tphone)
    local screen = tphone.screen
    if not screen then
        print("HyperCubeDesktop is running, but no screen driver is available.")
        return false, "ScreenUnavailable"
    end

    local state = {
        installed_apps = app_manager.load_all(tphone),
        app_state = {},
        app_launch = {},
        apps = {},
        buttons = {},
        button_map = {},
        windows = {},
        next_window_id = 0,
        active_window_id = nil,
        active_app = nil,
        home_page = 1,
        home_page_count = 1,
        running = true,
    }
    if tphone.identity and tphone.tesseracid and tphone.tesseracid.save_local then
        tphone.tesseracid.save_local(tphone.identity)
    end

    tphone.logger.info("desktop gui started", tphone.root_context)
    advance_frame(state)
    gui.render(tphone, state)
    local next_frame = os.clock() + (state.frame and state.frame.interval or (1 / DEFAULT_REFRESH_RATE))

    while state.running do
        if tphone.apps_dirty then
            state.installed_apps = app_manager.load_all(tphone)
            tphone.apps_dirty = false
            state.needs_render = true
        end
        if handle_shell_request(tphone, state) then
            state.needs_render = true
        end

        local timeout = math.max(0, next_frame - os.clock())
        local event = screen:pull_event(timeout)
        if event and event.type == "touch" then
            local button_id = hit_button(state.buttons, state.button_order, event.x, event.y)
            if button_id and handle_button(tphone, state, button_id, event) then
                state.needs_render = true
            else
                local width, height = screen:get_size()
                local window = hit_window(state, event.x, event.y, width, height)
                if window then
                    bring_front(tphone, state, window)
                    local layout = window_content_rect(window, width, height)
                    if event.x >= layout.x and event.x < layout.x + layout.width and event.y >= layout.y and event.y < layout.y + layout.height then
                        dispatch_touch(tphone, state, window, nil, event)
                    end
                    state.needs_render = true
                else
                    local app_id = hit_app(state.apps, event.x, event.y)
                    if app_id then
                        open_app(tphone, state, app_id)
                        state.needs_render = true
                    end
                end
            end
        elseif event and event.type == "scroll" then
            local width, height = screen:get_size()
            local window = hit_window(state, event.x, event.y, width, height) or find_window(state, state.active_window_id)
            if window then
                bring_front(tphone, state, window)
                dispatch_touch(tphone, state, window, nil, event)
            else
                move_home_page(state, tonumber(event.direction or 0) > 0 and 1 or -1)
            end
            state.needs_render = true
        elseif event and (event.type == "key" or event.type == "key_up" or event.type == "char" or event.type == "paste") then
            dispatch_key(tphone, state, event)
            state.needs_render = true
        elseif event and event.type == "resize" then
            local width, height = screen:get_size()
            for _, window in ipairs(state.windows or {}) do
                clamp_window(window, width, height)
            end
            state.needs_render = true
        end

        if os.clock() >= next_frame then
            advance_frame(state)
            dispatch_ticks(tphone, state)
            gui.render(tphone, state)
            next_frame = os.clock() + (state.frame and state.frame.interval or (1 / DEFAULT_REFRESH_RATE))
            state.needs_render = false
        end
    end

    tphone.shutdown("desktop_gui")
    return true
end

return gui
