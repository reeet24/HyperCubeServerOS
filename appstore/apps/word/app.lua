local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "HyperWrite",
        label = "Write",
        color = C.white,
        dock = true,
        render_mode = "window",
        refresh_rate = 12,
        devices = { "TDesktop", "TBusinessDesktop" },
    },
}

local DOC_FILE = "document.txt"
local TITLE_FILE = "title.txt"
local MAX_BODY = 12000

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

local function write(ctx, x, y, text, fg, bg)
    api.screen.write(ctx.x + x, ctx.y + y, text, fg or C.white, bg or C.black)
end

local function button(ctx, id, x, y, width, label, bg)
    ctx.buttons[id] = api.screen.button(id, ctx.x + x, ctx.y + y, width, label, {
        fg = bg == C.white and C.black or C.white,
        bg = bg or C.gray,
    })
end

local function ensure_state(state)
    if state.ready then
        return
    end
    state.ready = true
    state.title = api.fs.read(TITLE_FILE) or "Untitled"
    state.body = api.fs.read(DOC_FILE) or ""
    state.focus = "body"
    state.scroll = 0
    state.message = nil
    state.error = nil
end

local function save_doc(state)
    local ok, err = api.fs.write(TITLE_FILE, state.title)
    if not ok then
        state.error = err or "SaveFailed"
        state.message = nil
        return false
    end
    ok, err = api.fs.write(DOC_FILE, state.body)
    if not ok then
        state.error = err or "SaveFailed"
        state.message = nil
        return false
    end
    state.error = nil
    state.message = "Saved"
    return true
end

local function print_doc(state)
    save_doc(state)
    if state.error then
        return false
    end
    if not api.printer or not api.printer.print then
        state.error = "PrinterUnavailable"
        state.message = nil
        return false
    end
    local ok, result = api.printer.print(state.body, {
        title = state.title,
    })
    if ok then
        state.error = nil
        state.message = "Printed " .. tostring(result.pages or 1) .. " page(s)"
        return true
    end
    state.error = tostring(result or "PrintFailed")
    state.message = nil
    return false
end

local function new_doc(state)
    state.title = "Untitled"
    state.body = ""
    state.scroll = 0
    state.focus = "body"
    state.error = nil
    state.message = "New document"
end

local function append_char(state, ch)
    if state.focus == "title" then
        if #state.title < 48 then
            state.title = state.title .. ch
        end
    elseif #state.body < MAX_BODY then
        state.body = state.body .. ch
    end
    state.message = nil
    state.error = nil
end

local function backspace(state)
    if state.focus == "title" then
        state.title = state.title:sub(1, math.max(0, #state.title - 1))
    else
        state.body = state.body:sub(1, math.max(0, #state.body - 1))
    end
    state.message = nil
    state.error = nil
end

local function wrapped_body(width, body)
    if api.screen.wrap then
        return api.screen.wrap(body, math.max(1, width))
    end
    return { tostring(body or "") }
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)

    local toolbar_y = 0
    button(ctx, "word_new", 0, toolbar_y, 5, "New", C.gray)
    button(ctx, "word_save", 6, toolbar_y, 6, "Save", C.blue)
    button(ctx, "word_print", 13, toolbar_y, 7, "Print", C.green)
    local status = state.error or state.message or ""
    local status_color = state.error and C.red or C.lightGray
    write(ctx, 22, toolbar_y, truncate(status, math.max(1, ctx.width - 22)), status_color, C.black)

    local title_bg = state.focus == "title" and C.blue or C.gray
    api.screen.write(ctx.x, ctx.y + 2, string.rep(" ", ctx.width), C.white, title_bg)
    write(ctx, 0, 2, truncate(state.title == "" and "Untitled" or state.title, ctx.width), C.white, title_bg)

    local editor_y = 4
    local editor_h = math.max(1, ctx.height - editor_y)
    local body_w = math.max(1, ctx.width)
    local lines = wrapped_body(body_w, state.body)
    if #lines == 0 then
        lines[1] = ""
    end
    local max_scroll = math.max(0, #lines - editor_h)
    if state.scroll > max_scroll then
        state.scroll = max_scroll
    end
    for row = 0, editor_h - 1 do
        local line = lines[state.scroll + row + 1] or ""
        api.screen.write(ctx.x, ctx.y + editor_y + row, string.rep(" ", ctx.width), C.white, C.black)
        write(ctx, 0, editor_y + row, truncate(line, ctx.width), C.white, C.black)
    end
    if state.body == "" then
        write(ctx, 0, editor_y, state.focus == "body" and "_" or "", C.lightGray, C.black)
    end
end

function app.on_touch(ctx)
    local state = ctx.state
    ensure_state(state)
    if ctx.event and ctx.event.type == "scroll" then
        state.scroll = math.max(0, (state.scroll or 0) + tonumber(ctx.event.direction or 0))
        return true
    end
    if ctx.button_id == "word_new" then
        new_doc(state)
        return true
    elseif ctx.button_id == "word_save" then
        save_doc(state)
        return true
    elseif ctx.button_id == "word_print" then
        print_doc(state)
        return true
    elseif ctx.event and ctx.event.y == ctx.y + 2 then
        state.focus = "title"
        return true
    elseif ctx.event then
        state.focus = "body"
        return true
    end
    return false
end

function app.on_key(ctx)
    local state = ctx.state
    ensure_state(state)
    local event = ctx.event or {}
    if event.type == "char" then
        append_char(state, event.raw and event.raw[2] or "")
        return true
    elseif event.type ~= "key" or not keys then
        return false
    end

    local key = event.raw and event.raw[2]
    if key == keys.backspace then
        backspace(state)
        return true
    elseif key == keys.enter then
        if state.focus == "title" then
            state.focus = "body"
        elseif #state.body < MAX_BODY then
            state.body = state.body .. "\n"
        end
        return true
    elseif keys.tab and key == keys.tab then
        state.focus = state.focus == "title" and "body" or "title"
        return true
    elseif keys.f2 and key == keys.f2 then
        state.focus = "title"
        return true
    elseif keys.f3 and key == keys.f3 then
        save_doc(state)
        return true
    elseif keys.f4 and key == keys.f4 then
        print_doc(state)
        return true
    elseif key == keys.up then
        state.scroll = math.max(0, (state.scroll or 0) - 1)
        return true
    elseif key == keys.down then
        state.scroll = (state.scroll or 0) + 1
        return true
    end
    return false
end

return app
