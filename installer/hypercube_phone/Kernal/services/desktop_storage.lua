local desktop_storage = {}

local MARKER_FILE = ".hypercube_desktop_drive"
local DRIVE_ROOT = "hypercube"
local APPS_DIR = "apps"
local APPDATA_DIR = "appdata"
local INTERNAL_APP_ROOT = "user/apps"
local INTERNAL_APPDATA_ROOT = "user/appdata"

local function combine(a, b)
    if fs and fs.combine then
        return fs.combine(a, b)
    end
    a = tostring(a or "")
    b = tostring(b or "")
    if a == "" then
        return b
    end
    if a:sub(-1) == "/" then
        return a .. b
    end
    return a .. "/" .. b
end

local function ensure_dir(path)
    if not fs or not fs.exists or not fs.makeDir then
        return false, "FsUnavailable"
    end
    if not fs.exists(path) then
        fs.makeDir(path)
    end
    return true
end

local function read_table(path)
    if not fs or not fs.exists or not fs.open or not fs.exists(path) then
        return nil, "NotFound"
    end
    local handle = fs.open(path, "r")
    if not handle then
        return nil, "OpenFailed"
    end
    local data = handle.readAll()
    handle.close()
    if not textutils or not textutils.unserialize then
        return nil, "TextutilsUnavailable"
    end
    local ok, result = pcall(textutils.unserialize, data)
    if ok and type(result) == "table" then
        return result
    end
    return nil, "DecodeFailed"
end

local function write_table(path, value)
    local dir = tostring(path or ""):match("^(.*)/[^/]+$")
    if dir and dir ~= "" then
        local ok, err = ensure_dir(dir)
        if not ok then
            return false, err
        end
    end
    if not textutils or not textutils.serialize then
        return false, "TextutilsUnavailable"
    end
    local handle = fs.open(path, "w")
    if not handle then
        return false, "OpenFailed"
    end
    handle.write(textutils.serialize(value or {}))
    handle.close()
    return true
end

local function now()
    if os and os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function is_desktop_device(tphone)
    local device = tostring(tphone and tphone.device or "")
    return device == "TDesktop" or device == "TBusinessDesktop"
end

local function mount_for_drive(name)
    if not peripheral or not disk then
        return nil
    end
    if disk.isPresent and not disk.isPresent(name) then
        return nil
    end
    if disk.hasData and disk.hasData(name) == false then
        return nil
    end
    if disk.getMountPath then
        return disk.getMountPath(name)
    end
    return nil
end

local function drive_names()
    local names = {}
    if peripheral and peripheral.getNames then
        for _, name in ipairs(peripheral.getNames()) do
            local ok, kind = pcall(peripheral.getType, name)
            if ok and (kind == "drive" or (type(kind) == "table" and kind.drive)) then
                names[#names + 1] = name
            end
        end
    end
    table.sort(names)
    return names
end

local function paths_for_mount(mount)
    local root = combine(mount, DRIVE_ROOT)
    return {
        marker = combine(mount, MARKER_FILE),
        root = root,
        apps = combine(root, APPS_DIR),
        appdata = combine(root, APPDATA_DIR),
    }
end

local function app_id_path(id)
    id = tostring(id or ""):lower():gsub("%s+", "")
    id = id:gsub("[^%w_%-%.]", "_")
    if id == "" then
        return nil
    end
    return id
end

function desktop_storage.is_desktop(tphone)
    return is_desktop_device(tphone)
end

function desktop_storage.list_drives()
    local out = {}
    for _, name in ipairs(drive_names()) do
        local mount = mount_for_drive(name)
        local info = {
            name = name,
            present = mount ~= nil,
            mount = mount,
            formatted = false,
        }
        if mount then
            local paths = paths_for_mount(mount)
            local metadata = read_table(paths.marker)
            if metadata and metadata.format == "HyperCubeDesktopDrive" then
                info.formatted = true
                info.label = tostring(metadata.label or name)
                info.formatted_at = metadata.formatted_at
                info.apps_path = paths.apps
                info.appdata_path = paths.appdata
                info.free_space = fs.getFreeSpace and fs.getFreeSpace(mount) or nil
            end
        end
        out[#out + 1] = info
    end
    return out
end

function desktop_storage.mounted()
    local out = {}
    for _, drive in ipairs(desktop_storage.list_drives()) do
        if drive.formatted then
            out[#out + 1] = drive
        end
    end
    return out
end

function desktop_storage.format_drive(name, label)
    local mount = mount_for_drive(tostring(name or ""))
    if not mount then
        return false, "DriveUnavailable"
    end
    local paths = paths_for_mount(mount)
    local ok, err = ensure_dir(paths.apps)
    if not ok then
        return false, err
    end
    ok, err = ensure_dir(paths.appdata)
    if not ok then
        return false, err
    end
    ok, err = write_table(paths.marker, {
        format = "HyperCubeDesktopDrive",
        version = 1,
        label = tostring(label or name),
        formatted_at = now(),
    })
    if not ok then
        return false, err
    end
    return true, {
        name = name,
        mount = mount,
        apps_path = paths.apps,
        appdata_path = paths.appdata,
    }
end

function desktop_storage.app_roots()
    local roots = {}
    for _, drive in ipairs(desktop_storage.mounted()) do
        roots[#roots + 1] = drive.apps_path
    end
    return roots
end

function desktop_storage.default_app_root(tphone)
    if is_desktop_device(tphone) then
        local mounted = desktop_storage.mounted()
        if mounted[1] then
            return mounted[1].apps_path, mounted[1]
        end
    end
    return INTERNAL_APP_ROOT
end

function desktop_storage.data_root_for_app(app_id, app_dir)
    local id = app_id_path(app_id)
    if not id then
        return nil, "InvalidAppId"
    end
    app_dir = tostring(app_dir or "")
    for _, drive in ipairs(desktop_storage.mounted()) do
        local prefix = tostring(drive.apps_path or "")
        if prefix ~= "" and (app_dir == combine(prefix, id) or app_dir:sub(1, #prefix + 1) == prefix .. "/") then
            return combine(drive.appdata_path, id), drive
        end
    end
    return combine(INTERNAL_APPDATA_ROOT, id)
end

desktop_storage.INTERNAL_APP_ROOT = INTERNAL_APP_ROOT
desktop_storage.INTERNAL_APPDATA_ROOT = INTERNAL_APPDATA_ROOT

return desktop_storage
