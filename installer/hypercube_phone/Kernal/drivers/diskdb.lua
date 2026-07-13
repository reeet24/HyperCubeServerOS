local DiskDB = {}
DiskDB.__index = DiskDB

local DEFAULT_ROOT = "hypercube_db"

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function safe_key(key)
    key = tostring(key or "")
    local out = key:gsub("[^%w%._%-]", "_")
    if out == "" then
        return nil, "InvalidKey"
    end
    return out
end

local function combine(a, b)
    if fs and fs.combine then
        return fs.combine(a, b)
    end
    if a:sub(-1) == "/" then
        return a .. b
    end
    return a .. "/" .. b
end

local function ensure_dir(path)
    if fs and fs.exists and fs.exists(path) then
        return true
    end
    if fs and fs.makeDir then
        fs.makeDir(path)
        return true
    end
    return false, "FsUnavailable"
end

local function read_all(path)
    if not fs or not fs.open or not fs.exists or not fs.exists(path) then
        return nil, "NotFound"
    end
    local handle = fs.open(path, "r")
    if not handle then
        return nil, "OpenFailed"
    end
    local data = handle.readAll()
    handle.close()
    return data
end

local function write_all(path, data)
    local handle = fs.open(path, "w")
    if not handle then
        return false, "OpenFailed"
    end
    handle.write(data)
    handle.close()
    return true
end

local function serialize(value)
    if textutils and textutils.serialize then
        return textutils.serialize(value)
    end
    error("textutils.serialize unavailable")
end

local function unserialize(value)
    if textutils and textutils.unserialize then
        return textutils.unserialize(value)
    end
    error("textutils.unserialize unavailable")
end

