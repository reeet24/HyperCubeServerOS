local process_manager = require("Kernal.process_manager")
local scheduler = require("Kernal.scheduler")
local logger = require("Kernal.logger")

local init_system = {
    tasks = {},
}

function init_system.add_task(name, entrypoint, options)
    if type(name) ~= "string" or name == "" then
        return false, "NameRequired"
    end
    if type(entrypoint) ~= "function" then
        return false, "EntrypointMustBeFunction"
    end
    init_system.tasks[#init_system.tasks + 1] = {
        name = name,
        entrypoint = entrypoint,
        options = options or {},
    }
    return true
end

function init_system.run(context)
    logger.info("init starting", context)

    for _, task in ipairs(init_system.tasks) do
        local result = process_manager.spawn(context, task.name, task.entrypoint, task.options)
        if not result or result.success ~= true then
            logger.error("failed to start init task: " .. task.name, context)
            return result
        end
    end

    scheduler.tick({ type = "init" })
    logger.info("init complete", context)
    return true
end

function init_system.clear()
    init_system.tasks = {}
end

return init_system
