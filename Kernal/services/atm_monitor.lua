local atm_monitor = {}

local tesseracid = require("Kernal.services.tesseracid")

local DAY_MS = 24 * 60 * 60 * 1000

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
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

local function atm_key(device_id)
    return "atm:status:" .. tostring(device_id or "")
end

local function stats_key(device_id, day)
    return "atm:stats:" .. tostring(device_id or "") .. ":" .. tostring(day or "")
end

local function day_key(ms)
    return tostring(math.floor((tonumber(ms) or now()) / DAY_MS))
end

local function require_atm_session(database, sender, message, clients)
    if not database then
        return false, "DatabaseUnavailable"
    end
    local identity = session_identity(sender, message, clients)
    local ok, result = tesseracid.validate_session(database, identity.tesserac_id, identity.session_token, "bank.deposit")
    if not ok then
        return false, result
    end
    local device = result.device
    if not device or device.role ~= "atm" then
        return false, "AtmRequired"
    end
    if identity.device_id and tostring(identity.device_id) ~= tostring(device.device_id) then
        return false, "DeviceMismatch"
    end
    return true, {
        account = result.account,
        device = device,
        device_id = device.device_id,
    }
end

local function require_viewer(database, sender, message, clients)
    if not database then
        return false, "DatabaseUnavailable"
    end
    local identity = session_identity(sender, message, clients)
    local ok, result = tesseracid.validate_session(database, identity.tesserac_id, identity.session_token, "account.identity")
    if not ok then
        return false, result
    end
    return true, result.account
end

local function normalize_coin_counts(counts)
    local out = {}
    for id, count in pairs(counts or {}) do
        out[tostring(id)] = math.max(0, math.floor(tonumber(count) or 0))
    end
    return out
end

