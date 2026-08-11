local tesseracid = {}

local IDENTITY_PATH = "user/tesseracid"
local RECOVERY_INDEX_KEY = "auth:recovery:index"
local RECOVERY_PREFIX = "auth:recovery:"
local OFFICIAL_TESSERAC_USERNAME = "tesserac"

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function ensure_user_dir()
    if fs and fs.exists and not fs.exists("user") then
        fs.makeDir("user")
    end
end

local function read_file(path)
    if not fs or not fs.exists or not fs.open or not fs.exists(path) then
        return nil
    end
    local handle = fs.open(path, "r")
    if not handle then
        return nil
    end
    local data = handle.readAll()
    handle.close()
    return data
end

local function write_file(path, data)
    ensure_user_dir()
    local handle = fs.open(path, "w")
    if not handle then
        return false, "OpenFailed"
    end
    handle.write(data)
    handle.close()
    return true
end

local function serialize(value)
    return textutils.serialize(value)
end

local function unserialize(value)
    return textutils.unserialize(value)
end

local function normalize_username(username)
    username = tostring(username or ""):lower():gsub("%s+", "")
    username = username:gsub("[^%w_%.-]", "")
    if username == "" then
        return nil, "InvalidUsername"
    end
    return username
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

local function make_token(username, password_hash)
    return checksum(username .. ":" .. password_hash .. ":" .. tostring(now()) .. ":" .. tostring(os.getComputerID and os.getComputerID() or 0))
end

local function make_hcfs_key(username, password_hash)
    return checksum("hcfs:" .. tostring(username) .. ":" .. tostring(password_hash) .. ":" .. tostring(now()))
end

local DEFAULT_SCOPES = {
    phone = {
        "account.identity",
        "app.install",
        "bank.access",
        "db.user",
        "phone.access",
        "web.publish",
    },
    webserver = {
        "account.identity",
        "db.user",
        "web.origin",
    },
    bank_branch = {
        "account.identity",
        "bank.deposit",
    },
    atm = {
        "account.identity",
        "bank.deposit",
    },
    user_server = {
        "account.identity",
        "bank.access",
        "db.user",
        "web.origin",
        "web.publish",
    },
    business_phone = {
        "account.identity",
        "app.install",
        "bank.access",
        "db.user",
        "phone.access",
        "web.publish",
    },
}

local function account_tid_key(tesserac_id)
    return "account:tid:" .. tostring(tesserac_id or "")
end

local function device_key(device_id)
    return "device:" .. tostring(device_id or "")
end

local function copy_list(list)
    local out = {}
    for i, value in ipairs(list or {}) do
        out[i] = value
    end
    return out
end

local function list_contains(list, value)
    for _, item in ipairs(list or {}) do
        if item == value then
            return true
        end
    end
    return false
end

local function normalize_scope(scope)
    scope = tostring(scope or ""):lower():gsub("%s+", "")
    scope = scope:gsub("[^%w%.:%-]", "")
    if scope == "" then
        return nil
    end
    return scope
end

