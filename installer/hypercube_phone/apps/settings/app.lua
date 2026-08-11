local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "Settings",
        label = "Set",
        color = C.gray,
        dock = true,
        render_mode = "exclusive",
        refresh_rate = 10,
    },
}

local function write_line(ctx, row, text, fg)
    api.screen.write(ctx.x, ctx.y + row, text, fg or C.white, C.black)
end

local function truncate(text, width)
    text = tostring(text or "")
    width = math.max(1, tonumber(width) or 1)
    if #text <= width then
        return text
    end
    if width <= 1 then
        return text:sub(1, width)
    end
    return text:sub(1, width - 1) .. ">"
end

local function format_space(value)
    if value == nil then
        return "?"
    end
    if value == "unlimited" then
        return "unlimited"
    end
    value = tonumber(value)
    if not value then
        return "?"
    end
    if value >= 1024 * 1024 then
        return tostring(math.floor(value / (1024 * 1024) * 10 + 0.5) / 10) .. " MB"
    end
    if value >= 1024 then
        return tostring(math.floor(value / 1024 * 10 + 0.5) / 10) .. " KB"
    end
    return tostring(value) .. " B"
end

local function storage_line(info)
    info = type(info) == "table" and info or {}
    local free = format_space(info.free_space)
    local capacity = format_space(info.capacity)
    if capacity == "?" or capacity == "unlimited" then
        return free .. " free"
    end
    return free .. " / " .. capacity .. " free"
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

local function update_dev_unlock(state)
    if api.dev and api.dev.is_enabled and not api.dev.is_enabled() and state.ctrl_down and state.k_down then
        if unlock_progress(state) >= 10000 then
            local ok, err = api.dev.enable()
            state.dev_message = ok and "Developer mode: ON" or tostring(err or "DevModeFailed")
            state.ctrl_down = false
            state.k_down = false
            state.dev_combo_started_at = nil
            return true
        end
    end
    return false
end

function app.render(ctx)
    local state = ctx.state
    local row = 2

    ctx.buttons.shutdown = api.screen.button("shutdown", ctx.x, ctx.y, 12, "Shutdown", {
        fg = C.white,
        bg = C.red,
    })
    ctx.buttons.sign_out = api.screen.button("sign_out", ctx.x + 13, ctx.y, 10, "Sign Out", {
        fg = C.white,
        bg = C.orange,
    })
    write_line(ctx, row, "Device: " .. tostring(api.device and api.device.type or "TPhone"))
    row = row + 1
    write_line(ctx, row, "OS: HyperCube")
    row = row + 1
    write_line(ctx, row, "App sandbox: HCAPI")
    row = row + 1
    write_line(ctx, row, "Storage: encrypted HCFS")
    row = row + 2

    write_line(ctx, row, "Space", C.cyan)
    row = row + 1
    local storage = api.device and api.device.storage and api.device.storage() or nil
    if storage and storage.internal then
        write_line(ctx, row, "Device: " .. storage_line(storage.internal), C.lightGray)
        row = row + 1
    else
        write_line(ctx, row, "Device: unavailable", C.orange)
        row = row + 1
    end
    local drives = storage and storage.drives or {}
    if #drives > 0 then
        for _, drive in ipairs(drives) do
            if row >= ctx.height - 2 then
                write_line(ctx, row, "+" .. tostring(#drives) .. " drives", C.lightGray)
                row = row + 1
                break
            end
            local label = tostring(drive.label or drive.name or "Drive")
            if drive.mount then
                write_line(ctx, row, label .. ": " .. storage_line(drive), drive.formatted == false and C.orange or C.lightGray)
            else
                write_line(ctx, row, label .. ": no disk", C.orange)
            end
            row = row + 1
        end
    else
        write_line(ctx, row, "Drives: none connected", C.lightGray)
        row = row + 1
    end

    if api.dev and api.dev.is_enabled and api.dev.is_enabled() then
        row = row + 1
        write_line(ctx, row, "Developer mode: ON", C.yellow)
        write_line(ctx, row + 1, "Terminal enabled", C.lightGray)
    elseif state.dev_combo_started_at then
        local remaining = math.max(0, 10 - math.floor(unlock_progress(state) / 1000))
        row = row + 1
        write_line(ctx, row, "Developer unlock " .. tostring(remaining), C.lightGray)
    elseif state.dev_message then
        row = row + 1
        write_line(ctx, row, state.dev_message, C.lightGray)
    end

    if api.identity and api.identity.username == "tesserac" then
        row = row + 2
        write_line(ctx, row, "Recovery", C.cyan)
        row = row + 1
        ctx.buttons.recovery_refresh = api.screen.button("recovery_refresh", ctx.x, ctx.y + row, 8, "Refresh", {
            fg = C.white,
            bg = C.blue,
        })
        ctx.buttons.recovery_approve = api.screen.button("recovery_approve", ctx.x + 9, ctx.y + row, 8, "Approve", {
            fg = C.white,
            bg = C.green,
        })
        row = row + 1
        if state.recovery_message then
            write_line(ctx, row, truncate(state.recovery_message, ctx.width), C.lightGray)
            row = row + 1
        end
        local requests = state.recovery_requests or {}
        if #requests == 0 then
            write_line(ctx, row, "No pending recovery requests", C.lightGray)
        else
            local request = requests[1]
            write_line(ctx, row, "Pending: " .. tostring(#requests), C.yellow)
            row = row + 1
            write_line(ctx, row, truncate(tostring(request.username or request.tesserac_id), ctx.width), C.white)
            row = row + 1
            write_line(ctx, row, truncate("Req: " .. tostring(request.request_id), ctx.width), C.lightGray)
        end
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

function app.on_tick(ctx)
    return update_dev_unlock(ctx.state)
end

function app.on_touch(ctx)
    if ctx.button_id == "shutdown" then
        if api.device and api.device.shutdown then
            api.device.shutdown()
        elseif os and os.shutdown then
            os.shutdown()
        end
        return true
    elseif ctx.button_id == "sign_out" then
        if api.device and api.device.sign_out then
            api.device.sign_out()
        end
        return true
    elseif ctx.button_id == "recovery_refresh" then
        local ok, result = api.auth and api.auth.recovery_list and api.auth.recovery_list()
        if ok then
            ctx.state.recovery_requests = result.requests or {}
            ctx.state.recovery_message = "Loaded " .. tostring(#ctx.state.recovery_requests)
        else
            ctx.state.recovery_message = tostring(result or "RecoveryListFailed")
        end
        return true
    elseif ctx.button_id == "recovery_approve" then
        local requests = ctx.state.recovery_requests or {}
        local request = requests[1]
        if not request then
            ctx.state.recovery_message = "No pending requests"
            return true
        end
        local ok, result = api.auth and api.auth.recovery_approve and api.auth.recovery_approve(request.request_id)
        if ok then
            table.remove(requests, 1)
            ctx.state.recovery_requests = requests
            ctx.state.recovery_message = "Approved " .. tostring(result.username or request.username)
        else
            ctx.state.recovery_message = tostring(result or "RecoveryApproveFailed")
        end
        return true
    end
    return false
end

return app
