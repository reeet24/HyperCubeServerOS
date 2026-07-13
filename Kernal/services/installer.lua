local installer = {}

local DEFAULT_SOURCE = "installer/hypercube_phone"
local SOURCE_PROFILES = {
    phone = {
        source = "installer/hypercube_phone",
        os = "HyperCube",
        device = "TPhone",
    },
    business_phone = {
        source = "installer/hypercube_phone",
        os = "HyperCube",
        device = "TBusinessPhone",
    },
    turtle = {
        source = "installer/hypercube_turtle",
        os = "HyperCube",
        device = "Turtle",
    },
}
local INSTALL_PATHS = {
    "Kernal",
    "apps",
    "init.lua",
    "startup.lua",
    "checklist.md",
}
local ROM_FILE = "hypercube.rom"
local ROM_KEY = "Tesserac:HyperCube:BankOfBash:ROM:v1"
local ROM_HEADER = "HCBR1"
local SOFTWARE_VERSION = "0.3.5"

local function checksum(text)
    text = tostring(text or "")
    local a = 1
    local b = 0
    for i = 1, #text do
        a = (a + text:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return tostring((b * 65536 + a) % 2147483647)
end

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
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
    table.sort(mounts, function(a, b)
        return tostring(a.name) < tostring(b.name)
    end)
    return mounts
end

local function copy_tree(source, target)
    if fs.isDir(source) then
        if not fs.exists(target) then
            fs.makeDir(target)
        end
        for _, child in ipairs(fs.list(source)) do
            copy_tree(combine(source, child), combine(target, child))
        end
    else
        fs.copy(source, target)
    end
end

local function read_all(path)
    local handle = fs.open(path, "rb")
    if not handle then
        return nil, "OpenFailed"
    end
    local data = handle.readAll()
    handle.close()
    return data
end

local function write_all(path, data, binary)
    local handle = fs.open(path, binary and "wb" or "w")
    if not handle then
        return false, "OpenFailed"
    end
    handle.write(data)
    handle.close()
    return true
end

local function xor_crypt(data, key)
    if not bit32 then
        return nil, "Bit32Unavailable"
    end
    data = tostring(data or "")
    key = tostring(key or "")
    if key == "" then
        return nil, "KeyRequired"
    end
    local out = {}
    for i = 1, #data do
        local key_byte = key:byte(((i - 1) % #key) + 1)
        out[i] = string.char(bit32.bxor(data:byte(i), key_byte))
    end
    return table.concat(out)
end

local function collect_tree(root, relative, out)
    local path = relative == "" and root or combine(root, relative)
    if fs.isDir(path) then
        for _, child in ipairs(fs.list(path)) do
            collect_tree(root, relative == "" and child or combine(relative, child), out)
        end
        return true
    end

    local data, err = read_all(path)
    if not data then
        return false, err
    end
    out[#out + 1] = {
        path = relative,
        data = data,
    }
    return true
end

local function collect_image(source)
    local files = {}
    for _, path in ipairs(INSTALL_PATHS) do
        local full = combine(source, path)
        if fs.exists(full) then
            local ok, err = collect_tree(source, path, files)
            if not ok then
                return nil, err
            end
        end
    end
    table.sort(files, function(a, b)
        return a.path < b.path
    end)
    return files
end

local function profile_for_source(source)
    if source == DEFAULT_SOURCE then
        return SOURCE_PROFILES.phone
    end
    for _, profile in pairs(SOURCE_PROFILES) do
        if profile.source == source then
            return profile
        end
    end
    return {
        source = source,
        os = "HyperCube",
        device = source and source:match("turtle") and "Turtle" or "TPhone",
    }
end

local function profile_for_device(device)
    device = tostring(device or "")
    for _, profile in pairs(SOURCE_PROFILES) do
        if profile.device == device then
            return profile
        end
    end
    return nil
end

local function build_rom_blob(source, profile)
    local files, err = collect_image(source)
    if not files then
        return nil, err
    end
    profile = profile or profile_for_source(source)
    local payload = textutils.serialize({
        format = "HyperCubeROM",
        version = 1,
        software_version = SOFTWARE_VERSION,
        os = profile.os,
        device = profile.device,
        built_at = 0,
        files = files,
    })
    local encoded, crypt_err = xor_crypt(payload, ROM_KEY)
    if not encoded then
        return nil, crypt_err
    end
    return ROM_HEADER .. encoded, #files
end

local function loader_source(profile)
    profile = profile or profile_for_source(DEFAULT_SOURCE)
    return [[
local ROM_FILE = "hypercube.rom"
local ROM_KEY = "]] .. ROM_KEY .. [["
local ROM_HEADER = "]] .. ROM_HEADER .. [["
local DEVICE = "]] .. tostring(profile.device or "TPhone") .. [["

local function read_all(path)
    local handle = fs.open(path, "rb")
    if not handle then
        return nil, "OpenFailed"
    end
    local data = handle.readAll()
    handle.close()
    return data
end

local function write_all(path, data, binary)
    local handle = fs.open(path, binary and "wb" or "w")
    if not handle then
        return false, "OpenFailed"
    end
    handle.write(data or "")
    handle.close()
    return true
end

local function copy_file(source, target)
    if not fs.exists(source) then
        return false, "MissingSource"
    end
    if fs.exists(target) then
        fs.delete(target)
    end
    fs.copy(source, target)
    return true
end

local function dirname(path)
    path = tostring(path or ""):gsub("\\", "/")
    return path:match("^(.*)/[^/]+$") or ""
end

local function combine(a, b)
    if fs.combine then
        return fs.combine(a, b)
    end
    if a == "" then
        return b
    end
    if a:sub(-1) == "/" then
        return a .. b
    end
    return a .. "/" .. b
end

local function maybe_install_to_host()
    if DEVICE ~= "Turtle" then
        return false
    end
    if not shell or not shell.getRunningProgram then
        return false
    end

    local running = shell.getRunningProgram()
    local source_dir = dirname(running)
    if source_dir == "" then
        return false
    end

    local source_startup = combine(source_dir, "startup.lua")
    local source_rom = combine(source_dir, ROM_FILE)
    if not fs.exists(source_rom) or not fs.exists(source_startup) then
        return false
    end

    print("Installing HyperCube Turtle OS locally...")
    local ok, err = copy_file(source_rom, ROM_FILE)
    if not ok then
        error("ROM install failed: " .. tostring(err))
    end
    ok, err = copy_file(source_startup, "startup.lua")
    if not ok then
        error("startup install failed: " .. tostring(err))
    end
    write_all("hypercube_install", textutils.serialize({
        os = "HyperCube",
        device = "Turtle",
        mode = "local-rom",
        source = source_dir,
        installed_at = os.epoch and os.epoch("utc") or os.clock(),
        rom = ROM_FILE,
    }), false)
    print("Installed. Rebooting into local turtle OS.")
    if os.reboot then
        os.reboot()
    end
    return true
end

if maybe_install_to_host() then
    return
end

local function xor_crypt(data, key)
    if not bit32 then
        return nil, "Bit32Unavailable"
    end
    local out = {}
    for i = 1, #data do
        local key_byte = key:byte(((i - 1) % #key) + 1)
        out[i] = string.char(bit32.bxor(data:byte(i), key_byte))
    end
    return table.concat(out)
end

local function normalize_path(path)
    path = tostring(path or ""):gsub("\\", "/"):gsub("^/+", "")
    return path
end

local function module_path(name)
    return tostring(name or ""):gsub("%.", "/") .. ".lua"
end

local function load_chunk(source, path, env)
    env = env or _G
    if load then
        local ok, loader_or_err = pcall(load, source, "@" .. tostring(path), "t", env)
        if ok and loader_or_err then
            if setfenv then
                setfenv(loader_or_err, env)
            end
            return loader_or_err
        end
        if ok and type(loader_or_err) == "string" then
            return nil, loader_or_err
        end
    end
    if loadstring then
        local loader, err = loadstring(source, "@" .. tostring(path))
        if not loader then
            return nil, err
        end
        if setfenv then
            setfenv(loader, env)
        end
        return loader
    end
    return nil, "NoLoader"
end

local function decode_rom()
    local raw, read_err = read_all(ROM_FILE)
    if not raw then
        error("HyperCube ROM missing: " .. tostring(read_err))
    end
    if raw:sub(1, #ROM_HEADER) ~= ROM_HEADER then
        error("Invalid HyperCube ROM header")
    end
    local decoded, decode_err = xor_crypt(raw:sub(#ROM_HEADER + 1), ROM_KEY)
    if not decoded then
        error("HyperCube ROM decode failed: " .. tostring(decode_err))
    end
    local payload = textutils.unserialize(decoded)
    if type(payload) ~= "table" or payload.format ~= "HyperCubeROM" or type(payload.files) ~= "table" then
        error("Invalid HyperCube ROM payload")
    end

    local files = {}
    for _, file in ipairs(payload.files) do
        files[normalize_path(file.path)] = file.data or ""
    end
    payload.files_by_path = files
    return payload
end

local function install_memory_rom(payload)
    local files = payload.files_by_path or {}
    local rom = {
        payload = payload,
        files = files,
    }

    function rom.exists(path)
        return files[normalize_path(path)] ~= nil
    end

    function rom.read(path)
        return files[normalize_path(path)]
    end

    function rom.load(path, env)
        path = normalize_path(path)
        local source = files[path]
        if not source then
            return nil, "NotFound"
        end
        return load_chunk(source, path, env or _G)
    end

    function rom.list_apps()
        local seen = {}
        local apps = {}
        for path in pairs(files) do
            local id = path:match("^apps/([^/]+)/app%.lua$")
            if id and not seen[id] then
                seen[id] = true
                apps[#apps + 1] = {
                    id = id,
                    path = "apps/" .. id .. "/app.lua",
                }
            end
        end
        table.sort(apps, function(a, b)
            return a.id < b.id
        end)
        return apps
    end

    _G.HC_ROM = rom

    local original_require = require
    package = package or {}
    package.loaded = package.loaded or {}
    package.preload = package.preload or {}
    _G.package = package

    function rom.require(name)
        name = tostring(name or "")
        if package.loaded[name] ~= nil then
            return package.loaded[name]
        end

        local preload = package.preload[name]
        if preload then
            package.loaded[name] = true
            local result = preload(name)
            if result ~= nil then
                package.loaded[name] = result
            end
            return package.loaded[name]
        end

        local path = module_path(name)
        local source = files[path]
        if source then
            local loader, err = load_chunk(source, path, _G)
            if not loader then
                error("module load failed: " .. name .. ": " .. tostring(err), 2)
            end
            package.loaded[name] = true
            local result = loader(name)
            if result ~= nil then
                package.loaded[name] = result
            end
            return package.loaded[name]
        end

        if original_require then
            return original_require(name)
        end

        error("module not found: " .. name, 2)
    end

    _G.require = rom.require

    if package and package.preload then
        for path in pairs(files) do
            if path:match("%.lua$") then
                local module = path:gsub("%.lua$", ""):gsub("/", ".")
                local rom_path = path
                package.preload[module] = function()
                    local loader, err = rom.load(rom_path, _G)
                    if not loader then
                        error(err)
                    end
                    return loader()
                end
            end
        end
    end

    local original_loadfile = loadfile
    _G.loadfile = function(path, mode_or_env, maybe_env)
        local env = maybe_env or (type(mode_or_env) == "table" and mode_or_env or _G)
        local loader, err = rom.load(path, env)
        if loader then
            return loader
        end
        if original_loadfile then
            return original_loadfile(path, mode_or_env, maybe_env)
        end
        return nil, err
    end

    return rom
end

local ok, err = pcall(function()
    local payload = decode_rom()
    local rom = install_memory_rom(payload)
    local init_loader, init_err = rom.load("init.lua", _G)
    if not init_loader then
        error("HyperCube init missing from ROM: " .. tostring(init_err))
    end
    local TPhone = init_loader()
    local boot_ok, boot_err = pcall(function()
        return TPhone.boot()
    end)
    if not boot_ok then
        error("HyperCube boot failed: " .. tostring(boot_err))
    end
    local identity_ok, identity_err = TPhone.ensure_identity()
    if identity_ok then
        TPhone.start_gui()
    else
        print("TesseracID required: " .. tostring(identity_err))
    end
end)

if not ok then
    print("HyperCube ROM loader failed: " .. tostring(err))
end
]]
end

local function clean_target(mount)
    for _, path in ipairs(INSTALL_PATHS) do
        local target = combine(mount, path)
        if fs.exists(target) then
            fs.delete(target)
        end
    end
    for _, path in ipairs({ ROM_FILE, "hypercube_install" }) do
        local target = combine(mount, path)
        if fs.exists(target) then
            fs.delete(target)
        end
    end
end

function installer.new(options)
    local self = {
        source = options and options.source or DEFAULT_SOURCE,
        profile_key = options and options.profile or nil,
        selected_index = 1,
        last_result = nil,
        last_scan = nil,
    }
    if SOURCE_PROFILES[self.source] then
        self.profile_key = self.source
        self.source = SOURCE_PROFILES[self.profile_key].source
    elseif self.source == DEFAULT_SOURCE and not self.profile_key then
        self.profile_key = "phone"
    end

    function self:set_source(source)
        if SOURCE_PROFILES[source] then
            self.profile_key = source
            source = SOURCE_PROFILES[source].source
        elseif source == DEFAULT_SOURCE then
            self.profile_key = "phone"
        else
            self.profile_key = nil
        end
        self.source = source or DEFAULT_SOURCE
        self.last_result = nil
        return true, self.source
    end

    function self:source_profile()
        if self.profile_key and SOURCE_PROFILES[self.profile_key] then
            return SOURCE_PROFILES[self.profile_key]
        end
        return profile_for_source(self.source)
    end

    function self:drives()
        local drives = find_drive_mounts()
        self.last_scan = now()
        if self.selected_index > #drives then
            self.selected_index = math.max(1, #drives)
        end
        return drives
    end

    function self:selected_drive()
        local drives = self:drives()
        return drives[self.selected_index], drives
    end

    function self:select_next()
        local drives = self:drives()
        if #drives == 0 then
            self.selected_index = 1
            return nil, "NoDiskDrives"
        end
        self.selected_index = (self.selected_index % #drives) + 1
        return drives[self.selected_index]
    end

    function self:build_rom(target_mount)
        local profile = self:source_profile()
        local blob, file_count_or_err = build_rom_blob(self.source, profile)
        if not blob then
            return false, file_count_or_err
        end
        local ok, err = write_all(combine(target_mount, ROM_FILE), blob, true)
        if not ok then
            return false, err
        end
        ok, err = write_all(combine(target_mount, "startup.lua"), loader_source(profile), false)
        if not ok then
            return false, err
        end
        return true, {
            file_count = file_count_or_err,
            rom = ROM_FILE,
            device = profile.device,
            checksum = checksum(blob),
        }
    end

    function self:build_update_package()
        local profile = self:source_profile()
        local blob, file_count_or_err = build_rom_blob(self.source, profile)
        if not blob then
            return false, file_count_or_err
        end
        return true, {
            os = profile.os,
            device = profile.device,
            version = SOFTWARE_VERSION,
            rom = ROM_FILE,
            rom_checksum = checksum(blob),
            rom_data = blob,
            startup = loader_source(profile),
            packed_files = file_count_or_err,
            built_at = now(),
        }
    end

    function self:build_update_package_for_device(device)
        local profile = profile_for_device(device) or SOURCE_PROFILES.phone
        local blob, file_count_or_err = build_rom_blob(profile.source or self.source, profile)
        if not blob then
            return false, file_count_or_err
        end
        return true, {
            os = profile.os,
            device = profile.device,
            version = SOFTWARE_VERSION,
            rom = ROM_FILE,
            rom_checksum = checksum(blob),
            rom_data = blob,
            startup = loader_source(profile),
            packed_files = file_count_or_err,
            built_at = now(),
        }
    end

    function self:update_metadata()
        local profile = self:source_profile()
        local blob, file_count_or_err = build_rom_blob(self.source, profile)
        if not blob then
            return false, file_count_or_err
        end
        return true, {
            os = profile.os,
            device = profile.device,
            version = SOFTWARE_VERSION,
            rom = ROM_FILE,
            rom_checksum = checksum(blob),
            packed_files = file_count_or_err,
        }
    end

    function self:update_metadata_for_device(device)
        local profile = profile_for_device(device) or SOURCE_PROFILES.phone
        local blob, file_count_or_err = build_rom_blob(profile.source or self.source, profile)
        if not blob then
            return false, file_count_or_err
        end
        return true, {
            os = profile.os,
            device = profile.device,
            version = SOFTWARE_VERSION,
            rom = ROM_FILE,
            rom_checksum = checksum(blob),
            packed_files = file_count_or_err,
        }
    end

    function self:install()
        if not fs or not fs.exists or not fs.copy or not fs.delete then
            self.last_result = { ok = false, error = "FsUnavailable", time = now() }
            return false, "FsUnavailable"
        end
        if not fs.exists(self.source) then
            self.last_result = { ok = false, error = "InstallImageMissing", time = now() }
            return false, "InstallImageMissing"
        end

        local drive = self:selected_drive()
        if not drive then
            self.last_result = { ok = false, error = "NoDiskSelected", time = now() }
            return false, "NoDiskSelected"
        end

        clean_target(drive.mount)
        local rom_ok, rom_result = self:build_rom(drive.mount)
        if not rom_ok then
            self.last_result = { ok = false, error = rom_result, time = now() }
            return false, rom_result
        end

        local stamp = combine(drive.mount, "hypercube_install")
        local handle = fs.open(stamp, "w")
        if handle then
            local profile = self:source_profile()
            handle.write(textutils.serialize({
                os = profile.os,
                device = profile.device,
                installed_at = now(),
                source = self.source,
                mode = "rom",
                rom = ROM_FILE,
                version = SOFTWARE_VERSION,
                packed_files = rom_result.file_count,
                rom_checksum = rom_result.checksum,
            }))
            handle.close()
        end

        self.last_result = {
            ok = true,
            drive = drive.name,
            mount = drive.mount,
            mode = "rom",
            rom = ROM_FILE,
            version = SOFTWARE_VERSION,
            device = self:source_profile().device,
            packed_files = rom_result.file_count,
            rom_checksum = rom_result.checksum,
            time = now(),
        }
        return true, self.last_result
    end

    return self
end

installer.VERSION = SOFTWARE_VERSION
installer.SOURCES = SOURCE_PROFILES

return installer
