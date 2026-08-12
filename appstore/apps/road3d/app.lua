local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "Road3D",
        label = "Race",
        color = C.red,
        dock = false,
        render_mode = "exclusive",
        refresh_rate = 30,
    },
}

local SAVE_FILE = "best.txt"
local SEGMENTS = 14
local ROAD_DEPTH = 84
local MAX_SPEED = 1.85
local MIN_SPEED = 0.55

local function clamp(value, min_value, max_value)
    value = tonumber(value) or min_value
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
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

local function now()
    return api.time()
end

local function read_best()
    return tonumber(api.fs.read(SAVE_FILE) or "0") or 0
end

local function save_best(score)
    api.fs.write(SAVE_FILE, tostring(math.floor(tonumber(score) or 0)))
end

local function ensure_state(state)
    if state.ready then
        return
    end
    state.ready = true
    state.running = true
    state.player_x = 0
    state.speed = 0.9
    state.distance = 0
    state.score = 0
    state.best = read_best()
    state.health = 3
    state.message = "Arrow keys steer"
    state.last_tick = now()
    state.last_hit = 0
    state.flash = 0
end

local function rect(x, y, w, h, bg)
    api.screen.rect(math.floor(x), math.floor(y), math.floor(w), math.floor(h), bg)
end

local function tri(x1, y1, x2, y2, x3, y3, bg)
    if api.screen.tri then
        api.screen.tri(x1, y1, x2, y2, x3, y3, bg)
    else
        rect(math.min(x1, x2, x3), math.min(y1, y2, y3), math.max(1, math.abs(x2 - x1)), math.max(1, math.abs(y3 - y1)), bg)
    end
end

local function quad(x1, y1, x2, y2, x3, y3, x4, y4, bg)
    if api.screen.quad then
        api.screen.quad(x1, y1, x2, y2, x3, y3, x4, y4, bg)
    else
        rect(math.min(x1, x2, x3, x4), math.min(y1, y2, y3, y4), math.max(1, math.abs(x2 - x1)), math.max(1, math.abs(y3 - y1)), bg)
    end
end

local function curve_at(distance)
    return math.sin(distance * 0.018) * 0.72 + math.sin(distance * 0.043) * 0.28
end

local function projected_lane(ctx, state, z, lane_x)
    local width = ctx.width
    local height = ctx.height
    local horizon = ctx.y + math.max(4, math.floor(height * 0.38))
    local near_y = ctx.y + height - 4
    local depth = z / ROAD_DEPTH
    local perspective = 1 - depth
    local y = horizon + (near_y - horizon) * (1 - depth * depth)
    local road_w = math.max(5, width * (0.12 + perspective * 0.48))
    local curve = curve_at(z + (state.distance or 0) + 24)
    local center = ctx.x + width / 2 + curve * width * 0.18 * perspective
    return center + lane_x * road_w * 0.22, y, road_w
end

local function draw_background(ctx, state)
    local horizon = ctx.y + math.max(4, math.floor(ctx.height * 0.38))
    rect(ctx.x, ctx.y, ctx.width, horizon - ctx.y, C.cyan)
    rect(ctx.x, horizon, ctx.width, ctx.height - (horizon - ctx.y), C.green)

    local offset = math.floor((state.distance or 0) * 0.06) % math.max(12, ctx.width)
    for i = -1, 4 do
        local base_x = ctx.x + i * math.floor(ctx.width / 3) - offset
        tri(base_x, horizon, base_x + math.floor(ctx.width / 5), ctx.y + 2, base_x + math.floor(ctx.width / 2), horizon, C.gray)
        tri(base_x + 4, horizon, base_x + math.floor(ctx.width / 4), ctx.y + 4, base_x + math.floor(ctx.width / 2), horizon, C.lightGray)
    end
end

local function road_point(ctx, z, side)
    local state = ctx.state or {}
    local center, y, road_w = projected_lane(ctx, state, z, 0)
    return center + side * road_w * 0.5, y
end

