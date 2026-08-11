local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "Storage",
        label = "Disk",
        color = C.green,
        devices = { "TDesktop", "TBusinessDesktop" },
        refresh_rate = 4,
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

local function line(ctx, row, text, fg)
    api.screen.write(ctx.x, ctx.y + row, truncate(text, ctx.width), fg or C.white, C.black)
end

local function ensure_state(state)
    if state.ready then
        return
    end
    state.ready = true
    state.message = nil
end

local function refresh(state)
    if not api.desktop or not api.desktop.drives then
        state.drives = nil
        state.message = "Desktop storage unavailable"
        return
    end
    local drives, err = api.desktop.drives()
    state.drives = drives or {}
    if not drives then
        state.message = tostring(err or "DriveScanFailed")
    end
    state.install_root = api.desktop.install_root and api.desktop.install_root() or nil
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)
    refresh(state)

    line(ctx, 0, "Storage", C.yellow)
    local root = state.install_root
    if type(root) == "table" then
        local label = root.mounted and ("installing to " .. tostring(root.drive or root.root)) or "installing internally"
        line(ctx, 1, label, root.mounted and C.green or C.lightGray)
    end

    ctx.buttons.refresh = api.screen.button("refresh", ctx.x, ctx.y + 3, math.min(9, ctx.width), "Refresh", { fg = C.white, bg = C.blue })

    local row = 5
    if #(state.drives or {}) == 0 then
        line(ctx, row, "No disk drives found.", C.lightGray)
        row = row + 1
    end

    for index, drive in ipairs(state.drives or {}) do
        if row >= ctx.height - 1 then
            break
        end
        local status = drive.formatted and "formatted" or (drive.present and "needs format" or "empty")
        line(ctx, row, tostring(drive.name) .. " - " .. status, drive.formatted and C.green or C.yellow)
        row = row + 1
        if drive.formatted then
            line(ctx, row, truncate(tostring(drive.mount or "") .. " free " .. tostring(drive.free_space or "?"), ctx.width), C.lightGray)
            row = row + 1
        elseif drive.present then
            ctx.buttons["format_" .. index] = api.screen.button("format_" .. index, ctx.x + 2, ctx.y + row, math.max(1, math.min(14, ctx.width - 2)), "Format", { fg = C.white, bg = C.red })
            row = row + 1
        end
    end

    if state.message and ctx.height > 2 then
        line(ctx, ctx.height - 1, state.message, C.cyan)
    end
end

function app.on_touch(ctx)
    local state = ctx.state
    ensure_state(state)
    if ctx.button_id == "refresh" then
        refresh(state)
        if api.apps and api.apps.refresh then
            api.apps.refresh()
        end
        state.message = "Refreshed"
        return true
    end
    local index = tostring(ctx.button_id or ""):match("^format_(%d+)$")
    if index then
        local drive = state.drives and state.drives[tonumber(index)]
        if not drive then
            state.message = "DriveMissing"
            return true
        end
        local ok, result = api.desktop.format_drive(drive.name, "Desktop " .. tostring(drive.name))
        state.message = ok and ("Formatted " .. tostring(drive.name)) or tostring(result)
        refresh(state)
        if ok and api.apps and api.apps.refresh then
            api.apps.refresh()
        end
        return true
    end
    return false
end

return app
