local response = {}

response.errors = {
    InvalidPrivilege = {
        code = 400,
        message = "You do not have the required privileges to perform this action.",
        description = "This error occurs when a process attempts to perform an action that requires a higher privilege level than it currently has.",
    },
    ProcessNotFound = {
        code = 401,
        message = "The specified process could not be found.",
        description = "This error occurs when a process ID is provided that does not correspond to any currently running process.",
    },
    InvalidProcessState = {
        code = 402,
        message = "The process is in an invalid state for this operation.",
        description = "This error occurs when an operation is attempted on a process that is not in a state that allows it (e.g., trying to terminate a process that is already dead).",
    },
    InvalidSandbox = {
        code = 403,
        message = "The sandbox environment is invalid or does not exist.",
        description = "This error occurs when a process attempts to access or modify a sandbox that is not properly defined or does not exist.",
    },
    InvalidType = {
        code = 404,
        message = "The provided type is invalid.",
        description = "This error occurs when a process attempts to use a type that is not recognized or supported by the system.",
    },
    InvalidMetadata = {
        code = 405,
        message = "The provided metadata is invalid.",
        description = "This error occurs when the metadata provided for a process does not meet the required format or contains invalid values.",
    },
    InvalidResource = {
        code = 406,
        message = "The requested resource is invalid or unavailable.",
        description = "This error occurs when a process attempts to access a resource that does not exist or is not available in the current context.",
    },
    InvalidExecutionContent = {
        code = 407,
        message = "The execution content provided is invalid.",
        description = "This error occurs when the execution content for a process is not a valid function or does not meet the required criteria.",
    },
    InvalidProcessName = {
        code = 408,
        message = "The process name is invalid.",
        description = "This error occurs when a process name does not conform to the required naming conventions or is empty.",
    },
    InvalidProcessID = {
        code = 409,
        message = "The process ID is invalid.",
        description = "This error occurs when a process ID does not conform to the expected format or is not recognized by the system.",
    },
    InvalidProcessMetadata = {
        code = 410,
        message = "The process metadata is invalid.",
        description = "This error occurs when the metadata provided for a process does not conform to the expected structure or contains invalid values.",
    },
    InvalidProcessExecution = {
        code = 411,
        message = "The process execution is invalid.",
        description = "This error occurs when a process attempts to execute an operation that is not allowed or is in an invalid state for execution.",
    },
    InvalidProcessPrivilege = {
        code = 412,
        message = "The process does not have the required privilege for this operation.",
        description = "This error occurs when a process attempts to perform an operation that requires a higher privilege level than it currently has.",
    },
    InvalidProcessSandbox = {
        code = 413,
        message = "The process sandbox is invalid or does not exist.",
        description = "This error occurs when a process attempts to access or modify a sandbox that is not properly defined or does not exist.",
    },
    InvalidProcessIsolation = {
        code = 414,
        message = "The process isolation level is invalid.",
        description = "This error occurs when a process attempts to set or access an isolation level that is not recognized or supported by the system.",
    },
    InvalidProcessResource = {
        code = 415,
        message = "The process resource is invalid or unavailable.",
        description = "This error occurs when a process attempts to access a resource that does not exist or is not available in the current context.",
    },

}

response.success = {
    ProcessSpawned = {
        code = 200,
        message = "Process spawned successfully.",
        description = "This response indicates that a new process has been successfully spawned with the provided metadata.",
    },
    ProcessTerminated = {
        code = 201,
        message = "Process terminated successfully.",
        description = "This response indicates that a process has been successfully terminated.",
    },
    ProcessInfoRetrieved = {
        code = 202,
        message = "Process information retrieved successfully.",
        description = "This response indicates that the information for a specified process has been successfully retrieved.",
    },
    ProcessSandboxCreated = {
        code = 203,
        message = "Process sandbox created successfully.",
        description = "This response indicates that a new sandbox environment for a process has been successfully created.",
    },
    ProcessQueueTicked = {
        code = 204,
        message = "Process queue ticked successfully.",
        description = "This response indicates that the process queue has been successfully ticked, allowing processes to execute their scheduled tasks.",
    },
}