local function draw_road(ctx, state)
    for i = SEGMENTS, 1, -1 do
        local z1 = (i - 1) / SEGMENTS * ROAD_DEPTH
        local z2 = i / SEGMENTS * ROAD_DEPTH
        local y1 = select(2, projected_lane(ctx, state, z1, 0))
        local y2 = select(2, projected_lane(ctx, state, z2, 0))
        local color = i % 2 == 0 and C.gray or C.lightGray
        local lx1, _ = road_point(ctx, z1, -1)
        local rx1 = road_point(ctx, z1, 1)
        local lx2 = road_point(ctx, z2, -1)
        local rx2 = road_point(ctx, z2, 1)
        quad(lx2, y2, rx2, y2, rx1, y1, lx1, y1, color)

        if i % 2 == math.floor(state.distance / 5) % 2 then
            local l1x, l1y = projected_lane(ctx, state, z1, -0.55)
            local l2x, l2y = projected_lane(ctx, state, z2, -0.55)
            local r1x, r1y = projected_lane(ctx, state, z1, 0.55)
            local r2x, r2y = projected_lane(ctx, state, z2, 0.55)
            quad(l2x - 1, l2y, l2x + 1, l2y, l1x + 1, l1y, l1x - 1, l1y, C.white)
            quad(r2x - 1, r2y, r2x + 1, r2y, r1x + 1, r1y, r1x - 1, r1y, C.white)
        end
    end
end

local function obstacle_at(index, distance)
    local z = (index * 23 - distance) % ROAD_DEPTH
    local lane = ((index * 37) % 3) - 1
    local side = index % 2 == 0 and -1 or 1
    return z, lane, side
end

local function draw_obstacles(ctx, state)
    for i = 1, 7 do
        local z, lane, side = obstacle_at(i, state.distance or 0)
        if z > 5 and z < ROAD_DEPTH - 4 then
            local x, y, road_w = projected_lane(ctx, state, z, lane)
            local scale = 1 - z / ROAD_DEPTH
            local w = math.max(2, math.floor(road_w * 0.12 * scale))
            local h = math.max(1, math.floor(ctx.height * 0.12 * scale))
            local color = i % 2 == 0 and C.red or C.purple
            quad(x - w, y, x + w, y, x + math.floor(w * 0.7), y - h, x - math.floor(w * 0.7), y - h, color)
            rect(x - math.max(1, math.floor(w / 2)), y - h, math.max(1, w), 1, C.black)
        elseif z >= ROAD_DEPTH - 5 then
            local x, y = projected_lane(ctx, state, z, side * 2.4)
            tri(x - 2, y, x + 2, y, x, y - 4, C.green)
        end
    end
end

local function draw_car(ctx, state)
    local cx = ctx.x + math.floor(ctx.width / 2) + math.floor((state.player_x or 0) * ctx.width * 0.18)
    local cy = ctx.y + ctx.height - 3
    local car = state.flash and state.flash > 0 and C.orange or C.blue
    quad(cx - 5, cy, cx + 5, cy, cx + 3, cy - 3, cx - 3, cy - 3, car)
    tri(cx - 3, cy - 3, cx + 3, cy - 3, cx, cy - 5, C.cyan)
    rect(cx - 4, cy, 2, 1, C.black)
    rect(cx + 2, cy, 2, 1, C.black)
end

local function draw_hud(ctx, state)
    local speed = math.floor((state.speed or 0) * 100)
    local top = "Road3D  " .. tostring(speed) .. "km/h  Score " .. tostring(math.floor(state.score or 0))
    api.screen.write(ctx.x, ctx.y, truncate(top, ctx.width), C.white, C.black)
    local bottom = "Best " .. tostring(math.floor(state.best or 0)) .. "  HP " .. tostring(state.health or 0)
    if not state.running then
        bottom = "CRASHED - Enter to restart"
    elseif state.message then
        bottom = state.message
    end
    api.screen.write(ctx.x, ctx.y + ctx.height - 1, truncate(bottom, ctx.width), C.yellow, C.black)