local function normalize_scopes(device)
    local role = tostring(device and device.role or "device"):lower()
    local defaults = DEFAULT_SCOPES[role] or { "account.identity", "db.user" }
    local scopes = {}
    local requested = device and (device.scopes or device.scope) or {}
    if type(requested) == "string" then
        requested = { requested }
    end
    if type(requested) ~= "table" or #requested == 0 then
        return copy_list(defaults)
    end
    for _, scope in ipairs(type(requested) == "table" and requested or {}) do
        scope = normalize_scope(scope)
        if scope and list_contains(defaults, scope) and not list_contains(scopes, scope) then
            scopes[#scopes + 1] = scope
        end
    end
    if #scopes == 0 then
        return copy_list(defaults)
    end
    return scopes
end

local function normalize_device(account, device, token)
    device = device or {}
    local role = tostring(device.role or "device"):lower():gsub("[^%w_%-]", "")
    if role == "" then
        role = "device"
    end
    local computer_id = device.computer_id or (os.getComputerID and os.getComputerID() or nil)
    local id = tostring(device.device_id or device.id or "")
    if id == "" then
        id = "dev_" .. checksum(tostring(account.tesserac_id) .. ":" .. role .. ":" .. tostring(computer_id or "") .. ":" .. tostring(device.label or ""))
    end
    id = id:gsub("[^%w_%-%.]", "_")
    return {
        device_id = id,
        owner = account.tesserac_id,
        username = account.username,
        role = role,
        os = device.os or "HyperCube",
        label = device.label,
        computer_id = computer_id,
        scopes = normalize_scopes(device),
        status = device.status or "active",
        session_token = token,
        registered_at = device.registered_at or now(),
        last_seen = now(),
    }
end

local function normalize_account_type(account_type)
    account_type = tostring(account_type or "personal"):lower():gsub("%s+", "")
    account_type = account_type:gsub("[^%w_%-]", "")
    if account_type == "business" then
        return "business"
    end
    return "personal"
end

local function public_device(device)
    if not device then
        return nil
    end
    return {
        device_id = device.device_id,
        owner = device.owner,
        username = device.username,
        role = device.role,
        os = device.os,
        label = device.label,
        computer_id = device.computer_id,
        scopes = copy_list(device.scopes),
        status = device.status,
        registered_at = device.registered_at,
        last_seen = device.last_seen,
    }
end

local function public_devices(devices)
    local out = {}
    for _, device in pairs(devices or {}) do
        out[#out + 1] = public_device(device)
    end
    table.sort(out, function(a, b)
        return tostring(a.last_seen or 0) > tostring(b.last_seen or 0)
    end)
    return out
end

function tesseracid.password_hash(username, password, salt)
    salt = salt or username
    return checksum(tostring(username) .. ":" .. tostring(salt) .. ":" .. tostring(password))
end

function tesseracid.load_local()
    local data = read_file(IDENTITY_PATH)
    if not data then
        return nil
    end
    local ok, identity = pcall(unserialize, data)
    if ok and type(identity) == "table" and identity.tesserac_id then
        return identity
    end
    return nil
end

function tesseracid.save_local(identity)
    return write_file(IDENTITY_PATH, serialize(identity))
end

function tesseracid.clear_local()
    if fs and fs.exists and fs.delete and fs.exists(IDENTITY_PATH) then
        fs.delete(IDENTITY_PATH)
    end
    return true
end

local function prompt(label, hidden)
    write(label)
    if hidden and read then
        return read("*")
    end
    return read()
end

local function request(network, message, expected)
    if not network then
        return nil, "NetworkUnavailable"
    end
    return network:request(message, expected, 5)
end

local function install_info()
    local raw = read_file("hypercube_install")
    if not raw then
        return {
            os = "HyperCube",
            device = "TPhone",
        }
    end
    local ok, info = pcall(unserialize, raw)
    if ok and type(info) == "table" then
        return {
            os = tostring(info.os or "HyperCube"),
            device = tostring(info.device or "TPhone"),
        }
    end
    return {
        os = "HyperCube",
        device = "TPhone",
    }
end

function tesseracid.ensure_device_identity(network, logger, options)
    options = options or {}
    local existing = tesseracid.load_local()
    if existing then
        return existing
    end

    print("")
    print(options.title or "TesseracID required")
    print("1. Sign in")
    print("2. Sign up")
    print("3. Recover account")

    local choice = prompt("Select: ")
    local username = prompt("TesseracID: ")
    local normalized, err = normalize_username(username)
    if not normalized then
        return nil, err
    end

    if choice == "3" then
        if normalized:match("^tid_") then
            local resolved = request(network, {
                type = "auth.resolve",
                username = normalized,
            }, "auth.resolve.result")
            if resolved and resolved.ok and resolved.username then
                normalized = resolved.username
            else
                return nil, (resolved and resolved.error) or "AccountNotFound"
            end
        end
        local new_password = prompt("New password: ", true)
        local confirm = prompt("Confirm password: ", true)
        if new_password ~= confirm then
            return nil, "PasswordMismatch"
        end
        local recovery_hash = tesseracid.password_hash(normalized, new_password, normalized)
        local local_install = install_info()
        local reply, request_err = request(network, {
            type = "auth.recovery.request",
            username = normalized,
            requested_password_hash = recovery_hash,
            reason = "Device account recovery",
            device = {
                os = options.os or local_install.os or "HyperCube",
                role = options.role or "phone",
                device = options.device or local_install.device,
                label = os.getComputerLabel and os.getComputerLabel() or nil,
                computer_id = os.getComputerID and os.getComputerID() or nil,
            },
        }, "auth.recovery.request.result")
        if reply and reply.ok then
            print("Recovery request sent.")
            print("Request: " .. tostring(reply.request_id))
            print("Sign in with the new password after Tesserac approves it.")
            return nil, "RecoveryRequestSubmitted"
        end
        return nil, (reply and reply.error) or request_err or "RecoveryRequestFailed"
    end

    if choice ~= "2" and normalized:match("^tid_") then
        local resolved = request(network, {
            type = "auth.resolve",
            username = normalized,
        }, "auth.resolve.result")
        if resolved and resolved.ok and resolved.username then
            normalized = resolved.username
        else
            return nil, (resolved and resolved.error) or "AccountNotFound"
        end
    end

    local password = prompt("Password: ", true)
    local password_hash = tesseracid.password_hash(normalized, password, normalized)
    local message_type = choice == "2" and "auth.signup" or "auth.signin"
    local local_install = install_info()
    local device_type = options.device or local_install.device
    local business_install = device_type == "TBusinessPhone" or device_type == "TBusinessDesktop"
    local role = options.role or (business_install and "business_phone" or "phone")
    local os_name = options.os or local_install.os or "HyperCube"

    local reply, request_err = request(network, {
        type = message_type,
        username = normalized,
        password_hash = password_hash,
        account_type = options.account_type or (business_install and "business" or nil),
        device = {
            os = os_name,
            role = role,
            device = device_type,
            label = os.getComputerLabel and os.getComputerLabel() or nil,
            computer_id = os.getComputerID and os.getComputerID() or nil,
            scopes = options.scopes,
        },
    }, message_type .. ".result")

    if not reply or not reply.ok then
        local reason = (reply and reply.error) or request_err or "AuthFailed"
        if logger then
            logger.warn("TesseracID failed: " .. tostring(reason))
        end
        return nil, reason
    end

    local identity = {
        tesserac_id = reply.tesserac_id,
        username = reply.username,
        display_name = reply.display_name or reply.username,
        session_token = reply.session_token,
        device = reply.device,
        account = reply.account,
        signed_in_at = now(),
    }

    tesseracid.save_local(identity)
    return identity
end

function tesseracid.ensure_phone_identity(network, logger)
    return tesseracid.ensure_device_identity(network, logger)
end

function tesseracid.auth_database_key(username)
    local normalized = normalize_username(username)
    return "account:" .. tostring(normalized)
end

local function unwrap_record(value)
    if type(value) == "table" and value.value ~= nil and value.key and value.version then
        return value.value
    end
    return value
end

function tesseracid.device_has_scope(device, scope)
    scope = normalize_scope(scope)
    if not scope then
        return false
    end
    return list_contains(device and device.scopes or {}, scope)
end

function tesseracid.find_account_by_tid(database, tesserac_id)
    if not database then
        return nil, "DatabaseUnavailable"
    end
    tesserac_id = tostring(tesserac_id or "")
    local username = unwrap_record(database:get(account_tid_key(tesserac_id)))
    if type(username) == "table" and username.username then
        username = username.username
    end
    if username then
        local account = unwrap_record(database:get(tesseracid.auth_database_key(username)))
        if account then
            return account
        end
    end

    local direct = unwrap_record(database:get(tesseracid.auth_database_key(tesserac_id)))
    if direct and direct.tesserac_id then
        return direct
    end

    return nil, "AccountNotFound"
end

function tesseracid.find_account_for_signin(database, login)
    local username, err = normalize_username(login)
    if not username then
        return nil, nil, err
    end

    local account = unwrap_record(database:get(tesseracid.auth_database_key(username)))
    if account then
        return account, account.username or username
    end

    if username:match("^tid_") then
        account, err = tesseracid.find_account_by_tid(database, username)
        if account then
            return account, account.username
        end
        return nil, username, err
    end

    return nil, username, "AccountNotFound"
end

function tesseracid.server_resolve_login(database, message)
    if not database then
        return false, "DatabaseUnavailable"
    end
    local login, err = normalize_username(message.username or message.login)
    if not login then
        return false, err
    end

    local account
    if login:match("^tid_") then
        account = tesseracid.find_account_by_tid(database, login)
    else
        account = unwrap_record(database:get(tesseracid.auth_database_key(login)))
    end
    if not account then
        return false, "AccountNotFound"
    end
    return true, {
        tesserac_id = account.tesserac_id,
        username = account.username,
        display_name = account.display_name or account.username,
    }
end

function tesseracid.register_device(database, account, device, token)
    if not database then
        return false, "DatabaseUnavailable"
    end
    if not account or not account.tesserac_id then
        return false, "AccountRequired"
    end
    local role = tostring(device and device.role or "device"):lower():gsub("[^%w_%-]", "")
    if (role == "atm" or role == "bank_branch") and account.account_type ~= "business" then
        return false, "BusinessAccountRequired"
    end
    local record = normalize_device(account, device, token)
    account.devices = account.devices or {}
    local existing = account.devices[record.device_id]
    if existing and existing.registered_at then
        record.registered_at = existing.registered_at
    end
    account.devices[record.device_id] = record
    if token then
        account.sessions = account.sessions or {}
        account.sessions[token] = {
            token = token,
            device_id = record.device_id,
            scopes = copy_list(record.scopes),
            created_at = account.sessions[token] and account.sessions[token].created_at or now(),
            last_seen = now(),
        }
    end
    database:set(device_key(record.device_id), record)
    return true, record
end

function tesseracid.validate_session(database, tesserac_id, token, required_scope)
    if not token or token == "" then
        return false, "SessionRequired"
    end
    local account, err = tesseracid.find_account_by_tid(database, tesserac_id)
    if not account then
        return false, err
    end
    local session = account.sessions and account.sessions[token]
    if not session then
        return false, "InvalidSession"
    end
    local device = account.devices and account.devices[session.device_id]
    if required_scope and not tesseracid.device_has_scope(device, required_scope) then
        return false, "ScopeDenied:" .. tostring(required_scope)
    end
    session.last_seen = now()
    if device then
        device.last_seen = now()
    end
    database:set(tesseracid.auth_database_key(account.username), account)
    return true, {
        account = account,
        session = session,
        device = device,
    }
end

function tesseracid.server_signup(database, message)
    if not database then
        return false, "DatabaseUnavailable"
    end

    local username, err = normalize_username(message.username)
    if not username then
        return false, err
    end

    local existing = database:get(tesseracid.auth_database_key(username))
    if existing then
        return false, "AccountExists"
    end

    local account = {
        tesserac_id = "tid_" .. checksum(username .. ":" .. tostring(now())),
        username = username,
        display_name = message.display_name or username,
        account_type = normalize_account_type(message.account_type),
        password_hash = message.password_hash,
        hcfs_key = make_hcfs_key(username, message.password_hash),
        created_at = now(),
        services = {},
        devices = {},
    }
    local ok, result = database:set(tesseracid.auth_database_key(username), account)
    if not ok then
        return false, result
    end
    database:set(account_tid_key(account.tesserac_id), { username = username })

    local token = make_token(username, message.password_hash)
    local device_ok, device = tesseracid.register_device(database, account, message.device or {
        role = "phone",
        os = "HyperCube",
    }, token)
    if not device_ok then
        return false, device
    end
    database:set(tesseracid.auth_database_key(username), account)
    return true, {
        tesserac_id = account.tesserac_id,
        username = account.username,
        display_name = account.display_name,
        session_token = token,
        device = public_device(device),
        account = {
            tesserac_id = account.tesserac_id,
            username = account.username,
            display_name = account.display_name,
            account_type = account.account_type,
            hcfs_key = account.hcfs_key,
            services = account.services,
            devices = public_devices(account.devices),
        },
    }
end

function tesseracid.server_signin(database, message)
    if not database then
        return false, "DatabaseUnavailable"
    end

    local account, username, err = tesseracid.find_account_for_signin(database, message.username)
    if not account then
        return false, err or "AccountNotFound"
    end
    if account.password_hash ~= message.password_hash then
        return false, "InvalidPassword"
    end

    username = account.username or username

    if not account.hcfs_key then
        account.hcfs_key = make_hcfs_key(username, message.password_hash)
    end
    account.last_signin_at = now()
    database:set(account_tid_key(account.tesserac_id), { username = username })

    local token = make_token(username, message.password_hash)
    local device_ok, device = tesseracid.register_device(database, account, message.device or {
        role = "phone",
        os = "HyperCube",
    }, token)
    if not device_ok then
        return false, device
    end
    database:set(tesseracid.auth_database_key(username), account)
    return true, {
        tesserac_id = account.tesserac_id,
        username = account.username,
        display_name = account.display_name,
        session_token = token,
        device = public_device(device),
        account = {
            tesserac_id = account.tesserac_id,
            username = account.username,
            display_name = account.display_name,
            account_type = account.account_type or "personal",
            hcfs_key = account.hcfs_key,
            services = account.services or {},
            devices = public_devices(account.devices),
        },
    }
end

function tesseracid.server_register_device(database, message)
    local ok, validation = tesseracid.validate_session(database, message.tesserac_id, message.session_token)
    if not ok then
        return false, validation
    end
    local device_ok, device = tesseracid.register_device(database, validation.account, message.device or message, message.session_token)
    if not device_ok then
        return false, device
    end
    database:set(tesseracid.auth_database_key(validation.account.username), validation.account)
    return true, public_device(device)
end

function tesseracid.server_list_devices(database, message)
    local ok, validation = tesseracid.validate_session(database, message.tesserac_id, message.session_token, "account.identity")
    if not ok then
        return false, validation
    end
    return true, {
        devices = public_devices(validation.account.devices),
    }
end

local function recovery_key(id)
    return RECOVERY_PREFIX .. tostring(id or "")
end

local function make_recovery_id(account, message)
    return "rec_" .. checksum(tostring(account.tesserac_id) .. ":" .. tostring(message.requested_password_hash) .. ":" .. tostring(now()))
end

local function load_index(database, key)
    local value = unwrap_record(database:get(key))
    if type(value) ~= "table" then
        return {}
    end
    return value
end

local function append_index(database, key, id)
    local index = load_index(database, key)
    for _, existing in ipairs(index) do
        if existing == id then
            return true
        end
    end
    index[#index + 1] = id
    database:set(key, index)
    return true
end

local function public_recovery(record)
    if type(record) ~= "table" then
        return nil
    end
    return {
        request_id = record.request_id,
        status = record.status,
        tesserac_id = record.tesserac_id,
        username = record.username,
        display_name = record.display_name,
        requested_at = record.requested_at,
        requested_by = record.requested_by,
        device = record.device,
        reason = record.reason,
        reviewed_at = record.reviewed_at,
        reviewed_by = record.reviewed_by,
    }
end

local function require_official_tesserac(database, message)
    local ok, validation = tesseracid.validate_session(database, message.tesserac_id, message.session_token, "account.identity")
    if not ok then
        return false, validation
    end
    if tostring(validation.account.username or "") ~= OFFICIAL_TESSERAC_USERNAME then
        return false, "OfficialTesseracRequired"
    end
    return true, validation
end

function tesseracid.server_recovery_request(database, message, sender)
    if not database then
        return false, "DatabaseUnavailable"
    end
    local account, username, err = tesseracid.find_account_for_signin(database, message.username or message.login)
    if not account then
        return false, err or "AccountNotFound"
    end
    if not message.requested_password_hash or tostring(message.requested_password_hash) == "" then
        return false, "PasswordHashRequired"
    end
    username = account.username or username
    local request_id = make_recovery_id(account, message)
    local record = {
        request_id = request_id,
        status = "pending",
        tesserac_id = account.tesserac_id,
        username = username,
        display_name = account.display_name or username,
        requested_password_hash = tostring(message.requested_password_hash),
        requested_at = now(),
        requested_by = sender,
        reason = tostring(message.reason or ""),
        device = message.device,
    }
    local ok, result = database:set(recovery_key(request_id), record)
    if not ok then
        return false, result
    end
    append_index(database, RECOVERY_INDEX_KEY, request_id)
    return true, {
        request_id = request_id,
        status = record.status,
        username = username,
        tesserac_id = account.tesserac_id,
    }
end

function tesseracid.server_recovery_list(database, message)
    local ok, validation = require_official_tesserac(database, message)
    if not ok then
        return false, validation
    end
    local out = {}
    local index = load_index(database, RECOVERY_INDEX_KEY)
    for _, request_id in ipairs(index) do
        local record = unwrap_record(database:get(recovery_key(request_id)))
        if type(record) == "table" and record.status == "pending" then
            out[#out + 1] = public_recovery(record)
        end
    end
    table.sort(out, function(a, b)
        return (tonumber(a.requested_at) or 0) < (tonumber(b.requested_at) or 0)
    end)
    return true, {
        requests = out,
        reviewer = validation.account.username,
    }
end

function tesseracid.server_recovery_approve(database, message)
    local ok, validation = require_official_tesserac(database, message)
    if not ok then
        return false, validation
    end
    local request_id = tostring(message.request_id or "")
    if request_id == "" then
        return false, "RequestIdRequired"
    end
    local record = unwrap_record(database:get(recovery_key(request_id)))
    if type(record) ~= "table" then
        return false, "RecoveryRequestNotFound"
    end
    if record.status ~= "pending" then
        return false, "RecoveryRequestAlreadyReviewed"
    end
    local account, err = tesseracid.find_account_by_tid(database, record.tesserac_id)
    if not account then
        return false, err or "AccountNotFound"
    end
    account.password_hash = record.requested_password_hash
    account.hcfs_key = account.hcfs_key or make_hcfs_key(account.username, account.password_hash)
    account.sessions = {}
    for device_id, device in pairs(account.devices or {}) do
        device.session_token = nil
        device.status = "recovery_required"
        device.last_seen = now()
        database:set(device_key(device_id), device)
    end
    account.recovered_at = now()
    account.recovered_by = validation.account.tesserac_id
    database:set(tesseracid.auth_database_key(account.username), account)
    record.status = "approved"
    record.reviewed_at = now()
    record.reviewed_by = validation.account.username
    database:set(recovery_key(request_id), record)
    return true, public_recovery(record)
end

function tesseracid.server_signout(database, message)
    local ok, validation = tesseracid.validate_session(database, message.tesserac_id, message.session_token)
    if not ok then
        return false, validation
    end
    local token = tostring(message.session_token or "")
    local account = validation.account
    if account.sessions then
        account.sessions[token] = nil
    end
    if validation.device then
        validation.device.session_token = nil
        validation.device.status = "signed_out"
        validation.device.last_seen = now()
        account.devices = account.devices or {}
        account.devices[validation.device.device_id] = validation.device
        database:set(device_key(validation.device.device_id), validation.device)
    end
    database:set(tesseracid.auth_database_key(account.username), account)
    return true, {
        signed_out = true,
    }
end

return tesseracid
