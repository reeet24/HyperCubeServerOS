local moderation_server = {}

local tesseracid = require("Kernal.services.tesseracid")

local DOMAIN = "moderation.tesserac"
local ADMIN_USERNAME = "tesserac"
local AUTH_KEY = "moderation:authorized"
local INDEX_KEY = "moderation:reports:index"
local REPORT_PREFIX = "moderation:report:"
local MAX_INDEX = 100

local function domain_key(domain)
    return "web:domain:" .. tostring(domain or "")
end

local function phone_account_key(owner)
    return "phone:account:" .. tostring(owner or "")
end

local function phone_number_key(number)
    return "phone:number:" .. tostring(number or "")
end

local function username_key(username)
    return tostring(username or ""):lower()
end

local function normalize_lookup(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function normalize_phone_number(value)
    value = tostring(value or ""):gsub("%D", "")
    if #value == 6 then
        return value
    end
    return nil
end

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
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

local function escape(text)
    text = tostring(text or "")
    text = text:gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub("\"", "&quot;")
        :gsub("'", "&apos;")
    return text
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

local function session_identity(sender, message, clients)
    local client = clients and clients[sender] or {}
    return {
        tesserac_id = message.tesserac_id or client.tesserac_id,
        session_token = message.session_token or client.session_token,
        device_id = message.device_id or client.device_id,
    }
end

local function require_identity(database, sender, message, clients, scope)
    if not database then
        return false, "DatabaseUnavailable"
    end
    local identity = session_identity(sender, message, clients)
    local ok, result = tesseracid.validate_session(database, identity.tesserac_id, identity.session_token, scope or "account.identity")
    if not ok then
        return false, result
    end
    return true, result
end

local function resolve_account(database, login)
    local ok, result = tesseracid.server_resolve_login(database, { username = login })
    if ok and result then
        return result
    end
    return nil, result
end

local function full_account_by_login(database, login)
    local account = nil
    local username = nil
    local err = nil
    if tostring(login or ""):match("^tid_") then
        account, err = tesseracid.find_account_by_tid(database, login)
        username = account and account.username or nil
    else
        account, username, err = tesseracid.find_account_for_signin(database, login)
    end
    return account, username, err
end

local function public_account_info(account)
    if not account then
        return nil
    end
    return {
        tesserac_id = account.tesserac_id,
        username = account.username,
        display_name = account.display_name or account.username,
        account_type = account.account_type or "personal",
        created_at = account.created_at,
        last_signin_at = account.last_signin_at,
    }
end

local function authorized_record(database)
    local record = database:get(AUTH_KEY) or {
        users = {},
        updated_at = now(),
    }
    record.users = record.users or {}
    if not record.users[ADMIN_USERNAME] then
        record.users[ADMIN_USERNAME] = {
            username = ADMIN_USERNAME,
            added_by = "system",
            added_at = now(),
        }
    end
    return record
end

local function save_authorized(database, record)
    record.updated_at = now()
    return database:set(AUTH_KEY, record)
end

local function account_authorized(database, account)
    if not account then
        return false
    end
    local record = authorized_record(database)
    local tid = tostring(account.tesserac_id or "")
    local username = tostring(account.username or "")
    return record.users[tid] ~= nil
        or record.users[username] ~= nil
        or record.users[username_key(username)] ~= nil
end

local function require_authorized(database, account)
    if account_authorized(database, account) then
        return true
    end
    return false, "NotAuthorized"
end

local function authorize_user(database, actor, login)
    local ok, err = require_authorized(database, actor)
    if not ok then
        return false, err
    end
    local target, resolve_err = resolve_account(database, login)
    if not target then
        return false, resolve_err or "AccountNotFound"
    end
    local record = authorized_record(database)
    local entry = {
        tesserac_id = target.tesserac_id,
        username = target.username,
        display_name = target.display_name,
        added_by = actor.username or actor.tesserac_id,
        added_at = now(),
    }
    record.users[target.tesserac_id] = entry
    record.users[target.username] = entry
    record.users[username_key(target.username)] = entry
    local set_ok, set_err = save_authorized(database, record)
    if not set_ok then
        return false, set_err
    end
    return true, entry
end

local function normalize_message(message)
    local out = {}
    message = type(message) == "table" and message or {}
    out.id = tostring(message.id or "")
    out.from = tostring(message.from or "")
    out.to = tostring(message.to or "")
    out.body = tostring(message.body or ""):sub(1, 500)
    out.sent_at = message.sent_at
    out.direction = tostring(message.direction or "")
    return out
end

local function index_record(database)
    return database:get(INDEX_KEY) or {
        reports = {},
        updated_at = now(),
    }
end

local function public_report(report)
    return {
        id = report.id,
        status = report.status,
        reporter = report.reporter_username or report.reporter,
        reporter_id = report.reporter,
        chat_number = report.chat_number,
        reason = report.reason,
        message = report.message,
        created_at = report.created_at,
    }
end

local function page(title, lines)
    local out = { "<page title=\"" .. escape(title) .. "\">" }
    for _, line in ipairs(lines or {}) do
        out[#out + 1] = line
    end
    out[#out + 1] = "</page>"
    return table.concat(out, "\n")
end

local function unauthorized_page(account)
    return page("Tesserac Moderation", {
        "<h1>Tesserac Moderation</h1>",
        "<p>Access is restricted to authorized moderation users.</p>",
        "<p>Signed in as " .. escape(account and (account.username or account.tesserac_id) or "unknown") .. ".</p>",
    })
end

local function home_page(account)
    return page("Tesserac Moderation", {
        "<h1>Tesserac Moderation</h1>",
        "<p>Signed in as " .. escape(account.username or account.tesserac_id) .. ".</p>",
        "<link href=\"/reports\">Reports</link>",
        "<link href=\"/accounts\">Account Lookup</link>",
        "<link href=\"/authorize\">Authorize Users</link>",
    })
end

local function reports_page(database)
    local index = index_record(database)
    local lines = {
        "<h1>Flagged Messages</h1>",
        "<link href=\"/\">Home</link>",
        "<list>",
    }
    local shown = 0
    for _, id in ipairs(index.reports or {}) do
        local report = database:get(REPORT_PREFIX .. tostring(id))
        if report then
            shown = shown + 1
            local body = report.message and report.message.body or ""
            local from = report.message and report.message.from or "unknown"
            lines[#lines + 1] = "<item>#" .. escape(report.id)
                .. " [" .. escape(report.status or "open") .. "] "
                .. "from " .. escape(from)
                .. " reported by " .. escape(report.reporter_username or report.reporter or "unknown")
                .. ": " .. escape(body:sub(1, 160)) .. "</item>"
        end
    end
    if shown == 0 then
        lines[#lines + 1] = "<item>No reports yet.</item>"
    end
    lines[#lines + 1] = "</list>"
    return page("Moderation Reports", lines)
end

local function matching_reports(database, account, phone)
    local index = index_record(database)
    local matches = {}
    local tid = tostring(account and account.tesserac_id or "")
    local username = tostring(account and account.username or "")
    phone = tostring(phone or "")
    for _, id in ipairs(index.reports or {}) do
        local report = database:get(REPORT_PREFIX .. tostring(id))
        if report then
            local msg = report.message or {}
            local haystack = {
                tostring(report.reporter or ""),
                tostring(report.reporter_username or ""),
                tostring(report.chat_number or ""),
                tostring(msg.from or ""),
                tostring(msg.to or ""),
            }
            local matched = false
            for _, value in ipairs(haystack) do
                if value ~= "" and (value == tid or value == username or value == phone) then
                    matched = true
                    break
                end
            end
            if matched then
                matches[#matches + 1] = report
            end
        end
    end
    return matches
end

local function lookup_account(hypercube, query)
    query = normalize_lookup(query)
    if query == "" then
        return nil, "LookupRequired"
    end

    local phone = normalize_phone_number(query)
    if phone then
        local link = hypercube.database:get(phone_number_key(phone))
        if link and link.owner then
            local account = tesseracid.find_account_by_tid(hypercube.database, link.owner)
            if account then
                return {
                    account = public_account_info(account),
                    raw_account = account,
                    phone = phone,
                    matched_by = "phone",
                }
            end
        end
    end

    local account = full_account_by_login(hypercube.database, query)
    if account then
        local phone_record = hypercube.database:get(phone_account_key(account.tesserac_id))
        return {
            account = public_account_info(account),
            raw_account = account,
            phone = phone_record and phone_record.number or nil,
            matched_by = query:match("^tid_") and "tesserac_id" or "username",
        }
    end

    if hypercube.bank and hypercube.bank.lookup_by_minecraft then
        local bank_ok, bank_account = hypercube.bank:lookup_by_minecraft(query)
        if bank_ok and bank_account and bank_account.owner then
            account = tesseracid.find_account_by_tid(hypercube.database, bank_account.owner)
            local phone_record = account and hypercube.database:get(phone_account_key(account.tesserac_id)) or nil
            return {
                account = public_account_info(account) or {
                    tesserac_id = bank_account.owner,
                    username = bank_account.username,
                },
                raw_account = account,
                phone = phone_record and phone_record.number or nil,
                bank = bank_account,
                matched_by = "minecraft",
            }
        end
    end

    return nil, "AccountNotFound"
end

local function account_lookup_page(hypercube, viewer, query, notice)
    query = normalize_lookup(query)
    local lines = {
        "<h1>Account Lookup</h1>",
        "<link href=\"/\">Home</link>",
        "<link href=\"/reports\">Reports</link>",
        "<p>Navigate to /accounts/username, /accounts/phone, /accounts/tid, or /accounts/minecraft_name.</p>",
    }
    if notice then
        lines[#lines + 1] = "<p>" .. escape(notice) .. "</p>"
    end
    if query == "" then
        return page("Account Lookup", lines)
    end

    local found, err = lookup_account(hypercube, query)
    if not found then
        lines[#lines + 1] = "<p>No account found for " .. escape(query) .. ": " .. escape(err) .. ".</p>"
        return page("Account Lookup", lines)
    end

    local account = found.account or {}
    local bank = found.bank
    if not bank and hypercube.bank and hypercube.bank.status and account.tesserac_id then
        local bank_ok, bank_result = hypercube.bank:status(account.tesserac_id, account.username)
        if bank_ok then
            bank = bank_result
        end
    end

    lines[#lines + 1] = "<h2>" .. escape(account.username or account.tesserac_id or query) .. "</h2>"
    lines[#lines + 1] = "<list>"
    lines[#lines + 1] = "<item>Matched by: " .. escape(found.matched_by or "lookup") .. "</item>"
    lines[#lines + 1] = "<item>Tesserac ID: " .. escape(account.tesserac_id or "unknown") .. "</item>"
    lines[#lines + 1] = "<item>Username: " .. escape(account.username or "unknown") .. "</item>"
    lines[#lines + 1] = "<item>Display: " .. escape(account.display_name or account.username or "unknown") .. "</item>"
    lines[#lines + 1] = "<item>Type: " .. escape(account.account_type or "personal") .. "</item>"
    lines[#lines + 1] = "<item>Phone: " .. escape(found.phone or "none") .. "</item>"
    if bank and bank.open then
        lines[#lines + 1] = "<item>Bank: open, balance " .. escape(bank.balance or 0) .. " " .. escape(bank.currency or "TC") .. "</item>"
        lines[#lines + 1] = "<item>Minecraft: " .. escape(bank.minecraft_name or "missing") .. "</item>"
        if bank.minecraft_match_count and bank.minecraft_match_count > 1 then
            lines[#lines + 1] = "<item>Minecraft matches: " .. escape(bank.minecraft_match_count) .. " accounts use this name</item>"
        end
    else
        lines[#lines + 1] = "<item>Bank: none</item>"
    end
    lines[#lines + 1] = "</list>"

    local reports = matching_reports(hypercube.database, account, found.phone)
    lines[#lines + 1] = "<h2>Related Reports</h2>"
    lines[#lines + 1] = "<list>"
    if #reports == 0 then
        lines[#lines + 1] = "<item>No matching reports.</item>"
    else
        for _, report in ipairs(reports) do
            local body = report.message and report.message.body or ""
            lines[#lines + 1] = "<item>#" .. escape(report.id)
                .. " [" .. escape(report.status or "open") .. "] "
                .. escape(body:sub(1, 140)) .. "</item>"
        end
    end
    lines[#lines + 1] = "</list>"

    if username_key(viewer and viewer.username) == ADMIN_USERNAME and bank and bank.open and account.tesserac_id then
        lines[#lines + 1] = "<h2>Tesserac Actions</h2>"
        lines[#lines + 1] = "<link href=\"/accounts/close/" .. escape(account.tesserac_id) .. "\">Close bank account for bad signup name</link>"
    end

    return page("Account Lookup", lines)
end

local function authorize_page(database, account, target_login, result)
    local record = authorized_record(database)
    local lines = {
        "<h1>Authorize Users</h1>",
        "<link href=\"/\">Home</link>",
    }
    if result then
        lines[#lines + 1] = "<p>" .. escape(result) .. "</p>"
    end
    lines[#lines + 1] = "<p>To authorize a user, navigate to /authorize/username while signed in as an authorized user.</p>"
    if target_login and target_login ~= "" then
        lines[#lines + 1] = "<p>Requested: " .. escape(target_login) .. "</p>"
    end
    lines[#lines + 1] = "<h2>Authorized</h2>"
    lines[#lines + 1] = "<list>"
    local seen = {}
    for key, entry in pairs(record.users or {}) do
        local id = tostring(entry.tesserac_id or key)
        if not seen[id] then
            seen[id] = true
            lines[#lines + 1] = "<item>" .. escape(entry.username or id)
                .. " added by " .. escape(entry.added_by or "system") .. "</item>"
        end
    end
    lines[#lines + 1] = "</list>"
    return page("Authorize Moderators", lines)
end

function moderation_server.handle_web_request(hypercube, sender, message, clients)
    local ok, auth = require_identity(hypercube.database, sender, message, clients, "account.identity")
    if not ok then
        return false, auth
    end
    local account = auth.account
    if not account_authorized(hypercube.database, account) then
        return true, {
            content_type = "hctml",
            hctml = unauthorized_page(account),
        }
    end

    local path = tostring(message.path or "/")
    local hctml
    if path == "/" or path == "" then
        hctml = home_page(account)
    elseif path == "/reports" then
        hctml = reports_page(hypercube.database)
    elseif path == "/accounts" then
        hctml = account_lookup_page(hypercube, account)
    elseif path:match("^/accounts/close/") then
        local query = path:match("^/accounts/close/(.+)$") or ""
        if username_key(account.username) ~= ADMIN_USERNAME then
            hctml = account_lookup_page(hypercube, account, query, "Only the official Tesserac account can close bank accounts.")
        else
            local found = lookup_account(hypercube, query)
            if found and found.account and found.account.tesserac_id and hypercube.bank and hypercube.bank.close then
                local close_ok, close_result = hypercube.bank:close(
                    found.account.tesserac_id,
                    "Closed by Tesserac moderation: incorrect Minecraft signup name",
                    account.username or account.tesserac_id
                )
                hctml = account_lookup_page(
                    hypercube,
                    account,
                    query,
                    close_ok and "Bank account closed." or ("Close failed: " .. tostring(close_result))
                )
            else
                hctml = account_lookup_page(hypercube, account, query, "Close failed: AccountNotFound")
            end
        end
    elseif path:match("^/accounts/") then
        local query = path:match("^/accounts/(.+)$") or ""
        hctml = account_lookup_page(hypercube, account, query)
    elseif path == "/authorize" then
        hctml = authorize_page(hypercube.database, account)
    elseif path:match("^/authorize/") then
        local login = path:match("^/authorize/(.+)$") or ""
        local auth_ok, result = authorize_user(hypercube.database, account, login)
        hctml = authorize_page(
            hypercube.database,
            account,
            login,
            auth_ok and ("Authorized " .. tostring(result.username or result.tesserac_id)) or tostring(result)
        )
    else
        hctml = page("Not Found", {
            "<h1>Not Found</h1>",
            "<link href=\"/\">Home</link>",
        })
    end
    return true, {
        content_type = "hctml",
        hctml = hctml,
    }
end

local function create_report(hypercube, sender, message, clients)
    local ok, auth = require_identity(hypercube.database, sender, message, clients, "phone.access")
    if not ok then
        return false, auth
    end
    local msg = normalize_message(message.message)
    if msg.body == "" then
        return false, "MessageRequired"
    end

    local created = now()
    local id = "rpt_" .. checksum(tostring(auth.account.tesserac_id) .. ":" .. tostring(created) .. ":" .. msg.body)
    local report = {
        id = id,
        status = "open",
        reporter = auth.account.tesserac_id,
        reporter_username = auth.account.username,
        chat_number = tostring(message.chat_number or msg.from or ""),
        reason = tostring(message.reason or "harmful_message"):sub(1, 80),
        message = msg,
        created_at = created,
        updated_at = created,
    }
    local set_ok, set_err = hypercube.database:set(REPORT_PREFIX .. id, report)
    if not set_ok then
        return false, set_err
    end

    local index = index_record(hypercube.database)
    table.insert(index.reports, 1, id)
    while #index.reports > MAX_INDEX do
        table.remove(index.reports)
    end
    index.updated_at = now()
    hypercube.database:set(INDEX_KEY, index)
    return true, public_report(report)
end

local function list_reports(hypercube, sender, message, clients)
    local ok, auth = require_identity(hypercube.database, sender, message, clients, "account.identity")
    if not ok then
        return false, auth
    end
    local account = auth.account or {}
    local auth_ok, auth_err = require_authorized(hypercube.database, account)
    if not auth_ok then
        return false, auth_err
    end

    local index = index_record(hypercube.database)
    local out = {}
    local limit = math.min(tonumber(message.limit) or 25, 50)
    for _, id in ipairs(index.reports or {}) do
        if #out >= limit then
            break
        end
        local report = hypercube.database:get(REPORT_PREFIX .. tostring(id))
        if report then
            out[#out + 1] = public_report(report)
        end
    end
    return true, {
        reports = out,
        portal = DOMAIN,
    }
end

local function authorize_request(hypercube, sender, message, clients)
    local ok, auth = require_identity(hypercube.database, sender, message, clients, "account.identity")
    if not ok then
        return false, auth
    end
    return authorize_user(hypercube.database, auth.account, message.username or message.tesserac_id or message.login)
end

function moderation_server.install(hypercube)
    if not hypercube.network then
        return false, "NetworkUnavailable"
    end
    if not hypercube.database then
        return false, "DatabaseUnavailable"
    end
    authorized_record(hypercube.database)
    save_authorized(hypercube.database, authorized_record(hypercube.database))
    if hypercube.web then
        hypercube.web:register_domain(ADMIN_USERNAME, DOMAIN, {
            title = "Tesserac Moderation",
        })
    end
    local domain_record = hypercube.database:get(domain_key(DOMAIN)) or {
        domain = DOMAIN,
        owner = ADMIN_USERNAME,
        created_at = now(),
    }
    domain_record.owner = ADMIN_USERNAME
    domain_record.title = "Tesserac Moderation"
    domain_record.origin_id = nil
    domain_record.origin_label = nil
    domain_record.mode = "stored"
    domain_record.supports_api = false
    domain_record.updated_at = now()
    hypercube.database:set(domain_key(DOMAIN), domain_record)
    hypercube.moderation = moderation_server
    if hypercube.network then
        hypercube.network.moderation = moderation_server
        hypercube.network.hypercube = hypercube
    end
    if hypercube.moderation_registered then
        return true
    end

    hypercube.network:register_handler("moderation", function(network, sender, message)
        if type(message) ~= "table" or type(message.type) ~= "string" or message.type:sub(1, 11) ~= "moderation." then
            return false
        end
        local ok, result
        if message.type == "moderation.report" then
            ok, result = create_report(hypercube, sender, message, network.clients)
            reply(rednet, sender, network.protocol, "moderation.report.result", ok, result)
        elseif message.type == "moderation.report.list" then
            ok, result = list_reports(hypercube, sender, message, network.clients)
            reply(rednet, sender, network.protocol, "moderation.report.list.result", ok, result)
        elseif message.type == "moderation.authorize" then
            ok, result = authorize_request(hypercube, sender, message, network.clients)
            reply(rednet, sender, network.protocol, "moderation.authorize.result", ok, result)
        else
            reply(rednet, sender, network.protocol, "moderation.error", false, "UnknownModerationRequest")
        end
        return true
    end)

    hypercube.moderation_registered = true
    return true
end

function moderation_server.start(hypercube)
    local ok, err = moderation_server.install(hypercube)
    if not ok then
        return false, err
    end
    if hypercube.logger then
        hypercube.logger.info("moderation process started", hypercube.root_context)
    end
    while true do
        coroutine.yield("tick")
    end
end

moderation_server.DOMAIN = DOMAIN

return moderation_server
