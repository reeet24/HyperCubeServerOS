local banking = require("Kernal.services.banking")
local tesseracid = require("Kernal.services.tesseracid")

local banking_server = {}
local ADMIN_TOKEN_PATH = "banking/admin_token"

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function message_identity(sender, message, clients)
    return message.tesserac_id or (clients and clients[sender] and clients[sender].tesserac_id)
end

local function message_username(sender, message, clients)
    return message.username or (clients and clients[sender] and clients[sender].username)
end

local function session_identity(sender, message, clients)
    local client = clients and clients[sender] or {}
    return {
        tesserac_id = message.tesserac_id or client.tesserac_id,
        session_token = message.session_token or client.session_token,
        device_id = message.device_id or client.device_id,
    }
end

local function trusted_depositor_key(device_id)
    return "bank:trusted_depositor:" .. tostring(device_id or "")
end

local function read_admin_token()
    if not fs or not fs.exists or not fs.open or not fs.exists(ADMIN_TOKEN_PATH) then
        return nil
    end
    local handle = fs.open(ADMIN_TOKEN_PATH, "r")
    if not handle then
        return nil
    end
    local data = tostring(handle.readAll() or ""):match("^%s*(.-)%s*$")
    handle.close()
    if data == "" then
        return nil
    end
    return data
end

local function require_admin_token(message)
    local expected = read_admin_token()
    if not expected then
        return false, "AdminTokenUnavailable"
    end
    if tostring(message.admin_token or message.token or "") ~= expected then
        return false, "TokenRequired"
    end
    return true
end

local function require_trusted_depositor(database, sender, message, clients)
    if not database then
        return false, "DatabaseUnavailable"
    end
    local identity = session_identity(sender, message, clients)
    local ok, result = tesseracid.validate_session(database, identity.tesserac_id, identity.session_token, "bank.deposit")
    if not ok then
        return false, result
    end
    local device = result.device
    local device_id = device and device.device_id
    if not device_id or device_id == "" then
        return false, "TrustedServerRequired"
    end
    if device.role ~= "bank_branch" and device.role ~= "atm" then
        return false, "TrustedServerRequired"
    end
    if not result.account or result.account.account_type ~= "business" then
        return false, "BusinessAccountRequired"
    end
    local trust = database:get(trusted_depositor_key(device_id))
    if not trust or trust.enabled == false then
        return false, "TrustedServerRequired"
    end
    return true, {
        device_id = device_id,
        trust = trust,
        account = result.account,
        device = device,
    }
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

