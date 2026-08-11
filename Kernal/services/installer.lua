local installer = {}
local config_ok, server_config = pcall(require, "Kernal.services.server_config")

local DEFAULT_SOURCE = "installer/hypercube_phone"
local SOURCE_PROFILES = {
    phone = {
        source = "installer/hypercube_phone",
        os = "HyperCube",
        device = "TPhone",
    },
    business_phone = {
        source = "installer/hypercube_phone",
        os = "HyperCube",
        device = "TBusinessPhone",
    },
    desktop = {
        source = "installer/hypercube_desktop",
        extends = "installer/hypercube_phone",
        os = "HyperCubeDesktop",
        device = "TDesktop",
        bootstrap = true,
    },
    business_desktop = {
        source = "installer/hypercube_desktop",
        extends = "installer/hypercube_phone",
        os = "HyperCubeDesktop",
        device = "TBusinessDesktop",
        bootstrap = true,
    },
    user_server = {
        source = "installer/user_server",
        os = "HyperCubeUserServer",
        device = "UserServer",
        bootstrap = true,
        patch_sources = {
            "installer/hypercube_phone",
        },
    },
}
local INSTALL_PATHS = {
    "apps",
    "user_services",
    "init.lua",
    "startup.lua",
    "checklist.md",
}
local BASE_ROM_PATHS = {
    "Kernal",
}
local PATCH_ROOT = "patches"
local ROM_FILE = "hypercube.rom"
local ROM_KEY = "Tesserac:HyperCube:BankOfBash:ROM:v1"
local ROM_HEADER = "HCBR1"
local SOFTWARE_VERSION = "0.3.5"
local GITHUB_DEFAULTS = {
    owner = "reeet24",
    repo = "HyperCubeServerOS",
    branch = "main",
    root = "computer/0",
    cache_ttl_ms = 600000,
    hash_check_ms = 60000,
}
local github_cache = nil

