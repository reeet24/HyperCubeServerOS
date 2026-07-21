local hcapi = require("Kernal.services.hcapi")

local app_manager = {}

local APP_ROOT = "apps"
local USER_APP_ROOT = "user/apps"
local APP_INTEGRITY_FILE = ".hcapp_integrity"
local APP_INTEGRITY_KEY = "HyperCubeAppIntegrity:v1"

local function combine(a, b)
    if fs and fs.combine then
        return fs.combine(a, b)
    end
    if a:sub(-1) == "/" then
        return a .. b
    end
    return a .. "/" .. b
end

local function copy_manifest(manifest, id, path)
    manifest = manifest or {}
    local render_mode = tostring(manifest.render_mode or manifest.mode or "window"):lower():gsub("_", "-")
    if render_mode == "fullscreen" or render_mode == "full-screen" then
        render_mode = "exclusive"
    elseif render_mode == "borderless" then
        render_mode = "borderless-exclusive"
    elseif render_mode ~= "window" and render_mode ~= "exclusive" and render_mode ~= "borderless-exclusive" then
        render_mode = "window"
    end
    return {
        id = id,
        title = manifest.title or id,
        label = manifest.label or id:sub(1, 3),
        color = manifest.color,
        dock = manifest.dock == true,
        render_mode = render_mode,
        refresh_rate = manifest.refresh_rate or manifest.fps or manifest.frame_rate,
        path = path,
    }
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

local function app_order(id)
    local priority = {
        appstore = 1,
        messages = 2,
        banking = 3,
        browser = 4,
        settings = 5,
    }
    return priority[id] or 50
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

local function write_all(path, data)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
        local ok, err = ensure_dir(dir)
        if not ok then
            return false, err
        end
    end
    local handle = fs.open(path, "wb")
    if not handle then
        return false, "OpenFailed"
    end
    handle.write(tostring(data or ""))
    handle.close()
    return true
end

local function read_all(path)
    if not fs or not fs.exists or not fs.open or not fs.exists(path) then
        return nil, "NotFound"
    end
    local handle = fs.open(path, "rb")
    if not handle then
        return nil, "OpenFailed"
    end
    local data = handle.readAll()
    handle.close()
    return data
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

local function encode_integrity(metadata)
    if not textutils or not textutils.serialize then
        return nil, "TextutilsUnavailable"
    end
    local payload = textutils.serialize(metadata or {})
    return xor_crypt(payload, APP_INTEGRITY_KEY)
end

local function decode_integrity(data)
    if not textutils or not textutils.unserialize then
        return nil, "TextutilsUnavailable"
    end
    local decoded, err = xor_crypt(data, APP_INTEGRITY_KEY)
    if not decoded then
        return nil, err
    end
    local ok, result = pcall(textutils.unserialize, decoded)
    if not ok or type(result) ~= "table" then
        return nil, "AppIntegrityDecodeFailed"
    end
    return result
end

