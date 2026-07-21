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

function server_config.installer_source(config, profile)
    config = config or server_config.load()
    local root = normalize_path(config.installer and config.installer.root, DEFAULTS.installer.root)
    profile = tostring(profile or "hypercube_phone")
    if profile == "" then
        profile = "hypercube_phone"
    end
    if fs and fs.combine then
        return fs.combine(root, profile)
    end
    return root .. "/" .. profile
end

function server_config.local_path(config, repo_path)
    config = config or server_config.load()
    repo_path = normalize_path(repo_path, "")
    local installer_root = normalize_path(config.installer and config.installer.root, DEFAULTS.installer.root)
    if installer_root ~= "installer" then
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

return server_config
