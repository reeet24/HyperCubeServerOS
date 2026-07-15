local RednetDriver = {}
RednetDriver.__index = RednetDriver

local tesseracid = require("Kernal.services.tesseracid")
local hctml = require("Kernal.services.hctml")

local DEFAULT_PROTOCOL = "tesserac"
local DEFAULT_SERVER_HOSTS = {
    "HyperCubeServer",
    "TesseracServer",
    "tesserac-server",
}

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function find_modem_side()
    local fallback = nil

    if peripheral and peripheral.getNames and peripheral.getType then
        for _, side in ipairs(peripheral.getNames()) do
            if peripheral.getType(side) == "modem" then
                local modem = peripheral.wrap and peripheral.wrap(side) or nil
                if modem and modem.isWireless and modem.isWireless() then
                    return side
                end
                fallback = fallback or side
            end
        end
    end

    for _, side in ipairs({ "back", "top", "bottom", "left", "right", "front" }) do
        if peripheral and peripheral.getType and peripheral.getType(side) == "modem" then
            local modem = peripheral.wrap and peripheral.wrap(side) or nil
            if modem and modem.isWireless and modem.isWireless() then
                return side
            end
            fallback = fallback or side
        end
    end

    return fallback
end

local function copy_list(list)
    local out = {}
    for i, value in ipairs(list or {}) do
        out[i] = value
    end
    return out
end

local function message_type(message)
    if type(message) == "table" then
        return tostring(message.type or "table")
    end
    return type(message)
end

local function log_event(self, level, message)
    if not self or not self.verbose then
        return
    end
    level = level or "debug"
    local line = "rednet " .. tostring(message)
    self.logs[#self.logs + 1] = {
        time = now(),
        level = level,
        message = line,
    }
    while #self.logs > self.max_logs do
        table.remove(self.logs, 1)
    end
    if self.logger and self.logger[level] then
        self.logger[level](line)
    end
end

local function attach_identity(self, message)
    if type(message) == "table" and self.identity then
        message.tesserac_id = message.tesserac_id or self.identity.tesserac_id
        message.username = message.username or self.identity.username
        message.session_token = message.session_token or self.identity.session_token
        message.device_id = message.device_id or (self.identity.device and self.identity.device.device_id)
    end
    return message
end

local function scoped_key(sender, message, clients)
    local tesserac_id = message.tesserac_id or (clients[sender] and clients[sender].tesserac_id)
    if not tesserac_id then
        return nil, "AuthRequired"
    end
    return "service:" .. tostring(tesserac_id) .. ":" .. tostring(message.key)
end

local function accept_server_announce(self, sender, message, source)
    if type(message) ~= "table" or message.type ~= "server.announce" then
        return false
    end

    self.server_id = sender
    self.status = "connected"
    self.last_seen = now()
    log_event(self, "info", tostring(source or "announce") .. " connected server=" .. tostring(sender) .. " name=" .. tostring(message.server))
    return true, sender
end

local function wait_for_announce(self, timeout)
    timeout = timeout or 0.25
    local deadline = os.clock() + timeout
    while os.clock() < deadline do
        local sender, message = rednet.receive(self.protocol, math.max(0.05, deadline - os.clock()))
        local ok, id = accept_server_announce(self, sender, message, "announce")
        if ok then
            return true, id
        end
        if sender then
            log_event(self, "debug", "ignored discovery message type=" .. message_type(message) .. " sender=" .. tostring(sender))
        end
    end
    return false, "NoAnnounce"
end

local function message_identity(sender, message, clients)
    return message.tesserac_id or (clients and clients[sender] and clients[sender].tesserac_id)
end

local function message_username(sender, message, clients)
    return message.username or (clients and clients[sender] and clients[sender].username)
end

local function session_identity(sender, message, clients)
    local client = clients and clients[sender] or {}
    return {
        tesserac_id = message.tesserac_id or client.tesserac_id,
        session_token = message.session_token or client.session_token,
        device_id = message.device_id or client.device_id,
    }
end

local function require_device_scope(self, sender, message, scope)
    if not self.database then
        return false, "DatabaseUnavailable"
    end
    local identity = session_identity(sender, message, self.clients)
    local device_record = nil
    if (not identity.tesserac_id or identity.tesserac_id == "") and identity.device_id then
        device_record = self.database:get("device:" .. tostring(identity.device_id))
        if type(device_record) == "table" and device_record.owner then
            identity.tesserac_id = device_record.owner
        end
    end
    local ok, result = tesseracid.validate_session(self.database, identity.tesserac_id, identity.session_token, scope)
    if not ok and result == "AccountNotFound" and identity.device_id then
        device_record = device_record or self.database:get("device:" .. tostring(identity.device_id))
        if type(device_record) == "table" and device_record.owner and device_record.owner ~= identity.tesserac_id then
            identity.tesserac_id = device_record.owner
            ok, result = tesseracid.validate_session(self.database, identity.tesserac_id, identity.session_token, scope)
        end
    end
    if not ok and result == "AccountNotFound" and type(device_record) == "table" then
        local token_ok = tostring(device_record.session_token or "") == tostring(identity.session_token or "")
        local owner_ok = tostring(device_record.owner or "") == tostring(identity.tesserac_id or "")
        local scope_ok = not scope or tesseracid.device_has_scope(device_record, scope)
        if token_ok and owner_ok and scope_ok then
            ok = true
            result = {
                account = {
                    tesserac_id = device_record.owner,
                    username = device_record.username,
                    display_name = device_record.username,
                },
                session = {
                    token = identity.session_token,
                    device_id = device_record.device_id,
                    scopes = device_record.scopes,
                },
                device = device_record,
            }
            if self.logger and self.logger.warn then
                self.logger.warn("scope recovered from device record sender=" .. tostring(sender)
                    .. " scope=" .. tostring(scope)
                    .. " tid=" .. tostring(identity.tesserac_id)
                    .. " device=" .. tostring(identity.device_id))
            end
        end
    end
    if not ok then
        local line = "scope denied sender=" .. tostring(sender)
            .. " scope=" .. tostring(scope)
            .. " tid=" .. tostring(identity.tesserac_id)
            .. " device=" .. tostring(identity.device_id)
            .. " error=" .. tostring(result)
        if self.logger and self.logger.warn then
            self.logger.warn(line)
        else
            log_event(self, "warn", line)
        end
        return false, result
    end
    self.clients[sender] = self.clients[sender] or { id = sender }
    self.clients[sender].tesserac_id = result.account and result.account.tesserac_id or identity.tesserac_id
    self.clients[sender].username = result.account and result.account.username or self.clients[sender].username
    self.clients[sender].session_token = identity.session_token
    self.clients[sender].account = result.account
    self.clients[sender].device = result.device
    self.clients[sender].device_id = result.device and result.device.device_id or nil
    return true, result