local function append_alert(record, alert)
    record.alerts = record.alerts or {}
    record.alerts[#record.alerts + 1] = alert
    while #record.alerts > 25 do
        table.remove(record.alerts, 1)
    end
end

local function alert_key(alert)
    return tostring(alert.kind or "") .. ":" .. tostring(alert.coin or "")
end

local function send_official_alert(hypercube, official_owner, body)
    if not hypercube.phone or not hypercube.phone.system_alert then
        return false, "PhoneUnavailable"
    end
    local owner = tostring(official_owner or "")
    if owner ~= "" and not owner:match("^tid_") and hypercube.database then
        local ok, resolved = tesseracid.server_resolve_login(hypercube.database, { username = owner })
        if ok and resolved and resolved.tesserac_id then
            owner = resolved.tesserac_id
        end
    end
    return hypercube.phone:system_alert(owner, body, "Tesserac ATM")
end

local function process_alerts(hypercube, record, status)
    local official = tostring(status.official_account or record.official_account or "")
    if official == "" then
        return
    end

    local active = {}
    local alerts = {}
    local thresholds = status.thresholds or {}
    local coin_thresholds = thresholds.coins or {}
    local counts = status.coin_counts or {}
    for coin, min_count in pairs(coin_thresholds) do
        min_count = tonumber(min_count) or 0
        local count = tonumber(counts[coin] or 0) or 0
        if min_count > 0 and count < min_count then
            local alert = {
                kind = "coin_low",
                coin = tostring(coin),
                count = count,
                threshold = min_count,
                at = now(),
            }
            active[alert_key(alert)] = true
            alerts[#alerts + 1] = alert
        end
    end

    local balance_threshold = tonumber(thresholds.balance_high or 0) or 0
    local balance_units = tonumber(status.balance_units or 0) or 0
    if balance_threshold > 0 and (balance_units / 64) >= balance_threshold then
        local alert = {
            kind = "balance_high",
            balance = balance_units / 64,
            threshold = balance_threshold,
            at = now(),
        }
        active[alert_key(alert)] = true
        alerts[#alerts + 1] = alert
    end

    local previous = record.active_alerts or {}
    record.active_alerts = active
    for _, alert in ipairs(alerts) do
        local key = alert_key(alert)
        if not previous[key] then
            append_alert(record, alert)
            local label = tostring(record.label or record.device_id or "ATM")
            local body
            if alert.kind == "coin_low" then
                body = label .. " low " .. tostring(alert.coin) .. ": " .. tostring(alert.count) .. " left"
            else
                body = label .. " balance high: " .. tostring(alert.balance) .. " TC"
            end
            send_official_alert(hypercube, official, body)
        end
    end
end

local function public_record(record)
    if not record then
        return nil
    end
    return {
        device_id = record.device_id,
        owner = record.owner,
        label = record.label,
        official_account = record.official_account,
        balance_units = record.balance_units or 0,
        balance = (record.balance_units or 0) / 64,
        coin_counts = record.coin_counts or {},
        thresholds = record.thresholds or {},
        active_alerts = record.active_alerts or {},
        alerts = record.alerts or {},
        last_report_at = record.last_report_at,
    }
end

local function can_view(account, record)
    if not account or not record then
        return false
    end
    local id = tostring(account.tesserac_id or "")
    local username = tostring(account.username or "")
    local official = tostring(record.official_account or "")
    return id == tostring(record.owner or "")
        or username == tostring(record.owner_username or "")
        or id == official
        or username == official
end

local function report(hypercube, sender, message, clients)
    local ok, auth = require_atm_session(hypercube.database, sender, message, clients)
    if not ok then
        return false, auth
    end
    local existing = hypercube.database:get(atm_key(auth.device_id)) or {}
    local status = message.status or message
    local record = existing
    record.device_id = auth.device_id
    record.owner = auth.account and auth.account.tesserac_id or auth.device.owner
    record.owner_username = auth.account and auth.account.username or auth.device.username
    record.label = status.label or auth.device.label or record.label
    record.official_account = tostring(status.official_account or record.official_account or "")
    record.balance_units = math.max(0, math.floor(tonumber(status.balance_units or 0) or 0))
    record.coin_counts = normalize_coin_counts(status.coin_counts)
    record.thresholds = status.thresholds or record.thresholds or {}
    record.last_report_at = now()
    process_alerts(hypercube, record, status)
    local set_ok, set_err = hypercube.database:set(atm_key(auth.device_id), record)
    if not set_ok then
        return false, set_err
    end
    return true, public_record(record)
end

local function record_event(hypercube, sender, message, clients)
    local ok, auth = require_atm_session(hypercube.database, sender, message, clients)
    if not ok then
        return false, auth
    end
    local key = stats_key(auth.device_id, day_key(message.at))
    local stats = hypercube.database:get(key) or {
        device_id = auth.device_id,
        day = day_key(message.at),
        fee_units = 0,
        owner_fee_units = 0,
        official_fee_units = 0,
        deposits = 0,
        withdrawals = 0,
        maintenance_deposits = 0,
        maintenance_withdrawals = 0,
    }
    local kind = tostring(message.kind or "")
    if kind == "fee" then
        stats.fee_units = (stats.fee_units or 0) + math.max(0, math.floor(tonumber(message.fee_units or 0) or 0))
        stats.owner_fee_units = (stats.owner_fee_units or 0) + math.max(0, math.floor(tonumber(message.owner_fee_units or 0) or 0))
        stats.official_fee_units = (stats.official_fee_units or 0) + math.max(0, math.floor(tonumber(message.official_fee_units or 0) or 0))
    elseif kind == "deposit" then
        stats.deposits = (stats.deposits or 0) + 1
    elseif kind == "withdrawal" then
        stats.withdrawals = (stats.withdrawals or 0) + 1
    elseif kind == "maintenance_deposit" then
        stats.maintenance_deposits = (stats.maintenance_deposits or 0) + 1
    elseif kind == "maintenance_withdrawal" then
        stats.maintenance_withdrawals = (stats.maintenance_withdrawals or 0) + 1
    end
    stats.updated_at = now()
    local set_ok, set_err = hypercube.database:set(key, stats)
    if not set_ok then
        return false, set_err
    end
    return true, stats
end

local function status(hypercube, sender, message, clients)
    local ok, account = require_viewer(hypercube.database, sender, message, clients)
    if not ok then
        return false, account
    end
    local device_id = tostring(message.atm_device_id or message.device_id or "")
    if device_id == "" then
        return false, "DeviceRequired"
    end
    local record = hypercube.database:get(atm_key(device_id))
    if not record then
        return false, "AtmNotFound"
    end
    if not can_view(account, record) then
        return false, "AccessDenied"
    end
    local stats = hypercube.database:get(stats_key(device_id, day_key(now()))) or {}
    local public = public_record(record)
    public.stats_today = stats
    return true, public
end

function atm_monitor.install(hypercube)
    if not hypercube.network then
        return false, "NetworkUnavailable"
    end
    if not hypercube.database then
        return false, "DatabaseUnavailable"
    end
    if hypercube.atm_monitor_registered then
        return true
    end

    hypercube.network:register_handler("atm_monitor", function(network, sender, message)
        if type(message) ~= "table" or type(message.type) ~= "string" or message.type:sub(1, 4) ~= "atm." then
            return false
        end
        local ok, result
        if message.type == "atm.report" then
            ok, result = report(hypercube, sender, message, network.clients)
            reply(rednet, sender, network.protocol, "atm.report.result", ok, result)
        elseif message.type == "atm.event" then
            ok, result = record_event(hypercube, sender, message, network.clients)
            reply(rednet, sender, network.protocol, "atm.event.result", ok, result)
        elseif message.type == "atm.status" then
            ok, result = status(hypercube, sender, message, network.clients)
            reply(rednet, sender, network.protocol, "atm.status.result", ok, result)
        else
            reply(rednet, sender, network.protocol, "atm.error", false, "UnknownAtmRequest")
        end
        return true
    end)

    hypercube.atm_monitor_registered = true
    return true
end

return atm_monitor
