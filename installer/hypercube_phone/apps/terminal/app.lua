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

local function split_args(command)
    local args = {}
    local current = ""
    local quote
    local escaped = false
    for i = 1, #command do
        local ch = command:sub(i, i)
        if escaped then
            current = current .. ch
            escaped = false
        elseif ch == "\\" and quote then
            escaped = true
        elseif quote then
            if ch == quote then
                quote = nil
            else
                current = current .. ch
            end
        elseif ch == "\"" or ch == "'" then
            quote = ch
        elseif ch:match("%s") then
            if current ~= "" then
                args[#args + 1] = current
                current = ""
            end
        else
            current = current .. ch
        end
    end
    if current ~= "" then
        args[#args + 1] = current
    end
    return args
end

local function normalize_path(path)
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("^/+", ""):gsub("^%./", ""):gsub("//+", "/")
    return path
end

local function safe_app_id(id)
    id = tostring(id or ""):lower():gsub("%s+", "")
    id = id:gsub("[^%w_%-%.]", "_")
    if id == "" then
        return nil
    end
    return id
end

local function safe_user_path(path)
    path = normalize_path(path)
    if path == "" then
        return nil
    end
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    if path:find("..", 1, true) then
        return nil
    end
    return path
end

local function id_from_path(path)
    path = normalize_path(path)
    local leaf = path:match("([^/]+)/?$") or "devapp"
    leaf = leaf:gsub("%.lua$", "")
    if leaf == "app" then
        leaf = path:match("([^/]+)/app%.lua$") or leaf
    end
    return safe_app_id(leaf) or "devapp"
end

local function encode_segment(segment)
    return tostring(segment or ""):gsub("([^%w%-%_%.%~])", function(char)
        return string.format("%%%02X", char:byte())
    end)
end

local function encode_path(path)
    path = normalize_path(path)
    local out = {}
    for segment in path:gmatch("[^/]+") do
        out[#out + 1] = encode_segment(segment)
    end
    return table.concat(out, "/")
end

local function http_get(url, accept)
    if not api.dev or not api.dev.http_get then
        return nil, "HttpUnavailable"
    end
    return api.dev.http_get(url, accept)
end

local function decode_json(text)
    if not api.dev or not api.dev.decode_json then
        return nil
    end
    return api.dev.decode_json(text)
end

local function decode_lua_table(text)
    if not api.dev or not api.dev.decode_table then
        return nil
    end
    return api.dev.decode_table(text)
end

local function package_from_text(text, fallback_id)
    local package = decode_lua_table(text) or decode_json(text)
    if type(package) == "table" then
        package.id = safe_app_id(package.id or fallback_id)
        return package
    end
    local id = safe_app_id(fallback_id)
    if not id then
        return nil, "AppIdRequired"
    end
    return {
        id = id,
        title = id,
        source = text,
        version = "dev",
    }
end

local function install_package(state, package)
    if not api.apps or not api.apps.install_dev then
        push(state, "InstallUnavailable")
        return
    end
    local ok, result = api.apps.install_dev(package)
    if ok then
        push(state, "Installed " .. tostring(result.id) .. " (" .. tostring(result.files or 1) .. " files)")
    else
        push(state, tostring(result or "InstallFailed"))
    end
end

local function userfs_read(path)
    if not api.userfs or not api.userfs.read then
        return nil, "UserFSUnavailable"
    end
    path = safe_user_path(path)
    if not path then
        return nil, "InvalidPath"
    end
    return api.userfs.read(path)
end

local function userfs_write(path, data)
    if not api.userfs or not api.userfs.write then
        return false, "UserFSUnavailable"
    end
    path = safe_user_path(path)
    if not path then
        return false, "InvalidPath"
    end
    return api.userfs.write(path, data)
end

local function userfs_list(path)
    if not api.userfs or not api.userfs.list then
        return nil, "UserFSUnavailable"
    end
    path = safe_user_path(path or "/")
    if not path then
        return nil, "InvalidPath"
    end
    return api.userfs.list(path)
end

local function lint_source(state, source)
    if not api.dev or not api.dev.lint then
        push(state, "LintUnavailable")
        return false
    end
    local ok, diagnostics = api.dev.lint(source)
    if not ok then
        push(state, tostring(diagnostics))
        return false
    end
    if #diagnostics == 0 then
        push(state, "lint ok")
        return true
    end
    for _, item in ipairs(diagnostics) do
        push(state, tostring(item.severity or "info") .. ": " .. tostring(item.message or ""))
    end
    return false
end

local function collect_user_app_files(root, relative, files)
    if #files > 128 then
        return false, "TooManyFiles"
    end
    local path = root
    if relative and relative ~= "" then
        path = root:gsub("/+$", "") .. "/" .. relative
    end
    local listing = userfs_list(path)
    if type(listing) == "table" then
        for _, child in ipairs(listing) do
            local child_relative = relative == "" and child or (relative .. "/" .. child)
            local ok, err = collect_user_app_files(root, child_relative, files)
            if not ok then
                return false, err
            end
        end
        return true
    end
    local data, err = userfs_read(path)
    if data == nil then
        return false, err
    end
    if relative ~= "manifest" then
        files[#files + 1] = {
            path = relative,
            data = data,
        }
    end
    return true
end

local function read_manifest_from_userfs(root, fallback_id)
    local data = userfs_read(root:gsub("/+$", "") .. "/manifest")
    local manifest = data and decode_lua_table(data) or nil
    if type(manifest) ~= "table" then
        manifest = {
            id = fallback_id,
            title = fallback_id,
            version = "dev",
            devices = { "TDesktop", "TBusinessDesktop" },
        }
    end
    manifest.id = safe_app_id(manifest.id or fallback_id)
    return manifest
end

local function package_user_app(root, fallback_id)
    root = safe_user_path(root)
    if not root then
        return nil, "InvalidPath"
    end
    local id = safe_app_id(fallback_id or id_from_path(root))
    local manifest = read_manifest_from_userfs(root, id)
    if not manifest.id then
        return nil, "InvalidAppId"
    end
    local files = {}
    local ok, err = collect_user_app_files(root, "", files)
    if not ok then
        return nil, err
    end
    local has_app = false
    for _, file in ipairs(files) do
        if file.path == "app.lua" then
            has_app = true
            break
        end
    end
    if not has_app then
        return nil, "EntrypointRequired"
    end
    manifest.files = files
    return manifest
end

local function scaffold_app(state, args)
    local id = safe_app_id(args[2])
    if not id then
        push(state, "Usage: appnew <app_id>")
        return
    end
    local root = "/dev/apps/" .. id
    if api.userfs and api.userfs.mkdir then
        api.userfs.mkdir("/dev")
        api.userfs.mkdir("/dev/apps")
        api.userfs.mkdir(root)
    end
    userfs_write(root .. "/manifest", textutils.serialize({
        id = id,
        title = id,
        label = id:sub(1, 4),
        version = "0.1.0",
        devices = { "TDesktop", "TBusinessDesktop" },
        refresh_rate = 10,
    }))
    userfs_write(root .. "/app.lua", [[local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "]] .. id .. [[",
        label = "]] .. id:sub(1, 4) .. [[",
        devices = { "TDesktop", "TBusinessDesktop" },
        refresh_rate = 10,
    },
}

function app.render(ctx)
    api.screen.rect(ctx.x, ctx.y, ctx.width, ctx.height, C.black)
    api.screen.write(ctx.x + 1, ctx.y + 1, "Hello from ]] .. id .. [[", C.yellow, C.black)
end

return app
]])
    push(state, "Created " .. root)
end

local function install_local_app(state, args, run_after)
    local root = args[2]
    local app_id = args[3]
    if not root then
        push(state, "Usage: appinstalllocal <userfs_dir> [app_id]")
        return
    end
    local package, err = package_user_app(root, app_id)
    if not package then
        push(state, tostring(err))
        return
    end
    for _, file in ipairs(package.files or {}) do
        if file.path == "app.lua" then
            lint_source(state, file.data)
            break
        end
    end
    install_package(state, package)
    if run_after and api.desktop and api.desktop.open_app then
        api.desktop.open_app(package.id)
        push(state, "Opening " .. tostring(package.id))
    end
end

local function run_lua(state, source)
    if not api.dev or not api.dev.sandbox_run then
        push(state, "SandboxRunUnavailable")
        return
    end
    local ok, result = api.dev.sandbox_run(source, { app_id = "terminal" })
    if ok then
        if tostring(result or "") ~= "" then
            for line in (tostring(result) .. "\n"):gmatch("(.-)\n") do
                push(state, "= " .. line)
            end
        else
            push(state, "= ok")
        end
    else
        push(state, "! " .. tostring(result))
    end
end

local function run_lua_file(state, args)
    local path = args[2]
    if not path then
        push(state, "Usage: run <userfs_lua_path>")
        return
    end
    if not api.dev or not api.dev.run_user_file then
        push(state, "RunFileUnavailable")
        return
    end
    local ok, result = api.dev.run_user_file(path, { app_id = "terminal" })
    if ok then
        if tostring(result or "") ~= "" then
            for line in (tostring(result) .. "\n"):gmatch("(.-)\n") do
                push(state, "= " .. line)
            end
        else
            push(state, "= ok")
        end
    else
        push(state, "! " .. tostring(result))
    end
end

local function install_pastebin(state, args)
    local paste_id = args[3]
    local app_id = args[4]
    if not paste_id or paste_id == "" then
        push(state, "Usage: appinstall pastebin <paste_id> [app_id]")
        return
    end
    push(state, "Downloading pastebin...")
    local body, err = http_get("https://pastebin.com/raw/" .. encode_segment(paste_id), "text/plain")
    if not body then
        push(state, tostring(err or "DownloadFailed"))
        return
    end
    local package, package_err = package_from_text(body, app_id or paste_id)
    if not package then
        push(state, package_err or "InvalidPackage")
        return
    end
    install_package(state, package)
end

local function github_contents_url(repo, path, branch)
    local encoded = encode_path(path)
    local url = "https://api.github.com/repos/" .. tostring(repo or "") .. "/contents"
    if encoded ~= "" then
        url = url .. "/" .. encoded
    end
    return url .. "?ref=" .. encode_segment(branch or "main")
end

local function fetch_github_entry(repo, path, branch)
    local body, err = http_get(github_contents_url(repo, path, branch), "application/vnd.github+json")
    if not body then
        return nil, err
    end
    local decoded = decode_json(body)
    if not decoded then
        return nil, "JsonDecodeFailed"
    end
    if decoded.message and decoded.documentation_url then
        return nil, decoded.message
    end
    return decoded
end

local function collect_github_dir(repo, root_path, relative, branch, files)
    if #files >= 128 then
        return false, "TooManyFiles"
    end
    local path = relative == "" and root_path or normalize_path(root_path .. "/" .. relative)
    local entries, err = fetch_github_entry(repo, path, branch)
    if not entries then
        return false, err
    end
    if entries.type == "file" then
        if not entries.download_url or entries.download_url == "" then
            return false, "DownloadUrlMissing"
        end
        local data, data_err = http_get(entries.download_url, "application/octet-stream")
        if not data then
            return false, data_err
        end
        files[#files + 1] = {
            path = relative,
            data = data,
        }
        return true
    end
    if type(entries) ~= "table" or entries.type then
        return false, "InvalidGitHubEntry"
    end
    table.sort(entries, function(a, b)
        return tostring(a.name) < tostring(b.name)
    end)
    for _, entry in ipairs(entries) do
        if entry.type == "file" or entry.type == "dir" then
            local child = relative == "" and entry.name or (relative .. "/" .. entry.name)
            local ok, child_err = collect_github_dir(repo, root_path, child, branch, files)
            if not ok then
                return false, child_err
            end
        end
    end
    return true
end

local function install_github(state, args)
    local repo = args[3]
    local path = args[4]
    local branch = args[5] or "main"
    local app_id = args[6]
    if not repo or not path or not repo:match("^[%w_%-%.]+/[%w_%-%.]+$") then
        push(state, "Usage: appinstall github <owner/repo> <path> [branch] [app_id]")
        return
    end
    path = normalize_path(path)
    push(state, "Checking github...")
    local entry, err = fetch_github_entry(repo, path, branch)
    if not entry and branch == "main" then
        branch = "master"
        entry, err = fetch_github_entry(repo, path, branch)
    end
    if not entry then
        push(state, tostring(err or "GitHubFetchFailed"))
        return
    end
    if entry.type == "file" then
        if not entry.download_url or entry.download_url == "" then
            push(state, "DownloadUrlMissing")
            return
        end
        push(state, "Downloading file...")
        local body, data_err = http_get(entry.download_url, "application/octet-stream")
        if not body then
            push(state, tostring(data_err or "DownloadFailed"))
            return
        end
        local package, package_err = package_from_text(body, app_id or id_from_path(path))
        if not package then
            push(state, package_err or "InvalidPackage")
            return
        end
        install_package(state, package)
        return
    end
    if type(entry) == "table" and not entry.type then
        push(state, "Downloading folder...")
        local files = {}
        local ok, collect_err = collect_github_dir(repo, path, "", branch, files)
        if not ok then
            push(state, tostring(collect_err or "DownloadFailed"))
            return
        end
        install_package(state, {
            id = safe_app_id(app_id or id_from_path(path)),
            title = app_id or id_from_path(path),
            version = "dev-" .. branch,
            files = files,
        })
        return
    end
    push(state, "UnsupportedGitHubPath")
end

local function install_remote_app(state, command)
    local args = split_args(command)
    local source = tostring(args[2] or ""):lower()
    if source == "pastebin" or source == "pb" then
        install_pastebin(state, args)
    elseif source == "github" or source == "gh" then
        install_github(state, args)
    else
        push(state, "Usage: appinstall pastebin|github ...")
    end
end

local function run_command(state, command)
    command = tostring(command or "")
    push(state, "> " .. command)
    if command == "" then
        return
    elseif command == "help" then
        push(state, "help clear id net reboot ls cat")
        push(state, "lua <expr/code> | run <userfs.lua>")
        push(state, "appnew <id> | applint <file>")
        push(state, "appinstalllocal <dir> [id] | apprun <dir> [id]")
        push(state, "appinstall pastebin <id> [app_id]")
        push(state, "appinstall github <owner/repo> <path> [branch] [app_id]")
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
        run_lua(state, command:sub(5))
    elseif command:sub(1, 4) == "run " then
        run_lua_file(state, split_args(command))
    elseif command:sub(1, 3) == "ls " or command == "ls" then
        local list, err = userfs_list(split_args(command)[2] or "/")
        if not list then
            push(state, tostring(err))
        else
            push(state, table.concat(list, "  "))
        end
    elseif command:sub(1, 4) == "cat " then
        local data, err = userfs_read(split_args(command)[2])
        push(state, data or tostring(err))
    elseif command:sub(1, 7) == "appnew " then
        scaffold_app(state, split_args(command))
    elseif command:sub(1, 8) == "applint " then
        local source, err = userfs_read(split_args(command)[2])
        if source then
            lint_source(state, source)
        else
            push(state, tostring(err))
        end
    elseif command:sub(1, 16) == "appinstalllocal " then
        install_local_app(state, split_args(command), false)
    elseif command:sub(1, 7) == "apprun " then
        install_local_app(state, split_args(command), true)
    elseif command:sub(1, 11) == "appinstall " then
        install_remote_app(state, command)
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
    if state.suggestions and #state.suggestions > 0 and ctx.height > 4 then
        local y = ctx.y + ctx.height - math.min(5, #state.suggestions + 1) - 1
        for i = 1, math.min(4, #state.suggestions) do
            api.screen.write(ctx.x, y + i - 1, tostring(state.suggestions[i]):sub(1, ctx.width), C.black, C.lightGray)
        end
    end
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
        state.suggestions = nil
        run_command(state, command)
        return true
    elseif key == keys.tab then
        local prefix = state.input:match("([%w_%.:]+)$") or state.input
        local suggestions = {}
        if api.dev and api.dev.completions then
            suggestions = api.dev.completions(prefix)
        end
        state.suggestions = suggestions
        if #suggestions == 1 then
            state.input = state.input:gsub("([%w_%.:]+)$", suggestions[1])
        end
        return true
    end
    return false
end

return app
