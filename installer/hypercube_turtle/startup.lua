local HyperTurtle = require("init")

local ok, err = pcall(function()
    return HyperTurtle.boot()
end)

if not ok then
    print("HyperCube Turtle boot failed: " .. tostring(err))
else
    print("HyperCube Turtle booted")
    local identity_ok, identity_err = HyperTurtle.ensure_identity()
    if identity_ok then
        HyperTurtle.start_gui()
    else
        print("TesseracID required: " .. tostring(identity_err))
    end
end
