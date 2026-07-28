local docs_server = {}

local DOMAIN = "docs.tesserac"
local OWNER = "tesserac"
local DOC_ROOT = "docs"
local MAX_RESULTS = 25

local DOCS = {
    { id = "userapp-api", title = "User App API", file = "userapp-api.md", summary = "Phone user-app lifecycle, UI, storage, network, appstore, and dev-mode APIs." },
    { id = "web-api", title = "Web API", file = "web-api.md", summary = "HyperNet web publishing, routed origins, HCTML, and moderation web routes." },
    { id = "web-api-examples", title = "Web API Examples", file = "web-api-examples.md", summary = "Copyable examples for publishing pages and serving routed origins." },
    { id = "banking-api", title = "Banking API", file = "banking-api.md", summary = "Bank accounts, purchases, deposits, withdrawals, escrow, and integration patterns." },
    { id = "server-flow", title = "Server Flow", file = "server-flow.md", summary = "Main server boot, rednet routing, services, storage, updates, and operational flow." },
    { id = "user-server-api", title = "User Server API", file = "user-server-api.md", summary = "User-server install, service lifecycle, ServiceAPI, UI modules, storage, and network access." },
    { id = "tos-draft", title = "Draft TOS", file = "tos-draft.md", summary = "Draft terms for phone, Tesserac services, banking, web, moderation, and data handling." },
}

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function domain_key(domain)
    return "web:domain:" .. tostring(domain or "")
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

local function escape(text)
    text = tostring(text or "")
    text = text:gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub("\"", "&quot;")
        :gsub("'", "&apos;")
    return text
end

