local turtle_api = require("Kernal.services.turtle_api")

local app_manager = {}

local APP_ROOT = "apps"
local USER_APP_ROOT = "user/apps"

local function combine(a, b)
    if fs and fs.combine then
        return fs.combine(a, b)
    end
    if a:sub(-1) == "/" then
        return a .. b
    end
    return a .. "/" .. b
end

local function safe_id(id)
    id = tostring(id or ""):lower():gsub("%s+", "")
    id = id:gsub("[^%w_%-%.]", "_")
    if id == "" then
        return nil
    end
    return id
end

local function scan_root(root, apps, seen)
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

local function safe_env(api)
    local env = {
        _G = nil,
        HCAPI = api,
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
    }
    env._G = env
    return env
end

local function loadfile_with_env(path, env)
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
    scan_root(USER_APP_ROOT, apps, seen)
    scan_root(APP_ROOT, apps, seen)
    table.sort(apps, function(a, b) return a.id < b.id end)
    return apps
end

function app_manager.load(runtime, descriptor)
    local api = turtle_api.create(runtime, descriptor.id)
    local env = safe_env(api)
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
    app_or_err.id = descriptor.id
    app_or_err.path = descriptor.path
    return app_or_err
end

function app_manager.load_all(runtime)
    local loaded = {}
    for _, descriptor in ipairs(app_manager.scan()) do
        local app, err = app_manager.load(runtime, descriptor)
        if app then
            loaded[#loaded + 1] = app
        elseif runtime.logger then
            runtime.logger.warn("turtle app load failed " .. tostring(descriptor.id) .. ": " .. tostring(err), runtime.root_context)
        end
    end
    return loaded
end

function app_manager.start_all(runtime, apps)
    apps = apps or app_manager.load_all(runtime)
    for _, app in ipairs(apps) do
        if type(app.start) == "function" then
            local ok, err = pcall(app.start, app.api)
            if not ok and runtime.logger then
                runtime.logger.warn("turtle app start failed " .. tostring(app.id) .. ": " .. tostring(err), runtime.root_context)
            end
        end
    end
    return apps
end

function app_manager.tick_all(runtime, apps)
    for _, app in ipairs(apps or {}) do
        if type(app.tick) == "function" then
            local ok, err = pcall(app.tick, app.api)
            if not ok and runtime.logger then
                runtime.logger.warn("turtle app tick failed " .. tostring(app.id) .. ": " .. tostring(err), runtime.root_context)
            end
        end
    end
end

return app_manager
