local hctml = require("Kernal.services.hctml")

local WebService = {}
WebService.__index = WebService

local web = {}

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function normalize_domain(domain)
    domain = tostring(domain or ""):lower():gsub("%s+", "")
    domain = domain:gsub("[^a-z0-9%.%-]", "")
    domain = domain:gsub("%.%.+", ".")
    domain = domain:gsub("^%.+", ""):gsub("%.+$", "")
    if domain == "" or #domain > 64 then
        return nil, "InvalidDomain"
    end
    if not domain:match("^[a-z0-9]") or not domain:match("[a-z0-9]$") then
        return nil, "InvalidDomain"
    end
    return domain
end

local function normalize_path(path)
    path = tostring(path or "/")
    path = path:gsub("\\", "/")
    path = path:gsub("%s+", "")
    path = path:gsub("[^%w%._%-%/]", "")
    path = path:gsub("//+", "/")
    if path == "" then
        path = "/"
    end
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    if #path > 96 then
        return nil, "InvalidPath"
    end
    return path
end

local function domain_key(domain)
    return "web:domain:" .. domain
end

local function page_key(domain, path)
    return "web:page:" .. domain .. ":" .. path
end

local function owner_key(owner)
    return "web:owner:" .. owner .. ":domains"
end

local function require_database(self)
    if not self.database then
        return false, "DatabaseUnavailable"
    end
    return true
end

local function require_owner(owner)
    if not owner or owner == "" then
        return nil, "AuthRequired"
    end
    return tostring(owner)
end

local function list_contains(list, value)
    for _, item in ipairs(list or {}) do
        if item == value then
            return true
        end
    end
    return false
end

function WebService.new(options)
    options = options or {}
    local self = setmetatable({}, WebService)
    self.database = options.database
    return self
end

function WebService:register_domain(owner, domain, options)
    local ok, db_err = require_database(self)
    if not ok then
        return false, db_err
    end

    local owner_err
    owner, owner_err = require_owner(owner)
    if not owner then
        return false, owner_err
    end

    local domain_err
    domain, domain_err = normalize_domain(domain)
    if not domain then
        return false, domain_err
    end

    local existing = self.database:get(domain_key(domain))
    if existing and existing.owner ~= owner then
        return false, "DomainTaken"
    end

    local record = existing or {
        domain = domain,
        owner = owner,
        created_at = now(),
    }
    record.title = options and options.title or record.title or domain
    record.origin_id = options and options.origin_id or record.origin_id
    record.origin_label = options and options.origin_label or record.origin_label
    record.mode = record.origin_id and "routed" or (record.mode or "stored")
    record.supports_api = options and options.supports_api == true or record.supports_api == true
    record.updated_at = now()

    local set_ok, set_result = self.database:set(domain_key(domain), record)
    if not set_ok then
        return false, set_result
    end

    local owned = self.database:get(owner_key(owner)) or {
        owner = owner,
        domains = {},
    }
    if not list_contains(owned.domains, domain) then
        owned.domains[#owned.domains + 1] = domain
    end
    owned.updated_at = now()
    self.database:set(owner_key(owner), owned)

    return true, record
end

function WebService:publish(owner, domain, path, source)
    local ok, db_err = require_database(self)
    if not ok then
        return false, db_err
    end

    local owner_err
    owner, owner_err = require_owner(owner)
    if not owner then
        return false, owner_err
    end

    local domain_err
    domain, domain_err = normalize_domain(domain)
    if not domain then
        return false, domain_err
    end

    local path_err
    path, path_err = normalize_path(path)
    if not path then
        return false, path_err
    end

    local domain_record = self.database:get(domain_key(domain))
    if not domain_record then
        return false, "DomainNotFound"
    end
    if domain_record.owner ~= owner then
        return false, "Forbidden"
    end

    local compiled, compile_err = hctml.compile(source)
    if not compiled then
        return false, compile_err
    end

    local page = {
        domain = domain,
        path = path,
        owner = owner,
        hctml = source,
        rendered = compiled.rendered,
        ast = compiled.ast,
        updated_at = now(),
    }

    local set_ok, set_result = self.database:set(page_key(domain, path), page)
    if not set_ok then
        return false, set_result
    end

    domain_record.updated_at = now()
    domain_record.home_title = path == "/" and compiled.rendered.title or domain_record.home_title
    self.database:set(domain_key(domain), domain_record)

    return true, page
end

function WebService:resolve(domain)
    local ok, db_err = require_database(self)
    if not ok then
        return false, db_err
    end

    local domain_err
    domain, domain_err = normalize_domain(domain)
    if not domain then
        return false, domain_err
    end

    local record = self.database:get(domain_key(domain))
    if not record then
        return false, "DomainNotFound"
    end

    return true, record
end

function WebService:get_page(domain, path)
    local ok, db_err = require_database(self)
    if not ok then
        return false, db_err
    end

    local domain_err
    domain, domain_err = normalize_domain(domain)
    if not domain then
        return false, domain_err
    end

    local path_err
    path, path_err = normalize_path(path)
    if not path then
        return false, path_err
    end

    local page = self.database:get(page_key(domain, path))
    if not page then
        return false, "PageNotFound"
    end

    return true, page
end

function WebService:list_domains(owner)
    local ok, db_err = require_database(self)
    if not ok then
        return false, db_err
    end

    local owner_err
    owner, owner_err = require_owner(owner)
    if not owner then
        return false, owner_err
    end

    local record = self.database:get(owner_key(owner)) or {
        owner = owner,
        domains = {},
    }
    return true, record
end

function web.new(options)
    return WebService.new(options)
end

web.WebService = WebService
web.normalize_domain = normalize_domain
web.normalize_path = normalize_path

return web
