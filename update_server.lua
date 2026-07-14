-- HyperCubeServer GitHub updater
-- Repo: https://github.com/reeet24/HyperCubeServerOS

local REPO_OWNER = "reeet24"
local REPO_NAME = "HyperCubeServerOS"
local DEFAULT_BRANCH = "main"

local ARGS = { ... }

local INCLUDE_ROOTS = {
    "Kernal",
    "appstore",
    "installer",
    "docs",
    "init.lua",
    "startup.lua",
    "README.md",
    "checklist.md",
    "package_server.lua",
    "package_server.py",
    "update_server.lua",
}

local CLEAN_PATHS = {
    "Kernal",
    "appstore",
    "installer",
    "docs",
    "init.lua",
    "startup.lua",
    "README.md",
    "checklist.md",
    "package_server.lua",
    "package_server.py",
    "update_server.lua",
}

local EXCLUDE = {
    ["logs"] = true,
    ["user"] = true,
    ["hypercube_db"] = true,
    ["disk"] = true,
    [".git"] = true,
    [".agents"] = true,
    [".codex"] = true,
    ["pastebin_dev_key"] = true,
    ["pastebin_dev_key.lua"] = true,
    ["banking/admin_token"] = true,
    ["hypercube_server_pastebin.lua"] = true,
    ["hypercube_server_pastebin_install.lua"] = true,
    ["hypercube_server_pastebin_batch_install.lua"] = true,
}

local function has_flag(flag)
    for _, value in ipairs(ARGS) do
        if value == flag then
            return true
        end
    end
    return false
end

