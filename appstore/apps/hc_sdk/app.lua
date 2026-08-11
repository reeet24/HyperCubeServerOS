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

local DOCS = {
    "Offline SDK summary:",
    "App files live in /dev/apps/<id>.",
    "Every app needs app.lua returning an app table.",
    "Use HCAPI.screen, HCAPI.fs, HCAPI.userfs, HCAPI.desktop, and HCAPI.printer.",
    "Terminal commands: appnew, applint, appinstalllocal, apprun.",
}
local DOC_IDS = { "desktop-sdk", "userapp-api", "banking-api" }

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

local function root_for(id)
    return "/dev/apps/" .. safe_id(id)
end

local function read_file(path)
    return api.userfs.read(path)
end

local function write_file(path, data)
    local parts = {}
    for part in tostring(path or ""):gmatch("[^/]+") do
        parts[#parts + 1] = part
    end
    local current = ""
    for i = 1, #parts - 1 do
        current = current .. "/" .. parts[i]
        api.userfs.mkdir(current)
    end
    return api.userfs.write(path, data)
end

local function load_project(state)
    state.app_id = safe_id(state.app_id or "my_app")
    state.root = root_for(state.app_id)
    state.path = state.root .. "/app.lua"
    local source = read_file(state.path)
    if not source then
        api.userfs.mkdir("/dev")
        api.userfs.mkdir("/dev/apps")
        api.userfs.mkdir(state.root)
        write_file(state.root .. "/manifest", textutils.serialize({
            id = state.app_id,
            title = state.app_id,
            label = state.app_id:sub(1, 4),
            version = "0.1.0",
            devices = { "TDesktop", "TBusinessDesktop" },
        }))
        write_file(state.path, TEMPLATE)
        source = TEMPLATE
    end
    state.source = source or ""
    state.cursor = #(state.source or "")
end

local function lint(state)
    state.diagnostics = {}
    if api.dev and api.dev.lint then
        local ok, result = api.dev.lint(state.source or "")
        state.diagnostics = ok and result or { { severity = "error", message = tostring(result) } }
    end
end

local function install_package(state, run_after)
    write_file(state.path, state.source or "")
    lint(state)
    local package = {
        id = state.app_id,
        title = state.app_id,
        version = "dev",
        files = {
            { path = "app.lua", data = state.source or "" },
        },
        devices = { "TDesktop", "TBusinessDesktop" },
    }
    local ok, result = api.apps.install_dev(package)
    state.status = ok and ("Installed " .. tostring(result.id)) or tostring(result)
    if ok and run_after and api.desktop and api.desktop.open_app then
        api.desktop.open_app(package.id)
    end
end

local function completions(state)
    if api.dev and api.dev.completions then
        return api.dev.completions(state.complete_prefix or "HCAPI.")
    end
    return {}
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
    for tag, body in tostring(hctml or ""):gmatch("<([ph]%d?)%f[^>]*>(.-)</%1>") do
        local line = unescape(body:gsub("<[^>]+>", ""))
        if line:match("%S") then
            lines[#lines + 1] = line
        end
    end
    if #lines == 0 then
        for body in tostring(hctml or ""):gmatch("<p>(.-)</p>") do
            lines[#lines + 1] = unescape(body:gsub("<[^>]+>", ""))
        end
    end
    return lines
end

local function load_server_doc(state, doc_id)
    state.docs_cache = state.docs_cache or {}
    doc_id = tostring(doc_id or "desktop-sdk")
    if state.docs_cache[doc_id] then
        return state.docs_cache[doc_id]
    end
    if not api.hypernet or not api.hypernet.request then
        return nil, "HyperNetUnavailable"
    end
    local reply, err = api.hypernet.request({
        type = "web.get",
        domain = "docs.tesserac",
        path = "/raw/" .. doc_id,
    }, "web.get.result", 6)
    if not reply or not reply.ok then
        return nil, (reply and reply.error) or err or "DocsUnavailable"
    end
    local page = reply.result or {}
    local lines = hctml_to_lines(page.hctml or page.body or "")
    if #lines == 0 then
        return nil, "DocsEmpty"
    end
    state.docs_cache[doc_id] = lines
    return lines
end

local function init(state)
    if state.ready then
        return
    end
    state.ready = true
    state.app_id = "my_app"
    state.tab = "edit"
    state.status = "Ready"
    state.doc_id = "desktop-sdk"
    load_project(state)
    lint(state)
end

local function push_term(state, line)
    state.term_lines = state.term_lines or {}
    state.term_lines[#state.term_lines + 1] = tostring(line or "")
    while #state.term_lines > 80 do
        table.remove(state.term_lines, 1)
    end
end

local function run_term_command(state, command)
    command = tostring(command or "")
    push_term(state, "> " .. command)
    if command == "" then
        return
    elseif command == "help" then
        push_term(state, "lua <code> | lint | run")
    elseif command == "lint" then
        lint(state)
        if #(state.diagnostics or {}) == 0 then
            push_term(state, "lint ok")
        else
            for _, item in ipairs(state.diagnostics) do
                push_term(state, tostring(item.severity) .. ": " .. tostring(item.message))
            end
        end
    elseif command == "run" then
        install_package(state, true)
        push_term(state, tostring(state.status))
    elseif command:sub(1, 4) == "lua " and api.dev and api.dev.sandbox_run then
        local ok, result = api.dev.sandbox_run(command:sub(5), { app_id = state.app_id })
        push_term(state, (ok and "" or "! ") .. tostring(result))
    else
        push_term(state, "UnknownCommand")
    end
end

local function render_terminal(ctx, state)
    state.term_input = state.term_input or ""
    if not state.term_lines then
        state.term_lines = { "SDK terminal", "Type help" }
    end
    api.screen.rect(ctx.x, ctx.y, ctx.width, ctx.height, C.black)
    local visible = math.max(1, ctx.height - 1)
    local first = math.max(1, #state.term_lines - visible + 1)
    local row = 0
    for i = first, #state.term_lines do
        api.screen.write(ctx.x, ctx.y + row, tostring(state.term_lines[i]):sub(1, ctx.width), C.lightGray, C.black)
        row = row + 1
        if row >= visible then
            break
        end
    end
    api.screen.write(ctx.x, ctx.y + ctx.height - 1, ("> " .. state.term_input):sub(1, ctx.width), C.white, C.black)
end

local function draw_tabs(ctx, state)
    local tabs = { "edit", "lint", "docs", "complete" }
    local x = ctx.x
    for _, tab in ipairs(tabs) do
        ctx.buttons["tab_" .. tab] = api.screen.button("tab_" .. tab, x, ctx.y, #tab + 2, tab, {
            fg = state.tab == tab and C.black or C.white,
            bg = state.tab == tab and C.yellow or C.gray,
        })
        x = x + #tab + 3
    end
end

function app.render(ctx)
    local state = ctx.state
    init(state)
    if ctx.window and ctx.window.popup_kind == "terminal" then
        render_terminal(ctx, state)
        return
    end
    api.screen.rect(ctx.x, ctx.y, ctx.width, ctx.height, C.black)
    draw_tabs(ctx, state)
    local top = ctx.y + 2
    api.screen.write(ctx.x, top, "Project: " .. tostring(state.app_id), C.cyan, C.black)
    ctx.buttons.save = api.screen.button("save", ctx.x, top + 1, 6, "Save", { fg = C.white, bg = C.blue })
    ctx.buttons.install = api.screen.button("install", ctx.x + 7, top + 1, 9, "Install", { fg = C.white, bg = C.green })
    ctx.buttons.run = api.screen.button("run", ctx.x + 17, top + 1, 5, "Run", { fg = C.black, bg = C.yellow })
    ctx.buttons.term = api.screen.button("term", ctx.x + 23, top + 1, 6, "Term", { fg = C.white, bg = C.purple })
    top = top + 3

    if state.tab == "edit" then
        local lines = api.screen.wrap(state.source or "", math.max(1, ctx.width - 1))
        for i = 1, math.min(#lines, ctx.height - 5) do
            api.screen.write(ctx.x, top + i - 1, lines[i], C.lightGray, C.black)
        end
    elseif state.tab == "lint" then
        lint(state)
        if #(state.diagnostics or {}) == 0 then
            api.screen.write(ctx.x, top, "No diagnostics.", C.green, C.black)
        else
            for i, item in ipairs(state.diagnostics) do
                if i > ctx.height - 5 then break end
                api.screen.write(ctx.x, top + i - 1, tostring(item.severity) .. ": " .. tostring(item.message), C.orange, C.black)
            end
        end
    elseif state.tab == "complete" then
        local list = completions(state)
        for i = 1, math.min(#list, ctx.height - 5) do
            api.screen.write(ctx.x, top + i - 1, list[i], C.yellow, C.black)
        end
    else
        ctx.buttons.doc_prev = api.screen.button("doc_prev", ctx.x, top, 3, "<", { fg = C.white, bg = C.blue })
        ctx.buttons.doc_next = api.screen.button("doc_next", ctx.x + 4, top, 3, ">", { fg = C.white, bg = C.blue })
        api.screen.write(ctx.x + 8, top, "docs.tesserac/raw/" .. tostring(state.doc_id or "desktop-sdk"), C.cyan, C.black)
        top = top + 2
        local lines, err = load_server_doc(state, state.doc_id)
        lines = lines or DOCS
        if err then
            api.screen.write(ctx.x, top, "Docs offline: " .. tostring(err), C.orange, C.black)
            top = top + 1
        end
        for i = 1, math.min(#lines, ctx.height - 6) do
            api.screen.write(ctx.x, top + i - 1, tostring(lines[i]):sub(1, ctx.width), C.lightGray, C.black)
        end
    end
    api.screen.write(ctx.x, ctx.y + ctx.height - 1, tostring(state.status or ""), C.white, C.black)
end

function app.on_touch(ctx)
    local state = ctx.state
    init(state)
    local id = tostring(ctx.button_id or "")
    local tab = id:match("^tab_(.+)$")
    if tab then
        state.tab = tab
        return true
    elseif id == "save" then
        local ok, err = write_file(state.path, state.source or "")
        state.status = ok and "Saved " .. state.path or tostring(err)
        return true
    elseif id == "install" then
        install_package(state, false)
        return true
    elseif id == "run" then
        install_package(state, true)
        return true
    elseif id == "term" then
        if api.desktop and api.desktop.open_terminal then
            local ok, err = api.desktop.open_terminal({ cwd = state.root, command = "apprun " .. state.root })
            state.status = ok and "Terminal requested" or tostring(err)
        end
        return true
    elseif id == "doc_prev" or id == "doc_next" then
        local current = 1
        for i, doc_id in ipairs(DOC_IDS) do
            if doc_id == state.doc_id then
                current = i
                break
            end
        end
        current = current + (id == "doc_next" and 1 or -1)
        if current < 1 then current = #DOC_IDS end
        if current > #DOC_IDS then current = 1 end
        state.doc_id = DOC_IDS[current]
        state.status = "Loaded doc " .. state.doc_id
        return true
    end
    return false
end

function app.on_key(ctx)
    local state = ctx.state
    init(state)
    if ctx.window and ctx.window.popup_kind == "terminal" then
        state.term_input = state.term_input or ""
        local event = ctx.event
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
            run_term_command(state, command)
            return true
        end
        return false
    end
    if state.tab ~= "edit" then
        return false
    end
    local event = ctx.event
    if event.type == "char" then
        local ch = event.raw and event.raw[2] or ""
        state.source = (state.source or "") .. ch
        return true
    elseif event.type == "paste" then
        state.source = (state.source or "") .. tostring(event.raw and event.raw[2] or "")
        return true
    elseif event.type == "key" and event.raw and event.raw[2] == keys.backspace then
        state.source = tostring(state.source or ""):sub(1, math.max(0, #(state.source or "") - 1))
        return true
    elseif event.type == "key" and event.raw and event.raw[2] == keys.enter then
        state.source = (state.source or "") .. "\n"
        return true
    end
    return false
end

return app