function banking_server.install(hypercube)
    local logger = hypercube.logger
    if not hypercube.database then
        if logger then
            logger.warn("banking server unavailable: DatabaseUnavailable", hypercube.root_context)
        end
        return false, "DatabaseUnavailable"
    end
    if not hypercube.network then
        if logger then
            logger.warn("banking server unavailable: NetworkUnavailable", hypercube.root_context)
        end
        return false, "NetworkUnavailable"
    end

    if hypercube.bank and hypercube.bank_handler_registered then
        return true, hypercube.bank
    end

    local bank = hypercube.bank or banking.new({
        database = hypercube.database,
        starting_balance = 0,
    })
    hypercube.bank = bank

    hypercube.network:register_handler("banking", function(network, sender, message)
        if type(message) ~= "table" or type(message.type) ~= "string" or message.type:sub(1, 5) ~= "bank." then
            return false
        end

        local owner = message_identity(sender, message, network.clients)
        local username = message_username(sender, message, network.clients)
        local account_name = message.account_name or message.account or message.name
        local ok, result = false, "UnknownBankRequest"

        if message.type == "bank.open" then
            ok, result = bank:open(owner, username, message.minecraft_name or message.minecraft or message.mc_name, account_name)
            reply(rednet, sender, network.protocol, "bank.open.result", ok, result)
        elseif message.type == "bank.status" then
            ok, result = bank:status(owner, username, account_name)
            reply(rednet, sender, network.protocol, "bank.status.result", ok, result)
        elseif message.type == "bank.history" then
            ok, result = bank:history(owner, username, account_name)
            reply(rednet, sender, network.protocol, "bank.history.result", ok, result)
        elseif message.type == "bank.transfer" then
            ok, result = bank:transfer(owner, username, message.to, message.amount, message.memo, account_name)
            reply(rednet, sender, network.protocol, "bank.transfer.result", ok, result)
        elseif message.type == "bank.purchase" then
            ok, result = bank:purchase(
                owner,
                username,
                message.to or message.merchant or message.seller,
                message.amount,
                message.item_id or message.item,
                message.purchase_id,
                message.memo,
                message.app_id,
                account_name
            )
            reply(rednet, sender, network.protocol, "bank.purchase.result", ok, result)
        elseif message.type == "bank.credit" then
            ok, result = false, "PhysicalDepositNotEnabled"
            reply(rednet, sender, network.protocol, "bank.credit.result", ok, result)
        elseif message.type == "bank.deposit" then
            local trusted
            ok, trusted = require_trusted_depositor(hypercube.database, sender, message, network.clients)
            if ok then
                ok, result = bank:deposit(trusted.device_id, message.to or message.recipient, message.amount, message.memo, message.deposit_id, message.source)
            else
                result = trusted
            end
            reply(rednet, sender, network.protocol, "bank.deposit.result", ok, result)
        elseif message.type == "bank.withdraw" then
            local trusted
            ok, trusted = require_trusted_depositor(hypercube.database, sender, message, network.clients)
            if ok then
                ok, result = bank:withdraw(trusted.device_id, message.from or message.owner or message.account, message.amount, message.memo, message.withdrawal_id, message.source)
            else
                result = trusted
            end
            reply(rednet, sender, network.protocol, "bank.withdraw.result", ok, result)
        elseif message.type == "bank.atm.fee" then
            local trusted
            ok, trusted = require_trusted_depositor(hypercube.database, sender, message, network.clients)
            if ok then
                ok, result = bank:atm_fee(
                    trusted.device_id,
                    message.from or message.owner or message.account,
                    message.amount,
                    message.atm_owner,
                    message.official_account,
                    message.fee_id,
                    message.memo
                )
            else
                result = trusted
            end
            reply(rednet, sender, network.protocol, "bank.atm.fee.result", ok, result)
        elseif message.type == "bank.branch.trust" then
            ok, result = require_admin_token(message)
            if ok then
                local device_id = tostring(message.device_id or "")
                if device_id == "" then
                    ok, result = false, "DeviceRequired"
                else
                    result = {
                        device_id = device_id,
                        label = message.label,
                        enabled = true,
                        trusted_at = now(),
                    }
                    ok, result = hypercube.database:set(trusted_depositor_key(device_id), result)
                    if ok then
                        result = hypercube.database:get(trusted_depositor_key(device_id))
                    end
                end
            end
            reply(rednet, sender, network.protocol, "bank.branch.trust.result", ok, result)
        elseif message.type == "bank.branch.revoke" then
            ok, result = require_admin_token(message)
            if ok then
                local device_id = tostring(message.device_id or "")
                if device_id == "" then
                    ok, result = false, "DeviceRequired"
                else
                    ok, result = hypercube.database:set(trusted_depositor_key(device_id), {
                        device_id = device_id,
                        enabled = false,
                        revoked_at = now(),
                    })
                    if ok then
                        result = { device_id = device_id, enabled = false }
                    end
                end
            end
            reply(rednet, sender, network.protocol, "bank.branch.revoke.result", ok, result)
        else
            reply(rednet, sender, network.protocol, "bank.error", false, result)
        end

        if logger then
            local level = ok and "debug" or "warn"
            logger[level]("banking " .. tostring(message.type) .. " sender=" .. tostring(sender) .. " ok=" .. tostring(ok)
                .. (ok and "" or " error=" .. tostring(result)), hypercube.root_context)
        end
        return true
    end)
    hypercube.bank_handler_registered = true

    if logger then
        logger.info("Bank of Ba$h HyperNet API registered", hypercube.root_context)
    end
    return true, bank
end

function banking_server.start(hypercube)
    local ok, err = banking_server.install(hypercube)
    if not ok then
        return false, err
    end

    if hypercube.logger then
        hypercube.logger.info("Bank of Ba$h process started", hypercube.root_context)
    end

    while true do
        coroutine.yield("tick")
    end
end

return banking_server
