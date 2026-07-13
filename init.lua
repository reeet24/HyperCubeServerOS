local context = require("Kernal.context")
local process_manager = require("Kernal.process_manager")
local scheduler = require("Kernal.scheduler")
local syscall = require("Kernal.syscall")
local event_bus = require("Kernal.event_bus")
local module_loader = require("Kernal.module_loader")
local vfs = require("Kernal.vfs_api")
local logger = require("Kernal.logger")
local init_system = require("Kernal.init_system")
local program_runner = require("Kernal.program_runner")
local screen_driver = require("Kernal.drivers.screen")
local rednet_driver = require("Kernal.drivers.rednet")
local diskdb_driver = require("Kernal.drivers.diskdb")
local tesseracid = require("Kernal.services.tesseracid")
local web_service = require("Kernal.services.web")
local installer_service = require("Kernal.services.installer")
local phone_service = require("Kernal.services.phone_numbers")
local banking_server = require("Kernal.services.banking_server")
local atm_monitor = require("Kernal.services.atm_monitor")
local moderation_server = require("Kernal.services.moderation_server")
local software_updates = require("Kernal.services.software_updates")
local appstore = require("Kernal.services.appstore")
local chirper_server = require("Kernal.services.chirper_server")
local train_schedule_server = require("Kernal.services.train_schedule_server")
local gui = require("Kernal.gui")

local HyperCube = {
    name = "HyperCubeServer",
    subtitle = "Tesserac Server OS",
    network_mode = "server",
    context = context,
    process = process_manager,
    scheduler = scheduler,
    syscall = syscall,
    event_bus = event_bus,
    module_loader = module_loader,
    vfs = vfs,
    logger = logger,
    init = init_system,
    program_runner = program_runner,
    screen_driver = screen_driver,
    rednet_driver = rednet_driver,
    diskdb_driver = diskdb_driver,
    tesseracid = tesseracid,
    web_service = web_service,
    installer_service = installer_service,
    phone_service = phone_service,
    banking_server = banking_server,
    atm_monitor = atm_monitor,
    moderation_server = moderation_server,
    software_updates = software_updates,
    appstore = appstore,
    chirper_server = chirper_server,
    train_schedule_server = train_schedule_server,
    gui = gui,
    screen = nil,
    network = nil,
    database = nil,
    web = nil,
    installer = nil,
    phone = nil,
    bank = nil,
    chirper = nil,
    train_schedule = nil,
    identity = nil,
}

HyperCube.root_context = context.create(0, {
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
    groups = { "root", "dev" },
    origin = "init",
})
HyperCube.root_context.fd_table = {}
HyperCube.root_context.next_fd = 3

