local train_schedule = require("Kernal.services.train_schedule")

local train_schedule_server = {}

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
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

function train_schedule_server.install(hypercube)
    local logger = hypercube.logger
    if not hypercube.network then
        if logger then
            logger.warn("train schedule server unavailable: NetworkUnavailable", hypercube.root_context)
        end
        return false, "NetworkUnavailable"
    end

    if hypercube.train_schedule and hypercube.train_schedule_handler_registered then
        return true, hypercube.train_schedule
    end

    local service = hypercube.train_schedule or train_schedule.new()
    hypercube.train_schedule = service

    hypercube.network:register_handler("train_schedule", function(network, sender, message)
        if type(message) ~= "table" or type(message.type) ~= "string" or message.type:sub(1, 6) ~= "train." then
            return false
        end

        if message.type == "train.schedule" then
            local ok, result = service:fetch(message.force == true)
            reply(rednet, sender, network.protocol, "train.schedule.result", ok, result)
            if logger then
                local level = ok and "debug" or "warn"
                logger[level]("train schedule sender=" .. tostring(sender) .. " ok=" .. tostring(ok), hypercube.root_context)
            end
        else
            reply(rednet, sender, network.protocol, "train.error", false, "UnknownTrainRequest")
        end
        return true
    end)
    hypercube.train_schedule_handler_registered = true

    if logger then
        logger.info("train schedule HyperNet API registered", hypercube.root_context)
    end
    return true, service
end

function train_schedule_server.start(hypercube)
    local ok, err = train_schedule_server.install(hypercube)
    if not ok then
        return false, err
    end
    while true do
        coroutine.yield("tick")
    end
end

return train_schedule_server
