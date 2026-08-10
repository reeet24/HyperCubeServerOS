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

local function safe_protocol(protocol, system)
    protocol = tostring(protocol or ""):gsub("^%s*(.-)%s*$", "%1")
    if protocol == "" then
        return nil, "ProtocolRequired"
    end
    if #protocol > 64 or protocol:find("[%z\1-\31\127]") then
        return nil, "InvalidProtocol"
    end
    local reserved = system and system.network and system.network.protocol or "tesserac"
    if protocol == reserved then
        return nil, "ReservedProtocol"
    end
    return protocol
end

local function safe_hostname(hostname, fallback)
    hostname = tostring(hostname or fallback or ""):gsub("^%s*(.-)%s*$", "%1")
    hostname = hostname:gsub("[^%w_%-%.:]", "_")
    if hostname == "" then
        return fallback or "user-service"
    end
    return hostname:sub(1, 64)
end

local function ensure_rednet(system)
    if not rednet then
        return false, "RednetUnavailable"
    end
    if system and system.network and system.network.open then
        return system.network:open()
    end
    return false, "NetworkUnavailable"
end

local function make_rednet(system, service_id)
    local api = {}
    local hosted = {}

    function api.host(protocol, hostname)
        local protocol_err
        protocol, protocol_err = safe_protocol(protocol, system)
        if not protocol then
            return false, protocol_err
        end
        local ok, err = ensure_rednet(system)
        if not ok then
            return false, err
        end
        hostname = safe_hostname(hostname, "hc-" .. tostring(service_id or "service"))
        if rednet.host then
            rednet.host(protocol, hostname)
        end
        hosted[protocol] = hostname
        return true, {
            protocol = protocol,
            hostname = hostname,
        }
    end

    function api.unhost(protocol, hostname)
        local protocol_err
        protocol, protocol_err = safe_protocol(protocol, system)
        if not protocol then
            return false, protocol_err
        end
        hostname = hostname and safe_hostname(hostname) or hosted[protocol]
        if rednet.unhost then
            if not hostname then
                return false, "HostnameRequired"
            end
            rednet.unhost(protocol, hostname)
        end
        hosted[protocol] = nil
        return true
    end

    function api.send(target, message, protocol)
        local protocol_err
        protocol, protocol_err = safe_protocol(protocol, system)
        if not protocol then
            return false, protocol_err
        end
        target = tonumber(target)
        if not target then
            return false, "InvalidTarget"
        end
        local ok, err = ensure_rednet(system)
        if not ok then
            return false, err
        end
        rednet.send(target, message, protocol)
        return true
    end

    function api.broadcast(message, protocol)
        local protocol_err
        protocol, protocol_err = safe_protocol(protocol, system)
        if not protocol then
            return false, protocol_err
        end
        local ok, err = ensure_rednet(system)
        if not ok then
            return false, err
        end
        rednet.broadcast(message, protocol)
        return true
    end

    function api.receive(protocol, timeout)
        local protocol_err
        protocol, protocol_err = safe_protocol(protocol, system)
        if not protocol then
            return nil, protocol_err
        end
        local ok, err = ensure_rednet(system)
        if not ok then
            return nil, err
        end
        timeout = tonumber(timeout)
        if timeout == nil then
            timeout = 0.05
        end
        timeout = math.max(0, math.min(timeout, 5))
        local packet = coroutine.yield("wait_rednet", {
            protocol = protocol,
            timeout = timeout,
        })
        if not packet then
            return nil, "NoMessage"
        end
        return packet
    end

    function api.lookup(protocol, hostname)
        local protocol_err
        protocol, protocol_err = safe_protocol(protocol, system)
        if not protocol then
            return nil, protocol_err
        end
        local ok, err = ensure_rednet(system)
        if not ok then
            return nil, err
        end
        if not rednet.lookup then
            return nil, "LookupUnavailable"
        end
        return rednet.lookup(protocol, hostname)
    end

    function api.summary()
        local protocols = {}
        for protocol, hostname in pairs(hosted) do
            protocols[#protocols + 1] = {
                protocol = protocol,
                hostname = hostname,
            }
        end
        table.sort(protocols, function(a, b)
            return a.protocol < b.protocol
        end)
        return {
            side = system and system.network and system.network.side or nil,
            protocols = protocols,
        }
    end

    return api
end

function user_service_api.create(system, service_id)
    local api = {}
    local id = tostring(service_id or "service")
    api.colors = colors or {}
    api.colours = colours or colors or {}
    api.identity = system.identity
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
    api.rednet = make_rednet(system, id)
    api.localnet = api.rednet

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
