local process_manager = require("Kernal.process_manager")
local event_bus = require("Kernal.event_bus")
local logger = require("Kernal.logger")
local module_loader = require("Kernal.module_loader")
local context_builder = require("Kernal.context")

local syscall = {
    routes = {},
}

local privilege_rank = {
    user = 1,
    system = 2,
    root = 3,
}

local function has_permission(context, permission)
    if not permission then
        return true
    end
    if context.privilege == "root" then
        return true
    end
    local sandbox = context.sandbox or {}
    local permissions = sandbox.permissions or {}
    return permissions[permission] == true
end

local function authorize(context, route)
    local ok, err = context_builder.validate(context)
    if not ok then
        return false, err
    end

    local required = route.privilege or "user"
    if (privilege_rank[context.privilege] or 0) < (privilege_rank[required] or 0) then
        return false, "InsufficientPrivilege"
    end

    for _, permission in ipairs(route.permissions or {}) do
        if not has_permission(context, permission) then
            return false, "MissingPermission:" .. permission
        end
    end

    return true
end

local function validate_args(args, schema)
    args = args or {}
    for name, rule in pairs(schema or {}) do
        local value = args[name]
        if rule.required and value == nil then
            return false, "MissingArgument:" .. name
        end
        if value ~= nil and rule.type and type(value) ~= rule.type then
            return false, "InvalidArgument:" .. name
        end
    end
    return true
end

function syscall.register(name, route)
    if type(name) ~= "string" or name == "" then
        return false, "NameRequired"
    end
    if type(route) ~= "table" or type(route.handler) ~= "function" then
        return false, "RouteHandlerRequired"
    end
    syscall.routes[name] = route
    return true
end

function syscall.call(context, name, args)
    local route = syscall.routes[name]
    if not route then
        return nil, "UnknownSyscall:" .. tostring(name)
    end

    local ok, err = authorize(context, route)
    if not ok then
        return nil, err
    end

    ok, err = validate_args(args, route.args)
    if not ok then
        return nil, err
    end

    return route.handler(context, args or {})
end

function syscall.dispatcher(name, args, context)
    return syscall.call(context, name, args)
end

syscall.register("process.spawn", {
    privilege = "system",
    permissions = { "process.spawn" },
    args = {
        name = { type = "string", required = true },
        entrypoint = { type = "function", required = true },
    },
    handler = function(context, args)
        return process_manager.spawn(context, args.name, args.entrypoint, args.options or {})
    end,
})

syscall.register("process.kill", {
    privilege = "system",
    permissions = { "process.control" },
    args = {
        pid = { type = "number", required = true },
    },
    handler = function(context, args)
        return process_manager.kill(context, args.pid, args.reason)
    end,
})

syscall.register("process.suspend", {
    privilege = "system",
    permissions = { "process.control" },
    args = {
        pid = { type = "number", required = true },
    },
    handler = function(context, args)
        return process_manager.suspend(context, args.pid)
    end,
})

syscall.register("process.resume", {
    privilege = "system",
    permissions = { "process.control" },
    args = {
        pid = { type = "number", required = true },
    },
    handler = function(context, args)
        return process_manager.resume(context, args.pid)
    end,
})

syscall.register("process.list", {
    privilege = "user",
    handler = function()
        return process_manager.list()
    end,
})

syscall.register("event.emit", {
    privilege = "user",
    permissions = { "event.emit" },
    args = {
        signal = { type = "string", required = true },
    },
    handler = function(context, args)
        return event_bus.emit(args.signal, args.payload, context)
    end,
})

syscall.register("event.listen", {
    privilege = "system",
    permissions = { "event.listen" },
    args = {
        signal = { type = "string", required = true },
        handler = { type = "function", required = true },
    },
    handler = function(context, args)
        return event_bus.listen(args.signal, args.handler, { owner = context.pid })
    end,
})

syscall.register("time.sleep", {
    privilege = "user",
    args = {
        duration = { type = "number", required = true },
    },
    handler = function(_, args)
        return coroutine.yield("sleep", args.duration)
    end,
})

syscall.register("log.write", {
    privilege = "user",
    args = {
        level = { type = "string", required = true },
        message = { type = "string", required = true },
    },
    handler = function(context, args)
        return logger.log(args.level, args.message, context)
    end,
})

syscall.register("module.load", {
    privilege = "root",
    permissions = { "module.load" },
    args = {
        path = { type = "string", required = true },
    },
    handler = function(context, args)
        return module_loader.load_module(args.path, context)
    end,
})

syscall.register("driver.load", {
    privilege = "root",
    permissions = { "driver.load" },
    args = {
        path = { type = "string", required = true },
    },
    handler = function(context, args)
        return module_loader.init_driver(args.path, context)
    end,
})

return syscall
