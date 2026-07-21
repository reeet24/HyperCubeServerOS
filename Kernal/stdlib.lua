local stdlib = {}

function stdlib.make_env(context, apis)
    apis = apis or {}

    local safe_os = {
        clock = os.clock,
        time = os.time,
        date = os.date,
        epoch = os.epoch,
    }

    local safe_net = apis.net or {
        send = function()
            return nil, "NetworkUnavailable"
        end,
        receive = function()
            return nil, "NetworkUnavailable"
        end,
    }

    local env = {
        _G = nil,
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
        coroutine = {
            create = coroutine.create,
            resume = coroutine.resume,
            running = coroutine.running,
            status = coroutine.status,
            wrap = coroutine.wrap,
            yield = coroutine.yield,
        },
        math = math,
        string = string,
        table = table,
        os = safe_os,
        print = apis.print or print,
        sys = apis.sys,
        fs = apis.fs,
        net = safe_net,
        network = apis.network,
        database = apis.database,
        identity = apis.identity,
        tesseracid = apis.tesseracid,
        HCAPI = apis.HCAPI,
        screen = apis.screen,
        colors = colors,
        colours = colours,
        keys = keys,
        context = context,
    }

    env._G = env
    return env
end

return stdlib
