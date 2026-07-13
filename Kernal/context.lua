local contextBuilder = {}

local VALID_PRIVILEGE_LEVELS = {
    user = true,
    system = true,
    root = true,
}

local DEFAULT_ORIGIN = "process_manager"

local function epoch()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

--- Create a new process context
-- @param pid number: unique process ID
-- @param metadata table: optional additional context metadata
contextBuilder.create = function(pid, metadata)
    metadata = metadata or {}

    local context = {
        pid = pid,
        parentPid = metadata.parentPid or nil,
        user = metadata.user or "root",
        privilege = metadata.privilege or "user",
        sandbox = metadata.sandbox or {},
        created_at = epoch(),
        origin = metadata.origin or DEFAULT_ORIGIN,
        env = metadata.env or {},
        tags = metadata.tags or {},
        groups = metadata.groups or {},
        sudo_allow = metadata.sudo_allow or {}, -- sudo privileges (e.g., { "system" })
    }

    return context
end

--- Validate a context structure
-- @param context table: the context to check
-- @return boolean, string|nil: whether it's valid, and error message if not
contextBuilder.validate = function(context)
    if type(context) ~= "table" then
        return false, "Invalid context: must be a table."
    end

    if type(context.pid) ~= "number" then
        return false, "Invalid context: 'pid' must be a number."
    end

    if context.parentPid and type(context.parentPid) ~= "number" then
        return false, "Invalid context: 'parentPid' must be a number if set."
    end

    if type(context.user) ~= "string" then
        return false, "Invalid context: 'user' must be a string."
    end

    if not VALID_PRIVILEGE_LEVELS[context.privilege] then
        return false, "Invalid context: 'privilege' must be one of: user/system/root."
    end

    if type(context.created_at) ~= "number" then
        return false, "Invalid context: 'created_at' must be a number (epoch)."
    end

    if type(context.sandbox) ~= "table" then
        return false, "Invalid context: 'sandbox' must be a table."
    end

    if type(context.env) ~= "table" then
        return false, "Invalid context: 'env' must be a table."
    end

    if type(context.tags) ~= "table" then
        return false, "Invalid context: 'tags' must be a table."
    end

    if type(context.groups) ~= "table" then
        return false, "Invalid context: 'groups' must be a table."
    end

    if type(context.sudo_allow) ~= "table" then
        return false, "Invalid context: 'sudo_allow' must be a table."
    end

    return true, nil
end

return contextBuilder