local function checksum(text)
    text = tostring(text or "")
    local a = 1
    local b = 0
    for i = 1, #text do
        a = (a + text:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return tostring((b * 65536 + a) % 2147483647)
end

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function combine(a, b)
    if fs and fs.combine then
        return fs.combine(a, b)
    end
    if a:sub(-1) == "/" then
        return a .. b
    end
    return a .. "/" .. b
end

local function normalize_path(path)
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("^%./", ""):gsub("^/+", "")
    path = path:gsub("//+", "/")
    if path == "." then
        return ""
    end
    return path
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
    local data = trim(handle.readAll())
    handle.close()
    if data == "" then
        return nil
    end
    return data
end

local function encode_segment(segment)
    segment = tostring(segment or "")
    return segment:gsub("([^%w%-%_%.%~])", function(char)
        return string.format("%%%02X", char:byte())
    end)
end

local function encode_path(path)
    path = normalize_path(path)
    if path == "" then
        return ""
    end
    local out = {}
    for segment in path:gmatch("[^/]+") do
        out[#out + 1] = encode_segment(segment)
    end
    return table.concat(out, "/")
end

local function github_http_get(url, accept)
    if not http or not http.get then
        return nil, "HttpUnavailable"
    end
    local headers = {
        ["User-Agent"] = "HyperCubeServerOS-Installer",
        ["Accept"] = accept or "application/vnd.github+json",
    }
    local token = read_file_trim("github_token")
    if token then
        headers.Authorization = "Bearer " .. token
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
        return nil, "Http" .. tostring(code) .. ":" .. tostring(body):sub(1, 100)
    end
    return body
end

local function decode_json(text)
    if not textutils or not textutils.unserializeJSON then
        return nil, "JsonUnavailable"
    end
    local ok, decoded = pcall(textutils.unserializeJSON, text)
    if not ok or decoded == nil then
        return nil, ok and "JsonDecodeFailed" or decoded
    end
    return decoded
end

local function installer_config()
    if config_ok and server_config and server_config.load then
        local ok, config = pcall(server_config.load)
        if ok and type(config) == "table" then
            return config.installer or {}
        end
    end
    return {}
end

local function github_config()
    local cfg = installer_config()
    local github = cfg.github or {}
    return {
        source_mode = tostring(cfg.source_mode or "auto"),
        owner = tostring(github.owner or GITHUB_DEFAULTS.owner),
        repo = tostring(github.repo or GITHUB_DEFAULTS.repo),
        branch = tostring(github.branch or GITHUB_DEFAULTS.branch),
        root = normalize_path(github.root or GITHUB_DEFAULTS.root),
        cache_ttl_ms = tonumber(github.cache_ttl_ms) or GITHUB_DEFAULTS.cache_ttl_ms,
        hash_check_ms = tonumber(github.hash_check_ms) or GITHUB_DEFAULTS.hash_check_ms,
    }
end

local function repo_key(config)
    return table.concat({
        config.owner,
        config.repo,
        config.branch,
        config.root,
    }, ":")
end

local function github_api_base(config)
    return "https://api.github.com/repos/" .. encode_segment(config.owner) .. "/" .. encode_segment(config.repo)
end

local function root_candidates(config)
    local candidates = {}
    local seen = {}
    local function add(root)
        root = normalize_path(root)
        if not seen[root] then
            seen[root] = true
            candidates[#candidates + 1] = root
        end
    end
    add(config.root)
    add("computer/0")
    add("0")
    add("")
    return candidates
end

local function github_raw_url(config, repo_path)
    local full = config.root ~= "" and combine(config.root, repo_path) or repo_path
    return "https://raw.githubusercontent.com/" .. encode_segment(config.owner) .. "/" .. encode_segment(config.repo)
        .. "/" .. encode_segment(config.branch) .. "/" .. encode_path(full)
end

local function fetch_installer_tree_hash(config)
    local branches = { config.branch }
    if config.branch == "main" then
        branches[#branches + 1] = "master"
    end
    local last_err = nil
    for _, branch in ipairs(branches) do
        for _, root in ipairs(root_candidates(config)) do
            local full = root ~= "" and combine(root, "installer") or "installer"
            local url = github_api_base(config) .. "/contents/" .. encode_path(full) .. "?ref=" .. encode_segment(branch)
            local body, err = github_http_get(url)
            if body then
                local decoded, json_err = decode_json(body)
                if not decoded then
                    last_err = json_err
                elseif type(decoded) == "table" and decoded.sha then
                    config.branch = branch
                    config.root = root
                    return decoded.sha
                else
                    last_err = "InstallerTreeHashMissing:" .. full
                end
            else
                last_err = tostring(err) .. ":" .. full
            end
        end
    end
    return nil, last_err or "InstallerTreeHashMissing"
end

local function fetch_recursive_tree(config)
    local url = github_api_base(config) .. "/git/trees/" .. encode_segment(config.branch) .. "?recursive=1"
    local body, err = github_http_get(url)
    if not body and config.branch == "main" then
        url = github_api_base(config) .. "/git/trees/master?recursive=1"
        body, err = github_http_get(url)
        if body then
            config.branch = "master"
        end
    end
    if not body then
        return nil, err
    end
    local decoded, json_err = decode_json(body)
    if not decoded then
        return nil, json_err
    end
    if type(decoded.tree) ~= "table" then
        return nil, decoded.message or "GitTreeMissing"
    end
    return decoded
end

local function should_use_github(config, source)
    if config.source_mode == "local" then
        return false
    end
    if normalize_path(source):sub(1, 10) ~= "installer/" then
        return false
    end
    if config.source_mode == "github" then
        return true
    end
    if config_ok and server_config and server_config.local_paths then
        local ok, loaded = pcall(server_config.load)
        if ok and type(loaded) == "table" then
            for _, candidate in ipairs(server_config.local_paths(loaded, source)) do
                if fs.exists(candidate) then
                    return false
                end
            end
            return true
        end
    end
    return not fs.exists(source)
end

local function expire_github_cache(config)
    if github_cache and now() - tonumber(github_cache.last_used or 0) > config.cache_ttl_ms then
        github_cache = nil
    end
end

local function ensure_github_cache(source)
    local config = github_config()
    expire_github_cache(config)
    if not should_use_github(config, source) then
        return true, nil, false
    end
    local key = repo_key(config)
    local current_hash
    if github_cache and github_cache.key == key then
        if now() - tonumber(github_cache.checked_at or 0) < config.hash_check_ms then
            github_cache.last_used = now()
            return true, github_cache, true
        end
        current_hash = fetch_installer_tree_hash(config)
        if current_hash and current_hash == github_cache.tree_hash then
            github_cache.checked_at = now()
            github_cache.last_used = now()
            return true, github_cache, true
        end
    end

    local hash_err
    if not current_hash then
        current_hash, hash_err = fetch_installer_tree_hash(config)
        key = repo_key(config)
    end
    if not current_hash then
        return false, "GitHubInstallerHashUnavailable:" .. tostring(hash_err), true
    end
    local tree, tree_err = fetch_recursive_tree(config)
    if not tree then
        return false, tree_err, true
    end
    local files = {}
    local root_prefix = config.root ~= "" and (config.root .. "/installer/") or "installer/"
    for _, entry in ipairs(tree.tree or {}) do
        local path = normalize_path(entry.path)
        if entry.type == "blob" and path:sub(1, #root_prefix) == root_prefix then
            local repo_path = "installer/" .. path:sub(#root_prefix + 1)
            local data, data_err = github_http_get(github_raw_url(config, repo_path), "application/octet-stream")
            if not data then
                return false, "GitHubInstallerFileFailed:" .. repo_path .. ":" .. tostring(data_err), true
            end
            files[repo_path] = data
        end
    end
    github_cache = {
        key = key,
        owner = config.owner,
        repo = config.repo,
        branch = config.branch,
        root = config.root,
        tree_hash = current_hash,
        files = files,
        checked_at = now(),
        last_used = now(),
        loaded_at = now(),
    }
    return true, github_cache, true
end

local function github_file(path)
    path = normalize_path(path)
    if github_cache and github_cache.files then
        return github_cache.files[path]
    end
    return nil
end

local function github_exists(path)
    path = normalize_path(path)
    if not github_cache or not github_cache.files then
        return false
    end
    if github_cache.files[path] ~= nil then
        return true
    end
    local prefix = path == "" and "" or (path .. "/")
    for file_path in pairs(github_cache.files) do
        if file_path:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

local function github_list(path)
    path = normalize_path(path)
    if not github_cache or not github_cache.files then
        return {}
    end
    local prefix = path == "" and "" or (path .. "/")
    local seen = {}
    local out = {}
    for file_path in pairs(github_cache.files) do
        if file_path:sub(1, #prefix) == prefix then
            local rest = file_path:sub(#prefix + 1)
            local child = rest:match("^([^/]+)")
            if child and not seen[child] then
                seen[child] = true
                out[#out + 1] = child
            end
        end
    end
    table.sort(out)
    return out
end

local function source_under_root(root, source)
    root = tostring(root or ""):gsub("\\", "/"):gsub("/+$", "")
    source = tostring(source or DEFAULT_SOURCE):gsub("\\", "/")
    local suffix = source:match("^installer/(.+)$")
    if root == "" or root == "installer" or not suffix then
        return source
    end
    return combine(root, suffix)
end

local function find_drive_mounts()
    local mounts = {}
    if peripheral and peripheral.getNames and peripheral.getType and peripheral.wrap then
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "drive" then
                local drive = peripheral.wrap(name)
                if drive and drive.isDiskPresent and drive.isDiskPresent() and drive.getMountPath then
                    local mount = drive.getMountPath()
                    if mount then
                        mounts[#mounts + 1] = {
                            name = name,
                            mount = mount,
                            id = drive.getDiskID and drive.getDiskID() or nil,
                            label = drive.getDiskLabel and drive.getDiskLabel() or nil,
                        }
                    end
                end
            end
        end
    end
    table.sort(mounts, function(a, b)
        return tostring(a.name) < tostring(b.name)
    end)
    return mounts
end

local function copy_tree(source, target)
    if fs.isDir(source) then
        if not fs.exists(target) then
            fs.makeDir(target)
        end
        for _, child in ipairs(fs.list(source)) do
            copy_tree(combine(source, child), combine(target, child))
        end
    else
        fs.copy(source, target)
    end
end

local function read_all(path)
    local remote = github_file(path)
    if remote ~= nil then
        return remote
    end
    if config_ok and server_config and server_config.local_path then
        local ok, config = pcall(server_config.load)
        if ok and type(config) == "table" then
            path = server_config.local_path(config, path)
        end
    end
    local handle = fs.open(path, "rb")
    if not handle then
        return nil, "OpenFailed"
    end
    local data = handle.readAll()
    handle.close()
    return data
end

local function local_paths_for(path)
    if config_ok and server_config and server_config.local_path then
        local ok, config = pcall(server_config.load)
        if ok and type(config) == "table" then
            if server_config.local_paths then
                return server_config.local_paths(config, path)
            end
            return { server_config.local_path(config, path) }
        end
    end
    return { path }
end

local function exists_any(path)
    if github_exists(path) then
        return true
    end
    for _, candidate in ipairs(local_paths_for(path)) do
        if fs.exists(candidate) then
            return true
        end
    end
    return false
end

local function write_all(path, data, binary)
    local handle = fs.open(path, binary and "wb" or "w")
    if not handle then
        return false, "OpenFailed"
    end
    handle.write(data)
    handle.close()
    return true
end

local function xor_crypt(data, key)
    if not bit32 then
        return nil, "Bit32Unavailable"
    end
    data = tostring(data or "")
    key = tostring(key or "")
    if key == "" then
        return nil, "KeyRequired"
    end
    local out = {}
    for i = 1, #data do
        local key_byte = key:byte(((i - 1) % #key) + 1)
        out[i] = string.char(bit32.bxor(data:byte(i), key_byte))
    end
    return table.concat(out)
end

local function collect_tree(root, relative, out)
    local path = relative == "" and root or combine(root, relative)
    local remote_children = github_list(path)
    if #remote_children > 0 then
        for _, child in ipairs(remote_children) do
            collect_tree(root, relative == "" and child or combine(relative, child), out)
        end
        return true
    end
    local local_full = path
    local local_paths = { path }
    if config_ok and server_config and server_config.local_path then
        local ok, config = pcall(server_config.load)
        if ok and type(config) == "table" then
            local_full = server_config.local_path(config, path)
            if server_config.local_paths then
                local_paths = server_config.local_paths(config, path)
            else
                local_paths = { local_full }
            end
        end
    end
    local child_seen = {}
    for _, candidate in ipairs(local_paths) do
        if fs.exists(candidate) and fs.isDir(candidate) then
            for _, child in ipairs(fs.list(candidate)) do
                if not child_seen[child] then
                    child_seen[child] = true
                    collect_tree(root, relative == "" and child or combine(relative, child), out)
                end
            end
        end
    end
    if next(child_seen) then
        return true
    end
    if fs.exists(local_full) and fs.isDir(local_full) then
        for _, child in ipairs(fs.list(local_full)) do
            collect_tree(root, relative == "" and child or combine(relative, child), out)
        end
        return true
    end

    local data, err = read_all(path)
    if not data then
        return false, err
    end
    out.by_path = out.by_path or {}
    out.by_path[relative] = {
        path = relative,
        data = data,
    }
    return true
end

local profile_for_source

local function split_lines(text)
    text = tostring(text or "")
    local lines = {}
    local index = 1
    while index <= #text do
        local next_newline = text:find("\n", index, true)
        if next_newline then
            lines[#lines + 1] = text:sub(index, next_newline - 1)
            index = next_newline + 1
        else
            lines[#lines + 1] = text:sub(index)
            break
        end
    end
    if #text > 0 and text:sub(-1) == "\n" then
        lines[#lines + 1] = ""
    end
    return lines
end

local function join_lines(lines)
    return table.concat(lines or {}, "\n")
end

local function normalize_patch_path(path)
    path = tostring(path or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("^%./", ""):gsub("//+", "/")
    if path == "" or path:find("..", 1, true) then
        return nil, "InvalidPatchPath"
    end
    return path
end

local function apply_line_patch(base_data, patch)
    local lines = split_lines(base_data or "")
    local hunks = {}
    for _, hunk in ipairs(patch.hunks or {}) do
        hunks[#hunks + 1] = hunk
    end
    if type(patch.rml) == "string" then
        for start, count in patch.rml:gmatch("%-L(%d+)%s+(%d+)") do
            hunks[#hunks + 1] = {
                start = tonumber(start),
                remove = tonumber(count),
            }
        end
    elseif type(patch.rml) == "table" then
        for _, item in ipairs(patch.rml) do
            if type(item) == "table" then
                hunks[#hunks + 1] = {
                    start = tonumber(item[1] or item.start),
                    remove = tonumber(item[2] or item.count or item.remove),
                }
            end
        end
    end
    table.sort(hunks, function(a, b)
        return tonumber(a.start or 1) > tonumber(b.start or 1)
    end)
    for _, hunk in ipairs(hunks) do
        local start = math.max(1, math.floor(tonumber(hunk.start or 1) or 1))
        local remove = math.max(0, math.floor(tonumber(hunk.remove or hunk.delete or 0) or 0))
        for _ = 1, remove do
            if start <= #lines then
                table.remove(lines, start)
            end
        end
        local insert = hunk.lines or hunk.insert or {}
        for index = #insert, 1, -1 do
            table.insert(lines, start, tostring(insert[index] or ""))
        end
    end
    return join_lines(lines)
end

local function apply_compose_patch(base_data, patch)
    local source_lines = split_lines(base_data or "")
    local out = {}
    for _, chunk in ipairs(patch.chunks or {}) do
        local copy = chunk.copy or chunk.source
        if type(copy) == "table" then
            local start = math.max(1, math.floor(tonumber(copy[1] or copy.start or 1) or 1))
            local count = math.max(0, math.floor(tonumber(copy[2] or copy.count or 0) or 0))
            for index = start, start + count - 1 do
                out[#out + 1] = source_lines[index] or ""
            end
        end
        for _, line in ipairs(chunk.lines or chunk.insert or {}) do
            out[#out + 1] = tostring(line or "")
        end
    end
    return join_lines(out)
end

local function apply_patch_record(collected, patch)
    if type(patch) ~= "table" then
        return false, "InvalidPatch"
    end
    if patch.format and patch.format ~= "HyperCubeInstallPatch" then
        return false, "UnsupportedPatchFormat"
    end
    local path, path_err = normalize_patch_path(patch.path or patch.target)
    if not path then
        return false, path_err
    end
    collected.by_path = collected.by_path or {}
    if patch.delete == true or patch.mode == "delete" then
        collected.by_path[path] = nil
        return true
    end
    local existing = collected.by_path[path]
    if not existing and patch.require_existing ~= false then
        return false, "PatchBaseMissing:" .. path
    end
    local mode = tostring(patch.mode or "line")
    local data
    if mode == "replace" then
        data = tostring(patch.data or "")
    elseif mode == "append" then
        data = tostring(existing and existing.data or "") .. tostring(patch.data or "")
    elseif mode == "compose" then
        data = apply_compose_patch(existing and existing.data or "", patch)
    else
        data = apply_line_patch(existing and existing.data or "", patch)
    end
    collected.by_path[path] = {
        path = path,
        data = data,
    }
    return true
end

local function collect_patch_records(root, relative, out)
    local path = relative == "" and root or combine(root, relative)
    local remote_children = github_list(path)
    if #remote_children > 0 then
        for _, child in ipairs(remote_children) do
            local ok, err = collect_patch_records(root, relative == "" and child or combine(relative, child), out)
            if not ok then
                return false, err
            end
        end
        return true
    end
    local local_paths = local_paths_for(path)
    local child_seen = {}
    for _, candidate in ipairs(local_paths) do
        if fs.exists(candidate) and fs.isDir(candidate) then
            for _, child in ipairs(fs.list(candidate)) do
                if not child_seen[child] then
                    child_seen[child] = true
                    local ok, err = collect_patch_records(root, relative == "" and child or combine(relative, child), out)
                    if not ok then
                        return false, err
                    end
                end
            end
        end
    end
    if next(child_seen) then
        return true
    end
    local data, err = read_all(path)
    if not data then
        return false, err
    end
    local patch = textutils.unserialize(data)
    if type(patch) ~= "table" then
        return false, "PatchDecodeFailed:" .. tostring(relative)
    end
    out[#out + 1] = {
        path = relative,
        patch = patch,
    }
    return true
end

local function apply_source_patches(source, collected)
    local patch_root = combine(source, PATCH_ROOT)
    if not exists_any(patch_root) then
        return true
    end
    local records = {}
    local ok, err = collect_patch_records(patch_root, "", records)
    if not ok then
        return false, err
    end
    table.sort(records, function(a, b)
        return tostring(a.path) < tostring(b.path)
    end)
    for _, record in ipairs(records) do
        ok, err = apply_patch_record(collected, record.patch)
        if not ok then
            return false, err
        end
    end
    return true
end

local function collect_source_image(source, collected)
    local distro_kernel = combine(source, "Kernal")
    if exists_any(distro_kernel) then
        local ok, err = collect_tree(source, "Kernal", collected)
        if not ok then
            return false, err
        end
    end
    for _, path in ipairs(INSTALL_PATHS) do
        local full = combine(source, path)
        if exists_any(full) then
            local ok, err = collect_tree(source, path, collected)
            if not ok then
                return false, err
            end
        end
    end
    return apply_source_patches(source, collected)
end

local function collect_inherited_paths(profile, collected)
    for _, inherited in ipairs((profile and profile.inherits) or {}) do
        local source = inherited.source
        local path = inherited.path
        if source and path then
            local full = combine(source, path)
            if exists_any(full) then
                local ok, err = collect_tree(source, path, collected)
                if not ok then
                    return false, err
                end
            end
        end
    end
    return true
end

local function apply_patch_sources(profile, collected)
    for _, source in ipairs((profile and profile.patch_sources) or {}) do
        local ok, err = apply_source_patches(source, collected)
        if not ok then
            return false, err
        end
    end
    return true
end

local function collect_image(source, profile)
    local cache_ok, cache_err = ensure_github_cache(source)
    if not cache_ok then
        return nil, cache_err
    end
    local collected = {
        by_path = {},
    }
    for _, path in ipairs(BASE_ROM_PATHS) do
        if fs.exists(path) then
            local ok, err = collect_tree("", path, collected)
            if not ok then
                return nil, err
            end
        end
    end

    profile = profile or profile_for_source(source)
    if profile and profile.extends then
        local ok, err = collect_source_image(profile.extends, collected)
        if not ok then
            return nil, err
        end
    end

    local inherit_ok, inherit_err = collect_inherited_paths(profile, collected)
    if not inherit_ok then
        return nil, inherit_err
    end

    local patch_source_ok, patch_source_err = apply_patch_sources(profile, collected)
    if not patch_source_ok then
        return nil, patch_source_err
    end

    local ok, err = collect_source_image(source, collected)
    if not ok then
        return nil, err
    end
    local files = {}
    for _, file in pairs(collected.by_path) do
        files[#files + 1] = file
    end
    table.sort(files, function(a, b)
        return a.path < b.path
    end)
    return files
end

function profile_for_source(source)
    if source == DEFAULT_SOURCE then
        return SOURCE_PROFILES.phone
    end
    for _, profile in pairs(SOURCE_PROFILES) do
        if profile.source == source then
            return profile
        end
    end
    return {
        source = source,
        os = "HyperCube",
        device = "TPhone",
    }
end

local function profile_for_device(device)
    device = tostring(device or "")
    for _, profile in pairs(SOURCE_PROFILES) do
        if profile.device == device then
            return profile
        end
    end
    return nil
end

local function build_rom_blob(source, profile)
    local files, err = collect_image(source, profile)
    if not files then
        return nil, err
    end
    profile = profile or profile_for_source(source)
    local payload = textutils.serialize({
        format = "HyperCubeROM",
        version = 1,
        software_version = SOFTWARE_VERSION,
        os = profile.os,
        device = profile.device,
        built_at = 0,
        files = files,
    })
    local encoded, crypt_err = xor_crypt(payload, ROM_KEY)
    if not encoded then
        return nil, crypt_err
    end
    return ROM_HEADER .. encoded, #files
end

local function loader_source(profile)
    profile = profile or profile_for_source(DEFAULT_SOURCE)
    return [[
local ROM_FILE = "hypercube.rom"
local ROM_KEY = "]] .. ROM_KEY .. [["
local ROM_HEADER = "]] .. ROM_HEADER .. [["
local INSTALL_INFO = {
    os = "]] .. tostring(profile.os or "HyperCube") .. [[",
    device = "]] .. tostring(profile.device or "TPhone") .. [[",
}

local function read_all(path)
    local handle = fs.open(path, "rb")
    if not handle then
        return nil, "OpenFailed"
    end
    local data = handle.readAll()
    handle.close()
    return data
end

local function write_all(path, data, binary)
    local handle = fs.open(path, binary and "wb" or "w")
    if not handle then
        return false, "OpenFailed"
    end
    handle.write(data or "")
    handle.close()
    return true
end

local function combine(a, b)
    if fs.combine then
        return fs.combine(a, b)
    end
    if a == "" then
        return b
    end
    if a:sub(-1) == "/" then
        return a .. b
    end
    return a .. "/" .. b
end

local function xor_crypt(data, key)
    if not bit32 then
        return nil, "Bit32Unavailable"
    end
    local out = {}
    for i = 1, #data do
        local key_byte = key:byte(((i - 1) % #key) + 1)
        out[i] = string.char(bit32.bxor(data:byte(i), key_byte))
    end
    return table.concat(out)
end

local function normalize_path(path)
    path = tostring(path or ""):gsub("\\", "/"):gsub("^/+", "")
    return path
end

local function module_path(name)
    return tostring(name or ""):gsub("%.", "/") .. ".lua"
end

local function load_chunk(source, path, env)
    env = env or _G
    if load then
        local ok, loader_or_err = pcall(load, source, "@" .. tostring(path), "t", env)
        if ok and loader_or_err then
            if setfenv then
                setfenv(loader_or_err, env)
            end
            return loader_or_err
        end
        if ok and type(loader_or_err) == "string" then
            return nil, loader_or_err
        end
    end
    if loadstring then
        local loader, err = loadstring(source, "@" .. tostring(path))
        if not loader then
            return nil, err
        end
        if setfenv then
            setfenv(loader, env)
        end
        return loader
    end
    return nil, "NoLoader"
end

local function decode_rom()
    local raw, read_err = read_all(ROM_FILE)
    if not raw then
        error("HyperCube ROM missing: " .. tostring(read_err))
    end
    if raw:sub(1, #ROM_HEADER) ~= ROM_HEADER then
        error("Invalid HyperCube ROM header")
    end
    local decoded, decode_err = xor_crypt(raw:sub(#ROM_HEADER + 1), ROM_KEY)
    if not decoded then
        error("HyperCube ROM decode failed: " .. tostring(decode_err))
    end
    local payload = textutils.unserialize(decoded)
    if type(payload) ~= "table" or payload.format ~= "HyperCubeROM" or type(payload.files) ~= "table" then
        error("Invalid HyperCube ROM payload")
    end

    local files = {}
    for _, file in ipairs(payload.files) do
        files[normalize_path(file.path)] = file.data or ""
    end
    payload.files_by_path = files
    return payload
end

local function install_memory_rom(payload)
    local files = payload.files_by_path or {}
    local rom = {
        payload = payload,
        files = files,
    }

    function rom.exists(path)
        return files[normalize_path(path)] ~= nil
    end

    function rom.read(path)
        return files[normalize_path(path)]
    end

    function rom.load(path, env)
        path = normalize_path(path)
        local source = files[path]
        if not source then
            return nil, "NotFound"
        end
        return load_chunk(source, path, env or _G)
    end

    function rom.list_apps()
        local seen = {}
        local apps = {}
        for path in pairs(files) do
            local id = path:match("^apps/([^/]+)/app%.lua$")
            if id and not seen[id] then
                seen[id] = true
                apps[#apps + 1] = {
                    id = id,
                    path = "apps/" .. id .. "/app.lua",
                }
            end
        end
        table.sort(apps, function(a, b)
            return a.id < b.id
        end)
        return apps
    end

    _G.HC_ROM = rom

    local original_require = require
    package = package or {}
    package.loaded = package.loaded or {}
    package.preload = package.preload or {}
    _G.package = package

    function rom.require(name)
        name = tostring(name or "")
        if package.loaded[name] ~= nil then
            return package.loaded[name]
        end

        local preload = package.preload[name]
        if preload then
            package.loaded[name] = true
            local result = preload(name)
            if result ~= nil then
                package.loaded[name] = result
            end
            return package.loaded[name]
        end

        local path = module_path(name)
        local source = files[path]
        if source then
            local loader, err = load_chunk(source, path, _G)
            if not loader then
                error("module load failed: " .. name .. ": " .. tostring(err), 2)
            end
            package.loaded[name] = true
            local result = loader(name)
            if result ~= nil then
                package.loaded[name] = result
            end
            return package.loaded[name]
        end

        if original_require then
            return original_require(name)
        end

        error("module not found: " .. name, 2)
    end

    _G.require = rom.require

    if package and package.preload then
        for path in pairs(files) do
            if path:match("%.lua$") then
                local module = path:gsub("%.lua$", ""):gsub("/", ".")
                local rom_path = path
                package.preload[module] = function()
                    local loader, err = rom.load(rom_path, _G)
                    if not loader then
                        error(err)
                    end
                    return loader()
                end
            end
        end
    end

    local original_loadfile = loadfile
    _G.loadfile = function(path, mode_or_env, maybe_env)
        local env = maybe_env or (type(mode_or_env) == "table" and mode_or_env or _G)
        local loader, err = rom.load(path, env)
        if loader then
            return loader
        end
        if original_loadfile then
            return original_loadfile(path, mode_or_env, maybe_env)
        end
        return nil, err
    end

    return rom
end

local ok, err = pcall(function()
    local payload = decode_rom()
    INSTALL_INFO.os = payload.os or INSTALL_INFO.os
    INSTALL_INFO.device = payload.device or INSTALL_INFO.device
    write_all("hypercube_install", textutils.serialize(INSTALL_INFO), false)
    local rom = install_memory_rom(payload)
    local init_loader, init_err = rom.load("init.lua", _G)
    if not init_loader then
        error("HyperCube init missing from ROM: " .. tostring(init_err))
    end
    local system = init_loader()
    local boot_ok, boot_err = pcall(function()
        if system and system.boot then
            return system.boot()
        end
        return true
    end)
    if not boot_ok then
        error("HyperCube boot failed: " .. tostring(boot_err))
    end
    local identity_ok = true
    local identity_err = nil
    if system and system.ensure_identity then
        identity_ok, identity_err = system.ensure_identity()
    end
    if identity_ok then
        if system and system.start_gui then
            system.start_gui()
        end
    else
        print("Identity required: " .. tostring(identity_err))
    end
end)

if not ok then
    print("HyperCube ROM loader failed: " .. tostring(err))
end
]]
end

local function network_bootstrap_shim_source(profile)
    profile = profile or SOURCE_PROFILES.user_server
    local device = tostring(profile.device or "UserServer")
    local os_name = tostring(profile.os or "HyperCube")
    local title = tostring(profile.title or os_name .. " installer")
    return [[
local PROTOCOL = "tesserac"
local DEVICE = "]] .. device .. [["
local OS_NAME = "]] .. os_name .. [["
local INSTALLER_TITLE = "]] .. title .. [["
local SERVER_HOSTS = {
    "HyperCubeServer",
    "TesseracServer",
    "tesserac-server",
}

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function checksum(text)
    text = tostring(text or "")
    local a = 1
    local b = 0
    for i = 1, #text do
        a = (a + text:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return tostring((b * 65536 + a) % 2147483647)
end

local function find_modem_side()
    local fallback = nil
    if peripheral and peripheral.getNames and peripheral.getType then
        for _, side in ipairs(peripheral.getNames()) do
            if peripheral.getType(side) == "modem" then
                local modem = peripheral.wrap and peripheral.wrap(side) or nil
                if modem and modem.isWireless and modem.isWireless() then
                    return side
                end
                fallback = fallback or side
            end
        end
    end
    for _, side in ipairs({ "back", "top", "bottom", "left", "right", "front" }) do
        if peripheral and peripheral.getType and peripheral.getType(side) == "modem" then
            local modem = peripheral.wrap and peripheral.wrap(side) or nil
            if modem and modem.isWireless and modem.isWireless() then
                return side
            end
            fallback = fallback or side
        end
    end
    return fallback
end

local function open_rednet()
    if not rednet then
        return false, "RednetUnavailable"
    end
    local side = find_modem_side()
    if not side then
        return false, "ModemNotFound"
    end
    if not rednet.isOpen(side) then
        rednet.open(side)
    end
    return true, side
end

local function accept_announce(sender, message)
    if sender and type(message) == "table" and message.type == "server.announce" then
        return sender
    end
    return nil
end

local function discover_server()
    local ok, err = open_rednet()
    if not ok then
        return nil, err
    end
    local deadline = os.clock() + 0.25
    while os.clock() < deadline do
        local sender, message = rednet.receive(PROTOCOL, math.max(0.05, deadline - os.clock()))
        local id = accept_announce(sender, message)
        if id then
            return id
        end
    end
    for _, hostname in ipairs(SERVER_HOSTS) do
        if rednet.lookup then
            local id = rednet.lookup(PROTOCOL, hostname)
            if id then
                return id
            end
        end
    end
    rednet.broadcast({
        type = "server.lookup",
        hosts = SERVER_HOSTS,
        requester = os.getComputerID and os.getComputerID() or nil,
        time = now(),
    }, PROTOCOL)
    deadline = os.clock() + 5
    while os.clock() < deadline do
        local sender, message = rednet.receive(PROTOCOL, math.max(0.05, deadline - os.clock()))
        local id = accept_announce(sender, message)
        if id then
            return id
        end
    end
    return nil, "ServerNotFound"
end

local function request(server_id, message, expected_type, timeout)
    rednet.send(server_id, message, PROTOCOL)
    local deadline = os.clock() + (timeout or 8)
    while os.clock() < deadline do
        local sender, reply = rednet.receive(PROTOCOL, math.max(0.05, deadline - os.clock()))
        if sender == server_id and type(reply) == "table" and reply.type == expected_type then
            if reply.ok == false then
                return nil, reply.error or "RequestFailed"
            end
            return reply.result or reply
        end
    end
    return nil, "Timeout"
end

local function write_all(path, data, binary)
    local handle = fs.open(path, binary and "wb" or "w")
    if not handle then
        return false, "OpenFailed:" .. tostring(path)
    end
    handle.write(data or "")
    handle.close()
    return true
end

local function remove_if_exists(path)
    if fs.exists(path) then
        fs.delete(path)
    end
end

local function install_package(package, rom_data)
    if tostring(checksum(rom_data)) ~= tostring(package.rom_checksum or "") then
        return false, "ChecksumMismatch"
    end
    remove_if_exists("hypercube.rom")
    remove_if_exists("hypercube_install")
    remove_if_exists("startup.lua")
    local ok, err = write_all("hypercube.rom", rom_data, true)
    if not ok then
        return false, err
    end
    ok, err = write_all("startup.lua", package.startup or "", false)
    if not ok then
        return false, err
    end
    ok, err = write_all("hypercube_install", textutils.serialize({
        os = package.os or "HyperCubeUserServer",
        device = package.device or DEVICE,
        installed_at = now(),
        source = "hypernet",
        mode = "network",
        rom = "hypercube.rom",
        version = package.version,
        packed_files = package.packed_files,
        rom_checksum = package.rom_checksum,
        installer = "network_bootstrap_shim",
    }), false)
    if not ok then
        return false, err
    end
    return true
end

term.clear()
term.setCursorPos(1, 1)
print(INSTALLER_TITLE)
print("")

local server_id, discover_err = discover_server()
if not server_id then
    print("Server not found: " .. tostring(discover_err))
    return
end
print("Connected to server " .. tostring(server_id))
print("Requesting package...")

local package, download_err = request(server_id, {
    type = "update.download",
    os = OS_NAME,
    device = DEVICE,
    version = "",
}, "update.download.result", 12)
if not package then
    print("Download failed: " .. tostring(download_err))
    return
end

local chunks = tonumber(package.chunks) or 0
if chunks <= 0 then
    print("Download failed: PackageEmpty")
    return
end

local parts = {}
for index = 1, chunks do
    print("Chunk " .. tostring(index) .. "/" .. tostring(chunks))
    local chunk, chunk_err = request(server_id, {
        type = "update.chunk",
        os = OS_NAME,
        device = DEVICE,
        index = index,
    }, "update.chunk.result", 12)
    if not chunk or type(chunk.data) ~= "string" then
        print("Chunk failed: " .. tostring(chunk_err or "MissingData"))
        return
    end
    parts[index] = chunk.data
end

print("Installing to computer...")
local ok, err = install_package(package, table.concat(parts))
if not ok then
    print("Install failed: " .. tostring(err))
    return
end

print("")
print("Install complete.")
print("Remove this disk and reboot the computer.")
]]
end

local function user_server_shim_source()
    return network_bootstrap_shim_source(SOURCE_PROFILES.user_server)
end

local function clean_target(mount)
    for _, path in ipairs(INSTALL_PATHS) do
        local target = combine(mount, path)
        if fs.exists(target) then
            fs.delete(target)
        end
    end
    for _, path in ipairs({ ROM_FILE, "hypercube_install" }) do
        local target = combine(mount, path)
        if fs.exists(target) then
            fs.delete(target)
        end
    end
end

function installer.new(options)
    local self = {
        source = options and options.source or DEFAULT_SOURCE,
        source_root = options and options.source_root or nil,
        profile_key = options and options.profile or nil,
        selected_index = 1,
        last_result = nil,
        last_scan = nil,
    }
    if SOURCE_PROFILES[self.source] then
        self.profile_key = self.source
        self.source = SOURCE_PROFILES[self.profile_key].source
    elseif self.source == DEFAULT_SOURCE and not self.profile_key then
        self.profile_key = "phone"
    end

    function self:set_source(source)
        if SOURCE_PROFILES[source] then
            self.profile_key = source
            source = SOURCE_PROFILES[source].source
        elseif source == DEFAULT_SOURCE then
            self.profile_key = "phone"
        else
            self.profile_key = nil
        end
        self.source = source or DEFAULT_SOURCE
        self.last_result = nil
        return true, self.source
    end

    function self:source_profile()
        if self.profile_key and SOURCE_PROFILES[self.profile_key] then
            return SOURCE_PROFILES[self.profile_key]
        end
        return profile_for_source(self.source)
    end

    function self:profile_source(profile)
        profile = profile or self:source_profile()
        if config_ok and server_config and server_config.load then
            local ok, config = pcall(server_config.load)
            if ok and type(config) == "table"
                and config.installer
                and type(config.installer.roots) == "table"
                and #config.installer.roots > 1 then
                return profile.source or self.source
            end
        end
        return source_under_root(self.source_root, profile.source or self.source)
    end

    function self:drives()
        local drives = find_drive_mounts()
        self.last_scan = now()
        if self.selected_index > #drives then
            self.selected_index = math.max(1, #drives)
        end
        return drives
    end

    function self:selected_drive()
        local drives = self:drives()
        return drives[self.selected_index], drives
    end

    function self:select_next()
        local drives = self:drives()
        if #drives == 0 then
            self.selected_index = 1
            return nil, "NoDiskDrives"
        end
        self.selected_index = (self.selected_index % #drives) + 1
        return drives[self.selected_index]
    end

    function self:github_cache_status()
        local config = github_config()
        expire_github_cache(config)
        return {
            source_mode = config.source_mode,
            owner = config.owner,
            repo = config.repo,
            branch = config.branch,
            root = config.root,
            cached = github_cache ~= nil,
            cached_files = github_cache and github_cache.files and (function()
                local count = 0
                for _ in pairs(github_cache.files) do
                    count = count + 1
                end
                return count
            end)() or 0,
            tree_hash = github_cache and github_cache.tree_hash or nil,
            loaded_at = github_cache and github_cache.loaded_at or nil,
            last_used = github_cache and github_cache.last_used or nil,
        }
    end

    function self:prune_github_cache()
        local before = github_cache ~= nil
        expire_github_cache(github_config())
        return before and github_cache == nil
    end

    function self:build_rom(target_mount)
        local profile = self:source_profile()
        if profile.bootstrap == true then
            local shim = network_bootstrap_shim_source(profile)
            local ok, err = write_all(combine(target_mount, "startup.lua"), shim, false)
            if not ok then
                return false, err
            end
            return true, {
                file_count = 1,
                mode = "shim",
                device = profile.device,
                checksum = checksum(shim),
            }
        end
        local blob, file_count_or_err = build_rom_blob(profile.source or self.source, profile)
        if not blob then
            return false, file_count_or_err
        end
        local ok, err = write_all(combine(target_mount, ROM_FILE), blob, true)
        if not ok then
            return false, err
        end
        ok, err = write_all(combine(target_mount, "startup.lua"), loader_source(profile), false)
        if not ok then
            return false, err
        end
        return true, {
            file_count = file_count_or_err,
            rom = ROM_FILE,
            device = profile.device,
            checksum = checksum(blob),
        }
    end

    function self:build_update_package()
        local profile = self:source_profile()
        local blob, file_count_or_err = build_rom_blob(profile.source or self.source, profile)
        if not blob then
            return false, file_count_or_err
        end
        return true, {
            os = profile.os,
            device = profile.device,
            version = SOFTWARE_VERSION,
            rom = ROM_FILE,
            rom_checksum = checksum(blob),
            rom_data = blob,
            startup = loader_source(profile),
            packed_files = file_count_or_err,
            built_at = now(),
        }
    end

    function self:build_update_package_for_device(device)
        local profile = profile_for_device(device) or SOURCE_PROFILES.phone
        local blob, file_count_or_err = build_rom_blob(profile.source or self:profile_source(profile), profile)
        if not blob then
            return false, file_count_or_err
        end
        return true, {
            os = profile.os,
            device = profile.device,
            version = SOFTWARE_VERSION,
            rom = ROM_FILE,
            rom_checksum = checksum(blob),
            rom_data = blob,
            startup = loader_source(profile),
            packed_files = file_count_or_err,
            built_at = now(),
        }
    end

    function self:update_metadata()
        local profile = self:source_profile()
        local blob, file_count_or_err = build_rom_blob(profile.source or self.source, profile)
        if not blob then
            return false, file_count_or_err
        end
        return true, {
            os = profile.os,
            device = profile.device,
            version = SOFTWARE_VERSION,
            rom = ROM_FILE,
            rom_checksum = checksum(blob),
            packed_files = file_count_or_err,
        }
    end

    function self:update_metadata_for_device(device)
        local profile = profile_for_device(device) or SOURCE_PROFILES.phone
        local blob, file_count_or_err = build_rom_blob(profile.source or self:profile_source(profile), profile)
        if not blob then
            return false, file_count_or_err
        end
        return true, {
            os = profile.os,
            device = profile.device,
            version = SOFTWARE_VERSION,
            rom = ROM_FILE,
            rom_checksum = checksum(blob),
            packed_files = file_count_or_err,
        }
    end

    function self:install()
        if not fs or not fs.exists or not fs.copy or not fs.delete then
            self.last_result = { ok = false, error = "FsUnavailable", time = now() }
            return false, "FsUnavailable"
        end
        local profile = self:source_profile()
        local cache_ok, cache_err = ensure_github_cache(profile.source or self.source)
        if not cache_ok then
            self.last_result = { ok = false, error = cache_err, time = now() }
            return false, cache_err
        end
        if not exists_any(profile.source or self.source) then
            self.last_result = { ok = false, error = "InstallImageMissing", time = now() }
            return false, "InstallImageMissing"
        end

        local drive = self:selected_drive()
        if not drive then
            self.last_result = { ok = false, error = "NoDiskSelected", time = now() }
            return false, "NoDiskSelected"
        end

        clean_target(drive.mount)
        local rom_ok, rom_result = self:build_rom(drive.mount)
        if not rom_ok then
            self.last_result = { ok = false, error = rom_result, time = now() }
            return false, rom_result
        end

        local stamp = combine(drive.mount, "hypercube_install")
        local handle = fs.open(stamp, "w")
        if handle then
            handle.write(textutils.serialize({
                os = profile.os,
                device = profile.device,
                installed_at = now(),
                source = self.source,
                mode = rom_result.mode or "rom",
                rom = rom_result.mode == "shim" and nil or (rom_result.rom or ROM_FILE),
                version = SOFTWARE_VERSION,
                packed_files = rom_result.file_count,
                rom_checksum = rom_result.checksum,
            }))
            handle.close()
        end

        self.last_result = {
            ok = true,
            drive = drive.name,
            mount = drive.mount,
            mode = rom_result.mode or "rom",
            rom = rom_result.mode == "shim" and nil or (rom_result.rom or ROM_FILE),
            version = SOFTWARE_VERSION,
            device = self:source_profile().device,
            packed_files = rom_result.file_count,
            rom_checksum = rom_result.checksum,
            time = now(),
        }
        return true, self.last_result
    end

    return self
end

installer.VERSION = SOFTWARE_VERSION
installer.SOURCES = SOURCE_PROFILES

return installer
