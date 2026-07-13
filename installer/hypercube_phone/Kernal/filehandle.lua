local FileHandle = {}
FileHandle.__index = FileHandle

function FileHandle.new(vfs, context, path, mode)
    local self = setmetatable({}, FileHandle)
    self.vfs = vfs
    self.context = context
    self.path = path
    self.mode = mode or "r"
    self.offset = 0
    self.closed = false

    local data = ""
    if self.mode:match("[ra]") then
        local read_result = vfs.read_file(context, path)
        if read_result.type ~= "success" then
            return nil, read_result.error or "ReadFailure"
        end
        data = read_result.result.data or ""
    end

    self.buffer = data
    if self.mode:match("a") then
        self.offset = #self.buffer
    end
    return self
end

function FileHandle:check_open()
    if self.closed then return false, "ClosedHandle" end
    return true
end

function FileHandle:read(n)
    local ok, err = self:check_open()
    if not ok then return nil, err end
    if n == nil then
        n = #self.buffer - self.offset
    end
    local chunk = self.buffer:sub(self.offset + 1, self.offset + n)
    self.offset = self.offset + #chunk
    return chunk
end

function FileHandle:write(data)
    local ok, err = self:check_open()
    if not ok then return false, err end
    if not self.mode:match("[wa]") then return false, "WriteDenied" end

    local pre = self.buffer:sub(1, self.offset)
    local post = self.buffer:sub(self.offset + #data + 1)
    self.buffer = pre .. data .. post
    self.offset = self.offset + #data
    return true
end

function FileHandle:seek(offset, whence)
    local ok, err = self:check_open()
    if not ok then return false, err end
    whence = whence or "set"

    if whence == "set" then
        self.offset = math.max(0, offset)
    elseif whence == "cur" then
        self.offset = math.max(0, self.offset + offset)
    elseif whence == "end" then
        self.offset = math.max(0, #self.buffer + offset)
    else
        return false, "InvalidSeek"
    end

    return self.offset
end

function FileHandle:close()
    if self.closed then return false, "AlreadyClosed" end
    self.closed = true

    if self.mode:match("[wa]") then
        local result = self.vfs.write_file(self.context, self.path, self.buffer)
        if not result or result.success ~= true then
            return false, "FlushWriteFailed: " .. tostring(result and result.error)
        end
    end

    return true
end

return FileHandle
