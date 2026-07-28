local api = ServiceAPI
local C = api.colors

local app = {}

function app.render(ctx)
    local width, height = api.screen.size()
    api.screen.write(2, 2, "Hello Service", C.yellow, C.black)
    api.screen.write(2, 4, "Daemon ticks: " .. tostring(api.state.ticks or 0), C.white, C.black)
    api.screen.write(2, math.max(6, height - 1), "Press Q to return", C.lightGray, C.black)
end

function app.on_event(ctx)
    if ctx.event.type == "key" and keys and ctx.event.raw and ctx.event.raw[2] == keys.q then
        return false
    end
    return true
end

return app
