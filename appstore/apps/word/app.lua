local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "HyperWrite",
        label = "Write",
        color = C.white,
        dock = true,
        render_mode = "exclusive",
        refresh_rate = 12,
        devices = { "TDesktop", "TBusinessDesktop" },
    },
}

local LAST_FILE = "last_path.txt"
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

local function basename(path)
    return tostring(path or ""):match("([^/]+)$") or "Untitled.txt"
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

local function combine(path, name)
    if path == "/" or path == "" then
        return "/" .. tostring(name or "")
    end
    return tostring(path or "/") .. "/" .. tostring(name or "")
end

local function safe_file_name(name)
    name = tostring(name or ""):gsub("[/\\:*?\"<>|]", "_")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        name = "Untitled.txt"
    end
    if not name:lower():match("%.txt$") then
        name = name .. ".txt"
    end
    return name
end

local function title_from_name(name)
    return tostring(name or "Untitled.txt"):gsub("%.txt$", "")
end

local function doc_path(state)
    if state.file_path and state.file_path ~= "" then
        return state.file_path
    end
    return "/Documents/" .. safe_file_name(state.file_name)
end

local function wrapped_body(width, body)
    if api.screen.wrap then
        return api.screen.wrap(body, math.max(1, width))
    end
    return { tostring(body or "") }
end

local function load_path(state, path)
    if not api.userfs or not api.userfs.read then
        state.error = "UserFSUnavailable"
        state.message = nil
        return false
    end
    local body, err = api.userfs.read(path)
    if body == nil then
        state.error = tostring(err or "OpenFailed")
        state.message = nil
        return false
    end
    state.file_path = path
    state.file_name = basename(path)
    state.title = title_from_name(state.file_name)
    state.body = body
    state.scroll = 0
    state.focus = "body"
    state.error = nil
    state.message = "Opened " .. state.file_name
    if api.fs and api.fs.write then
        api.fs.write(LAST_FILE, path)
    end
    return true
end

local function ensure_state(state)
    if state.ready then
        return
    end
    state.ready = true
    state.file_path = nil
    state.file_name = "Untitled.txt"
    state.title = "Untitled"
    state.body = ""
    state.focus = "body"
    state.scroll = 0
    state.picker = false
    state.picker_path = "/Documents"
    state.picker_scroll = 0
    state.message = nil
    state.error = nil

    local last = api.fs and api.fs.read and api.fs.read(LAST_FILE) or nil
    if last and last ~= "" and api.userfs and api.userfs.exists and api.userfs.exists(last) then
        load_path(state, last)
    end
end

local function save_doc(state)
    if not api.userfs or not api.userfs.write then
        state.error = "UserFSUnavailable"
        state.message = nil
        return false
    end
    local path = doc_path(state)
    local ok, err = api.userfs.write(path, state.body)
    if not ok then
        state.error = err or "SaveFailed"
        state.message = nil
        return false
    end
    state.file_path = path
    state.file_name = basename(path)
    state.title = state.title ~= "" and state.title or title_from_name(state.file_name)
    if api.fs and api.fs.write then
        api.fs.write(LAST_FILE, path)
    end
    state.error = nil
    state.message = "Saved " .. state.file_name
    return true
end

