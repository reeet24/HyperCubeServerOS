local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "Services",
        label = "Svc",
        color = C.purple,
        render_mode = "exclusive",
    },
}

local function write_line(ctx, row, text, fg)
    api.screen.write(ctx.x, ctx.y + row, text, fg or C.white, C.black)
end

function app.render(ctx)
    write_line(ctx, 0, "Tesserac services", C.yellow)
    write_line(ctx, 2, "All app data is scoped")
    write_line(ctx, 3, "to your TesseracID.")
    write_line(ctx, 5, "Network access is")
    write_line(ctx, 6, "HyperNet-only.")
end

return app
