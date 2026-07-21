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
local tesseracid = require("Kernal.services.tesseracid")
local hcapi = require("Kernal.services.hcapi")
local app_manager = require("Kernal.services.app_manager")
local gui = require("Kernal.gui")

local TPhone = {
    name = "HyperCube",
    subtitle = "Tesserac TPhone",
    software_version = "0.3.5",
    network_mode = "client",
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
    tesseracid = tesseracid,
    hcapi = hcapi,
    gui = gui,
    screen = nil,
    network = nil,
    database = nil,
    hcfs = nil,
    identity = nil,
    dev_mode = false,
    update_pending = false,
}

TPhone.root_context = context.create(0, {
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
TPhone.root_context.fd_table = {}
TPhone.root_context.next_fd = 3

local function terminal_line(line)
    if not term then
        return false
    end

    local output = term.native and term.native() or (term.current and term.current())
    if not output then
        return false
    end

    local previous = term.current and term.current() or nil
    if term.redirect and previous ~= output then
        term.redirect(output)
    end

    if output.getSize and output.setCursorPos then
        local width, height = output.getSize()
        local text = tostring(line or "")
        if #text > width then
            text = text:sub(1, math.max(1, width - 3)) .. "..."
        end
        local _, y = output.getCursorPos()
        if y >= height and output.scroll then
            output.scroll(1)
            output.setCursorPos(1, height)
        end
        print(text)
    else
        print(tostring(line or ""))
    end

    if term.redirect and previous and previous ~= output then
        term.redirect(previous)
    end

    return true
end

local function load_dev_mode()
    return fs and fs.exists and fs.exists("user/dev_mode") == true
end

local function write_file(path, data, binary)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and fs and fs.exists and fs.makeDir and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local handle = fs and fs.open and fs.open(path, binary and "wb" or "w")
    if not handle then
        return false, "OpenFailed"
    end
    handle.write(data or "")
    handle.close()
    return true
end

local function read_file(path)
    if not fs or not fs.exists or not fs.open or not fs.exists(path) then
        return nil, "NotFound"
    end
    local handle = fs.open(path, "rb")
    if not handle then
        return nil, "OpenFailed"
    end
    local data = handle.readAll()
    handle.close()
    return data
end

local function checksum(text)
    text = tostring(text or "")
    local a = 1
    local b = 0
    for i = 1, #text do
        a = (a + text:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return tostring((b * 65536 + a) % 2147483647)
end

local function rom_checksum()
    local data, err = read_file("hypercube.rom")
    if not data then
        return nil, err
    end
    return checksum(data)
end

local function install_device()
    local data = read_file("hypercube_install")
    if not data then
        return "TPhone"
    end
    local ok, info = pcall(textutils.unserialize, data)
    if ok and type(info) == "table" and info.device then
        return tostring(info.device)
    end
    return "TPhone"
end

function TPhone.enable_terminal_logs()
    if TPhone.terminal_logs_enabled then
        return true
    end
    if not TPhone.screen or TPhone.screen.side == "term" then
        return false, "MonitorNotAttached"
    end
    if not term then
        return false, "TerminalUnavailable"
    end

    local output = term.native and term.native() or (term.current and term.current())
    if output and output.clear and output.setCursorPos then
        local previous = term.current and term.current() or nil
        if term.redirect and previous ~= output then
            term.redirect(output)
        end
        output.clear()
        output.setCursorPos(1, 1)
        if term.redirect and previous and previous ~= output then
            term.redirect(previous)
        end
    end

    terminal_line("HyperCube terminal log mirror")
    terminal_line("screen=" .. tostring(TPhone.screen.side) .. " rednet logs follow")
    for _, line in ipairs(logger.lines()) do
        terminal_line(line)
    end

    logger.add_sink("tphone_terminal", function(entry)
        terminal_line("[" .. tostring(entry.time) .. "] " .. tostring(entry.level) .. " " .. tostring(entry.message))
    end)

    TPhone.terminal_logs_enabled = true
    logger.info("terminal log mirror enabled on " .. tostring(TPhone.screen.side), TPhone.root_context)
    return true
end

function TPhone.boot()
    logger.start_file("logs/kernel.log")
    logger.info("HyperCube boot", TPhone.root_context)
    TPhone.identity = tesseracid.load_local()
    TPhone.dev_mode = load_dev_mode()
    TPhone.device = install_device()
    TPhone.rom_checksum = rom_checksum()
    if TPhone.identity then
        TPhone.hcfs = hcapi.UserFS.new(TPhone.identity)
        tesseracid.save_local(TPhone.identity)
    end

    local ok, screen_or_err, screen_err = pcall(screen_driver.init, {
        screen = {
            text_scale = 0.5,
        },
    })
    if ok and screen_or_err then
        TPhone.screen = screen_or_err
        logger.info("screen driver loaded", TPhone.root_context)
        TPhone.enable_terminal_logs()
    else
        logger.warn("screen driver unavailable: " .. tostring(screen_err or screen_or_err), TPhone.root_context)
    end

    local net_ok, network_or_err = pcall(rednet_driver.init, {
        rednet = {
            mode = TPhone.network_mode,
            protocol = "tesserac",
            hostname = TPhone.name,
            os = TPhone.name,
            role = TPhone.network_mode == "server" and "server" or "phone",
            device = TPhone.device,
            identity = TPhone.identity,
            rom_checksum = TPhone.rom_checksum,
            logger = logger,
            verbose = true,
            server_hosts = {
                "HyperCubeServer",
                "TesseracServer",
                "tesserac-server",
            },
        },
    })
    if net_ok and network_or_err then
        TPhone.network = network_or_err
        local summary = TPhone.network:summary()
        logger.info("rednet " .. summary.status .. " on " .. tostring(summary.side or "none"), TPhone.root_context)
        if summary.status == "rejected" then
            logger.warn("server rejected phone ROM: " .. tostring(summary.last_error), TPhone.root_context)
        end
        TPhone:check_for_updates()
    else
        logger.warn("rednet driver unavailable: " .. tostring(network_or_err), TPhone.root_context)
    end

    init_system.add_task("system.event_tick", function(proc_context)
        event_bus.emit("system.on_tick", { source = "init" }, proc_context)
        coroutine.yield("tick")
    end, {
        privilege = "system",
        daemon = true,
        sandbox = TPhone.root_context.sandbox,
    })

    return init_system.run(TPhone.root_context)
end

function TPhone:check_for_updates()
    if not self.network or not self.network.request then
        return false, "NetworkUnavailable"
    end

    local status, status_err = self.network:request({
        type = "update.status",
        os = self.name,
        device = self.device or "TPhone",
        version = self.software_version,
    }, "update.status.result", 8)
    if not status then
        logger.warn("software update status failed: " .. tostring(status_err), self.root_context)
        return false, status_err
    end
    if not status.ok then
        logger.warn("software update unavailable: " .. tostring(status.error), self.root_context)
        return false, status.error
    end
    local server_checksum = status.result and status.result.rom_checksum
    local checksum_mismatch = server_checksum and tostring(server_checksum) ~= tostring(self.rom_checksum or "")
    if not status.result or (status.result.update_available ~= true and not checksum_mismatch) then
        logger.info("software up to date " .. tostring(self.software_version), self.root_context)
        return true, "Current"
    end

    if checksum_mismatch then
        logger.warn("software ROM checksum mismatch local=" .. tostring(self.rom_checksum) .. " server=" .. tostring(server_checksum), self.root_context)
    end
    logger.info("software update available " .. tostring(self.software_version) .. " -> " .. tostring(status.result.version), self.root_context)
    local package, package_err = self.network:request({
        type = "update.download",
        os = self.name,
        device = self.device or "TPhone",
        version = self.software_version,
    }, "update.download.result", 20)
    if not package or not package.ok or type(package.result) ~= "table" then
        local reason = (package and package.error) or package_err or "DownloadFailed"
        logger.warn("software update download failed: " .. tostring(reason), self.root_context)
        return false, reason
    end

    local result = package.result
    local rom_data = result.rom_data
    if not rom_data and result.chunks then
        local chunks = {}
        for i = 1, tonumber(result.chunks) or 0 do
            local chunk, chunk_err = self.network:request({
                type = "update.chunk",
                device = self.device or "TPhone",
                index = i,
            }, "update.chunk.result", 10)
            if not chunk or not chunk.ok or not chunk.result or not chunk.result.data then
                local reason = (chunk and chunk.error) or chunk_err or "ChunkFailed"
                logger.warn("software update chunk failed: " .. tostring(reason), self.root_context)
                return false, reason
            end
            chunks[i] = chunk.result.data
        end
        rom_data = table.concat(chunks)
    end

    if not rom_data or rom_data == "" then
        logger.warn("software update missing ROM payload", self.root_context)
        return false, "MissingRomPayload"
    end
    if server_checksum and checksum(rom_data) ~= tostring(server_checksum) then
        logger.warn("software update checksum failed", self.root_context)
        return false, "DownloadedROMChecksumMismatch"
    end

    local ok, err = write_file(result.rom or "hypercube.rom", rom_data, true)
    if not ok then
        logger.warn("software update rom write failed: " .. tostring(err), self.root_context)
        return false, err
    end
    ok, err = write_file("startup.lua", result.startup, false)
    if not ok then
        logger.warn("software update startup write failed: " .. tostring(err), self.root_context)
        return false, err
    end
    write_file("hypercube_version", tostring(result.version or status.result.version or ""), false)

    self.update_pending = true
    logger.info("software update installed; rebooting", self.root_context)
    if os.reboot then
        os.reboot()
    end
    return true, result
end

function TPhone:install_app(package)
    local ok, result = app_manager.install(package)
    if ok then
        self.apps_dirty = true
        logger.info("installed app " .. tostring(result.id), self.root_context)
    else
        logger.warn("app install failed: " .. tostring(result), self.root_context)
    end
    return ok, result
end

function TPhone.ensure_identity()
    if TPhone.network_mode == "server" then
        return true
    end
    if TPhone.network and TPhone.network.status == "rejected" then
        local reason = TPhone.network.last_error or "ROMIntegrityRequired"
        logger.warn("identity blocked by ROM integrity failure: " .. tostring(reason), TPhone.root_context)
        return false, reason
    end
    if TPhone.identity then
        if not TPhone.hcfs then
            TPhone.hcfs = hcapi.UserFS.new(TPhone.identity)
            tesseracid.save_local(TPhone.identity)
        end
        if TPhone.network then
            TPhone.network:identify(TPhone.identity)
        end
        return true
    end

    local identity, err = tesseracid.ensure_phone_identity(TPhone.network, logger)
    if not identity then
        logger.warn("TesseracID unavailable: " .. tostring(err), TPhone.root_context)
        return false, err
    end

    TPhone.identity = identity
    TPhone.hcfs = hcapi.UserFS.new(TPhone.identity)
    if TPhone.network then
        TPhone.network:identify(identity)
    end
    logger.info("signed in as " .. tostring(identity.username), TPhone.root_context)
    return true
end

function TPhone.run_app(path, options)
    options = options or {}
    options.apis = options.apis or {}
    options.apis.identity = options.apis.identity or TPhone.identity
    options.apis.HCAPI = options.apis.HCAPI or hcapi.create(TPhone, options.app_id or path)
    if options.system == true then
        options.apis.screen = options.apis.screen or TPhone.screen
        options.apis.sys = options.apis.sys or TPhone.syscall
        options.apis.fs = options.apis.fs or TPhone.vfs
        options.apis.network = options.apis.network or TPhone.network
        options.apis.database = options.apis.database or TPhone.database
        options.apis.tesseracid = options.apis.tesseracid or TPhone.tesseracid
    end
    return program_runner.run(path, TPhone.root_context, options)
end

function TPhone.start_gui()
    return gui.run(TPhone)
end

function TPhone.shutdown(reason)
    event_bus.emit("system.on_shutdown", { reason = reason or "shutdown" }, TPhone.root_context)
    if TPhone.network then
        TPhone.network:shutdown()
    end
    scheduler.stop()
    logger.info("HyperCube shutdown", TPhone.root_context)
    return true
end

return TPhone