function HyperCube.boot()
    logger.start_file("logs/kernel.log")
    logger.info("HyperCubeServer boot", HyperCube.root_context)
    HyperCube.identity = tesseracid.load_local()

    local ok, screen_or_err, screen_err = pcall(screen_driver.init, {
        screen = {
            text_scale = 0.5,
        },
    })
    if ok and screen_or_err then
        HyperCube.screen = screen_or_err
        logger.info("screen driver loaded", HyperCube.root_context)
    else
        logger.warn("screen driver unavailable: " .. tostring(screen_err or screen_or_err), HyperCube.root_context)
    end

    local net_ok, network_or_err = pcall(rednet_driver.init, {
        rednet = {
            mode = HyperCube.network_mode,
            protocol = "tesserac",
            hostname = HyperCube.name,
            os = HyperCube.name,
            role = HyperCube.network_mode == "server" and "server" or "phone",
            identity = HyperCube.identity,
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
        HyperCube.network = network_or_err
        local summary = HyperCube.network:summary()
        logger.info("rednet " .. summary.status .. " on " .. tostring(summary.side or "none"), HyperCube.root_context)
    else
        logger.warn("rednet driver unavailable: " .. tostring(network_or_err), HyperCube.root_context)
    end

    if HyperCube.network_mode == "server" then
        local db_ok, database_or_err = pcall(diskdb_driver.init, {
            diskdb = {
                root = "hypercube_db",
                min_replicas = 2,
            },
        })
        if db_ok and database_or_err then
            HyperCube.database = database_or_err
            if HyperCube.network then
                HyperCube.network.database = HyperCube.database
            end
            local summary = HyperCube.database:summary()
            logger.info("diskdb " .. summary.status .. " drives=" .. tostring(summary.drives), HyperCube.root_context)

            HyperCube.web = web_service.new({
                database = HyperCube.database,
            })
            HyperCube.phone = phone_service.new({
                database = HyperCube.database,
                weekly_bill = 25,
            })
            if HyperCube.network then
                HyperCube.network.web = HyperCube.web
                HyperCube.network.phone = HyperCube.phone
            end
            logger.info("web registrar/router loaded", HyperCube.root_context)
            logger.info("phone number service loaded", HyperCube.root_context)
        else
            logger.warn("diskdb unavailable: " .. tostring(database_or_err), HyperCube.root_context)
        end

        HyperCube.installer = installer_service.new({
            source = "installer/hypercube_phone",
        })
        if HyperCube.network and HyperCube.installer.update_metadata_for_device then
            HyperCube.network.expected_rom_checksums = {}
            for _, device in ipairs({ "TPhone", "TBusinessPhone" }) do
                local metadata_ok, metadata = HyperCube.installer:update_metadata_for_device(device)
                if metadata_ok and metadata then
                    HyperCube.network.expected_rom_checksums[device] = metadata.rom_checksum
                    if device == "TPhone" then
                        HyperCube.network.expected_phone_rom_checksum = metadata.rom_checksum
                    end
                    logger.info(tostring(device) .. " ROM checksum " .. tostring(metadata.rom_checksum), HyperCube.root_context)
                else
                    logger.warn(tostring(device) .. " ROM checksum unavailable: " .. tostring(metadata), HyperCube.root_context)
                end
            end
        elseif HyperCube.network and HyperCube.installer.update_metadata then
            local metadata_ok, metadata = HyperCube.installer:update_metadata()
            if metadata_ok and metadata then
                HyperCube.network.expected_phone_rom_checksum = metadata.rom_checksum
                logger.info("phone ROM checksum " .. tostring(metadata.rom_checksum), HyperCube.root_context)
            else
                logger.warn("phone ROM checksum unavailable: " .. tostring(metadata), HyperCube.root_context)
            end
        end
        logger.info("HyperCube installer loaded", HyperCube.root_context)

        local bank_ok, bank_err = banking_server.install(HyperCube)
        if not bank_ok then
            logger.warn("Bank of Ba$h unavailable: " .. tostring(bank_err), HyperCube.root_context)
        elseif HyperCube.phone and HyperCube.phone.set_bank then
            HyperCube.phone:set_bank(HyperCube.bank)
        end

        local atm_ok, atm_err = atm_monitor.install(HyperCube)
        if not atm_ok then
            logger.warn("ATM monitor unavailable: " .. tostring(atm_err), HyperCube.root_context)
        end

        local moderation_ok, moderation_err = moderation_server.install(HyperCube)
        if not moderation_ok then
            logger.warn("moderation portal unavailable: " .. tostring(moderation_err), HyperCube.root_context)
        end

        local updates_ok, updates_err = software_updates.install(HyperCube)
        if not updates_ok then
            logger.warn("software updates unavailable: " .. tostring(updates_err), HyperCube.root_context)
        end

        local store_ok, store_err = appstore.install(HyperCube)
        if not store_ok then
            logger.warn("App Store unavailable: " .. tostring(store_err), HyperCube.root_context)
        end

        local chirper_ok, chirper_err = chirper_server.install(HyperCube)
        if not chirper_ok then
            logger.warn("Chirper unavailable: " .. tostring(chirper_err), HyperCube.root_context)
        end

        local train_ok, train_err = train_schedule_server.install(HyperCube)
        if not train_ok then
            logger.warn("train schedule unavailable: " .. tostring(train_err), HyperCube.root_context)
        end

        init_system.add_task("service.banking", function(proc_context)
            return banking_server.start(HyperCube, proc_context)
        end, {
            privilege = "system",
            daemon = true,
            sandbox = HyperCube.root_context.sandbox,
        })

        init_system.add_task("service.software_updates", function(proc_context)
            return software_updates.start(HyperCube, proc_context)
        end, {
            privilege = "system",
            daemon = true,
            sandbox = HyperCube.root_context.sandbox,
        })

        init_system.add_task("service.moderation", function(proc_context)
            return moderation_server.start(HyperCube, proc_context)
        end, {
            privilege = "system",
            daemon = true,
            sandbox = HyperCube.root_context.sandbox,
        })

        init_system.add_task("service.appstore", function(proc_context)
            return appstore.start(HyperCube, proc_context)
        end, {
            privilege = "system",
            daemon = true,
            sandbox = HyperCube.root_context.sandbox,
        })

        init_system.add_task("service.chirper", function(proc_context)
            return chirper_server.start(HyperCube, proc_context)
        end, {
            privilege = "system",
            daemon = true,
            sandbox = HyperCube.root_context.sandbox,
        })

        init_system.add_task("service.train_schedule", function(proc_context)
            return train_schedule_server.start(HyperCube, proc_context)
        end, {
            privilege = "system",
            daemon = true,
            sandbox = HyperCube.root_context.sandbox,
        })
    end

    init_system.add_task("system.event_tick", function(proc_context)
        event_bus.emit("system.on_tick", { source = "init" }, proc_context)
        coroutine.yield("tick")
    end, {
        privilege = "system",
        daemon = true,
        sandbox = HyperCube.root_context.sandbox,
    })

    return init_system.run(HyperCube.root_context)
end

function HyperCube.ensure_identity()
    if HyperCube.network_mode == "server" then
        return true
    end
    if HyperCube.identity then
        if HyperCube.network then
            HyperCube.network:identify(HyperCube.identity)
        end
        return true
    end

    local identity, err = tesseracid.ensure_phone_identity(HyperCube.network, logger)
    if not identity then
        logger.warn("TesseracID unavailable: " .. tostring(err), HyperCube.root_context)
        return false, err
    end

    HyperCube.identity = identity
    if HyperCube.network then
        HyperCube.network:identify(identity)
    end
    logger.info("signed in as " .. tostring(identity.username), HyperCube.root_context)
    return true
end

function HyperCube.run_app(path, options)
    options = options or {}
    options.apis = options.apis or {}
    options.apis.screen = options.apis.screen or HyperCube.screen
    options.apis.sys = options.apis.sys or HyperCube.syscall
    options.apis.fs = options.apis.fs or HyperCube.vfs
    options.apis.network = options.apis.network or HyperCube.network
    options.apis.database = options.apis.database or HyperCube.database
    options.apis.web = options.apis.web or HyperCube.web
    options.apis.installer = options.apis.installer or HyperCube.installer
    options.apis.phone = options.apis.phone or HyperCube.phone
    options.apis.bank = options.apis.bank or HyperCube.bank
    options.apis.identity = options.apis.identity or HyperCube.identity
    options.apis.tesseracid = options.apis.tesseracid or HyperCube.tesseracid
    return program_runner.run(path, HyperCube.root_context, options)
end

function HyperCube.start_gui()
    return gui.run(HyperCube)
end

function HyperCube.shutdown(reason)
    event_bus.emit("system.on_shutdown", { reason = reason or "shutdown" }, HyperCube.root_context)
    if HyperCube.network then
        HyperCube.network:shutdown()
    end
    scheduler.stop()
    logger.info("HyperCubeServer shutdown", HyperCube.root_context)
    return true
end

return HyperCube
