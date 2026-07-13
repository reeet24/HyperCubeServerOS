local TPhone = require("init")

local ok, err = pcall(function()
    return TPhone.boot()
end)

if not ok then
    print("HyperCube boot failed: " .. tostring(err))
else
    print("HyperCube booted")
    local identity_ok, identity_err = TPhone.ensure_identity()
    if identity_ok then
        TPhone.start_gui()
    else
        print("TesseracID required: " .. tostring(identity_err))
    end
end
