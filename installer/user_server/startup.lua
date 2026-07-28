local ok, server_or_err = pcall(require, "init")
if not ok then
    print("UserServer load failed: " .. tostring(server_or_err))
    return
end

local server = server_or_err
local boot_ok, boot_err = pcall(function()
    return server.boot()
end)
if not boot_ok then
    print("UserServer boot failed: " .. tostring(boot_err))
    return
end

server.start_gui()