local function print_doc(state)
    if not save_doc(state) then
        return false
    end
    if not api.printer or not api.printer.print then
        state.error = "PrinterUnavailable"
        state.message = nil
        return false
    end
    local printable = (state.title ~= "" and (state.title .. "\n\n") or "") .. state.body
    local ok, result = api.printer.print(printable, {
        title = state.title ~= "" and state.title or state.file_name,
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
    state.file_path = nil
    state.file_name = "Untitled.txt"
    state.title = "Untitled"
    state.body = ""
    state.scroll = 0
    state.focus = "body"
    state.error = nil
    state.message = "New document"
end

local function append_char(state, ch)
    if state.focus == "name" then
        if #state.file_name < 48 then
            state.file_name = state.file_name .. ch
            state.file_path = nil
        end
    elseif state.focus == "title" then
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
    if state.focus == "name" then
        state.file_name = state.file_name:sub(1, math.max(0, #state.file_name - 1))
        state.file_path = nil
    elseif state.focus == "title" then
        state.title = state.title:sub(1, math.max(0, #state.title - 1))
    else
        state.body = state.body:sub(1, math.max(0, #state.body - 1))
    end
    state.message = nil
    state.error = nil
end

local function picker_entries(state)
    local list, err
    if api.userfs and api.userfs.list then
        list, err = api.userfs.list(state.picker_path or "/")
    else
        err = "UserFSUnavailable"
    end
    if not list then
        state.error = err or "ListFailed"
        return {}
    end
    local entries = {}
    for _, name in ipairs(list) do
        local path = combine(state.picker_path, name)
        local stat = api.userfs.stat(path) or { kind = "file" }
        if stat.kind == "dir" or name:lower():match("%.txt$") then
            entries[#entries + 1] = {
                name = name,
                path = path,
                kind = stat.kind,
            }
        end
    end
    table.sort(entries, function(a, b)
        if a.kind ~= b.kind then
            return a.kind == "dir"
        end
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    return entries
end

local function open_picker(state)
    state.picker = true
    state.picker_path = "/Documents"
    if api.userfs and api.userfs.exists and not api.userfs.exists(state.picker_path) then
        state.picker_path = "/"
    end
    state.picker_scroll = 0
end

local function render_picker(ctx, state, embedded)
    local y = embedded and 2 or 0
    local h = embedded and math.max(5, ctx.height - 3) or ctx.height
    api.screen.rect(ctx.x, ctx.y + y, ctx.width, h, C.gray)
    write(ctx, 1, y, "Open .txt", C.white, C.gray)
    button(ctx, "word_pick_close", math.max(1, ctx.width - 7), y, 7, "Cancel", C.red)
    button(ctx, "word_pick_up", 1, y + 2, 4, "Up", C.gray)
    write(ctx, 6, y + 2, truncate(state.picker_path or "/", math.max(1, ctx.width - 6)), C.white, C.gray)

    local entries = picker_entries(state)
    state.picker_entries = entries
    local rows_y = y + 4
    local rows_h = math.max(1, h - 4)
    local max_scroll = math.max(0, #entries - rows_h)
    state.picker_scroll = math.min(math.max(0, state.picker_scroll or 0), max_scroll)
    for row = 0, rows_h - 1 do
        local entry = entries[state.picker_scroll + row + 1]
        local row_y = rows_y + row
        api.screen.write(ctx.x + 1, ctx.y + row_y, string.rep(" ", math.max(1, ctx.width - 2)), C.white, C.black)
        if entry then
            local label = (entry.kind == "dir" and "[ ] " or "    ") .. entry.name
            ctx.buttons["word_pick_row_" .. tostring(row + 1)] = api.screen.button("word_pick_row_" .. tostring(row + 1), ctx.x + 1, ctx.y + row_y, math.max(1, ctx.width - 2), "", { fg = C.white, bg = C.black })
            write(ctx, 1, row_y, truncate(label, math.max(1, ctx.width - 2)), entry.kind == "dir" and C.yellow or C.white, C.black)
        end
    end
end

function app.on_resume(ctx)
    local state = ctx.state
    ensure_state(state)
    local path = ctx.open_file or (ctx.launch and ctx.launch.open_file)
    if path and path ~= state.last_open_request then
        state.last_open_request = path
        load_path(state, path)
    end
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)

    if ctx.window and ctx.window.popup and ctx.window.popup_kind == "file_picker" then
        state.picker = true
        if not state.picker_path then
            open_picker(state)
        end
        render_picker(ctx, state, false)
        return
    end

    button(ctx, "word_new", 0, 0, 5, "New", C.gray)
    button(ctx, "word_open", 6, 0, 6, "Open", C.gray)
    button(ctx, "word_save", 13, 0, 6, "Save", C.blue)
    button(ctx, "word_print", 20, 0, 7, "Print", C.green)
    local status = state.error or state.message or ""
    write(ctx, 28, 0, truncate(status, math.max(1, ctx.width - 28)), state.error and C.red or C.lightGray, C.black)

    local name_bg = state.focus == "name" and C.blue or C.gray
    api.screen.write(ctx.x, ctx.y + 2, string.rep(" ", ctx.width), C.white, name_bg)
    write(ctx, 0, 2, truncate("File: " .. safe_file_name(state.file_name), ctx.width), C.white, name_bg)

    local title_bg = state.focus == "title" and C.blue or C.gray
    api.screen.write(ctx.x, ctx.y + 3, string.rep(" ", ctx.width), C.white, title_bg)
    write(ctx, 0, 3, truncate("Title: " .. (state.title == "" and "Untitled" or state.title), ctx.width), C.white, title_bg)

    local editor_y = 5
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
    if state.picker then
        render_picker(ctx, state, true)
    end
end

function app.on_touch(ctx)
    local state = ctx.state
    ensure_state(state)
    local popup_picker = ctx.window and ctx.window.popup and ctx.window.popup_kind == "file_picker"
    if ctx.event and ctx.event.type == "scroll" then
        if state.picker or popup_picker then
            state.picker_scroll = math.max(0, (state.picker_scroll or 0) + tonumber(ctx.event.direction or 0))
        else
            state.scroll = math.max(0, (state.scroll or 0) + tonumber(ctx.event.direction or 0))
        end
        return true
    end
    if state.picker or popup_picker then
        if ctx.button_id == "word_pick_close" then
            state.picker = false
            if popup_picker and api.desktop and api.desktop.close then
                api.desktop.close()
            end
            return true
        elseif ctx.button_id == "word_pick_up" then
            state.picker_path = parent(state.picker_path)
            state.picker_scroll = 0
            return true
        elseif tostring(ctx.button_id or ""):match("^word_pick_row_") then
            local row = tonumber(tostring(ctx.button_id):match("(%d+)$")) or 0
            local entry = (state.picker_entries or {})[(state.picker_scroll or 0) + row]
            if entry then
                if entry.kind == "dir" then
                    state.picker_path = entry.path
                    state.picker_scroll = 0
                else
                    load_path(state, entry.path)
                    state.picker = false
                    if popup_picker and api.desktop and api.desktop.close then
                        api.desktop.close()
                    end
                end
            end
            return true
        end
        return true
    end
    if ctx.button_id == "word_new" then
        new_doc(state)
        return true
    elseif ctx.button_id == "word_open" then
        open_picker(state)
        if ctx.desktop and api.desktop and api.desktop.open_popup then
            local ok = api.desktop.open_popup("file_picker", {
                title = "Open .txt",
                width = math.min(36, math.max(24, ctx.width - 4)),
                height = math.min(14, math.max(8, ctx.height - 2)),
            })
            if ok then
                state.picker = false
            end
        end
        return true
    elseif ctx.button_id == "word_save" then
        save_doc(state)
        return true
    elseif ctx.button_id == "word_print" then
        print_doc(state)
        return true
    elseif ctx.event and ctx.event.y == ctx.y + 2 then
        state.focus = "name"
        return true
    elseif ctx.event and ctx.event.y == ctx.y + 3 then
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
    local popup_picker = ctx.window and ctx.window.popup and ctx.window.popup_kind == "file_picker"
    if event.type == "char" then
        if state.picker or popup_picker then
            return true
        end
        append_char(state, event.raw and event.raw[2] or "")
        return true
    elseif event.type ~= "key" or not keys then
        return false
    end

    local key = event.raw and event.raw[2]
    if state.picker or popup_picker then
        if key == keys.backspace then
            state.picker_path = parent(state.picker_path)
            state.picker_scroll = 0
        elseif key == keys.enter then
            state.picker = false
            if popup_picker and api.desktop and api.desktop.close then
                api.desktop.close()
            end
        elseif key == keys.up then
            state.picker_scroll = math.max(0, (state.picker_scroll or 0) - 1)
        elseif key == keys.down then
            state.picker_scroll = (state.picker_scroll or 0) + 1
        end
        return true
    end
    if key == keys.backspace then
        backspace(state)
        return true
    elseif key == keys.enter then
        if state.focus == "name" then
            state.file_name = safe_file_name(state.file_name)
            state.file_path = nil
            state.focus = "title"
        elseif state.focus == "title" then
            state.focus = "body"
        elseif #state.body < MAX_BODY then
            state.body = state.body .. "\n"
        end
        return true
    elseif keys.tab and key == keys.tab then
        if state.focus == "name" then
            state.focus = "title"
        elseif state.focus == "title" then
            state.focus = "body"
        else
            state.focus = "name"
        end
        return true
    elseif keys.f2 and key == keys.f2 then
        state.focus = "name"
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