end

local function reply_web(sender, protocol, response_type, ok, result)
    local response = {
        type = response_type,
        ok = ok == true,
    }

    if ok then
        response.result = result
    else
        response.error = result
    end

    rednet.send(sender, response, protocol)
end

local function reply_service(sender, protocol, response_type, ok, result)
    local response = {
        type = response_type,
        ok = ok == true,
    }
    if ok then
        response.result = result
    else
        response.error = result
    end
    rednet.send(sender, response, protocol)
end

local function request_id(sender)
    return tostring(sender) .. ":" .. tostring(now()) .. ":" .. tostring(math.floor((os.clock() or 0) * 1000))
end

local function phone_rom_integrity(self, message)
    local device = tostring(message.device or "TPhone")
    if tostring(message.role or "") ~= "phone" and device ~= "TPhone" and device ~= "TBusinessPhone" then
        return true
    end

    local expected = self.expected_rom_checksums and self.expected_rom_checksums[device] or self.expected_phone_rom_checksum
    if not expected or expected == "" then
        return false, "ServerROMChecksumUnavailable"
    end

    local actual = tostring(message.rom_checksum or "")
    if actual == "" then
        return false, "MissingROMChecksum"
    end
    if actual ~= tostring(expected) then
        return false, "ROMChecksumMismatch"
    end
    return true
end

local function client_allowed(self, sender)
    local client = self.clients and self.clients[sender]
    return client and client.integrity_ok == true
end

local function reject_main_server(sender, protocol, reason)
    rednet.send(sender, {
        type = "server.reject",
        ok = false,
        error = reason or "ROMIntegrityRequired",
        time = now(),
    }, protocol)
end

local function is_update_message(message)
    return type(message) == "table"
        and type(message.type) == "string"
        and message.type:sub(1, 7) == "update."
end

local function normalize_domain_name(domain)
    domain = tostring(domain or ""):lower():gsub("%s+", "")
    domain = domain:gsub("^hyper://", ""):gsub("^hc://", ""):gsub("^hcm://", "")
    domain = domain:gsub("/.*$", "")
    return domain
end

local function public_web_result(page)
    if not page then
        return nil
    end
    return {
        domain = page.domain,
        path = page.path,
        title = page.rendered and page.rendered.title or page.title,
        rendered = page.rendered,
        content_type = page.content_type,
        body = page.body,
        headers = page.headers,
        status = page.status,
        updated_at = page.updated_at,
        routed = page.routed == true,
    }
end

local function compile_origin_response(domain, path, response)
    if not response.ok then
        return false, response.error or "OriginError"
    end

    local content_type = response.content_type or response.kind or "hctml"
    local page = {
        domain = domain,
        path = path,
        routed = true,
        content_type = content_type,
        status = response.status or 200,
        headers = response.headers,
        body = response.body,
        updated_at = now(),
    }

    if content_type == "hctml" or content_type == "hcml" or response.hctml then
        local source = response.hctml or response.body or ""
        local compiled, err = hctml.compile(source)
        if not compiled then
            return false, err
        end
        page.hctml = source
        page.ast = compiled.ast
        page.rendered = compiled.rendered
        page.title = compiled.rendered.title
    end

    return true, page
end