local function page(title, lines)
    local out = { "<page title=\"" .. escape(title) .. "\">" }
    out[#out + 1] = "<h1>" .. escape(title) .. "</h1>"
    out[#out + 1] = "<p>HyperCube and Tesserac documentation.</p>"
    out[#out + 1] = "<link href=\"/\">Docs Home</link>"
    out[#out + 1] = "<link href=\"/search\">Search</link>"
    for _, line in ipairs(lines or {}) do
        out[#out + 1] = line
    end
    out[#out + 1] = "</page>"
    return table.concat(out, "\n")
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

local function doc_by_id(id)
    id = tostring(id or ""):lower():gsub("[^%w%-_%.]", "")
    for _, doc in ipairs(DOCS) do
        if doc.id == id or doc.file == id or doc.file == id .. ".md" then
            return doc
        end
    end
    return nil
end

local function markdown_to_hctml(markdown)
    local lines = {}
    local in_code = false
    for raw in (tostring(markdown or "") .. "\n"):gmatch("(.-)\n") do
        if raw:match("^```") then
            in_code = not in_code
        elseif in_code then
            if raw ~= "" then
                lines[#lines + 1] = "<p>" .. escape("    " .. raw) .. "</p>"
            end
        elseif raw:match("^###%s+") then
            lines[#lines + 1] = "<h2>" .. escape(raw:gsub("^###%s+", "")) .. "</h2>"
        elseif raw:match("^##%s+") then
            lines[#lines + 1] = "<h2>" .. escape(raw:gsub("^##%s+", "")) .. "</h2>"
        elseif raw:match("^#%s+") then
            lines[#lines + 1] = "<h2>" .. escape(raw:gsub("^#%s+", "")) .. "</h2>"
        elseif raw:match("^%-%s+") then
            lines[#lines + 1] = "<p>" .. escape("* " .. raw:gsub("^%-%s+", "")) .. "</p>"
        elseif raw:match("^%d+%.%s+") then
            lines[#lines + 1] = "<p>" .. escape(raw) .. "</p>"
        elseif raw:match("%S") then
            lines[#lines + 1] = "<p>" .. escape(raw) .. "</p>"
        end
    end
    return lines
end

local function home_page()
    local lines = {
        "<h2>Documents</h2>",
        "<p>Open a document below or use /search/query to find matching docs.</p>",
    }
    for _, doc in ipairs(DOCS) do
        lines[#lines + 1] = "<link href=\"/doc/" .. escape(doc.id) .. "\">" .. escape(doc.title) .. "</link>"
        lines[#lines + 1] = "<p>" .. escape(doc.summary) .. "</p>"
    end
    lines[#lines + 1] = "<h2>Search Tools</h2>"
    lines[#lines + 1] = "<p>Navigate to /search/bank, /search/web, /search/service, or any keyword.</p>"
    return page("Tesserac Docs", lines)
end

local function doc_page(doc)
    if not doc then
        return page("Document Not Found", {
            "<p>The requested document does not exist.</p>",
        })
    end
    local body = read_file(combine(DOC_ROOT, doc.file))
    if not body then
        return page(doc.title, {
            "<p>Document file missing: " .. escape(doc.file) .. "</p>",
        })
    end
    local lines = {
        "<p>" .. escape(doc.summary) .. "</p>",
        "<link href=\"/raw/" .. escape(doc.id) .. "\">Raw Markdown</link>",
    }
    local rendered = markdown_to_hctml(body)
    for _, line in ipairs(rendered) do
        lines[#lines + 1] = line
    end
    return page(doc.title, lines)
end

local function raw_page(doc)
    if not doc then
        return page("Document Not Found", {
            "<p>The requested document does not exist.</p>",
        })
    end
    local body = read_file(combine(DOC_ROOT, doc.file)) or "Missing document."
    local lines = {}
    for line in (body .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then
            lines[#lines + 1] = "<p>" .. escape(line) .. "</p>"
        end
    end
    return page(doc.title .. " Raw", lines)
end

local function search_page(query)
    query = tostring(query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local lines = {
        "<h2>Search</h2>",
        "<p>Use /search/query to search document titles, summaries, and body text.</p>",
    }
    if query == "" then
        lines[#lines + 1] = "<p>No query provided.</p>"
        return page("Search Docs", lines)
    end
    lines[#lines + 1] = "<p>Query: " .. escape(query) .. "</p>"
    local count = 0
    for _, doc in ipairs(DOCS) do
        local body = read_file(combine(DOC_ROOT, doc.file)) or ""
        local haystack = (doc.title .. "\n" .. doc.summary .. "\n" .. body):lower()
        if haystack:find(query, 1, true) then
            count = count + 1
            lines[#lines + 1] = "<link href=\"/doc/" .. escape(doc.id) .. "\">" .. escape(doc.title) .. "</link>"
            lines[#lines + 1] = "<p>" .. escape(doc.summary) .. "</p>"
            if count >= MAX_RESULTS then
                break
            end
        end
    end
    if count == 0 then
        lines[#lines + 1] = "<p>No matching documents.</p>"
    end
    return page("Search Docs", lines)
end

function docs_server.handle_web_request(_, _, message)
    local path = tostring(message and message.path or "/")
    if path == "/" or path == "" then
        return true, {
            content_type = "hctml",
            hctml = home_page(),
        }
    end
    if path == "/search" then
        return true, {
            content_type = "hctml",
            hctml = search_page(""),
        }
    end
    if path:match("^/search/") then
        return true, {
            content_type = "hctml",
            hctml = search_page(path:match("^/search/(.+)$") or ""),
        }
    end
    if path:match("^/raw/") then
        return true, {
            content_type = "hctml",
            hctml = raw_page(doc_by_id(path:match("^/raw/(.+)$"))),
        }
    end
    if path:match("^/doc/") then
        return true, {
            content_type = "hctml",
            hctml = doc_page(doc_by_id(path:match("^/doc/(.+)$"))),
        }
    end
    return true, {
        content_type = "hctml",
        hctml = page("Not Found", {
            "<p>The requested documentation page does not exist.</p>",
        }),
    }
end

function docs_server.install(hypercube)
    if not hypercube.database then
        return false, "DatabaseUnavailable"
    end
    if hypercube.web then
        hypercube.web:register_domain(OWNER, DOMAIN, {
            title = "Tesserac Docs",
        })
    end
    local record = hypercube.database:get(domain_key(DOMAIN)) or {
        domain = DOMAIN,
        owner = OWNER,
        created_at = now(),
    }
    record.owner = OWNER
    record.title = "Tesserac Docs"
    record.origin_id = nil
    record.origin_label = nil
    record.mode = "stored"
    record.supports_api = false
    record.updated_at = now()
    hypercube.database:set(domain_key(DOMAIN), record)
    hypercube.docs_server = docs_server
    if hypercube.network then
        hypercube.network.docs_server = docs_server
        hypercube.network.hypercube = hypercube
    end
    return true
end

function docs_server.start(hypercube)
    local ok, err = docs_server.install(hypercube)
    if not ok then
        return false, err
    end
    if hypercube.logger then
        hypercube.logger.info("docs portal process started", hypercube.root_context)
    end
    while true do
        coroutine.yield("tick")
    end
end

docs_server.DOMAIN = DOMAIN

return docs_server
