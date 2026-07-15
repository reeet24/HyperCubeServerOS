local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "Settings",
        label = "Set",
        color = C.gray,
        dock = true,
        render_mode = "exclusive",
    },
}

local function write_line(ctx, row, text, fg)
    api.screen.write(ctx.x, ctx.y + row, text, fg or C.white, C.black)
end

local function is_ctrl(key)
    return key == keys.leftCtrl
        or key == keys.rightCtrl
        or key == keys.leftControl
        or key == keys.rightControl
        or key == keys.leftCommand
        or key == keys.rightCommand
end

local function unlock_progress(state)
    if not state.dev_combo_started_at then
        return 0
    end
    return math.max(0, api.time() - state.dev_combo_started_at)
end

function app.render(ctx)
    local state = ctx.state
    if api.dev and api.dev.is_enabled and not api.dev.is_enabled() and state.ctrl_down and state.k_down then
        if unlock_progress(state) >= 10000 then
            local ok, err = api.dev.enable()
            state.dev_message = ok and "Developer mode: ON" or tostring(err or "DevModeFailed")
            state.ctrl_down = false
            state.k_down = false
            state.dev_combo_started_at = nil
        end
    end

    ctx.buttons.shutdown = api.screen.button("shutdown", ctx.x, ctx.y, 12, "Shutdown", {
        fg = C.white,
        bg = C.red,
    })
    write_line(ctx, 2, "Device: TPhone")
    write_line(ctx, 3, "OS: HyperCube")
    write_line(ctx, 4, "App sandbox: HCAPI")
    write_line(ctx, 5, "Storage: encrypted HCFS")
    if api.dev and api.dev.is_enabled and api.dev.is_enabled() then
        write_line(ctx, 7, "Developer mode: ON", C.yellow)
        write_line(ctx, 8, "Terminal enabled", C.lightGray)
    elseif state.dev_combo_started_at then
        local remaining = math.max(0, 10 - math.floor(unlock_progress(state) / 1000))
        write_line(ctx, 7, "Developer unlock " .. tostring(remaining), C.lightGray)
    elseif state.dev_message then
        write_line(ctx, 7, state.dev_message, C.lightGray)
    end
end

function app.on_key(ctx)
    local state = ctx.state
    local event = ctx.event
    local key = event.raw and event.raw[2]
    if event.type == "key" then
        if is_ctrl(key) then
            state.ctrl_down = true
        elseif key == keys.k then
            state.k_down = true
        end
        if state.ctrl_down and state.k_down and not state.dev_combo_started_at then
            state.dev_combo_started_at = api.time()
            state.dev_message = nil
        end
        return state.ctrl_down or state.k_down
    elseif event.type == "key_up" then
        if is_ctrl(key) then
            state.ctrl_down = false
        elseif key == keys.k then
            state.k_down = false
        end
        if not (state.ctrl_down and state.k_down) then
            state.dev_combo_started_at = nil
        end
        return true
    end
    return false
end

function app.on_touch(ctx)
    if ctx.button_id == "shutdown" then
        if api.device and api.device.shutdown then
            api.device.shutdown()
        elseif os and os.shutdown then
            os.shutdown()
        end
        return true
    end
    return false
end

return app
