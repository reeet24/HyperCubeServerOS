local response = require("Kernal.response")
local context_builder = require("Kernal.context")

local process_manager = {}

local process_table = {}
local ready_queue = {}
local next_pid = 1

process_manager.statuses = {
    RUNNING = "Running",
    WAITING = "Waiting",
    SUSPENDED = "Suspended",
    DEAD = "Dead",
    SLEEPING = "Sleeping",
}

process_manager.exit_codes = {
    SUCCESS = 0,
    ERROR = 1,
    KILLED = 3,
}

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function clone_shallow(source)
    local out = {}
    for key, value in pairs(source or {}) do
        out[key] = value
    end
    return out
end

local function generate_pid()
    local pid = next_pid
    next_pid = next_pid + 1
    return pid
end

local function queue_pid(pid)
    for _, queued in ipairs(ready_queue) do
        if queued == pid then
            return
        end
    end
    table.insert(ready_queue, pid)
end

local function remove_from_queue(pid)
    for i = #ready_queue, 1, -1 do
        if ready_queue[i] == pid then
            table.remove(ready_queue, i)
        end
    end
end

local function ensure_context(process)
    if process.context then
        return process.context
    end

    process.context = context_builder.create(process.pid, {
        parentPid = process.parent_pid,
        user = process.user,
        privilege = process.privilege,
        sandbox = process.sandbox,
        env = process.env,
        tags = process.tags,
        groups = process.groups,
        origin = "process_manager",
    })
    process.context.fd_table = process.context.fd_table or {}
    process.context.next_fd = process.context.next_fd or 3
    return process.context
end

local function public_process_view(process)
    if not process then
        return nil
    end

    return {
        pid = process.pid,
        name = process.name,
        status = process.status,
        parent_pid = process.parent_pid,
        children = clone_shallow(process.children),
        daemon = process.daemon,
        privilege = process.privilege,
        user = process.user,
        created_at = process.created_at,
        started_at = process.started_at,
        ended_at = process.ended_at,
        exit_code = process.exit_code,
        error = process.error,
        cpu_time = process.cpu_time,
        wake_at = process.wake_at,
    }
end

local function success(code, result)
    return response.success_response(code, {
        origin = "process_manager",
        result = result,
    })
end

local function fail(code, error_id)
    return response.error(code, {
        origin = "process_manager",
        error_id = error_id,
    })
end

function process_manager.new_sandbox(_, isolation_level, resources, permissions)
    return {
        resources = resources or {
            memory = { available = 1024 * 64, used = 0 },
            cpu = { available = 100, used = 0 },
            disk_space = { available = 1024 * 1024, used = 0 },
        },
        permissions = permissions or {},
        isolation_level = isolation_level or "None",
    }
end

function process_manager.validate_sandbox(_, sandbox)
    if type(sandbox) ~= "table" then
        return fail("InvalidSandbox", "SandboxMustBeTable")
    end
    if type(sandbox.resources or {}) ~= "table" then
        return fail("InvalidSandbox", "ResourcesMustBeTable")
    end
    if type(sandbox.permissions or {}) ~= "table" then
        return fail("InvalidSandbox", "PermissionsMustBeTable")
    end
    return success("ProcessSandboxCreated", sandbox)
end

function process_manager.new_process_metadata(_, name, entrypoint, privilege, sandbox, parent_pid)
    return {
        name = name,
        entrypoint = entrypoint,
        privilege = privilege or "user",
        sandbox = sandbox,
        parent_pid = parent_pid,
    }
end

local function normalize_metadata(metadata)
    if type(metadata) ~= "table" then
        return nil, "MetadataMustBeTable"
    end

    local entrypoint = metadata.entrypoint or metadata.execution_content
    if type(metadata.name) ~= "string" or metadata.name == "" then
        return nil, "NameRequired"
    end
    if type(entrypoint) ~= "function" then
        return nil, "EntrypointMustBeFunction"
    end

    local privilege = metadata.privilege or metadata.privilege_level or "user"
    local privilege_map = {
        User = "user",
        Sudo = "system",
        System = "system",
        Kernel = "root",
        user = "user",
        system = "system",
        root = "root",
    }

    privilege = privilege_map[privilege]
    if not privilege then
        return nil, "InvalidPrivilege"
    end

    return {
        name = metadata.name,
        entrypoint = entrypoint,
        privilege = privilege,
        sandbox = metadata.sandbox or process_manager.new_sandbox(nil, "None"),
        parent_pid = metadata.parent_pid or metadata.parent_process_id,
        daemon = metadata.daemon == true,
        env = metadata.env or {},
        user = metadata.user or "root",
        groups = metadata.groups or {},
        tags = metadata.tags or {},
    }
end

