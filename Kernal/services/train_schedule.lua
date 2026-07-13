local train_schedule = {}

local TrainScheduleService = {}
TrainScheduleService.__index = TrainScheduleService

local SOURCE_URL = "https://grosik.dev/snr/timetables/cmr"
local CACHE_TTL = 30

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function minutes_now()
    if os.date then
        local date = os.date("*t")
        return (date.hour or 0) * 60 + (date.min or 0)
    end
    return 0
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function collapse_spaces(value)
    return trim((tostring(value or ""):gsub("%s+", " ")))
end

local function decode_entities(value)
    value = tostring(value or "")
    value = value:gsub("&nbsp;", " ")
    value = value:gsub("&amp;", "&")
    value = value:gsub("&lt;", "<")
    value = value:gsub("&gt;", ">")
    value = value:gsub("&quot;", "\"")
    value = value:gsub("&#39;", "'")
    return value
end

local function time_to_eta(time_text)
    local hour, minute = tostring(time_text or ""):match("(%d%d?):(%d%d)")
    hour = tonumber(hour)
    minute = tonumber(minute)
    if not hour or not minute then
        return nil
    end

    local target = hour * 60 + minute
    local eta = target - minutes_now()
    if eta < -120 then
        eta = eta + 24 * 60
    end
    return eta
end

local function eta_to_minutes(value)
    value = tostring(value or ""):lower():gsub("%s+", "")
    if value == "now" or value == "due" then
        return 0
    end

    local hours, minutes = value:match("^(%d+)h(%d*)m?$")
    if hours then
        return (tonumber(hours) or 0) * 60 + (tonumber(minutes) or 0)
    end

    local only_minutes = value:match("^(%d+)m?$")
    if only_minutes then
        return tonumber(only_minutes)
    end

    return tonumber(value)
end

local function clean_route(value)
    value = tostring(value or ""):gsub("<[^>]+>", " ")
    value = collapse_spaces(decode_entities(value))
    value = value:gsub("^%p+", ""):gsub("%p+$", "")
    return value
end

local function add_train(out, item)
    if not item then
        return
    end
    local eta_text = item.eta or item.eta_label
    local time = item.time or item.eta_time or item.departure or item.arrival
    local eta = tonumber(item.eta_minutes) or eta_to_minutes(eta_text)
    if not eta then
        eta = time_to_eta(time)
    end
    if eta == nil then
        return
    end

    out[#out + 1] = {
        time = time and tostring(time) or nil,
        eta = tostring(eta_text or ""),
        eta_minutes = eta,
        train = collapse_spaces(item.train or item.service or item.number or item.id or ""),
        direction = collapse_spaces(item.direction or ""),
        destination = clean_route(item.destination or item.dest or item.to or item.route or ""),
        platform = collapse_spaces(item.platform or item.track or item.line or ""),
        status = collapse_spaces(item.status or item.note or ""),
    }
end

local function scan_json_value(value, out)
    if type(value) ~= "table" then
        return
    end

    add_train(out, value)
    for _, child in pairs(value) do
        if type(child) == "table" then
            scan_json_value(child, out)
        end
    end
end

local function parse_json(body)
    if not textutils or not textutils.unserializeJSON then
        return {}
    end

    local ok, decoded = pcall(textutils.unserializeJSON, body)
    if not ok or type(decoded) ~= "table" then
        return {}
    end

    local trains = {}
    scan_json_value(decoded, trains)
    return trains
end

local function strip_tags(value)
    value = tostring(value or ""):gsub("<br%s*/?>", " ")
    value = value:gsub("<[^>]+>", " ")
    return collapse_spaces(decode_entities(value))
end

local function parse_row(row)
    local cells = {}
    for cell in row:gmatch("<t[dh][^>]*>(.-)</t[dh]>") do
        cells[#cells + 1] = strip_tags(cell)
    end
    if #cells == 0 then
        local text = strip_tags(row)
        local time = text:match("(%d%d?:%d%d)")
        if time then
            return {
                time = time,
                destination = clean_route(text:gsub(time, "", 1)),
            }
        end
        return nil
    end

    local time_index = nil
    for i, cell in ipairs(cells) do
        if cell:match("%d%d?:%d%d") then
            time_index = i
            break
        end
    end
    if not time_index then
        return nil
    end

    local time = cells[time_index]:match("(%d%d?:%d%d)")
    return {
        time = time,
        train = cells[1] ~= time and cells[1] or "",
        destination = cells[time_index + 1] or cells[#cells] or "",
        platform = cells[time_index + 2] or "",
        status = cells[time_index + 3] or "",
    }
end

local function parse_html(body)
    local trains = {}
    for row in tostring(body or ""):gmatch("<tr[^>]*>(.-)</tr>") do
        add_train(trains, parse_row(row))
    end
    return trains
end

local function parse_text(body)
    local trains = {}
    for line in tostring(body or ""):gmatch("[^\r\n]+") do
        local time = line:match("(%d%d?:%d%d)")
        if time then
            add_train(trains, {
                time = time,
                destination = clean_route(line:gsub(time, "", 1)),
            })
        end
    end
    return trains
end

local function sort_trains(trains)
    table.sort(trains, function(a, b)
        local ae = tonumber(a.eta_minutes) or 99999
        local be = tonumber(b.eta_minutes) or 99999
        if ae ~= be then
            return ae < be
        end
        return tostring(a.time) < tostring(b.time)
    end)

    local compact = {}
    local seen = {}
    for _, train in ipairs(trains) do
        local key = tostring(train.time or train.eta) .. "|" .. tostring(train.destination) .. "|" .. tostring(train.train)
        if not seen[key] then
            seen[key] = true
            compact[#compact + 1] = train
            if #compact >= 25 then
                break
            end
        end
    end
    return compact
end

local function parse_body(body)
    local trains = parse_json(body)
    if #trains == 0 then
        trains = parse_html(body)
    end
    if #trains == 0 then
        trains = parse_text(body)
    end
    return sort_trains(trains)
end

local function read_response(handle)
    if not handle then
        return nil, "HttpOpenFailed"
    end
    local body = handle.readAll()
    handle.close()
    return body
end

function TrainScheduleService.new(options)
    options = options or {}
    local self = setmetatable({}, TrainScheduleService)
    self.url = options.url or SOURCE_URL
    self.cache = nil
    return self
end

function TrainScheduleService:fetch(force)
    if self.cache and not force and (now() - self.cache.fetched_at) < (CACHE_TTL * 1000) then
        return true, self.cache
    end
    if not http or not http.get then
        return false, "HttpUnavailable"
    end

    local ok, handle_or_err = pcall(http.get, self.url)
    if not ok then
        return false, handle_or_err
    end
    local body, read_err = read_response(handle_or_err)
    if not body then
        return false, read_err
    end

    local trains = parse_body(body)
    self.cache = {
        source = self.url,
        station = "CMR",
        fetched_at = now(),
        trains = trains,
    }
    return true, self.cache
end

function train_schedule.new(options)
    return TrainScheduleService.new(options)
end

train_schedule.TrainScheduleService = TrainScheduleService

return train_schedule
