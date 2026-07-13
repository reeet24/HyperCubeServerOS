local webserver = {}

local DedicatedWebServer = {}
DedicatedWebServer.__index = DedicatedWebServer

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function monotonic()
    return os.clock and os.clock() or 0
end

local function normalize_path(path)
    path = tostring(path or "/")
    path = path:gsub("\\", "/")
    path = path:gsub("//+", "/")
    if path == "" then
        path = "/"
    end
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    return path
end

local function request_id(message)
    return message and message.request_id or tostring(now())
end

function DedicatedWebServer.new(options)
    options = options or {}
    return setmetatable({
        network = options.network,
        identity = options.identity,
        logger = options.logger,
        domain = options.domain,
        title = options.title or "HyperCube Turtle",
        routes = {},
        registered = false,
        registered_domain = nil,
        next_register_at = 0,
        register_attempts = 0,
        register_retry_delay = options.register_retry_delay or 5,
        register_max_delay = options.register_max_delay or 300,
        last_error = nil,
        request_count = 0,
    }, DedicatedWebServer)
end

function DedicatedWebServer:set_domain(domain, title)
    local previous_domain = self.domain
    local previous_title = self.title
    self.domain = tostring(domain or "")
    if title then
        self.title = title
    end
    if self.domain ~= previous_domain or self.title ~= previous_title then
        self.registered = false
        self.registered_domain = nil
        self.next_register_at = 0
        self.register_attempts = 0
    end
end

function DedicatedWebServer:log(level, message)
    if self.logger and self.logger[level] then
        self.logger[level]("webserver " .. tostring(message))
    end
end

function DedicatedWebServer:register()
    if not self.network then
        return false, "NetworkUnavailable"
    end
    if not self.domain or self.domain == "" then
        return false, "DomainRequired"
    end
    if self.registered and self.registered_domain == self.domain then
        return true, {
            domain = self.domain,
            cached = true,
        }
    end

    local clock = monotonic()
    if clock < (self.next_register_at or 0) then
        return false, "RegisterBackoff"
    end

    local reply, err = self.network:request({
        type = "web.register",
        domain = self.domain,
        title = self.title,
        origin = true,
        origin_label = os.getComputerLabel and os.getComputerLabel() or "HyperCube Turtle",
        supports_api = true,
    }, "web.register.result", 8)
    if reply and reply.ok then
        self.registered = true
        self.registered_domain = self.domain
        self.register_attempts = 0
        self.next_register_at = 0
        self.last_error = nil
        self:log("info", "registered domain=" .. tostring(self.domain))
        return true, reply.result
    end
    self.last_error = (reply and reply.error) or err or "RegisterFailed"
    self.register_attempts = (self.register_attempts or 0) + 1
    local delay = math.min(self.register_max_delay, self.register_retry_delay * (2 ^ math.min(self.register_attempts - 1, 6)))
    if self.last_error == "AccountNotFound" or self.last_error == "AuthRequired" or tostring(self.last_error):match("^ScopeDenied") then
        delay = math.max(delay, 60)
    end
    self.next_register_at = clock + delay
    self:log("warn", "register failed " .. tostring(self.last_error))
    return false, self.last_error
end

function DedicatedWebServer:page(path, hctml, options)
    path = normalize_path(path)
    options = options or {}
    self.routes[path] = {
        kind = "page",
        hctml = tostring(hctml or ""),
        status = options.status or 200,
        headers = options.headers,
    }
    return true
end

function DedicatedWebServer:api(path, handler)
    if type(handler) ~= "function" then
        return false, "HandlerRequired"
    end
    self.routes[normalize_path(path)] = {
        kind = "api",
        handler = handler,
    }
    return true
end

function DedicatedWebServer:handle(path, handler)
    return self:api(path, handler)
end

function DedicatedWebServer:default_response(route)
    local body = "<page title=\"" .. tostring(self.title) .. "\"><h1>" .. tostring(self.title) .. "</h1><p>HyperCube turtle webserver online.</p></page>"
    return {
        ok = true,
        status = 200,
        content_type = "hctml",
        body = body,
    }
end

function DedicatedWebServer:dispatch(message)
    local path = normalize_path(message.path or "/")
    local route = self.routes[path] or self.routes["*"]
    self.request_count = self.request_count + 1

    if not route then
        if path == "/" then
            return self:default_response(message)
        end
        return {
            ok = false,
            status = 404,
            error = "NotFound",
        }
    end

    if route.kind == "page" then
        return {
            ok = true,
            status = route.status or 200,
            content_type = "hctml",
            headers = route.headers,
            body = route.hctml,
        }
    end

    local ok, result = pcall(route.handler, {
        domain = message.domain,
        path = path,
        method = message.method or "GET",
        headers = message.headers,
        query = message.query,
        body = message.body,
        api = message.api == true,
        raw = message,
    })
    if not ok then
        return {
            ok = false,
            status = 500,
            error = tostring(result),
        }
    end
    if type(result) ~= "table" then
        result = {
            body = tostring(result or ""),
        }
    end
    result.ok = result.ok ~= false
    result.status = result.status or 200
    result.content_type = result.content_type or result.kind or "hctml"
    return result
end

function DedicatedWebServer:poll(timeout)
    if not self.network then
        return nil, "NetworkUnavailable"
    end
    local ok, err = self.network:open()
    if not ok then
        return nil, err
    end
    if (not self.registered or self.registered_domain ~= self.domain) and self.domain and self.domain ~= "" then
        self:register()
    end

    local sender, message = rednet.receive(self.network.protocol, timeout or 0.1)
    if not sender then
        return nil, "NoMessage"
    end
    if type(message) ~= "table" or message.type ~= "web.origin.request" then
        return nil, "Ignored"
    end

    local response = self:dispatch(message)
    rednet.send(sender, {
        type = "web.origin.response",
        request_id = request_id(message),
        ok = response.ok == true,
        status = response.status,
        content_type = response.content_type,
        kind = response.kind,
        headers = response.headers,
        body = response.body,
        hctml = response.hctml,
        error = response.error,
        time = now(),
    }, self.network.protocol)
    return true, response
end

function DedicatedWebServer:summary()
    return {
        domain = self.domain,
        title = self.title,
        registered = self.registered,
        routes = self.routes,
        request_count = self.request_count,
        last_error = self.last_error,
        next_register_at = self.next_register_at,
        register_attempts = self.register_attempts,
    }
end

function webserver.new(options)
    return DedicatedWebServer.new(options)
end

webserver.DedicatedWebServer = DedicatedWebServer

return webserver
