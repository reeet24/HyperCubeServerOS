local stdlib = require("Kernal.stdlib")
local process_manager = require("Kernal.process_manager")

local program_runner = {}
local unpack_args = unpack or table.unpack

local function loadfile_with_env(path, env)
    if not loadfile then
        return nil, "loadfile unavailable"
    end

    local attempts = {
        { path, env },       -- ComputerCraft Tweaked
        { path, "t", env },  -- Lua 5.2+
        { path },           -- Lua 5.1 fallback, paired with setfenv below
    }

    local last_err
    for _, args in ipairs(attempts) do
        local ok, loader, err = pcall(loadfile, unpack_args(args))
        if ok and loader then
            if setfenv then
                setfenv(loader, env)
            end
            return loader
        end
        last_err = ok and err or loader
    end

    return nil, last_err
end

function program_runner.load_program(path, context, apis)
    if type(path) ~= "string" or path == "" then
        return nil, "PathRequired"
    end

    local env = stdlib.make_env(context, apis)
    local loader, err = loadfile_with_env(path, env)
    if not loader then
        return nil, err
    end

    return function(runtime_context)
        env.context = runtime_context or context
        return loader()
    end
end

function program_runner.run(path, context, options)
    options = options or {}
    local entrypoint, err = program_runner.load_program(path, context, options.apis)
    if not entrypoint then
        return nil, err
    end
    return process_manager.spawn(context, options.name or path, entrypoint, options)
end

function program_runner.scan(folder)
    folder = folder or "programs"
    local programs = {}

    if fs and fs.exists and fs.list and fs.exists(folder) then
        for _, file in ipairs(fs.list(folder)) do
            if file:match("%.lua$") then
                programs[#programs + 1] = {
                    name = file:gsub("%.lua$", ""),
                    path = folder .. "/" .. file,
                }
            end
        end
    end

    return programs
end

return program_runner