response.info = {
    ProcessRunning = {
        code = 300,
        message = "The process is currently running.",
        description = "This response indicates that the specified process is currently in a running state.",
    },
    ProcessPaused = {
        code = 301,
        message = "The process is currently paused.",
        description = "This response indicates that the specified process is currently in a paused state.",
    },
    ProcessStopped = {
        code = 302,
        message = "The process has been stopped.",
        description = "This response indicates that the specified process has been stopped and is no longer running.",
    },
}

response.warnings = {
    ProcessNotResponding = {
        code = 500,
        message = "The process is not responding.",
        description = "This warning indicates that the specified process is not responding to requests or commands.",
    },
    ProcessResourceLimitReached = {
        code = 501,
        message = "The process has reached its resource limit.",
        description = "This warning indicates that the specified process has reached its allocated resource limits (e.g., memory, CPU).",
    },
}

response.debug = {
    ProcessDebugInfo = {
        code = 600,
        message = "Process debug information retrieved successfully.",
        description = "This response indicates that debug information for a specified process has been successfully retrieved.",
    },
    ProcessExecutionTrace = {
        code = 601,
        message = "Process execution trace retrieved successfully.",
        description = "This response indicates that the execution trace for a specified process has been successfully retrieved.",
    },
}

response.codes = {
    -- Error codes
    InvalidPrivilege = 400,
    ProcessNotFound = 401,
    InvalidProcessState = 402,
    InvalidSandbox = 403,
    InvalidType = 404,
    InvalidMetadata = 405,
    InvalidResource = 406,
    InvalidExecutionContent = 407,
    InvalidProcessName = 408,
    InvalidProcessID = 409,
    InvalidProcessMetadata = 410,
    InvalidProcessExecution = 411,
    InvalidProcessPrivilege = 412,
    InvalidProcessSandbox = 413,
    InvalidProcessIsolation = 414,
    InvalidProcessResource = 415,

    -- Success codes
    ProcessSpawned = 200,
    ProcessTerminated = 201,
    ProcessInfoRetrieved = 202,
    ProcessSandboxCreated = 203,
    ProcessQueueTicked = 204,

    -- Info codes
    ProcessRunning = 300,
    ProcessPaused = 301,
    ProcessStopped = 302,

    -- Warning codes
    ProcessNotResponding = 500,
    ProcessResourceLimitReached = 501,

    -- Debug codes
    ProcessDebugInfo = 600,
    ProcessExecutionTrace = 601,
}

function response.wrap(is_success, template, context)
    return {
        type = is_success and "success" or "error",
        success = is_success,
        code = template.code,
        message = template.message,
        description = template.description,
        origin = context and context.origin,
        additional_info = context and context.additional_info,
        result = context and context.result, -- for success
        error = not is_success and context and context.error_id,
    }
end


response.error = function (error_code, context)
    local error_response = response.errors[error_code]
    if not error_response then
        error_response = {
            code = 500,
            message = "An unknown error occurred.",
            description = "An unexpected error has occurred. Please try again later.",
        }
    end

    return response.wrap(false, error_response, context)
end

response.success_response = function (success_code, context)
    local success_response = response.success[success_code]
    if not success_response then
        success_response = {
            code = 200,
            message = "Operation completed successfully.",
            description = "The operation was completed without any issues.",
        }
    end

    return response.wrap(true, success_response, context)
end

response.warn = function (warning_code, context)
    local warning_response = response.warnings[warning_code]
    if not warning_response then
        warning_response = {
            code = 500,
            message = "An unknown warning occurred.",
            description = "An unexpected warning has occurred. Please check the system logs for more details.",
        }
    end

    return response.wrap(false, warning_response, context)
end

response.info_response = function (info_code, context)
    local info_response = response.info[info_code]
    if not info_response then
        info_response = {
            code = 300,
            message = "Information retrieved successfully.",
            description = "The requested information has been retrieved without any issues.",
        }
    end

    return response.wrap(true, info_response, context)
end

response.get_response_by_code = function (code, context)
    for _, response_type in pairs({response.errors, response.success, response.info, response.warnings, response.debug}) do
        for _, template in pairs(response_type) do
            if template.code == code then
                return response.wrap(true, template, context)
            end
        end
    end

    return response.wrap(false, {
        code = 404,
        message = "Response code not found.",
        description = "The specified response code does not exist.",
    }, context)
end

return response
