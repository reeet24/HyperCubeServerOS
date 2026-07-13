local logger = {
    levels = {
        DEBUG = 1,
        INFO = 2,
        WARN = 3,
        ERROR = 4,
    },
    min_level = "DEBUG",
    entries = {},
    max_entries = 200,
    max_file_size = 1024,
    sinks = {},
    log_path = "/logs/kernel.log",
    file_path = "logs/kernel.log",
    file_enabled = false,
}

local function ensure_dir(path)
    if not fs or not fs.makeDir then
        return false, "FsUnavailable"
    end
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and (not fs.exists or not fs.exists(dir)) then
        fs.makeDir(dir)
    end
    return true
end

local function timestamp()
    if os.date then
        return os.date("%Y-%m-%d %H:%M:%S")
    end
    return tostring(os.clock())
end

local function format_entry(entry)
    local pid = entry.pid and (" pid=" .. tostring(entry.pid)) or ""
    local repeats = entry.repeats and entry.repeats > 1 and (" x" .. tostring(entry.repeats)) or ""
    return string.format("[%s] %s%s %s%s", entry.time, entry.level, pid, entry.message, repeats)
end

function logger.log(level, message, context)
    level = string.upper(level or "INFO")
    if not logger.levels[level] then
        level = "INFO"
    end
    if logger.levels[level] < logger.levels[logger.min_level] then
        return nil
    end

    local pid = context and (context.pid or context.process_id)
    message = tostring(message)

    local previous = logger.entries[#logger.entries]
    if previous and previous.level == level and previous.message == message and previous.pid == pid then
        previous.repeats = (previous.repeats or 1) + 1
        previous.time = timestamp()
        previous.context = context
        return previous
    end

    local entry = {
        time = timestamp(),
        level = level,
        message = message,
        pid = pid,
        context = context,
        repeats = 1,
    }

    table.insert(logger.entries, entry)
    while #logger.entries > logger.max_entries do
        table.remove(logger.entries, 1)
    end

    if logger.file_enabled and fs and fs.open then

        -- Check file size before writing
        local file_size = 0
        if fs.exists(logger.file_path) then
            local handle = fs.open(logger.file_path, "r")
            if handle then
                file_size = handle.readAll():len()
                handle.close()
            end
        end

        -- If the file size exceeds the maximum allowed size, and a DB is available, persist the log to the DB and clear the file
        if file_size >= logger.max_file_size then
            if logger.persist then
                local vfs = _G.vfs -- Assuming a global VFS is available
                if vfs then
                    local success, err = logger.persist(vfs, nil, logger.log_path)
                    if success then
                        -- Clear the log file after persisting
                        local handle = fs.open(logger.file_path, "w")
                        if handle then
                            handle.write("") -- Clear the file
                            handle.close()
                        end
                    else
                        -- Handle persistence error (optional)
                    end
                end
            end
        end

        local handle = fs.open(logger.file_path, "a")
        if handle then
            handle.writeLine(format_entry(entry))
            handle.close()
        end
    end

    for _, sink in pairs(logger.sinks) do
        pcall(sink, entry)
    end

    return entry
end

function logger.info(message, context)
    return logger.log("INFO", message, context)
end

function logger.warn(message, context)
    return logger.log("WARN", message, context)
end

function logger.error(message, context)
    return logger.log("ERROR", message, context)
end

function logger.debug(message, context)
    return logger.log("DEBUG", message, context)
end

function logger.lines()
    local lines = {}
    for i, entry in ipairs(logger.entries) do
        lines[i] = format_entry(entry)
    end
    return lines
end

function logger.add_sink(id, sink)
    if not id or type(sink) ~= "function" then
        return false, "InvalidSink"
    end
    logger.sinks[id] = sink
    return true
end

function logger.remove_sink(id)
    logger.sinks[id] = nil
    return true
end

function logger.start_file(path)
    path = path or logger.file_path
    logger.file_path = path
    local ok, err = ensure_dir(path)
    if not ok then
        logger.file_enabled = false
        return false, err
    end
    if not fs or not fs.open then
        logger.file_enabled = false
        return false, "FsUnavailable"
    end

    local handle = fs.open(path, "w")
    if not handle then
        logger.file_enabled = false
        return false, "OpenFailed"
    end
    handle.close()
    logger.file_enabled = true
    return true
end

function logger.stop_file()
    logger.file_enabled = false
    return true
end

function logger.persist(vfs, context, path)
    if not vfs then
        return false, "MissingVFS"
    end

    path = path or logger.log_path
    local data = table.concat(logger.lines(), "\n") .. "\n"
    local result = vfs.write_file(context, path, data)
    return result and result.success == true, result
end

return logger
