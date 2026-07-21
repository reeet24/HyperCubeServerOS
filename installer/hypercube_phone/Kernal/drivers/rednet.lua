local RednetDriver = {}
RednetDriver.__index = RednetDriver

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

function RednetDriver.new(options)
    options = options or {}
    local self = setmetatable({}, RednetDriver)

    self.mode = options.mode or "client"
    self.protocol = options.protocol or DEFAULT_PROTOCOL
    self.hostname = options.hostname or (self.mode == "server" and "HyperCubeServer" or "TPhone")
    self.server_hosts = copy_list(options.server_hosts or DEFAULT_SERVER_HOSTS)
    self.side = options.side
    self.status = "offline"
    self.server_id = nil
    self.clients = {}
    self.identity = options.identity
    self.last_error = nil
    self.last_seen = nil
    self.verbose = options.verbose ~= false
    self.logger = options.logger
    self.logs = {}
    self.max_logs = options.max_logs or 100
    self.rom_checksum = options.rom_checksum
    self.device = options.device or "TPhone"
    self.rom_verified = false

    log_event(self, "debug", "driver created mode=" .. tostring(self.mode) .. " host=" .. tostring(self.hostname))

    return self
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
        device = device.device or "TPhone",
        rom_checksum = device.rom_checksum or self.rom_checksum,
        time = now(),
    }

    log_event(self, "debug", "send hello target=" .. tostring(target))
    rednet.send(target, message, self.protocol)
    local sender, reply = rednet.receive(self.protocol, 2)
    if sender == target and type(reply) == "table" and reply.type == "welcome" then
        if reply.ok == false then
            self.status = "rejected"
            self.server_id = target
            self.last_seen = now()
            self.last_error = reply.error or "ServerRejected"
            self.expected_rom_checksum = reply.expected_rom_checksum
            self.actual_rom_checksum = reply.actual_rom_checksum or message.rom_checksum
            self.rom_verified = false
            log_event(self, "warn", "handshake rejected server=" .. tostring(sender) .. " error=" .. tostring(self.last_error))
            return false, self.last_error
        end
        self.status = "connected"
        self.last_seen = now()
        self.rom_verified = true
        self.expected_rom_checksum = reply.rom_checksum
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
            device = options.device or instance.device,
            rom_checksum = options.rom_checksum,
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