local function get_option(name, fallback)
    for index, value in ipairs(ARGS) do
        if value == name then
            return ARGS[index + 1] or fallback
        end
        local prefix = name .. "="
        if tostring(value):sub(1, #prefix) == prefix then
            return tostring(value):sub(#prefix + 1)
        end
    end
    return fallback
end

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function read_file_trim(path)
    if not fs or not fs.exists or not fs.open or not fs.exists(path) then
        return nil
    end
    local handle = fs.open(path, "r")
    if not handle then
        return nil
    end
    local data = handle.readAll()
    handle.close()
    data = trim(data)
    if data == "" then
        return nil
    end
    return data
end

local function github_token()
    local token = get_option("--token")
    if token and trim(token) ~= "" then
        return trim(token)
    end
    return read_file_trim("github_token")
end

local function combine(a, b)
    if fs and fs.combine then
        return fs.combine(a, b)
    end
    a = tostring(a or "")
    b = tostring(b or "")
    if a == "" then
        return b
    end
    if a:sub(-1) == "/" then
        return a .. b
    end
    return a .. "/" .. b
end

local function normalize(path)
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("^%./", ""):gsub("^/+", "")
    path = path:gsub("//+", "/")
    if path == "." then
        path = ""
    end
    return path
end

local function is_safe_relative(path)
    path = normalize(path)
    return path ~= "" and path:sub(1, 1) ~= "/" and not path:find("..", 1, true)
end

local function is_excluded(path)
    path = normalize(path)
    if EXCLUDE[path] then
        return true
    end
    for excluded in pairs(EXCLUDE) do
        if path:sub(1, #excluded + 1) == excluded .. "/" then
            return true
        end
    end
    return false
end

local function encode_segment(segment)
    segment = tostring(segment or "")
    return segment:gsub("([^%w%-%_%.%~])", function(char)
        return string.format("%%%02X", char:byte())
    end)
end

local function encode_path(path)
    path = normalize(path)
    if path == "" then
        return ""
    end
    local out = {}
    for segment in path:gmatch("[^/]+") do
        out[#out + 1] = encode_segment(segment)
    end
    return table.concat(out, "/")
end

local function http_get(url, accept)
    if not http or not http.get then
        return nil, "HttpUnavailable"
    end
    local headers = {
        ["User-Agent"] = "HyperCubeServerOS-Updater",
        ["Accept"] = accept or "application/vnd.github+json",
        ["X-GitHub-Api-Version"] = "2022-11-28",
    }
    local token = github_token()
    if token then
        headers["Authorization"] = "Bearer " .. token
    end
    local ok, response_or_err, request_err = pcall(http.get, url, headers)
    if not ok then
        return nil, response_or_err
    end
    local response = response_or_err
    if not response and tostring(request_err or ""):lower():match("header") then
        ok, response_or_err, request_err = pcall(http.get, url)
        if not ok then
            return nil, response_or_err
        end
        response = response_or_err
    end
    if not response then
        return nil, request_err or "HttpRequestFailed"
    end
    local body = response.readAll()
    local code = response.getResponseCode and response.getResponseCode() or 200
    response.close()
    if tonumber(code) and tonumber(code) >= 400 then
        return nil, "Http" .. tostring(code) .. ": " .. tostring(body):sub(1, 120)
    end
    return body
end

local function decode_json(text)
    if not textutils or not textutils.unserializeJSON then
        return nil, "JsonUnavailable"
    end
    local ok, result = pcall(textutils.unserializeJSON, text)
    if not ok or result == nil then
        return nil, ok and "JsonDecodeFailed" or result
    end
    return result
end

local entry_names

local function contents_url(path, branch)
    local encoded = encode_path(path)
    local base = "https://api.github.com/repos/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/contents"
    if encoded ~= "" then
        base = base .. "/" .. encoded
    end
    return base .. "?ref=" .. encode_segment(branch)
end

local function fetch_contents(path, branch)
    local body, err = http_get(contents_url(path, branch))
    if not body then
        return nil, err
    end
    local decoded, json_err = decode_json(body)
    if not decoded then
        return nil, json_err
    end
    if type(decoded) == "table" and decoded.message and decoded.documentation_url then
        return nil, decoded.message
    end
    return decoded
end

local function tree_url(branch)
    return "https://api.github.com/repos/" .. REPO_OWNER .. "/" .. REPO_NAME
        .. "/git/trees/" .. encode_segment(branch) .. "?recursive=1"
end

local function fetch_tree(branch)
    local body, err = http_get(tree_url(branch))
    if not body then
        return nil, err
    end
    local decoded, json_err = decode_json(body)
    if not decoded then
        return nil, json_err
    end
    if type(decoded) == "table" and decoded.message then
        return nil, decoded.message
    end
    if decoded.truncated == true then
        return nil, "GitHubTreeTruncated"
    end
    if type(decoded.tree) ~= "table" then
        return nil, "GitHubTreeMissing"
    end
    return decoded
end

local function tree_has_path(tree, path, kind)
    path = normalize(path)
    for _, entry in ipairs(tree and tree.tree or {}) do
        if normalize(entry.path) == path and (not kind or entry.type == kind) then
            return true
        end
    end
    return false
end

local function tree_looks_like_server_root(tree, root)
    root = normalize(root)
    local prefix = root == "" and "" or root .. "/"
    return tree_has_path(tree, prefix .. "init.lua", "blob")
        and tree_has_path(tree, prefix .. "startup.lua", "blob")
        and tree_has_path(tree, prefix .. "Kernal", "tree")
        and tree_has_path(tree, prefix .. "installer", "tree")
end

local function tree_root_entries(tree, root)
    root = normalize(root)
    local prefix = root == "" and "" or root .. "/"
    local seen = {}
    local entries = {}
    for _, entry in ipairs(tree and tree.tree or {}) do
        local path = normalize(entry.path)
        if path:sub(1, #prefix) == prefix then
            local rest = path:sub(#prefix + 1)
            local name = rest:match("^([^/]+)")
            if name and not seen[name] then
                seen[name] = true
                entries[#entries + 1] = {
                    name = name,
                    type = rest == name and entry.type or "tree",
                }
            end
        end
    end
    table.sort(entries, function(a, b)
        return tostring(a.name) < tostring(b.name)
    end)
    return entries
end

local function detect_remote_root_from_tree(tree, requested)
    local candidates = {}
    if requested and requested ~= "" then
        candidates[#candidates + 1] = normalize(requested)
    end
    candidates[#candidates + 1] = "computer/0"
    candidates[#candidates + 1] = "0"
    candidates[#candidates + 1] = ""

    for _, candidate in ipairs(candidates) do
        if tree_looks_like_server_root(tree, candidate) then
            return normalize(candidate), tree_root_entries(tree, candidate)
        end
    end

    for _, entry in ipairs(tree.tree or {}) do
        if entry.type == "tree" then
            local path = normalize(entry.path)
            local depth = 0
            for _ in path:gmatch("/") do
                depth = depth + 1
            end
            if depth <= 4 and tree_looks_like_server_root(tree, path) then
                return path, tree_root_entries(tree, path)
            end
        end
    end

    return nil, "NotServerRoot:/ [" .. entry_names(tree_root_entries(tree, "")) .. "]"
end

local function raw_url(branch, path)
    return "https://raw.githubusercontent.com/" .. REPO_OWNER .. "/" .. REPO_NAME
        .. "/" .. encode_segment(branch) .. "/" .. encode_path(path)
end

local function include_relative(path)
    path = normalize(path)
    if path == "" or is_excluded(path) or not is_safe_relative(path) then
        return false
    end
    for _, root in ipairs(INCLUDE_ROOTS) do
        if path == root or path:sub(1, #root + 1) == root .. "/" then
            return true
        end
    end
    return false
end

local function collect_package_from_tree(remote_root, branch, tree)
    local files = {}
    remote_root = normalize(remote_root)
    local prefix = remote_root == "" and "" or remote_root .. "/"
    for _, entry in ipairs(tree and tree.tree or {}) do
        if entry.type == "blob" then
            local remote_path = normalize(entry.path)
            local relative
            if prefix == "" then
                relative = remote_path
            elseif remote_path:sub(1, #prefix) == prefix then
                relative = remote_path:sub(#prefix + 1)
            end
            if relative and include_relative(relative) then
                local data, data_err = http_get(raw_url(branch, remote_path), "application/octet-stream")
                if not data then
                    return nil, data_err
                end
                files[#files + 1] = {
                    path = relative,
                    data = data,
                    size = #data,
                }
            end
        end
    end
    table.sort(files, function(a, b)
        return a.path < b.path
    end)
    return files
end

local function entry_list_has(entries, name)
    for _, entry in ipairs(entries or {}) do
        if entry.name == name then
            return true
        end
    end
    return false
end

entry_names = function(entries)
    local names = {}
    for _, entry in ipairs(entries or {}) do
        names[#names + 1] = tostring(entry.name or "?")
    end
    table.sort(names)
    return table.concat(names, ", ")
end

local function looks_like_server_root(entries)
    return type(entries) == "table"
        and entry_list_has(entries, "init.lua")
        and entry_list_has(entries, "startup.lua")
        and entry_list_has(entries, "Kernal")
        and entry_list_has(entries, "installer")
end

local function find_server_root(branch, path, depth, seen)
    path = normalize(path)
    seen = seen or {}
    if seen[path] then
        return nil, "AlreadyChecked"
    end
    seen[path] = true

    local entries, err = fetch_contents(path, branch)
    if not entries then
        return nil, err
    end
    if looks_like_server_root(entries) then
        return path, entries
    end
    if depth <= 0 or type(entries) ~= "table" or entries.type then
        return nil, "NotServerRoot:" .. (path == "" and "/" or path) .. " [" .. entry_names(entries) .. "]"
    end

    local last_err = "ServerRootNotFound"
    for _, entry in ipairs(entries) do
        if entry.type == "dir" and entry.name ~= ".git" and entry.name ~= ".github" then
            local child_path = path == "" and entry.name or combine(path, entry.name)
            local found, found_entries = find_server_root(branch, child_path, depth - 1, seen)
            if found then
                return found, found_entries
            end
            last_err = found_entries or last_err
        end
    end
    return nil, last_err
end

local function detect_remote_root(branch, requested)
    local candidates = {}
    if requested and requested ~= "" then
        candidates[#candidates + 1] = requested
    end
    candidates[#candidates + 1] = "computer/0"
    candidates[#candidates + 1] = "0"
    candidates[#candidates + 1] = ""

    local last_err
    for _, candidate in ipairs(candidates) do
        local entries, err = fetch_contents(candidate, branch)
        if entries and looks_like_server_root(entries) then
            return normalize(candidate), entries
        end
        if entries then
            last_err = "NotServerRoot:" .. (candidate == "" and "/" or candidate) .. " [" .. entry_names(entries) .. "]"
        else
            last_err = err
        end
    end
    local found, found_entries_or_err = find_server_root(branch, requested ~= "" and requested or "", 4, {})
    if found then
        return found, found_entries_or_err
    end
    return nil, found_entries_or_err or last_err or "ServerRootNotFound"
end

local function collect_remote(remote_root, relative, branch, files)
    relative = normalize(relative)
    if relative == "" or is_excluded(relative) then
        return true
    end
    if not is_safe_relative(relative) then
        return false, "UnsafePath:" .. tostring(relative)
    end

    local remote_path = remote_root == "" and relative or combine(remote_root, relative)
    local entry, err = fetch_contents(remote_path, branch)
    if not entry then
        return false, err
    end

    if entry.type == "file" then
        if not entry.download_url or entry.download_url == "" then
            return false, "DownloadUrlMissing:" .. relative
        end
        local data, data_err = http_get(entry.download_url, "application/octet-stream")
        if not data then
            return false, data_err
        end
        files[#files + 1] = {
            path = relative,
            data = data,
            size = #data,
        }
        return true
    end

    if type(entry) == "table" and not entry.type then
        table.sort(entry, function(a, b)
            return tostring(a.name) < tostring(b.name)
        end)
        for _, child in ipairs(entry) do
            local child_relative = combine(relative, child.name)
            local ok, child_err = collect_remote(remote_root, child_relative, branch, files)
            if not ok then
                return false, child_err
            end
        end
        return true
    end

    if entry.type == "dir" then
        return true
    end
    return false, "UnsupportedEntry:" .. tostring(relative)
end

local function collect_package(remote_root, branch, root_entries)
    local files = {}
    for _, root in ipairs(INCLUDE_ROOTS) do
        if entry_list_has(root_entries, root) then
            local ok, err = collect_remote(remote_root, root, branch, files)
            if not ok then
                return nil, err
            end
        end
    end
    table.sort(files, function(a, b)
        return a.path < b.path
    end)
    return files
end

local function ensure_parent(path)
    local dir = tostring(path):match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function write_file(path, data)
    ensure_parent(path)
    local handle = fs.open(path, "wb")
    if not handle then
        return false, "OpenFailed:" .. tostring(path)
    end
    handle.write(data)
    handle.close()
    return true
end

local function write_install_record(branch, remote_root, files)
    local handle = fs.open("hypercube_server_install", "w")
    if not handle then
        return false
    end
    handle.write(textutils.serialize({
        os = "HyperCubeServer",
        installed_at = now(),
        files = #files,
        source = "github",
        repo = REPO_OWNER .. "/" .. REPO_NAME,
        branch = branch,
        remote_root = remote_root,
    }))
    handle.close()
    return true
end

local function print_usage()
    print("HyperCubeServer GitHub updater")
    print("")
    print("Usage:")
    print("  update_server.lua [--branch main] [--root computer/0] [--token TOKEN] [--yes] [--dry-run]")
    print("")
    print("Repo: https://github.com/" .. REPO_OWNER .. "/" .. REPO_NAME)
    print("Put a GitHub token in github_token to avoid rate limits.")
end

if has_flag("--help") or has_flag("-h") then
    print_usage()
    return
end

local requested_branch = trim(get_option("--branch", ""))
local branch = requested_branch ~= "" and requested_branch or DEFAULT_BRANCH
local requested_root = trim(get_option("--root", ""))

term.clear()
term.setCursorPos(1, 1)
print("HyperCubeServer GitHub updater")
print("Repo: " .. REPO_OWNER .. "/" .. REPO_NAME)
print("Branch: " .. branch)
print("")

local tree, tree_err = fetch_tree(branch)
local remote_root, root_entries_or_err
if tree then
    remote_root, root_entries_or_err = detect_remote_root_from_tree(tree, requested_root)
else
    root_entries_or_err = tree_err
end
if not remote_root
    and requested_branch == ""
    and branch ~= "master"
    and not tostring(root_entries_or_err or ""):lower():find("rate limit", 1, true) then
    branch = "master"
    print("Branch main not found; trying master...")
    tree, tree_err = fetch_tree(branch)
    if tree then
        remote_root, root_entries_or_err = detect_remote_root_from_tree(tree, requested_root)
    else
        root_entries_or_err = tree_err
    end
end
if not remote_root then
    print("Could not find server root: " .. tostring(root_entries_or_err))
    if tostring(root_entries_or_err or ""):lower():find("rate limit", 1, true) then
        print("Create a GitHub token and run: update_server.lua --token <token> --dry-run")
        print("Or save it in a local file named github_token.")
    end
    print("Try: update_server.lua --root computer/0")
    return
end
print("Remote root: " .. (remote_root == "" and "/" or remote_root))

local files, collect_err
if tree then
    files, collect_err = collect_package_from_tree(remote_root, branch, tree)
else
    files, collect_err = collect_package(remote_root, branch, root_entries_or_err)
end
if not files then
    print("Download failed: " .. tostring(collect_err))
    return
end

local total = 0
for _, file in ipairs(files) do
    total = total + file.size
end
print("Files: " .. tostring(#files))
print("Bytes: " .. tostring(total))

if has_flag("--dry-run") then
    print("")
    print("Dry run complete. No files changed.")
    return
end

if not has_flag("--yes") and not has_flag("-y") then
    print("")
    print("This will replace server source files but preserve user data, logs, and disk DB.")
    write("Continue? [y/N] ")
    local answer = read()
    if tostring(answer or ""):lower() ~= "y" then
        print("Cancelled.")
        return
    end
end

print("Cleaning source paths...")
for _, path in ipairs(CLEAN_PATHS) do
    if fs.exists(path) then
        fs.delete(path)
    end
end

print("Writing files...")
for index, file in ipairs(files) do
    local ok, err = write_file(file.path, file.data)
    if not ok then
        print("Write failed: " .. tostring(err))
        return
    end
    if index % 10 == 0 or index == #files then
        print("Installed " .. tostring(index) .. "/" .. tostring(#files))
    end
end

write_install_record(branch, remote_root, files)
print("")
print("Update complete.")
print("Run 'reboot' or restart this computer.")
