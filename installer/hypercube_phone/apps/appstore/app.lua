local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "App Store",
        label = "Store",
        color = C.orange,
        dock = true,
        render_mode = "exclusive",
    },
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

local function write_line(ctx, row, text, fg)
    api.screen.write(ctx.x, ctx.y + row, truncate(text, ctx.width), fg or C.white, C.black)
end

local function clamp(value, min_value, max_value)
    value = tonumber(value) or min_value
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function draw_frame(ctx, row, height, title)
    local width = math.max(6, ctx.width)
    local inner = math.max(0, width - 2)
    api.screen.write(ctx.x, ctx.y + row, "+" .. string.rep("-", inner) .. "+", C.lightGray, C.black)
    if title and title ~= "" and width > 8 then
        api.screen.write(ctx.x + 2, ctx.y + row, " " .. truncate(title, width - 6) .. " ", C.yellow, C.black)
    end
    for y = row + 1, row + height - 2 do
        api.screen.write(ctx.x, ctx.y + y, "|", C.lightGray, C.black)
        api.screen.write(ctx.x + width - 1, ctx.y + y, "|", C.lightGray, C.black)
    end
    api.screen.write(ctx.x, ctx.y + row + height - 1, "+" .. string.rep("-", inner) .. "+", C.lightGray, C.black)
end