local function route_origin_request(self, origin_id, route)
    if not origin_id then
        log_event(self, "warn", "origin route failed OriginUnavailable domain=" .. tostring(route and route.domain))
        return false, "OriginUnavailable"
    end

    local id = request_id(origin_id)
    local deferred = {}
    log_event(self, "debug", "origin request id=" .. tostring(id) .. " origin=" .. tostring(origin_id) .. " domain=" .. tostring(route.domain) .. " path=" .. tostring(route.path or "/"))
    rednet.send(origin_id, {
        type = "web.origin.request",
        request_id = id,
        domain = route.domain,
        path = route.path or "/",
        method = route.method or "GET",
        headers = route.headers,
        query = route.query,
        body = route.body,
        api = route.api == true,
    }, self.protocol)

    local deadline = os.clock() + (route.timeout or 6)
    while os.clock() < deadline do
        local sender, response, protocol = rednet.receive(self.protocol, math.max(0.05, deadline - os.clock()))
        if sender == origin_id and type(response) == "table" and response.type == "web.origin.response" and response.request_id == id then
            log_event(self, "debug", "origin response id=" .. tostring(id) .. " origin=" .. tostring(origin_id) .. " ok=" .. tostring(response.ok == true))
            for _, event in ipairs(deferred) do
                if os.queueEvent then
                    os.queueEvent("rednet_message", event.sender, event.message, event.protocol or self.protocol)
                end
            end
            return compile_origin_response(route.domain, route.path or "/", response)
        elseif sender then
            log_event(self, "debug", "deferred while waiting origin sender=" .. tostring(sender) .. " type=" .. message_type(response))
            deferred[#deferred + 1] = {
                sender = sender,
                message = response,
                protocol = protocol,
            }
        end
    end

    for _, event in ipairs(deferred) do
        if os.queueEvent then
            os.queueEvent("rednet_message", event.sender, event.message, event.protocol or self.protocol)
        end
    end
    log_event(self, "warn", "origin timeout id=" .. tostring(id) .. " origin=" .. tostring(origin_id))
    return false, "OriginTimeout"
end

function RednetDriver.new(options)
    options = options or {}
    local self = setmetatable({}, RednetDriver)

    self.mode = options.mode or "client"
    self.protocol = options.protocol or DEFAULT_PROTOCOL
    self.hostname = options.hostname or (self.mode == "server" and "HyperCubeServer" or "HyperCubePhone")
    self.server_hosts = copy_list(options.server_hosts or DEFAULT_SERVER_HOSTS)
    self.side = options.side
    self.status = "offline"
    self.server_id = nil
    self.clients = {}
    self.handlers = {}
    self.identity = options.identity
    self.last_error = nil
    self.last_seen = nil
    self.verbose = options.verbose ~= false
    self.logger = options.logger
    self.logs = {}
    self.max_logs = options.max_logs or 150
    self.expected_phone_rom_checksum = options.expected_phone_rom_checksum
    self.expected_rom_checksums = options.expected_rom_checksums or {}

    log_event(self, "debug", "driver created mode=" .. tostring(self.mode) .. " host=" .. tostring(self.hostname))

    return self
end

function RednetDriver:register_handler(name, handler)
    if type(name) ~= "string" or name == "" then
        return false, "NameRequired"
    end
    if type(handler) ~= "function" then
        return false, "HandlerRequired"
    end
    self.handlers[name] = handler
    log_event(self, "info", "registered handler=" .. tostring(name))
    return true
end

function RednetDriver:unregister_handler(name)
    self.handlers[name] = nil
    log_event(self, "info", "unregistered handler=" .. tostring(name))
    return true
end

function RednetDriver:dispatch_handlers(sender, message)
    for name, handler in pairs(self.handlers or {}) do
        local ok, consumed_or_err = pcall(handler, self, sender, message)
        if not ok then
            log_event(self, "warn", "handler failed name=" .. tostring(name) .. " error=" .. tostring(consumed_or_err))
        elseif consumed_or_err == true then
            log_event(self, "debug", "handler consumed name=" .. tostring(name) .. " type=" .. message_type(message))
            return true
        end
    end
    return false
end

function RednetDriver:open()
    if not rednet then
        self.status = "offline"
        self.last_error = "RednetUnavailable"
        log_event(self, "warn", "open failed RednetUnavailable")
        return false, self.last_error
    end

    local side = self.side or find_modem_side()
    if not side then
        self.status = "offline"
        self.last_error = "ModemNotFound"
        log_event(self, "warn", "open failed ModemNotFound")
        return false, self.last_error
    end

    if not rednet.isOpen(side) then
        rednet.open(side)
        log_event(self, "info", "opened modem side=" .. tostring(side))
    end

    self.side = side
    self.status = "online"
    log_event(self, "debug", "open ok side=" .. tostring(side))
    return true
end

function RednetDriver:host()
    local ok, err = self:open()
    if not ok then
        return false, err
    end

    if rednet.host then
        rednet.host(self.protocol, self.hostname)
        log_event(self, "info", "hosting protocol=" .. tostring(self.protocol) .. " hostname=" .. tostring(self.hostname))
    else
        log_event(self, "warn", "rednet.host unavailable")
    end

    self.mode = "server"
    self.status = "hosting"
    self.last_seen = now()
    self:announce()
    return true
end

function RednetDriver:announce(target)
    local ok, err = self:open()
    if not ok then
        log_event(self, "warn", "announce open failed " .. tostring(err))
        return false, err
    end

    local message = {
        type = "server.announce",
        server = self.hostname,
        protocol = self.protocol,
        time = now(),
    }

    if target then
        rednet.send(target, message, self.protocol)
        log_event(self, "debug", "sent server.announce target=" .. tostring(target))
    else
        rednet.broadcast(message, self.protocol)
        log_event(self, "debug", "broadcast server.announce")
    end

    self.last_announce = os.clock()
    return true
end