local function integrity_body(files)
    local lines = {}
    for _, file in ipairs(files or {}) do
        lines[#lines + 1] = tostring(file.path) .. "\n" .. tostring(file.checksum)
    end
    return table.concat(lines, "\n--\n")
end

local function verify_user_app_integrity(id, app_dir)
    local encoded, err = read_all(combine(app_dir, APP_INTEGRITY_FILE))
    if not encoded then
        return false, "AppIntegrityMissing"
    end
    local metadata
    metadata, err = decode_integrity(encoded)
    if not metadata then
        return false, err
    end
    if metadata.format ~= "HyperCubeAppIntegrity" then
        return false, "AppIntegrityInvalid"
    end
    if tostring(metadata.app_id or "") ~= tostring(id or "") then
        return false, "AppIntegrityAppMismatch"
    end
    if not metadata.files or #metadata.files == 0 then
        return false, "AppIntegrityEmpty"
    end
    if checksum(integrity_body(metadata.files)) ~= tostring(metadata.checksum or "") then
        return false, "AppIntegrityChecksumMismatch"
    end
    for _, file in ipairs(metadata.files) do
        local path = safe_relative(file.path)
        if not path then
            return false, "AppIntegrityInvalidPath"
        end
        local data = read_all(combine(app_dir, path))
        if data == nil then
            return false, "AppFileMissing:" .. tostring(path)
        end
        if checksum(data) ~= tostring(file.checksum or "") then
            return false, "AppChecksumMismatch:" .. tostring(path)
        end
    end
    return true, metadata
end

local function app_dir_for_path(path)
    return tostring(path or ""):match("^(.*)/app%.lua$") or tostring(path or ""):match("^(.*)/[^/]+$")
end

local function scan_disk_root(root, apps, seen)
    if not fs or not fs.exists or not fs.list or not fs.exists(root) then
        return
    end
    for _, id in ipairs(fs.list(root)) do
        local app_dir = combine(root, id)
        local app_path = combine(app_dir, "app.lua")
        if fs.exists(app_path) then
            local key = safe_id(id)
            if key and not seen[key] then
                seen[key] = true
                apps[#apps + 1] = {
                    id = key,
                    path = app_path,
                }
            end
        end
    end
end

local function make_app_file_api(app_dir)
    return {
        read = function(path)
            path = safe_relative(path)
            if not path then
                return nil
            end
            return read_all(combine(app_dir, path))
        end,
        exists = function(path)
            path = safe_relative(path)
            return path and fs.exists(combine(app_dir, path)) == true
        end,
        list = function(path)
            path = tostring(path or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("^%./", ""):gsub("//+", "/")
            if path:find("..", 1, true) then
                return {}
            end
            local full = path == "" and app_dir or combine(app_dir, path)
            if fs.exists(full) and fs.isDir(full) then
                return fs.list(full)
            end
            return {}
        end,
    }
end

local loadfile_with_env

local function safe_env(api, app_dir)
    local module_cache = {}
    local env
    local function app_require(name)
        name = tostring(name or ""):gsub("%.", "/")
        local path, path_err = safe_relative(name .. ".lua")
        if not path then
            error(path_err or "InvalidModule", 2)
        end
        if module_cache[path] ~= nil then
            return module_cache[path]
        end
        local full = combine(app_dir, path)
        local loader, err = loadfile_with_env(full, env)
        if not loader then
            error(err or ("ModuleNotFound:" .. tostring(name)), 2)
        end
        module_cache[path] = true
        local ok, result = pcall(loader)
        if not ok then
            module_cache[path] = nil
            error(result, 2)
        end
        if result ~= nil then
            module_cache[path] = result
        end
        return module_cache[path]
    end

    api.app = api.app or make_app_file_api(app_dir)
    env = {
        _G = nil,
        HCAPI = api,
        require = app_require,
        assert = assert,
        error = error,
        ipairs = ipairs,
        next = next,
        pairs = pairs,
        pcall = pcall,
        select = select,
        tonumber = tonumber,
        tostring = tostring,
        type = type,
        unpack = unpack or table.unpack,
        math = math,
        string = string,
        table = table,
        coroutine = {
            create = coroutine.create,
            resume = coroutine.resume,
            running = coroutine.running,
            status = coroutine.status,
            wrap = coroutine.wrap,
            yield = coroutine.yield,
        },
        colors = colors,
        colours = colours,
        keys = keys,
    }
    env._G = env
    return env
end

function loadfile_with_env(path, env)
    local rom = rawget(_G, "HC_ROM")
    if rom and rom.load then
        local loader, err = rom.load(path, env)
        if loader then
            return loader
        end
        if err and err ~= "NotFound" then
            return nil, err
        end
    end

    local attempts = {
        { path, env },
        { path, "t", env },
        { path },
    }
    local unpack_args = unpack or table.unpack
    local last_err
    for _, args in ipairs(attempts) do
        local ok, loader, err = pcall(loadfile, unpack_args(args))
        if ok and loader then
            if setfenv then
                setfenv(loader, env)
            end
            return loader
        end
        last_err = ok and err or loader
    end
    return nil, last_err
end

function app_manager.scan()
    local apps = {}
    local seen = {}
    local rom = rawget(_G, "HC_ROM")
    if rom and rom.list_apps then
        for _, descriptor in ipairs(rom.list_apps()) do
            local key = safe_id(descriptor.id)
            if key and not seen[key] then
                seen[key] = true
                apps[#apps + 1] = descriptor
            end
        end
    end

    scan_disk_root(USER_APP_ROOT, apps, seen)
    scan_disk_root(APP_ROOT, apps, seen)

    table.sort(apps, function(a, b)
        local ao = app_order(a.id)
        local bo = app_order(b.id)
        if ao ~= bo then
            return ao < bo
        end
        return a.id < b.id
    end)
    return apps
end

function app_manager.load(tphone, descriptor)
    local api = hcapi.create(tphone, descriptor.id)
    local app_dir = app_dir_for_path(descriptor.path)
    if tostring(app_dir or ""):sub(1, #USER_APP_ROOT + 1) == USER_APP_ROOT .. "/" then
        local verified, verify_err = verify_user_app_integrity(descriptor.id, app_dir)
        if not verified then
            return nil, verify_err
        end
    end
    api.app = make_app_file_api(app_dir)
    local env = safe_env(api, app_dir)
    local loader, err = loadfile_with_env(descriptor.path, env)
    if not loader then
        return nil, err
    end

    local ok, app_or_err = pcall(loader)
    if not ok then
        return nil, app_or_err
    end
    if type(app_or_err) ~= "table" then
        return nil, "InvalidApp"
    end

    app_or_err.api = api
    local raw_manifest = app_or_err.manifest or {}
    app_or_err.manifest = copy_manifest(raw_manifest, descriptor.id, descriptor.path)
    app_or_err.manifest.dev_mode = raw_manifest.dev_mode == true or raw_manifest.requires_dev_mode == true
    return app_or_err
end

function app_manager.load_all(tphone)
    local apps = {}
    for _, descriptor in ipairs(app_manager.scan()) do
        local app, err = app_manager.load(tphone, descriptor)
        local hidden = false
        if app and app.manifest and app.manifest.dev_mode and not (tphone and tphone.dev_mode) then
            app = nil
            hidden = true
        end
        if app then
            apps[#apps + 1] = app
        elseif not hidden and tphone.logger then
            tphone.logger.warn("app load failed " .. tostring(descriptor.id) .. ": " .. tostring(err), tphone.root_context)
        end
    end
    return apps
end

local function decode_package_integrity(package)
    local encoded = package.integrity_encoded or package.encoded_integrity or package.app_integrity_encoded
    if type(encoded) == "string" and encoded ~= "" then
        return decode_integrity(encoded)
    end
    return nil, "AppIntegrityRequired"
end

local function verify_package_integrity(id, version, files, package)
    local metadata, err = decode_package_integrity(package)
    if not metadata then
        return nil, err
    end
    if metadata.format ~= "HyperCubeAppIntegrity" then
        return nil, "AppIntegrityInvalid"
    end
    if tostring(metadata.app_id or "") ~= tostring(id or "") then
        return nil, "AppIntegrityAppMismatch"
    end
    if checksum(integrity_body(metadata.files or {})) ~= tostring(metadata.checksum or "") then
        return nil, "AppIntegrityChecksumMismatch"
    end

    local by_path = {}
    for _, file in ipairs(files or {}) do
        by_path[file.path] = file.data or ""
    end
    local has_app_lua = false
    for _, file in ipairs(metadata.files or {}) do
        local path = safe_relative(file.path)
        if not path then
            return nil, "AppIntegrityInvalidPath"
        end
        if path == "app.lua" then
            has_app_lua = true
        end
        if by_path[path] == nil then
            return nil, "AppFileMissing:" .. tostring(path)
        end
        if checksum(by_path[path]) ~= tostring(file.checksum or "") then
            return nil, "AppChecksumMismatch:" .. tostring(path)
        end
    end
    if not has_app_lua then
        return nil, "AppIntegrityEntrypointMissing"
    end
    metadata.app_version = metadata.app_version or version
    return metadata
end

function app_manager.install(package)
    if type(package) ~= "table" then
        return false, "InvalidPackage"
    end
    local id, id_err = safe_id(package.id)
    if not id then
        return false, id_err
    end
    local source = package.source or package.app_lua or package.code
    local package_files = package.files
    if (type(source) ~= "string" or source == "") and type(package_files) ~= "table" then
        return false, "SourceRequired"
    end

    local install_files = {}
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
            install_files[#install_files + 1] = {
                path = path,
                data = tostring(data or ""),
            }
        end
    end

    if type(source) == "string" and source ~= "" and not has_app_lua then
        install_files[#install_files + 1] = {
            path = "app.lua",
            data = source,
        }
        has_app_lua = true
    end
    if not has_app_lua then
        return false, "EntrypointRequired"
    end

    table.sort(install_files, function(a, b)
        return a.path < b.path
    end)
    local integrity, integrity_err = verify_package_integrity(id, package.version, install_files, package)
    if not integrity then
        return false, integrity_err
    end
    local encoded_integrity
    encoded_integrity, integrity_err = encode_integrity(integrity)
    if not encoded_integrity then
        return false, integrity_err
    end

    local root_ok, root_err = ensure_dir(USER_APP_ROOT)
    if not root_ok then
        return false, root_err
    end

    local app_dir = combine(USER_APP_ROOT, id)
    if fs.exists(app_dir) then
        fs.delete(app_dir)
    end
    local ok, err = ensure_dir(app_dir)
    if not ok then
        return false, err
    end

    local written = 0
    for _, file in ipairs(install_files) do
        ok, err = write_all(combine(app_dir, file.path), file.data)
        if not ok then
            return false, err
        end
        written = written + 1
    end
    ok, err = write_all(combine(app_dir, APP_INTEGRITY_FILE), encoded_integrity)
    if not ok then
        return false, err
    end

    return true, {
        id = id,
        path = combine(app_dir, "app.lua"),
        version = package.version,
        files = written,
        protected_files = #(integrity.files or {}),
        mutable_paths = integrity.mutable_paths or {},
    }
end

return app_manager
