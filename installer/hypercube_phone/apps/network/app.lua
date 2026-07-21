local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "HyperNet",
        label = "Net",
        color = C.green,
        dock = true,
        render_mode = "exclusive",
        refresh_rate = 4,
    },
}

local function write_line(ctx, row, text, fg)
    api.screen.write(ctx.x, ctx.y + row, text, fg or C.white, C.black)
end

function app.render(ctx)
    local net = api.hypernet.summary()
    write_line(ctx, 0, "Status: " .. tostring(net.status or "offline"))
    write_line(ctx, 1, "Server: " .. tostring(net.server_id or "none"))
    write_line(ctx, 2, "Protocol: HyperNet")
    write_line(ctx, 3, "Side: " .. tostring(net.side or "none"))
end

return app
