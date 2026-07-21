local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "Notes",
        label = "Notes",
        color = C.cyan,
        dock = false,
        render_mode = "exclusive",
        refresh_rate = 10,
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

local function ensure_state(state)
    if state.ready then
        return
    end
    state.ready = true
    state.body = api.fs.read("note.txt") or ""
    state.message = nil
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)
    write_line(ctx, 0, "Notes", C.yellow)
    write_line(ctx, 2, state.body == "" and "Tap keys to write..." or state.body, C.white)
    write_line(ctx, ctx.height - 3, "Enter saves, Backspace deletes", C.lightGray)
    if state.message then
        write_line(ctx, ctx.height - 1, state.message, C.green)
    end
end

function app.on_key(ctx)
    local state = ctx.state
    ensure_state(state)
    if ctx.event.type == "char" then
        local ch = ctx.event.raw and ctx.event.raw[2] or ""
        if #state.body < 220 then
            state.body = state.body .. ch
            state.message = nil
        end
        return true
    end

    local key = ctx.event.raw and ctx.event.raw[2]
    if not keys then
        return false
    end
    if key == keys.backspace then
        state.body = state.body:sub(1, math.max(0, #state.body - 1))
        state.message = nil
        return true
    elseif key == keys.enter then
        api.fs.write("note.txt", state.body)
        state.message = "Saved"
        return true
    end
    return false
end

return app
