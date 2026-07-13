local RamDisk = {}
RamDisk.__index = RamDisk

local BLOCK_SIZE = 512
local TOTAL_BLOCKS = 4096

-- Helper: Create empty block data (string of zeros)
local function empty_block()
    return ("\0"):rep(BLOCK_SIZE)
end

-- Constructor: Initialize a new RAMDisk instance
function RamDisk.new(label)
    local self = setmetatable({}, RamDisk)

    self.label = label or "hypercube_ramdisk"
    self.block_size = BLOCK_SIZE
    self.total_blocks = TOTAL_BLOCKS

    -- Disk blocks storage (index = block id)
    self.blocks = {}
    for i = 1, TOTAL_BLOCKS do
        self.blocks[i] = empty_block()
    end

    -- Block usage map: true = used, false = free
    self.block_map = {}
    for i = 1, TOTAL_BLOCKS do
        self.block_map[i] = false
    end

    -- Inode table: id -> inode metadata
    self.inodes = {}
    self.next_inode_id = 1

    -- Map paths to inodes for quick lookup
    self.path_to_inode = {}

    -- Root directory inode initialization
    local root_inode = self:create_inode("/", "dir", "root")
    self.path_to_inode["/"] = root_inode.id

    return self
end

function RamDisk.init(context)
    return RamDisk.new(context and context.label or "hypercube_ramdisk")
end

function RamDisk.shutdown()
    return true
end

-- Allocate a free block, mark it used, and return block id
function RamDisk:allocate_block(context)
    for i = 1, self.total_blocks do
        if not self.block_map[i] then
            self.block_map[i] = true
            -- Optional: record ownership metadata
            -- Could attach context.pid or context.user here if desired
            return i
        end
    end
    return nil, "No free blocks available"
end

-- Free a block by block id
function RamDisk:free_block(block_id)
    if block_id < 1 or block_id > self.total_blocks then
        return false, "Invalid block id"
    end
    self.block_map[block_id] = false
    self.blocks[block_id] = empty_block()
    return true
end

-- Create an inode for a file or directory
-- type: "file" or "dir"
function RamDisk:create_inode(path, type, owner)
    local inode = {
        id = self.next_inode_id,
        type = type,
        owner = owner or "root",
        size = 0,
        blocks = {}, -- list of block ids holding file content
        created = os.time(),
        modified = os.time(),
        path = path,
    }
    self.inodes[inode.id] = inode
    self.next_inode_id = self.next_inode_id + 1
    return inode
end

-- Lookup inode by path
function RamDisk:get_inode(path)
    local inode_id = self.path_to_inode[path]
    if not inode_id then return nil end
    return self.inodes[inode_id]
end

-- Convert a 32-bit integer to 4 big-endian bytes
local function int_to_bytes(n)
    local b4 = n % 256
    n = (n - b4) / 256
    local b3 = n % 256
    n = (n - b3) / 256
    local b2 = n % 256
    n = (n - b2) / 256
    local b1 = n % 256
    return string.char(b1, b2, b3, b4)
end

-- Convert 4 big-endian bytes to a 32-bit integer
local function bytes_to_int(s)
    local b1, b2, b3, b4 = s:byte(1,4)
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end


-- Create a file or directory
function RamDisk:create_file(context, path, type)
    if self:get_inode(path) then
        return nil, "File or directory already exists: " .. path
    end

    -- Simple parent directory check
    local parent_path = path:match("^(.*)/[^/]+$")
    if not parent_path or parent_path == "" then parent_path = "/" end

    local parent_inode = self:get_inode(parent_path)
    if not parent_inode or parent_inode.type ~= "dir" then
        return nil, "Parent directory does not exist: " .. tostring(parent_path)
    end

    local inode = self:create_inode(path, type, context.user)
    self.path_to_inode[path] = inode.id

    -- Add child to parent's blocks (storing dir entries as filenames)
    -- Here we store directory entries inside blocks as serialized strings or table; simplified as list

    parent_inode.children = parent_inode.children or {}
    table.insert(parent_inode.children, path:match("[^/]+$")) -- filename

    parent_inode.modified = os.time()

    return inode
end

