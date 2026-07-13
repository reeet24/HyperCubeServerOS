local event_bus = {
    listeners = {},
    history = {},
    max_history = 100,
}

local function matches(pattern, signal)
    if pattern == signal then
        return true
    end
    if pattern:sub(-2) == ".*" then
        local prefix = pattern:sub(1, -2)
        return signal:sub(1, #prefix) == prefix
    end
    return false
end

function event_bus.listen(signal, handler, options)
    if type(signal) ~= "string" then
        return false, "SignalMustBeString"
    end
    if type(handler) ~= "function" then
        return false, "HandlerMustBeFunction"
    end

    options = options or {}
    event_bus.listeners[signal] = event_bus.listeners[signal] or {}
    local listener = {
        handler = handler,
        once = options.once == true,
        owner = options.owner,
    }
    table.insert(event_bus.listeners[signal], listener)
    return true, listener
end

function event_bus.off(signal, handler)
    local listeners = event_bus.listeners[signal]
    if not listeners then
        return false, "SignalNotFound"
    end
    for index = #listeners, 1, -1 do
        if listeners[index].handler == handler then
            table.remove(listeners, index)
        end
    end
    return true
end

function event_bus.emit(signal, payload, context)
    if type(signal) ~= "string" then
        return false, "SignalMustBeString"
    end

    local event = {
        signal = signal,
        payload = payload,
        context = context,
        time = os.clock(),
    }

    table.insert(event_bus.history, event)
    while #event_bus.history > event_bus.max_history do
        table.remove(event_bus.history, 1)
    end

    for pattern, listeners in pairs(event_bus.listeners) do
        if matches(pattern, signal) then
            for index = #listeners, 1, -1 do
                local listener = listeners[index]
                local ok, err = pcall(listener.handler, event)
                if not ok then
                    listener.last_error = err
                end
                if listener.once then
                    table.remove(listeners, index)
                end
            end
        end
    end

    return true, event
end

function event_bus.clear()
    event_bus.listeners = {}
    event_bus.history = {}
end

return event_bus
