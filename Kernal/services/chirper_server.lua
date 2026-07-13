local chirper = require("Kernal.services.chirper")

local chirper_server = {}

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function message_identity(sender, message, clients)
    return message.tesserac_id or (clients and clients[sender] and clients[sender].tesserac_id)
end

local function message_username(sender, message, clients)
    return message.username or (clients and clients[sender] and clients[sender].username)
end

local function reply(rednet_api, sender, protocol, response_type, ok, result)
    rednet_api.send(sender, {
        type = response_type,
        ok = ok == true,
        result = ok and result or nil,
        error = ok and nil or result,
        time = now(),
    }, protocol)
end

function chirper_server.install(hypercube)
    local logger = hypercube.logger
    if not hypercube.database then
        if logger then
            logger.warn("chirper server unavailable: DatabaseUnavailable", hypercube.root_context)
        end
        return false, "DatabaseUnavailable"
    end
    if not hypercube.network then
        if logger then
            logger.warn("chirper server unavailable: NetworkUnavailable", hypercube.root_context)
        end
        return false, "NetworkUnavailable"
    end

    if hypercube.chirper and hypercube.chirper_handler_registered then
        return true, hypercube.chirper
    end

    local service = hypercube.chirper or chirper.new({
        database = hypercube.database,
    })
    hypercube.chirper = service

    hypercube.network:register_handler("chirper", function(network, sender, message)
        if type(message) ~= "table" or type(message.type) ~= "string" or message.type:sub(1, 8) ~= "chirper." then
            return false
        end

        local owner = message_identity(sender, message, network.clients)
        local username = message_username(sender, message, network.clients)
        local ok, result = false, "UnknownChirperRequest"

        if message.type == "chirper.profile" then
            ok, result = service:profile(owner, username)
            reply(rednet, sender, network.protocol, "chirper.profile.result", ok, result)
        elseif message.type == "chirper.feed" then
            ok, result = service:feed(owner, username)
            reply(rednet, sender, network.protocol, "chirper.feed.result", ok, result)
        elseif message.type == "chirper.post" then
            ok, result = service:post(owner, username, message.body)
            reply(rednet, sender, network.protocol, "chirper.post.result", ok, result)
        else
            reply(rednet, sender, network.protocol, "chirper.error", false, result)
        end

        if logger then
            local level = ok and "debug" or "warn"
            logger[level]("chirper " .. tostring(message.type) .. " sender=" .. tostring(sender) .. " ok=" .. tostring(ok), hypercube.root_context)
        end
        return true
    end)
    hypercube.chirper_handler_registered = true

    if logger then
        logger.info("Chirper HyperNet API registered", hypercube.root_context)
    end
    return true, service
end

function chirper_server.start(hypercube)
    local ok, err = chirper_server.install(hypercube)
    if not ok then
        return false, err
    end

    if hypercube.logger then
        hypercube.logger.info("Chirper process started", hypercube.root_context)
    end

    while true do
        coroutine.yield("tick")
    end
end

return chirper_server
