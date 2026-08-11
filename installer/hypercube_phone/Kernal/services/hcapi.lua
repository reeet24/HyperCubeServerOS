local printer_driver_ok, printer_driver = pcall(require, "Kernal.drivers.printer")
local desktop_storage_ok, desktop_storage = pcall(require, "Kernal.services.desktop_storage")

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
    if normalize_path(path) == "/" then
        return false, "InvalidPath"
    end
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

function UserFS:mkdir(path)
    if normalize_path(path) == "/" then
        return true
    end
    local parent, name = self:parent(path, true)
    if not parent then
        return false, name
    end
    if parent.children[name] and parent.children[name].kind ~= "dir" then
        return false, "FileExists"
    end
    parent.children[name] = parent.children[name] or make_node("dir")
    parent.children[name].updated_at = now()
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

function UserFS:stat(path)
    local normalized = normalize_path(path or "/")
    if normalized == "/" then
        return {
            path = "/",
            name = "/",
            kind = "dir",
            size = 0,
            updated_at = self.tree.updated_at,
        }
    end
    local node, err = self:resolve(normalized, false)
    if not node then
        return nil, err
    end
    local name = normalized:match("([^/]+)$") or normalized
    return {
        path = normalized,
        name = name,
        kind = node.kind,
        size = node.kind == "file" and #(node.data or "") or 0,
        updated_at = node.updated_at,
    }
end

function UserFS:exists(path)
    return self:resolve(path, false) ~= nil
end

function UserFS:delete(path)
    if normalize_path(path) == "/" then
        return false, "CannotDeleteRoot"
    end
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

    function screen_api.line(x1, y1, x2, y2, color, fg, char)
        if not tphone.screen then
            return false, "ScreenUnavailable"
        end
        if not tphone.screen.line then
            return false, "PrimitiveUnavailable"
        end
        tphone.screen:line(x1, y1, x2, y2, char or " ", fg, color)
        return true
    end

    function screen_api.tri(x1, y1, x2, y2, x3, y3, color, fg, char)
        if not tphone.screen then
            return false, "ScreenUnavailable"
        end
        if not tphone.screen.tri then
            return false, "PrimitiveUnavailable"
        end
        tphone.screen:tri(x1, y1, x2, y2, x3, y3, color, fg, char)
        return true
    end

    function screen_api.quad(x1, y1, x2, y2, x3, y3, x4, y4, color, fg, char)
        if not tphone.screen then
            return false, "ScreenUnavailable"
        end
        if not tphone.screen.quad then
            return false, "PrimitiveUnavailable"
        end
        tphone.screen:quad(x1, y1, x2, y2, x3, y3, x4, y4, color, fg, char)
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
        escrow = {
            create = function(options)
                options = options or {}
                return request({
                    type = "bank.escrow.create",
                    seller = options.seller or options.to or options.merchant,
                    amount = options.amount,
                    escrow_id = options.escrow_id,
                    item_id = options.item_id or options.item,
                    memo = options.memo,
                    app_id = options.app_id or app_id,
                    account_name = options.account_name,
                }, "bank.escrow.create.result")
            end,
            status = function(escrow_id)
                return request({
                    type = "bank.escrow.status",
                    escrow_id = escrow_id,
                }, "bank.escrow.status.result")
            end,
            list = function()
                return request({
                    type = "bank.escrow.list",
                }, "bank.escrow.list.result")
            end,
            release = function(escrow_id, memo)
                return request({
                    type = "bank.escrow.release",
                    escrow_id = escrow_id,
                    memo = memo,
                }, "bank.escrow.release.result")
            end,
            refund = function(escrow_id, memo)
                return request({
                    type = "bank.escrow.refund",
                    escrow_id = escrow_id,
                    memo = memo,
                }, "bank.escrow.refund.result")
            end,
            cancel = function(escrow_id, memo)
                return request({
                    type = "bank.escrow.cancel",
                    escrow_id = escrow_id,
                    memo = memo,
                }, "bank.escrow.cancel.result")
            end,
        },
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

local function is_desktop_device(tphone)
    local device = tostring(tphone and tphone.device or "")
    return device == "TDesktop" or device == "TBusinessDesktop"
end

