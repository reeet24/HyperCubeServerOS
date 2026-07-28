local context = require("Kernal.context")
local process_manager = require("Kernal.process_manager")
local scheduler = require("Kernal.scheduler")
local event_bus = require("Kernal.event_bus")
local module_loader = require("Kernal.module_loader")
local vfs = require("Kernal.vfs_api")
local logger = require("Kernal.logger")
local init_system = require("Kernal.init_system")
local program_runner = require("Kernal.program_runner")
local tesseracid = require("Kernal.services.tesseracid")
local screen_driver = require("Kernal.drivers.screen")
local rednet_driver = require("Kernal.drivers.rednet")
local service_manager = require("Kernal.services.user_service_manager")
local gui = require("Kernal.gui")

local UserServer = {
    name = "HyperCubeUserServer",
    subtitle = "User Service Host",
    software_version = "0.1.0",
    network_mode = "client",
    context = context,
    process = process_manager,
    scheduler = scheduler,
    event_bus = event_bus,
    module_loader = module_loader,
    vfs = vfs,
    logger = logger,
    init = init_system,
    program_runner = program_runner,
    tesseracid = tesseracid,
    screen_driver = screen_driver,
    rednet_driver = rednet_driver,
    service_manager = service_manager,
    gui = gui,
    identity = nil,
    screen = nil,
    network = nil,
    services = {},
    services_started = false,
    service_state = {},
    service_root = "user_services",
}

UserServer.root_context = context.create(0, {
    user = "root",
    privilege = "root",
    sandbox = {
        root = "/",
        permissions = {
            ["process.spawn"] = true,
            ["process.control"] = true,
            ["event.emit"] = true,
            ["event.listen"] = true,
            ["module.load"] = true,
            ["driver.load"] = true,
        },
    },
    groups = { "root", "service-host" },
    origin = "init",
})
UserServer.root_context.fd_table = {}
UserServer.root_context.next_fd = 3

UserServer.service_context = context.create(1, {
    user = "service",
    privilege = "service",
    sandbox = {
        root = "/",
        permissions = {
            ["event.emit"] = true,
            ["event.listen"] = true,
            ["network.client"] = true,
            ["storage.service"] = true,
        },
    },
    groups = { "service" },
    origin = "user_service",
})

UserServer.ui_context = context.create(2, {
    user = "service_ui",
    privilege = "user_service_ui",
    sandbox = {
        root = "/",
        permissions = {
            ["event.listen"] = true,
            ["screen.draw"] = true,
            ["storage.service"] = true,
        },
    },
    groups = { "service_ui" },
    origin = "user_service_ui",
})

function UserServer.boot()
    logger.start_file("logs/kernel.log")
    logger.info("UserServer boot", UserServer.root_context)
    UserServer.identity = tesseracid.load_local()

    local ok, screen_or_err, screen_err = pcall(screen_driver.init, {
        screen = {
            text_scale = 0.5,
        },
    })
    if ok and screen_or_err then
        UserServer.screen = screen_or_err
        logger.info("screen driver loaded", UserServer.root_context)
    else
        logger.warn("screen driver unavailable: " .. tostring(screen_err or screen_or_err), UserServer.root_context)
    end

    local net_ok, network_or_err = pcall(rednet_driver.init, {
        rednet = {
            mode = "client",
            protocol = "tesserac",
            hostname = UserServer.name,
            os = UserServer.name,
            role = "user_server",
            device = "UserServer",
            identity = UserServer.identity,
            logger = logger,
            verbose = false,
            server_hosts = {
                "HyperCubeServer",
                "TesseracServer",
                "tesserac-server",
            },
        },
    })
    if net_ok and network_or_err then
        UserServer.network = network_or_err
        local summary = UserServer.network:summary()
        logger.info("rednet " .. summary.status .. " on " .. tostring(summary.side or "none"), UserServer.root_context)
    else
        logger.warn("rednet unavailable: " .. tostring(network_or_err), UserServer.root_context)
    end

    init_system.add_task("system.event_tick", function(proc_context)
        event_bus.emit("system.on_tick", { source = "init" }, proc_context)
        coroutine.yield("tick")
    end, {
        privilege = "system",
        daemon = true,
        sandbox = UserServer.root_context.sandbox,
    })

    return init_system.run(UserServer.root_context)
end

function UserServer.start_services()
    if UserServer.services_started then
        return true
    end
    local ok, err = service_manager.start_services(UserServer)
    if not ok then
        return false, err
    end
    UserServer.services_started = true
    return true
end

function UserServer.ensure_identity()
    if UserServer.identity then
        if UserServer.network then
            UserServer.network:identify(UserServer.identity)
        end
        UserServer.start_services()
        return true
    end

    local identity, err = tesseracid.ensure_device_identity(UserServer.network, logger, {
        title = "User server account required",
        os = UserServer.name,
        role = "user_server",
        device = "UserServer",
    })
    if not identity then
        logger.warn("user server account unavailable: " .. tostring(err), UserServer.root_context)
        return false, err
    end

    UserServer.identity = identity
    if UserServer.network then
        UserServer.network:identify(identity)
    end
    UserServer.start_services()
    logger.info("signed in as " .. tostring(identity.username), UserServer.root_context)
    return true
end

function UserServer.start_gui()
    return gui.run(UserServer)
end

function UserServer.shutdown(reason)
    event_bus.emit("system.on_shutdown", { reason = reason or "shutdown" }, UserServer.root_context)
    if UserServer.network then
        UserServer.network:shutdown()
    end
    scheduler.stop()
    logger.info("UserServer shutdown", UserServer.root_context)
    return true
end

return UserServer
