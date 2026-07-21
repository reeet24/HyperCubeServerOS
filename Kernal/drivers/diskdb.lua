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

local function root_sort_key(root)
    return tostring(root.id or "") .. ":" .. tostring(root.name or "") .. ":" .. tostring(root.mount or "")
end

local function shard_index_for(key, shard_count)
    shard_count = tonumber(shard_count) or 1
    if shard_count <= 1 then
        return 1
    end
    return (checksum(key) % shard_count) + 1
end

local function stable_serialize(value, seen)
    local value_type = type(value)
    if value_type == "nil" then
        return "nil"
    elseif value_type == "number" or value_type == "boolean" then
        return tostring(value)
    elseif value_type == "string" then
        return string.format("%q", value)
    elseif value_type ~= "table" then
        return string.format("%q", tostring(value))
    end

    seen = seen or {}
    if seen[value] then
        return "\"<cycle>\""
    end
    seen[value] = true

    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        local ta = type(a)
        local tb = type(b)
        if ta == tb then
            return tostring(a) < tostring(b)
        end
        return ta < tb
    end)

    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = "[" .. stable_serialize(key, seen) .. "]=" .. stable_serialize(value[key], seen)
    end

    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

local function record_parity(record)
    return checksum(stable_serialize({
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

local function make_drive_filter(drives)
    if type(drives) ~= "table" or #drives == 0 then
        return nil
    end
    local allowed = {}
    for _, drive in ipairs(drives) do
        if type(drive) == "table" then
            if drive.name then
                allowed["name:" .. tostring(drive.name)] = true
            end
            if drive.mount then
                allowed["mount:" .. tostring(drive.mount)] = true
            end
            if drive.id then
                allowed["id:" .. tostring(drive.id)] = true
            end
        else
            allowed["name:" .. tostring(drive)] = true
            allowed["mount:" .. tostring(drive)] = true
            allowed["id:" .. tostring(drive)] = true
        end
    end
    return function(root)
        return allowed["name:" .. tostring(root.name)]
            or allowed["mount:" .. tostring(root.mount)]
            or allowed["id:" .. tostring(root.id)]
    end
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

local function read_parity_file(root, key)
    local paths = paths_for(root, key)
    local data = read_all(paths.parity_file)
    if not data then
        return nil
    end

    local ok, parity = pcall(unserialize, data)
    if ok and type(parity) == "table" then
        return parity
    end
    return nil
end

function DiskDB.new(options)
    options = options or {}
    local self = setmetatable({}, DiskDB)
    self.db_root = options.root or DEFAULT_ROOT
    self.min_replicas = options.min_replicas or 2
    self.drive_filter = make_drive_filter(options.drives)
    self.roots = {}
    self.status = "offline"
    self.last_error = nil
    self.last_scan = nil
    self:refresh()
    return self
end

function DiskDB:refresh()
    self.roots = find_drive_mounts()
    if self.drive_filter then
        local filtered = {}
        for _, root in ipairs(self.roots) do
            if self.drive_filter(root) then
                filtered[#filtered + 1] = root
            end
        end
        self.roots = filtered
    end
    table.sort(self.roots, function(a, b)
        return root_sort_key(a) < root_sort_key(b)
    end)
    for _, root in ipairs(self.roots) do
        root.db_root = self.db_root
        local paths = paths_for(root, "_init")
        ensure_dir(paths.base)
        ensure_dir(paths.records)
        ensure_dir(paths.parity)
    end

    self.groups = {}
    self.spares = {}
    local group_count = math.min(self.min_replicas, #self.roots)
    local group_size = group_count > 0 and math.floor(#self.roots / group_count) or 0
    if group_count > 0 and group_size > 0 then
        local used = group_count * group_size
        for group_index = 1, group_count do
            local group = {
                index = group_index,
                roots = {},
            }
            for shard_index = 1, group_size do
                local root = self.roots[((group_index - 1) * group_size) + shard_index]
                root.group_index = group_index
                root.shard_index = shard_index
                root.shard_count = group_size
                group.roots[shard_index] = root
            end
            self.groups[#self.groups + 1] = group
        end
        for index = used + 1, #self.roots do
            self.spares[#self.spares + 1] = self.roots[index]
        end
    end

    self.last_scan = now()
    if #self.roots == 0 then
        self.status = "offline"
        self.last_error = "NoDiskDrives"
    elseif #self.groups < self.min_replicas then
        self.status = "degraded"
        self.last_error = "BelowMinReplicas"
    else
        self.status = "online"
        self.last_error = nil
    end

    return #self.roots
end

function DiskDB:target_roots(key)
    if not self.groups or #self.groups == 0 then
        return {}
    end
    local shard_count = self.groups[1] and #(self.groups[1].roots or {}) or 1
    local shard_index = shard_index_for(key, shard_count)
    local targets = {}
    for _, group in ipairs(self.groups) do
        local root = group.roots and group.roots[shard_index]
        if root then
            targets[#targets + 1] = root
        end
    end
    return targets, shard_index, shard_count
end

function DiskDB:write_record(root, key, record)
    local paths = paths_for(root, key)
    ensure_dir(paths.base)
    ensure_dir(paths.records)
    ensure_dir(paths.parity)

    record._repair_parity = nil
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

    local expected = record_parity(record)
    if record.parity ~= expected then
        local parity = read_parity_file(root, key)
        if not parity or parity.parity ~= record.parity or parity.version ~= record.version then
            return nil, "ParityMismatch"
        end
        record.parity = expected
        record._repair_parity = true
    end

    return record
end

function DiskDB:best_record(key)
    local best = nil
    local reads = {}
    local seen = {}

    local targets = self:target_roots(key)
    for _, root in ipairs(targets) do
        seen[root.mount] = true
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

    for _, root in ipairs(self.roots) do
        if not seen[root.mount] then
            local record, err = self:read_record(root, key)
            reads[#reads + 1] = {
                root = root,
                record = record,
                error = err,
                fallback = true,
            }

            if record and (not best or (record.version or 0) > (best.version or 0)) then
                best = record
            end
        end
    end

    return best, reads
end

function DiskDB:repair(key, record)
    if not record then
        return 0
    end

    local repaired = 0
    local targets = self:target_roots(key)
    for _, root in ipairs(targets) do
        local current = self:read_record(root, key)
        if not current or current.version ~= record.version or current.parity ~= record.parity or current._repair_parity == true then
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
    local targets = self:target_roots(safe)
    for _, root in ipairs(targets) do
        local ok, write_err = self:write_record(root, safe, record)
        if ok then
            writes = writes + 1
        else
            last_error = write_err
        end
    end

    if writes < math.min(self.min_replicas, #targets) then
        self.status = "degraded"
        self.last_error = last_error or "InsufficientReplicas"
        return false, self.last_error
    end

    return true, {
        key = key,
        version = record.version,
        replicas = writes,
        shard = shard_index_for(safe, self.groups[1] and #self.groups[1].roots or 1),
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

function DiskDB:list(prefix, limit)
    self:refresh()
    prefix = tostring(prefix or "")
    limit = tonumber(limit) or 200

    local safe_keys = {}
    local seen = {}
    for _, root in ipairs(self.roots or {}) do
        local records_dir = paths_for(root, "_init").records
        if fs and fs.exists and fs.list and fs.exists(records_dir) then
            for _, file in ipairs(fs.list(records_dir)) do
                local safe = tostring(file):match("^(.*)%.db$")
                if safe and not seen[safe] then
                    seen[safe] = true
                    safe_keys[#safe_keys + 1] = safe
                end
            end
        end
    end
    table.sort(safe_keys)

    local entries = {}
    for _, safe in ipairs(safe_keys) do
        local record = self:best_record(safe)
        if record and not record.deleted then
            local key = tostring(record.key or safe)
            if prefix == "" or key:sub(1, #prefix) == prefix then
                local value_type = type(record.value)
                local preview
                if value_type == "table" then
                    local count = 0
                    for _ in pairs(record.value) do
                        count = count + 1
                    end
                    preview = "table[" .. tostring(count) .. "]"
                else
                    preview = tostring(record.value)
                end
                entries[#entries + 1] = {
                    key = key,
                    safe_key = safe,
                    version = record.version or 0,
                    value_type = value_type,
                    preview = preview,
                    updated_at = record.updated_at,
                }
                if #entries >= limit then
                    break
                end
            end
        end
    end

    return entries
end

function DiskDB:summary()
    return {
        status = self.status,
        drives = #self.roots,
        groups = self.groups and #self.groups or 0,
        shards_per_group = self.groups and self.groups[1] and #self.groups[1].roots or 0,
        spares = self.spares and #self.spares or 0,
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
