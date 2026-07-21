local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "Logs",
        label = "Log",
        color = C.orange,
        render_mode = "exclusive",
        refresh_rate = 4,
    },
}

local function write_line(ctx, row, text, fg)
    api.screen.write(ctx.x, ctx.y + row, text, fg or C.white, C.black)
end

function app.render(ctx)
    local state = ctx.state
    if not state.ready then
        state.ready = true
        state.launches = tonumber(api.fs.read("launches.txt") or "0") or 0
    end

    local launches = state.launches or 0
    write_line(ctx, 0, "App diagnostics", C.yellow)
    write_line(ctx, 2, "Sandboxed log view")
    write_line(ctx, 3, "Launch count: " .. tostring(launches))
    write_line(ctx, 5, "Kernel logs are not")
    write_line(ctx, 6, "exposed to user apps.")
end

function app.on_resume(ctx)
    local state = ctx.state
    if not state.ready then
        state.ready = true
        state.launches = tonumber(api.fs.read("launches.txt") or "0") or 0
    end
    local launches = tonumber(state.launches or 0) or 0
    launches = launches + 1
    state.launches = launches
    api.fs.write("launches.txt", tostring(launches))
end

return app
