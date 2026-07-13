local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "IdleCube",
        label = "Idle",
        color = C.purple,
        dock = false,
        render_mode = "exclusive",
    },
}

local SAVE_FILE = "save.txt"

local PRODUCERS = {
    {
        key = "bots",
        label = "Bot",
        rate = 0.2,
        base_cost = 15,
        scale = 1.18,
    },
    {
        key = "drills",
        label = "Drill",
        rate = 2,
        base_cost = 120,
        scale = 1.22,
    },
    {
        key = "labs",
        label = "Lab",
        rate = 12,
        base_cost = 900,
        scale = 1.25,
    },
}

local function now()
    return api.time()
end

local function truncate(text, width)
    text = tostring(text or "")
    width = math.max(1, tonumber(width) or 1)
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

local function format_number(value)
    value = tonumber(value) or 0
    local suffixes = {
        { 1000000000, "b" },
        { 1000000, "m" },
        { 1000, "k" },
    }
    for _, suffix in ipairs(suffixes) do
        if value >= suffix[1] then
            return string.format("%.2f%s", value / suffix[1], suffix[2])
        end
    end
    if value >= 100 then
        return tostring(math.floor(value))
    end
    return string.format("%.1f", value)
end

local function parse_save(raw)
    local data = {}
    for line in tostring(raw or ""):gmatch("[^\n]+") do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key then
            data[key] = tonumber(value) or value
        end
    end
    return data
end

local function save_state(state)
    state.last_saved = now()
    local rows = {
        "cubes=" .. tostring(state.cubes or 0),
        "total=" .. tostring(state.total or 0),
        "bots=" .. tostring(state.bots or 0),
        "drills=" .. tostring(state.drills or 0),
        "labs=" .. tostring(state.labs or 0),
        "last_saved=" .. tostring(state.last_saved),
    }
    api.fs.write(SAVE_FILE, table.concat(rows, "\n"))
    state.last_persist = state.last_saved
end

local function production_rate(state)
    local rate = 0
    for _, producer in ipairs(PRODUCERS) do
        rate = rate + ((state[producer.key] or 0) * producer.rate)
    end
    return rate
end

local function apply_gain(state, elapsed_ms)
    elapsed_ms = math.max(0, tonumber(elapsed_ms) or 0)
    local gain = production_rate(state) * (elapsed_ms / 1000)
    if gain > 0 then
        state.cubes = (state.cubes or 0) + gain
        state.total = (state.total or 0) + gain
    end
    return gain
end

local function producer_cost(state, producer)
    local owned = state[producer.key] or 0
    return math.floor(producer.base_cost * (producer.scale ^ owned))
end

local function ensure_state(state)
    if state.ready then
        local current = now()
        apply_gain(state, current - (state.last_tick or current))
        state.last_tick = current
        if current - (state.last_persist or 0) >= 10000 then
            save_state(state)
        end
        return
    end

    local loaded = parse_save(api.fs.read(SAVE_FILE) or "")
    state.ready = true
    state.cubes = tonumber(loaded.cubes) or 0
    state.total = tonumber(loaded.total) or state.cubes
    state.bots = tonumber(loaded.bots) or 0
    state.drills = tonumber(loaded.drills) or 0
    state.labs = tonumber(loaded.labs) or 0
    state.message = nil

    local current = now()
    local saved_at = tonumber(loaded.last_saved) or current
    state.offline_gain = apply_gain(state, current - saved_at)
    state.last_tick = current
    state.last_persist = current
    save_state(state)
end

local function gather(state)
    state.cubes = (state.cubes or 0) + 1
    state.total = (state.total or 0) + 1
    state.message = "+1 cube"
    save_state(state)
end

local function buy(state, index)
    local producer = PRODUCERS[index]
    if not producer then
        return
    end
    local cost = producer_cost(state, producer)
    if (state.cubes or 0) < cost then
        state.message = "Need " .. format_number(cost) .. " cubes"
        return
    end
    state.cubes = state.cubes - cost
    state[producer.key] = (state[producer.key] or 0) + 1
    state.message = producer.label .. " purchased"
    save_state(state)
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)

    write_line(ctx, 0, "IdleCube", C.yellow)
    write_line(ctx, 2, "Cubes: " .. format_number(state.cubes), C.white)
    write_line(ctx, 3, "Rate: " .. format_number(production_rate(state)) .. "/s", C.cyan)
    write_line(ctx, 4, "Total: " .. format_number(state.total), C.lightGray)

    if state.offline_gain and state.offline_gain > 0.01 then
        write_line(ctx, 6, "Offline: +" .. format_number(state.offline_gain), C.green)
    else
        write_line(ctx, 6, "Offline: none", C.lightGray)
    end

    local gather_width = math.min(12, ctx.width)
    local save_width = math.min(8, ctx.width)
    local save_x = ctx.width >= 22 and (ctx.x + 14) or ctx.x
    local save_row = ctx.width >= 22 and 8 or 9

    ctx.buttons.idle_gather = api.screen.button("idle_gather", ctx.x, ctx.y + 8, gather_width, "Gather", {
        fg = C.white,
        bg = C.blue,
    })
    ctx.buttons.idle_save = api.screen.button("idle_save", save_x, ctx.y + save_row, save_width, "Save", {
        fg = C.white,
        bg = C.gray,
    })

    local row = save_row + 2
    for index, producer in ipairs(PRODUCERS) do
        if row >= ctx.height - 2 then
            break
        end
        local owned = state[producer.key] or 0
        local cost = producer_cost(state, producer)
        local label = producer.label .. " " .. tostring(owned) .. " $" .. format_number(cost)
        ctx.buttons["idle_buy_" .. tostring(index)] = api.screen.button("idle_buy_" .. tostring(index), ctx.x, ctx.y + row, math.min(ctx.width, 24), truncate(label, 24), {
            fg = C.white,
            bg = (state.cubes or 0) >= cost and C.green or C.gray,
        })
        row = row + 1
        write_line(ctx, row, "+" .. format_number(producer.rate) .. "/s each", C.lightGray)
        row = row + 2
    end

    if state.message then
        write_line(ctx, ctx.height - 1, state.message, C.green)
    else
        write_line(ctx, ctx.height - 1, "Automates while closed.", C.lightGray)
    end
end

function app.on_touch(ctx)
    local state = ctx.state
    ensure_state(state)
    if ctx.button_id == "idle_gather" then
        gather(state)
        return true
    elseif ctx.button_id == "idle_save" then
        save_state(state)
        state.message = "Saved"
        return true
    end

    local index = tostring(ctx.button_id or ""):match("^idle_buy_(%d+)$")
    if index then
        buy(state, tonumber(index))
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
    if key == keys.space or key == keys.enter then
        gather(state)
        return true
    elseif key == keys.one then
        buy(state, 1)
        return true
    elseif key == keys.two then
        buy(state, 2)
        return true
    elseif key == keys.three then
        buy(state, 3)
        return true
    elseif key == keys.s then
        save_state(state)
        state.message = "Saved"
        return true
    end
    return false
end

function app.on_pause(ctx)
    ensure_state(ctx.state)
    save_state(ctx.state)
end

return app