local function storage_stats(path)
    path = tostring(path or "/")
    return {
        path = path,
        free_space = fs and fs.getFreeSpace and fs.getFreeSpace(path) or nil,
        capacity = fs and fs.getCapacity and fs.getCapacity(path) or nil,
    }
end

local function connected_drive_storage()
    local out = {}
    if not peripheral or not peripheral.getNames then
        return out
    end
    for _, name in ipairs(peripheral.getNames()) do
        local ok, kind = pcall(peripheral.getType, name)
        local is_drive = ok and (kind == "drive" or (type(kind) == "table" and kind.drive))
        if is_drive then
            local mount
            if disk and disk.isPresent and disk.isPresent(name) and disk.getMountPath then
                local has_data = not disk.hasData or disk.hasData(name) ~= false
                if has_data then
                    mount = disk.getMountPath(name)
                end
            end
            local info = {
                name = name,
                present = mount ~= nil,
                mount = mount,
            }
            if mount then
                local stats = storage_stats(mount)
                info.free_space = stats.free_space
                info.capacity = stats.capacity
            end
            out[#out + 1] = info
        end
    end
    table.sort(out, function(a, b)
        return tostring(a.name) < tostring(b.name)
    end)
    return out
end

local function make_printer_api(tphone)
    local function status()
        if not is_desktop_device(tphone) then
            return false, "DesktopRequired"
        end
        if not printer_driver_ok or not printer_driver then
            return false, "PrinterDriverUnavailable"
        end
        return printer_driver.status()
    end

    local function print_text(text, options)
        if not is_desktop_device(tphone) then
            return false, "DesktopRequired"
        end
        if not printer_driver_ok or not printer_driver then
            return false, "PrinterDriverUnavailable"
        end
        return printer_driver.print(text, options)
    end

    return {
        status = status,
        print = print_text,
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

local function make_userfs_api(tphone, user_fs)
    local function desktop_required()
        if not is_desktop_device(tphone) then
            return false, "DesktopRequired"
        end
        return true
    end

    return {
        read = function(path)
            local ok, err = desktop_required()
            if not ok then return nil, err end
            return user_fs:read(path)
        end,
        write = function(path, data)
            local ok, err = desktop_required()
            if not ok then return false, err end
            return user_fs:write(path, data)
        end,
        mkdir = function(path)
            local ok, err = desktop_required()
            if not ok then return false, err end
            return user_fs:mkdir(path)
        end,
        list = function(path)
            local ok, err = desktop_required()
            if not ok then return nil, err end
            return user_fs:list(path or "/")
        end,
        stat = function(path)
            local ok, err = desktop_required()
            if not ok then return nil, err end
            return user_fs:stat(path or "/")
        end,
        exists = function(path)
            local ok = desktop_required()
            if not ok then return false end
            return user_fs:exists(path)
        end,
        delete = function(path)
            local ok, err = desktop_required()
            if not ok then return false, err end
            return user_fs:delete(path)
        end,
    }
end

local function safe_relative(path)
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("^/+", ""):gsub("^%./", ""):gsub("//+", "/")
    if path == "." then
        path = ""
    end
    if path:find("..", 1, true) then
        return nil, "InvalidPath"
    end
    path = path:gsub("[^%w%._%-%/]", "_")
    return path
end

local function combine_path(a, b)
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

local function ensure_parent(path)
    local dir = tostring(path or ""):match("^(.*)/[^/]+$")
    if dir and dir ~= "" then
        return ensure_dir(dir)
    end
    return true
end

local function make_storage_api(tphone, app_id, options)
    options = type(options) == "table" and options or {}
    local root, mounted_drive
    if desktop_storage_ok and desktop_storage and desktop_storage.data_root_for_app then
        root, mounted_drive = desktop_storage.data_root_for_app(app_id, options.app_dir)
    end
    root = root or combine_path("user/appdata", tostring(app_id or "app"):gsub("[^%w_%-%.]", "_"))

    local function full_path(path)
        local relative, err = safe_relative(path or "")
        if not relative then
            return nil, err
        end
        if relative == "" then
            return root
        end
        return combine_path(root, relative)
    end

    return {
        info = function()
            return {
                root = root,
                mounted = mounted_drive ~= nil,
                drive = mounted_drive and mounted_drive.name or nil,
                mount = mounted_drive and mounted_drive.mount or nil,
            }
        end,
        read = function(path)
            local full, err = full_path(path)
            if not full then return nil, err end
            local data = read_all(full)
            if data == nil then
                return nil, "NotFound"
            end
            return data
        end,
        write = function(path, data)
            local full, err = full_path(path)
            if not full then return false, err end
            local ok
            ok, err = ensure_parent(full)
            if not ok then return false, err end
            local handle = fs.open(full, "wb")
            if not handle then return false, "OpenFailed" end
            handle.write(tostring(data or ""))
            handle.close()
            return true
        end,
        mkdir = function(path)
            local full, err = full_path(path)
            if not full then return false, err end
            return ensure_dir(full)
        end,
        list = function(path)
            local full, err = full_path(path)
            if not full then return nil, err end
            if fs.exists(full) and fs.isDir(full) then
                return fs.list(full)
            end
            return nil, "NotFound"
        end,
        exists = function(path)
            local full = full_path(path)
            return full and fs.exists(full) == true
        end,
        delete = function(path)
            local full, err = full_path(path)
            if not full then return false, err end
            if full == root then
                return false, "CannotDeleteRoot"
            end
            if fs.exists(full) then
                fs.delete(full)
                return true
            end
            return false, "NotFound"
        end,
    }
end

local function make_desktop_api(tphone, app_id)
    local function request(action, payload)
        if not is_desktop_device(tphone) then
            return false, "DesktopRequired"
        end
        payload = payload or {}
        payload.type = "window"
        payload.action = action
        payload.app_id = app_id
        tphone.shell_request = payload
        return true
    end

    return {
        open_file = function(path)
            if not is_desktop_device(tphone) then
                return false, "DesktopRequired"
            end
            tphone.shell_request = {
                type = "open_file",
                path = tostring(path or ""),
            }
            return true
        end,
        open_app = function(id)
            if not is_desktop_device(tphone) then
                return false, "DesktopRequired"
            end
            tphone.shell_request = {
                type = "open_app",
                app_id = tostring(id or ""),
            }
            return true
        end,
        minimize = function()
            return request("minimize")
        end,
        fullscreen = function()
            return request("fullscreen")
        end,
        restore = function()
            return request("restore")
        end,
        close = function()
            return request("close")
        end,
        set_title = function(title)
            return request("set_title", { title = tostring(title or "") })
        end,
        open_popup = function(kind, options)
            options = type(options) == "table" and options or {}
            return request("open_popup", {
                kind = tostring(kind or "popup"),
                title = tostring(options.title or ""),
                width = tonumber(options.width),
                height = tonumber(options.height),
                x = tonumber(options.x),
                y = tonumber(options.y),
                data = type(options.data) == "table" and options.data or {},
            })
        end,
        open_terminal = function(options)
            options = type(options) == "table" and options or {}
            if tphone.dev_mode ~= true then
                return false, "DevModeRequired"
            end
            return request("open_popup", {
                kind = "terminal",
                title = tostring(options.title or "Terminal"),
                width = tonumber(options.width) or 42,
                height = tonumber(options.height) or 12,
                data = {
                    command = tostring(options.command or ""),
                    cwd = tostring(options.cwd or "/"),
                },
            })
        end,
        drives = function()
            if not is_desktop_device(tphone) then
                return nil, "DesktopRequired"
            end
            if not desktop_storage_ok or not desktop_storage then
                return nil, "DesktopStorageUnavailable"
            end
            return desktop_storage.list_drives()
        end,
        mounts = function()
            if not is_desktop_device(tphone) then
                return nil, "DesktopRequired"
            end
            if not desktop_storage_ok or not desktop_storage then
                return nil, "DesktopStorageUnavailable"
            end
            return desktop_storage.mounted()
        end,
        format_drive = function(name, label)
            if not is_desktop_device(tphone) then
                return false, "DesktopRequired"
            end
            if not desktop_storage_ok or not desktop_storage then
                return false, "DesktopStorageUnavailable"
            end
            return desktop_storage.format_drive(name, label)
        end,
        install_root = function()
            if not is_desktop_device(tphone) then
                return nil, "DesktopRequired"
            end
            if not desktop_storage_ok or not desktop_storage then
                return nil, "DesktopStorageUnavailable"
            end
            local root, drive = desktop_storage.default_app_root(tphone)
            return {
                root = root,
                mounted = drive ~= nil,
                drive = drive and drive.name or nil,
                mount = drive and drive.mount or nil,
            }
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

    local function sandbox_env(app_id, output, root)
        local api_ref = hcapi.create(tphone, app_id or "terminal")
        local module_cache = {}
        root = normalize_path(root or "/")
        local env
        local function app_require(name)
            name = tostring(name or ""):gsub("%.", "/")
            local path = normalize_path(root .. "/" .. name .. ".lua")
            if module_cache[path] ~= nil then
                return module_cache[path]
            end
            local source, read_err = tphone.hcfs:read(path)
            if not source then
                error(read_err or ("ModuleNotFound:" .. tostring(name)), 2)
            end
            local loader, load_err = load(source, "@" .. path, "t", env)
            if not loader then
                error(load_err or "ModuleLoadFailed", 2)
            end
            module_cache[path] = true
            local ok, result = pcall(loader)
            if not ok then
                module_cache[path] = nil
                error(result, 2)
            end
            if result ~= nil then
                module_cache[path] = result
            end
            return module_cache[path]
        end
        env = {
            _G = nil,
            HCAPI = api_ref,
            api = api_ref,
            require = app_require,
            assert = assert,
            error = error,
            ipairs = ipairs,
            next = next,
            pairs = pairs,
            pcall = pcall,
            select = select,
            tonumber = tonumber,
            tostring = tostring,
            type = type,
            unpack = unpack or table.unpack,
            math = math,
            string = string,
            table = table,
            coroutine = {
                create = coroutine.create,
                resume = coroutine.resume,
                running = coroutine.running,
                status = coroutine.status,
                wrap = coroutine.wrap,
                yield = coroutine.yield,
            },
            os = {
                clock = os.clock,
                time = os.time,
                date = os.date,
                epoch = os.epoch,
            },
            colors = colors,
            colours = colours,
            keys = keys,
            textutils = textutils,
            print = function(...)
                local parts = {}
                for i = 1, select("#", ...) do
                    parts[#parts + 1] = tostring(select(i, ...))
                end
                output[#output + 1] = table.concat(parts, " ")
            end,
        }
        env._G = env
        return env
    end

    local function sandbox_run(source, options)
        if not enabled() then
            return false, "DevModeRequired"
        end
        source = tostring(source or "")
        options = type(options) == "table" and options or {}
        local output = {}
        local env = sandbox_env(options.app_id or "terminal", output, options.root)
        local name = tostring(options.name or "terminal")
        local loader, err = load("return " .. source, name, "t", env)
        if not loader then
            loader, err = load(source, name, "t", env)
        end
        if not loader then
            return false, err
        end
        local ok, result = pcall(loader)
        if not ok then
            return false, result
        end
        if result ~= nil then
            if type(result) == "table" and textutils and textutils.serialize then
                result = textutils.serialize(result)
            end
            output[#output + 1] = tostring(result)
        end
        return true, table.concat(output, "\n")
    end

    local function run_user_file(path, options)
        if not tphone.hcfs then
            tphone.hcfs = UserFS.new(tphone.identity or {})
        end
        local source, err = tphone.hcfs:read(path)
        if not source then
            return false, err
        end
        options = type(options) == "table" and options or {}
        options.name = "@" .. tostring(path or "")
        options.root = tostring(path or ""):match("^(.*)/[^/]+$") or "/"
        return sandbox_run(source, options)
    end

    local function lint(source)
        if not enabled() then
            return false, "DevModeRequired"
        end
        source = tostring(source or "")
        local diagnostics = {}
        local loader, err = load(source, "lint", "t", {})
        if not loader then
            diagnostics[#diagnostics + 1] = {
                severity = "error",
                message = tostring(err or "SyntaxError"),
            }
        end
        if source:find("os%.shutdown", 1, false) or source:find("fs%.delete", 1, false) then
            diagnostics[#diagnostics + 1] = {
                severity = "warning",
                message = "Direct OS/filesystem calls are not available in user-app sandbox; use HCAPI.",
            }
        end
        if not source:find("return%s+app") and not source:find("return%s+{") then
            diagnostics[#diagnostics + 1] = {
                severity = "hint",
                message = "User apps should return an app table.",
            }
        end
        return true, diagnostics
    end

    local function completions(prefix)
        prefix = tostring(prefix or "")
        local words = {
            "HCAPI.screen.write", "HCAPI.screen.button", "HCAPI.screen.rect", "HCAPI.screen.line", "HCAPI.screen.tri",
            "HCAPI.screen.quad", "HCAPI.screen.wrap",
            "HCAPI.fs.read", "HCAPI.fs.write", "HCAPI.fs.list", "HCAPI.storage.read", "HCAPI.storage.write",
            "HCAPI.storage.info", "HCAPI.userfs.read", "HCAPI.userfs.write",
            "HCAPI.desktop.open_popup", "HCAPI.desktop.open_terminal", "HCAPI.desktop.open_file", "HCAPI.desktop.drives",
            "HCAPI.device.storage", "HCAPI.bank.purchase", "HCAPI.phone.send", "app.render", "app.on_key", "app.on_touch", "app.on_tick",
        }
        local out = {}
        for _, word in ipairs(words) do
            if prefix == "" or word:sub(1, #prefix) == prefix then
                out[#out + 1] = word
            end
        end
        return out
    end

    local function http_get(url, accept)
        if not enabled() then
            return nil, "DevModeRequired"
        end
        if not http or not http.get then
            return nil, "HttpUnavailable"
        end
        local headers = {
            ["User-Agent"] = "HyperCubePhone-DevInstaller",
            ["Accept"] = accept or "*/*",
        }
        local ok, response_or_err, request_err = pcall(http.get, tostring(url or ""), headers)
        if not ok then
            return nil, response_or_err
        end
        local response = response_or_err
        if not response and tostring(request_err or ""):lower():match("header") then
            ok, response_or_err, request_err = pcall(http.get, tostring(url or ""))
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
            return nil, "Http" .. tostring(code)
        end
        return body
    end

    local function decode_table(text)
        if not enabled() then
            return nil, "DevModeRequired"
        end
        if not textutils or not textutils.unserialize then
            return nil, "TextutilsUnavailable"
        end
        local ok, result = pcall(textutils.unserialize, tostring(text or ""))
        if ok and type(result) == "table" then
            return result
        end
        return nil, "TableDecodeFailed"
    end

    local function decode_json(text)
        if not enabled() then
            return nil, "DevModeRequired"
        end
        if not textutils or not textutils.unserializeJSON then
            return nil, "JsonUnavailable"
        end
        local ok, result = pcall(textutils.unserializeJSON, tostring(text or ""))
        if ok and type(result) == "table" then
            return result
        end
        return nil, "JsonDecodeFailed"
    end

    return {
        is_enabled = enabled,
        enable = enable,
        eval = eval,
        sandbox_run = sandbox_run,
        run_user_file = run_user_file,
        lint = lint,
        completions = completions,
        http_get = http_get,
        decode_table = decode_table,
        decode_json = decode_json,
    }
end

local function make_device_api(tphone)
    return {
        os = tphone and tphone.name or nil,
        type = tphone and tphone.device or nil,
        desktop = is_desktop_device(tphone),
        storage = function()
            local internal = storage_stats("/")
            internal.name = "Device"
            local drives
            if is_desktop_device(tphone) and desktop_storage_ok and desktop_storage and desktop_storage.list_drives then
                drives = desktop_storage.list_drives()
            else
                drives = connected_drive_storage()
            end
            return {
                internal = internal,
                drives = drives,
            }
        end,
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

function hcapi.create(tphone, app_id, options)
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
        printer = make_printer_api(tphone),
        fs = make_fs_api(tphone.hcfs, app_id),
        userfs = make_userfs_api(tphone, tphone.hcfs),
        storage = make_storage_api(tphone, app_id, options),
        desktop = make_desktop_api(tphone, app_id),
        dev = make_dev_api(tphone),
        device = make_device_api(tphone),
        apps = {
            refresh = function()
                tphone.apps_dirty = true
                return true
            end,
            install = function(package)
                if not tphone.install_app then
                    return false, "InstallUnavailable"
                end
                return tphone:install_app(package)
            end,
            install_dev = function(package)
                if not tphone.install_dev_app then
                    return false, "InstallUnavailable"
                end
                if not tphone.dev_mode then
                    return false, "DevModeRequired"
                end
                return tphone:install_dev_app(package)
            end,
        },
        colors = C,
        time = now,
    }
end

hcapi.UserFS = UserFS

return hcapi
