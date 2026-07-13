local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "TesseracID",
        label = "ID",
        color = C.blue,
        dock = true,
        render_mode = "exclusive",
    },
}

local function write_line(ctx, row, text, fg)
    api.screen.write(ctx.x, ctx.y + row, text, fg or C.white, C.black)
end

function app.render(ctx)
    local identity = api.identity or {}
    write_line(ctx, 0, "Signed in as", C.lightGray)
    write_line(ctx, 1, tostring(identity.display_name or identity.username or "Not signed in"), C.white)
    write_line(ctx, 3, "TesseracID", C.lightGray)
    write_line(ctx, 4, tostring(identity.tesserac_id or "Unavailable"), C.white)
    write_line(ctx, 6, "Apps run through HCAPI.", C.yellow)
end

return app
