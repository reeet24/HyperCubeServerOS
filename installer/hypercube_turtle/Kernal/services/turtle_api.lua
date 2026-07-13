local hcapi = require("Kernal.services.hcapi")

local turtle_api = {}

local C = {
    black = colors and colors.black or 32768,
    white = colors and colors.white or 1,
    gray = colors and colors.gray or 128,
    lightGray = colors and colors.lightGray or 256,
    blue = colors and colors.blue or 2048,
    cyan = colors and colors.cyan or 8192,
    green = colors and colors.green or 32,
    red = colors and colors.red or 16384,
    yellow = colors and colors.yellow or 16,
    purple = colors and colors.purple or 1024,
    orange = colors and colors.orange or 2,
}

local function normalize_path(path)
    path = tostring(path or "/")
    path = path:gsub("\\", "/")
    path = path:gsub("[^%w%._%-%/]", "")
    path = path:gsub("//+", "/")
    if path == "" then
        path = "/"
    end
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    return path
end

local function app_path(app_id, path)
    app_id = tostring(app_id or "app"):gsub("[^%w_%-%.]", "_")
    return "/turtle_apps/" .. app_id .. normalize_path(path)
end

local function make_fs_api(user_fs, app_id)
    return {
        read = function(path)
            return user_fs:read(app_path(app_id, path))
        end,
        write = function(path, data)
            return user_fs:write(app_path(app_id, path), data)
        end,
        list = function(path)
            return user_fs:list(app_path(app_id, path))
        end,
        exists = function(path)
            return user_fs:exists(app_path(app_id, path))
        end,
        delete = function(path)
            return user_fs:delete(app_path(app_id, path))
        end,
    }
end

local function attach_identity(runtime, message)
    message = message or {}
    if runtime.identity then
        message.tesserac_id = message.tesserac_id or runtime.identity.tesserac_id
        message.username = message.username or runtime.identity.username
        message.session_token = message.session_token or runtime.identity.session_token
    end
    return message
end

local function make_net_api(runtime)
    return {
        send = function(message)
            if not runtime.network then
                return false, "NetworkUnavailable"
            end
            return runtime.network:send(attach_identity(runtime, message))
        end,
        request = function(message, expected_type, timeout)
            if not runtime.network then
                return nil, "NetworkUnavailable"
            end
            return runtime.network:request(attach_identity(runtime, message), expected_type, timeout or 8)
        end,
    }
end

local function make_turtle_api(driver)
    local function unavailable()
        return false, "TurtleUnavailable"
    end
    local function call(method, ...)
        if not driver then
            return unavailable()
        end
        return driver[method](driver, ...)
    end
    return {
        status = function()
            if not driver then return nil, "TurtleUnavailable" end
            return driver:status()
        end,
        inventory = function()
            if not driver then return nil, "TurtleUnavailable" end
            return driver:inventory()
        end,
        fuel = function()
            if not driver then return nil, "TurtleUnavailable" end
            return driver:fuel()
        end,
        select = function(slot) return call("select", slot) end,
        refuel = function(count) return call("refuel", count) end,
        forward = function() return call("forward") end,
        back = function() return call("back") end,
        up = function() return call("up") end,
        down = function() return call("down") end,
        turn_left = function() return call("turn_left") end,
        turn_right = function() return call("turn_right") end,
        dig = function() return call("dig") end,
        dig_up = function() return call("dig_up") end,
        dig_down = function() return call("dig_down") end,
        place = function() return call("place") end,
        place_up = function() return call("place_up") end,
        place_down = function() return call("place_down") end,
        detect = function() return call("detect") end,
        detect_up = function() return call("detect_up") end,
        detect_down = function() return call("detect_down") end,
        suck = function(count) return call("suck", count) end,
        drop = function(count) return call("drop", count) end,
    }
end

local function make_web_api(runtime)
    return {
        set_domain = function(domain, title)
            if not runtime.webserver then
                return false, "WebServerUnavailable"
            end
            runtime.webserver:set_domain(domain, title)
            return runtime.webserver:register()
        end,
        page = function(path, hctml, options)
            if not runtime.webserver then
                return false, "WebServerUnavailable"
            end
            return runtime.webserver:page(path, hctml, options)
        end,
        api = function(path, handler)
            if not runtime.webserver then
                return false, "WebServerUnavailable"
            end
            return runtime.webserver:api(path, handler)
        end,
        handle = function(path, handler)
            if not runtime.webserver then
                return false, "WebServerUnavailable"
            end
            return runtime.webserver:handle(path, handler)
        end,
        status = function()
            return runtime.webserver and runtime.webserver:summary() or nil
        end,
    }
end

function turtle_api.create(runtime, app_id)
    if not runtime.hcfs then
        runtime.hcfs = hcapi.UserFS.new(runtime.identity or {})
    end
    return {
        app_id = app_id,
        identity = {
            tesserac_id = runtime.identity and runtime.identity.tesserac_id or nil,
            username = runtime.identity and runtime.identity.username or nil,
            display_name = runtime.identity and runtime.identity.display_name or nil,
        },
        fs = make_fs_api(runtime.hcfs, app_id),
        hypernet = make_net_api(runtime),
        turtle = make_turtle_api(runtime.turtle),
        web = make_web_api(runtime),
        colors = C,
        log = function(message)
            if runtime.logger then
                runtime.logger.info("app " .. tostring(app_id) .. " " .. tostring(message), runtime.root_context)
            end
        end,
        time = function()
            if os.epoch then
                return os.epoch("utc")
            end
            return math.floor(os.clock() * 1000)
        end,
    }
end

return turtle_api
