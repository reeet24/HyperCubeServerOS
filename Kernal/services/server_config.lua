local server_config = {}

server_config.PATH = "server_config"

local DEFAULTS = {
    db = {
        root = "hypercube_db",
        min_replicas = 2,
        drives = nil,
    },
    network = {
        modem = nil,
        protocol = "tesserac",
        hostname = "HyperCubeServer",
    },
    installer = {
        root = "installer",
        source_mode = "auto",
        github = {
            owner = "reeet24",
            repo = "HyperCubeServerOS",
            branch = "main",
            root = "",
            cache_ttl_ms = 600000,
            hash_check_ms = 60000,
        },
    },
    appstore = {
        root = "appstore",
        db_root = "hypercube_appstore_db",
        min_replicas = 2,
        drives = nil,
        source_mode = "auto",
        github = {
            owner = "reeet24",
            repo = "HyperCubeServerOS",
            branch = "main",
            root = "",
            cache_ttl_ms = 600000,
            hash_check_ms = 60000,
        },
    },
}

local function copy_table(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, child in pairs(value) do
        out[key] = copy_table(child)
    end
    return out
end

local function merge_defaults(config, defaults)
    config = type(config) == "table" and config or {}
    defaults = defaults or DEFAULTS
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            config[key] = merge_defaults(config[key], value)
        elseif config[key] == nil then
            config[key] = value
        end
    end
    return config
end

local function normalize_path(path, fallback)
    path = tostring(path or fallback or ""):gsub("\\", "/")
    path = path:gsub("^%./", ""):gsub("^/+", "")
    path = path:gsub("//+", "/")
    if path == "" then
        return fallback
    end
    return path
end

local function checksum(text)
    text = tostring(text or "")
    local a = 1
    local b = 0
    for i = 1, #text do
        a = (a + text:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return (b * 65536 + a) % 2147483647
end

local function installer_roots(config)
    local installer = config and config.installer or {}
    local roots = {}
    if type(installer.roots) == "table" then
        for _, root in ipairs(installer.roots) do
            local path = type(root) == "table" and root.root or root
            path = normalize_path(path)
            if path and path ~= "" then
                roots[#roots + 1] = path
            end
        end
    end
    if #roots == 0 then
        roots[1] = normalize_path(installer.root, DEFAULTS.installer.root)
    end
    return roots
end

local function storage_root(config, name, fallback)
    local section = config and config[name] or {}
    return normalize_path(section and section.root, fallback)
end

function server_config.defaults()
    return copy_table(DEFAULTS)
end

function server_config.load(path)
    path = path or server_config.PATH
    local config = nil
    if fs and fs.exists and fs.open and fs.exists(path) then
        local handle = fs.open(path, "r")
        if handle then
            local data = handle.readAll()
            handle.close()
            if textutils and textutils.unserialize then
                local ok, decoded = pcall(textutils.unserialize, data)
                if ok and type(decoded) == "table" then
                    config = decoded
                end
            end
        end
    end
    config = merge_defaults(config or {}, copy_table(DEFAULTS))
    config.db.root = normalize_path(config.db.root, DEFAULTS.db.root)
    config.installer.root = normalize_path(config.installer.root, DEFAULTS.installer.root)
    config.installer.source_mode = tostring(config.installer.source_mode or DEFAULTS.installer.source_mode)
    config.installer.github = merge_defaults(config.installer.github, copy_table(DEFAULTS.installer.github))
    config.installer.github.root = normalize_path(config.installer.github.root, DEFAULTS.installer.github.root)
    config.installer.github.branch = tostring(config.installer.github.branch or DEFAULTS.installer.github.branch)
    config.installer.github.owner = tostring(config.installer.github.owner or DEFAULTS.installer.github.owner)
    config.installer.github.repo = tostring(config.installer.github.repo or DEFAULTS.installer.github.repo)
    config.installer.github.cache_ttl_ms = tonumber(config.installer.github.cache_ttl_ms)
        or DEFAULTS.installer.github.cache_ttl_ms
    config.installer.github.hash_check_ms = tonumber(config.installer.github.hash_check_ms)
        or DEFAULTS.installer.github.hash_check_ms
    config.appstore.root = normalize_path(config.appstore.root, DEFAULTS.appstore.root)
    config.appstore.db_root = normalize_path(config.appstore.db_root, DEFAULTS.appstore.db_root)
    config.appstore.min_replicas = tonumber(config.appstore.min_replicas) or DEFAULTS.appstore.min_replicas
    config.appstore.source_mode = tostring(config.appstore.source_mode or DEFAULTS.appstore.source_mode)
    config.appstore.github = merge_defaults(config.appstore.github, copy_table(DEFAULTS.appstore.github))
    config.appstore.github.root = normalize_path(config.appstore.github.root, DEFAULTS.appstore.github.root)
    config.appstore.github.branch = tostring(config.appstore.github.branch or DEFAULTS.appstore.github.branch)
    config.appstore.github.owner = tostring(config.appstore.github.owner or DEFAULTS.appstore.github.owner)
    config.appstore.github.repo = tostring(config.appstore.github.repo or DEFAULTS.appstore.github.repo)
    config.appstore.github.cache_ttl_ms = tonumber(config.appstore.github.cache_ttl_ms)
        or DEFAULTS.appstore.github.cache_ttl_ms
    config.appstore.github.hash_check_ms = tonumber(config.appstore.github.hash_check_ms)
        or DEFAULTS.appstore.github.hash_check_ms
    config.network.protocol = tostring(config.network.protocol or DEFAULTS.network.protocol)
    config.network.hostname = tostring(config.network.hostname or DEFAULTS.network.hostname)
    return config
end

function server_config.save(config, path)
    if not fs or not fs.open or not textutils or not textutils.serialize then
        return false, "FsUnavailable"
    end
    path = path or server_config.PATH
    config = merge_defaults(config or {}, copy_table(DEFAULTS))
    local handle = fs.open(path, "w")
    if not handle then
        return false, "OpenFailed"
    end
    handle.write(textutils.serialize(config))
    handle.close()
    return true, config
end

function server_config.delete_local_installer(config)
    config = config or server_config.load()
    local paths = {}
    paths[#paths + 1] = normalize_path(config.installer and config.installer.root, DEFAULTS.installer.root)
    if type(config.installer and config.installer.roots) == "table" then
        for _, entry in ipairs(config.installer.roots) do
            local root = type(entry) == "table" and entry.root or entry
            root = normalize_path(root)
            if root and root ~= "" then
                paths[#paths + 1] = root
            end
        end
    end
    paths[#paths + 1] = DEFAULTS.installer.root
    local seen = {}
    local deleted = 0
    for _, path in ipairs(paths) do
        if path and path ~= "" and not seen[path] and fs and fs.exists and fs.delete and fs.exists(path) then
            seen[path] = true
            fs.delete(path)
            deleted = deleted + 1
        end
    end
    return true, deleted
end

function server_config.delete_local_appstore_source(config)
    config = config or server_config.load()
    local roots = {
        normalize_path(config.appstore and config.appstore.root, DEFAULTS.appstore.root),
        DEFAULTS.appstore.root,
    }
    local seen = {}
    local deleted = 0
    for _, root in ipairs(roots) do
        local path = normalize_path(root .. "/apps")
        if path and path ~= "" and not seen[path] and fs and fs.exists and fs.delete and fs.exists(path) then
            seen[path] = true
            fs.delete(path)
            deleted = deleted + 1
        end
    end
    return true, deleted
end

function server_config.installer_source(config, profile)
    config = config or server_config.load()
    local roots = installer_roots(config)
    local root = normalize_path(config.installer and config.installer.root, DEFAULTS.installer.root)
    profile = tostring(profile or "hypercube_phone")
    if profile == "" then
        profile = "hypercube_phone"
    end
    if #roots > 1 then
        return "installer/" .. profile
    end
    if fs and fs.combine then
        return fs.combine(root, profile)
    end
    return root .. "/" .. profile
end

function server_config.local_path(config, repo_path)
    config = config or server_config.load()
    repo_path = normalize_path(repo_path, "")
    local appstore_root = storage_root(config, "appstore", DEFAULTS.appstore.root)
    if appstore_root ~= DEFAULTS.appstore.root then
        if repo_path == "appstore" then
            return appstore_root
        end
        local appstore_prefix = "appstore/"
        if repo_path:sub(1, #appstore_prefix) == appstore_prefix then
            return normalize_path(appstore_root .. "/" .. repo_path:sub(#appstore_prefix + 1), repo_path)
        end
    end

    local roots = installer_roots(config)
    local installer_root = roots[1]
    if #roots > 1 then
        if repo_path == "installer" then
            return installer_root
        end
        local prefix = "installer/"
        if repo_path:sub(1, #prefix) == prefix then
            local relative = repo_path:sub(#prefix + 1)
            local index = (checksum(relative) % #roots) + 1
            return normalize_path(roots[index] .. "/" .. relative, repo_path)
        end
    elseif installer_root ~= "installer" then
        if repo_path == "installer" then
            return installer_root
        end
        local prefix = "installer/"
        if repo_path:sub(1, #prefix) == prefix then
            return normalize_path(installer_root .. "/" .. repo_path:sub(#prefix + 1), repo_path)
        end
    end
    return repo_path
end

function server_config.local_paths(config, repo_path)
    config = config or server_config.load()
    repo_path = normalize_path(repo_path, "")
    if repo_path == "appstore" or repo_path:sub(1, 9) == "appstore/" then
        return { server_config.local_path(config, repo_path) }
    end
    local prefix = "installer/"
    if repo_path == "installer" or repo_path:sub(1, #prefix) == prefix then
        local roots = installer_roots(config)
        if #roots > 1 then
            local out = {}
            local relative = repo_path == "installer" and "" or repo_path:sub(#prefix + 1)
            for _, root in ipairs(roots) do
                out[#out + 1] = relative == "" and root or normalize_path(root .. "/" .. relative)
            end
            return out
        end
    end
    return { server_config.local_path(config, repo_path) }
end

return server_config
