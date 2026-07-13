local acl = {}

-- Privilege hierarchy
local LEVELS = {
    user = 1,
    system = 2,
    root = 3,
}

-- Capability rule format:
-- required: minimum privilege level
-- groups: table of allowed groups (optional)
local RESOURCE_CAPABILITIES = {
    ["fs.read"] =         { required = "user" },
    ["fs.write"] =        { required = "system", groups = { "dev" } },
    ["fs.delete"] =       { required = "root" },

    ["net.send"] =        { required = "user" },
    ["driver.gpu.control"] = { required = "system", groups = { "video" } },

    ["sys.shutdown"] =    { required = "root" },
    ["sys.spawn_process"] = { required = "system" },
}

--- Check whether context meets privilege requirements
local function checkPrivilegeLevel(context, requiredLevel)
    local ctxLevel = LEVELS[context.privilege or "user"]
    local ruleLevel = LEVELS[requiredLevel]
    return ctxLevel and ctxLevel >= ruleLevel
end

--- Check whether the context's groups satisfy the ACL rule
local function checkGroupAccess(context, rule)
    if not rule.groups or #rule.groups == 0 then
        return true
    end

    local ctxGroups = context.groups or {}
    for _, group in ipairs(ctxGroups) do
        for _, allowed in ipairs(rule.groups) do
            if group == allowed then
                return true
            end
        end
    end

    return false
end

--- Check access to a given resource based on context
-- @param context table: the execution context
-- @param resource string: resource name
-- @return boolean, string: access granted, error message
function acl.check(context, resource)
    if type(context) ~= "table" then
        return false, "Invalid context"
    end

    local rule = RESOURCE_CAPABILITIES[resource]
    if not rule then
        return false, "No ACL rule defined for resource: " .. resource
    end

    if not checkPrivilegeLevel(context, rule.required) then
        return false, string.format(
            "Access denied: requires '%s' privilege, got '%s'",
            rule.required, context.privilege or "none"
        )
    end

    if not checkGroupAccess(context, rule) then
        return false, "Access denied: insufficient group permissions"
    end

    return true
end

--- Elevate privilege using sudo-like system (context must support it)
-- @param context table: the original context
-- @param targetPrivilege string: the requested privilege level
-- @return boolean, string: success flag and message
function acl.sudo(context, targetPrivilege)
    local allowed = context.sudo_allow or {}

    -- Only contexts with a sudo_allow table can elevate
    if type(allowed) ~= "table" then
        return false, "Sudo not permitted for this context"
    end

    for _, level in ipairs(allowed) do
        if level == targetPrivilege then
            context.privilege = targetPrivilege
            context.tags = context.tags or {}
            context.tags.sudo = true
            return true, "Privilege elevated to " .. targetPrivilege
        end
    end

    return false, "Insufficient sudo rights"
end

--- Drop back to previous privilege if context is in sudo mode
function acl.sudo_revert(context, defaultPrivilege)
    if context.tags and context.tags.sudo then
        context.privilege = defaultPrivilege or "user"
        context.tags.sudo = nil
        return true, "Privilege reverted to " .. context.privilege
    end
    return false, "Not in sudo mode"
end

return acl
