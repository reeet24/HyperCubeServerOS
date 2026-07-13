local banking = {}

local BankService = {}
BankService.__index = BankService
local AMOUNT_UNIT = 64

local function now()
    if os.epoch then
        return os.epoch("utc")
    end
    return math.floor(os.clock() * 1000)
end

local function require_owner(owner)
    owner = tostring(owner or "")
    if owner == "" then
        return nil, "AuthRequired"
    end
    return owner
end

local function account_key(owner)
    return "bank:account:" .. tostring(owner)
end

local function username_key(username)
    return "bank:username:" .. tostring(username)
end

local function minecraft_key(minecraft_name)
    return "bank:minecraft:" .. tostring(minecraft_name)
end

local function history_key(owner)
    return "bank:history:" .. tostring(owner)
end

local function deposit_key(source_device_id, deposit_id)
    return "bank:deposit:" .. tostring(source_device_id) .. ":" .. tostring(deposit_id)
end

local function withdrawal_key(source_device_id, withdrawal_id)
    return "bank:withdrawal:" .. tostring(source_device_id) .. ":" .. tostring(withdrawal_id)
end

local function atm_fee_key(source_device_id, fee_id)
    return "bank:atm_fee:" .. tostring(source_device_id) .. ":" .. tostring(fee_id)
end

local function normalize_username(username)
    username = tostring(username or ""):lower():gsub("%s+", "")
    username = username:gsub("[^%w_%-%.]", "")
    if username == "" or #username > 32 then
        return nil, "InvalidUsername"
    end
    return username
end

local function normalize_minecraft_name(minecraft_name)
    minecraft_name = tostring(minecraft_name or ""):gsub("%s+", "")
    minecraft_name = minecraft_name:gsub("[^%w_]", "")
    if minecraft_name == "" or #minecraft_name < 3 or #minecraft_name > 16 then
        return nil, "InvalidMinecraftName"
    end
    return minecraft_name
end

local function minecraft_lookup_key(minecraft_name)
    local normalized = normalize_minecraft_name(minecraft_name)
    if not normalized then
        return nil
    end
    return normalized:lower()
end

local function normalize_amount(amount)
    amount = tonumber(amount)
    if not amount or amount <= 0 then
        return nil, "InvalidAmount"
    end
    amount = math.floor(amount * AMOUNT_UNIT + 0.5) / AMOUNT_UNIT
    if amount <= 0 then
        return nil, "InvalidAmount"
    end
    return amount
end

local function add_amount(a, b)
    return math.floor(((a or 0) + (b or 0)) * AMOUNT_UNIT + 0.5) / AMOUNT_UNIT
end

local function subtract_amount(a, b)
    return math.floor(((a or 0) - (b or 0)) * AMOUNT_UNIT + 0.5) / AMOUNT_UNIT
end

local function normalize_deposit_id(deposit_id)
    deposit_id = tostring(deposit_id or ""):gsub("%s+", "")
    deposit_id = deposit_id:gsub("[^%w_%-%.:]", "")
    if deposit_id == "" or #deposit_id > 64 then
        return nil, "DepositIdRequired"
    end
    return deposit_id
end

local function normalize_withdrawal_id(withdrawal_id)
    withdrawal_id = tostring(withdrawal_id or ""):gsub("%s+", "")
    withdrawal_id = withdrawal_id:gsub("[^%w_%-%.:]", "")
    if withdrawal_id == "" or #withdrawal_id > 64 then
        return nil, "WithdrawalIdRequired"
    end
    return withdrawal_id
end

local function normalize_fee_id(fee_id)
    fee_id = tostring(fee_id or ""):gsub("%s+", "")
    fee_id = fee_id:gsub("[^%w_%-%.:]", "")
    if fee_id == "" or #fee_id > 64 then
        return nil, "FeeIdRequired"
    end
    return fee_id
end

local function amount_to_units(amount)
    return math.floor((tonumber(amount) or 0) * AMOUNT_UNIT + 0.5)
end

local function units_to_amount(units)
    return math.floor(tonumber(units) or 0) / AMOUNT_UNIT
end

