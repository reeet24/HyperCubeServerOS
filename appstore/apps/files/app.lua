local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "File Explorer",
        label = "Files",
        color = C.lightGray,
        dock = true,
        render_mode = "window",
        refresh_rate = 12,
        devices = { "TDesktop", "TBusinessDesktop" },
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

local function combine(path, name)
    path = tostring(path or "/")
    name = tostring(name or "")
    if path == "/" or path == "" then
        return "/" .. name
    end
    return path .. "/" .. name
end

local function parent(path)
    path = tostring(path or "/")
    if path == "/" then
        return "/"
    end
    local value = path:gsub("/+$", ""):match("^(.*)/[^/]+$") or "/"
    if value == "" then
        value = "/"
    end
    return value
end

local function is_text_file(path)
    return tostring(path or ""):lower():match("%.txt$") ~= nil
end

local function button(ctx, id, x, y, width, label, bg)
    ctx.buttons[id] = api.screen.button(id, ctx.x + x, ctx.y + y, width, label, {
        fg = bg == C.white and C.black or C.white,
        bg = bg or C.gray,
    })
end

local function write(ctx, x, y, text, fg, bg)
    api.screen.write(ctx.x + x, ctx.y + y, text, fg or C.white, bg or C.black)
end

local function ensure_state(state)
    if state.ready then
        return
    end
    state.ready = true
    state.path = "/"
    state.selected = nil
    state.selected_stat = nil
    state.scroll = 0
    state.error = nil
    state.message = nil
end

local function refresh_entries(state)
    local list, err
    if api.userfs and api.userfs.list then
        list, err = api.userfs.list(state.path or "/")
    else
        err = "UserFSUnavailable"
    end
    if not list then
        state.entries = {}
        state.error = err or "ListFailed"
        return
    end
    local entries = {}
    for _, name in ipairs(list) do
        local path = combine(state.path, name)
        local stat = api.userfs.stat(path) or { kind = "file", size = 0 }
        entries[#entries + 1] = {
            name = name,
            path = path,
            kind = stat.kind or "file",
            size = stat.size or 0,
        }
    end
    table.sort(entries, function(a, b)
        if a.kind ~= b.kind then
            return a.kind == "dir"
        end
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    state.entries = entries
    state.error = nil
end

local function open_selected(state)
    local selected = state.selected_stat
    if not selected then
        return
    end
    if selected.kind == "dir" then
        state.path = selected.path
        state.selected = nil
        state.selected_stat = nil
        state.scroll = 0
        refresh_entries(state)
        return
    end
    if is_text_file(selected.path) and api.desktop and api.desktop.open_file then
        local ok, err = api.desktop.open_file(selected.path)
        state.message = ok and "Opening in HyperWrite" or nil
        state.error = ok and nil or tostring(err or "OpenFailed")
        return
    end
    state.error = "NoAppForFile"
    state.message = nil
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)
    refresh_entries(state)

    button(ctx, "files_up", 0, 0, 4, "Up", C.gray)
    button(ctx, "files_open", 5, 0, 6, "Open", C.blue)
    local status = state.error or state.message or ""
    write(ctx, 12, 0, truncate(status, math.max(1, ctx.width - 12)), state.error and C.red or C.lightGray, C.black)

    api.screen.write(ctx.x, ctx.y + 2, string.rep(" ", ctx.width), C.black, C.white)
    write(ctx, 0, 2, truncate(state.path or "/", ctx.width), C.black, C.white)

    local rows_y = 4
    local rows_h = math.max(1, ctx.height - rows_y)
    local entries = state.entries or {}
    local max_scroll = math.max(0, #entries - rows_h)
    state.scroll = math.min(math.max(0, state.scroll or 0), max_scroll)
    for row = 0, rows_h - 1 do
        local entry = entries[state.scroll + row + 1]
        local y = rows_y + row
        local bg = C.black
        local fg = C.white
        if entry and state.selected == entry.path then
            bg = C.blue
        elseif entry and entry.kind == "dir" then
            fg = C.yellow
        end
        api.screen.write(ctx.x, ctx.y + y, string.rep(" ", ctx.width), fg, bg)
        if entry then
            local prefix = entry.kind == "dir" and "[ ] " or "    "
            ctx.buttons["files_row_" .. tostring(row + 1)] = api.screen.button("files_row_" .. tostring(row + 1), ctx.x, ctx.y + y, ctx.width, "", { fg = fg, bg = bg })
            write(ctx, 0, y, truncate(prefix .. entry.name, ctx.width), fg, bg)
        end
    end
end

function app.on_touch(ctx)
    local state = ctx.state
    ensure_state(state)
    if ctx.event and ctx.event.type == "scroll" then
        state.scroll = math.max(0, (state.scroll or 0) + tonumber(ctx.event.direction or 0))
        return true
    end
    if ctx.button_id == "files_up" then
        state.path = parent(state.path)
        state.selected = nil
        state.selected_stat = nil
        state.scroll = 0
        refresh_entries(state)
        return true
    elseif ctx.button_id == "files_open" then
        open_selected(state)
        return true
    elseif tostring(ctx.button_id or ""):match("^files_row_") then
        local row = tonumber(tostring(ctx.button_id):match("(%d+)$")) or 0
        local entry = (state.entries or {})[(state.scroll or 0) + row]
        if entry then
            if state.selected == entry.path then
                open_selected(state)
            else
                state.selected = entry.path
                state.selected_stat = entry
                state.message = entry.kind == "dir" and "Open folder" or "Open with app"
                state.error = nil
            end
        end
        return true
    end
    return false
end

function app.on_key(ctx)
    local state = ctx.state
    ensure_state(state)
    local key = ctx.event and ctx.event.raw and ctx.event.raw[2]
    if not keys or not key then
        return false
    end
    if key == keys.enter then
        open_selected(state)
        return true
    elseif key == keys.backspace then
        state.path = parent(state.path)
        state.selected = nil
        state.selected_stat = nil
        state.scroll = 0
        refresh_entries(state)
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