local function max_scroll(state, visible)
    return math.max(0, #state.catalog - math.max(1, visible))
end

local function set_scroll(state, value, visible)
    state.scroll = clamp(value or 0, 0, max_scroll(state, visible))
end

local function ensure_selected_visible(state, visible)
    visible = math.max(1, visible)
    state.selected = clamp(state.selected or 1, 1, math.max(1, #state.catalog))
    if state.selected <= state.scroll then
        state.scroll = state.selected - 1
    elseif state.selected > state.scroll + visible then
        state.scroll = state.selected - visible
    end
    set_scroll(state, state.scroll, visible)
end

local function draw_scroll_marker(ctx, frame_row, frame_height, scroll, max_value)
    if max_value <= 0 or frame_height < 4 then
        return
    end
    local track = frame_height - 2
    local y = frame_row + 1 + math.floor((scroll / max_value) * (track - 1))
    api.screen.write(ctx.x + ctx.width - 1, ctx.y + frame_row + 1, "^", C.yellow, C.black)
    api.screen.write(ctx.x + ctx.width - 1, ctx.y + y, "#", C.white, C.black)
    api.screen.write(ctx.x + ctx.width - 1, ctx.y + frame_row + frame_height - 2, "v", C.yellow, C.black)
end

local function request(message, expected)
    if not api.hypernet or not api.hypernet.request then
        return nil, "HyperNetUnavailable"
    end
    local ok, reply, err = pcall(api.hypernet.request, message, expected, 10)
    if not ok then
        return nil, reply
    end
    return reply, err
end

local function ensure_state(state)
    if state.ready then
        return
    end
    state.ready = true
    state.catalog = {}
    state.selected = 1
    state.scroll = 0
    state.loaded = false
    state.error = nil
    state.status = nil
end

local function refresh(state)
    local reply, err = request({
        type = "appstore.list",
    }, "appstore.list.result")
    if reply and reply.ok then
        state.catalog = reply.result and reply.result.apps or {}
        state.loaded = true
        state.error = nil
        if state.selected > #state.catalog then
            state.selected = math.max(1, #state.catalog)
        end
        state.scroll = clamp(state.scroll or 0, 0, math.max(0, #state.catalog - 1))
    else
        state.loaded = true
        state.error = (reply and reply.error) or err or "StoreUnavailable"
    end
end

local function selected_app(state)
    return state.catalog[state.selected]
end

local function install_selected(state)
    local item = selected_app(state)
    if not item then
        state.error = "No app selected"
        return
    end

    state.status = "Downloading..."
    local reply, err = request({
        type = "appstore.download",
        app_id = item.id,
    }, "appstore.download.result")
    if not reply or not reply.ok then
        state.error = (reply and reply.error) or err or "DownloadFailed"
        state.status = nil
        return
    end

    if not api.apps or not api.apps.install then
        state.error = "Update HyperCube first"
        state.status = nil
        return
    end

    local ok, result = api.apps.install(reply.result)
    if ok then
        state.error = nil
        state.status = "Installed " .. tostring(result.id) .. " (" .. tostring(result.files or 1) .. " files)"
    else
        state.error = result or "InstallFailed"
        state.status = nil
    end
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)
    if not state.loaded then
        refresh(state)
    end

    write_line(ctx, 0, "HyperCube App Store", C.yellow)
    ctx.buttons.store_refresh = api.screen.button("store_refresh", ctx.x, ctx.y + 1, 9, "Refresh", {
        fg = C.white,
        bg = C.blue,
    })

    local frame_row = 3
    local frame_height = math.max(4, ctx.height - 9)
    local visible = math.max(1, frame_height - 2)
    state.list_visible = visible
    ensure_selected_visible(state, visible)
    draw_frame(ctx, frame_row, frame_height, "Apps")

    if #state.catalog == 0 then
        write_line(ctx, frame_row + 1, "No apps available.", C.lightGray)
    else
        local row = frame_row + 1
        for i = state.scroll + 1, math.min(#state.catalog, state.scroll + visible) do
            local item = state.catalog[i]
            local bg = i == state.selected and C.blue or C.gray
            local file_count = item.file_count and (" [" .. tostring(item.file_count) .. "f]") or ""
            local label = tostring(item.title or item.id) .. " " .. tostring(item.version or "") .. file_count
            ctx.buttons["store_select_" .. tostring(i)] = api.screen.button("store_select_" .. tostring(i), ctx.x + 1, ctx.y + row, math.max(4, ctx.width - 2), truncate(label, ctx.width - 4), {
                fg = C.white,
                bg = bg,
            })
            row = row + 1
        end
        draw_scroll_marker(ctx, frame_row, frame_height, state.scroll or 0, max_scroll(state, visible))
    end

    local selected = selected_app(state)
    if selected then
        write_line(ctx, ctx.height - 5, truncate(selected.description or "", ctx.width), C.lightGray)
    end
    ctx.buttons.store_install = api.screen.button("store_install", ctx.x, ctx.y + ctx.height - 3, 10, "Install", {
        fg = C.white,
        bg = selected and C.green or C.gray,
    })

    if state.status then
        write_line(ctx, ctx.height - 1, state.status, C.green)
    elseif state.error then
        write_line(ctx, ctx.height - 1, state.error, C.red)
    end
end

function app.on_touch(ctx)
    local state = ctx.state
    ensure_state(state)
    if ctx.event and ctx.event.type == "scroll" then
        local visible = state.list_visible or 1
        set_scroll(state, (state.scroll or 0) + (ctx.event.direction or 0), visible)
        state.selected = clamp((state.scroll or 0) + 1, 1, math.max(1, #state.catalog))
        return true
    elseif ctx.button_id == "store_refresh" then
        refresh(state)
        return true
    elseif ctx.button_id == "store_install" then
        install_selected(state)
        return true
    end

    local index = tostring(ctx.button_id or ""):match("^store_select_(%d+)$")
    if index then
        state.selected = tonumber(index) or state.selected
        state.status = nil
        state.error = nil
        return true
    end
    return false
end

function app.on_key(ctx)
    local state = ctx.state
    ensure_state(state)
    local key = ctx.event.raw and ctx.event.raw[2]
    if not keys then
        return false
    end
    if key == keys.up then
        state.selected = math.max(1, state.selected - 1)
        ensure_selected_visible(state, state.list_visible or 1)
        return true
    elseif key == keys.down then
        state.selected = math.min(math.max(1, #state.catalog), state.selected + 1)
        ensure_selected_visible(state, state.list_visible or 1)
        return true
    elseif key == keys.enter then
        install_selected(state)
        return true
    end
    return false
end

return app
