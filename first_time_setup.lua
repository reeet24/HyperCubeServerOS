-- HyperCubeServer all-in-one first-time setup.
-- Upload this file to Pastebin and run it on a fresh ComputerCraft server.

local REPO_OWNER = "reeet24"
local REPO_NAME = "HyperCubeServerOS"
local DEFAULT_BRANCH = "main"
local CONFIG_PATH = "server_config"

local INCLUDE_ROOTS = {
    "Kernal",
    "appstore",
    "installer",
    "docs",
    "init.lua",
    "startup.lua",
    "README.md",
    "checklist.md",
    "package_server.lua",
    "package_server.py",
    "update_server.lua",
    "first_time_setup.lua",
}

local CLEAN_PATHS = {
    "Kernal",
    "appstore",
    "installer",
    "docs",
    "init.lua",
    "startup.lua",
    "README.md",
    "checklist.md",
    "package_server.lua",
    "package_server.py",
    "update_server.lua",
    "first_time_setup.lua",
}

local EXCLUDE = {
    ["logs"] = true,
    ["user"] = true,
    ["hypercube_db"] = true,
    ["disk"] = true,
    ["server_config"] = true,
    ["github_token"] = true,
    ["banking/admin_token"] = true,
    ["hypercube_server_install"] = true,
}

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

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

local function normalize(path)
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("^%./", ""):gsub("^/+", "")
    path = path:gsub("//+", "/")
    if path == "." then
        path = ""
    end
    return path
end

local function encode_segment(segment)
    return tostring(segment or ""):gsub("([^%w%-%_%.%~])", function(char)
        return string.format("%%%02X", char:byte())
    end)
end

