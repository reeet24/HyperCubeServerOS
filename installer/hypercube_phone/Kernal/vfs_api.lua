local response = require("Kernal.response")
local RamDisk = require("Kernal.drivers.ramdisk")
local FileHandle = require("Kernal.filehandle")

local vfs = {}
vfs.mounts = {
    root = RamDisk.new("rootfs")
}

-- === Utility ===

local function split_path(path)
    return path:match("^(.*)/([^/]+)$") or "/", path
end

local function resolve_mount(path)
    -- For now, single mount root
    return vfs.mounts.root
end

-- Normalizes redundant slashes and ".."
local function normalize_path(path)
    local parts, result = {}, {}

    for part in path:gmatch("[^/]+") do
        if part == ".." then
            table.remove(result)
        elseif part ~= "." and part ~= "" then
            table.insert(result, part)
        end
    end

    return "/" .. table.concat(result, "/")
end

-- Sandbox-aware path resolver
local function resolve_path(context, requested_path)
    local clean_requested = normalize_path(requested_path)

    if context.privilege == "root" or not context.sandbox then
        return clean_requested -- unrestricted
    end

    local sandbox_root = "/"
    if type(context.sandbox) == "string" then
        sandbox_root = context.sandbox
    elseif type(context.sandbox) == "table" then
        sandbox_root = context.sandbox.root or context.sandbox.path or "/"
    end

    local clean_sandbox = normalize_path(sandbox_root)

    if clean_requested == clean_sandbox or clean_requested:sub(1, #clean_sandbox + 1) == clean_sandbox .. "/" then
        return clean_requested
    end

    -- Absolute path inside sandbox
    local combined = normalize_path(clean_sandbox .. "/" .. clean_requested)
    
    -- Enforce sandbox escape prevention
    if combined:sub(1, #clean_sandbox) ~= clean_sandbox then
        return nil, "PathEscapeViolation"
    end

    return combined
end


-- === API ===

function vfs.mkdir(context, path)
    local resolved_path, err = resolve_path(context, path)
    if not resolved_path then
        return response.error("InvalidPrivilege", {
            origin = "vfs.read_file",
            error_id = err or "SandboxViolation"
        })
    end

    local fs = resolve_mount(resolved_path)
    local inode, create_err = fs:create_file(context, resolved_path, "dir")
    if not inode then
        return response.error("InvalidResource", {
            origin = "vfs.mkdir",
            error_id = create_err or "CreateDirectoryFailed"
        })
    end

    return response.success_response("DirectoryCreated", {
        origin = "vfs.mkdir",
        result = { path = resolved_path, inode_id = inode.id }
    })
end

function vfs.create_file(context, path)
    local resolved_path, err = resolve_path(context, path)
    if not resolved_path then
        return response.error("InvalidPrivilege", {
            origin = "vfs.read_file",
            error_id = err or "SandboxViolation"
        })
    end

    local fs = resolve_mount(resolved_path)

    if fs:get_inode(resolved_path) then
        return response.error("InvalidResource", {
            origin = "vfs.create_file",
            error_id = "AlreadyExists"
        })
    end

    local parent_path = resolved_path:match("^(.*)/[^/]+$") or "/"
    local parent_inode = fs:get_inode(parent_path)
    if not parent_inode or parent_inode.type ~= "dir" then
        return response.error("InvalidResource", {
            origin = "vfs.create_file",
            error_id = "ParentInvalid"
        })
    end

    if parent_inode.owner ~= context.user and context.privilege ~= "root" then
        return response.error("InvalidPrivilege", {
            origin = "vfs.create_file",
            error_id = "PermissionDenied"
        })
    end

    local inode = fs:create_inode(resolved_path, "file", context.user)
    fs.path_to_inode[resolved_path] = inode.id

    parent_inode.children = parent_inode.children or {}
    table.insert(parent_inode.children, resolved_path:match("[^/]+$"))
    parent_inode.modified = os.time()

    return response.success_response("FileCreated", {
        origin = "vfs.create_file",
        result = { path = resolved_path, inode_id = inode.id }
    })
end

function vfs.write_file(context, path, data)
    local resolved_path, err = resolve_path(context, path)
    if not resolved_path then
        return response.error("InvalidPrivilege", {
            origin = "vfs.read_file",
            error_id = err or "SandboxViolation"
        })
    end

    local fs = resolve_mount(resolved_path)

    local ok, err = fs:write_file(context, resolved_path, data)
    if not ok then
        return response.error("IOFailure", {
            origin = "vfs.write_file",
            error_id = err or "WriteFailed"
        })
    end

    return response.success_response("FileWritten", {
        origin = "vfs.write_file",
        result = { path = resolved_path }
    })
end

function vfs.read_file(context, path)
    local resolved_path, err = resolve_path(context, path)
    if not resolved_path then
        return response.error("InvalidPrivilege", {
            origin = "vfs.read_file",
            error_id = err or "SandboxViolation"
        })
    end

    local fs = resolve_mount(resolved_path)

    local data, err = fs:read_file(context, resolved_path)
    if not data then
        return response.error("InvalidResource", {
            origin = "vfs.read_file",
            error_id = err or "ReadFailed"
        })
    end

    return response.success_response("FileRead", {
        origin = "vfs.read_file",
        result = { data = data }
    })
end

function vfs.delete_file(context, path)
    local resolved_path, err = resolve_path(context, path)
    if not resolved_path then
        return response.error("InvalidPrivilege", {
            origin = "vfs.read_file",
            error_id = err or "SandboxViolation"
        })
    end

    local fs = resolve_mount(resolved_path)

    local ok, err = fs:delete_file(context, resolved_path)
    if not ok then
        return response.error("InvalidResource", {
            origin = "vfs.delete_file",
            error_id = err or "DeleteFailed"
        })
    end

    return response.success_response("FileDeleted", {
        origin = "vfs.delete_file",
        result = { path = resolved_path }
    })
end

function vfs.list_dir(context, path)
    local resolved_path, err = resolve_path(context, path)
    if not resolved_path then
        return response.error("InvalidPrivilege", {
            origin = "vfs.read_file",
            error_id = err or "SandboxViolation"
        })
    end

    local fs = resolve_mount(resolved_path)

    local list, err = fs:list_dir(context, resolved_path)
    if not list then
        return response.error("InvalidResource", {
            origin = "vfs.list_dir",
            error_id = err or "ListFailed"
        })
    end

    return response.success_response("DirectoryListed", {
        origin = "vfs.list_dir",
        result = { entries = list }
    })
end

function vfs.open(context, path, mode)
    local resolved, err = resolve_path(context, path)
    if not resolved then
        return response.error("InvalidPrivilege", {
            origin = "vfs.open",
            error_id = err or "SandboxViolation"
        })
    end

    local fs = resolve_mount(resolved)

    -- Ensure file exists for reading, or create if mode allows
    if not fs:get_inode(resolved) then
        if mode and mode:match("w") then
            local created = vfs.create_file(context, resolved)
            if created.type ~= "success" then
                return response.error("InvalidResource", {
                    origin = "vfs.open",
                    error_id = "AutoCreateFailed"
                })
            end
        else
            return response.error("InvalidResource", {
                origin = "vfs.open",
                error_id = "NotFound"
            })
        end
    end

    local handle, herr = FileHandle.new(vfs, context, resolved, mode)
    if not handle then
        return response.error("IOFailure", {
            origin = "vfs.open",
            error_id = herr
        })
    end

    return response.success_response("FileOpened", {
        origin = "vfs.open",
        result = { handle = handle }
    })
end

function vfs.open_fd(context, path, mode)
    local res = vfs.open(context, path, mode)
    if res.type ~= "success" then return res end

    local handle = res.result.handle
    local fd = context.next_fd
    context.fd_table[fd] = handle
    context.next_fd = fd + 1

    return response.success_response("FileOpenedFD", {
        origin = "vfs.open_fd",
        result = { fd = fd, handle = handle }
    })
end

function vfs.read_fd(context, fd, n)
    local handle = context.fd_table[fd]
    if not handle then
        return response.error("InvalidResource", {
            origin = "vfs.read_fd",
            error_id = "InvalidFD"
        })
    end

    local data, err = handle:read(n)
    if not data then
        return response.error("IOFailure", {
            origin = "vfs.read_fd",
            error_id = err
        })
    end

    return response.success_response("FDRead", {
        origin = "vfs.read_fd",
        result = { data = data }
    })
end

function vfs.write_fd(context, fd, data)
    local handle = context.fd_table[fd]
    if not handle then
        return response.error("InvalidResource", {
            origin = "vfs.write_fd",
            error_id = "InvalidFD"
        })
    end

    local ok, err = handle:write(data)
    if not ok then
        return response.error("IOFailure", {
            origin = "vfs.write_fd",
            error_id = err
        })
    end

    return response.success_response("FDWrite", {
        origin = "vfs.write_fd",
        result = { bytes_written = #data }
    })
end

function vfs.close_fd(context, fd)
    local handle = context.fd_table[fd]
    if not handle then
        return response.error("InvalidResource", {
            origin = "vfs.close_fd",
            error_id = "InvalidFD"
        })
    end

    local ok, err = handle:close()
    context.fd_table[fd] = nil

    if not ok then
        return response.error("IOFailure", {
            origin = "vfs.close_fd",
            error_id = err
        })
    end

    return response.success_response("FDClose", {
        origin = "vfs.close_fd",
        result = { fd = fd }
    })
end


return vfs