function process_manager.create_process(_, metadata)
    local normalized, err = normalize_metadata(metadata)
    if not normalized then
        return fail("InvalidProcessMetadata", err)
    end

    local parent = nil
    if normalized.parent_pid then
        parent = process_table[normalized.parent_pid]
        if not parent then
            return fail("ProcessNotFound", "ParentNotFound")
        end
    end

    local pid = generate_pid()
    local process = {
        pid = pid,
        id = pid,
        name = normalized.name,
        coroutine = coroutine.create(normalized.entrypoint),
        status = process_manager.statuses.RUNNING,
        privilege = normalized.privilege,
        sandbox = normalized.sandbox,
        parent_pid = normalized.parent_pid,
        children = {},
        daemon = normalized.daemon,
        env = normalized.env,
        user = normalized.user,
        groups = normalized.groups,
        tags = normalized.tags,
        created_at = now(),
        started_at = os.clock(),
        ended_at = nil,
        exit_code = nil,
        error = nil,
        cpu_time = 0,
        wake_at = nil,
        last_yield = nil,
    }
    process.execution_content = process.coroutine
    ensure_context(process)

    process_table[pid] = process
    if parent then
        table.insert(parent.children, pid)
    end
    queue_pid(pid)

    return success("ProcessSpawned", public_process_view(process))
end

function process_manager.spawn(context, name, entrypoint, options)
    options = options or {}
    return process_manager.create_process(context, {
        name = name,
        entrypoint = entrypoint,
        privilege = options.privilege or options.privilege_level,
        sandbox = options.sandbox,
        parent_pid = options.parent_pid,
        daemon = options.daemon,
        env = options.env,
        user = options.user,
        groups = options.groups,
        tags = options.tags,
    })
end

function process_manager.spawn_daemon(context, name, entrypoint, options)
    options = options or {}
    options.daemon = true
    return process_manager.spawn(context, name, entrypoint, options)
end

function process_manager.get(pid)
    return process_table[pid]
end

function process_manager.info(_, pid)
    local process = process_table[pid]
    if not process then
        return fail("ProcessNotFound", "NotFound")
    end
    return success("ProcessInfoRetrieved", public_process_view(process))
end

function process_manager.list()
    local list = {}
    for pid, process in pairs(process_table) do
        list[#list + 1] = public_process_view(process)
    end
    table.sort(list, function(a, b) return a.pid < b.pid end)
    return success("ProcessInfoRetrieved", list)
end

function process_manager.kill(_, pid, reason)
    local process = process_table[pid]
    if not process then
        return fail("ProcessNotFound", "NotFound")
    end
    if process.status == process_manager.statuses.DEAD then
        return fail("InvalidProcessState", "AlreadyDead")
    end

    process.status = process_manager.statuses.DEAD
    process.exit_code = process_manager.exit_codes.KILLED
    process.error = reason or "Killed"
    process.ended_at = os.clock()
    remove_from_queue(pid)
    return success("ProcessTerminated", public_process_view(process))
end

function process_manager.suspend(_, pid)
    local process = process_table[pid]
    if not process then
        return fail("ProcessNotFound", "NotFound")
    end
    if process.status ~= process_manager.statuses.RUNNING and process.status ~= process_manager.statuses.SLEEPING then
        return fail("InvalidProcessState", "CannotSuspend")
    end
    process.status = process_manager.statuses.SUSPENDED
    remove_from_queue(pid)
    return success("ProcessInfoRetrieved", public_process_view(process))
end

function process_manager.resume(_, pid)
    local process = process_table[pid]
    if not process then
        return fail("ProcessNotFound", "NotFound")
    end
    if process.status ~= process_manager.statuses.SUSPENDED then
        return fail("InvalidProcessState", "CannotResume")
    end
    process.status = process_manager.statuses.RUNNING
    process.wake_at = nil
    queue_pid(pid)
    return success("ProcessInfoRetrieved", public_process_view(process))
end

local function finish_process(process, exit_code, err)
    process.status = process_manager.statuses.DEAD
    process.exit_code = exit_code
    process.error = err
    process.ended_at = os.clock()
    remove_from_queue(process.pid)
end

local function handle_yield(process, signal, payload)
    process.last_yield = { signal = signal, payload = payload }

    if signal == "sleep" then
        local duration = tonumber(payload) or 0
        process.status = process_manager.statuses.SLEEPING
        process.wake_at = os.clock() + math.max(0, duration)
    elseif signal == "wait" or signal == "event" then
        process.status = process_manager.statuses.WAITING
    else
        process.status = process_manager.statuses.RUNNING
    end
end

function process_manager.tick_process_queue(event)
    local tick_started = os.clock()
    local snapshot = clone_shallow(ready_queue)

    for _, pid in ipairs(snapshot) do
        local process = process_table[pid]
        if process then
            if process.status == process_manager.statuses.SLEEPING and process.wake_at and os.clock() >= process.wake_at then
                process.status = process_manager.statuses.RUNNING
                process.wake_at = nil
            end

            if process.status == process_manager.statuses.RUNNING then
                local runtime_start = os.clock()
                local ok, signal, payload = coroutine.resume(process.coroutine, ensure_context(process), event)
                process.cpu_time = process.cpu_time + (os.clock() - runtime_start)

                if not ok then
                    finish_process(process, process_manager.exit_codes.ERROR, signal)
                elseif coroutine.status(process.coroutine) == "dead" then
                    finish_process(process, process_manager.exit_codes.SUCCESS)
                else
                    handle_yield(process, signal, payload)
                end
            end
        end
    end

    return success("ProcessQueueTicked", { elapsed = os.clock() - tick_started })
end

function process_manager.cleanup_dead(include_daemons)
    for pid, process in pairs(process_table) do
        if process.status == process_manager.statuses.DEAD and (include_daemons or not process.daemon) then
            process_table[pid] = nil
        end
    end
end

process_manager.registry = process_table
process_manager.ready_queue = ready_queue

return process_manager