local function public_account(record)
    if not record then
        return {
            open = false,
        }
    end
    return {
        open = true,
        bank_name = "Bank of Ba$h",
        account_id = record.account_id,
        owner = record.owner,
        username = record.username,
        minecraft_name = record.minecraft_name,
        balance = record.balance or 0,
        currency = record.currency or "TC",
        created_at = record.created_at,
        updated_at = record.updated_at,
    }
end

local function resolve_account(database, owner, username)
    owner = tostring(owner or "")
    username = tostring(username or "")

    if owner ~= "" then
        local direct = database:get(account_key(owner))
        if direct then
            return owner, direct
        end
    end

    if username ~= "" then
        local normalized = normalize_username(username)
        if normalized then
            local link = database:get(username_key(normalized))
            if link and link.owner then
                local linked = database:get(account_key(link.owner))
                if linked then
                    return link.owner, linked
                end
            end
            local by_username = database:get(account_key(normalized))
            if by_username then
                return normalized, by_username
            end
        end
    end

    return nil, nil
end

local function append_history(database, owner, entry)
    local record = database:get(history_key(owner)) or {
        owner = owner,
        transactions = {},
    }
    record.transactions = record.transactions or {}
    record.transactions[#record.transactions + 1] = entry
    while #record.transactions > 40 do
        table.remove(record.transactions, 1)
    end
    record.updated_at = now()
    database:set(history_key(owner), record)
end

function BankService.new(options)
    options = options or {}
    local self = setmetatable({}, BankService)
    self.database = options.database
    self.starting_balance = options.starting_balance or 0
    return self
end

function BankService:require_database()
    if not self.database then
        return false, "DatabaseUnavailable"
    end
    return true
end

function BankService:get_account(owner, username)
    local ok, err = self:require_database()
    if not ok then
        return false, err
    end
    owner, err = require_owner(owner)
    if not owner then
        return false, err
    end
    local _, account = resolve_account(self.database, owner, username)
    return true, account
end

function BankService:open(owner, username, minecraft_name)
    local ok, err = self:require_database()
    if not ok then
        return false, err
    end
    owner, err = require_owner(owner)
    if not owner then
        return false, err
    end
    local username_err
    username, username_err = normalize_username(username or owner)
    if not username then
        username = owner
    end
    local minecraft_err
    minecraft_name, minecraft_err = normalize_minecraft_name(minecraft_name)
    if not minecraft_name then
        return false, minecraft_err == "InvalidMinecraftName" and "MinecraftNameRequired" or minecraft_err
    end
    local minecraft_lookup = minecraft_lookup_key(minecraft_name)
    local minecraft_link = self.database:get(minecraft_key(minecraft_lookup))
    if minecraft_link and minecraft_link.owner and minecraft_link.owner ~= owner then
        return false, "MinecraftNameInUse"
    end

    local existing_owner, existing = resolve_account(self.database, owner, username)
    if existing then
        local changed = false
        if not existing.minecraft_name then
            existing.minecraft_name = minecraft_name
            changed = true
        end
        if changed then
            existing.updated_at = now()
            self.database:set(account_key(existing_owner), existing)
        end
        self.database:set(minecraft_key(minecraft_lookup), {
            owner = existing_owner,
            username = existing.username or username,
            minecraft_name = existing.minecraft_name or minecraft_name,
        })
        if existing_owner ~= owner then
            self.database:set(account_key(owner), existing)
        end
        return true, public_account(existing)
    end

    local record = {
        account_id = "tb_" .. tostring(now()) .. "_" .. tostring(math.floor((os.clock() or 0) * 1000)),
        owner = owner,
        username = username,
        minecraft_name = minecraft_name,
        balance = self.starting_balance,
        currency = "TC",
        bank_name = "Bank of Ba$h",
        created_at = now(),
        updated_at = now(),
        deposit_sources = {
            numismatics = {
                enabled = false,
                note = "Reserved for future Create: Numismatics conversion.",
            },
        },
    }

    local set_ok, set_err = self.database:set(account_key(owner), record)
    if not set_ok then
        return false, set_err
    end
    if username then
        self.database:set(username_key(username), {
            owner = owner,
            username = username,
        })
    end
    self.database:set(minecraft_key(minecraft_lookup), {
        owner = owner,
        username = username,
        minecraft_name = minecraft_name,
    })
    append_history(self.database, owner, {
        id = record.account_id .. ":open",
        kind = "open",
        direction = "in",
        amount = 0,
        balance = record.balance,
        memo = "Account opened",
        at = now(),
    })

    return true, public_account(record)
end

function BankService:lookup_by_minecraft(minecraft_name)
    local ok, err = self:require_database()
    if not ok then
        return false, err
    end
    local lookup = minecraft_lookup_key(minecraft_name)
    if not lookup then
        return false, "InvalidMinecraftName"
    end
    local link = self.database:get(minecraft_key(lookup))
    if not link or not link.owner then
        return false, "AccountNotFound"
    end
    local account = self.database:get(account_key(link.owner))
    if not account then
        return false, "AccountNotFound"
    end
    return true, public_account(account)
end

function BankService:close(owner, reason, closed_by)
    local ok, err = self:require_database()
    if not ok then
        return false, err
    end
    owner, err = require_owner(owner)
    if not owner then
        return false, err
    end
    local account = self.database:get(account_key(owner))
    if not account then
        return false, "AccountNotFound"
    end
    local closed = public_account(account)
    closed.closed_at = now()
    closed.closed_by = closed_by
    closed.close_reason = tostring(reason or "Closed by Tesserac moderation"):sub(1, 120)
    self.database:set("bank:closed:" .. tostring(owner), closed)
    self.database:delete(account_key(owner))
    if account.username then
        self.database:delete(username_key(account.username))
    end
    local lookup = minecraft_lookup_key(account.minecraft_name)
    if lookup then
        self.database:delete(minecraft_key(lookup))
    end
    append_history(self.database, owner, {
        id = tostring(account.account_id or owner) .. ":closed:" .. tostring(now()),
        kind = "closed",
        direction = "out",
        amount = 0,
        balance = account.balance or 0,
        memo = closed.close_reason,
        at = now(),
    })
    return true, closed
end

function BankService:status(owner, username)
    local ok, record = self:get_account(owner, username)
    if not ok then
        return false, record
    end
    return true, public_account(record)
end

function BankService:history(owner, username)
    local ok, err = self:require_database()
    if not ok then
        return false, err
    end
    owner, err = require_owner(owner)
    if not owner then
        return false, err
    end
    local resolved_owner = resolve_account(self.database, owner, username) or owner
    return true, self.database:get(history_key(resolved_owner)) or {
        owner = resolved_owner,
        transactions = {},
    }
end

function BankService:resolve_recipient(identifier)
    identifier = tostring(identifier or "")
    if identifier == "" then
        return nil, "RecipientRequired"
    end
    local direct = self.database:get(account_key(identifier))
    if direct then
        return identifier, direct
    end
    local username = normalize_username(identifier)
    if username then
        local link = self.database:get(username_key(username))
        if link and link.owner then
            local linked = self.database:get(account_key(link.owner))
            if linked then
                return link.owner, linked
            end
        end
    end
    return nil, "RecipientNotFound"
end

function BankService:transfer(owner, username, to_identifier, amount, memo)
    local ok, err = self:require_database()
    if not ok then
        return false, err
    end
    owner, err = require_owner(owner)
    if not owner then
        return false, err
    end
    amount, err = normalize_amount(amount)
    if not amount then
        return false, err
    end
    memo = tostring(memo or "Transfer"):sub(1, 80)

    local sender_owner, sender = resolve_account(self.database, owner, username)
    if not sender then
        return false, "AccountRequired"
    end
    owner = sender_owner
    if (sender.balance or 0) < amount then
        return false, "InsufficientFunds"
    end

    local recipient_owner, recipient = self:resolve_recipient(to_identifier)
    if not recipient_owner then
        return false, recipient
    end
    if recipient_owner == owner then
        return false, "CannotTransferToSelf"
    end

    sender.balance = subtract_amount(sender.balance, amount)
    sender.updated_at = now()
    recipient.balance = add_amount(recipient.balance, amount)
    recipient.updated_at = now()

    local tx_id = "tx_" .. tostring(now()) .. "_" .. tostring(math.floor((os.clock() or 0) * 1000))
    local set_sender, set_sender_err = self.database:set(account_key(owner), sender)
    if not set_sender then
        return false, set_sender_err
    end
    local set_recipient, set_recipient_err = self.database:set(account_key(recipient_owner), recipient)
    if not set_recipient then
        sender.balance = add_amount(sender.balance, amount)
        self.database:set(account_key(owner), sender)
        return false, set_recipient_err
    end

    append_history(self.database, owner, {
        id = tx_id,
        kind = "transfer",
        direction = "out",
        to = recipient_owner,
        amount = amount,
        balance = sender.balance,
        memo = memo,
        at = now(),
    })
    append_history(self.database, recipient_owner, {
        id = tx_id,
        kind = "transfer",
        direction = "in",
        from = owner,
        amount = amount,
        balance = recipient.balance,
        memo = memo,
        at = now(),
    })

    return true, {
        transaction_id = tx_id,
        account = public_account(sender),
        recipient = {
            owner = recipient.owner,
            username = recipient.username,
        },
    }
end

function BankService:credit(owner, amount, memo, source)
    local ok, err = self:require_database()
    if not ok then
        return false, err
    end
    owner, err = require_owner(owner)
    if not owner then
        return false, err
    end
    amount, err = normalize_amount(amount)
    if not amount then
        return false, err
    end

    local account = self.database:get(account_key(owner))
    if not account then
        return false, "AccountRequired"
    end
    account.balance = add_amount(account.balance, amount)
    account.updated_at = now()
    local set_ok, set_err = self.database:set(account_key(owner), account)
    if not set_ok then
        return false, set_err
    end
    append_history(self.database, owner, {
        id = "credit_" .. tostring(now()),
        kind = "credit",
        direction = "in",
        source = source or "digital",
        amount = amount,
        balance = account.balance,
        memo = memo or "Credit",
        at = now(),
    })
    return true, public_account(account)
end

function BankService:debit(owner, amount, memo, sink)
    local ok, err = self:require_database()
    if not ok then
        return false, err
    end
    owner, err = require_owner(owner)
    if not owner then
        return false, err
    end
    amount, err = normalize_amount(amount)
    if not amount then
        return false, err
    end

    local account = self.database:get(account_key(owner))
    if not account then
        return false, "AccountRequired"
    end
    if (account.balance or 0) < amount then
        return false, "InsufficientFunds"
    end

    account.balance = subtract_amount(account.balance, amount)
    account.updated_at = now()
    local set_ok, set_err = self.database:set(account_key(owner), account)
    if not set_ok then
        return false, set_err
    end
    append_history(self.database, owner, {
        id = "debit_" .. tostring(now()),
        kind = "debit",
        direction = "out",
        sink = sink or "service",
        amount = amount,
        balance = account.balance,
        memo = memo or "Debit",
        at = now(),
    })
    return true, public_account(account)
end

function BankService:deposit(source_device_id, to_identifier, amount, memo, deposit_id, source)
    local ok, err = self:require_database()
    if not ok then
        return false, err
    end
    source_device_id = tostring(source_device_id or "")
    if source_device_id == "" then
        return false, "TrustedServerRequired"
    end
    deposit_id, err = normalize_deposit_id(deposit_id)
    if not deposit_id then
        return false, err
    end
    amount, err = normalize_amount(amount)
    if not amount then
        return false, err
    end
    memo = tostring(memo or "Cash deposit"):sub(1, 80)
    source = tostring(source or "atm"):sub(1, 40)

    local key = deposit_key(source_device_id, deposit_id)
    local existing = self.database:get(key)
    if existing then
        if existing.result then
            return true, existing.result
        end
        return false, existing.status == "failed" and "DepositFailed" or "DepositPending"
    end

    local recipient_owner, recipient = self:resolve_recipient(to_identifier)
    if not recipient_owner then
        return false, recipient
    end

    local tx_id = "dep_" .. tostring(now()) .. "_" .. tostring(math.floor((os.clock() or 0) * 1000))
    local result = {
        transaction_id = tx_id,
        deposit_id = deposit_id,
        source_device_id = source_device_id,
        account = nil,
    }
    local reserve_ok, reserve_err = self.database:set(key, {
        source_device_id = source_device_id,
        deposit_id = deposit_id,
        recipient = recipient_owner,
        amount = amount,
        memo = memo,
        source = source,
        status = "pending",
        at = now(),
    })
    if not reserve_ok then
        return false, reserve_err
    end

    recipient.balance = add_amount(recipient.balance, amount)
    recipient.updated_at = now()

    local set_ok, set_err = self.database:set(account_key(recipient_owner), recipient)
    if not set_ok then
        self.database:set(key, {
            source_device_id = source_device_id,
            deposit_id = deposit_id,
            recipient = recipient_owner,
            amount = amount,
            memo = memo,
            source = source,
            status = "failed",
            error = set_err,
            at = now(),
        })
        return false, set_err
    end

    append_history(self.database, recipient_owner, {
        id = tx_id,
        kind = "deposit",
        direction = "in",
        source = source,
        source_device_id = source_device_id,
        deposit_id = deposit_id,
        amount = amount,
        balance = recipient.balance,
        memo = memo,
        at = now(),
    })

    result.account = public_account(recipient)
    self.database:set(key, {
        source_device_id = source_device_id,
        deposit_id = deposit_id,
        recipient = recipient_owner,
        amount = amount,
        memo = memo,
        source = source,
        status = "complete",
        result = result,
        at = now(),
    })
    return true, result
end

function BankService:withdraw(source_device_id, from_identifier, amount, memo, withdrawal_id, source)
    local ok, err = self:require_database()
    if not ok then
        return false, err
    end
    source_device_id = tostring(source_device_id or "")
    if source_device_id == "" then
        return false, "TrustedServerRequired"
    end
    withdrawal_id, err = normalize_withdrawal_id(withdrawal_id)
    if not withdrawal_id then
        return false, err
    end
    amount, err = normalize_amount(amount)
    if not amount then
        return false, err
    end
    memo = tostring(memo or "ATM Withdraw"):sub(1, 80)
    source = tostring(source or "atm"):sub(1, 40)

    local key = withdrawal_key(source_device_id, withdrawal_id)
    local existing = self.database:get(key)
    if existing then
        if existing.result then
            return true, existing.result
        end
        return false, existing.status == "failed" and "WithdrawalFailed" or "WithdrawalPending"
    end

    local owner, account = self:resolve_recipient(from_identifier)
    if not owner then
        return false, account
    end
    if (account.balance or 0) < amount then
        return false, "InsufficientFunds"
    end

    local tx_id = "atmwd_" .. tostring(now()) .. "_" .. tostring(math.floor((os.clock() or 0) * 1000))
    local reserve_ok, reserve_err = self.database:set(key, {
        source_device_id = source_device_id,
        withdrawal_id = withdrawal_id,
        owner = owner,
        amount = amount,
        memo = memo,
        source = source,
        status = "pending",
        at = now(),
    })
    if not reserve_ok then
        return false, reserve_err
    end

    account.balance = subtract_amount(account.balance, amount)
    account.updated_at = now()
    local set_ok, set_err = self.database:set(account_key(owner), account)
    if not set_ok then
        self.database:set(key, {
            source_device_id = source_device_id,
            withdrawal_id = withdrawal_id,
            owner = owner,
            amount = amount,
            memo = memo,
            source = source,
            status = "failed",
            error = set_err,
            at = now(),
        })
        return false, set_err
    end

    append_history(self.database, owner, {
        id = tx_id,
        kind = "withdrawal",
        direction = "out",
        source = source,
        source_device_id = source_device_id,
        withdrawal_id = withdrawal_id,
        amount = amount,
        balance = account.balance,
        memo = memo,
        at = now(),
    })

    local result = {
        transaction_id = tx_id,
        withdrawal_id = withdrawal_id,
        source_device_id = source_device_id,
        account = public_account(account),
    }
    self.database:set(key, {
        source_device_id = source_device_id,
        withdrawal_id = withdrawal_id,
        owner = owner,
        amount = amount,
        memo = memo,
        source = source,
        status = "complete",
        result = result,
        at = now(),
    })
    return true, result
end

function BankService:atm_fee(source_device_id, from_identifier, amount, owner_identifier, official_identifier, fee_id, memo)
    local ok, err = self:require_database()
    if not ok then
        return false, err
    end
    source_device_id = tostring(source_device_id or "")
    if source_device_id == "" then
        return false, "TrustedServerRequired"
    end
    fee_id, err = normalize_fee_id(fee_id)
    if not fee_id then
        return false, err
    end
    amount, err = normalize_amount(amount)
    if not amount then
        return false, err
    end
    memo = tostring(memo or "ATM Fee"):sub(1, 80)

    local key = atm_fee_key(source_device_id, fee_id)
    local existing = self.database:get(key)
    if existing then
        if existing.result then
            return true, existing.result
        end
        return false, existing.status == "failed" and "AtmFeeFailed" or "AtmFeePending"
    end

    local payer_owner, payer = self:resolve_recipient(from_identifier)
    if not payer_owner then
        return false, payer
    end
    local owner_owner, owner_account = self:resolve_recipient(owner_identifier)
    if not owner_owner then
        return false, owner_account
    end
    local official_owner, official_account = self:resolve_recipient(official_identifier)
    if not official_owner then
        return false, official_account
    end

    local fee_units = amount_to_units(amount)
    local official_units = math.floor(fee_units / 3)
    local owner_units = fee_units - official_units
    local deltas = {}
    deltas[payer_owner] = (deltas[payer_owner] or 0) - fee_units
    deltas[owner_owner] = (deltas[owner_owner] or 0) + owner_units
    deltas[official_owner] = (deltas[official_owner] or 0) + official_units

    local accounts = {
        [payer_owner] = payer,
        [owner_owner] = owner_account,
        [official_owner] = official_account,
    }
    for owner, delta_units in pairs(deltas) do
        local balance_units = amount_to_units(accounts[owner].balance or 0)
        if balance_units + delta_units < 0 then
            return false, "InsufficientFunds"
        end
    end

    local tx_id = "atmfee_" .. tostring(now()) .. "_" .. tostring(math.floor((os.clock() or 0) * 1000))
    local reserve_ok, reserve_err = self.database:set(key, {
        source_device_id = source_device_id,
        fee_id = fee_id,
        payer = payer_owner,
        owner = owner_owner,
        official = official_owner,
        amount = amount,
        status = "pending",
        at = now(),
    })
    if not reserve_ok then
        return false, reserve_err
    end

    for owner, delta_units in pairs(deltas) do
        local account = accounts[owner]
        account.balance = units_to_amount(amount_to_units(account.balance or 0) + delta_units)
        account.updated_at = now()
        local set_ok, set_err = self.database:set(account_key(owner), account)
        if not set_ok then
            self.database:set(key, {
                source_device_id = source_device_id,
                fee_id = fee_id,
                payer = payer_owner,
                owner = owner_owner,
                official = official_owner,
                amount = amount,
                status = "failed",
                error = set_err,
                at = now(),
            })
            return false, set_err
        end
    end

    append_history(self.database, payer_owner, {
        id = tx_id,
        kind = "atm_fee",
        direction = "out",
        source_device_id = source_device_id,
        amount = amount,
        balance = payer.balance,
        memo = memo,
        at = now(),
    })
    if owner_units > 0 then
        append_history(self.database, owner_owner, {
            id = tx_id,
            kind = "atm_fee_share",
            direction = "in",
            source_device_id = source_device_id,
            from = payer_owner,
            amount = units_to_amount(owner_units),
            balance = owner_account.balance,
            memo = "ATM owner fee share",
            at = now(),
        })
    end
    if official_units > 0 then
        append_history(self.database, official_owner, {
            id = tx_id,
            kind = "atm_fee_share",
            direction = "in",
            source_device_id = source_device_id,
            from = payer_owner,
            amount = units_to_amount(official_units),
            balance = official_account.balance,
            memo = "Tesserac ATM fee share",
            at = now(),
        })
    end

    local result = {
        transaction_id = tx_id,
        fee_id = fee_id,
        amount = amount,
        owner_amount = units_to_amount(owner_units),
        official_amount = units_to_amount(official_units),
        account = public_account(payer),
    }
    self.database:set(key, {
        source_device_id = source_device_id,
        fee_id = fee_id,
        payer = payer_owner,
        owner = owner_owner,
        official = official_owner,
        amount = amount,
        status = "complete",
        result = result,
        at = now(),
    })
    return true, result
end

function banking.new(options)
    return BankService.new(options)
end

banking.BankService = BankService

return banking
