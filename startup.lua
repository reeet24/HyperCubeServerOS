local HyperCube = require("init")

local ok, err = pcall(function()
    return HyperCube.boot()
end)

if not ok then
    print("HyperCubeServer boot failed: " .. tostring(err))
else
    print("HyperCubeServer booted")
    local identity_ok, identity_err = HyperCube.ensure_identity()
    if identity_ok then
        HyperCube.start_gui()
    else
        print("TesseracID required: " .. tostring(identity_err))
    end
end
