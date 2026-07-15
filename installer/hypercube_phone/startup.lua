local TPhone = require("init")

while true do
    local ok, err = pcall(function()
        local boot_ok, boot_err = TPhone.boot()
        if not boot_ok then
            return false, boot_err
        end
        local identity_ok, identity_err = TPhone.ensure_identity()
        if not identity_ok then
            return false, identity_err
        end
        return TPhone.start_gui()
    end)

    if not ok then
        print("HyperCube phone OS recovered: " .. tostring(err))
    elseif err == false then
        print("HyperCube phone OS stopped unexpectedly")
    end

    if sleep then
        sleep(1)
    end
end
