local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "HyperCube SDK",
        label = "SDK",
        devices = { "TDesktop", "TBusinessDesktop" },
        refresh_rate = 12,
    },
}

local DOC_IDS = { "desktop-sdk", "userapp-api", "banking-api", "web-api", "user-server-api" }
local TABS = { "project", "edit", "manifest", "docs", "api", "build", "term" }
local MENU_ACTIONS = { "save", "install", "run", "term" }
local API_WORDS = {
    "HCAPI.screen.write", "HCAPI.screen.write_wrap", "HCAPI.screen.button", "HCAPI.screen.rect", "HCAPI.screen.wrap",
    "HCAPI.fs.read", "HCAPI.fs.write", "HCAPI.fs.list", "HCAPI.fs.delete",
    "HCAPI.userfs.read", "HCAPI.userfs.write", "HCAPI.userfs.mkdir", "HCAPI.userfs.list", "HCAPI.userfs.delete",
    "HCAPI.desktop.open_app", "HCAPI.desktop.open_popup", "HCAPI.desktop.open_terminal", "HCAPI.desktop.set_title",
    "HCAPI.bank.status", "HCAPI.bank.purchase", "HCAPI.bank.transfer",
    "HCAPI.phone.status", "HCAPI.phone.send", "HCAPI.phone.inbox",
    "HCAPI.printer.status", "HCAPI.printer.print",
    "app.render", "app.on_touch", "app.on_key", "app.on_tick", "app.on_resume", "app.on_pause", "app.on_close",
}

local TEMPLATE = [[local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "New App",
        label = "App",
        devices = { "TDesktop", "TBusinessDesktop" },
        refresh_rate = 10,
    },
}

function app.render(ctx)
    api.screen.rect(ctx.x, ctx.y, ctx.width, ctx.height, C.black)
    api.screen.write(ctx.x + 1, ctx.y + 1, "Hello HyperCube", C.yellow, C.black)
end

function app.on_touch(ctx)
    return false
end

function app.on_key(ctx)
    return false
end

return app
]]

local function safe_id(id)
    id = tostring(id or ""):lower():gsub("%s+", "")
    id = id:gsub("[^%w_%-%.]", "_")
    if id == "" then
        return "my_app"
    end
    return id
end

local function safe_path(path)
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("^%./", ""):gsub("//+", "/")
    if path == "" or path:find("..", 1, true) then
        return nil
    end
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    return path
end

