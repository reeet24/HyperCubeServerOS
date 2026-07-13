local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "Logs",
        label = "Log",
        color = C.orange,
        render_mode = "exclusive",
    },
}

local function write_line(ctx, row, text, fg)
    api.screen.write(ctx.x, ctx.y + row, text, fg or C.white, C.black)
end

function app.render(ctx)
    local launches = tonumber(api.fs.read("launches.txt") or "0") or 0
    launches = launches + 1
    api.fs.write("launches.txt", tostring(launches))

    write_line(ctx, 0, "App diagnostics", C.yellow)
    write_line(ctx, 2, "Sandboxed log view")
    write_line(ctx, 3, "Launch count: " .. tostring(launches))
    write_line(ctx, 5, "Kernel logs are not")
    write_line(ctx, 6, "exposed to user apps.")
end

return app
