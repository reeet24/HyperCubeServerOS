local tesseracid = require("Kernal.services.tesseracid")

local auth_web = {}

local DOMAIN = "auth.tesserac"
local OWNER = "tesserac"
local TOKEN_PREFIX = "web:auth:token:"

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function domain_key(domain)
    return "web:domain:" .. tostring(domain or "")
end

local function normalize_domain(domain)
    domain = tostring(domain or ""):lower():gsub("%s+", "")
    domain = domain:gsub("^hyper://", ""):gsub("^hc://", ""):gsub("^hcm://", "")
    domain = domain:gsub("/.*$", "")
    return domain
end

local function normalize_path(path)
    path = tostring(path or "/")
    if path == "" then
        return "/"
    end
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    return path
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

local function token_key(domain, token)
    return TOKEN_PREFIX .. normalize_domain(domain) .. ":" .. tostring(token or "")
end

local function session_identity(sender, message, clients)
    local client = clients and clients[sender] or {}
    return {
        tesserac_id = message and message.tesserac_id or client.tesserac_id,
        username = message and message.username or client.username,
        session_token = message and message.session_token or client.session_token,
        device_id = message and message.device_id or client.device_id,
    }
end

local function public_subject(record)
    if type(record) ~= "table" then
        return nil
    end
    return {
        domain = record.domain,
        subject_token = record.subject_token,
        username = record.username,
        display_name = record.display_name,
        account_type = record.account_type,
        issued_at = record.issued_at,
        last_seen = record.last_seen,
    }
end

local function page(title, lines)
    local out = { "<page title=\"" .. escape(title) .. "\">" }
    out[#out + 1] = "<h1>" .. escape(title) .. "</h1>"
    out[#out + 1] = "<p>Tesserac sign-in for HyperNet websites.</p>"
    for _, line in ipairs(lines or {}) do
        out[#out + 1] = line
    end
    out[#out + 1] = "</page>"
    return table.concat(out, "\n")
end

function auth_web.issue_for_view(hypercube, sender, message, clients, domain)
    if not hypercube or not hypercube.database then
        return false, "DatabaseUnavailable"
    end
    domain = normalize_domain(domain)
    if domain == "" then
        return false, "DomainRequired"
    end

    local identity = session_identity(sender, message, clients)
    local ok, validation = tesseracid.validate_session(
        hypercube.database,
        identity.tesserac_id,
        identity.session_token,
        "account.identity"
    )
    if not ok then
        return false, validation or "AuthRequired"
    end

    local account = validation.account or {}
    local seed = tostring(domain) .. ":" .. tostring(account.tesserac_id) .. ":" .. tostring(account.hcfs_key or account.created_at or account.username)
    local subject_token = "wsub_" .. checksum(seed)
    local record = {
        domain = domain,
        subject_token = subject_token,
        tesserac_id = account.tesserac_id,
        username = account.username,
        display_name = account.display_name or account.username,
        account_type = account.account_type,
        issued_at = now(),
        last_seen = now(),
    }
    hypercube.database:set(token_key(domain, subject_token), record)
    return true, public_subject(record)
end

function auth_web.verify(hypercube, origin_sender, message)
    if not hypercube or not hypercube.database then
        return false, "DatabaseUnavailable"
    end
    local domain = normalize_domain(message and (message.domain or message.audience))
    local subject_token = tostring(message and (message.subject_token or message.token) or "")
    if domain == "" then
        return false, "DomainRequired"
    end
    if subject_token == "" then
        return false, "SubjectTokenRequired"
    end

    local domain_record = hypercube.database:get(domain_key(domain))
    if not domain_record then
        return false, "DomainNotFound"
    end
    if tostring(domain_record.origin_id or "") ~= tostring(origin_sender or "") then
        return false, "OriginDenied"
    end

    local record = hypercube.database:get(token_key(domain, subject_token))
    if not record then
        return false, "SubjectNotFound"
    end
    record.last_seen = now()
    hypercube.database:set(token_key(domain, subject_token), record)
    return true, public_subject(record)
end

function auth_web.handle_web_request(hypercube, sender, message, clients)
    local path = normalize_path(message and message.path)
    if path == "/" then
        return true, {
            content_type = "hctml",
            hctml = page("Tesserac Auth", {
                "<h2>For Users</h2>",
                "<p>Websites can request a private Tesserac sign-in token for your current account.</p>",
                "<h2>For Developers</h2>",
                "<p>Register a routed origin and read request.auth.subject_token from web.origin.request.</p>",
                "<p>Verify tokens with web.auth.verify before trusting them.</p>",
            }),
        }
    end

    if path == "/session" or path == "/api/session" then
        local domain = message and (message.domain_for_auth or message.audience or (message.query and message.query.domain))
        local ok, result = auth_web.issue_for_view(hypercube, sender, message, clients, domain)
        return true, {
            content_type = "json",
            body = {
                ok = ok == true,
                result = ok and result or nil,
                error = ok and nil or result,
            },
            status = ok and 200 or 403,
        }
    end

    return true, {
        content_type = "hctml",
        hctml = page("Not Found", {
            "<p>The requested Tesserac Auth page does not exist.</p>",
        }),
        status = 404,
    }
end

function auth_web.install(hypercube)
    if not hypercube.database then
        return false, "DatabaseUnavailable"
    end
    if hypercube.web then
        hypercube.web:register_domain(OWNER, DOMAIN, {
            title = "Tesserac Auth",
        })
    end
    local record = hypercube.database:get(domain_key(DOMAIN)) or {
        domain = DOMAIN,
        owner = OWNER,
        created_at = now(),
    }
    record.owner = OWNER
    record.title = "Tesserac Auth"
    record.origin_id = nil
    record.origin_label = nil
    record.mode = "stored"
    record.supports_api = true
    record.updated_at = now()
    hypercube.database:set(domain_key(DOMAIN), record)
    hypercube.auth_web = auth_web
    if hypercube.network then
        hypercube.network.auth_web = auth_web
        hypercube.network.hypercube = hypercube
    end
    return true
end

function auth_web.start(hypercube)
    local ok, err = auth_web.install(hypercube)
    if not ok then
        return false, err
    end
    if hypercube.logger then
        hypercube.logger.info("Tesserac Auth web service started", hypercube.root_context)
    end
    while true do
        coroutine.yield("tick")
    end
end

auth_web.DOMAIN = DOMAIN

return auth_web
