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
    if #text <= width then return text end
    if width <= 3 then return text:sub(1, width) end
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
    if path == "/" then return "/" end
    local value = path:gsub("/+$", ""):match("^(.*)/[^/]+$") or "/"
    return value == "" and "/" or value
end

local function basename(path)
    return tostring(path or ""):match("([^/]+)$") or "item"
end

local function is_text_file(path)
    return tostring(path or ""):lower():match("%.txt$") ~= nil
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
    if state.ready then return end
    state.ready = true
    state.path = "/"
    state.selected = nil
    state.selected_stat = nil
    state.scroll = 0
    state.clipboard = nil
    state.error = nil
    state.message = nil
end

local function stat(path)
    if api.userfs and api.userfs.stat then
        return api.userfs.stat(path)
    end
    return nil
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
        local item = stat(path) or { kind = "file", size = 0 }
        entries[#entries + 1] = {
            name = name,
            path = path,
            kind = item.kind or "file",
            size = item.size or 0,
        }
    end
    table.sort(entries, function(a, b)
        if a.kind ~= b.kind then return a.kind == "dir" end
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    state.entries = entries
    state.error = nil
end

local function unique_path(dir, name)
    local base, ext = tostring(name or "item"):match("^(.-)(%.[^%.]*)$")
    if not base then
        base = tostring(name or "item")
        ext = ""
    end
    local candidate = combine(dir, base .. ext)
    local index = 2
    while api.userfs and api.userfs.exists and api.userfs.exists(candidate) do
        candidate = combine(dir, base .. " " .. tostring(index) .. ext)
        index = index + 1
    end
    return candidate
end

local function open_entry(state, entry)
    entry = entry or state.selected_stat
    if not entry then return end
    if entry.kind == "dir" then
        state.path = entry.path
        state.selected = nil
        state.selected_stat = nil
        state.scroll = 0
        refresh_entries(state)
        return
    end
    if is_text_file(entry.path) and api.desktop and api.desktop.open_file then
        local ok, err = api.desktop.open_file(entry.path)
        state.message = ok and "Opening in HyperWrite" or nil
        state.error = ok and nil or tostring(err or "OpenFailed")
        return
    end
    state.error = "NoAppForFile"
    state.message = nil
end

local function copy_tree(source, target)
    local info = stat(source)
    if not info then return false, "NotFound" end
    if info.kind == "dir" then
        local ok, err = api.userfs.mkdir(target)
        if not ok then return false, err end
        local children, list_err = api.userfs.list(source)
        if not children then return false, list_err end
        for _, child in ipairs(children) do
            ok, err = copy_tree(combine(source, child), combine(target, child))
            if not ok then return false, err end
        end
        return true
    end
    local data, err = api.userfs.read(source)
    if data == nil then return false, err end
    return api.userfs.write(target, data)
end

local function create_file(state)
    local path = unique_path(state.path, "New File.txt")
    local ok, err = api.userfs.write(path, "")
    state.message = ok and ("Created " .. basename(path)) or nil
    state.error = ok and nil or tostring(err or "CreateFailed")
    refresh_entries(state)
end

local function create_folder(state)
    local path = unique_path(state.path, "New Folder")
    local ok, err = api.userfs.mkdir(path)
    state.message = ok and ("Created " .. basename(path)) or nil
    state.error = ok and nil or tostring(err or "CreateFailed")
    refresh_entries(state)
end

local function delete_entry(state, entry)
    entry = entry or state.selected_stat
    if not entry then return end
    local ok, err = api.userfs.delete(entry.path)
    state.message = ok and ("Deleted " .. entry.name) or nil
    state.error = ok and nil or tostring(err or "DeleteFailed")
    if state.selected == entry.path then
        state.selected = nil
        state.selected_stat = nil
    end
    refresh_entries(state)
end

local function copy_entry(state, entry)
    entry = entry or state.selected_stat
    if not entry then return end
    state.clipboard = {
        path = entry.path,
        name = entry.name,
        kind = entry.kind,
    }
    state.message = "Copied " .. entry.name
    state.error = nil
end

local function paste_entry(state, target)
    if not state.clipboard then
        state.error = "ClipboardEmpty"
        state.message = nil
        return
    end
    local dest_dir = state.path
    if target and target.kind == "dir" then
        dest_dir = target.path
    end
    local target_path = unique_path(dest_dir, state.clipboard.name)
    local ok, err = copy_tree(state.clipboard.path, target_path)
    state.message = ok and ("Pasted " .. basename(target_path)) or nil
    state.error = ok and nil or tostring(err or "PasteFailed")
    refresh_entries(state)
end

local function context_actions(state, target)
    local actions = {}
    if target then
        actions[#actions + 1] = { id = "open", label = target.kind == "dir" and "Open Folder" or "Open" }
        actions[#actions + 1] = { id = "copy", label = "Copy" }
        actions[#actions + 1] = { id = "delete", label = "Delete" }
        if target.kind == "dir" and state.clipboard then
            actions[#actions + 1] = { id = "paste", label = "Paste Here" }
        end
    end
    actions[#actions + 1] = { id = "new_file", label = "New File" }
    actions[#actions + 1] = { id = "new_folder", label = "New Folder" }
    if state.clipboard then
        actions[#actions + 1] = { id = "paste", label = "Paste" }
    end
    return actions
end

local function open_context_menu(ctx, state, target)
    state.context_target = target
    state.context_actions = context_actions(state, target)
    if api.desktop and api.desktop.open_popup then
        api.desktop.open_popup("files_context", {
            title = "Actions",
            x = ctx.event and ctx.event.x or nil,
            y = ctx.event and ctx.event.y or nil,
            width = 18,
            height = math.max(5, #state.context_actions + 2),
            data = {
                path = target and target.path or state.path,
                kind = target and target.kind or "dir",
            },
        })
    end
end

local function run_context_action(state, action)
    local target = state.context_target
    if action == "open" then
        open_entry(state, target)
    elseif action == "copy" then
        copy_entry(state, target)
    elseif action == "delete" then
        delete_entry(state, target)
    elseif action == "new_file" then
        create_file(state)
    elseif action == "new_folder" then
        create_folder(state)
    elseif action == "paste" then
        paste_entry(state, target)
    end
end

local function render_context_menu(ctx, state)
    local actions = state.context_actions or context_actions(state, state.context_target)
    api.screen.rect(ctx.x, ctx.y, ctx.width, ctx.height, C.gray)
    write(ctx, 1, 0, "Actions", C.white, C.gray)
    button(ctx, "ctx_close", math.max(1, ctx.width - 2), 0, 2, "x", C.red)
    for index, action in ipairs(actions) do
        local y = index + 1
        api.screen.write(ctx.x + 1, ctx.y + y, string.rep(" ", math.max(1, ctx.width - 2)), C.white, C.black)
        ctx.buttons["ctx_" .. action.id] = api.screen.button("ctx_" .. action.id, ctx.x + 1, ctx.y + y, math.max(1, ctx.width - 2), "", { fg = C.white, bg = C.black })
        write(ctx, 1, y, truncate(action.label, math.max(1, ctx.width - 2)), C.white, C.black)
    end
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)
    if ctx.window and ctx.window.popup and ctx.window.popup_kind == "files_context" then
        render_context_menu(ctx, state)
        return
    end
    refresh_entries(state)

    button(ctx, "files_up", 0, 0, 4, "Up", C.gray)
    button(ctx, "files_open", 5, 0, 6, "Open", C.blue)
    button(ctx, "files_new_file", 12, 0, 8, "New File", C.gray)
    button(ctx, "files_new_folder", 21, 0, 10, "New Folder", C.gray)
    local status = state.error or state.message or ""
    write(ctx, 32, 0, truncate(status, math.max(1, ctx.width - 32)), state.error and C.red or C.lightGray, C.black)

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
    if ctx.window and ctx.window.popup and ctx.window.popup_kind == "files_context" then
        if ctx.button_id == "ctx_close" then
            api.desktop.close()
            return true
        end
        local action = tostring(ctx.button_id or ""):match("^ctx_(.+)$")
        if action then
            run_context_action(state, action)
            if api.desktop and api.desktop.close then api.desktop.close() end
            return true
        end
        return true
    end
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
        open_entry(state)
        return true
    elseif ctx.button_id == "files_new_file" then
        create_file(state)
        return true
    elseif ctx.button_id == "files_new_folder" then
        create_folder(state)
        return true
    elseif tostring(ctx.button_id or ""):match("^files_row_") then
        local row = tonumber(tostring(ctx.button_id):match("(%d+)$")) or 0
        local entry = (state.entries or {})[(state.scroll or 0) + row]
        if entry then
            state.selected = entry.path
            state.selected_stat = entry
            if ctx.event and ctx.event.button == 2 then
                open_context_menu(ctx, state, entry)
            elseif state.selected == entry.path and ctx.event and ctx.event.button == 1 then
                state.message = entry.kind == "dir" and "Open folder" or "Open with app"
                state.error = nil
            end
        end
        return true
    elseif ctx.event and ctx.event.button == 2 then
        open_context_menu(ctx, state, nil)
        return true
    end
    return false
end

function app.on_key(ctx)
    local state = ctx.state
    ensure_state(state)
    local key = ctx.event and ctx.event.raw and ctx.event.raw[2]
    if not keys or not key then return false end
    if key == keys.enter then
        open_entry(state)
        return true
    elseif key == keys.backspace then
        state.path = parent(state.path)
        state.selected = nil
        state.selected_stat = nil
        state.scroll = 0
        refresh_entries(state)
        return true
    elseif keys.delete and key == keys.delete then
        delete_entry(state)
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
