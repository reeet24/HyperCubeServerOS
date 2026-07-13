local appstore = {}

local APPSTORE_ROOT = "appstore"
local APP_ROOT = "appstore/apps"
local TOKEN_PATH = "appstore/admin_token"

local SEED_APPS = {
    {
        id = "notes",
        title = "Notes",
        version = "1.0.0",
        author = "Tesserac",
        description = "Simple local notes stored in your encrypted HCFS.",
        source = [=[
local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "Notes",
        label = "Notes",
        color = C.cyan,
        dock = false,
        render_mode = "exclusive",
    },
}

local function truncate(text, width)
    text = tostring(text or "")
    if #text <= width then
        return text
    end
    if width <= 3 then
        return text:sub(1, width)
    end
    return text:sub(1, width - 3) .. "..."
end

local function write_line(ctx, row, text, fg)
    api.screen.write(ctx.x, ctx.y + row, truncate(text, ctx.width), fg or C.white, C.black)
end

local function ensure_state(state)
    if state.ready then
        return
    end
    state.ready = true
    state.body = api.fs.read("note.txt") or ""
    state.message = nil
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)
    write_line(ctx, 0, "Notes", C.yellow)
    write_line(ctx, 2, state.body == "" and "Tap keys to write..." or state.body, C.white)
    write_line(ctx, ctx.height - 3, "Enter saves, Backspace deletes", C.lightGray)
    if state.message then
        write_line(ctx, ctx.height - 1, state.message, C.green)
    end
end

function app.on_key(ctx)
    local state = ctx.state
    ensure_state(state)
    if ctx.event.type == "char" then
        local ch = ctx.event.raw and ctx.event.raw[2] or ""
        if #state.body < 220 then
            state.body = state.body .. ch
            state.message = nil
        end
        return true
    end

    local key = ctx.event.raw and ctx.event.raw[2]
    if not keys then
        return false
    end
    if key == keys.backspace then
        state.body = state.body:sub(1, math.max(0, #state.body - 1))
        state.message = nil
        return true
    elseif key == keys.enter then
        api.fs.write("note.txt", state.body)
        state.message = "Saved"
        return true
    end
    return false
end

return app
]=],
    },
    {
        id = "chirper",
        title = "Chirper",
        version = "1.0.0",
        author = "Tesserac",
        description = "A short-post timeline backed by your TesseracID.",
        source = [=[
local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "Chirper",
        label = "Chirp",
        color = C.purple,
        dock = false,
        render_mode = "exclusive",
    },
}

local function truncate(text, width)
    text = tostring(text or "")
    if #text <= width then
        return text
    end
    if width <= 3 then
        return text:sub(1, width)
    end
    return text:sub(1, width - 3) .. "..."
end

local function write_line(ctx, row, text, fg)
    api.screen.write(ctx.x, ctx.y + row, truncate(text, ctx.width), fg or C.white, C.black)
end

local function request(message, expected)
    if not api.hypernet or not api.hypernet.request then
        return nil, "HyperNetUnavailable"
    end
    message.username = api.identity and api.identity.username or message.username
    local ok, reply, err = pcall(api.hypernet.request, message, expected, 10)
    if not ok then
        return nil, reply
    end
    return reply, err
end

local function ensure_state(state)
    if state.ready then
        return
    end
    state.ready = true
    state.loaded = false
    state.posts = {}
    state.profile = nil
    state.body = ""
    state.focus = "body"
    state.status = nil
    state.error = nil
end

local function refresh(state)
    local reply, err = request({
        type = "chirper.feed",
    }, "chirper.feed.result")

    state.loaded = true
    if reply and reply.ok then
        state.profile = reply.result and reply.result.profile or nil
        state.posts = reply.result and reply.result.posts or {}
        state.error = nil
    else
        state.error = (reply and reply.error) or err or "ChirperUnavailable"
    end
end

local function post(state)
    if state.body == "" then
        state.error = "Write something first"
        return
    end

    state.status = "Posting..."
    local reply, err = request({
        type = "chirper.post",
        body = state.body,
    }, "chirper.post.result")

    if reply and reply.ok then
        state.body = ""
        state.status = "Posted"
        state.error = nil
        refresh(state)
    else
        state.status = nil
        state.error = (reply and reply.error) or err or "PostFailed"
    end
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)
    if not state.loaded then
        refresh(state)
    end

    local username = state.profile and state.profile.username or (api.identity and api.identity.username) or "guest"
    write_line(ctx, 0, "Chirper @" .. tostring(username), C.yellow)

    ctx.buttons.chirper_refresh = api.screen.button("chirper_refresh", ctx.x, ctx.y + 2, 9, "Refresh", {
        fg = C.white,
        bg = C.blue,
    })
    ctx.buttons.chirper_post = api.screen.button("chirper_post", ctx.x + 11, ctx.y + 2, 7, "Post", {
        fg = C.white,
        bg = state.body ~= "" and C.green or C.gray,
    })

    local composer = state.body == "" and "Say something..." or state.body
    ctx.buttons.chirper_body = api.screen.button("chirper_body", ctx.x, ctx.y + 4, math.min(ctx.width, 24), truncate(composer, 24), {
        fg = state.body == "" and C.lightGray or C.white,
        bg = state.focus == "body" and C.blue or C.gray,
    })

    local row = 6
    if #state.posts == 0 then
        write_line(ctx, row, "No chirps yet.", C.lightGray)
    else
        for _, item in ipairs(state.posts) do
            if row >= ctx.height - 2 then
                break
            end
            write_line(ctx, row, "@" .. tostring(item.username or "user"), C.cyan)
            row = row + 1
            write_line(ctx, row, tostring(item.body or ""), C.white)
            row = row + 2
        end
    end

    if state.error then
        write_line(ctx, ctx.height - 1, state.error, C.red)
    elseif state.status then
        write_line(ctx, ctx.height - 1, state.status, C.green)
    else
        write_line(ctx, ctx.height - 1, "Enter posts, Backspace edits", C.lightGray)
    end
