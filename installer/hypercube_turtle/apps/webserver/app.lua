local api = HCAPI

local app = {
    manifest = {
        title = "Dedicated Webserver",
        id = "webserver",
    },
}

local function default_domain()
    local id = api.identity and api.identity.tesserac_id or "turtle"
    id = tostring(id):lower():gsub("[^a-z0-9%-]", "")
    if id == "" then
        id = "turtle"
    end
    return "turtle-" .. id .. ".hc"
end

local function status_hctml(status)
    local fuel = status and status.fuel or "unknown"
    local selected = status and status.selected or "unknown"
    return "<page title=\"HyperCube Turtle\"><h1>HyperCube Turtle</h1><p>Dedicated webserver online.</p><p>Fuel: " .. tostring(fuel) .. "</p><p>Selected slot: " .. tostring(selected) .. "</p></page>"
end

function app.start()
    local domain = api.fs.read("domain.txt") or default_domain()
    api.fs.write("domain.txt", domain)
    api.web.set_domain(domain, "HyperCube Turtle")
    api.web.page("/", status_hctml(api.turtle.status()))
    api.web.api("/api/status", function()
        local status = api.turtle.status()
        local inventory = api.turtle.inventory()
        local used = 0
        if type(inventory) == "table" then
            for _, slot in ipairs(inventory) do
                if (slot.count or 0) > 0 then
                    used = used + 1
                end
            end
        end
        return {
            ok = true,
            content_type = "text",
            body = "fuel=" .. tostring(status and status.fuel) .. "\nselected=" .. tostring(status and status.selected) .. "\nused_slots=" .. tostring(used) .. "\n",
        }
    end)
    api.log("webserver domain=" .. tostring(domain))
end

function app.tick()
    api.web.page("/", status_hctml(api.turtle.status()))
end

return app