function RednetDriver:discover()
    local ok, err = self:open()
    if not ok then
        return false, err
    end

    wait_for_announce(self, 0.15)
    if self.server_id then
        return true, self.server_id
    end

    for _, hostname in ipairs(self.server_hosts) do
        if rednet.lookup then
            log_event(self, "debug", "lookup hostname=" .. tostring(hostname))
            local id = rednet.lookup(self.protocol, hostname)
            if id then
                self.server_id = id
                self.status = "connected"
                self.last_seen = now()
                log_event(self, "info", "lookup connected server=" .. tostring(id) .. " hostname=" .. tostring(hostname))
                return true, id
            end
            log_event(self, "debug", "lookup missed hostname=" .. tostring(hostname))
        end
    end

    log_event(self, "debug", "broadcast server.lookup")
    rednet.broadcast({
        type = "server.lookup",
        hosts = self.server_hosts,
        requester = os.getComputerID and os.getComputerID() or nil,
        time = now(),
    }, self.protocol)
    local deadline = os.clock() + 4
    while os.clock() < deadline do
        local sender, message = rednet.receive(self.protocol, math.max(0.05, deadline - os.clock()))
        local accepted, id = accept_server_announce(self, sender, message, "lookup")
        if accepted then
            return true, id
        end
        if sender then
            log_event(self, "debug", "ignored discovery reply type=" .. message_type(message) .. " sender=" .. tostring(sender))
        end
    end

    self.status = "searching"
    self.last_error = "ServerNotFound"
    log_event(self, "warn", "discover failed ServerNotFound")
    return false, self.last_error
end

function RednetDriver:handshake(device)
    device = device or {}
    local ok, target = self:discover()
    if not ok then
        log_event(self, "warn", "handshake discover failed " .. tostring(target))
        return false, target
    end

    local message = {
        type = "hello",
        os = device.os or "HyperCube",
        role = device.role or "phone",
        label = os.getComputerLabel and os.getComputerLabel() or nil,
        computer_id = os.getComputerID and os.getComputerID() or nil,
        tesserac_id = device.tesserac_id,
        username = device.username,
        session_token = device.session_token,
        time = now(),
    }

    log_event(self, "debug", "send hello target=" .. tostring(target))
    rednet.send(target, message, self.protocol)
    local sender, reply = rednet.receive(self.protocol, 2)
    if sender == target and type(reply) == "table" and reply.type == "welcome" then
        self.status = "connected"
        self.last_seen = now()
        log_event(self, "info", "handshake ok server=" .. tostring(sender))
        return true, reply
    end

    self.status = "searching"
    self.last_error = "HandshakeTimeout"
    log_event(self, "warn", "handshake timeout target=" .. tostring(target))
    return false, self.last_error
end

function RednetDriver:send(message)
    if not self.server_id then
        local ok, err = self:discover()
        if not ok then
            log_event(self, "warn", "send discover failed " .. tostring(err))
            return false, err
        end
    end

    log_event(self, "debug", "send type=" .. message_type(message) .. " target=" .. tostring(self.server_id))
    rednet.send(self.server_id, attach_identity(self, message), self.protocol)
    return true
end

function RednetDriver:request(message, expected_type, timeout)
    timeout = timeout or 5
    if not self.server_id then
        local ok, err = self:discover()
        if not ok then
            log_event(self, "warn", "request discover failed " .. tostring(err))
            return nil, err
        end
    end

    log_event(self, "debug", "request type=" .. message_type(message) .. " expected=" .. tostring(expected_type) .. " target=" .. tostring(self.server_id))
    rednet.send(self.server_id, attach_identity(self, message), self.protocol)
    local deadline = os.clock() + timeout
    while os.clock() < deadline do
        local sender, reply = rednet.receive(self.protocol, math.max(0.05, deadline - os.clock()))
        if sender == self.server_id and type(reply) == "table" then
            if not expected_type or reply.type == expected_type then
                log_event(self, "debug", "reply type=" .. message_type(reply) .. " sender=" .. tostring(sender))
                return reply
            end
        end
    end

    log_event(self, "warn", "request timeout type=" .. message_type(message) .. " expected=" .. tostring(expected_type))
    return nil, "Timeout"
end

function RednetDriver:identify(identity)
    self.identity = identity
    if not identity then
        log_event(self, "warn", "identify failed IdentityRequired")
        return false, "IdentityRequired"
    end

    log_event(self, "info", "identify tesserac_id=" .. tostring(identity.tesserac_id))
    return self:send({
        type = "identify",
        tesserac_id = identity.tesserac_id,
        username = identity.username,
        session_token = identity.session_token,
        device = identity.device,
        label = os.getComputerLabel and os.getComputerLabel() or nil,
        computer_id = os.getComputerID and os.getComputerID() or nil,
    })
end

function RednetDriver:broadcast(message)
    local ok, err = self:open()
    if not ok then
        log_event(self, "warn", "broadcast open failed " .. tostring(err))
        return false, err
    end
    log_event(self, "debug", "broadcast type=" .. message_type(message))
    rednet.broadcast(message, self.protocol)
    return true
end

