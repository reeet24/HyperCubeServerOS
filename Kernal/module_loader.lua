local module_loader = {
    modules = {},
    drivers = {},
}

local unpack_args = unpack or table.unpack

local function normalize_module_name(path)
    local name = path:gsub("%.lua$", ""):gsub("/", ".")
    return name
end

local function load_lua_file(path, env)
    if not loadfile then
        return nil, "loadfile unavailable"
    end

    local attempts
    if env then
        attempts = {
            { path, env },       -- ComputerCraft Tweaked
            { path, "t", env },  -- Lua 5.2+
            { path },           -- Lua 5.1 fallback, paired with setfenv below
        }
    else
        attempts = {
            { path },
        }
    end

    local last_err
    for _, args in ipairs(attempts) do
        local ok, loader, err = pcall(loadfile, unpack_args(args))
        if ok and loader then
            if env and setfenv then
                setfenv(loader, env)
            end
            return loader
        end
        last_err = ok and err or loader
    end

    return nil, last_err
end

local function exists(path)
    if fs and fs.exists then
        return fs.exists(path)
    end
    local file = io and io.open and io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

local function to_module_name(path)
    if fs and fs.combine then
        path = fs.combine("", path)
    end
    return normalize_module_name(path)
end

function module_loader.load_module(path, context, env)
    if type(path) ~= "string" or path == "" then
        return nil, "PathRequired"
    end

    local module_name = to_module_name(path)
    local ok, loaded = pcall(require, module_name)
    if not ok then
        local file_path = path
        if not file_path:match("%.lua$") and exists(file_path .. ".lua") then
            file_path = file_path .. ".lua"
        end
        local loader, err = load_lua_file(file_path, env)
        if not loader then
            return nil, loaded or err
        end
        ok, loaded = pcall(loader, context)
        if not ok then
            return nil, loaded
        end
    end

    local module = loaded == true and package.loaded[module_name] or loaded
    module_loader.modules[path] = {
        path = path,
        name = module_name,
        module = module,
        loaded_at = os.clock(),
    }
    return module
end

function module_loader.unload_module(path)
    local record = module_loader.modules[path]
    if not record then
        return false, "ModuleNotLoaded"
    end
    package.loaded[record.name] = nil
    module_loader.modules[path] = nil
    return true
end

function module_loader.reload_module(path, context, env)
    module_loader.unload_module(path)
    return module_loader.load_module(path, context, env)
end

function module_loader.init_driver(path, context)
    local driver, err = module_loader.load_module(path, context)
    if not driver then
        return nil, err
    end
    if type(driver.init) ~= "function" then
        return nil, "DriverMissingInit"
    end

    local ok, result = pcall(driver.init, context)
    if not ok then
        return nil, result
    end

    module_loader.drivers[path] = {
        path = path,
        driver = driver,
        state = result,
    }
    return result or driver
end

function module_loader.shutdown_driver(path)
    local record = module_loader.drivers[path]
    if not record then
        return false, "DriverNotLoaded"
    end
    if type(record.driver.shutdown) == "function" then
        local ok, err = pcall(record.driver.shutdown, record.state)
        if not ok then
            return false, err
        end
    end
    module_loader.drivers[path] = nil
    return true
end

function module_loader.autoload_drivers(context, folder)
    folder = folder or "Kernal/drivers"
    local loaded = {}

    if fs and fs.list then
        for _, file in ipairs(fs.list(folder)) do
            if file:match("%.lua$") then
                local path = folder .. "/" .. file
                loaded[path] = { module_loader.init_driver(path, context) }
            end
        end
    end

    return loaded
end

return module_loader
