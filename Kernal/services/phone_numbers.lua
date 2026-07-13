local phone_numbers = {}

local WEEK_MS = 7 * 24 * 60 * 60 * 1000
local DEFAULT_BILL = 25

local PhoneService = {}
PhoneService.__index = PhoneService

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
    return (b * 65536 + a) % 2147483647
end

local function account_key(tesserac_id)
    return "phone:account:" .. tostring(tesserac_id)
end

local function number_key(number)
    return "phone:number:" .. tostring(number)
end

local function inbox_key(tesserac_id)
    return "phone:inbox:" .. tostring(tesserac_id)
end

local function chats_key(tesserac_id)
    return "phone:chats:" .. tostring(tesserac_id)
end

local function normalize_number(number)
    number = tostring(number or ""):gsub("%D", "")
    if #number ~= 6 then
        return nil, "InvalidPhoneNumber"
    end
    return number
end

local function require_owner(owner)
    if not owner or owner == "" then
        return nil, "AuthRequired"
    end
    return tostring(owner)
end

local function append_chat_message(chats, number, message)
    chats.chats = chats.chats or {}
    local chat = chats.chats[number] or {
        number = number,
        messages = {},
        unread = 0,
        updated_at = now(),
    }
    chat.messages = chat.messages or {}
    chat.messages[#chat.messages + 1] = message
    while #chat.messages > 80 do
        table.remove(chat.messages, 1)
    end
    chat.last_message = message.body
    chat.last_at = message.sent_at
    chat.updated_at = now()
    if message.direction == "in" and message.read ~= true then
        chat.unread = (chat.unread or 0) + 1
    end
    chats.chats[number] = chat
end

function PhoneService.new(options)
    options = options or {}
    local self = setmetatable({}, PhoneService)
    self.database = options.database
    self.bank = options.bank
    self.weekly_bill = options.weekly_bill or DEFAULT_BILL
    return self
end

function PhoneService:require_database()
    if not self.database then
        return false, "DatabaseUnavailable"
    end
    return true
end

function PhoneService:find_free_number(owner)
    local seed = checksum(owner)
    for i = 0, 999999 do
        local candidate = string.format("%06d", (seed + i * 7919) % 1000000)
        local existing = self.database:get(number_key(candidate))
        if not existing then
            return candidate
        end
    end
    return nil, "NoNumbersAvailable"
end

function PhoneService:set_bank(bank)
    self.bank = bank
    return self
end

function PhoneService:require_bank_account(owner)
    if not self.bank or not self.bank.status then
        return false, "BankAccountRequired"
    end
    local ok, account = self.bank:status(owner)
    if not ok then
        if account == "AccountRequired" or account == "AuthRequired" then
            return false, "BankAccountRequired"
        end
        return false, account
    end
    if not account or account.open ~= true then
        return false, "BankAccountRequired"
    end
    return true, account
end

function PhoneService:charge_renewal(owner)
    local ok, account = self:require_bank_account(owner)
    if not ok then
        return false, account
    end
    if not self.bank.debit then
        return false, "BankAccountRequired"
    end
    local charged, result = self.bank:debit(owner, self.weekly_bill, "Tesserac Phone weekly service", "phone")
    if not charged then
        if result == "AccountRequired" then
            return false, "BankAccountRequired"
        end
        return false, result
    end
    return true, result or account
end

function PhoneService:status(owner)
    local ok, db_err = self:require_database()
    if not ok then
        return false, db_err
    end
    owner = require_owner(owner)
    if not owner then
        return false, "AuthRequired"
    end

    local record = self.database:get(account_key(owner))
    if not record then
        return true, {
            active = false,
            has_number = false,
            bill_due = true,
            weekly_bill = self.weekly_bill,
        }
    end

    local active = (record.paid_until or 0) > now()
    record.has_number = record.number ~= nil
    record.active = active
    record.bill_due = not active
    record.weekly_bill = self.weekly_bill
    local bank_ok = self:require_bank_account(owner)
    record.bank_account_linked = bank_ok == true
    return true, record
end

function PhoneService:subscribe(owner)
    local ok, db_err = self:require_database()
    if not ok then
        return false, db_err
    end
    owner = require_owner(owner)
    if not owner then
        return false, "AuthRequired"
    end

    local record = self.database:get(account_key(owner))
    if record and record.number then
        return self:pay(owner)
    end

    local bank_ok, bank_err = self:require_bank_account(owner)
    if not bank_ok then
        return false, bank_err
    end

    local number, number_err = self:find_free_number(owner)
    if not number then
        return false, number_err
    end

    record = {
        owner = owner,
        number = number,
        created_at = now(),
        paid_until = now() + WEEK_MS,
        weekly_bill = self.weekly_bill,
        first_week_free = true,
    }

    local set_ok, set_err = self.database:set(account_key(owner), record)
    if not set_ok then
        return false, set_err
    end
    local number_ok, number_err = self.database:set(number_key(number), {
        number = number,
        owner = owner,
        created_at = record.created_at,
    })
    if not number_ok then
        return false, number_err
    end
    local inbox_ok, inbox_err = self.database:set(inbox_key(owner), {
        owner = owner,
        messages = {},
    })
    if not inbox_ok then
        return false, inbox_err
    end
    local chats_ok, chats_err = self.database:set(chats_key(owner), {
        owner = owner,
        chats = {},
    })
    if not chats_ok then
        return false, chats_err
    end

    record.active = true
    record.has_number = true
    record.bill_due = false
    record.bank_account_linked = true
    return true, record
end

function PhoneService:pay(owner)
    local ok, db_err = self:require_database()
    if not ok then
        return false, db_err
    end
    owner = require_owner(owner)
    if not owner then
        return false, "AuthRequired"
    end

    local record = self.database:get(account_key(owner))
    if not record then
        return false, "NoPhoneNumber"
    end

    local charge_ok, charge_err = self:charge_renewal(owner)
    if not charge_ok then
        return false, charge_err
    end

    local base = math.max(record.paid_until or 0, now())
    record.paid_until = base + WEEK_MS
    record.last_payment_at = now()
    record.weekly_bill = self.weekly_bill
    record.bank_account_linked = true
    local set_ok, set_err = self.database:set(account_key(owner), record)
    if not set_ok then
        return false, set_err
    end

    record.active = true
    record.has_number = true
    record.bill_due = false
    return true, record
end

function PhoneService:send(owner, to_number, body)
    local ok, db_err = self:require_database()
    if not ok then
        return false, db_err
    end
    owner = require_owner(owner)
    if not owner then
        return false, "AuthRequired"
    end

    to_number = normalize_number(to_number)
    if not to_number then
        return false, "InvalidPhoneNumber"
    end
    body = tostring(body or "")
    if body == "" then
        return false, "EmptyMessage"
    end
    if #body > 240 then
        body = body:sub(1, 240)
    end

    local sender = self.database:get(account_key(owner))
    if not sender or not sender.number then
        return false, "NoPhoneNumber"
    end
    if (sender.paid_until or 0) <= now() then
        return false, "PhoneBillDue"
    end

    local recipient_link = self.database:get(number_key(to_number))
    if not recipient_link then
        return false, "NumberNotFound"
    end
    local recipient = self.database:get(account_key(recipient_link.owner))
    if not recipient or (recipient.paid_until or 0) <= now() then
        return false, "RecipientInactive"
    end

    local sent_at = now()
    local message_id = tostring(sent_at) .. ":" .. tostring(checksum(owner .. ":" .. to_number .. ":" .. body))
    local sender_chats = self.database:get(chats_key(owner)) or {
        owner = owner,
        chats = {},
    }
    append_chat_message(sender_chats, to_number, {
        id = message_id,
        direction = "out",
        from = sender.number,
        to = to_number,
        body = body,
        sent_at = sent_at,
        read = true,
    })
    local sender_ok, sender_err = self.database:set(chats_key(owner), sender_chats)
    if not sender_ok then
        return false, sender_err
    end

    local inbox = self.database:get(inbox_key(recipient.owner)) or {
        owner = recipient.owner,
        messages = {},
    }
    inbox.messages = inbox.messages or {}
    local message = {
        id = message_id,
        from = sender.number,
        to = to_number,
        body = body,
        sent_at = sent_at,
        read = false,
    }
    inbox.messages[#inbox.messages + 1] = message
    while #inbox.messages > 80 do
        table.remove(inbox.messages, 1)
    end
    local inbox_ok, inbox_err = self.database:set(inbox_key(recipient.owner), inbox)
    if not inbox_ok then
        return false, inbox_err
    end

    return true, {
        id = message_id,
        direction = "out",
        from = sender.number,
        to = to_number,
        body = body,
        sent_at = sent_at,
        read = true,
    }
end

function PhoneService:system_alert(owner, body, from_label)
    local ok, db_err = self:require_database()
    if not ok then
        return false, db_err
    end
    owner = require_owner(owner)
    if not owner then
        return false, "AuthRequired"
    end
    body = tostring(body or "")
    if body == "" then
        return false, "EmptyMessage"
    end
    if #body > 240 then
        body = body:sub(1, 240)
    end

    local recipient = self.database:get(account_key(owner))
    if not recipient or not recipient.number then
        return false, "NoPhoneNumber"
    end
    if (recipient.paid_until or 0) <= now() then
        return false, "PhoneBillDue"
    end

    local sent_at = now()
    local from = "000000"
    if from_label and from_label ~= "" then
        body = tostring(from_label) .. ": " .. body
        if #body > 240 then
            body = body:sub(1, 240)
        end
    end
    local message_id = tostring(sent_at) .. ":" .. tostring(checksum(owner .. ":" .. from .. ":" .. body))
    local inbox = self.database:get(inbox_key(owner)) or {
        owner = owner,
        messages = {},
    }
    inbox.messages = inbox.messages or {}
    inbox.messages[#inbox.messages + 1] = {
        id = message_id,
        from = from,
        to = recipient.number,
        body = body,
        sent_at = sent_at,
        read = false,
    }
    while #inbox.messages > 80 do
        table.remove(inbox.messages, 1)
    end
    local inbox_ok, inbox_err = self.database:set(inbox_key(owner), inbox)
    if not inbox_ok then
        return false, inbox_err
    end
    return true, {
        id = message_id,
        from = from,
        to = recipient.number,
        body = body,
        sent_at = sent_at,
    }
end

function PhoneService:sync(owner)
    local ok, db_err = self:require_database()
    if not ok then
        return false, db_err
    end
    owner = require_owner(owner)
    if not owner then
        return false, "AuthRequired"
    end

    local status_ok, status = self:status(owner)
    if not status_ok then
        return false, status
    end
    if not status.has_number then
        return false, "NoPhoneNumber"
    end
    if not status.active then
        return false, "PhoneBillDue"
    end

    local inbox = self.database:get(inbox_key(owner)) or {
        owner = owner,
        messages = {},
    }
    local chats = self.database:get(chats_key(owner)) or {
        owner = owner,
        chats = {},
    }
    local synced = 0
    for _, message in ipairs(inbox.messages or {}) do
        append_chat_message(chats, tostring(message.from), {
            id = message.id,
            direction = "in",
            from = message.from,
            to = message.to,
            body = message.body,
            sent_at = message.sent_at,
            read = message.read == true,
        })
        synced = synced + 1
    end
    if synced > 0 then
        inbox.messages = {}
        local chats_ok, chats_err = self.database:set(chats_key(owner), chats)
        if not chats_ok then
            return false, chats_err
        end
        local inbox_ok, inbox_err = self.database:set(inbox_key(owner), inbox)
        if not inbox_ok then
            return false, inbox_err
        end
    end
    return true, {
        synced = synced,
        chats = chats,
    }
end

function PhoneService:inbox(owner)
    local ok, result = self:sync(owner)
    if not ok then
        return false, result
    end
    return true, {
        owner = owner,
        messages = {},
        synced = result.synced,
    }
end

function PhoneService:chats(owner)
    local ok, result = self:sync(owner)
    if not ok then
        return false, result
    end
    local out = {}
    for number, chat in pairs(result.chats.chats or {}) do
        out[#out + 1] = {
            number = number,
            last_message = chat.last_message,
            last_at = chat.last_at,
            unread = chat.unread or 0,
            message_count = #(chat.messages or {}),
        }
    end
    table.sort(out, function(a, b)
        return tostring(a.last_at or 0) > tostring(b.last_at or 0)
    end)
    return true, {
        synced = result.synced,
        chats = out,
    }
end

function PhoneService:chat(owner, number, mark_read)
    owner = require_owner(owner)
    if not owner then
        return false, "AuthRequired"
    end
    number = normalize_number(number)
    if not number then
        return false, "InvalidPhoneNumber"
    end
    local ok, result = self:sync(owner)
    if not ok then
        return false, result
    end
    local chat = (result.chats.chats or {})[number] or {
        number = number,
        messages = {},
        unread = 0,
    }
    if mark_read ~= false and (chat.unread or 0) > 0 then
        chat.unread = 0
        result.chats.chats[number] = chat
        self.database:set(chats_key(owner), result.chats)
    end
    return true, {
        number = number,
        messages = chat.messages or {},
        unread = chat.unread or 0,
    }
end

function PhoneService:delete_chat(owner, number)
    owner = require_owner(owner)
    if not owner then
        return false, "AuthRequired"
    end
    number = normalize_number(number)
    if not number then
        return false, "InvalidPhoneNumber"
    end
    local chats = self.database:get(chats_key(owner)) or {
        owner = owner,
        chats = {},
    }
    chats.chats = chats.chats or {}
    chats.chats[number] = nil
    local ok, err = self.database:set(chats_key(owner), chats)
    return ok, ok and { number = number } or err
end

function phone_numbers.new(options)
    return PhoneService.new(options)
end

phone_numbers.PhoneService = PhoneService

return phone_numbers