end

function app.on_touch(ctx)
    local state = ctx.state
    ensure_state(state)
    if ctx.button_id == "chirper_refresh" then
        refresh(state)
        return true
    elseif ctx.button_id == "chirper_post" then
        post(state)
        return true
    elseif ctx.button_id == "chirper_body" then
        state.focus = "body"
        state.status = nil
        state.error = nil
        return true
    end
    return false
end

function app.on_key(ctx)
    local state = ctx.state
    ensure_state(state)
    if ctx.event.type == "char" then
        local ch = ctx.event.raw and ctx.event.raw[2] or ""
        if #state.body < 240 then
            state.body = state.body .. ch
            state.status = nil
            state.error = nil
        end
        return true
    end

    if not keys then
        return false
    end
    local key = ctx.event.raw and ctx.event.raw[2]
    if key == keys.backspace then
        state.body = state.body:sub(1, math.max(0, #state.body - 1))
        state.status = nil
        state.error = nil
        return true
    elseif key == keys.enter then
        post(state)
        return true
    elseif key == keys.r then
        refresh(state)
        return true
    end
    return false
end

return app
]=],
    },
    {
        id = "trains",
        title = "CMR Trains",
        version = "1.0.0",
        author = "Tesserac",
        description = "Live CMR train timetable sorted by soonest ETA.",
        source = [=[
local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "CMR Trains",
        label = "Rail",
        color = C.blue,
        dock = false,
        render_mode = "exclusive",
    },
}

local function truncate(text, width)
    text = tostring(text or "")
    if #text <= width then
        return text
    end
    if width <= 3 then
        return text:sub(1, width)
    end
    return text:sub(1, width - 3) .. "..."
end

local function write_line(ctx, row, text, fg)
    api.screen.write(ctx.x, ctx.y + row, truncate(text, ctx.width), fg or C.white, C.black)
end

local function request(force)
    if not api.hypernet or not api.hypernet.request then
        return nil, "HyperNetUnavailable"
    end
    local ok, reply, err = pcall(api.hypernet.request, {
        type = "train.schedule",
        force = force == true,
    }, "train.schedule.result", 12)
    if not ok then
        return nil, reply
    end
    return reply, err
end

local function eta_label(minutes)
    minutes = tonumber(minutes)
    if not minutes then
        return "?"
    end
    if minutes <= 0 then
        return "now"
    end
    if minutes >= 60 then
        return tostring(math.floor(minutes / 60)) .. "h" .. tostring(minutes % 60)
    end
    return tostring(minutes) .. "m"
end

local function ensure_state(state)
    if state.ready then
        return
    end
    state.ready = true
    state.loaded = false
    state.trains = {}
    state.error = nil
    state.status = nil
    state.fetched_at = nil
end

local function refresh(state, force)
    state.status = "Loading..."
    local reply, err = request(force)
    state.loaded = true
    state.status = nil
    if reply and reply.ok then
        state.trains = reply.result and reply.result.trains or {}
        state.fetched_at = reply.result and reply.result.fetched_at or nil
        state.error = nil
    else
        state.error = (reply and reply.error) or err or "ScheduleUnavailable"
    end
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)
    if not state.loaded then
        refresh(state, false)
    end

    write_line(ctx, 0, "CMR Train Times", C.yellow)
    ctx.buttons.train_refresh = api.screen.button("train_refresh", ctx.x, ctx.y + 2, 9, "Refresh", {
        fg = C.white,
        bg = C.blue,
    })

    local row = 4
    if #state.trains == 0 then
        write_line(ctx, row, state.error or state.status or "No departures found.", state.error and C.red or C.lightGray)
    else
        for _, train in ipairs(state.trains) do
            if row >= ctx.height - 2 then
                break
            end
            local eta = train.eta and train.eta ~= "" and train.eta or eta_label(train.eta_minutes)
            local head = train.time and tostring(train.time) .. "  " .. eta or "ETA " .. eta
            local dest = train.destination and train.destination ~= "" and train.destination or "Destination unknown"
            if train.direction and train.direction ~= "" and train.direction ~= "unknown" then
                dest = tostring(train.direction) .. " to " .. dest
            end
            write_line(ctx, row, head, C.cyan)
            row = row + 1
            write_line(ctx, row, dest, C.white)
            row = row + 1
            local meta = ""
            if train.train and train.train ~= "" then
                meta = meta .. tostring(train.train)
            end
            if train.platform and train.platform ~= "" then
                meta = meta .. "  Plat " .. tostring(train.platform)
            end
            if train.status and train.status ~= "" then
                meta = meta .. "  " .. tostring(train.status)
            end
            if meta ~= "" and row < ctx.height - 2 then
                write_line(ctx, row, meta, C.lightGray)
                row = row + 1
            end
            row = row + 1
        end
    end

    if state.error then
        write_line(ctx, ctx.height - 1, state.error, C.red)
    elseif state.status then
        write_line(ctx, ctx.height - 1, state.status, C.green)
    else
        write_line(ctx, ctx.height - 1, "Sorted by soonest ETA", C.lightGray)
    end
