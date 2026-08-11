local appstore = {}
local diskdb_ok, diskdb_driver = pcall(require, "Kernal.drivers.diskdb")
local config_ok, server_config = pcall(require, "Kernal.services.server_config")

local APPSTORE_ROOT = "appstore"
local APP_ROOT = "appstore/apps"
local TOKEN_PATH = "appstore/admin_token"
local APP_INTEGRITY_FILE = ".hcapp_integrity"
local APP_INTEGRITY_KEY = "HyperCubeAppIntegrity:v1"
local APPSTORE_DB = nil
local APPSTORE_INDEX_KEY = "appstore:index"
local DEPRECATED_APPS = {
    chirper = true,
    trains = true,
}

local SEED_APPS = {}
local GITHUB_DEFAULTS = {
    owner = "reeet24",
    repo = "HyperCubeServerOS",
    branch = "main",
    root = "computer/0",
    cache_ttl_ms = 600000,
    hash_check_ms = 60000,
}
local github_cache = nil

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

local function configure_storage(config)
    local root = config and config.appstore and config.appstore.root or APPSTORE_ROOT
    root = tostring(root or "appstore"):gsub("\\", "/")
    root = root:gsub("^%./", ""):gsub("^/+", ""):gsub("//+", "/")
    if root == "" then
        root = "appstore"
    end
    APPSTORE_ROOT = root
    APP_ROOT = combine(APPSTORE_ROOT, "apps")
    TOKEN_PATH = combine(APPSTORE_ROOT, "admin_token")
    appstore.root = APPSTORE_ROOT
    appstore.app_root = APP_ROOT
    appstore.token_path = TOKEN_PATH
    return APPSTORE_ROOT
end

local function configure_database(config)
    APPSTORE_DB = nil
    if not diskdb_ok or not diskdb_driver or not diskdb_driver.new then
        return false, "DiskDBUnavailable"
    end
    local appstore_config = config and config.appstore or {}
    local db_config = config and config.db or {}
    local drives = appstore_config.drives or db_config.drives
    if type(drives) ~= "table" and type(appstore_config.drive) == "table" then
        drives = { appstore_config.drive }
    end
    local ok, db_or_err = pcall(diskdb_driver.new, {
        root = appstore_config.db_root or "hypercube_appstore_db",
        min_replicas = tonumber(appstore_config.min_replicas or db_config.min_replicas) or 2,
        drives = drives,
    })
    if not ok or not db_or_err then
        return false, db_or_err or "DiskDBInitFailed"
    end
    APPSTORE_DB = db_or_err
    appstore.database = APPSTORE_DB
    return true, APPSTORE_DB
end

local function safe_id(id)
    id = tostring(id or ""):lower():gsub("%s+", "")
    id = id:gsub("[^%w_%-%.]", "_")
    if id == "" then
        return nil, "InvalidAppId"
    end
    return id
end

local function safe_relative(path)
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("^/+", ""):gsub("^%./", ""):gsub("//+", "/")
    if path == "" or path:find("..", 1, true) then
        return nil, "InvalidPath"
    end
    path = path:gsub("[^%w%._%-%/]", "_")
    if path == "" or path:sub(-1) == "/" then
        return nil, "InvalidPath"
    end
    return path
end

local function ensure_dir(path)
    if not fs or not fs.exists or not fs.makeDir then
        return false, "FsUnavailable"
    end
    if not fs.exists(path) then
        fs.makeDir(path)
    end
    return true
end

local function read_all(path)
    if not fs or not fs.exists or not fs.open or not fs.exists(path) then
        return nil, "NotFound"
    end
    local handle = fs.open(path, "r")
    if not handle then
        return nil, "OpenFailed"
    end
    local data = handle.readAll()
    handle.close()
    return data
end

local function write_all(path, data)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then
        local ok, err = ensure_dir(dir)
        if not ok then
            return false, err
        end
    end
    local handle = fs.open(path, "w")
    if not handle then
        return false, "OpenFailed"
    end
    handle.write(tostring(data or ""))
    handle.close()
    return true
end

local function serialize(value)
    if textutils and textutils.serialize then
        return textutils.serialize(value)
    end
    return tostring(value or "")
end

local function unserialize(value)
    if textutils and textutils.unserialize then
        return textutils.unserialize(value)
    end
    return nil
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
        ["User-Agent"] = "HyperCubeServerOS-AppStore",
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

