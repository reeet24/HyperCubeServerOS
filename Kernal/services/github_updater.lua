-- HyperCubeServer GitHub updater
-- Repo: https://github.com/reeet24/HyperCubeServerOS

local github_updater = {}

local REPO_OWNER = "reeet24"
local REPO_NAME = "HyperCubeServerOS"
local DEFAULT_BRANCH = "main"

local ARGS = { ... }
local config_ok, server_config = pcall(require, "Kernal.services.server_config")

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
    "first_time_setup.lua",
}

local CLEAN_PATHS = {
    "Kernal",
    "installer",
    "docs",
    "init.lua",
    "startup.lua",
    "README.md",
    "checklist.md",
    "package_server.lua",
    "package_server.py",
    "update_server.lua",
    "first_time_setup.lua",
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

local function load_server_config()
    if config_ok and server_config and server_config.load then
        local ok, config = pcall(server_config.load)
        if ok and type(config) == "table" then
            return config
        end
    end
    return {
        installer = {
            root = "installer",
        },
    }
end

local function local_path(path, config)
    path = normalize(path)
    config = config or load_server_config()
    if config_ok and server_config and server_config.local_path then
        return server_config.local_path(config, path)
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

local function commit_url(branch)
    return "https://api.github.com/repos/" .. REPO_OWNER .. "/" .. REPO_NAME
        .. "/commits/" .. encode_segment(branch)
end

local function fetch_commit_sha(branch)
    local body, err = http_get(commit_url(branch))
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
    if not decoded.sha or decoded.sha == "" then
        return nil, "CommitShaMissing"
    end
    return decoded.sha
end

local function compare_url(base_sha, head_sha)
    return "https://api.github.com/repos/" .. REPO_OWNER .. "/" .. REPO_NAME
        .. "/compare/" .. encode_segment(base_sha) .. "..." .. encode_segment(head_sha)
end

local function fetch_compare(base_sha, head_sha)
    local body, err = http_get(compare_url(base_sha, head_sha))
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
    if type(decoded.files) ~= "table" then
        return nil, "CompareFilesMissing"
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
    local base_kernel_sha = {}
    for _, entry in ipairs(tree and tree.tree or {}) do
        if entry.type == "blob" then
            local remote_path = normalize(entry.path)
            local relative
            if prefix == "" then
                relative = remote_path
            elseif remote_path:sub(1, #prefix) == prefix then
                relative = remote_path:sub(#prefix + 1)
            end
            if relative and relative:sub(1, 7) == "Kernal/" then
                base_kernel_sha[relative:sub(8)] = entry.sha
            end
        end
    end
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
                local distro_kernel = relative:match("^installer/[^/]+/Kernal/(.+)$")
                local duplicate_kernel = distro_kernel and base_kernel_sha[distro_kernel] == entry.sha
                if not duplicate_kernel then
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
    path = local_path(path)
    local dir = tostring(path):match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function write_file(path, data)
    path = local_path(path)
    ensure_parent(path)
    local handle = fs.open(path, "wb")
    if not handle then
        return false, "OpenFailed:" .. tostring(path)
    end
    handle.write(data)
    handle.close()
    return true
end

local function read_file(path)
    path = local_path(path)
    if not fs.exists(path) or not fs.open then
        return nil
    end
    local handle = fs.open(path, "rb")
    if not handle then
        return nil
    end
    local data = handle.readAll()
    handle.close()
    return data or ""
end

local function split_lines(text)
    text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if text == "" then
        return {}
    end
    local lines = {}
    if text:sub(-1) ~= "\n" then
        text = text .. "\n"
    end
    for line in text:gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

local function read_install_record()
    local data = read_file("hypercube_server_install")
    if not data or data == "" or not textutils or not textutils.unserialize then
        return nil
    end
    local ok, record = pcall(textutils.unserialize, data)
    if not ok or type(record) ~= "table" then
        return nil
    end
    return record
end

local function remote_relative(remote_root, remote_path)
    remote_root = normalize(remote_root)
    remote_path = normalize(remote_path)
    if remote_root == "" then
        return remote_path
    end
    local prefix = remote_root .. "/"
    if remote_path:sub(1, #prefix) ~= prefix then
        return nil
    end
    return remote_path:sub(#prefix + 1)
end

local function apply_unified_patch(path, patch)
    patch = tostring(patch or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if patch == "" then
        return false, "EmptyPatch:" .. tostring(path)
    end

    local old_lines = split_lines(read_file(path) or "")
    local out = {}
    local source = 1
    local patch_lines = split_lines(patch)
    local index = 1

    while index <= #patch_lines do
        local line = patch_lines[index]
        local old_start = line:match("^@@ %-(%d+)")
        if old_start then
            old_start = tonumber(old_start) or 1
            if old_start < 1 then
                old_start = 1
            end
            while source < old_start and source <= #old_lines do
                out[#out + 1] = old_lines[source]
                source = source + 1
            end
            index = index + 1
            while index <= #patch_lines and not patch_lines[index]:match("^@@ ") do
                line = patch_lines[index]
                local marker = line:sub(1, 1)
                local content = line:sub(2)
                if marker == " " then
                    if old_lines[source] ~= content then
                        return false, "PatchContextMismatch:" .. tostring(path)
                    end
                    out[#out + 1] = content
                    source = source + 1
                elseif marker == "-" then
                    if old_lines[source] ~= content then
                        return false, "PatchRemoveMismatch:" .. tostring(path)
                    end
                    source = source + 1
                elseif marker == "+" then
                    out[#out + 1] = content
                elseif marker == "\\" then
                    -- Ignore "\ No newline at end of file" metadata.
                else
                    return false, "UnsupportedPatchLine:" .. tostring(path)
                end
                index = index + 1
            end
        else
            index = index + 1
        end
    end

    while source <= #old_lines do
        out[#out + 1] = old_lines[source]
        source = source + 1
    end

    return write_file(path, table.concat(out, "\n") .. "\n")
end

local function patch_changes_from_compare(compare, remote_root)
    local changes = {}
    local patch_bytes = 0
    for _, file in ipairs(compare and compare.files or {}) do
        local relative = remote_relative(remote_root, file.filename)
        local previous_relative = file.previous_filename and remote_relative(remote_root, file.previous_filename) or nil
        local include_new = relative and include_relative(relative)
        local include_old = previous_relative and include_relative(previous_relative)

        if include_new or include_old then
            if file.status == "removed" or (file.status == "renamed" and include_old and not include_new) then
                changes[#changes + 1] = {
                    status = "removed",
                    path = previous_relative or relative,
                }
            else
                if file.status == "renamed" and include_old and include_new and previous_relative ~= relative then
                    changes[#changes + 1] = {
                        status = "renamed",
                        from = previous_relative,
                        path = relative,
                    }
                end
                if file.status == "renamed" and include_old and include_new and (not file.patch or file.patch == "") then
                    -- Pure rename. Nothing else to patch after moving the file.
                elseif not file.patch or file.patch == "" then
                    return nil, "PatchMissing:" .. tostring(file.filename)
                else
                    patch_bytes = patch_bytes + #file.patch
                    changes[#changes + 1] = {
                        status = file.status or "modified",
                        path = relative,
                        patch = file.patch,
                    }
                end
            end
        end
    end
    return changes, patch_bytes
end

local function apply_patch_changes(changes)
    for index, change in ipairs(changes or {}) do
        if change.status == "removed" then
            local path = local_path(change.path)
            if fs.exists(path) then
                fs.delete(path)
            end
        elseif change.status == "renamed" then
            local from_path = local_path(change.from)
            local to_path = local_path(change.path)
            if fs.exists(from_path) then
                ensure_parent(change.path)
                if fs.exists(to_path) then
                    fs.delete(to_path)
                end
                fs.move(from_path, to_path)
            end
        else
            local ok, err = apply_unified_patch(change.path, change.patch)
            if not ok then
                return false, err
            end
        end
    end
    return true
end

local function write_install_record(branch, remote_root, files_or_count, commit_sha)
    local handle = fs.open("hypercube_server_install", "w")
    if not handle then
        return false
    end
    local file_count = type(files_or_count) == "table" and #files_or_count or tonumber(files_or_count) or 0
    handle.write(textutils.serialize({
        os = "HyperCubeServer",
        installed_at = now(),
        files = file_count,
        source = "github",
        repo = REPO_OWNER .. "/" .. REPO_NAME,
        branch = branch,
        remote_root = remote_root,
        commit_sha = commit_sha,
    }))
    handle.close()
    return true
end

local function classify_changes(changes)
    local groups = {
        added = {},
        changed = {},
        deleted = {},
    }
    for _, change in ipairs(changes or {}) do
        if change.status == "removed" then
            groups.deleted[#groups.deleted + 1] = change
        elseif change.status == "added" then
            groups.added[#groups.added + 1] = change
        else
            groups.changed[#groups.changed + 1] = change
        end
    end
    return groups
end

local function prepare_status(options)
    options = options or {}
    local branch = trim(options.branch or DEFAULT_BRANCH)
    local requested_root = trim(options.root or "")
    local force_full = options.full == true

    local tree, tree_err = fetch_tree(branch)
    local remote_root, root_entries_or_err
    if tree then
        remote_root, root_entries_or_err = detect_remote_root_from_tree(tree, requested_root)
    else
        root_entries_or_err = tree_err
    end
    if not remote_root
        and not options.branch
        and branch ~= "master"
        and not tostring(root_entries_or_err or ""):lower():find("rate limit", 1, true) then
        branch = "master"
        tree, tree_err = fetch_tree(branch)
        if tree then
            remote_root, root_entries_or_err = detect_remote_root_from_tree(tree, requested_root)
        else
            root_entries_or_err = tree_err
        end
    end
    if not remote_root then
        return false, root_entries_or_err or "ServerRootNotFound"
    end

    local head_sha, head_sha_err = fetch_commit_sha(branch)
    local install_record = read_install_record()
    local status = {
        repo = REPO_OWNER .. "/" .. REPO_NAME,
        branch = branch,
        remote_root = remote_root,
        head_sha = head_sha,
        head_sha_error = head_sha_err,
        base_sha = install_record and install_record.commit_sha or nil,
        installed_at = install_record and install_record.installed_at or nil,
        up_to_date = false,
        mode = force_full and "full" or "unknown",
        changes = {},
        groups = classify_changes({}),
        patch_bytes = 0,
        tree = tree,
        root_entries = root_entries_or_err,
    }

    if not head_sha then
        status.error = head_sha_err or "CommitShaMissing"
        return true, status
    end
    if install_record
        and install_record.source == "github"
        and install_record.repo == status.repo
        and install_record.commit_sha == head_sha
        and not force_full then
        status.up_to_date = true
        status.mode = "current"
        return true, status
    end

    if not force_full
        and install_record
        and install_record.source == "github"
        and install_record.repo == status.repo
        and install_record.commit_sha then
        local compare, compare_err = fetch_compare(tostring(install_record.commit_sha), head_sha)
        if compare then
            local changes, patch_bytes = patch_changes_from_compare(compare, remote_root)
            if changes then
                status.mode = "patch"
                status.changes = changes
                status.groups = classify_changes(changes)
                status.patch_bytes = patch_bytes or 0
                return true, status
            end
            status.patch_error = patch_bytes
        else
            status.patch_error = compare_err
        end
    end

    status.mode = "full"
    local files, collect_err
    if tree then
        files, collect_err = collect_package_from_tree(remote_root, branch, tree)
    else
        files, collect_err = collect_package(remote_root, branch, root_entries_or_err)
    end
    if not files then
        status.error = collect_err
        return true, status
    end
    status.files = files
    status.file_count = #files
    local pseudo = {}
    for _, file in ipairs(files) do
        pseudo[#pseudo + 1] = {
            status = fs.exists(local_path(file.path)) and "modified" or "added",
            path = file.path,
        }
    end
    status.changes = pseudo
    status.groups = classify_changes(pseudo)
    return true, status
end

function github_updater.check_status(options)
    return prepare_status(options)
end

function github_updater.install(status, options)
    options = options or {}
    if type(status) ~= "table" then
        local ok, result = prepare_status(options)
        if not ok then
            return false, result
        end
        status = result
    end
    if status.up_to_date then
        return true, { already_current = true }
    end
    if status.error then
        return false, status.error
    end

    if status.mode == "patch" then
        local ok, err = apply_patch_changes(status.changes)
        if not ok then
            return false, err
        end
        write_install_record(status.branch, status.remote_root, #(status.changes or {}), status.head_sha)
        return true, {
            mode = "patch",
            files = #(status.changes or {}),
            commit_sha = status.head_sha,
        }
    end

    local files = status.files
    if not files then
        local collect_err
        if status.tree then
            files, collect_err = collect_package_from_tree(status.remote_root, status.branch, status.tree)
        else
            files, collect_err = collect_package(status.remote_root, status.branch, status.root_entries)
        end
        if not files then
            return false, collect_err
        end
    end
    for _, path in ipairs(CLEAN_PATHS) do
        local target = local_path(path)
        if fs.exists(target) then
            fs.delete(target)
        end
    end
    for _, file in ipairs(files) do
        local ok, err = write_file(file.path, file.data)
        if not ok then
            return false, err
        end
    end
    write_install_record(status.branch, status.remote_root, files, status.head_sha)
    return true, {
        mode = "full",
        files = #files,
        commit_sha = status.head_sha,
    }
end

if ... == "Kernal.services.github_updater" then
    return github_updater
end

local function print_usage()
    print("HyperCubeServer GitHub updater")
    print("")
    print("Usage:")
    print("  update_server.lua [--branch main] [--root computer/0] [--token TOKEN] [--yes] [--dry-run]")
    print("  update_server.lua --full")
    print("  update_server.lua --patch-only")
    print("")
    print("By default, GitHub installs with a saved commit SHA update by diff patch.")
    print("Use --full to force a full source refresh.")
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

local head_sha, head_sha_err = fetch_commit_sha(branch)
if head_sha then
    print("Remote commit: " .. tostring(head_sha):sub(1, 12))
else
    print("Remote commit: unknown (" .. tostring(head_sha_err) .. ")")
end

local install_record = read_install_record()
local can_try_patch = not has_flag("--full")
    and head_sha
    and install_record
    and install_record.source == "github"
    and install_record.repo == REPO_OWNER .. "/" .. REPO_NAME
    and install_record.commit_sha

if can_try_patch then
    local base_sha = tostring(install_record.commit_sha)
    if base_sha == head_sha then
        print("")
        print("Already up to date.")
        return
    end

    print("Base commit: " .. base_sha:sub(1, 12))
    local compare, compare_err = fetch_compare(base_sha, head_sha)
    local changes, patch_bytes, patch_build_err
    if compare then
        changes, patch_bytes = patch_changes_from_compare(compare, remote_root)
        if not changes then
            patch_build_err = patch_bytes
        end
    end

    if compare and changes then
        print("Mode: patch")
        print("Changed files: " .. tostring(#changes))
        print("Patch bytes: " .. tostring(patch_bytes or 0))

        if has_flag("--dry-run") then
            print("")
            print("Dry run complete. No files changed.")
            return
        end

        if not has_flag("--yes") and not has_flag("-y") then
            print("")
            print("This will apply a GitHub diff patch and preserve user data, logs, and disk DB.")
            write("Continue? [y/N] ")
            local answer = read()
            if tostring(answer or ""):lower() ~= "y" then
                print("Cancelled.")
                return
            end
        end

        print("Applying patch...")
        local ok, patch_err = apply_patch_changes(changes)
        if not ok then
            print("Patch failed: " .. tostring(patch_err))
            print("Run update_server.lua --full to replace source files from GitHub.")
            return
        end

        write_install_record(branch, remote_root, #changes, head_sha)
        print("")
        print("Patch update complete.")
        print("Run 'reboot' or restart this computer.")
        return
    end

    print("Patch unavailable: " .. tostring(compare_err or patch_build_err or "PatchBuildFailed"))
    if has_flag("--patch-only") then
        return
    end
    print("Falling back to full source refresh.")
elseif has_flag("--patch-only") then
    print("Patch unavailable: no previous GitHub commit SHA in hypercube_server_install.")
    return
elseif not has_flag("--full") then
    print("Patch unavailable: no previous GitHub commit SHA; using full source refresh.")
end

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
    local target = local_path(path)
    if fs.exists(target) then
        fs.delete(target)
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

write_install_record(branch, remote_root, files, head_sha)
print("")
print("Update complete.")
print("Run 'reboot' or restart this computer.")