end

local function reset(state)
    state.running = true
    state.player_x = 0
    state.speed = 0.9
    state.distance = 0
    state.score = 0
    state.health = 3
    state.message = "Arrow keys steer"
    state.last_hit = 0
    state.flash = 0
    state.last_tick = now()
end

local function hit_test(state)
    for i = 1, 7 do
        local z, lane = obstacle_at(i, state.distance or 0)
        if z < 8 then
            local target = lane * 0.62
            if math.abs((state.player_x or 0) - target) < 0.34 then
                local current = now()
                if current - (state.last_hit or 0) > 900 then
                    state.health = (state.health or 3) - 1
                    state.last_hit = current
                    state.flash = 8
                    state.speed = math.max(MIN_SPEED, (state.speed or 1) * 0.75)
                    state.message = "Impact"
                    if state.health <= 0 then
                        state.running = false
                        state.message = "Crashed"
                        if (state.score or 0) > (state.best or 0) then
                            state.best = state.score
                            save_best(state.best)
                        end
                    end
                end
                break
            end
        end
    end
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)
    draw_background(ctx, state)
    draw_road(ctx, state)
    draw_obstacles(ctx, state)
    draw_car(ctx, state)
    draw_hud(ctx, state)
end

function app.on_tick(ctx)
    local state = ctx.state
    ensure_state(state)
    local current = now()
    local dt = math.max(0.001, math.min(0.08, (current - (state.last_tick or current)) / 1000))
    state.last_tick = current
    if not state.running then
        return false
    end
    local curve = curve_at((state.distance or 0) + 12)
    state.player_x = clamp((state.player_x or 0) - curve * dt * 0.22, -1.45, 1.45)
    state.speed = clamp((state.speed or 0.9) + dt * 0.035, MIN_SPEED, MAX_SPEED)
    state.distance = (state.distance or 0) + (state.speed or 1) * dt * 26
    state.score = (state.score or 0) + (state.speed or 1) * dt * 12
    if state.flash and state.flash > 0 then
        state.flash = state.flash - 1
    end
    if math.abs(state.player_x or 0) > 1.12 then
        state.speed = math.max(MIN_SPEED, (state.speed or 1) - dt * 0.35)
        state.message = "Off road"
    elseif state.message == "Off road" then
        state.message = nil
    end
    hit_test(state)
    if (state.score or 0) > (state.best or 0) then
        state.best = state.score
    end
    return true
end

function app.on_key(ctx)
    local state = ctx.state
    ensure_state(state)
    if not keys then
        return false
    end
    local key = ctx.event.raw and ctx.event.raw[2]
    if key == keys.left or key == keys.a then
        state.player_x = clamp((state.player_x or 0) - 0.25, -1.45, 1.45)
        return true
    elseif key == keys.right or key == keys.d then
        state.player_x = clamp((state.player_x or 0) + 0.25, -1.45, 1.45)
        return true
    elseif key == keys.up or key == keys.w then
        state.speed = clamp((state.speed or 0.9) + 0.16, MIN_SPEED, MAX_SPEED)
        return true
    elseif key == keys.down or key == keys.s then
        state.speed = clamp((state.speed or 0.9) - 0.2, MIN_SPEED, MAX_SPEED)
        return true
    elseif key == keys.enter or key == keys.space then
        if not state.running then
            reset(state)
        end
        return true
    end
    return false
end

function app.on_touch(ctx)
    local state = ctx.state
    ensure_state(state)
    local event = ctx.event or {}
    if not state.running then
        reset(state)
        return true
    end
    local mid = ctx.x + ctx.width / 2
    if event.x and event.x < mid then
        state.player_x = clamp((state.player_x or 0) - 0.25, -1.45, 1.45)
    else
        state.player_x = clamp((state.player_x or 0) + 0.25, -1.45, 1.45)
    end
    return true
end

function app.on_pause(ctx)
    local state = ctx.state
    if state and state.best then
        save_best(state.best)
    end
end

return app