end

function app.on_touch(ctx)
    local state = ctx.state
    ensure_state(state)
    if ctx.button_id == "train_refresh" then
        refresh(state, true)
        return true
    end
    return false
end

function app.on_key(ctx)
    local state = ctx.state
    ensure_state(state)
    if not keys then
        return false
    end
    local key = ctx.event.raw and ctx.event.raw[2]
    if key == keys.r then
        refresh(state, true)
        return true
    end
    return false
end

return app
]=],
    },
}

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

local function safe_id(id)
    id = tostring(id or ""):lower():gsub("%s+", "")
    id = id:gsub("[^%w_%-%.]", "_")
    if id == "" then
        return nil, "InvalidAppId"
    end
    return id
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

local function read_all(path)
    if not fs or not fs.exists or not fs.open or not fs.exists(path) then
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
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then
        local ok, err = ensure_dir(dir)
        if not ok then
            return false, err
        end
    end
    local handle = fs.open(path, "w")
    if not handle then
        return false, "OpenFailed"
    end
    handle.write(tostring(data or ""))
    handle.close()
    return true
end

local function serialize(value)
    if textutils and textutils.serialize then
        return textutils.serialize(value)
    end
    return tostring(value or "")
end

local function unserialize(value)
    if textutils and textutils.unserialize then
        return textutils.unserialize(value)
    end
    return nil
end

local function manifest_path(app_dir)
    return combine(app_dir, "manifest")
end

local function public_item(item)
    return {
        id = item.id,
        title = item.title,
        version = item.version,
        author = item.author,
        description = item.description,
    }
end

local function default_manifest(id)
    return {
        id = id,
        title = id,
        version = "1.0.0",
        author = "Server",
        description = "Server-hosted HyperCube app.",
    }
end

local function load_manifest(id, app_dir)
    local manifest = default_manifest(id)
    local data = read_all(manifest_path(app_dir))
    local loaded = data and unserialize(data) or nil
    if type(loaded) == "table" then
        for key, value in pairs(loaded) do
            if key ~= "source" and key ~= "app_lua" and key ~= "code" then
                manifest[key] = value
            end
        end
    end
    manifest.id = id
    return manifest
end

local function save_manifest(app_dir, item)
    local manifest = {
        id = item.id,
        title = item.title,
        label = item.label,
        version = item.version,
        author = item.author,
        description = item.description,
    }
    return write_all(manifest_path(app_dir), serialize(manifest))
end

local function read_app(id)
    local safe, id_err = safe_id(id)
    if not safe then
        return nil, id_err
    end
    local app_dir = combine(APP_ROOT, safe)
    local app_path = combine(app_dir, "app.lua")
    local source, read_err = read_all(app_path)
    if not source then
        return nil, read_err
    end
    local manifest = load_manifest(safe, app_dir)
    manifest.source = source
    return manifest
end

