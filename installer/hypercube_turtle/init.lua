local context = require("Kernal.context")
local logger = require("Kernal.logger")
local rednet_driver = require("Kernal.drivers.rednet")
local turtle_driver = require("Kernal.drivers.turtle")
local tesseracid = require("Kernal.services.tesseracid")
local hcapi = require("Kernal.services.hcapi")
local dedicated_webserver = require("Kernal.services.dedicated_webserver")
local app_manager = require("Kernal.services.turtle_app_manager")

local HyperTurtle = {
    name = "HyperCubeTurtle",
    subtitle = "Tesserac Turtle OS",
    software_version = "0.3.5-turtle",
    network = nil,
    turtle = nil,
    identity = nil,
    hcfs = nil,
    webserver = nil,
    apps = {},
    running = false,
    logger = logger,
}

HyperTurtle.root_context = context.create(0, {
    user = "root",
    privilege = "root",
    sandbox = {
        root = "/",
        permissions = {
            ["driver.load"] = true,
            ["net.send"] = true,
            ["turtle.control"] = true,
        },
    },
    groups = { "root", "dev", "turtle" },
    origin = "hypercube_turtle",
})

local function terminal_line(line)
    if term and term.setCursorPos and term.getSize then
        local width, height = term.getSize()
        local _, y = term.getCursorPos()
        if y >= height and term.scroll then
            term.scroll(1)
            term.setCursorPos(1, height)
        end
        line = tostring(line or "")
        if #line > width then
            line = line:sub(1, math.max(1, width - 3)) .. "..."
        end
        print(line)
    else
        print(tostring(line or ""))
    end
end

local function sleep_tick(seconds)
    if os.sleep then
        os.sleep(seconds or 0.1)
    else
        local wake = os.clock() + (seconds or 0.1)
        while os.clock() < wake do
            coroutine.yield()
        end
    end
end

local function prompt(label, hidden)
    write(label)
    if hidden and read then
        return read("*")
    end
    return read()
end

local function normalize_username(username)
    username = tostring(username or ""):lower():gsub("%s+", "")
    username = username:gsub("[^%w_%.-]", "")
    if username == "" then
        return nil, "InvalidUsername"
    end
    return username
end

local function turtle_device()
    return {
        role = "turtle",
        os = HyperTurtle.name,
        label = os.getComputerLabel and os.getComputerLabel() or nil,
        computer_id = os.getComputerID and os.getComputerID() or nil,
        scopes = {
            "account.identity",
            "db.user",
            "turtle.control",
            "web.origin",
        },
    }
end

function HyperTurtle.boot()
    logger.start_file("logs/kernel.log")
    logger.info("HyperCube Turtle boot", HyperTurtle.root_context)

    HyperTurtle.identity = tesseracid.load_local()
    if HyperTurtle.identity then
        HyperTurtle.hcfs = hcapi.UserFS.new(HyperTurtle.identity)
        tesseracid.save_local(HyperTurtle.identity)
    else
        HyperTurtle.hcfs = hcapi.UserFS.new({})
        logger.warn("no TesseracID found; web registration may require sign-in", HyperTurtle.root_context)
    end

    local turtle_ok, turtle_or_err = pcall(turtle_driver.init, {})
    if turtle_ok and turtle_or_err then
        HyperTurtle.turtle = turtle_or_err
        logger.info("turtle driver loaded", HyperTurtle.root_context)
    else
        logger.warn("turtle driver unavailable: " .. tostring(turtle_or_err), HyperTurtle.root_context)
    end

    local net_ok, network_or_err = pcall(rednet_driver.init, {
        rednet = {
            mode = "client",
            protocol = "tesserac",
            hostname = HyperTurtle.name,
            os = HyperTurtle.name,
            role = "turtle",
            identity = HyperTurtle.identity,
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
        HyperTurtle.network = network_or_err
        logger.info("rednet " .. tostring(HyperTurtle.network.status), HyperTurtle.root_context)
        if HyperTurtle.identity then
            HyperTurtle.identity.device = HyperTurtle.identity.device or turtle_device()
            HyperTurtle.network:identify(HyperTurtle.identity)
        end
    else
        logger.warn("rednet unavailable: " .. tostring(network_or_err), HyperTurtle.root_context)
    end

    HyperTurtle.webserver = dedicated_webserver.new({
        network = HyperTurtle.network,
        identity = HyperTurtle.identity,
        logger = logger,
        title = "HyperCube Turtle",
    })

    return true
end

function HyperTurtle.ensure_identity()
    if HyperTurtle.identity then
        return true
    end
    if not HyperTurtle.network then
        terminal_line("TesseracID unavailable: network offline")
        return false, "NetworkUnavailable"
    end

    terminal_line("")
    terminal_line("TesseracID required for registered turtle device")
    terminal_line("1. Sign in")
    terminal_line("2. Sign up")
    local choice = prompt("Select: ")
    local username = prompt("TesseracID: ")
    username = normalize_username(username)
    if not username then
        return false, "InvalidUsername"
    end
    if choice ~= "2" and username:match("^tid_") then
        local resolved = HyperTurtle.network:request({
            type = "auth.resolve",
            username = username,
        }, "auth.resolve.result", 8)
        if resolved and resolved.ok and resolved.username then
            username = resolved.username
        else
            return false, (resolved and resolved.error) or "AccountNotFound"
        end
    end
    local password = prompt("Password: ", true)
    local password_hash = tesseracid.password_hash(username, password, username)
    local message_type = choice == "2" and "auth.signup" or "auth.signin"
    local reply, err = HyperTurtle.network:request({
        type = message_type,
        username = username,
        password_hash = password_hash,
        device = turtle_device(),
    }, message_type .. ".result", 10)
    if not reply or not reply.ok then
        return false, (reply and reply.error) or err or "AuthFailed"
    end

    HyperTurtle.identity = {
        tesserac_id = reply.tesserac_id,
        username = reply.username,
        display_name = reply.display_name or reply.username,
        session_token = reply.session_token,
        device = reply.device,
        account = reply.account,
        signed_in_at = os.epoch and os.epoch("utc") or os.clock(),
    }
    HyperTurtle.hcfs = hcapi.UserFS.new(HyperTurtle.identity)
    tesseracid.save_local(HyperTurtle.identity)
    HyperTurtle.network:identify(HyperTurtle.identity)
    return true
end

function HyperTurtle:load_apps()
    self.apps = app_manager.load_all(self)
    app_manager.start_all(self, self.apps)
    logger.info("loaded turtle apps=" .. tostring(#self.apps), self.root_context)
end

function HyperTurtle:start()
    self:load_apps()
    self.running = true
    terminal_line("HyperCube Turtle OS")
    terminal_line("Apps: " .. tostring(#self.apps))
    terminal_line("Web domain: " .. tostring(self.webserver and self.webserver.domain or "not set"))
    terminal_line("Hold Ctrl+T to terminate.")

    local last_tick = os.clock()
    while self.running do
        if self.webserver then
            self.webserver:poll(0.1)
        else
            sleep_tick(0.1)
        end

        if os.clock() - last_tick >= 2 then
            app_manager.tick_all(self, self.apps)
            last_tick = os.clock()
        end
    end
    return true
end

function HyperTurtle.start_gui()
    return HyperTurtle:start()
end

function HyperTurtle.shutdown(reason)
    HyperTurtle.running = false
    logger.info("HyperCube Turtle shutdown " .. tostring(reason or ""), HyperTurtle.root_context)
    return true
end

return HyperTurtle
