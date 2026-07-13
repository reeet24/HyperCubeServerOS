local process_manager = require("Kernal.process_manager")

local scheduler = {
    running = false,
    tick_interval = 0,
}

local function sleep(interval)
    if interval <= 0 then
        coroutine.yield("tick")
        return
    end

    if os.sleep then
        os.sleep(interval)
    else
        local wake = os.clock() + interval
        while os.clock() < wake do
            coroutine.yield("tick")
        end
    end
end

function scheduler.spawn(name, entrypoint, options)
    return process_manager.spawn(nil, name, entrypoint, options)
end

function scheduler.spawn_daemon(name, entrypoint, options)
    return process_manager.spawn_daemon(nil, name, entrypoint, options)
end

function scheduler.tick(event)
    return process_manager.tick_process_queue(event)
end

function scheduler.run(max_ticks)
    scheduler.running = true
    local ticks = 0

    while scheduler.running do
        scheduler.tick({ type = "tick", count = ticks })
        ticks = ticks + 1
        if max_ticks and ticks >= max_ticks then
            scheduler.running = false
        end
        sleep(scheduler.tick_interval)
    end
end

function scheduler.stop()
    scheduler.running = false
end

return scheduler