-- Write data to a file (overwrites)
function RamDisk:write_file(context, path, data)
    local inode = self:get_inode(path)
    if not inode then
        return false, "File does not exist"
    end
    if inode.type ~= "file" then
        return false, "Not a file"
    end
    if inode.owner ~= context.user and context.privilege ~= "root" then
        return false, "Permission denied"
    end

    -- Free old blocks
    for _, block_id in ipairs(inode.blocks) do
        self:free_block(block_id)
    end
    inode.blocks = {}

    local data_len = #data
    local blocks_needed = math.ceil(data_len / BLOCK_SIZE)
    local offset = 1

    for i = 1, blocks_needed do
        local block_id, err = self:allocate_block(context)
        if not block_id then
            return false, "Disk full: " .. (err or "")
        end

        local chunk = data:sub(offset, offset + BLOCK_SIZE - 1)
        self.blocks[block_id] = chunk .. ("\0"):rep(BLOCK_SIZE - #chunk)
        table.insert(inode.blocks, block_id)
        offset = offset + BLOCK_SIZE
    end

    inode.size = data_len
    inode.modified = os.time()

    return true
end

-- Read a file's content
function RamDisk:read_file(context, path)
    local inode = self:get_inode(path)
    if not inode then
        return nil, "File does not exist"
    end
    if inode.type ~= "file" then
        return nil, "Not a file"
    end
    if inode.owner ~= context.user and context.privilege ~= "root" then
        return nil, "Permission denied"
    end

    local chunks = {}
    for _, block_id in ipairs(inode.blocks) do
        table.insert(chunks, self.blocks[block_id])
    end

    local content = table.concat(chunks)
    return content:sub(1, inode.size)
end

-- Delete a file or directory (directories must be empty)
function RamDisk:delete_file(context, path)
    local inode = self:get_inode(path)
    if not inode then
        return false, "File does not exist"
    end
    if inode.owner ~= context.user and context.privilege ~= "root" then
        return false, "Permission denied"
    end
    if inode.type == "dir" then
        if inode.children and #inode.children > 0 then
            return false, "Directory not empty"
        end
    end

    -- Free file blocks
    for _, block_id in ipairs(inode.blocks) do
        self:free_block(block_id)
    end

    -- Remove from parent's children list
    local parent_path = path:match("^(.*)/[^/]+$")
    if not parent_path or parent_path == "" then parent_path = "/" end
    local parent_inode = self:get_inode(parent_path)
    if parent_inode and parent_inode.children then
        for i, child_name in ipairs(parent_inode.children) do
            if child_name == path:match("[^/]+$") then
                table.remove(parent_inode.children, i)
                break
            end
        end
        parent_inode.modified = os.time()
    end

    -- Remove inode entry
    self.path_to_inode[path] = nil
    self.inodes[inode.id] = nil

    return true
end

-- List directory contents
function RamDisk:list_dir(context, path)
    local inode = self:get_inode(path)
    if not inode then
        return nil, "Directory does not exist"
    end
    if inode.type ~= "dir" then
        return nil, "Not a directory"
    end
    if inode.owner ~= context.user and context.privilege ~= "root" then
        return nil, "Permission denied"
    end

    return inode.children or {}
end

-- Save disk image as raw binary
function RamDisk:save(filename)
    local file, err = io.open(filename, "wb")
    if not file then
        return false, "Failed to open file for writing: " .. err
    end

    -- Serialize header as JSON and prefix with 4-byte length
    local header = {
        label = self.label,
        block_size = self.block_size,
        total_blocks = self.total_blocks,
        next_inode_id = self.next_inode_id,
        inodes = self.inodes,
        path_to_inode = self.path_to_inode,
        block_map = self.block_map,
    }
    local json_header = require("json").encode(header)
    local len = #json_header
    local len_bytes = int_to_bytes(len)
    if not len_bytes then
        file:close()
        return false, "Failed to convert header length to bytes"
    end

    file:write(len_bytes)
    file:write(json_header)

    -- Write all blocks raw
    for i = 1, self.total_blocks do
        file:write(self.blocks[i])
    end

    file:close()
    return true
end

-- Load disk image from raw binary
function RamDisk:load(filename)
    local file, err = io.open(filename, "rb")
    if not file then
        return false, "Failed to open file for reading: " .. err
    end

    -- Read 4-byte header length prefix
    local len_bytes = file:read(4)
    local len = bytes_to_int(len_bytes)
    if not len or len <= 0 then
        file:close()
        return false, "Invalid header length"
    end

    -- Read header JSON
    local json_header = file:read(len)
    local header, err2 = require("json").decode(json_header)
    if not header then
        file:close()
        return false, "Failed to decode header: " .. err2
    end

    self.label = header.label
    self.block_size = header.block_size
    self.total_blocks = header.total_blocks
    self.next_inode_id = header.next_inode_id
    self.inodes = header.inodes
    self.path_to_inode = header.path_to_inode
    self.block_map = header.block_map

    -- Read all blocks
    self.blocks = {}
    for i = 1, self.total_blocks do
        local block_data = file:read(self.block_size)
        self.blocks[i] = block_data
    end

    file:close()
    return true
end

function RamDisk:mkdir(context, path)
    -- Reject empty or invalid paths
    if type(path) ~= "string" or path == "" or path:sub(1, 1) ~= "/" then
        return false, "Invalid path"
    end

    if self:get_inode(path) then
        return false, "Directory already exists"
    end

    -- Determine parent directory
    local parent_path = path:match("^(.*)/[^/]+$") or "/"
    if parent_path == "" then parent_path = "/" end

    local parent_inode = self:get_inode(parent_path)
    if not parent_inode or parent_inode.type ~= "dir" then
        return false, "Parent directory not found"
    end

    -- Access control
    if parent_inode.owner ~= context.user and context.privilege ~= "root" then
        return false, "Permission denied"
    end

    -- Create new directory inode
    local inode = self:create_inode(path, "dir", context.user)
    self.path_to_inode[path] = inode.id

    -- Register in parent's child list
    parent_inode.children = parent_inode.children or {}
    local name = path:match("[^/]+$") or path
    table.insert(parent_inode.children, name)
    parent_inode.modified = os.time()

    return true
end

return RamDisk