local function checksum(text)
    text = tostring(text or "")
    local a = 1
    local b = 0
    for i = 1, #text do
        a = (a + text:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return (b * 65536 + a) % 2147483647
end

local function record_parity(record)
    return checksum(serialize({
        key = record.key,
        value = record.value,
        version = record.version,
        deleted = record.deleted == true,
    }))
end

local function find_drive_mounts()
    local mounts = {}

    if peripheral and peripheral.getNames and peripheral.getType and peripheral.wrap then
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "drive" then
                local drive = peripheral.wrap(name)
                if drive and drive.isDiskPresent and drive.isDiskPresent() and drive.getMountPath then
                    local mount = drive.getMountPath()
                    if mount then
                        mounts[#mounts + 1] = {
                            name = name,
                            mount = mount,
                            id = drive.getDiskID and drive.getDiskID() or nil,
                            label = drive.getDiskLabel and drive.getDiskLabel() or nil,
                        }
                    end
                end
            end
        end
    end

    return mounts
end

local function paths_for(root, key)
    local base = combine(root.mount, root.db_root)
    return {
        base = base,
        records = combine(base, "records"),
        parity = combine(base, "parity"),
        record = combine(combine(base, "records"), key .. ".db"),
        parity_file = combine(combine(base, "parity"), key .. ".par"),
    }
end

function DiskDB.new(options)
    options = options or {}
    local self = setmetatable({}, DiskDB)
    self.db_root = options.root or DEFAULT_ROOT
    self.min_replicas = options.min_replicas or 2
    self.roots = {}
    self.status = "offline"
    self.last_error = nil
    self.last_scan = nil
    self:refresh()
    return self
end

function DiskDB:refresh()
    self.roots = find_drive_mounts()
    for _, root in ipairs(self.roots) do
        root.db_root = self.db_root
        local paths = paths_for(root, "_init")
        ensure_dir(paths.base)
        ensure_dir(paths.records)
        ensure_dir(paths.parity)
    end

    self.last_scan = now()
    if #self.roots == 0 then
        self.status = "offline"
        self.last_error = "NoDiskDrives"
    elseif #self.roots < self.min_replicas then
        self.status = "degraded"
        self.last_error = "BelowMinReplicas"
    else
        self.status = "online"
        self.last_error = nil
    end

    return #self.roots
end

function DiskDB:write_record(root, key, record)
    local paths = paths_for(root, key)
    ensure_dir(paths.base)
    ensure_dir(paths.records)
    ensure_dir(paths.parity)

    record.parity = record_parity(record)
    record.updated_at = now()

    local ok, err = write_all(paths.record, serialize(record))
    if not ok then
        return false, err
    end

    return write_all(paths.parity_file, serialize({
        key = record.key,
        version = record.version,
        parity = record.parity,
        updated_at = record.updated_at,
    }))
end

function DiskDB:read_record(root, key)
    local paths = paths_for(root, key)
    local data, err = read_all(paths.record)
    if not data then
        return nil, err
    end

    local ok, record = pcall(unserialize, data)
    if not ok or type(record) ~= "table" then
        return nil, "CorruptRecord"
    end

    if record.parity ~= record_parity(record) then
        return nil, "ParityMismatch"
    end

    return record
end

function DiskDB:best_record(key)
    local best = nil
    local reads = {}

    for _, root in ipairs(self.roots) do
        local record, err = self:read_record(root, key)
        reads[#reads + 1] = {
            root = root,
            record = record,
            error = err,
        }

        if record and (not best or (record.version or 0) > (best.version or 0)) then
            best = record
        end
    end

    return best, reads
end

function DiskDB:repair(key, record)
    if not record then
        return 0
    end

    local repaired = 0
    for _, root in ipairs(self.roots) do
        local current = self:read_record(root, key)
        if not current or current.version ~= record.version or current.parity ~= record.parity then
            local ok = self:write_record(root, key, record)
            if ok then
                repaired = repaired + 1
            end
        end
    end

    return repaired
end

function DiskDB:set(key, value)
    local safe, err = safe_key(key)
    if not safe then
        return false, err
    end
    self:refresh()
    if #self.roots == 0 then
        return false, "NoDiskDrives"
    end

    local current = self:best_record(safe)
    local record = {
        key = key,
        value = value,
        version = (current and current.version or 0) + 1,
        deleted = false,
    }

    local writes = 0
    local last_error = nil
    for _, root in ipairs(self.roots) do
        local ok, write_err = self:write_record(root, safe, record)
        if ok then
            writes = writes + 1
        else
            last_error = write_err
        end
    end

    if writes < math.min(self.min_replicas, #self.roots) then
        self.status = "degraded"
        self.last_error = last_error or "InsufficientReplicas"
        return false, self.last_error
    end

    return true, {
        key = key,
        version = record.version,
        replicas = writes,
        parity = record.parity,
    }
end

function DiskDB:get(key)
    local safe, err = safe_key(key)
    if not safe then
        return nil, err
    end
    self:refresh()

    local record = self:best_record(safe)
    if not record or record.deleted then
        return nil, "NotFound"
    end

    local repaired = self:repair(safe, record)
    return record.value, {
        key = record.key,
        version = record.version,
        parity = record.parity,
        repaired = repaired,
    }
end

function DiskDB:delete(key)
    local safe, err = safe_key(key)
    if not safe then
        return false, err
    end
    self:refresh()

    local current = self:best_record(safe)
    local record = {
        key = key,
        value = nil,
        version = (current and current.version or 0) + 1,
        deleted = true,
    }

    local writes = 0
    for _, root in ipairs(self.roots) do
        local ok = self:write_record(root, safe, record)
        if ok then
            writes = writes + 1
        end
    end

    return writes > 0, {
        key = key,
        version = record.version,
        replicas = writes,
    }
end

function DiskDB:summary()
    return {
        status = self.status,
        drives = #self.roots,
        min_replicas = self.min_replicas,
        root = self.db_root,
        last_error = self.last_error,
        last_scan = self.last_scan,
    }
end

local driver = {
    name = "diskdb",
    version = "0.1.0",
}

function driver.init(context)
    local options = context and context.diskdb or {}
    return DiskDB.new(options)
end

function driver.shutdown()
    return true
end

driver.DiskDB = DiskDB
driver.new = DiskDB.new

return driver