local function appstore_config()
    if config_ok and server_config and server_config.load then
        local ok, config = pcall(server_config.load)
        if ok and type(config) == "table" then
            return config.appstore or {}
        end
    end
    return {}
end

local function github_config()
    local cfg = appstore_config()
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
    return table.concat({ config.owner, config.repo, config.branch, config.root }, ":")
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

local function fetch_appstore_tree_hash(config)
    local branches = { config.branch }
    if config.branch == "main" then
        branches[#branches + 1] = "master"
    end
    local last_err = nil
    for _, branch in ipairs(branches) do
        for _, root in ipairs(root_candidates(config)) do
            local full = root ~= "" and combine(root, "appstore/apps") or "appstore/apps"
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
                    last_err = "AppStoreTreeHashMissing:" .. full
                end
            else
                last_err = tostring(err) .. ":" .. full
            end
        end
        local url = github_api_base(config) .. "/git/trees/" .. encode_segment(branch) .. "?recursive=1"
        local body, tree_err = github_http_get(url)
        if body then
            local decoded, json_err = decode_json(body)
            if type(decoded) == "table" and type(decoded.tree) == "table" then
                for _, entry in ipairs(decoded.tree) do
                    local path = normalize_path(entry.path)
                    if entry.type == "tree" and (path == "appstore/apps" or path:sub(-14) == "/appstore/apps") then
                        config.branch = branch
                        config.root = path == "appstore/apps" and "" or path:sub(1, #path - 14)
                        return entry.sha
                    end
                end
                last_err = "AppStoreFolderNotInRepo"
            else
                last_err = json_err or (type(decoded) == "table" and decoded.message) or "GitTreeMissing"
            end
        else
            last_err = tostring(tree_err)
        end
    end
    return nil, last_err or "AppStoreTreeHashMissing"
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

local function local_app_source_exists()
    return fs and fs.exists and fs.exists(APP_ROOT)
end

local function should_use_github(config)
    if config.source_mode == "local" then
        return false
    end
    if config.source_mode == "github" then
        return true
    end
    return not local_app_source_exists()
end

local function source_mode()
    return github_config().source_mode
end

local function expire_github_cache(config)
    if github_cache and now() - tonumber(github_cache.last_used or 0) > config.cache_ttl_ms then
        github_cache = nil
    end
end

local function ensure_github_cache()
    local config = github_config()
    expire_github_cache(config)
    if not should_use_github(config) then
        return true, nil, false
    end
    local key = repo_key(config)
    local current_hash
    if github_cache and github_cache.key == key then
        if now() - tonumber(github_cache.checked_at or 0) < config.hash_check_ms then
            github_cache.last_used = now()
            return true, github_cache, true
        end
        current_hash = fetch_appstore_tree_hash(config)
        if current_hash and current_hash == github_cache.tree_hash then
            github_cache.checked_at = now()
            github_cache.last_used = now()
            return true, github_cache, true
        end
    end
    local hash_err
    if not current_hash then
        current_hash, hash_err = fetch_appstore_tree_hash(config)
        key = repo_key(config)
    end
    if not current_hash then
        return false, "GitHubAppStoreHashUnavailable:" .. tostring(hash_err), true
    end
    local tree, tree_err = fetch_recursive_tree(config)
    if not tree then
        return false, tree_err, true
    end
    local files = {}
    local root_prefix = config.root ~= "" and (config.root .. "/appstore/apps/") or "appstore/apps/"
    for _, entry in ipairs(tree.tree or {}) do
        local path = normalize_path(entry.path)
        if entry.type == "blob" and path:sub(1, #root_prefix) == root_prefix then
            local repo_path = "appstore/apps/" .. path:sub(#root_prefix + 1)
            local data, data_err = github_http_get(github_raw_url(config, repo_path), "application/octet-stream")
            if not data then
                return false, "GitHubAppStoreFileFailed:" .. repo_path .. ":" .. tostring(data_err), true
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

local function app_manifest_key(id)
    return "appstore:app:" .. tostring(id) .. ":manifest"
end

local function app_file_key(id, path)
    return "appstore:app:" .. tostring(id) .. ":file:" .. checksum(tostring(path or ""))
end

local function db_get(key)
    if not APPSTORE_DB then
        return nil, "DatabaseUnavailable"
    end
    return APPSTORE_DB:get(key)
end

local function db_set(key, value)
    if not APPSTORE_DB then
        return false, "DatabaseUnavailable"
    end
    return APPSTORE_DB:set(key, value)
end

local function db_delete(key)
    if not APPSTORE_DB then
        return false, "DatabaseUnavailable"
    end
    return APPSTORE_DB:delete(key)
end

local function load_index()
    local index = db_get(APPSTORE_INDEX_KEY)
    if type(index) ~= "table" then
        index = {
            format = "HyperCubeAppStoreIndex",
            version = 1,
            apps = {},
        }
    end
    index.apps = index.apps or {}
    return index
end

local function save_index(index)
    index = type(index) == "table" and index or load_index()
    index.updated_at = now()
    return db_set(APPSTORE_INDEX_KEY, index)
end

local function index_app(id)
    if DEPRECATED_APPS[id] then
        return true
    end
    local index = load_index()
    for _, existing in ipairs(index.apps) do
        if existing == id then
            return save_index(index)
        end
    end
    index.apps[#index.apps + 1] = id
    table.sort(index.apps)
    return save_index(index)
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

local function normalize_mutable_paths(paths)
    local out = {}
    for _, path in ipairs(type(paths) == "table" and paths or {}) do
        local safe = safe_relative(path)
        if safe and safe ~= "app.lua" and safe ~= APP_INTEGRITY_FILE then
            out[#out + 1] = safe
        end
    end
    table.sort(out)
    return out
end

local function path_is_mutable(path, mutable_paths)
    path = tostring(path or "")
    if path == "app.lua" or path == APP_INTEGRITY_FILE then
        return false
    end
    for _, mutable in ipairs(mutable_paths or {}) do
        if path == mutable or path:sub(1, #mutable + 1) == mutable .. "/" then
            return true
        end
    end
    return false
end

local function integrity_body(files)
    local lines = {}
    for _, file in ipairs(files or {}) do
        lines[#lines + 1] = tostring(file.path) .. "\n" .. tostring(file.checksum)
    end
    return table.concat(lines, "\n--\n")
end

local function build_integrity(item, files)
    local mutable_paths = normalize_mutable_paths(item.mutable_paths or item.mutable or item.unchecked_paths or item.mod_paths)
    local protected = {}
    for _, file in ipairs(files or {}) do
        local path = safe_relative(file.path)
        if path and path ~= APP_INTEGRITY_FILE and not path_is_mutable(path, mutable_paths) then
            protected[#protected + 1] = {
                path = path,
                checksum = checksum(file.data or ""),
            }
        end
    end
    table.sort(protected, function(a, b)
        return a.path < b.path
    end)
    return {
        format = "HyperCubeAppIntegrity",
        version = 1,
        app_id = item.id,
        app_version = item.version,
        mutable_paths = mutable_paths,
        files = protected,
        checksum = checksum(integrity_body(protected)),
    }
end

local function encode_integrity(metadata)
    local payload = serialize(metadata)
    return xor_crypt(payload, APP_INTEGRITY_KEY)
end

local function manifest_path(app_dir)
    return combine(app_dir, "manifest")
end

local function public_item(item)
    return {
        id = item.id,
        title = item.title,
        version = item.version,
        author = item.author,
        description = item.description,
        file_count = item.file_count,
        protected_file_count = item.protected_file_count,
        mutable_paths = item.mutable_paths,
        devices = item.devices,
    }
end

local function normalize_devices(devices)
    if type(devices) ~= "table" then
        return nil
    end
    local out = {}
    local seen = {}
    for _, device in ipairs(devices) do
        device = tostring(device or ""):gsub("^%s*(.-)%s*$", "%1")
        if device ~= "" and not seen[device] then
            seen[device] = true
            out[#out + 1] = device
        end
    end
    table.sort(out)
    if #out == 0 then
        return nil
    end
    return out
end

local function default_manifest(id)
    return {
        id = id,
        title = id,
        version = "1.0.0",
        author = "Server",
        description = "Server-hosted HyperCube app.",
        mutable_paths = {},
    }
end

local function load_manifest(id, app_dir)
    local manifest = default_manifest(id)
    local data = read_all(manifest_path(app_dir))
    local loaded = data and unserialize(data) or nil
    if type(loaded) == "table" then
        for key, value in pairs(loaded) do
            if key ~= "source" and key ~= "app_lua" and key ~= "code" then
                manifest[key] = value
            end
        end
    end
    manifest.id = id
    return manifest
end

local function save_manifest(app_dir, item)
    local manifest = {
        id = item.id,
        title = item.title,
        label = item.label,
        version = item.version,
        author = item.author,
        description = item.description,
        file_count = item.file_count,
        entry = item.entry or "app.lua",
        color = item.color,
        dock = item.dock,
        render_mode = item.render_mode,
        refresh_rate = item.refresh_rate or item.fps or item.frame_rate,
        mutable_paths = normalize_mutable_paths(item.mutable_paths or item.mutable or item.unchecked_paths or item.mod_paths),
        devices = normalize_devices(item.devices or item.device_types or item.supported_devices),
    }
    return write_all(manifest_path(app_dir), serialize(manifest))
end

local function collect_files(root, path, files)
    local full = path == "" and root or combine(root, path)
    if fs.isDir(full) then
        for _, child in ipairs(fs.list(full)) do
            collect_files(root, path == "" and child or combine(path, child), files)
        end
    else
        local relative = safe_relative(path)
        if relative and relative ~= "manifest" and relative ~= APP_INTEGRITY_FILE then
            local data = read_all(full)
            if data then
                files[#files + 1] = {
                    path = relative,
                    data = data,
                }
            end
        end
    end
end

local function read_app_from_fs(id)
    local safe, id_err = safe_id(id)
    if not safe then
        return nil, id_err
    end
    local app_dir = combine(APP_ROOT, safe)
    local app_path = combine(app_dir, "app.lua")
    local source, read_err = read_all(app_path)
    if not source then
        return nil, read_err
    end
    local manifest = load_manifest(safe, app_dir)
    manifest.source = source
    local files = {}
    collect_files(app_dir, "", files)
    table.sort(files, function(a, b)
        return tostring(a.path) < tostring(b.path)
    end)
    manifest.files = files
    manifest.file_count = #files
    manifest.integrity = build_integrity(manifest, files)
    manifest.integrity_encoded = encode_integrity(manifest.integrity)
    manifest.protected_file_count = #(manifest.integrity.files or {})
    return manifest
end

local function read_app_from_github(id)
    local safe, id_err = safe_id(id)
    if not safe then
        return nil, id_err
    end
    if DEPRECATED_APPS[safe] then
        return nil, "AppDeprecated"
    end
    local ok, cache_or_err = ensure_github_cache()
    if not ok then
        return nil, cache_or_err
    end
    if not github_cache or not github_cache.files then
        return nil, "AppNotFound"
    end
    local prefix = "appstore/apps/" .. safe .. "/"
    local app_source = github_cache.files[prefix .. "app.lua"]
    if type(app_source) ~= "string" then
        return nil, "AppNotFound"
    end
    local manifest = default_manifest(safe)
    local manifest_data = github_cache.files[prefix .. "manifest"]
    local loaded = manifest_data and unserialize(manifest_data) or nil
    if type(loaded) == "table" then
        for key, value in pairs(loaded) do
            if key ~= "source" and key ~= "app_lua" and key ~= "code" then
                manifest[key] = value
            end
        end
    end
    manifest.id = safe
    manifest.source = app_source
    local files = {}
    for path, data in pairs(github_cache.files) do
        if path:sub(1, #prefix) == prefix then
            local relative = safe_relative(path:sub(#prefix + 1))
            if relative and relative ~= "manifest" and relative ~= APP_INTEGRITY_FILE then
                files[#files + 1] = {
                    path = relative,
                    data = data or "",
                }
            end
        end
    end
    table.sort(files, function(a, b)
        return tostring(a.path) < tostring(b.path)
    end)
    manifest.files = files
    manifest.file_count = #files
    manifest.integrity = build_integrity(manifest, files)
    manifest.integrity_encoded = encode_integrity(manifest.integrity)
    manifest.protected_file_count = #(manifest.integrity.files or {})
    manifest.mutable_paths = manifest.integrity.mutable_paths
    return manifest
end

local function list_github_apps()
    local ok = ensure_github_cache()
    if not ok or not github_cache or not github_cache.files then
        return {}
    end
    local seen = {}
    local apps = {}
    for path in pairs(github_cache.files) do
        local id = path:match("^appstore/apps/([^/]+)/app%.lua$")
        id = id and safe_id(id)
        if id and not seen[id] and not DEPRECATED_APPS[id] then
            seen[id] = true
            local item = read_app_from_github(id)
            if item then
                apps[#apps + 1] = public_item(item)
            end
        end
    end
    return apps
end

local function manifest_for_db(item, files)
    local manifest = {
        format = "HyperCubeAppStoreApp",
        version = 1,
        id = item.id,
        title = item.title or item.id,
        label = item.label,
        app_version = item.version or "1.0.0",
        author = item.author or item.username or "Server",
        description = item.description or "Server-hosted HyperCube app.",
        entry = item.entry or "app.lua",
        color = item.color,
        dock = item.dock,
        render_mode = item.render_mode,
        refresh_rate = item.refresh_rate or item.fps or item.frame_rate,
        mutable_paths = normalize_mutable_paths(item.mutable_paths or item.mutable or item.unchecked_paths or item.mod_paths),
        devices = normalize_devices(item.devices or item.device_types or item.supported_devices),
        files = {},
        file_count = #files,
        updated_at = now(),
    }
    for _, file in ipairs(files or {}) do
        manifest.files[#manifest.files + 1] = {
            path = file.path,
            checksum = checksum(file.data or ""),
            size = #(file.data or ""),
        }
    end
    table.sort(manifest.files, function(a, b)
        return tostring(a.path) < tostring(b.path)
    end)
    return manifest
end

local function db_manifest_to_item(manifest)
    if type(manifest) ~= "table" then
        return nil
    end
    return {
        id = manifest.id,
        title = manifest.title,
        label = manifest.label,
        version = manifest.app_version or manifest.version,
        author = manifest.author,
        description = manifest.description,
        entry = manifest.entry,
        color = manifest.color,
        dock = manifest.dock,
        render_mode = manifest.render_mode,
        refresh_rate = manifest.refresh_rate,
        mutable_paths = manifest.mutable_paths or {},
        devices = manifest.devices,
        file_count = manifest.file_count or #(manifest.files or {}),
        updated_at = manifest.updated_at,
    }
end

local function protected_file_count_from_manifest(manifest)
    local mutable_paths = manifest and manifest.mutable_paths or {}
    local count = 0
    for _, file in ipairs((manifest and manifest.files) or {}) do
        if file.path and file.path ~= APP_INTEGRITY_FILE and not path_is_mutable(file.path, mutable_paths) then
            count = count + 1
        end
    end
    return count
end

local function save_app_to_db(item, files)
    if not APPSTORE_DB then
        return false, "DatabaseUnavailable"
    end
    local id, id_err = safe_id(item and item.id)
    if not id then
        return false, id_err
    end
    item.id = id
    table.sort(files, function(a, b)
        return tostring(a.path) < tostring(b.path)
    end)

    local existing = db_get(app_manifest_key(id))
    if type(existing) == "table" then
        for _, file in ipairs(existing.files or {}) do
            if file.path then
                db_delete(app_file_key(id, file.path))
            end
        end
    end

    local manifest = manifest_for_db(item, files)
    for _, file in ipairs(files or {}) do
        local ok, err = db_set(app_file_key(id, file.path), {
            app_id = id,
            path = file.path,
            data = file.data or "",
            checksum = checksum(file.data or ""),
            size = #(file.data or ""),
            updated_at = manifest.updated_at,
        })
        if not ok then
            return false, err
        end
    end

    local ok, err = db_set(app_manifest_key(id), manifest)
    if not ok then
        return false, err
    end
    ok, err = index_app(id)
    if not ok then
        return false, err
    end
    local result = db_manifest_to_item(manifest)
    result.protected_file_count = protected_file_count_from_manifest(manifest)
    return true, public_item(result)
end

local function read_app(id)
    local safe, id_err = safe_id(id)
    if not safe then
        return nil, id_err
    end
    local manifest = db_get(app_manifest_key(safe))
    if type(manifest) ~= "table" then
        return read_app_from_github(safe)
    end
    local item = db_manifest_to_item(manifest)
    local files = {}
    for _, file_ref in ipairs(manifest.files or {}) do
        local record = db_get(app_file_key(safe, file_ref.path))
        if type(record) ~= "table" or record.path ~= file_ref.path then
            return nil, "AppFileMissing:" .. tostring(file_ref.path)
        end
        if checksum(record.data or "") ~= tostring(file_ref.checksum or "") then
            return nil, "AppFileChecksumMismatch:" .. tostring(file_ref.path)
        end
        files[#files + 1] = {
            path = file_ref.path,
            data = record.data or "",
        }
    end
    table.sort(files, function(a, b)
        return tostring(a.path) < tostring(b.path)
    end)
    item.files = files
    item.file_count = #files
    for _, file in ipairs(files) do
        if file.path == "app.lua" then
            item.source = file.data
            break
        end
    end
    if not item.source then
        return nil, "EntrypointRequired"
    end
    item.integrity = build_integrity(item, files)
    item.integrity_encoded = encode_integrity(item.integrity)
    item.protected_file_count = #(item.integrity.files or {})
    item.mutable_paths = item.integrity.mutable_paths
    return item
end

local function ensure_seed_apps()
    if not APPSTORE_DB then
        return false, "DatabaseUnavailable"
    end

    for _, item in ipairs(SEED_APPS) do
        local id = safe_id(item.id)
        if id and not db_get(app_manifest_key(id)) then
            local ok, err = save_app_to_db(item, {
                {
                    path = "app.lua",
                    data = item.source,
                },
            })
            if not ok then
                return false, err
            end
        end
    end

    if source_mode() ~= "github" and fs and fs.exists and fs.list and fs.exists(APP_ROOT) then
        for _, id in ipairs(fs.list(APP_ROOT)) do
            local safe = safe_id(id)
            if safe then
                local item = read_app_from_fs(safe)
                local existing = db_get(app_manifest_key(safe))
                if item and (not existing or tostring(existing.app_version or existing.version or "") ~= tostring(item.version or "")) then
                    local ok, err = save_app_to_db(item, item.files or {})
                    if not ok then
                        return false, err
                    end
                end
            end
        end
    end

    return true
end

local function list_apps()
    ensure_seed_apps()
    local apps = {}
    local seen = {}
    if not APPSTORE_DB then
        return list_github_apps()
    end

    local index = load_index()
    for _, id in ipairs(index.apps or {}) do
        local manifest = not DEPRECATED_APPS[id] and db_get(app_manifest_key(id)) or nil
        if type(manifest) == "table" then
            local item = db_manifest_to_item(manifest)
            item.protected_file_count = protected_file_count_from_manifest(manifest)
            apps[#apps + 1] = public_item(item)
            seen[item.id] = true
        end
    end

    for _, item in ipairs(list_github_apps()) do
        if item.id and not seen[item.id] then
            apps[#apps + 1] = item
            seen[item.id] = true
        end
    end

    table.sort(apps, function(a, b)
        return tostring(a.title or a.id) < tostring(b.title or b.id)
    end)
    return apps
end

local function token_required()
    return fs and fs.exists and fs.exists(TOKEN_PATH)
end

local function check_publish_token(message)
    if not token_required() then
        return true
    end
    local token = read_all(TOKEN_PATH)
    token = tostring(token or ""):match("^%s*(.-)%s*$")
    return token ~= "" and tostring(message.admin_token or message.token or "") == token
end

local function publish_app(package)
    if type(package) ~= "table" then
        return false, "InvalidPackage"
    end
    local id, id_err = safe_id(package.id)
    if not id then
        return false, id_err
    end
    if DEPRECATED_APPS[id] then
        return false, "AppDeprecated"
    end
    local source = package.source or package.app_lua or package.code
    local package_files = package.files
    if (type(source) ~= "string" or source == "") and type(package_files) ~= "table" then
        return false, "SourceRequired"
    end

    local files = {}
    local err
    local has_app_lua = false
    if type(package_files) == "table" then
        for key, file in pairs(package_files) do
            local path, data
            if type(file) == "table" then
                path = file.path or file.name
                data = file.data or file.source or file.contents or file.content
            else
                path = key
                data = file
            end
            path, err = safe_relative(path)
            if not path then
                return false, err
            end
            if path == "manifest" or path == APP_INTEGRITY_FILE then
                return false, "ReservedPath"
            end
            if path == "app.lua" then
                has_app_lua = true
            end
            files[#files + 1] = {
                path = path,
                data = tostring(data or ""),
            }
        end
    end

    if type(source) == "string" and source ~= "" and not has_app_lua then
        files[#files + 1] = {
            path = "app.lua",
            data = source,
        }
        has_app_lua = true
    end
    if not has_app_lua then
        return false, "EntrypointRequired"
    end

    return save_app_to_db({
        id = id,
        title = package.title or id,
        label = package.label,
        version = package.version or "1.0.0",
        author = package.author or package.username or "Server",
        description = package.description or "Server-hosted HyperCube app.",
        entry = package.entry or "app.lua",
        color = package.color,
        dock = package.dock,
        render_mode = package.render_mode,
        refresh_rate = package.refresh_rate or package.fps or package.frame_rate,
        mutable_paths = package.mutable_paths or package.mutable or package.unchecked_paths or package.mod_paths,
    }, files)
end

local function reply(rednet_api, sender, protocol, response_type, ok, result)
    rednet_api.send(sender, {
        type = response_type,
        ok = ok == true,
        result = ok and result or nil,
        error = ok and nil or result,
        time = now(),
    }, protocol)
end

function appstore.install(hypercube)
    if not hypercube.network then
        return false, "NetworkUnavailable"
    end
    configure_storage(hypercube and hypercube.config)
    local db_ok, db_or_err = configure_database(hypercube and hypercube.config)
    if not db_ok then
        return false, db_or_err
    end
    ensure_dir(APPSTORE_ROOT)
    local seed_ok, seed_err = ensure_seed_apps()
    if not seed_ok then
        return false, seed_err
    end
    if hypercube.appstore_handler_registered then
        return true
    end

    hypercube.network:register_handler("appstore", function(network, sender, message)
        if type(message) ~= "table" or type(message.type) ~= "string" or message.type:sub(1, 9) ~= "appstore." then
            return false
        end

        if message.type == "appstore.list" then
            reply(rednet, sender, network.protocol, "appstore.list.result", true, {
                apps = list_apps(),
            })
        elseif message.type == "appstore.download" then
            local safe = safe_id(message.app_id)
            local item = safe and not DEPRECATED_APPS[safe] and read_app(safe) or nil
            if item then
                reply(rednet, sender, network.protocol, "appstore.download.result", true, {
                    id = item.id,
                    title = item.title,
                    version = item.version,
                    author = item.author,
                    description = item.description,
                    source = item.source,
                    files = item.files,
                    file_count = item.file_count,
                    protected_file_count = item.protected_file_count,
                    mutable_paths = item.mutable_paths,
                    devices = item.devices,
                    integrity_encoded = item.integrity_encoded,
                })
            else
                reply(rednet, sender, network.protocol, "appstore.download.result", false, "AppNotFound")
            end
        elseif message.type == "appstore.publish" then
            if not check_publish_token(message) then
                reply(rednet, sender, network.protocol, "appstore.publish.result", false, "TokenRequired")
            else
                local ok, result = publish_app(message.package or message)
                reply(rednet, sender, network.protocol, "appstore.publish.result", ok, result)
            end
        else
            reply(rednet, sender, network.protocol, "appstore.error", false, "UnknownAppStoreRequest")
        end

        if hypercube.logger then
            hypercube.logger.debug("appstore " .. tostring(message.type) .. " sender=" .. tostring(sender), hypercube.root_context)
        end
        return true
    end)

    hypercube.appstore_handler_registered = true
    if hypercube.logger then
        hypercube.logger.info("App Store HyperNet API registered", hypercube.root_context)
    end
    return true
end

function appstore.start(hypercube)
    local ok, err = appstore.install(hypercube)
    if not ok then
        return false, err
    end
    while true do
        if appstore.prune_github_cache and appstore.prune_github_cache() and hypercube.logger then
            hypercube.logger.info("github appstore source cache expired", hypercube.root_context)
        end
        coroutine.yield("tick")
    end
end

function appstore.github_cache_status()
    local config = github_config()
    expire_github_cache(config)
    local count = 0
    if github_cache and github_cache.files then
        for _ in pairs(github_cache.files) do
            count = count + 1
        end
    end
    return {
        source_mode = config.source_mode,
        owner = config.owner,
        repo = config.repo,
        branch = config.branch,
        root = config.root,
        cached = github_cache ~= nil,
        cached_files = count,
        tree_hash = github_cache and github_cache.tree_hash or nil,
        loaded_at = github_cache and github_cache.loaded_at or nil,
        last_used = github_cache and github_cache.last_used or nil,
    }
end

function appstore.prune_github_cache()
    local before = github_cache ~= nil
    expire_github_cache(github_config())
    return before and github_cache == nil
end

appstore.root = APPSTORE_ROOT
appstore.app_root = APP_ROOT
appstore.token_path = TOKEN_PATH
appstore.configure_storage = configure_storage
appstore.configure_database = configure_database
appstore.list_apps = list_apps
appstore.read_app = read_app
appstore.publish = publish_app

return appstore
