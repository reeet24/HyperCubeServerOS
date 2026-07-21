local hcapi = {}

local C = {
    black = colors and colors.black or 32768,
    white = colors and colors.white or 1,
    gray = colors and colors.gray or 128,
    lightGray = colors and colors.lightGray or 256,
    blue = colors and colors.blue or 2048,
    cyan = colors and colors.cyan or 8192,
    green = colors and colors.green or 32,
    red = colors and colors.red or 16384,
    yellow = colors and colors.yellow or 16,
    purple = colors and colors.purple or 1024,
    orange = colors and colors.orange or 2,
}

local STORAGE_FILE = "user/hcfs.raw"

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
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
        return nil
    end
    local handle = fs.open(path, "rb")
    if not handle then
        return nil
    end
    local data = handle.readAll()
    handle.close()
    return data
end

local function write_all(path, data)
    ensure_dir("user")
    local handle = fs.open(path, "wb")
    if not handle then
        return false, "OpenFailed"
    end
    handle.write(data)
    handle.close()
    return true
end

local function ensure_user_dir()
    if fs and fs.exists and fs.makeDir and not fs.exists("user") then
        fs.makeDir("user")
    end
end

local function serialize(value)
    return textutils.serialize(value)
end

local function unserialize(value)
    return textutils.unserialize(value)
end

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

local function storage_key(identity)
    identity = identity or {}
    identity.account = identity.account or {}
    identity.account.hcfs_key = identity.account.hcfs_key or identity.hcfs_key
    if not identity.account.hcfs_key then
        identity.account.hcfs_key = checksum(tostring(identity.tesserac_id) .. ":" .. tostring(identity.session_token) .. ":" .. tostring(now()))
        identity.hcfs_key = identity.account.hcfs_key
    end
    return tostring(identity.account.hcfs_key)
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

local function normalize_path(path)
    path = tostring(path or "/")
    path = path:gsub("\\", "/")
    path = path:gsub("[^%w%._%-%/]", "")
    path = path:gsub("//+", "/")
    if path == "" then
        path = "/"
    end
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    return path
end

local function app_path(app_id, path)
    app_id = tostring(app_id or "app"):gsub("[^%w_%-%.]", "_")
    path = normalize_path(path)
    return "/apps/" .. app_id .. path
end

local function make_node(kind)
    return {
        kind = kind,
        children = kind == "dir" and {} or nil,
        data = kind == "file" and "" or nil,
        updated_at = now(),
    }
end

local UserFS = {}
UserFS.__index = UserFS

function UserFS.new(identity)
    local self = setmetatable({}, UserFS)
    self.identity = identity or {}
    self.key = storage_key(self.identity)
    self.tree = make_node("dir")
    self:load()
    return self
end

function UserFS:load()
    local raw = read_all(STORAGE_FILE)
    if not raw or raw == "" then
        return true
    end

    local decoded, err = xor_crypt(raw, self.key)
    if not decoded then
        return false, err
    end

    local ok, value = pcall(unserialize, decoded)
    if ok and type(value) == "table" and value.kind == "dir" then
        self.tree = value
        return true
    end

    return false, "CorruptUserFS"
end

function UserFS:flush()
    local encrypted, err = xor_crypt(serialize(self.tree), self.key)
    if not encrypted then
        return false, err
    end
    return write_all(STORAGE_FILE, encrypted)
end

