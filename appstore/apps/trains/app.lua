local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "CMR Trains",
        label = "Rail",
        color = C.blue,
        dock = false,
        render_mode = "exclusive",
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

local function write_line(ctx, row, text, fg)
    api.screen.write(ctx.x, ctx.y + row, truncate(text, ctx.width), fg or C.white, C.black)
end

local function request(force)
    if not api.hypernet or not api.hypernet.request then
        return nil, "HyperNetUnavailable"
    end
    local ok, reply, err = pcall(api.hypernet.request, {
        type = "train.schedule",
        force = force == true,
    }, "train.schedule.result", 12)
    if not ok then
        return nil, reply
    end
    return reply, err
end

local function eta_label(minutes)
    minutes = tonumber(minutes)
    if not minutes then
        return "?"
    end
    if minutes <= 0 then
        return "now"
    end
    if minutes >= 60 then
        return tostring(math.floor(minutes / 60)) .. "h" .. tostring(minutes % 60)
    end
    return tostring(minutes) .. "m"
end

local function ensure_state(state)
    if state.ready then
        return
    end
    state.ready = true
    state.loaded = false
    state.trains = {}
    state.error = nil
    state.status = nil
    state.fetched_at = nil
end

local function refresh(state, force)
    state.status = "Loading..."
    local reply, err = request(force)
    state.loaded = true
    state.status = nil
    if reply and reply.ok then
        state.trains = reply.result and reply.result.trains or {}
        state.fetched_at = reply.result and reply.result.fetched_at or nil
        state.error = nil
    else
        state.error = (reply and reply.error) or err or "ScheduleUnavailable"
    end
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)
    if not state.loaded then
        refresh(state, false)
    end

    write_line(ctx, 0, "CMR Train Times", C.yellow)
    ctx.buttons.train_refresh = api.screen.button("train_refresh", ctx.x, ctx.y + 2, 9, "Refresh", {
        fg = C.white,
        bg = C.blue,
    })

    local row = 4
    if #state.trains == 0 then
        write_line(ctx, row, state.error or state.status or "No departures found.", state.error and C.red or C.lightGray)
    else
        for _, train in ipairs(state.trains) do
            if row >= ctx.height - 2 then
                break
            end
            local eta = train.eta and train.eta ~= "" and train.eta or eta_label(train.eta_minutes)
            local head = train.time and tostring(train.time) .. "  " .. eta or "ETA " .. eta
            local dest = train.destination and train.destination ~= "" and train.destination or "Destination unknown"
            if train.direction and train.direction ~= "" and train.direction ~= "unknown" then
                dest = tostring(train.direction) .. " to " .. dest
            end
            write_line(ctx, row, head, C.cyan)
            row = row + 1
            write_line(ctx, row, dest, C.white)
            row = row + 1
            local meta = ""
            if train.train and train.train ~= "" then
                meta = meta .. tostring(train.train)
            end
            if train.platform and train.platform ~= "" then
                meta = meta .. "  Plat " .. tostring(train.platform)
            end
            if train.status and train.status ~= "" then
                meta = meta .. "  " .. tostring(train.status)
            end
            if meta ~= "" and row < ctx.height - 2 then
                write_line(ctx, row, meta, C.lightGray)
                row = row + 1
            end
            row = row + 1
        end
    end

    if state.error then
        write_line(ctx, ctx.height - 1, state.error, C.red)
    elseif state.status then
        write_line(ctx, ctx.height - 1, state.status, C.green)
    else
        write_line(ctx, ctx.height - 1, "Sorted by soonest ETA", C.lightGray)
    end
end

function app.on_touch(ctx)
    local state = ctx.state
    ensure_state(state)
    if ctx.button_id == "train_refresh" then
        refresh(state, true)
        return true
    end
    return false
end

function app.on_key(ctx)
    local state = ctx.state
    ensure_state(state)
    if not keys then
        return false
    end
    local key = ctx.event.raw and ctx.event.raw[2]
    if key == keys.r then
        refresh(state, true)
        return true
    end
    return false
end

return app