function RednetDriver:poll(timeout)
    timeout = timeout or 0.05
    local ok, err = self:open()
    if not ok then
        log_event(self, "warn", "poll open failed " .. tostring(err))
        return nil, err
    end

    local sender, message = rednet.receive(self.protocol, timeout)
    if not sender then
        return nil, "NoMessage"
    end

    self.last_seen = now()
    log_event(self, "debug", "received type=" .. message_type(message) .. " sender=" .. tostring(sender))

    if self.mode == "server" then
        if type(message) == "table" and message.type == "server.lookup" then
            log_event(self, "info", "server.lookup sender=" .. tostring(sender))
            self:announce(sender)
        elseif type(message) == "table" and message.type ~= "hello" and not is_update_message(message) and not client_allowed(self, sender) then
            local reason = self.clients[sender] and self.clients[sender].integrity_error or "ROMIntegrityRequired"
            log_event(self, "warn", "rejected main server message sender=" .. tostring(sender) .. " type=" .. message_type(message) .. " reason=" .. tostring(reason))
            reject_main_server(sender, self.protocol, reason)
        elseif self:dispatch_handlers(sender, message) then
            return {
                sender = sender,
                message = message,
                handled = true,
            }
        elseif type(message) == "table" and message.type == "hello" then
            log_event(self, "info", "client hello sender=" .. tostring(sender) .. " os=" .. tostring(message.os) .. " role=" .. tostring(message.role))
            local integrity_ok, integrity_err = phone_rom_integrity(self, message)
            local expected_rom_checksum = self.expected_rom_checksums
                and self.expected_rom_checksums[tostring(message.device or "TPhone")]
                or self.expected_phone_rom_checksum
            self.clients[sender] = {
                id = sender,
                os = message.os,
                role = message.role,
                label = message.label,
                computer_id = message.computer_id,
                tesserac_id = message.tesserac_id,
                username = message.username,
                session_token = message.session_token,
                rom_checksum = message.rom_checksum,
                expected_rom_checksum = expected_rom_checksum,
                integrity_ok = integrity_ok == true,
                integrity_error = integrity_ok and nil or integrity_err,
                last_seen = now(),
            }
            if not integrity_ok then
                rednet.send(sender, {
                    type = "welcome",
                    ok = false,
                    server = self.hostname,
                    protocol = self.protocol,
                    error = integrity_err,
                    expected_rom_checksum = expected_rom_checksum,
                    actual_rom_checksum = message.rom_checksum,
                    time = now(),
                }, self.protocol)
                log_event(self, "warn", "rejected client sender=" .. tostring(sender) .. " reason=" .. tostring(integrity_err))
                return {
                    sender = sender,
                    message = message,
                    rejected = true,
                }
            end
            rednet.send(sender, {
                type = "welcome",
                ok = true,
                server = self.hostname,
                protocol = self.protocol,
                identity_required = true,
                rom_checksum = expected_rom_checksum,
                time = now(),
            }, self.protocol)
            log_event(self, "debug", "sent welcome sender=" .. tostring(sender))
        elseif type(message) == "table" and message.type == "identify" then
            log_event(self, "info", "client identify sender=" .. tostring(sender) .. " tesserac_id=" .. tostring(message.tesserac_id))
            self.clients[sender] = self.clients[sender] or { id = sender }
            self.clients[sender].tesserac_id = message.tesserac_id
            self.clients[sender].username = message.username
            self.clients[sender].session_token = message.session_token
            self.clients[sender].label = message.label
            self.clients[sender].computer_id = message.computer_id
            self.clients[sender].last_seen = now()
            local device_ok, device_result = false, nil
            if message.tesserac_id and message.session_token and self.database then
                device_ok, device_result = tesseracid.server_register_device(self.database, {
                    tesserac_id = message.tesserac_id,
                    session_token = message.session_token,
                    device = message.device or {
                        role = message.role,
                        os = message.os,
                        label = message.label,
                        computer_id = message.computer_id,
                    },
                })
                if device_ok then
                    self.clients[sender].device = device_result
                    self.clients[sender].device_id = device_result.device_id
                end
            end
            rednet.send(sender, {
                type = "identify.result",
                ok = message.tesserac_id ~= nil,
                tesserac_id = message.tesserac_id,
                device = device_ok and device_result or nil,
                error = (not device_ok and message.session_token) and device_result or nil,
            }, self.protocol)
        elseif type(message) == "table" and message.type == "auth.resolve" then
            log_event(self, "debug", "auth resolve sender=" .. tostring(sender) .. " login=" .. tostring(message.username or message.login))
            local ok, result = tesseracid.server_resolve_login(self.database, message)
            rednet.send(sender, {
                type = "auth.resolve.result",
                ok = ok == true,
                result = ok and result or nil,
                error = ok and nil or result,
                tesserac_id = ok and result.tesserac_id or nil,
                username = ok and result.username or nil,
                display_name = ok and result.display_name or nil,
            }, self.protocol)
        elseif type(message) == "table" and message.type == "auth.signup" then
            log_event(self, "info", "auth signup sender=" .. tostring(sender) .. " username=" .. tostring(message.username))
            local ok, result = tesseracid.server_signup(self.database, message)
            if ok then
                self.clients[sender] = self.clients[sender] or { id = sender }
                self.clients[sender].tesserac_id = result.tesserac_id
                self.clients[sender].username = result.username
                self.clients[sender].session_token = result.session_token
                self.clients[sender].device = result.device
                self.clients[sender].device_id = result.device and result.device.device_id or nil
            end
            rednet.send(sender, {
                type = "auth.signup.result",
                ok = ok == true,
                error = ok and nil or result,
                tesserac_id = ok and result.tesserac_id or nil,
                username = ok and result.username or nil,
                display_name = ok and result.display_name or nil,
                session_token = ok and result.session_token or nil,
                device = ok and result.device or nil,
                account = ok and result.account or nil,
            }, self.protocol)
        elseif type(message) == "table" and message.type == "auth.signin" then
            log_event(self, "info", "auth signin sender=" .. tostring(sender) .. " username=" .. tostring(message.username))
            local ok, result = tesseracid.server_signin(self.database, message)
            if ok then
                self.clients[sender] = self.clients[sender] or { id = sender }
                self.clients[sender].tesserac_id = result.tesserac_id
                self.clients[sender].username = result.username
                self.clients[sender].session_token = result.session_token
                self.clients[sender].device = result.device
                self.clients[sender].device_id = result.device and result.device.device_id or nil
            end
            rednet.send(sender, {
                type = "auth.signin.result",
                ok = ok == true,
                error = ok and nil or result,
                tesserac_id = ok and result.tesserac_id or nil,
                username = ok and result.username or nil,
                display_name = ok and result.display_name or nil,
                session_token = ok and result.session_token or nil,
                device = ok and result.device or nil,
                account = ok and result.account or nil,
            }, self.protocol)
        elseif type(message) == "table" and message.type == "device.register" then
            log_event(self, "info", "device.register sender=" .. tostring(sender))
            local ok, result = tesseracid.server_register_device(self.database, message)
            if ok then
                self.clients[sender] = self.clients[sender] or { id = sender }
                self.clients[sender].device = result
                self.clients[sender].device_id = result.device_id
                self.clients[sender].tesserac_id = result.owner
                self.clients[sender].username = result.username
                self.clients[sender].session_token = message.session_token
            end
            rednet.send(sender, {
                type = "device.register.result",
                ok = ok == true,
                result = ok and result or nil,
                error = ok and nil or result,
            }, self.protocol)
        elseif type(message) == "table" and message.type == "device.list" then
            log_event(self, "debug", "device.list sender=" .. tostring(sender))
            local identity = session_identity(sender, message, self.clients)
            local ok, result = tesseracid.server_list_devices(self.database, {
                tesserac_id = identity.tesserac_id,
                session_token = identity.session_token,
            })
            rednet.send(sender, {
                type = "device.list.result",
                ok = ok == true,
                result = ok and result or nil,
                error = ok and nil or result,
            }, self.protocol)
        elseif type(message) == "table" and message.type == "ping" then
            log_event(self, "debug", "ping sender=" .. tostring(sender))
            rednet.send(sender, {
                type = "pong",
                server = self.hostname,
                time = now(),
            }, self.protocol)
        elseif type(message) == "table" and message.type == "db.status" then
            log_event(self, "debug", "db.status sender=" .. tostring(sender))
            rednet.send(sender, {
                type = "db.status.result",
                ok = self.database ~= nil,
                status = self.database and self.database:summary() or nil,
            }, self.protocol)
        elseif type(message) == "table" and message.type == "db.get" then
            log_event(self, "debug", "db.get sender=" .. tostring(sender) .. " key=" .. tostring(message.key))
            local value, meta_or_err = nil, "DatabaseUnavailable"
            if self.database then
                local scope_ok, scope_err = require_device_scope(self, sender, message, "db.user")
                local key, key_err = scoped_key(sender, message, self.clients)
                if scope_ok and key then
                    value, meta_or_err = self.database:get(key)
                    if type(value) == "table" and value.value ~= nil then
                        value = value.value
                    end
                else
                    meta_or_err = scope_ok and key_err or scope_err
                end
            end
            rednet.send(sender, {
                type = "db.get.result",
                ok = value ~= nil,
                key = message.key,
                value = value,
                meta = type(meta_or_err) == "table" and meta_or_err or nil,
                error = type(meta_or_err) == "string" and meta_or_err or nil,
            }, self.protocol)
        elseif type(message) == "table" and message.type == "db.set" then
            log_event(self, "debug", "db.set sender=" .. tostring(sender) .. " key=" .. tostring(message.key))
            local ok, result = false, "DatabaseUnavailable"
            if self.database then
                local scope_ok, scope_err = require_device_scope(self, sender, message, "db.user")
                local key, key_err = scoped_key(sender, message, self.clients)
                if scope_ok and key then
                    ok, result = self.database:set(key, {
                        owner = message.tesserac_id or (self.clients[sender] and self.clients[sender].tesserac_id),
                        key = message.key,
                        value = message.value,
                    })
                else
                    result = scope_ok and key_err or scope_err
                end
            end
            rednet.send(sender, {
                type = "db.set.result",
                ok = ok == true,
                key = message.key,
                result = type(result) == "table" and result or nil,
                error = type(result) == "string" and result or nil,
            }, self.protocol)
        elseif type(message) == "table" and message.type == "db.delete" then
            log_event(self, "debug", "db.delete sender=" .. tostring(sender) .. " key=" .. tostring(message.key))
            local ok, result = false, "DatabaseUnavailable"
            if self.database then
                local scope_ok, scope_err = require_device_scope(self, sender, message, "db.user")
                local key, key_err = scoped_key(sender, message, self.clients)
                if scope_ok and key then
                    ok, result = self.database:delete(key)
                else
                    result = scope_ok and key_err or scope_err
                end
            end
            rednet.send(sender, {
                type = "db.delete.result",
                ok = ok == true,
                key = message.key,
                result = type(result) == "table" and result or nil,
                error = type(result) == "string" and result or nil,
            }, self.protocol)
        elseif type(message) == "table" and message.type == "web.register" then
            log_event(self, "info", "web.register sender=" .. tostring(sender) .. " domain=" .. tostring(message.domain) .. " origin=" .. tostring(message.origin == true))
            local ok, result = false, "WebUnavailable"
            if self.web then
                if message.origin == true then
                    ok, result = require_device_scope(self, sender, message, "web.origin")
                else
                    ok = true
                end
                if ok then
                    local owner = type(result) == "table" and result.account and result.account.tesserac_id or message_identity(sender, message, self.clients)
                    ok, result = self.web:register_domain(owner, message.domain, {
                        title = message.title,
                        origin_id = message.origin == true and sender or nil,
                        origin_label = message.origin_label or message.label,
                        supports_api = message.supports_api == true,
                    })
                end
            end
            reply_web(sender, self.protocol, "web.register.result", ok, result)
        elseif type(message) == "table" and message.type == "web.publish" then
            log_event(self, "info", "web.publish sender=" .. tostring(sender) .. " domain=" .. tostring(message.domain) .. " path=" .. tostring(message.path or "/"))
            local ok, result = false, "WebUnavailable"
            if self.web then
                ok, result = require_device_scope(self, sender, message, "web.publish")
                if ok then
                    ok, result = self.web:publish(
                        message_identity(sender, message, self.clients),
                        message.domain,
                        message.path or "/",
                        message.hctml or message.source or ""
                    )
                end
            end
            reply_web(sender, self.protocol, "web.publish.result", ok, result)
        elseif type(message) == "table" and message.type == "web.resolve" then
            log_event(self, "debug", "web.resolve sender=" .. tostring(sender) .. " domain=" .. tostring(message.domain))
            local ok, result = false, "WebUnavailable"
            if self.web then
                ok, result = self.web:resolve(message.domain)
            end
            reply_web(sender, self.protocol, "web.resolve.result", ok, result)
        elseif type(message) == "table" and message.type == "web.get" then
            log_event(self, "debug", "web.get sender=" .. tostring(sender) .. " domain=" .. tostring(message.domain) .. " path=" .. tostring(message.path or "/"))
            local ok, result = false, "WebUnavailable"
            if self.moderation and normalize_domain_name(message.domain) == tostring(self.moderation.DOMAIN or "") and self.hypercube then
                ok, result = self.moderation.handle_web_request(self.hypercube, sender, message, self.clients)
                if ok then
                    if type(result) == "table" and result.ok == nil then
                        result.ok = true
                    end
                    ok, result = compile_origin_response(message.domain, message.path or "/", result)
                end
            elseif self.web then
                local resolved_ok, domain_or_err = self.web:resolve(message.domain)
                if resolved_ok and domain_or_err.origin_id then
                    ok, result = route_origin_request(self, domain_or_err.origin_id, {
                        domain = message.domain,
                        path = message.path or "/",
                        method = "GET",
                        headers = message.headers,
                        query = message.query,
                        timeout = message.timeout or 6,
                    })
                else
                    ok, result = self.web:get_page(message.domain, message.path or "/")
                end
                if ok and message.raw ~= true then
                    result = public_web_result(result)
                elseif not ok and not resolved_ok then
                    result = domain_or_err
                end
            end
            reply_web(sender, self.protocol, "web.get.result", ok, result)
        elseif type(message) == "table" and message.type == "web.request" then
            log_event(self, "debug", "web.request sender=" .. tostring(sender) .. " domain=" .. tostring(message.domain) .. " path=" .. tostring(message.path or "/"))
            local ok, result = false, "WebUnavailable"
            if self.moderation and normalize_domain_name(message.domain) == tostring(self.moderation.DOMAIN or "") and self.hypercube then
                ok, result = self.moderation.handle_web_request(self.hypercube, sender, message, self.clients)
                if ok then
                    if type(result) == "table" and result.ok == nil then
                        result.ok = true
                    end
                    ok, result = compile_origin_response(message.domain, message.path or "/", result)
                end
                if ok then
                    result = public_web_result(result)
                end
            elseif self.web then
                local resolved_ok, domain_or_err = self.web:resolve(message.domain)
                if resolved_ok and domain_or_err.origin_id then
                    ok, result = route_origin_request(self, domain_or_err.origin_id, {
                        domain = message.domain,
                        path = message.path or "/",
                        method = message.method or "GET",
                        headers = message.headers,
                        query = message.query,
                        body = message.body,
                        api = true,
                        timeout = message.timeout or 6,
                    })
                    if ok then
                        result = public_web_result(result)
                    end
                elseif resolved_ok then
                    ok, result = false, "NoOriginForDomain"
                else
                    ok, result = false, domain_or_err
                end
            end
            reply_web(sender, self.protocol, "web.request.result", ok, result)
        elseif type(message) == "table" and message.type == "web.list" then
            log_event(self, "debug", "web.list sender=" .. tostring(sender))
            local ok, result = false, "WebUnavailable"
            if self.web then
                ok, result = self.web:list_domains(message_identity(sender, message, self.clients))
            end
            reply_web(sender, self.protocol, "web.list.result", ok, result)
        elseif type(message) == "table" and message.type == "phone.status" then
            log_event(self, "debug", "phone.status sender=" .. tostring(sender))
            local ok, result = false, "PhoneUnavailable"
            if self.phone then
                ok, result = require_device_scope(self, sender, message, "phone.access")
                if ok then
                    ok, result = self.phone:status(
                        message_identity(sender, message, self.clients),
                        message_username(sender, message, self.clients)
                    )
                end
            end
            reply_service(sender, self.protocol, "phone.status.result", ok, result)
        elseif type(message) == "table" and message.type == "phone.subscribe" then
            log_event(self, "info", "phone.subscribe sender=" .. tostring(sender))
            local ok, result = false, "PhoneUnavailable"
            if self.phone then
                ok, result = require_device_scope(self, sender, message, "phone.access")
                if ok then
                    ok, result = self.phone:subscribe(
                        message_identity(sender, message, self.clients),
                        message_username(sender, message, self.clients)
                    )
                end
            end
            reply_service(sender, self.protocol, "phone.subscribe.result", ok, result)
        elseif type(message) == "table" and message.type == "phone.pay" then
            log_event(self, "info", "phone.pay sender=" .. tostring(sender))
            local ok, result = false, "PhoneUnavailable"
            if self.phone then
                ok, result = require_device_scope(self, sender, message, "phone.access")
                if ok then
                    ok, result = self.phone:pay(
                        message_identity(sender, message, self.clients),
                        message_username(sender, message, self.clients)
                    )
                end
            end
            reply_service(sender, self.protocol, "phone.pay.result", ok, result)
        elseif type(message) == "table" and message.type == "phone.send" then
            log_event(self, "info", "phone.send sender=" .. tostring(sender) .. " to=" .. tostring(message.to))
            local ok, result = false, "PhoneUnavailable"
            if self.phone then
                ok, result = require_device_scope(self, sender, message, "phone.access")
                if ok then
                    ok, result = self.phone:send(message_identity(sender, message, self.clients), message.to, message.body)
                end
            end
            reply_service(sender, self.protocol, "phone.send.result", ok, result)
        elseif type(message) == "table" and message.type == "phone.inbox" then
            log_event(self, "debug", "phone.inbox sender=" .. tostring(sender))
            local ok, result = false, "PhoneUnavailable"
            if self.phone then
                ok, result = require_device_scope(self, sender, message, "phone.access")
                if ok then
                    ok, result = self.phone:inbox(message_identity(sender, message, self.clients))
                end
            end
            reply_service(sender, self.protocol, "phone.inbox.result", ok, result)
        elseif type(message) == "table" and message.type == "phone.sync" then
            log_event(self, "debug", "phone.sync sender=" .. tostring(sender))
            local ok, result = false, "PhoneUnavailable"
            if self.phone then
                ok, result = require_device_scope(self, sender, message, "phone.access")
                if ok then
                    ok, result = self.phone:sync(message_identity(sender, message, self.clients))
                end
            end
            reply_service(sender, self.protocol, "phone.sync.result", ok, result)
        elseif type(message) == "table" and message.type == "phone.chats" then
            log_event(self, "debug", "phone.chats sender=" .. tostring(sender))
            local ok, result = false, "PhoneUnavailable"
            if self.phone then
                ok, result = require_device_scope(self, sender, message, "phone.access")
                if ok then
                    ok, result = self.phone:chats(message_identity(sender, message, self.clients))
                end
            end
            reply_service(sender, self.protocol, "phone.chats.result", ok, result)
        elseif type(message) == "table" and message.type == "phone.chat" then
            log_event(self, "debug", "phone.chat sender=" .. tostring(sender) .. " number=" .. tostring(message.number))
            local ok, result = false, "PhoneUnavailable"
            if self.phone then
                ok, result = require_device_scope(self, sender, message, "phone.access")
                if ok then
                    ok, result = self.phone:chat(message_identity(sender, message, self.clients), message.number, message.mark_read)
                end
            end
            reply_service(sender, self.protocol, "phone.chat.result", ok, result)
        elseif type(message) == "table" and message.type == "phone.chat.delete" then
            log_event(self, "info", "phone.chat.delete sender=" .. tostring(sender) .. " number=" .. tostring(message.number))
            local ok, result = false, "PhoneUnavailable"
            if self.phone then
                ok, result = require_device_scope(self, sender, message, "phone.access")
                if ok then
                    ok, result = self.phone:delete_chat(message_identity(sender, message, self.clients), message.number)
                end
            end
            reply_service(sender, self.protocol, "phone.chat.delete.result", ok, result)
        end
    end

    return {
        sender = sender,
        message = message,
    }