local function rel_path(path)
    path = tostring(path or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("^%./", ""):gsub("//+", "/")
    if path == "" or path:find("..", 1, true) or path:sub(-1) == "/" then
        return nil
    end
    return path
end

local function root_for(id)
    return "/dev/apps/" .. safe_id(id)
end

local function write_file(path, data)
    path = safe_path(path)
    if not path then
        return false, "InvalidPath"
    end
    local current = ""
    local parts = {}
    for part in path:gmatch("[^/]+") do
        parts[#parts + 1] = part
    end
    for i = 1, #parts - 1 do
        current = current .. "/" .. parts[i]
        api.userfs.mkdir(current)
    end
    return api.userfs.write(path, tostring(data or ""))
end

local function read_file(path)
    path = safe_path(path)
    if not path then
        return nil, "InvalidPath"
    end
    return api.userfs.read(path)
end

local function list_dir(path)
    path = safe_path(path or "/")
    if not path then
        return nil, "InvalidPath"
    end
    return api.userfs.list(path)
end

local function ensure_project_dirs(root)
    api.userfs.mkdir("/dev")
    api.userfs.mkdir("/dev/apps")
    api.userfs.mkdir(root)
    api.userfs.mkdir(root .. "/lib")
    api.userfs.mkdir(root .. "/assets")
end

local function serialize_manifest(manifest)
    return textutils.serialize({
        id = manifest.id,
        title = manifest.title,
        label = manifest.label,
        version = manifest.version,
        author = manifest.author,
        description = manifest.description,
        devices = manifest.devices,
        refresh_rate = manifest.refresh_rate,
        render_mode = manifest.render_mode,
        mutable_paths = manifest.mutable_paths,
    })
end

local function default_manifest(id)
    return {
        id = safe_id(id),
        title = safe_id(id),
        label = safe_id(id):sub(1, 4),
        version = "0.1.0",
        author = api.identity and api.identity.username or "Developer",
        description = "HyperCube desktop app.",
        devices = { "TDesktop", "TBusinessDesktop" },
        refresh_rate = 10,
        mutable_paths = { "assets" },
    }
end

local function load_manifest(root, id)
    local data = read_file(root .. "/manifest")
    local ok, manifest = pcall(textutils.unserialize, data or "")
    if not ok or type(manifest) ~= "table" then
        manifest = default_manifest(id)
    end
    manifest.id = safe_id(manifest.id or id)
    manifest.title = tostring(manifest.title or manifest.id)
    manifest.label = tostring(manifest.label or manifest.id:sub(1, 4))
    manifest.version = tostring(manifest.version or "0.1.0")
    manifest.devices = type(manifest.devices) == "table" and manifest.devices or { "TDesktop", "TBusinessDesktop" }
    manifest.refresh_rate = tonumber(manifest.refresh_rate) or 10
    return manifest
end

local function project_files(root, dir, out)
    out = out or {}
    dir = dir or ""
    local full = dir == "" and root or (root .. "/" .. dir)
    local listing = list_dir(full)
    if type(listing) == "table" then
        for _, child in ipairs(listing) do
            local child_rel = dir == "" and child or (dir .. "/" .. child)
            project_files(root, child_rel, out)
        end
    else
        local path = rel_path(dir)
        if path then
            out[#out + 1] = path
        end
    end
    table.sort(out)
    return out
end

local function load_projects(state)
    state.projects = {}
    local roots = list_dir("/dev/apps")
    if type(roots) == "table" then
        for _, id in ipairs(roots) do
            state.projects[#state.projects + 1] = safe_id(id)
        end
    end
    table.sort(state.projects)
end

local function load_current_file(state)
    state.files = project_files(state.root)
    if #state.files == 0 then
        state.files = { "app.lua" }
    end
    state.file_index = math.max(1, math.min(tonumber(state.file_index or 1) or 1, #state.files))
    state.file = state.files[state.file_index]
    state.source = read_file(state.root .. "/" .. state.file) or ""
    state.cursor = #(state.source or "")
    state.selection_anchor = nil
    state.lint_dirty = true
    state.edit_scroll = 0
end

local function clamp_scroll(value, total, visible)
    value = math.floor(tonumber(value) or 0)
    total = math.max(0, math.floor(tonumber(total) or 0))
    visible = math.max(1, math.floor(tonumber(visible) or 1))
    return math.max(0, math.min(value, math.max(0, total - visible)))
end

local function clamp_cursor(state, pos)
    return math.max(0, math.min(math.floor(tonumber(pos) or 0), #(state.source or "")))
end

local function clear_selection(state)
    state.selection_anchor = nil
end

local function selection_bounds(state)
    local anchor = state.selection_anchor
    local cursor = state.cursor or 0
    if anchor == nil or anchor == cursor then
        return nil
    end
    return math.min(anchor, cursor), math.max(anchor, cursor)
end

local function selected_text(state)
    local first, last = selection_bounds(state)
    if not first then
        return ""
    end
    return tostring(state.source or ""):sub(first + 1, last)
end

local function replace_selection(state, text)
    local source = tostring(state.source or "")
    local first, last = selection_bounds(state)
    text = tostring(text or "")
    if first then
        state.source = source:sub(1, first) .. text .. source:sub(last + 1)
        state.cursor = first + #text
        clear_selection(state)
    else
        local cursor = clamp_cursor(state, state.cursor)
        state.source = source:sub(1, cursor) .. text .. source:sub(cursor + 1)
        state.cursor = cursor + #text
    end
    state.dirty = true
    state.lint_dirty = true
end

local function delete_selection(state)
    local text = selected_text(state)
    if text == "" then
        return false
    end
    replace_selection(state, "")
    return true
end

local function line_start_for(source, pos)
    source = tostring(source or "")
    pos = math.max(0, math.min(tonumber(pos) or 0, #source))
    local before = source:sub(1, pos)
    local start = before:match(".*()\n")
    return start or 0
end

local function line_end_for(source, pos)
    source = tostring(source or "")
    pos = math.max(0, math.min(tonumber(pos) or 0, #source))
    local found = source:find("\n", pos + 1, true)
    return found and (found - 1) or #source
end

local function cursor_line_number(source, pos)
    local _, count = tostring(source or ""):sub(1, math.max(0, pos)):gsub("\n", "")
    return count + 1
end

local function move_cursor(state, pos, selecting)
    if selecting and state.selection_anchor == nil then
        state.selection_anchor = state.cursor or 0
    elseif not selecting then
        clear_selection(state)
    end
    state.cursor = clamp_cursor(state, pos)
end

local function move_cursor_word(state, direction, selecting)
    local source = tostring(state.source or "")
    local pos = clamp_cursor(state, state.cursor)
    if direction < 0 then
        while pos > 0 and source:sub(pos, pos):match("%s") do
            pos = pos - 1
        end
        while pos > 0 and source:sub(pos, pos):match("[%w_]") do
            pos = pos - 1
        end
    else
        while pos < #source and source:sub(pos + 1, pos + 1):match("[%w_]") do
            pos = pos + 1
        end
        while pos < #source and source:sub(pos + 1, pos + 1):match("%s") do
            pos = pos + 1
        end
    end
    move_cursor(state, pos, selecting)
end

local function visual_lines_for(source, width)
    width = math.max(1, tonumber(width) or 1)
    local lines = {}
    local offset = 0
    local line_no = 1
    for raw in (tostring(source or "") .. "\n"):gmatch("(.-)\n") do
        if raw == "" then
            lines[#lines + 1] = { text = "", start = offset, finish = offset, line_no = line_no }
        else
            local index = 1
            while index <= #raw do
                local part = raw:sub(index, index + width - 1)
                lines[#lines + 1] = {
                    text = part,
                    start = offset + index - 1,
                    finish = offset + index - 1 + #part,
                    line_no = line_no,
                }
                index = index + width
            end
        end
        offset = offset + #raw + 1
        line_no = line_no + 1
    end
    if #lines > 1 and lines[#lines].start >= #tostring(source or "") then
        lines[#lines] = nil
    end
    if #lines == 0 then
        lines[1] = { text = "", start = 0, finish = 0, line_no = 1 }
    end
    return lines
end

local function cursor_from_editor_point(state, x, y)
    local layout = state.editor_layout
    if type(layout) ~= "table" then
        return state.cursor or 0
    end
    local row = math.max(0, math.floor((tonumber(y) or layout.y) - layout.y))
    local line = layout.lines[(layout.first or 1) + row]
    if not line then
        return state.cursor or 0
    end
    local col = math.max(0, math.floor((tonumber(x) or layout.x) - layout.x))
    return clamp_cursor(state, line.start + math.min(col, #line.text))
end

local function current_file_diagnostics(state)
    local out = {}
    for _, item in ipairs(state.diagnostics or {}) do
        if item.file == state.file then
            out[#out + 1] = item
        end
    end
    return out
end

local function diagnostic_lines_for_current_file(state)
    local lines = {}
    for _, item in ipairs(current_file_diagnostics(state)) do
        local line = tonumber(tostring(item.message or ""):match(":(%d+):") or tostring(item.message or ""):match("line%s+(%d+)"))
        if line then
            lines[line] = item.severity or "info"
        end
    end
    return lines
end

local function create_project(state, id)
    id = safe_id(id or state.new_id or "my_app")
    local root = root_for(id)
    ensure_project_dirs(root)
    local manifest = default_manifest(id)
    write_file(root .. "/manifest", serialize_manifest(manifest))
    write_file(root .. "/app.lua", TEMPLATE:gsub("New App", manifest.title):gsub("App\",", manifest.label .. "\","))
    write_file(root .. "/lib/readme.lua", "return { name = \"" .. id .. "\" }\n")
    state.app_id = id
    state.root = root
    state.manifest = manifest
    state.status = "Created " .. root
    load_projects(state)
    load_current_file(state)
end

local function load_project(state, id)
    id = safe_id(id or state.app_id or "my_app")
    state.app_id = id
    state.root = root_for(id)
    if not api.userfs.exists(state.root .. "/app.lua") then
        create_project(state, id)
        return
    end
    state.manifest = load_manifest(state.root, id)
    load_current_file(state)
    state.status = "Loaded " .. id
end

local function save_current_file(state)
    local ok, err = write_file(state.root .. "/" .. state.file, state.source or "")
    state.status = ok and ("Saved " .. state.file) or tostring(err)
    if ok then
        state.dirty = false
    end
    return ok
end

local function save_manifest(state)
    state.manifest = state.manifest or default_manifest(state.app_id)
    state.manifest.id = state.app_id
    local ok, err = write_file(state.root .. "/manifest", serialize_manifest(state.manifest))
    state.status = ok and "Saved manifest" or tostring(err)
    return ok
end

local function make_package(state)
    save_current_file(state)
    save_manifest(state)
    local files = {}
    for _, file in ipairs(project_files(state.root)) do
        if file ~= "manifest" then
            files[#files + 1] = {
                path = file,
                data = read_file(state.root .. "/" .. file) or "",
            }
        end
    end
    return {
        id = state.app_id,
        title = state.manifest and state.manifest.title or state.app_id,
        label = state.manifest and state.manifest.label or state.app_id:sub(1, 4),
        version = state.manifest and state.manifest.version or "dev",
        author = state.manifest and state.manifest.author,
        description = state.manifest and state.manifest.description,
        devices = state.manifest and state.manifest.devices,
        refresh_rate = state.manifest and state.manifest.refresh_rate,
        render_mode = state.manifest and state.manifest.render_mode,
        mutable_paths = state.manifest and state.manifest.mutable_paths,
        files = files,
    }
end

local function lint_source(name, source, diagnostics)
    diagnostics = diagnostics or {}
    if name:match("%.lua$") and api.dev and api.dev.lint then
        local ok, result = api.dev.lint(source or "")
        if ok then
            for _, item in ipairs(result or {}) do
                diagnostics[#diagnostics + 1] = {
                    file = name,
                    severity = item.severity or "info",
                    message = item.message or "",
                }
            end
        else
            diagnostics[#diagnostics + 1] = { file = name, severity = "error", message = tostring(result) }
        end
    end
    if name == "app.lua" and not tostring(source or ""):find("return%s+app") then
        diagnostics[#diagnostics + 1] = { file = name, severity = "hint", message = "Entry should return app." }
    end
    return diagnostics
end

local function lint_project(state)
    save_current_file(state)
    local diagnostics = {}
    for _, file in ipairs(project_files(state.root)) do
        if file ~= "manifest" then
            lint_source(file, read_file(state.root .. "/" .. file), diagnostics)
        end
    end
    state.diagnostics = diagnostics
    state.status = #diagnostics == 0 and "Lint passed" or ("Diagnostics: " .. tostring(#diagnostics))
    return diagnostics
end

local function lint_current_file(state)
    if not state.lint_dirty then
        return state.diagnostics or {}
    end
    local diagnostics = {}
    lint_source(state.file or "app.lua", state.source or "", diagnostics)
    state.diagnostics = diagnostics
    state.lint_dirty = false
    return diagnostics
end

local function install_project(state, run_after)
    local diagnostics = lint_project(state)
    local blocking = false
    for _, item in ipairs(diagnostics) do
        if item.severity == "error" then
            blocking = true
            break
        end
    end
    if blocking then
        state.status = "Fix lint errors before install"
        return false
    end
    local ok, result = api.apps.install_dev(make_package(state))
    state.status = ok and ("Installed " .. tostring(result.id)) or tostring(result)
    if ok and run_after and api.desktop and api.desktop.open_app then
        api.desktop.open_app(state.app_id)
    end
    return ok
end

local function completions(prefix)
    local out = {}
    if api.dev and api.dev.completions then
        out = api.dev.completions(prefix or "")
    end
    local seen = {}
    for _, word in ipairs(out) do
        seen[word] = true
    end
    for _, word in ipairs(API_WORDS) do
        if not seen[word] and (not prefix or prefix == "" or word:sub(1, #prefix) == prefix) then
            out[#out + 1] = word
        end
    end
    table.sort(out)
    return out
end

local function unescape(text)
    return tostring(text or "")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", "\"")
        :gsub("&apos;", "'")
        :gsub("&amp;", "&")
end

local function hctml_to_lines(hctml)
    local lines = {}
    for body in tostring(hctml or ""):gmatch("<h%d[^>]*>(.-)</h%d>") do
        lines[#lines + 1] = unescape(body:gsub("<[^>]+>", ""))
    end
    for body in tostring(hctml or ""):gmatch("<p[^>]*>(.-)</p>") do
        local line = unescape(body:gsub("<[^>]+>", ""))
        if line:match("%S") then
            lines[#lines + 1] = line
        end
    end
    return lines
end

local function fetch_doc(state, path)
    if not api.hypernet or not api.hypernet.request then
        return nil, "HyperNetUnavailable"
    end
    local reply, err = api.hypernet.request({
        type = "web.get",
        domain = "docs.tesserac",
        path = path,
    }, "web.get.result", 6)
    if not reply or not reply.ok then
        return nil, (reply and reply.error) or err or "DocsUnavailable"
    end
    local page = reply.result or {}
    return hctml_to_lines(page.hctml or page.body or "")
end

local function load_server_doc(state)
    state.docs_cache = state.docs_cache or {}
    local key = tostring(state.doc_id or "desktop-sdk") .. ":" .. tostring(state.doc_query or "")
    if state.docs_cache[key] then
        return state.docs_cache[key]
    end
    local path
    if tostring(state.doc_query or "") ~= "" then
        path = "/search/" .. tostring(state.doc_query):gsub("%s+", "%%20")
    else
        path = "/raw/" .. tostring(state.doc_id or "desktop-sdk")
    end
    local lines, err = fetch_doc(state, path)
    if lines and #lines > 0 then
        state.docs_cache[key] = lines
        return lines
    end
    return {
        "Docs offline: " .. tostring(err or "DocsEmpty"),
        "Use Terminal: appnew, applint, appinstalllocal, apprun.",
        "Use HCAPI.screen, HCAPI.fs, HCAPI.userfs, HCAPI.desktop.",
    }
end

local function push_term(state, line)
    state.term_lines = state.term_lines or {}
    state.term_lines[#state.term_lines + 1] = tostring(line or "")
    state.term_scroll = 0
    while #state.term_lines > 120 do
        table.remove(state.term_lines, 1)
    end
end

local function command_words(command)
    local out = {}
    for word in tostring(command or ""):gmatch("%S+") do
        out[#out + 1] = word
    end
    return out
end

local function run_sdk_command(state, command)
    local args = command_words(command)
    local cmd = tostring(args[1] or "")
    if cmd == "" then
        return
    elseif cmd == "help" then
        push_term(state, "new <id> load <id> file <path> save lint install run")
        push_term(state, "set title|label|version|desc <value>")
        push_term(state, "doc <id> search <query> lua <code>")
    elseif cmd == "new" then
        create_project(state, args[2] or "my_app")
        push_term(state, state.status)
    elseif cmd == "load" then
        load_project(state, args[2] or state.app_id)
        push_term(state, state.status)
    elseif cmd == "file" then
        local file = rel_path(args[2] or "app.lua")
        if file then
            write_file(state.root .. "/" .. file, read_file(state.root .. "/" .. file) or "")
            state.files = project_files(state.root)
            for i, candidate in ipairs(state.files) do
                if candidate == file then
                    state.file_index = i
                    break
                end
            end
            load_current_file(state)
            push_term(state, "Editing " .. file)
        end
    elseif cmd == "save" then
        save_current_file(state)
        save_manifest(state)
        push_term(state, state.status)
    elseif cmd == "lint" then
        local d = lint_project(state)
        push_term(state, #d == 0 and "lint ok" or ("diagnostics " .. #d))
    elseif cmd == "install" then
        install_project(state, false)
        push_term(state, state.status)
    elseif cmd == "run" then
        install_project(state, true)
        push_term(state, state.status)
    elseif cmd == "set" then
        local field = args[2]
        local value = command:match("^%S+%s+%S+%s+(.+)$") or ""
        state.manifest = state.manifest or default_manifest(state.app_id)
        if field == "title" or field == "label" or field == "version" or field == "author" then
            state.manifest[field] = value
        elseif field == "desc" or field == "description" then
            state.manifest.description = value
        elseif field == "fps" or field == "refresh_rate" then
            state.manifest.refresh_rate = tonumber(value) or state.manifest.refresh_rate
        end
        save_manifest(state)
        push_term(state, "Set " .. tostring(field))
    elseif cmd == "doc" then
        state.doc_id = args[2] or "desktop-sdk"
        state.doc_query = ""
        state.tab = "docs"
        push_term(state, "Doc " .. state.doc_id)
    elseif cmd == "search" then
        state.doc_query = command:match("^%S+%s+(.+)$") or ""
        state.tab = "docs"
        push_term(state, "Search " .. state.doc_query)
    elseif cmd == "lua" and api.dev and api.dev.sandbox_run then
        local code = command:match("^%S+%s+(.+)$") or ""
        local ok, result = api.dev.sandbox_run(code, { app_id = state.app_id, root = state.root })
        push_term(state, (ok and "" or "! ") .. tostring(result))
    else
        push_term(state, "Unknown command")
    end
end

local function init(state)
    if state.ready then
        return
    end
    state.ready = true
    state.tab = "project"
    state.app_id = "my_app"
    state.new_id = "my_app"
    state.doc_id = "desktop-sdk"
    state.doc_query = ""
    state.term_input = ""
    state.term_lines = { "HyperCube SDK terminal", "Type help" }
    state.menu_open = false
    state.sidebar_open = true
    state.clipboard = ""
    state.ctrl_down = false
    state.drag_selecting = false
    state.lint_dirty = true
    state.project_scroll = 0
    state.files_scroll = 0
    state.lint_scroll = 0
    state.doc_scroll = 0
    state.api_scroll = 0
    state.term_scroll = 0
    load_projects(state)
    load_project(state, state.projects[1] or state.app_id)
end

local function truncate(text, width)
    text = tostring(text or "")
    width = math.max(1, tonumber(width) or 1)
    if #text > width then
        return text:sub(1, math.max(1, width - 1)) .. "~"
    end
    return text
end

local function draw_tabs(ctx, state)
    local x = ctx.x
    for _, tab in ipairs(TABS) do
        local w = math.min(#tab + 2, 10)
        if x + w > ctx.x + ctx.width then
            break
        end
        ctx.buttons["tab_" .. tab] = api.screen.button("tab_" .. tab, x, ctx.y, w, truncate(tab, w), {
            fg = state.tab == tab and C.black or C.white,
            bg = state.tab == tab and C.yellow or C.gray,
        })
        x = x + w + 1
    end
end

local function draw_toolbar(ctx, state, y)
    ctx.buttons.menu = api.screen.button("menu", ctx.x, y, 6, "Menu", { fg = C.white, bg = C.blue })
    local status_x = ctx.x + 8
    api.screen.write(status_x, y, truncate(state.status or "", math.max(1, ctx.width - 8)), C.lightGray, C.black)
    if state.menu_open then
        local labels = {
            save = "Save",
            install = "Install",
            run = "Run",
            term = "Terminal",
        }
        local row = y + 1
        for _, action in ipairs(MENU_ACTIONS) do
            ctx.buttons["menu_" .. action] = api.screen.button("menu_" .. action, ctx.x, row, 10, labels[action] or action, {
                fg = C.white,
                bg = action == "run" and C.green or C.gray,
            })
            row = row + 1
        end
    end
end

local function draw_file_sidebar(ctx, state, y)
    local width = state.sidebar_open and math.min(18, math.max(10, math.floor(ctx.width * 0.32))) or 3
    local bottom = ctx.y + ctx.height - 1
    local sidebar_height = math.max(1, bottom - y + 1)
    api.screen.rect(ctx.x, y, width, sidebar_height, C.gray)
    ctx.buttons.sidebar_toggle = api.screen.button("sidebar_toggle", ctx.x, y, 3, state.sidebar_open and "<<" or ">>", { fg = C.white, bg = C.blue })
    if not state.sidebar_open then
        return width + 1
    end

    ctx.buttons.prev_file = api.screen.button("prev_file", ctx.x + 4, y, 3, "<", { fg = C.white, bg = C.blue })
    ctx.buttons.next_file = api.screen.button("next_file", ctx.x + 8, y, 3, ">", { fg = C.white, bg = C.blue })
    ctx.buttons.new_file = api.screen.button("new_file", ctx.x + 12, y, math.max(1, math.min(5, width - 12)), "+", { fg = C.white, bg = C.green })

    local row = y + 2
    local visible = math.max(0, bottom - row + 1)
    state.files_scroll = clamp_scroll(state.files_scroll, #(state.files or {}), visible)
    local first = (state.files_scroll or 0) + 1
    for i = first, math.min(#(state.files or {}), first + visible - 1) do
        local file = state.files[i]
        local depth = 0
        for _ in tostring(file or ""):gmatch("/") do
            depth = depth + 1
        end
        local name = tostring(file or ""):match("([^/]+)$") or tostring(file or "")
        local label = string.rep(" ", math.min(3, depth)) .. name
        local bg = i == state.file_index and C.black or C.gray
        local fg = i == state.file_index and C.yellow or C.white
        ctx.buttons["file_" .. tostring(i)] = api.screen.button("file_" .. tostring(i), ctx.x, row, width, truncate(label, width), { fg = fg, bg = bg })
        row = row + 1
    end
    return width + 1
end

local function draw_project(ctx, state, y)
    api.screen.write(ctx.x, y, "Projects in /dev/apps", C.cyan, C.black)
    ctx.buttons.new_project = api.screen.button("new_project", ctx.x, y + 1, 6, "New", { fg = C.white, bg = C.green })
    ctx.buttons.prev_project = api.screen.button("prev_project", ctx.x + 7, y + 1, 3, "<", { fg = C.white, bg = C.blue })
    ctx.buttons.next_project = api.screen.button("next_project", ctx.x + 11, y + 1, 3, ">", { fg = C.white, bg = C.blue })
    api.screen.write(ctx.x + 15, y + 1, "new id: " .. tostring(state.new_id or ""), C.white, C.black)
    local row = y + 3
    local visible = math.max(1, ctx.y + ctx.height - row - 1)
    state.project_scroll = clamp_scroll(state.project_scroll, #(state.projects or {}), visible)
    local first = (state.project_scroll or 0) + 1
    for i = first, math.min(#(state.projects or {}), first + visible - 1) do
        local id = state.projects[i]
        if row >= ctx.y + ctx.height - 1 then break end
        local marker = id == state.app_id and "> " or "  "
        api.screen.write(ctx.x, row, marker .. id, id == state.app_id and C.yellow or C.lightGray, C.black)
        row = row + 1
    end
end

local LUA_KEYWORDS = {
    ["and"] = true,
    ["break"] = true,
    ["do"] = true,
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["false"] = true,
    ["for"] = true,
    ["function"] = true,
    ["if"] = true,
    ["in"] = true,
    ["local"] = true,
    ["nil"] = true,
    ["not"] = true,
    ["or"] = true,
    ["repeat"] = true,
    ["return"] = true,
    ["then"] = true,
    ["true"] = true,
    ["until"] = true,
    ["while"] = true,
}

local SPECIAL_NAMES = {
    HCAPI = C.cyan,
    api = C.cyan,
    app = C.green,
    ctx = C.yellow,
    state = C.yellow,
    C = C.purple,
    colors = C.purple,
    keys = C.purple,
}

local function draw_code_segment(ctx, x, y, text, fg, bg)
    if text == "" then
        return x
    end
    api.screen.write(x, y, text, fg, bg or C.black)
    return x + #text
end

local function draw_code_line(ctx, y, line, state, diagnostics)
    line = line or { text = "", start = 0, finish = 0, line_no = 1 }
    state = state or {}
    local width = math.max(1, ctx.width)
    local text = tostring(line.text or ""):sub(1, width)
    local line_bg = diagnostics and diagnostics[line.line_no] == "error" and C.red or C.black
    local sel_first, sel_last = selection_bounds(state)
    api.screen.write(ctx.x, y, string.rep(" ", width), C.lightGray, line_bg)

    local x = ctx.x
    local index = 1
    while index <= #text and x < ctx.x + width do
        local two = text:sub(index, index + 1)
        local ch = text:sub(index, index)

        if two == "--" then
            x = draw_code_segment(ctx, x, y, text:sub(index), C.gray, line_bg)
            break
        elseif ch == "\"" or ch == "'" then
            local quote = ch
            local finish = index + 1
            local escaped = false
            while finish <= #text do
                local current = text:sub(finish, finish)
                if escaped then
                    escaped = false
                elseif current == "\\" then
                    escaped = true
                elseif current == quote then
                    break
                end
                finish = finish + 1
            end
            local segment = text:sub(index, math.min(finish, #text))
            local global = (line.start or 0) + index - 1
            local bg = sel_first and global < sel_last and global + #segment > sel_first and C.blue or line_bg
            x = draw_code_segment(ctx, x, y, segment, C.orange, bg)
            index = math.min(finish + 1, #text + 1)
        elseif ch:match("[%a_]") then
            local finish = index
            while finish <= #text and text:sub(finish, finish):match("[%w_]") do
                finish = finish + 1
            end
            local word = text:sub(index, finish - 1)
            local color = SPECIAL_NAMES[word] or (LUA_KEYWORDS[word] and C.blue) or C.lightGray
            local global = (line.start or 0) + index - 1
            local bg = sel_first and global < sel_last and global + #word > sel_first and C.blue or line_bg
            x = draw_code_segment(ctx, x, y, word, color, bg)
            index = finish
        elseif ch:match("%d") then
            local finish = index
            while finish <= #text and text:sub(finish, finish):match("[%w%.]") do
                finish = finish + 1
            end
            local segment = text:sub(index, finish - 1)
            local global = (line.start or 0) + index - 1
            local bg = sel_first and global < sel_last and global + #segment > sel_first and C.blue or line_bg
            x = draw_code_segment(ctx, x, y, segment, C.yellow, bg)
            index = finish
        elseif ch:match("[%+%-%*%/%=%%<>#{}%[%]%(%)%,%.:]") then
            local global = (line.start or 0) + index - 1
            local bg = sel_first and global >= sel_first and global < sel_last and C.blue or line_bg
            x = draw_code_segment(ctx, x, y, ch, C.white, bg)
            index = index + 1
        else
            local global = (line.start or 0) + index - 1
            local bg = sel_first and global >= sel_first and global < sel_last and C.blue or line_bg
            x = draw_code_segment(ctx, x, y, ch, C.lightGray, bg)
            index = index + 1
        end
    end

    local cursor = tonumber(state.cursor or 0) or 0
    local line_start = tonumber(line.start or 0) or 0
    local line_finish = tonumber(line.finish or line_start) or line_start
    local blink = api.time and math.floor(api.time() / 500) % 2 == 0
    if blink and cursor >= line_start and cursor <= line_finish then
        local col = math.min(width - 1, math.max(0, cursor - line_start))
        api.screen.write(ctx.x + col, y, col < #text and text:sub(col + 1, col + 1) or " ", C.black, C.yellow)
    end
end

local function draw_editor(ctx, state, y)
    api.screen.write(ctx.x, y, "Editing " .. tostring(state.file), C.cyan, C.black)
    ctx.buttons.complete_insert = api.screen.button("complete_insert", ctx.x, y + 1, 8, "Insert", { fg = C.black, bg = C.yellow })
    local diagnostics = lint_current_file(state)
    local issue = diagnostics[1]
    local status = issue and (tostring(issue.severity) .. ": " .. tostring(issue.message)) or "No diagnostics"
    api.screen.write(ctx.x + 10, y + 1, truncate(status, math.max(1, ctx.width - 10)), issue and C.orange or C.green, C.black)
    local lines = visual_lines_for(state.source or "", math.max(1, ctx.width - 1))
    local first_row = y + 3
    local bottom = ctx.y + ctx.height - 1
    local max_rows = math.max(0, bottom - first_row + 1)
    state.edit_scroll = clamp_scroll(state.edit_scroll, #lines, max_rows)
    local first = math.max(1, (state.edit_scroll or 0) + 1)
    state.editor_layout = {
        x = ctx.x,
        y = first_row,
        width = ctx.width,
        height = max_rows,
        first = first,
        lines = lines,
    }
    local diagnostic_lines = diagnostic_lines_for_current_file(state)
    for i = 1, math.min(max_rows, #lines - first + 1) do
        draw_code_line(ctx, y + 2 + i, lines[first + i - 1], state, diagnostic_lines)
    end
end

local function draw_manifest(ctx, state, y)
    local m = state.manifest or {}
    local rows = {
        "id: " .. tostring(state.app_id),
        "title: " .. tostring(m.title),
        "label: " .. tostring(m.label),
        "version: " .. tostring(m.version),
        "author: " .. tostring(m.author),
        "description: " .. tostring(m.description),
        "refresh_rate: " .. tostring(m.refresh_rate),
        "devices: " .. table.concat(m.devices or {}, ", "),
    }
    api.screen.write(ctx.x, y, "Manifest - edit with terminal: set title <value>", C.cyan, C.black)
    for i, row in ipairs(rows) do
        if y + i >= ctx.y + ctx.height then break end
        api.screen.write(ctx.x, y + i, truncate(row, ctx.width), C.lightGray, C.black)
    end
end

local function draw_files(ctx, state, y)
    api.screen.write(ctx.x, y, "Project files", C.cyan, C.black)
    ctx.buttons.prev_file = api.screen.button("prev_file", ctx.x, y + 1, 3, "<", { fg = C.white, bg = C.blue })
    ctx.buttons.next_file = api.screen.button("next_file", ctx.x + 4, y + 1, 3, ">", { fg = C.white, bg = C.blue })
    ctx.buttons.delete_file = api.screen.button("delete_file", ctx.x + 8, y + 1, 7, "Delete", { fg = C.white, bg = C.red })
    local row = y + 3
    local visible = math.max(1, ctx.y + ctx.height - row - 1)
    state.files_scroll = clamp_scroll(state.files_scroll, #(state.files or {}), visible)
    local first = (state.files_scroll or 0) + 1
    for i = first, math.min(#(state.files or {}), first + visible - 1) do
        local file = state.files[i]
        if row >= ctx.y + ctx.height - 1 then break end
        local marker = i == state.file_index and "> " or "  "
        api.screen.write(ctx.x, row, marker .. file, i == state.file_index and C.yellow or C.lightGray, C.black)
        row = row + 1
    end
end

local function draw_lint(ctx, state, y)
    lint_project(state)
    api.screen.write(ctx.x, y, "Diagnostics", C.cyan, C.black)
    if #(state.diagnostics or {}) == 0 then
        api.screen.write(ctx.x, y + 1, "No diagnostics.", C.green, C.black)
        return
    end
    local visible = math.max(1, ctx.height - 4)
    state.lint_scroll = clamp_scroll(state.lint_scroll, #(state.diagnostics or {}), visible)
    local first = (state.lint_scroll or 0) + 1
    for row = 1, math.min(visible, #(state.diagnostics or {}) - first + 1) do
        local item = state.diagnostics[first + row - 1]
        local text = tostring(item.file) .. " " .. tostring(item.severity) .. ": " .. tostring(item.message)
        api.screen.write(ctx.x, y + row, truncate(text, ctx.width), item.severity == "error" and C.red or C.orange, C.black)
    end
end

local function draw_docs(ctx, state, y)
    ctx.buttons.doc_prev = api.screen.button("doc_prev", ctx.x, y, 3, "<", { fg = C.white, bg = C.blue })
    ctx.buttons.doc_next = api.screen.button("doc_next", ctx.x + 4, y, 3, ">", { fg = C.white, bg = C.blue })
    ctx.buttons.doc_search = api.screen.button("doc_search", ctx.x + 8, y, 7, "Search", { fg = C.white, bg = C.green })
    api.screen.write(ctx.x + 16, y, truncate((state.doc_query ~= "" and ("search: " .. state.doc_query) or ("doc: " .. state.doc_id)), ctx.width - 16), C.cyan, C.black)
    local lines = load_server_doc(state)
    local visible = math.max(1, ctx.height - 4)
    state.doc_scroll = clamp_scroll(state.doc_scroll, #lines, visible)
    local first = (state.doc_scroll or 0) + 1
    for i = 1, math.min(#lines - first + 1, visible) do
        api.screen.write(ctx.x, y + i + 1, truncate(lines[first + i - 1], ctx.width), C.lightGray, C.black)
    end
end

local function draw_api(ctx, state, y)
    local prefix = state.complete_prefix or "HCAPI."
    api.screen.write(ctx.x, y, "Completions for " .. prefix, C.cyan, C.black)
    ctx.buttons.complete_prefix = api.screen.button("complete_prefix", ctx.x, y + 1, 7, "Prefix", { fg = C.white, bg = C.blue })
    local list = completions(prefix)
    state.current_completions = list
    local visible = math.max(1, ctx.height - 4)
    state.api_scroll = clamp_scroll(state.api_scroll, #list, visible)
    local first = (state.api_scroll or 0) + 1
    for i = 1, math.min(#list - first + 1, visible) do
        api.screen.write(ctx.x, y + i + 1, truncate(list[first + i - 1], ctx.width), C.yellow, C.black)
    end
end

local function draw_build(ctx, state, y)
    local package = make_package(state)
    api.screen.write(ctx.x, y, "Build package", C.cyan, C.black)
    local rows = {
        "id: " .. tostring(package.id),
        "version: " .. tostring(package.version),
        "files: " .. tostring(#(package.files or {})),
        "devices: " .. table.concat(package.devices or {}, ", "),
        "mutable: " .. table.concat(package.mutable_paths or {}, ", "),
    }
    for i, row in ipairs(rows) do
        api.screen.write(ctx.x, y + i, truncate(row, ctx.width), C.lightGray, C.black)
    end
end

local function draw_term(ctx, state, y, height, width)
    api.screen.write(ctx.x, y, "SDK terminal", C.cyan, C.black)
    local visible = math.max(1, height - 3)
    state.term_scroll = clamp_scroll(state.term_scroll, #(state.term_lines or {}), visible)
    local first = math.max(1, #(state.term_lines or {}) - visible + 1 - (state.term_scroll or 0))
    local row = y + 1
    for i = first, #(state.term_lines or {}) do
        api.screen.write(ctx.x, row, truncate(state.term_lines[i], width), C.lightGray, C.black)
        row = row + 1
        if row >= y + visible then break end
    end
    api.screen.write(ctx.x, y + height - 1, truncate("> " .. tostring(state.term_input or ""), width), C.white, C.black)
end

function app.render(ctx)
    local state = ctx.state
    init(state)
    if ctx.window and ctx.window.popup_kind == "terminal" then
        api.screen.rect(ctx.x, ctx.y, ctx.width, ctx.height, C.black)
        draw_term(ctx, state, ctx.y, ctx.height, ctx.width)
        return
    end
    api.screen.rect(ctx.x, ctx.y, ctx.width, ctx.height, C.black)
    draw_tabs(ctx, state)
    local y = ctx.y + 2
    draw_toolbar(ctx, state, y)
    y = y + 2
    if state.menu_open then
        y = y + #MENU_ACTIONS
    end
    if state.tab == "project" then
        draw_project(ctx, state, y)
    elseif state.tab == "edit" then
        local sidebar_width = draw_file_sidebar(ctx, state, y)
        local editor_ctx = {
            x = ctx.x + sidebar_width,
            y = ctx.y,
            width = math.max(1, ctx.width - sidebar_width),
            height = ctx.height,
            buttons = ctx.buttons,
        }
        draw_editor(editor_ctx, state, y)
    elseif state.tab == "manifest" then
        draw_manifest(ctx, state, y)
    elseif state.tab == "docs" then
        draw_docs(ctx, state, y)
    elseif state.tab == "api" then
        draw_api(ctx, state, y)
    elseif state.tab == "build" then
        draw_build(ctx, state, y)
    else
        draw_term(ctx, state, y, ctx.height - 4, ctx.width)
    end
end

local function cycle_project(state, delta)
    if #(state.projects or {}) == 0 then
        load_projects(state)
    end
    if #(state.projects or {}) == 0 then return end
    local index = 1
    for i, id in ipairs(state.projects) do
        if id == state.app_id then index = i break end
    end
    index = index + delta
    if index < 1 then index = #state.projects end
    if index > #state.projects then index = 1 end
    load_project(state, state.projects[index])
end

local function cycle_file(state, delta)
    save_current_file(state)
    state.file_index = (state.file_index or 1) + delta
    if state.file_index < 1 then state.file_index = #(state.files or { "app.lua" }) end
    if state.file_index > #(state.files or {}) then state.file_index = 1 end
    load_current_file(state)
end

local function open_terminal(state)
    if api.desktop and api.desktop.open_terminal then
        local ok = api.desktop.open_terminal({ title = "SDK Terminal", cwd = state.root, width = 48, height = 14 })
        if ok then
            return true
        end
    end
    state.tab = "term"
    return true
end

local function key_is_ctrl(key)
    return keys and (key == keys.leftCtrl or key == keys.rightCtrl or key == keys.leftControl or key == keys.rightControl)
end

local function select_file_index(state, index)
    index = tonumber(index)
    if not index or not state.files or not state.files[index] then
        return false
    end
    save_current_file(state)
    state.file_index = index
    load_current_file(state)
    return true
end

local function select_all(state)
    state.selection_anchor = 0
    state.cursor = #(state.source or "")
end

local function copy_selection(state)
    local text = selected_text(state)
    if text ~= "" then
        state.clipboard = text
        state.status = "Copied"
        return true
    end
    return false
end

local function cut_selection(state)
    if copy_selection(state) then
        delete_selection(state)
        state.status = "Cut"
        return true
    end
    return false
end

function app.on_touch(ctx)
    local state = ctx.state
    init(state)
    local event = ctx.event or {}
    if event.type == "scroll" then
        local delta = tonumber(event.direction or (event.raw and event.raw[2]) or 0) or 0
        if delta == 0 then
            return false
        end
        if ctx.window and ctx.window.popup_kind == "terminal" then
            state.term_scroll = (state.term_scroll or 0) - delta
        elseif state.tab == "project" then
            state.project_scroll = (state.project_scroll or 0) + delta
        elseif state.tab == "edit" then
            state.edit_scroll = (state.edit_scroll or 0) + delta
        elseif state.tab == "files" then
            state.files_scroll = (state.files_scroll or 0) + delta
        elseif state.tab == "lint" then
            state.lint_scroll = (state.lint_scroll or 0) + delta
        elseif state.tab == "docs" then
            state.doc_scroll = (state.doc_scroll or 0) + delta
        elseif state.tab == "api" then
            state.api_scroll = (state.api_scroll or 0) + delta
        elseif state.tab == "term" then
            state.term_scroll = (state.term_scroll or 0) - delta
        else
            return false
        end
        return true
    end
    local id = tostring(ctx.button_id or "")
    local tab = id:match("^tab_(.+)$")
    if tab then
        state.tab = tab
        state.menu_open = false
    elseif id == "menu" then
        state.menu_open = not state.menu_open
    elseif id == "menu_save" then
        save_current_file(state)
        save_manifest(state)
        state.menu_open = false
    elseif id == "menu_install" then
        install_project(state, false)
        state.menu_open = false
    elseif id == "menu_run" then
        install_project(state, true)
        state.menu_open = false
    elseif id == "menu_term" then
        open_terminal(state)
        state.menu_open = false
    elseif id == "sidebar_toggle" then
        state.sidebar_open = not state.sidebar_open
    elseif id == "new_project" then
        create_project(state, state.new_id)
    elseif id == "prev_project" then
        cycle_project(state, -1)
    elseif id == "next_project" then
        cycle_project(state, 1)
    elseif id == "prev_file" then
        cycle_file(state, -1)
    elseif id == "next_file" then
        cycle_file(state, 1)
    elseif id == "new_file" then
        local name = "lib/module" .. tostring(#(state.files or {}) + 1) .. ".lua"
        write_file(state.root .. "/" .. name, "return {}\n")
        state.files = project_files(state.root)
        for i, file in ipairs(state.files) do
            if file == name then state.file_index = i break end
        end
        load_current_file(state)
    elseif id:match("^file_%d+$") then
        select_file_index(state, tonumber(id:match("(%d+)$")))
    elseif id == "delete_file" and state.file ~= "app.lua" and state.file ~= "manifest" then
        api.userfs.delete(state.root .. "/" .. state.file)
        load_current_file(state)
        state.status = "Deleted file"
    elseif id == "complete_insert" then
        local list = completions(state.complete_prefix or "HCAPI.")
        if list[1] then
            replace_selection(state, list[1])
            state.status = "Inserted " .. list[1]
        end
    elseif id == "complete_prefix" then
        state.complete_prefix = state.complete_prefix == "app." and "HCAPI." or "app."
    elseif id == "doc_prev" or id == "doc_next" then
        state.doc_query = ""
        state.doc_scroll = 0
        local current = 1
        for i, doc_id in ipairs(DOC_IDS) do
            if doc_id == state.doc_id then current = i break end
        end
        current = current + (id == "doc_next" and 1 or -1)
        if current < 1 then current = #DOC_IDS end
        if current > #DOC_IDS then current = 1 end
        state.doc_id = DOC_IDS[current]
    elseif id == "doc_search" then
        state.doc_query = state.doc_query == "" and "screen" or ""
        state.doc_scroll = 0
    else
        if state.tab == "edit" and event.type == "touch" and state.editor_layout then
            state.cursor = cursor_from_editor_point(state, event.x, event.y)
            state.selection_anchor = nil
            state.drag_selecting = true
            return true
        elseif state.tab == "edit" and event.type == "drag" and state.editor_layout then
            if state.selection_anchor == nil then
                state.selection_anchor = state.cursor or 0
            end
            state.cursor = cursor_from_editor_point(state, event.x, event.y)
            return true
        elseif event.type == "mouse_up" then
            state.drag_selecting = false
            return true
        end
        return false
    end
    return true
end

function app.on_key(ctx)
    local state = ctx.state
    init(state)
    local event = ctx.event
    local key = event.raw and event.raw[2]
    if event.type == "key" and key_is_ctrl(key) then
        state.ctrl_down = true
        return true
    elseif event.type == "key_up" and key_is_ctrl(key) then
        state.ctrl_down = false
        return true
    end
    if event.type == "key" and state.ctrl_down then
        if key == keys.s then
            save_current_file(state)
            save_manifest(state)
            return true
        elseif key == keys.t then
            open_terminal(state)
            return true
        elseif key == keys.a and state.tab == "edit" then
            select_all(state)
            return true
        elseif key == keys.c and state.tab == "edit" then
            return copy_selection(state)
        elseif key == keys.x and state.tab == "edit" then
            return cut_selection(state)
        elseif key == keys.v and state.tab == "edit" then
            replace_selection(state, state.clipboard or "")
            return true
        elseif key == keys.left and state.tab == "edit" then
            move_cursor_word(state, -1, true)
            return true
        elseif key == keys.right and state.tab == "edit" then
            move_cursor_word(state, 1, true)
            return true
        end
    end
    if state.tab == "term" or (ctx.window and ctx.window.popup_kind == "terminal") then
        if event.type == "char" then
            state.term_input = state.term_input .. tostring(event.raw and event.raw[2] or "")
            return true
        elseif event.type == "paste" then
            state.term_input = state.term_input .. tostring(event.raw and event.raw[2] or "")
            return true
        elseif event.type == "key" and event.raw and event.raw[2] == keys.backspace then
            state.term_input = state.term_input:sub(1, math.max(0, #state.term_input - 1))
            return true
        elseif event.type == "key" and event.raw and event.raw[2] == keys.enter then
            local command = state.term_input
            state.term_input = ""
            push_term(state, "> " .. command)
            run_sdk_command(state, command)
            return true
        end
        return false
    end
    if state.tab == "project" then
        if event.type == "char" then
            state.new_id = safe_id(tostring(state.new_id or "") .. tostring(event.raw and event.raw[2] or ""))
            return true
        elseif event.type == "key" and event.raw and event.raw[2] == keys.backspace then
            state.new_id = tostring(state.new_id or ""):sub(1, math.max(0, #(state.new_id or "") - 1))
            return true
        end
    elseif state.tab == "docs" then
        if event.type == "char" then
            state.doc_query = tostring(state.doc_query or "") .. tostring(event.raw and event.raw[2] or "")
            state.doc_scroll = 0
            return true
        elseif event.type == "key" and event.raw and event.raw[2] == keys.backspace then
            state.doc_query = tostring(state.doc_query or ""):sub(1, math.max(0, #(state.doc_query or "") - 1))
            state.doc_scroll = 0
            return true
        end
    elseif state.tab == "edit" then
        if event.type == "char" then
            replace_selection(state, tostring(event.raw and event.raw[2] or ""))
            return true
        elseif event.type == "paste" then
            replace_selection(state, tostring(event.raw and event.raw[2] or ""))
            return true
        elseif event.type == "key" and event.raw and event.raw[2] == keys.backspace then
            if not delete_selection(state) and (state.cursor or 0) > 0 then
                local source = tostring(state.source or "")
                local cursor = clamp_cursor(state, state.cursor)
                state.source = source:sub(1, cursor - 1) .. source:sub(cursor + 1)
                state.cursor = cursor - 1
                state.dirty = true
                state.lint_dirty = true
            end
            return true
        elseif event.type == "key" and event.raw and event.raw[2] == keys.enter then
            replace_selection(state, "\n")
            return true
        elseif event.type == "key" and event.raw and event.raw[2] == keys.tab then
            local prefix = tostring(state.source or ""):match("([%w_%.:]+)$") or state.complete_prefix or "HCAPI."
            local list = completions(prefix)
            if list[1] then
                local source = tostring(state.source or "")
                local cursor = clamp_cursor(state, state.cursor)
                local before = source:sub(1, cursor)
                local word = before:match("([%w_%.:]+)$") or ""
                state.source = before:sub(1, #before - #word) .. list[1] .. source:sub(cursor + 1)
                state.cursor = #before - #word + #list[1]
                state.dirty = true
                state.lint_dirty = true
                state.status = "Completed " .. list[1]
            end
            return true
        elseif event.type == "key" and event.raw and event.raw[2] == keys.up then
            state.edit_scroll = math.max(0, (state.edit_scroll or 0) - 1)
            return true
        elseif event.type == "key" and event.raw and event.raw[2] == keys.down then
            state.edit_scroll = (state.edit_scroll or 0) + 1
            return true
        elseif event.type == "key" and event.raw and event.raw[2] == keys.left then
            move_cursor(state, (state.cursor or 0) - 1, false)
            return true
        elseif event.type == "key" and event.raw and event.raw[2] == keys.right then
            move_cursor(state, (state.cursor or 0) + 1, false)
            return true
        elseif event.type == "key" and event.raw and event.raw[2] == keys.home then
            move_cursor(state, line_start_for(state.source, state.cursor or 0), false)
            return true
        elseif event.type == "key" and event.raw and event.raw[2] == keys["end"] then
            move_cursor(state, line_end_for(state.source, state.cursor or 0), false)
            return true
        end
    end
    return false
end

return app
