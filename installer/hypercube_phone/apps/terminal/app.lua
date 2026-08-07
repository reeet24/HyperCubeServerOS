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
        push(state, "help clear id net reboot")
        push(state, "appinstall pastebin <id> [app_id]")
        push(state, "appinstall github <owner/repo> <path> [branch] [app_id]")
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