end

function RednetDriver:client_count()
    local count = 0
    for _ in pairs(self.clients) do
        count = count + 1
    end
    return count
end

function RednetDriver:summary()
    return {
        mode = self.mode,
        protocol = self.protocol,
        hostname = self.hostname,
        side = self.side,
        status = self.status,
        server_id = self.server_id,
        client_count = self:client_count(),
        last_error = self.last_error,
        last_seen = self.last_seen,
        log_count = #self.logs,
    }
end

function RednetDriver:shutdown()
    if rednet and self.side and rednet.isOpen(self.side) then
        rednet.close(self.side)
        log_event(self, "info", "closed side=" .. tostring(self.side))
    end
    self.status = "offline"
    return true
end

function RednetDriver:recent_logs()
    return copy_list(self.logs)
end

local driver = {
    name = "rednet",
    version = "0.1.0",
}

function driver.init(context)
    local options = context and context.rednet or {}
    local instance = RednetDriver.new(options)

    if instance.mode == "server" then
        instance:host()
    else
        instance:open()
        instance:handshake({
            os = options.os or "HyperCube",
            role = options.role or "phone",
            tesserac_id = options.identity and options.identity.tesserac_id,
            username = options.identity and options.identity.username,
            session_token = options.identity and options.identity.session_token,
        })
    end

    log_event(instance, "debug", "init complete status=" .. tostring(instance.status))
    return instance
end

function driver.shutdown(instance)
    if instance and instance.shutdown then
        return instance:shutdown()
    end
    return true
end

driver.RednetDriver = RednetDriver
driver.new = RednetDriver.new

return driver
