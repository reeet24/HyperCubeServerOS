local contextBuilder = require("Kernal.context")
local acl = require("Kernal.acl")

local syswrap = {}

--- Wrap a system function with context validation and optional ACL
-- @param fn function: the system function to wrap
-- @param resource string|nil: optional resource name for ACL check
-- @return function: wrapped function
function syswrap.secure(fn, resource)
    return function(context, ...)
        -- Validate context
        local ok, err = contextBuilder.validate(context)
        if not ok then
            return nil, "Invalid context: " .. err
        end

        -- ACL check if applicable
        if resource then
            local allowed, reason = acl.check(context, resource)
            if not allowed then
                return nil, "Access denied: " .. reason
            end
        end

        -- Call function safely
        return fn(context, ...)
    end
end

return syswrap
