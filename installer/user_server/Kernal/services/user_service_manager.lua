local program_runner = require("Kernal.program_runner")
local stdlib = require("Kernal.stdlib")
local user_service_api = require("Kernal.services.user_service_api")

local manager = {}

local SERVICE_ROOT = "user_services"

local function combine(a, b)
    if fs and fs.combine then
        return fs.combine(a, b)
    end
    if a == "" then
        return b
    end
    if a:sub(-1) == "/" then
        return a .. b
    end
    return a .. "/" .. b
end

local function read_manifest(path, id)
    local manifest = {
        id = id,
        title = id,
        description = "User service",
    }
    local manifest_path = combine(path, "manifest")
    if fs and fs.exists and fs.exists(manifest_path) then
        local handle = fs.open(manifest_path, "r")
        if handle then
            local data = handle.readAll()
            handle.close()
            local ok, decoded = pcall(textutils.unserialize, data)
            if ok and type(decoded) == "table" then
                for key, value in pairs(decoded) do
                    manifest[key] = value
                end
            end
        end
    end
    manifest.id = id
    return manifest
end

local function service_title(service)
    return tostring(service and service.manifest and service.manifest.title or service and service.id or "?")
end

local function log_info(system, message)
    if system and system.logger then
        system.logger.info(tostring(message), system.root_context)
    end
end

local function log_warn(system, message)
    if system and system.logger then
        system.logger.warn(tostring(message), system.root_context)
    end
end

local function load_with_env(path, env)
    local unpack_args = unpack or table.unpack
    local attempts = {
        { path, env },
        { path, "t", env },
        { path },
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

function manager.scan(root)
    root = root or SERVICE_ROOT
    local services = {}
    if not fs or not fs.exists or not fs.list or not fs.exists(root) then
        return services
    end
    for _, id in ipairs(fs.list(root)) do
        local path = combine(root, id)
        if fs.isDir(path) then
            local manifest = read_manifest(path, id)
            services[#services + 1] = {
                id = id,
                path = path,
                manifest = manifest,
                service_path = combine(path, "service.lua"),
                ui_path = combine(path, "ui.lua"),
            }
        end
    end
    table.sort(services, function(a, b)
        return tostring(a.manifest.title or a.id) < tostring(b.manifest.title or b.id)
    end)
    return services
end

function manager.start_services(system)
    system.services = manager.scan(system.service_root or SERVICE_ROOT)
    system.service_process_audit = system.service_process_audit or {}
    log_info(system, "service scan found " .. tostring(#(system.services or {})) .. " service(s)")
    for _, service in ipairs(system.services) do
        if fs.exists(service.service_path) then
            log_info(system, "service starting " .. tostring(service.id) .. " (" .. service_title(service) .. ")")
            local api = user_service_api.create(system, service.id)
            local result, err = program_runner.run(service.service_path, system.service_context, {
                name = "service." .. service.id,
                daemon = true,
                privilege = "service",
                apis = {
                    ServiceAPI = api,
                    HCAPI = api,
                },
            })
            if result and result.success then
                service.pid = result.result and result.result.pid
                if service.pid then
                    system.service_process_audit[service.pid] = {
                        id = service.id,
                        title = service_title(service),
                        pid = service.pid,
                        logged_dead = false,
                    }
                    log_info(system, "service started " .. tostring(service.id) .. " pid=" .. tostring(service.pid))
                else
                    log_warn(system, "service started without pid " .. tostring(service.id))
                end
            else
                log_warn(system, "service start failed " .. service.id .. ": " .. tostring(err or result))
            end
        else
            log_info(system, "service ui-only " .. tostring(service.id) .. " (" .. service_title(service) .. ")")
        end
    end
    return true
end

function manager.audit_services(system)
    local audit = system and system.service_process_audit
    if not audit or not system.process or not system.process.get then
        return true
    end
    for pid, record in pairs(audit) do
        if not record.logged_dead then
            local process = system.process.get(pid)
            if not process then
                record.logged_dead = true
                log_warn(system, "service process missing " .. tostring(record.id) .. " pid=" .. tostring(pid))
            elseif process.status == "Dead" then
                record.logged_dead = true
                local base = "service stopped " .. tostring(record.id) .. " pid=" .. tostring(pid)
                    .. " exit=" .. tostring(process.exit_code)
                if process.exit_code == 0 then
                    log_info(system, base)
                else
                    log_warn(system, base .. " error=" .. tostring(process.error or "unknown"))
                end
            end
        end
    end
    return true
end

function manager.run_ui(system, service)
    if not service or not fs.exists(service.ui_path) then
        return false, "UiUnavailable"
    end
    local api = user_service_api.create(system, service.id)
    local env = stdlib.make_env(system.ui_context, {
        ServiceAPI = api,
        HCAPI = api,
    })
    env.ServiceAPI = api
    local loader, err = load_with_env(service.ui_path, env)
    if not loader then
        return false, err
    end
    if setfenv then
        setfenv(loader, env)
    end
    local ok, app_or_err = pcall(loader)
    if not ok then
        return false, app_or_err
    end
    local app = type(app_or_err) == "table" and app_or_err or {}

    local state = {}
    local running = true
    while running do
        if app.render then
            system.screen:clear()
            app.render({
                api = api,
                state = state,
                screen = system.screen,
            })
            system.screen:present()
        end
        local event = system.screen:pull_event(0.1)
        if event then
            system.scheduler.tick(event)
        else
            system.scheduler.tick({ type = "tick" })
        end
        if event then
            if event.type == "key" and keys and event.raw and event.raw[2] == keys.q then
                running = false
            elseif app.on_event then
                local keep_open = app.on_event({
                    api = api,
                    state = state,
                    screen = system.screen,
                    event = event,
                })
                if keep_open == false then
                    running = false
                end
            end
        end
    end
    return true
end

return manager