local function encode_path(path)
    path = normalize(path)
    local out = {}
    for segment in path:gmatch("[^/]+") do
        out[#out + 1] = encode_segment(segment)
    end
    return table.concat(out, "/")
end

local function ask(prompt, fallback)
    if fallback ~= nil then
        write(prompt .. " [" .. tostring(fallback) .. "]: ")
    else
        write(prompt .. ": ")
    end
    local value = trim(read())
    if value == "" and fallback ~= nil then
        return fallback
    end
    return value
end

local function ask_yes(prompt, fallback)
    write(prompt .. " [" .. (fallback and "Y/n" or "y/N") .. "] ")
    local value = trim(read()):lower()
    if value == "" then
        return fallback == true
    end
    return value == "y" or value == "yes"
end

local function ensure_parent(path)
    local dir = tostring(path):match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function write_file(path, data, binary)
    ensure_parent(path)
    local handle = fs.open(path, binary and "wb" or "w")
    if not handle then
        return false, "OpenFailed:" .. tostring(path)
    end
    handle.write(data or "")
    handle.close()
    return true
end

local function peripheral_type(name)
    if not peripheral or not peripheral.getType then
        return nil
    end
    return peripheral.getType(name)
end

local function list_modems()
    local out = {}
    if peripheral and peripheral.getNames and peripheral.wrap then
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral_type(name) == "modem" then
                local modem = peripheral.wrap(name)
                out[#out + 1] = {
                    name = name,
                    wireless = modem and modem.isWireless and modem.isWireless() or false,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.wireless ~= b.wireless then
            return a.wireless
        end
        return tostring(a.name) < tostring(b.name)
    end)
    return out
end

local function list_drives()
    local out = {}
    if peripheral and peripheral.getNames and peripheral.wrap then
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral_type(name) == "drive" then
                local drive = peripheral.wrap(name)
                local present = drive and drive.isDiskPresent and drive.isDiskPresent() or false
                local mount = present and drive.getMountPath and drive.getMountPath() or nil
                out[#out + 1] = {
                    name = name,
                    present = present,
                    mount = mount,
                    id = present and drive.getDiskID and drive.getDiskID() or nil,
                    label = present and drive.getDiskLabel and drive.getDiskLabel() or nil,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        return tostring(a.name) < tostring(b.name)
    end)
    return out
end

local function print_modems(modems)
    print("")
    print("Modems:")
    if #modems == 0 then
        print("  none found")
        return
    end
    for index, modem in ipairs(modems) do
        print("  " .. tostring(index) .. ". " .. tostring(modem.name)
            .. (modem.wireless and " wireless" or " wired"))
    end
end

local function print_drives(drives)
    print("")
    print("Disk drives:")
    if #drives == 0 then
        print("  none found")
        return
    end
    for index, drive in ipairs(drives) do
        local detail = drive.present and (" mount=" .. tostring(drive.mount)) or " empty"
        if drive.id then
            detail = detail .. " id=" .. tostring(drive.id)
        end
        if drive.label then
            detail = detail .. " label=" .. tostring(drive.label)
        end
        print("  " .. tostring(index) .. ". " .. tostring(drive.name) .. detail)
    end
end

local function choose_modem()
    while true do
        local modems = list_modems()
        print_modems(modems)
        if #modems == 0 then
            print("Attach a modem, then press enter to rescan.")
            read()
        else
            local value = ask("Server modem side/name", modems[1].name)
            for _, modem in ipairs(modems) do
                if tostring(value) == tostring(modem.name) then
                    return modem.name
                end
            end
            print("Unknown modem: " .. tostring(value))
        end
    end
end

local function choose_installer_drive()
    while true do
        local drives = list_drives()
        print_drives(drives)
        local present = {}
        for _, drive in ipairs(drives) do
            if drive.present and drive.mount then
                present[#present + 1] = drive
            end
        end
        if #present == 0 then
            print("Insert a disk for installer storage, then press enter to rescan.")
            read()
        else
            local value = ask("Installer disk drive", present[1].name)
            for _, drive in ipairs(present) do
                if tostring(value) == tostring(drive.name) or tostring(value) == tostring(drive.mount) then
                    return drive
                end
            end
            print("Unknown installer drive: " .. tostring(value))
        end
    end
end

local function drive_by_name(drives)
    local out = {}
    for _, drive in ipairs(drives) do
        out[tostring(drive.name)] = drive
        if drive.mount then
            out[tostring(drive.mount)] = drive
        end
    end
    return out
end

local function choose_db_drives(installer_drive)
    while true do
        local drives = list_drives()
        print_drives(drives)
        print("")
        print("Enter DB drive names separated by commas.")
        print("Example: drive_0,drive_1,drive_2,drive_3")
        local value = ask("DB drives", "")
        local by_name = drive_by_name(drives)
        local selected = {}
        local seen = {}
        for token in value:gmatch("[^,%s]+") do
            local drive = by_name[token]
            if drive and drive.present and drive.mount and not seen[drive.name] then
                if not installer_drive or drive.name ~= installer_drive.name then
                    selected[#selected + 1] = drive
                    seen[drive.name] = true
                end
            end
        end
        if #selected > 0 then
            return selected
        end
        print("No valid DB drives selected. Do not include the installer disk.")
    end
end

local function http_get(url, accept)
    if not http or not http.get then
        return nil, "HttpUnavailable"
    end
    local headers = {
        ["User-Agent"] = "HyperCubeServerOS-FirstTimeSetup",
        ["Accept"] = accept or "application/vnd.github+json",
    }
    local ok, response_or_err, request_err = pcall(http.get, url, headers)
    if not ok then
        return nil, response_or_err
    end
    local response = response_or_err
    if not response and tostring(request_err or ""):lower():find("header", 1, true) then
        ok, response_or_err, request_err = pcall(http.get, url)
        if not ok then
            return nil, response_or_err
        end
        response = response_or_err
    end
    if not response then
        return nil, request_err or "HttpRequestFailed"
    end
    local body = response.readAll()
    local code = response.getResponseCode and response.getResponseCode() or 200
    response.close()
    if tonumber(code) and tonumber(code) >= 400 then
        return nil, "Http" .. tostring(code) .. ": " .. tostring(body):sub(1, 120)
    end
    return body
end

local function decode_json(text)
    if not textutils or not textutils.unserializeJSON then
        return nil, "JsonUnavailable"
    end
    local ok, result = pcall(textutils.unserializeJSON, text)
    if not ok or result == nil then
        return nil, "JsonDecodeFailed"
    end
    return result
end

local function fetch_json(url)
    local body, err = http_get(url)
    if not body then
        return nil, err
    end
    return decode_json(body)
end

local function fetch_tree(branch)
    return fetch_json("https://api.github.com/repos/" .. REPO_OWNER .. "/" .. REPO_NAME
        .. "/git/trees/" .. encode_segment(branch) .. "?recursive=1")
end

local function fetch_commit_sha(branch)
    local decoded, err = fetch_json("https://api.github.com/repos/" .. REPO_OWNER .. "/" .. REPO_NAME
        .. "/commits/" .. encode_segment(branch))
    if not decoded then
        return nil, err
    end
    return decoded.sha, decoded.sha and nil or "CommitShaMissing"
end

local function tree_has_path(tree, path, kind)
    path = normalize(path)
    for _, entry in ipairs(tree and tree.tree or {}) do
        if normalize(entry.path) == path and (not kind or entry.type == kind) then
            return true
        end
    end
    return false
end

local function looks_like_root(tree, root)
    root = normalize(root)
    local prefix = root == "" and "" or root .. "/"
    return tree_has_path(tree, prefix .. "init.lua", "blob")
        and tree_has_path(tree, prefix .. "startup.lua", "blob")
        and tree_has_path(tree, prefix .. "Kernal", "tree")
        and tree_has_path(tree, prefix .. "installer", "tree")
end

local function find_remote_root(tree)
    for _, candidate in ipairs({ "computer/0", "0", "" }) do
        if looks_like_root(tree, candidate) then
            return normalize(candidate)
        end
    end
    for _, entry in ipairs(tree and tree.tree or {}) do
        if entry.type == "tree" and looks_like_root(tree, entry.path) then
            return normalize(entry.path)
        end
    end
    return nil, "ServerRootNotFound"
end

local function relative_path(remote_root, path)
    remote_root = normalize(remote_root)
    path = normalize(path)
    if remote_root == "" then
        return path
    end
    local prefix = remote_root .. "/"
    if path:sub(1, #prefix) ~= prefix then
        return nil
    end
    return path:sub(#prefix + 1)
end

local function include_relative(path)
    path = normalize(path)
    if path == "" or EXCLUDE[path] then
        return false
    end
    for excluded in pairs(EXCLUDE) do
        if path:sub(1, #excluded + 1) == excluded .. "/" then
            return false
        end
    end
    for _, root in ipairs(INCLUDE_ROOTS) do
        if path == root or path:sub(1, #root + 1) == root .. "/" then
            return true
        end
    end
    return false
end

local function local_path(repo_path, config)
    repo_path = normalize(repo_path)
    local installer_root = normalize(config.installer and config.installer.root or "installer")
    if installer_root ~= "installer" then
        if repo_path == "installer" then
            return installer_root
        end
        local prefix = "installer/"
        if repo_path:sub(1, #prefix) == prefix then
            return normalize(combine(installer_root, repo_path:sub(#prefix + 1)))
        end
    end
    return repo_path
end

local function raw_url(branch, remote_root, repo_path)
    local remote_path = remote_root == "" and repo_path or combine(remote_root, repo_path)
    return "https://raw.githubusercontent.com/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/"
        .. encode_segment(branch) .. "/" .. encode_path(remote_path)
end

local function collect_files(tree, remote_root)
    local files = {}
    for _, entry in ipairs(tree and tree.tree or {}) do
        if entry.type == "blob" then
            local relative = relative_path(remote_root, entry.path)
            if relative and include_relative(relative) then
                files[#files + 1] = {
                    path = relative,
                    size = entry.size or 0,
                }
            end
        end
    end
    table.sort(files, function(a, b)
        return a.path < b.path
    end)
    return files
end

local function clean_source_paths(config)
    for _, path in ipairs(CLEAN_PATHS) do
        local target = local_path(path, config)
        if fs.exists(target) then
            fs.delete(target)
        end
    end
end

local function download_and_write(files, branch, remote_root, config)
    for index, file in ipairs(files) do
        local data, err = http_get(raw_url(branch, remote_root, file.path), "application/octet-stream")
        if not data then
            return false, "DownloadFailed:" .. tostring(file.path) .. ":" .. tostring(err)
        end
        local target = local_path(file.path, config)
        local ok, write_err = write_file(target, data, true)
        if not ok then
            return false, write_err
        end
        if index % 10 == 0 or index == #files then
            print("Installed " .. tostring(index) .. "/" .. tostring(#files))
        end
    end
    return true
end

local function write_config(config)
    return write_file(CONFIG_PATH, textutils.serialize(config), false)
end

local function write_install_record(branch, remote_root, files, commit_sha)
    return write_file("hypercube_server_install", textutils.serialize({
        os = "HyperCubeServer",
        installed_at = now(),
        files = #files,
        source = "github",
        repo = REPO_OWNER .. "/" .. REPO_NAME,
        branch = branch,
        remote_root = remote_root,
        commit_sha = commit_sha,
        first_time_setup = true,
    }), false)
end

local function fetch_repo()
    local branch = ask("GitHub branch", DEFAULT_BRANCH)
    local tree, err = fetch_tree(branch)
    if not tree and branch == DEFAULT_BRANCH then
        print("Branch main unavailable, trying master...")
        branch = "master"
        tree, err = fetch_tree(branch)
    end
    if not tree then
        return nil, nil, nil, err
    end
    if tree.truncated == true then
        return nil, nil, nil, "GitHubTreeTruncated"
    end
    local root, root_err = find_remote_root(tree)
    if not root then
        return nil, nil, nil, root_err
    end
    local sha = fetch_commit_sha(branch)
    return branch, tree, root, nil, sha
end

term.clear()
term.setCursorPos(1, 1)
print("HyperCubeServer All-In-One Setup")
print("Repo: " .. REPO_OWNER .. "/" .. REPO_NAME)
print("")

if not http or not http.get then
    print("HTTP API is disabled. Enable http in ComputerCraft config first.")
    return
end

local modem = choose_modem()
local installer_drive = choose_installer_drive()
local installer_root = normalize(combine(installer_drive.mount, "installer"))
local db_drives = choose_db_drives(installer_drive)
local min_replicas = tonumber(ask("DB replica groups", 2)) or 2
if min_replicas < 1 then
    min_replicas = 1
end

local db_records = {}
for _, drive in ipairs(db_drives) do
    db_records[#db_records + 1] = {
        name = drive.name,
        mount = drive.mount,
        id = drive.id,
        label = drive.label,
    }
end

local config = {
    version = 1,
    configured_at = now(),
    db = {
        root = "hypercube_db",
        min_replicas = min_replicas,
        drives = db_records,
    },
    network = {
        modem = modem,
        protocol = "tesserac",
        hostname = "HyperCubeServer",
    },
    installer = {
        root = installer_root,
        drive = {
            name = installer_drive.name,
            mount = installer_drive.mount,
            id = installer_drive.id,
            label = installer_drive.label,
        },
    },
}

print("")
print("Fetching repository metadata...")
local branch, tree, remote_root, fetch_err, commit_sha = fetch_repo()
if not branch then
    print("Repo fetch failed: " .. tostring(fetch_err))
    return
end
local files = collect_files(tree, remote_root)
print("Remote root: " .. (remote_root == "" and "/" or remote_root))
print("Files: " .. tostring(#files))
print("Installer target: " .. installer_root)
print("")
print("This will install HyperCubeServerOS source files on this computer.")
print("The installer folder will be written to the selected installer disk.")
if not ask_yes("Continue install?", true) then
    print("Cancelled.")
    return
end

print("Cleaning old source paths...")
clean_source_paths(config)

print("Downloading and installing...")
local install_ok, install_err = download_and_write(files, branch, remote_root, config)
if not install_ok then
    print("Install failed: " .. tostring(install_err))
    return
end

local config_ok, config_err = write_config(config)
if not config_ok then
    print("Config write failed: " .. tostring(config_err))
    return
end

local record_ok, record_err = write_install_record(branch, remote_root, files, commit_sha)
if not record_ok then
    print("Install record failed: " .. tostring(record_err))
    return
end

print("")
print("Setup complete.")
print("Wrote " .. CONFIG_PATH)
print("Modem: " .. tostring(modem))
print("Installer root: " .. tostring(installer_root))
print("DB drives: " .. tostring(#db_records))
print("")
if ask_yes("Reboot now?", true) then
    os.reboot()
end