function UserFS:parts(path)
    local parts = {}
    for part in normalize_path(path):gmatch("[^/]+") do
        parts[#parts + 1] = part
    end
    return parts
end

function UserFS:resolve(path, create_dirs)
    local parts = self:parts(path)
    local node = self.tree
    for i = 1, #parts do
        local part = parts[i]
        if node.kind ~= "dir" then
            return nil, "NotDirectory"
        end
        if not node.children[part] then
            if create_dirs then
                node.children[part] = make_node(i == #parts and "file" or "dir")
            else
                return nil, "NotFound"
            end
        end
        node = node.children[part]
    end
    return node
end

function UserFS:parent(path, create_dirs)
    local parts = self:parts(path)
    local name = parts[#parts]
    parts[#parts] = nil
    local node = self.tree
    for _, part in ipairs(parts) do
        if not node.children[part] then
            if not create_dirs then
                return nil, "NotFound"
            end
            node.children[part] = make_node("dir")
        end
        node = node.children[part]
        if node.kind ~= "dir" then
            return nil, "NotDirectory"
        end
    end
    return node, name
end

function UserFS:read(path)
    local node, err = self:resolve(path, false)
    if not node then
        return nil, err
    end
    if node.kind ~= "file" then
        return nil, "IsDirectory"
    end
    return node.data or ""
end

function UserFS:write(path, data)
    local parent, name = self:parent(path, true)
    if not parent then
        return false, name
    end
    parent.children[name] = {
        kind = "file",
        data = tostring(data or ""),
        updated_at = now(),
    }
    return self:flush()
end

function UserFS:list(path)
    local node, err = self:resolve(path or "/", false)
    if not node then
        return nil, err
    end
    if node.kind ~= "dir" then
        return nil, "NotDirectory"
    end
    local out = {}
    for name in pairs(node.children) do
        out[#out + 1] = name
    end
    table.sort(out)
    return out
end

function UserFS:exists(path)
    return self:resolve(path, false) ~= nil
end

function UserFS:delete(path)
    local parent, name = self:parent(path, false)
    if not parent then
        return false, name
    end
    parent.children[name] = nil
    return self:flush()
end

local function make_screen_api(tphone)
    local screen_api = {}

    local function clamp_width(width)
        return math.max(1, math.floor(tonumber(width) or 1))
    end

    local function pad_to_width(text, width)
        text = tostring(text or "")
        if #text >= width then
            return text:sub(1, width)
        end
        return text .. string.rep(" ", width - #text)
    end

    local function wrap_text(text, width)
        width = clamp_width(width)
        text = tostring(text or "")
        local lines = {}

        local function push_long_word(word)
            while #word > width do
                lines[#lines + 1] = word:sub(1, width)
                word = word:sub(width + 1)
            end
            return word
        end

        for raw_line in (text .. "\n"):gmatch("(.-)\n") do
            local line = ""
            for word in raw_line:gmatch("%S+") do
                word = push_long_word(word)
                if word ~= "" then
                    if line == "" then
                        line = word
                    elseif #line + 1 + #word <= width then
                        line = line .. " " .. word
                    else
                        lines[#lines + 1] = line
                        line = word
                    end
                end
            end
            if line ~= "" then
                lines[#lines + 1] = line
            elseif raw_line == "" then
                lines[#lines + 1] = ""
            end
        end

        if #lines > 0 and lines[#lines] == "" and text:sub(-1) ~= "\n" then
            lines[#lines] = nil
        end
        return lines
    end

    function screen_api.size()
        if not tphone.screen then
            return 0, 0
        end
        return tphone.screen:get_size()
    end

    function screen_api.write(x, y, text, fg, bg)
        if not tphone.screen then
            return false, "ScreenUnavailable"
        end
        tphone.screen:write(x, y, text, fg, bg)
        return true
    end

    function screen_api.write_scroll(x, y, width, text, offset, fg, bg)
        width = clamp_width(width)
        offset = math.max(0, math.floor(tonumber(offset) or 0))
        text = tostring(text or "")
        local view = text:sub(offset + 1, offset + width)
        return screen_api.write(x, y, pad_to_width(view, width), fg, bg)
    end

    function screen_api.write_wrap(x, y, text, width, height, fg, bg, offset)
        width = clamp_width(width)
        height = math.max(1, math.floor(tonumber(height) or 1))
        offset = math.max(0, math.floor(tonumber(offset) or 0))
        local lines = wrap_text(text, width)
        for row = 1, height do
            screen_api.write(x, y + row - 1, pad_to_width(lines[offset + row] or "", width), fg, bg)
        end
        return true, lines
    end

    function screen_api.wrap(text, width)
        return wrap_text(text, width)
    end

    function screen_api.rect(x, y, width, height, bg)
        if not tphone.screen then
            return false, "ScreenUnavailable"
        end
        tphone.screen:rect(x, y, width, height, bg)
        return true
    end

    function screen_api.button(id, x, y, width, label, options)
        if not tphone.screen then
            return nil, "ScreenUnavailable"
        end
        return tphone.screen:button(id, x, y, width, label, options)
    end

    function screen_api.manager(default_screen)
        local manager = {
            active = default_screen,
            screens = {},
            order = {},
            history = {},
            params = {},
        }

        function manager:define(id, definition)
            id = tostring(id or "")
            if id == "" or type(definition) ~= "table" then
                return self
            end
            if not self.screens[id] then
                self.order[#self.order + 1] = id
            end
            definition.id = id
            definition.state = definition.state or {}
            self.screens[id] = definition
            if not self.active then
                self.active = id
            end
            return self
        end

        function manager:current()
            return self.screens[self.active], self.active
        end

        function manager:set(id, params)
            id = tostring(id or "")
            if not self.screens[id] then
                return false, "ScreenNotFound"
            end
            local previous = self.screens[self.active]
            if previous and previous.on_leave then
                previous.on_leave(previous.state, self)
            end
            if self.active and self.active ~= id then
                self.history[#self.history + 1] = self.active
            end
            self.active = id
            self.params = params or {}
            local current = self.screens[id]
            if current and current.on_enter then
                current.on_enter(current.state, self.params, self)
            end
            return true
        end

        function manager:back(fallback)
            local previous = table.remove(self.history)
            return self:set(previous or fallback or self.order[1])
        end

        function manager:render(ctx)
            local screen = self.screens[self.active]
            if not screen or not screen.render then
                return false, "ScreenRendererMissing"
            end
            ctx.screen_manager = self
            return screen.render(ctx, screen.state, self)
        end

        function manager:touch(ctx)
            local screen = self.screens[self.active]
            if screen and screen.on_touch then
                ctx.screen_manager = self
                return screen.on_touch(ctx, screen.state, self) == true
            end
            return false
        end

        function manager:key(ctx)
            local screen = self.screens[self.active]
            if screen and screen.on_key then
                ctx.screen_manager = self
                return screen.on_key(ctx, screen.state, self) == true
            end
            return false
        end

        return manager
    end

    screen_api.colors = C
    return screen_api
end

local function make_net_api(tphone)
    local function attach_identity(message)
        if type(message) == "table" and tphone.identity then
            message.tesserac_id = message.tesserac_id or tphone.identity.tesserac_id
            message.username = message.username or tphone.identity.username
            message.session_token = message.session_token or tphone.identity.session_token
        end
        return message
    end

    return {
        request = function(message, expected_type, timeout)
            if not tphone.network then
                return nil, "NetworkUnavailable"
            end
            if type(message) ~= "table" then
                return nil, "InvalidMessage"
            end
            message.hypernet = true
            return tphone.network:request(attach_identity(message), expected_type, timeout)
        end,
        send = function(message)
            if not tphone.network then
                return false, "NetworkUnavailable"
            end
            if type(message) ~= "table" then
                return false, "InvalidMessage"
            end
            message.hypernet = true
            return tphone.network:send(attach_identity(message))
        end,
        summary = function()
            return tphone.network and tphone.network:summary() or {
                status = "offline",
            }
        end,
    }
end

local function make_bank_api(tphone, app_id)
    local net = make_net_api(tphone)
    local function request(message, expected, timeout)
        local reply, err = net.request(message, expected, timeout or 8)
        if reply and reply.ok then
            return true, reply.result
        end
        return false, (reply and reply.error) or err or "BankRequestFailed"
    end

    return {
        open = function(account_name, minecraft_name)
            return request({
                type = "bank.open",
                account_name = account_name,
                minecraft_name = minecraft_name,
            }, "bank.open.result")
        end,
        status = function(account_name)
            return request({
                type = "bank.status",
                account_name = account_name,
            }, "bank.status.result")
        end,
        history = function(account_name)
            return request({
                type = "bank.history",
                account_name = account_name,
            }, "bank.history.result")
        end,
        transfer = function(to, amount, memo, account_name)
            return request({
                type = "bank.transfer",
                to = to,
                amount = amount,
                memo = memo,
                account_name = account_name,
            }, "bank.transfer.result")
        end,
        purchase = function(options)
            options = options or {}
            return request({
                type = "bank.purchase",
                to = options.to or options.merchant or options.seller,
                amount = options.amount,
                item_id = options.item_id or options.item,
                purchase_id = options.purchase_id,
                memo = options.memo,
                app_id = options.app_id or app_id,
                account_name = options.account_name,
            }, "bank.purchase.result")
        end,
    }
end

local function make_phone_api(tphone)
    local net = make_net_api(tphone)
    local function request(message, expected, timeout)
        local reply, err = net.request(message, expected, timeout or 6)
        if reply and reply.ok then
            return true, reply.result
        end
        return false, (reply and reply.error) or err or "PhoneRequestFailed"
    end

    return {
        status = function()
            return request({ type = "phone.status" }, "phone.status.result")
        end,
        subscribe = function()
            return request({ type = "phone.subscribe" }, "phone.subscribe.result")
        end,
        pay = function(purchase_id)
            return request({ type = "phone.pay", purchase_id = purchase_id }, "phone.pay.result")
        end,
        send = function(to, body)
            return request({ type = "phone.send", to = to, body = body }, "phone.send.result")
        end,
        sync = function()
            return request({ type = "phone.sync" }, "phone.sync.result")
        end,
        chats = function()
            return request({ type = "phone.chats" }, "phone.chats.result")
        end,
        chat = function(number, mark_read)
            return request({ type = "phone.chat", number = number, mark_read = mark_read }, "phone.chat.result")
        end,
        delete_chat = function(number)
            return request({ type = "phone.chat.delete", number = number }, "phone.chat.delete.result")
        end,
        report_message = function(chat_number, message, reason)
            return request({
                type = "moderation.report",
                chat_number = chat_number,
                message = message,
                reason = reason or "harmful_message",
            }, "moderation.report.result", 6)
        end,
    }
end

local function make_fs_api(user_fs, app_id)
    return {
        read = function(path)
            return user_fs:read(app_path(app_id, path))
        end,
        write = function(path, data)
            return user_fs:write(app_path(app_id, path), data)
        end,
        list = function(path)
            return user_fs:list(app_path(app_id, path or "/"))
        end,
        exists = function(path)
            return user_fs:exists(app_path(app_id, path))
        end,
        delete = function(path)
            return user_fs:delete(app_path(app_id, path))
        end,
    }
end

local function make_dev_api(tphone)
    local function enabled()
        return tphone.dev_mode == true
    end

    local function enable()
        ensure_user_dir()
        local handle = fs and fs.open and fs.open("user/dev_mode", "w") or nil
        if not handle then
            return false, "OpenFailed"
        end
        handle.write("enabled")
        handle.close()
        tphone.dev_mode = true
        tphone.apps_dirty = true
        return true
    end

    local function eval(source)
        if not enabled() then
            return false, "DevModeRequired"
        end
        source = tostring(source or "")
        local api_ref = hcapi.create(tphone, "terminal")
        local env = setmetatable({
            HCAPI = api_ref,
            api = api_ref,
        }, { __index = _G })
        local loader, err = load("return " .. source, "terminal", "t", env)
        if not loader then
            loader, err = load(source, "terminal", "t", env)
        end
        if not loader then
            return false, err
        end
        local ok, result = pcall(loader)
        if not ok then
            return false, result
        end
        if type(result) == "table" and textutils and textutils.serialize then
            result = textutils.serialize(result)
        end
        if result == nil then
            result = "ok"
        end
        return true, tostring(result)
    end

    return {
        is_enabled = enabled,
        enable = enable,
        eval = eval,
    }
end

local function make_device_api(tphone)
    return {
        shutdown = function()
            if tphone and tphone.shutdown then
                tphone.shutdown("settings")
            end
            if os.shutdown then
                os.shutdown()
            end
            return false, "ShutdownUnavailable"
        end,
    }
end

function hcapi.create(tphone, app_id)
    if not tphone.hcfs then
        tphone.hcfs = UserFS.new(tphone.identity or {})
    end

    return {
        app_id = app_id,
        identity = {
            tesserac_id = tphone.identity and tphone.identity.tesserac_id or nil,
            username = tphone.identity and tphone.identity.username or nil,
            display_name = tphone.identity and tphone.identity.display_name or nil,
        },
        screen = make_screen_api(tphone),
        hypernet = make_net_api(tphone),
        bank = make_bank_api(tphone, app_id),
        phone = make_phone_api(tphone),
        fs = make_fs_api(tphone.hcfs, app_id),
        dev = make_dev_api(tphone),
        device = make_device_api(tphone),
        apps = {
            install = function(package)
                if not tphone.install_app then
                    return false, "InstallUnavailable"
                end
                return tphone:install_app(package)
            end,
        },
        colors = C,
        time = now,
    }
end

hcapi.UserFS = UserFS

return hcapi