local function ensure_seed_apps()
    local ok, err = ensure_dir(APP_ROOT)
    if not ok then
        return false, err
    end

    for _, item in ipairs(SEED_APPS) do
        local id = safe_id(item.id)
        if id then
            local app_dir = combine(APP_ROOT, id)
            local app_path = combine(app_dir, "app.lua")
            ensure_dir(app_dir)
            if not fs.exists(app_path) then
                write_all(app_path, item.source)
                save_manifest(app_dir, item)
            elseif not fs.exists(manifest_path(app_dir)) then
                save_manifest(app_dir, item)
            end
        end
    end

    return true
end

local function list_apps()
    ensure_seed_apps()
    local apps = {}
    if not fs or not fs.exists or not fs.list or not fs.exists(APP_ROOT) then
        return apps
    end

    for _, id in ipairs(fs.list(APP_ROOT)) do
        local safe = safe_id(id)
        local app_dir = safe and combine(APP_ROOT, safe) or nil
        if app_dir and fs.exists(combine(app_dir, "app.lua")) then
            apps[#apps + 1] = public_item(load_manifest(safe, app_dir))
        end
    end

    table.sort(apps, function(a, b)
        return tostring(a.title or a.id) < tostring(b.title or b.id)
    end)
    return apps
end

local function token_required()
    return fs and fs.exists and fs.exists(TOKEN_PATH)
end

local function check_publish_token(message)
    if not token_required() then
        return true
    end
    local token = read_all(TOKEN_PATH)
    token = tostring(token or ""):match("^%s*(.-)%s*$")
    return token ~= "" and tostring(message.admin_token or message.token or "") == token
end

local function publish_app(package)
    if type(package) ~= "table" then
        return false, "InvalidPackage"
    end
    local id, id_err = safe_id(package.id)
    if not id then
        return false, id_err
    end
    local source = package.source or package.app_lua or package.code
    if type(source) ~= "string" or source == "" then
        return false, "SourceRequired"
    end

    local app_dir = combine(APP_ROOT, id)
    local ok, err = ensure_dir(app_dir)
    if not ok then
        return false, err
    end

    ok, err = write_all(combine(app_dir, "app.lua"), source)
    if not ok then
        return false, err
    end

    ok, err = save_manifest(app_dir, {
        id = id,
        title = package.title or id,
        label = package.label,
        version = package.version or "1.0.0",
        author = package.author or package.username or "Server",
        description = package.description or "Server-hosted HyperCube app.",
    })
    if not ok then
        return false, err
    end

    return true, public_item(load_manifest(id, app_dir))
end

local function reply(rednet_api, sender, protocol, response_type, ok, result)
    rednet_api.send(sender, {
        type = response_type,
        ok = ok == true,
        result = ok and result or nil,
        error = ok and nil or result,
        time = now(),
    }, protocol)
end

function appstore.install(hypercube)
    if not hypercube.network then
        return false, "NetworkUnavailable"
    end
    ensure_dir(APPSTORE_ROOT)
    ensure_seed_apps()
    if hypercube.appstore_handler_registered then
        return true
    end

    hypercube.network:register_handler("appstore", function(network, sender, message)
        if type(message) ~= "table" or type(message.type) ~= "string" or message.type:sub(1, 9) ~= "appstore." then
            return false
        end

        if message.type == "appstore.list" then
            reply(rednet, sender, network.protocol, "appstore.list.result", true, {
                apps = list_apps(),
            })
        elseif message.type == "appstore.download" then
            local item = read_app(message.app_id)
            if item then
                reply(rednet, sender, network.protocol, "appstore.download.result", true, {
                    id = item.id,
                    title = item.title,
                    version = item.version,
                    author = item.author,
                    description = item.description,
                    source = item.source,
                })
            else
                reply(rednet, sender, network.protocol, "appstore.download.result", false, "AppNotFound")
            end
        elseif message.type == "appstore.publish" then
            if not check_publish_token(message) then
                reply(rednet, sender, network.protocol, "appstore.publish.result", false, "TokenRequired")
            else
                local ok, result = publish_app(message.package or message)
                reply(rednet, sender, network.protocol, "appstore.publish.result", ok, result)
            end
        else
            reply(rednet, sender, network.protocol, "appstore.error", false, "UnknownAppStoreRequest")
        end

        if hypercube.logger then
            hypercube.logger.debug("appstore " .. tostring(message.type) .. " sender=" .. tostring(sender), hypercube.root_context)
        end
        return true
    end)

    hypercube.appstore_handler_registered = true
    if hypercube.logger then
        hypercube.logger.info("App Store HyperNet API registered", hypercube.root_context)
    end
    return true
end

function appstore.start(hypercube)
    local ok, err = appstore.install(hypercube)
    if not ok then
        return false, err
    end
    while true do
        coroutine.yield("tick")
    end
end

appstore.root = APPSTORE_ROOT
appstore.app_root = APP_ROOT
appstore.list_apps = list_apps
appstore.read_app = read_app
appstore.publish = publish_app

return appstore
