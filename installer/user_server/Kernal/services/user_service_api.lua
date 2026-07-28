local user_service_api = {}

local function combine(a, b)
    if fs and fs.combine then
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

local function safe_relative(path, allow_empty)
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("^/+", ""):gsub("^%./", ""):gsub("//+", "/")
    if path == "" and allow_empty then
        return ""
    end
    if path == "" or path:find("..", 1, true) then
        return nil, "InvalidPath"
    end
    return path
end

local function ensure_dir(path)
    local dir = tostring(path):match("^(.*)/[^/]+$")
    if dir and dir ~= "" and fs and fs.exists and fs.makeDir and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function make_fs(root)
    root = tostring(root or "user_services_data")
    if fs and fs.exists and fs.makeDir and not fs.exists(root) then
        fs.makeDir(root)
    end
    local api = {}

    function api.path(path, allow_empty)
        local safe, err = safe_relative(path, allow_empty)
        if not safe then
            return nil, err
        end
        if safe == "" then
            return root
        end
        return combine(root, safe)
    end

    function api.read(path)
        local full, err = api.path(path)
        if not full then
            return nil, err
        end
        if not fs.exists(full) then
            return nil, "NotFound"
        end
        local handle = fs.open(full, "r")
        if not handle then
            return nil, "OpenFailed"
        end
        local data = handle.readAll()
        handle.close()
        return data
    end

    function api.write(path, data)
        local full, err = api.path(path)
        if not full then
            return false, err
        end
        ensure_dir(full)
        local handle = fs.open(full, "w")
        if not handle then
            return false, "OpenFailed"
        end
        handle.write(tostring(data or ""))
        handle.close()
        return true
    end

    function api.list(path)
        local full, err = api.path(path or "", true)
        if not full then
            return {}, err
        end
        if not fs.exists(full) or not fs.isDir(full) then
            return {}
        end
        return fs.list(full)
    end

    function api.exists(path)
        local full = api.path(path)
        return full and fs.exists(full) or false
    end

    return api
end

function user_service_api.create(system, service_id)
    local api = {}
    local id = tostring(service_id or "service")
    api.colors = colors or {}
    api.colours = colours or colors or {}
    api.fs = make_fs(combine("user_services_data", id))
    api.state = system.service_state[id] or {}
    system.service_state[id] = api.state

    api.log = {
        info = function(message)
            if system.logger then
                system.logger.info("service " .. id .. ": " .. tostring(message), system.root_context)
            end
        end,
        warn = function(message)
            if system.logger then
                system.logger.warn("service " .. id .. ": " .. tostring(message), system.root_context)
            end
        end,
    }

    api.net = {
        send = function(message)
            if not system.network or not system.network.send then
                return false, "NetworkUnavailable"
            end
            return system.network:send(message)
        end,
        request = function(message, expected, timeout)
            if not system.network or not system.network.request then
                return nil, "NetworkUnavailable"
            end
            return system.network:request(message, expected, timeout or 5)
        end,
    }

    api.screen = {
        write = function(x, y, text, fg, bg)
            if not system.screen then
                return false, "ScreenUnavailable"
            end
            system.screen:write(x, y, tostring(text or ""), fg, bg)
            return true
        end,
        clear = function(bg)
            if not system.screen then
                return false, "ScreenUnavailable"
            end
            system.screen:clear(bg)
            return true
        end,
        size = function()
            if not system.screen then
                return 0, 0
            end
            return system.screen:get_size()
        end,
        button = function(id, x, y, width, label, options)
            if not system.screen or not system.screen.button then
                return nil, "ScreenUnavailable"
            end
            return system.screen:button(id, x, y, width, label, options)
        end,
    }

    return api
end

return user_service_api
