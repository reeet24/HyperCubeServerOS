local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "Terminal",
        label = "Term",
        color = C.black,
        render_mode = "exclusive",
        refresh_rate = 10,
        dev_mode = true,
    },
}

local function push(state, line)
    state.lines = state.lines or {}
    state.lines[#state.lines + 1] = tostring(line or "")
    while #state.lines > 80 do
        table.remove(state.lines, 1)
    end
end

local function init(state)
    if state.ready then
        return
    end
    state.ready = true
    state.input = ""
    state.lines = {
        "HyperCube dev terminal",
        "Type help",
    }
end

local function run_command(state, command)
    command = tostring(command or "")
    push(state, "> " .. command)
    if command == "" then
        return
    elseif command == "help" then
        push(state, "help clear id net reboot")
        push(state, "lua <expr/code>")
    elseif command == "clear" then
        state.lines = {}
    elseif command == "id" then
        push(state, tostring(api.identity.username or "?"))
        push(state, tostring(api.identity.tesserac_id or "?"))
    elseif command == "net" then
        local net = api.hypernet.summary()
        push(state, tostring(net.status or "offline") .. " #" .. tostring(net.server_id or "-"))
    elseif command == "reboot" then
        if api.dev and api.dev.eval then
            local ok, result = api.dev.eval("os.reboot()")
            if not ok then
                push(state, tostring(result))
            end
        else
            push(state, "RebootUnavailable")
        end
    elseif command:sub(1, 4) == "lua " then
        if not api.dev or not api.dev.eval then
            push(state, "DevEvalUnavailable")
            return
        end
        local ok, result = api.dev.eval(command:sub(5))
        push(state, (ok and "= " or "! ") .. tostring(result))
    else
        push(state, "UnknownCommand")
    end
end

function app.render(ctx)
    local state = ctx.state
    init(state)

    local lines_height = math.max(1, ctx.height - 2)
    local start = math.max(1, #(state.lines or {}) - lines_height + 1)
    local row = 0
    for i = start, #(state.lines or {}) do
        api.screen.write(ctx.x, ctx.y + row, tostring(state.lines[i]):sub(1, ctx.width), C.lightGray, C.black)
        row = row + 1
        if row >= lines_height then
            break
        end
    end

    local prompt = "> " .. tostring(state.input or "")
    api.screen.write(ctx.x, ctx.y + ctx.height - 1, string.rep(" ", ctx.width), C.white, C.black)
    api.screen.write(ctx.x, ctx.y + ctx.height - 1, prompt:sub(1, ctx.width), C.white, C.black)
end

function app.on_key(ctx)
    local state = ctx.state
    init(state)
    local event = ctx.event
    if event.type == "paste" then
        local text = event.raw and event.raw[2] or ""
        if #text < 512 then
            state.input = text
        end

        local command = state.input
        state.input = ""
        run_command(state, command)
        return true
    end
    if event.type == "char" then
        local ch = event.raw and event.raw[2] or ""
        if #state.input < 512 then
            state.input = state.input .. ch
        end
        return true
    end
    if event.type ~= "key" then
        return false
    end
    local key = event.raw and event.raw[2]
    if key == keys.backspace then
        state.input = state.input:sub(1, math.max(0, #state.input - 1))
        return true
    elseif key == keys.enter then
        local command = state.input
        state.input = ""
        run_command(state, command)
        return true
    end
    return false
end

return app
