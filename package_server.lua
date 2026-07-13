local SOURCE_ROOT = "."
local OUTPUT_FILE = "hypercube_server_pastebin.lua"
local CHUNK_SIZE = 240000
local BATCH_INSTALL_FILE = "hypercube_server_pastebin_batch_install.lua"

local ARGS = { ... }

local INCLUDE_ROOTS = {
    "Kernal",
    "appstore",
    "installer",
    "init.lua",
    "startup.lua",
    "checklist.md",
}

local EXCLUDE = {
    [OUTPUT_FILE] = true,
    ["logs"] = true,
    ["user"] = true,
    ["hypercube_db"] = true,
    ["package_server.lua"] = true,
}

local function has_flag(flag)
    for _, value in ipairs(ARGS) do
        if value == flag then
            return true
        end
    end
    return false
end

local function get_option(name)
    for index, value in ipairs(ARGS) do
        if value == name then
            return ARGS[index + 1]
        end
        local prefix = name .. "="
        if tostring(value):sub(1, #prefix) == prefix then
            return tostring(value):sub(#prefix + 1)
        end
    end
    return nil
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
    if a == "" then
        return b
    end
    if a:sub(-1) == "/" then
        return a .. b
    end
    return a .. "/" .. b
end

local function normalize(path)
    return tostring(path or ""):gsub("\\", "/"):gsub("^%./", ""):gsub("^/+", "")
end

local function is_excluded(path)
    path = normalize(path)
    if EXCLUDE[path] then
        return true
    end
    for excluded in pairs(EXCLUDE) do
        if path:sub(1, #excluded + 1) == excluded .. "/" then
            return true
        end
    end
    return false
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

local function write_all(path, data)
    local handle = fs.open(path, "w")
    if not handle then
        return false, "OpenFailed"
    end
    handle.write(data)
    handle.close()
    return true
end

local function output_part_name(index)
    return "hypercube_server_pastebin_chunk_" .. string.format("%02d", index) .. ".lua"
end

local function output_install_name()
    return "hypercube_server_pastebin_install.lua"
end

local function cleanup_outputs()
    local paths = {
        OUTPUT_FILE,
        output_install_name(),
        BATCH_INSTALL_FILE,
    }
    for _, path in ipairs(paths) do
        if fs.exists(path) then
            fs.delete(path)
        end
    end
    for i = 1, 99 do
        local path = output_part_name(i)
        if fs.exists(path) then
            fs.delete(path)
        end
    end
end

local function pastebin_code_from_text(text)
    text = tostring(text or "")
    local patterns = {
        "pastebin%.com/raw/([%w_%-]+)",
        "pastebin%.com/([%w_%-]+)",
        "code:%s*([%w_%-]+)",
        "Code:%s*([%w_%-]+)",
    }
    for _, pattern in ipairs(patterns) do
        local code = text:match(pattern)
        if code then
            return code
        end
    end
    return nil
end

local function url_encode(value)
    value = tostring(value or "")
    value = value:gsub("\n", "\r\n")
    value = value:gsub("([^%w%-%_%.%~ ])", function(char)
        return string.format("%%%02X", char:byte())
    end)
    return value:gsub(" ", "+")
end

local function form_encode(fields)
    local parts = {}
    for key, value in pairs(fields) do
        parts[#parts + 1] = url_encode(key) .. "=" .. url_encode(value)
    end
    table.sort(parts)
    return table.concat(parts, "&")
end

local function collect_tree(root, relative, files)
    relative = normalize(relative)
    if is_excluded(relative) then
        return true
    end

    local path = relative == "" and root or combine(root, relative)
    if fs.isDir(path) then
        local children = fs.list(path)
        table.sort(children)
        for _, child in ipairs(children) do
            local ok, err = collect_tree(root, relative == "" and child or combine(relative, child), files)
            if not ok then
                return false, err
            end
        end
        return true
    end

    local data, err = read_all(path)
    if not data then
        return false, err
    end
    files[#files + 1] = {
        path = relative,
        data = data,
        size = #data,
    }
    return true
end

local function collect()
    local files = {}
    for _, root_path in ipairs(INCLUDE_ROOTS) do
        if fs.exists(root_path) then
            local ok, err = collect_tree(SOURCE_ROOT, root_path, files)
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

local function installer_source(files)
    local lines = {
        "-- HyperCubeServer pastebin installer",
        "-- Generated by package_server.lua",
        "local PACKAGE = {",
        "  name = \"HyperCubeServer\",",
        "  generated_at = " .. tostring(now()) .. ",",
        "  files = {",
    }

    for _, file in ipairs(files) do
        lines[#lines + 1] = "    { path = " .. string.format("%q", file.path) .. ", data = " .. string.format("%q", file.data) .. " },"
    end

    lines[#lines + 1] = "  },"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = [[

local CLEAN_PATHS = {
  "Kernal",
  "installer",
  "init.lua",
  "startup.lua",
  "checklist.md",
}

local function ensure_parent(path)
  local dir = path:match("^(.*)/[^/]+$")
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
end

local function write_file(path, data)
  ensure_parent(path)
  local handle = fs.open(path, "wb")
  if not handle then
    error("Failed to open " .. tostring(path))
  end
  handle.write(data)
  handle.close()
end

term.clear()
term.setCursorPos(1, 1)
print("HyperCubeServer installer")
print("Files: " .. tostring(#PACKAGE.files))
print("")
write("Install/overwrite this computer? [y/N] ")
local answer = read()
if tostring(answer or ""):lower() ~= "y" then
  print("Cancelled.")
  return
end

for _, path in ipairs(CLEAN_PATHS) do
  if fs.exists(path) then
    fs.delete(path)
  end
end

for i, file in ipairs(PACKAGE.files) do
  write_file(file.path, file.data)
  if i % 10 == 0 then
    print("Installed " .. tostring(i) .. "/" .. tostring(#PACKAGE.files))
  end
end

local handle = fs.open("hypercube_server_install", "w")
if handle then
  handle.write(textutils.serialize({
    os = PACKAGE.name,
    installed_at = os.epoch and os.epoch("utc") or os.clock(),
    files = #PACKAGE.files,
    source = "pastebin",
  }))
  handle.close()
end

print("HyperCubeServer installed.")
print("Run 'reboot' or restart this computer.")
]]

    return table.concat(lines, "\n")
end

local function chunk_bootstrap_source(chunk_count)
    return [=[-- HyperCubeServer chunked pastebin installer
-- Generated by package_server.lua
local PACKAGE_NAME = "HyperCubeServer"
local CHUNK_COUNT = ]=] .. tostring(chunk_count) .. [=[

local function load_lua(source, name, env)
  env = env or _G
  if load then
    local ok, loader_or_err = pcall(load, source, name, "t", env)
    if ok and loader_or_err then
      if setfenv then setfenv(loader_or_err, env) end
      return loader_or_err
    end
    if ok and type(loader_or_err) == "string" then
      return nil, loader_or_err
    end
  end
  if loadstring then
    local loader, err = loadstring(source, name)
    if not loader then return nil, err end
    if setfenv then setfenv(loader, env) end
    return loader
  end
  return nil, "NoLoader"
end

local function read_code(index)
  write("Pastebin code for chunk " .. tostring(index) .. "/" .. tostring(CHUNK_COUNT) .. ": ")
  local code = read()
  code = tostring(code or ""):match("^%s*(.-)%s*$")
  if code == "" then
    error("Missing code for chunk " .. tostring(index))
  end
  return code
end

local function fetch_chunk(index, code)
  if not http or not http.get then
    error("HTTP API is required to fetch pastebin chunks")
  end
  local url = "https://pastebin.com/raw/" .. tostring(code)
  local response, err = http.get(url)
  if not response then
    error("Chunk " .. tostring(index) .. " download failed: " .. tostring(err))
  end
  local source = response.readAll()
  response.close()
  local loader, load_err = load_lua(source, "@chunk_" .. tostring(index), {})
  if not loader then
    error("Chunk " .. tostring(index) .. " load failed: " .. tostring(load_err))
  end
  local ok, data = pcall(loader)
  if not ok then
    error("Chunk " .. tostring(index) .. " returned error: " .. tostring(data))
  end
  if type(data) ~= "string" then
    error("Chunk " .. tostring(index) .. " did not return string data")
  end
  return data
end

term.clear()
term.setCursorPos(1, 1)
print(PACKAGE_NAME .. " chunked installer")
print("Chunks required: " .. tostring(CHUNK_COUNT))
print("Upload all chunk files first with pastebin put, then enter each code here.")
print("")

local chunks = {}
for i = 1, CHUNK_COUNT do
  chunks[i] = fetch_chunk(i, read_code(i))
  print("Fetched chunk " .. tostring(i) .. "/" .. tostring(CHUNK_COUNT))
end

local installer_source = table.concat(chunks)
local installer, err = load_lua(installer_source, "@hypercube_server_combined", _G)
if not installer then
  error("Combined installer failed to load: " .. tostring(err))
end
return installer()
]=]
end

local function batch_install_source(codes)
    local encoded = {}
    for _, code in ipairs(codes) do
        encoded[#encoded + 1] = string.format("%q", code)
    end

    return [=[-- HyperCubeServer batch pastebin installer
-- Generated by package_server.lua
local PACKAGE_NAME = "HyperCubeServer"
local CHUNK_CODES = { ]=] .. table.concat(encoded, ", ") .. [=[ }

local function load_lua(source, name, env)
  env = env or _G
  if load then
    local ok, loader_or_err = pcall(load, source, name, "t", env)
    if ok and loader_or_err then
      if setfenv then setfenv(loader_or_err, env) end
      return loader_or_err
    end
    if ok and type(loader_or_err) == "string" then
      return nil, loader_or_err
    end
  end
  if loadstring then
    local loader, err = loadstring(source, name)
    if not loader then return nil, err end
    if setfenv then setfenv(loader, env) end
    return loader
  end
  return nil, "NoLoader"
end

local function fetch_chunk(index, code)
  if not http or not http.get then
    error("HTTP API is required to fetch pastebin chunks")
  end
  local url = "https://pastebin.com/raw/" .. tostring(code)
  local response, err = http.get(url)
  if not response then
    error("Chunk " .. tostring(index) .. " download failed: " .. tostring(err))
  end
  local source = response.readAll()
  response.close()
  local loader, load_err = load_lua(source, "@chunk_" .. tostring(index), {})
  if not loader then
    error("Chunk " .. tostring(index) .. " load failed: " .. tostring(load_err))
  end
  local ok, data = pcall(loader)
  if not ok then
    error("Chunk " .. tostring(index) .. " returned error: " .. tostring(data))
  end
  if type(data) ~= "string" then
    error("Chunk " .. tostring(index) .. " did not return string data")
  end
  return data
end

term.clear()
term.setCursorPos(1, 1)
print(PACKAGE_NAME .. " batch installer")
print("Chunks: " .. tostring(#CHUNK_CODES))
print("")

local chunks = {}
for i, code in ipairs(CHUNK_CODES) do
  chunks[i] = fetch_chunk(i, code)
  print("Fetched chunk " .. tostring(i) .. "/" .. tostring(#CHUNK_CODES))
end

local installer_source = table.concat(chunks)
local installer, err = load_lua(installer_source, "@hypercube_server_combined", _G)
if not installer then
  error("Combined installer failed to load: " .. tostring(err))
end
return installer()
]=]
end

local function write_chunked_outputs(source)
    local chunks = {}
    local index = 1
    for start_pos = 1, #source, CHUNK_SIZE do
        local chunk = source:sub(start_pos, start_pos + CHUNK_SIZE - 1)
        local path = output_part_name(index)
        local ok, err = write_all(path, "return " .. string.format("%q", chunk) .. "\n")
        if not ok then
            return nil, err
        end
        chunks[#chunks + 1] = path
        index = index + 1
    end

    local bootstrap = chunk_bootstrap_source(#chunks)
    local install_path = output_install_name()
    local ok, err = write_all(install_path, bootstrap)
    if not ok then
        return nil, err
    end

    local outputs = { install_path }
    for _, path in ipairs(chunks) do
        outputs[#outputs + 1] = path
    end
    return outputs
end

local function capture_pastebin_put(path)
    if not shell or not shell.run or not term or not term.current or not term.redirect then
        return nil, "ShellPastebinUnavailable"
    end

    local previous = term.current()
    local lines = {}
    local current = ""
    local capture = {
        write = function(text)
            current = current .. tostring(text or "")
        end,
        blit = function(text)
            current = current .. tostring(text or "")
        end,
        clear = function() end,
        clearLine = function()
            current = ""
        end,
        setCursorPos = function() end,
        getCursorPos = function()
            return 1, #lines + 1
        end,
        getSize = function()
            return 80, 24
        end,
        setTextColor = function() end,
        setTextColour = function() end,
        setBackgroundColor = function() end,
        setBackgroundColour = function() end,
        isColor = function()
            return true
        end,
        isColour = function()
            return true
        end,
        scroll = function() end,
    }

    term.redirect(capture)
    local ok, result = pcall(shell.run, "pastebin", "put", path)
    term.redirect(previous)
    if current ~= "" then
        lines[#lines + 1] = current
    end

    local output = table.concat(lines, "\n")
    if not ok then
        return nil, result
    end
    if result == false then
        return nil, output ~= "" and output or "PastebinPutFailed"
    end

    local code = pastebin_code_from_text(output)
    if not code then
        return nil, "PastebinCodeNotFound: " .. output
    end
    return code, output
end

local function upload_with_api(path, dev_key)
    if not http or not http.post then
        return nil, "HttpPostUnavailable"
    end
    if not dev_key or dev_key == "" then
        return nil, "PastebinDevKeyRequired"
    end

    local source, read_err = read_all(path)
    if not source then
        return nil, read_err
    end

    local body = form_encode({
        api_dev_key = dev_key,
        api_option = "paste",
        api_paste_code = source,
        api_paste_name = path,
        api_paste_private = get_option("--private") or "1",
        api_paste_expire_date = get_option("--expire") or "N",
        api_paste_format = "lua",
    })

    local user_key = get_option("--user-key")
    if user_key and user_key ~= "" then
        body = body .. "&" .. form_encode({ api_user_key = user_key })
    end

    local ok, response_or_err = pcall(http.post,
        "https://pastebin.com/api/api_post.php",
        body,
        { ["Content-Type"] = "application/x-www-form-urlencoded" }
    )
    if not ok then
        return nil, response_or_err
    end

    local response = response_or_err
    if not response then
        return nil, "PastebinPostFailed"
    end

    local text = response.readAll()
    response.close()
    if tostring(text):match("^Bad API request") then
        return nil, text
    end

    local code = pastebin_code_from_text(text)
    if not code then
        return nil, "PastebinCodeNotFound: " .. tostring(text)
    end
    return code, text
end

local function upload_file(path)
    local code, detail = capture_pastebin_put(path)
    if code then
        return code, detail, "pastebin"
    end

    local dev_key = get_option("--dev-key")
    if not dev_key and fs.exists("pastebin_dev_key") then
        local key_data = read_all("pastebin_dev_key")
        dev_key = key_data and key_data:match("^%s*(.-)%s*$") or nil
    end
    code, detail = upload_with_api(path, dev_key)
    if code then
        return code, detail, "api"
    end

    return nil, detail
end

local function upload_batch_install(chunk_outputs)
    local chunk_paths = {}
    for _, path in ipairs(chunk_outputs) do
        if tostring(path):match("_chunk_%d+%.lua$") then
            chunk_paths[#chunk_paths + 1] = path
        end
    end

    if #chunk_paths == 0 then
        return nil, "NoChunkFiles"
    end

    local codes = {}
    for index, path in ipairs(chunk_paths) do
        print("Uploading chunk " .. tostring(index) .. "/" .. tostring(#chunk_paths) .. ": " .. path)
        local code, upload_err = upload_file(path)
        if not code then
            return nil, "Upload failed for " .. path .. ": " .. tostring(upload_err)
        end
        codes[#codes + 1] = code
        print("  code: " .. code)
    end

    local ok, write_err = write_all(BATCH_INSTALL_FILE, batch_install_source(codes))
    if not ok then
        return nil, write_err
    end

    print("Uploading batch installer: " .. BATCH_INSTALL_FILE)
    local final_code, final_err = upload_file(BATCH_INSTALL_FILE)
    if not final_code then
        return nil, "Upload failed for " .. BATCH_INSTALL_FILE .. ": " .. tostring(final_err)
    end

    return {
        path = BATCH_INSTALL_FILE,
        code = final_code,
        chunks = codes,
    }
end

local function upload_batch_install_streaming(source)
    local codes = {}
    local total_chunks = math.ceil(#source / CHUNK_SIZE)

    for index = 1, total_chunks do
        local start_pos = ((index - 1) * CHUNK_SIZE) + 1
        local chunk = source:sub(start_pos, start_pos + CHUNK_SIZE - 1)
        local path = output_part_name(index)
        local ok, write_err = write_all(path, "return " .. string.format("%q", chunk) .. "\n")
        if not ok then
            return nil, "Chunk write failed for " .. path .. ": " .. tostring(write_err)
        end

        print("Uploading chunk " .. tostring(index) .. "/" .. tostring(total_chunks) .. ": " .. path)
        local code, upload_err = upload_file(path)
        if fs.exists(path) then
            fs.delete(path)
        end
        if not code then
            return nil, "Upload failed for " .. path .. ": " .. tostring(upload_err)
        end
        code = code:sub(1,8)
        codes[#codes + 1] = code
        print("  code: " .. code)
    end

    local ok, write_err = write_all(BATCH_INSTALL_FILE, batch_install_source(codes))
    if not ok then
        return nil, write_err
    end

    print("Uploading batch installer: " .. BATCH_INSTALL_FILE)
    local final_code, final_err = upload_file(BATCH_INSTALL_FILE)
    if not final_code then
        return nil, "Upload failed for " .. BATCH_INSTALL_FILE .. ": " .. tostring(final_err)
    end
    final_code = final_code:sub(1,8)

    return {
        path = BATCH_INSTALL_FILE,
        code = final_code,
        chunks = codes,
    }
end

cleanup_outputs()

local files, err = collect()
if not files then
    print("Package failed: " .. tostring(err))
    return
end

local total = 0
for _, file in ipairs(files) do
    total = total + file.size
end

local source = installer_source(files)
print("Files packed: " .. tostring(#files))
print("Raw bytes: " .. tostring(total))
print("Installer bytes: " .. tostring(#source))

if has_flag("--upload") then
    local result, upload_err = upload_batch_install_streaming(source)
    if not result then
        print("Upload failed: " .. tostring(upload_err))
        print("If the built-in pastebin program is unavailable, run with --dev-key <Pastebin API key> or place it in pastebin_dev_key.")
        return
    end
    print("")
    print("Wrote " .. result.path)
    print("Final installer Pastebin code: " .. result.code)
    print("Install command:")
    print("pastebin run " .. result.code)
else
    if has_flag("--single") then
        local ok, write_err = write_all(OUTPUT_FILE, source)
        if not ok then
            print("Write failed: " .. tostring(write_err))
            return
        end
        print("Wrote " .. OUTPUT_FILE)
    else
        print("Skipping " .. OUTPUT_FILE .. " to save disk space. Pass --single to write it.")
    end

    local chunk_outputs, chunk_err = write_chunked_outputs(source)
    if not chunk_outputs then
        print("Chunk write failed: " .. tostring(chunk_err))
        return
    end

    print("Pastebin-safe chunk files:")
    for _, path in ipairs(chunk_outputs) do
        local size = fs.exists(path) and fs.getSize(path) or 0
        print("  " .. path .. " (" .. tostring(size) .. " bytes)")
    end
    print("Run with --upload to upload chunks and generate a final batch installer code.")
end
