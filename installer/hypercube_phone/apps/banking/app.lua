local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "Bank of Ba$h",
        label = "Bank",
        color = C.green,
        dock = true,
        render_mode = "exclusive",
        refresh_rate = 8,
    },
}

local AUTO_REFRESH_MS = 10000

local function truncate(text, width)
    text = tostring(text or "")
    width = math.max(1, tonumber(width) or 1)
    if #text <= width then
        return text
    end
    if width <= 3 then
        return text:sub(1, width)
    end
    return text:sub(1, width - 3) .. "..."
end

local function write_line(ctx, row, text, fg, bg)
    api.screen.write(ctx.x, ctx.y + row, truncate(text, ctx.width), fg or C.white, bg or C.black)
end

local function field_value(state, field)
    return tostring(state[field] or "")
end

local function normalize_amount(value)
    local amount = tonumber(value)
    if not amount or amount <= 0 then
        return nil
    end
    return math.floor(amount * 64 + 0.5) / 64
end

local function request(message, expected)
    if not api.hypernet or not api.hypernet.request then
        return nil, "HyperNetUnavailable"
    end
    local ok, reply, err = pcall(api.hypernet.request, message, expected, 8)
    if not ok then
        return nil, reply
    end
    return reply, err
end

local function ensure_state(state)
    if state.ready then
        return
    end
    state.ready = true
    state.loaded = false
    state.view = "loading"
    state.focus = "account_name"
    state.account_name = api.fs.read("bank_account_name.txt") or "main"
    state.minecraft_name = api.fs.read("minecraft_name.txt") or ""
    state.transfer_to = ""
    state.transfer_amount = ""
    state.transfer_memo = ""
    state.error = nil
    state.status = nil
    state.account = nil
    state.last_auto_refresh = 0
end

local function refresh(state)
    local reply, err = request({
        type = "bank.status",
        account_name = state.account_name,
    }, "bank.status.result")

    state.loaded = true
    if reply and reply.ok and reply.result and reply.result.open then
        state.account = reply.result
        if not reply.result.minecraft_name or reply.result.minecraft_name == "" then
            state.view = "open"
            state.status = "Minecraft name required"
            state.focus = "minecraft_name"
        else
            state.view = state.view == "transfer" and "transfer" or "home"
        end
        state.error = nil
    else
        state.account = nil
        state.view = "open"
        state.error = (reply and reply.error ~= "AccountRequired" and reply.error) or nil
    end
end

local function open_account(state)
    local account_name = field_value(state, "account_name")
    if account_name == "" then
        account_name = "main"
    end
    local minecraft_name = field_value(state, "minecraft_name")
    if minecraft_name == "" then
        state.error = "Minecraft name required"
        state.focus = "minecraft_name"
        return
    end
    local reply, err = request({
        type = "bank.open",
        account_name = account_name,
        minecraft_name = minecraft_name,
    }, "bank.open.result")
    if reply and reply.ok then
        api.fs.write("bank_account_name.txt", account_name)
        api.fs.write("minecraft_name.txt", minecraft_name)
        state.account = reply.result
        state.view = "home"
        state.error = nil
        state.status = "Account opened"
    else
        state.error = (reply and reply.error) or err or "OpenFailed"
    end
end

local function transfer(state)
    local amount = normalize_amount(state.transfer_amount)
    if field_value(state, "transfer_to") == "" then
        state.error = "Recipient required"
        state.focus = "transfer_to"
        return
    end
    if not amount then
        state.error = "Invalid amount"
        state.focus = "transfer_amount"
        return
    end
    local reply, err = request({
        type = "bank.transfer",
        account_name = state.account_name,
        to = state.transfer_to,
        amount = amount,
        memo = state.transfer_memo,
    }, "bank.transfer.result")
    if reply and reply.ok then
        state.account = reply.result and reply.result.account or state.account
        state.view = "home"
        state.error = nil
        state.status = "Transfer sent"
        state.transfer_to = ""
        state.transfer_amount = ""
        state.transfer_memo = ""
    else
        state.error = (reply and reply.error) or err or "TransferFailed"
    end
end

local function draw_field(ctx, row, label, value, focused)
    local width = math.max(8, ctx.width - #label - 3)
    local prefix = focused and ">" or " "
    api.screen.write(ctx.x, ctx.y + row, prefix .. label .. ":", focused and C.yellow or C.lightGray, C.black)
    api.screen.write(ctx.x + #label + 3, ctx.y + row, truncate(value, width), C.white, focused and C.gray or C.black)
end

local function render_open(ctx, state)
    local has_account = state.account and state.account.open
    write_line(ctx, 0, has_account and "Complete Bank Setup" or "Open Bank of Ba$h", C.yellow)
    write_line(ctx, 2, "Account", C.lightGray)
    draw_field(ctx, 3, "Acct", state.account_name, state.focus == "account_name")
    write_line(ctx, 4, "Minecraft username", C.lightGray)
    draw_field(ctx, 5, "Name", state.minecraft_name, state.focus == "minecraft_name")
    write_line(ctx, 7, "Use main for phone service.", C.lightGray)

    ctx.buttons.bank_open = api.screen.button("bank_open", ctx.x, ctx.y + 9, 9, has_account and "Save" or "Open", {
        fg = C.white,
        bg = C.green,
    })
    ctx.buttons.bank_refresh = api.screen.button("bank_refresh", ctx.x + 10, ctx.y + 9, 9, "Refresh", {
        fg = C.white,
        bg = C.blue,
    })
end

local function render_home(ctx, state)
    local account = state.account or {}
    write_line(ctx, 0, "Bank of Ba$h", C.yellow)
    write_line(ctx, 2, "Balance", C.lightGray)
    write_line(ctx, 3, tostring(account.balance or 0) .. " " .. tostring(account.currency or "TC"), C.white)
    write_line(ctx, 5, "Account", C.lightGray)
    write_line(ctx, 6, tostring(account.account_name or state.account_name or "main"), C.white)
    write_line(ctx, 7, "Minecraft", C.lightGray)
    write_line(ctx, 8, tostring(account.minecraft_name or "missing"), account.minecraft_name and C.white or C.red)

    ctx.buttons.bank_transfer = api.screen.button("bank_transfer", ctx.x, ctx.y + 10, 8, "Transfer", {
        fg = C.white,
        bg = C.green,
    })
    ctx.buttons.bank_account = api.screen.button("bank_account", ctx.x + 9, ctx.y + 10, 7, "Acct", {
        fg = C.white,
        bg = C.gray,
    })
    ctx.buttons.bank_refresh = api.screen.button("bank_refresh", ctx.x + 17, ctx.y + 10, 8, "Refresh", {
        fg = C.white,
        bg = C.blue,
    })
end

local function render_transfer(ctx, state)
    write_line(ctx, 0, "Transfer", C.yellow)
    draw_field(ctx, 2, "To", state.transfer_to, state.focus == "transfer_to")
    draw_field(ctx, 3, "TC", state.transfer_amount, state.focus == "transfer_amount")
    draw_field(ctx, 4, "Memo", state.transfer_memo, state.focus == "transfer_memo")

    ctx.buttons.bank_send = api.screen.button("bank_send", ctx.x, ctx.y + 6, 8, "Send", {
        fg = C.white,
        bg = C.green,
    })
    ctx.buttons.bank_back = api.screen.button("bank_back", ctx.x + 9, ctx.y + 6, 8, "Back", {
        fg = C.white,
        bg = C.gray,
    })
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)
    if not state.loaded then
        refresh(state)
    end

    if state.view == "transfer" then
        render_transfer(ctx, state)
    elseif state.view == "home" then
        render_home(ctx, state)
    else
        render_open(ctx, state)
    end

    local row = math.max(10, ctx.height - 2)
    if state.error then
        write_line(ctx, row, tostring(state.error), C.red)
    elseif state.status then
        write_line(ctx, row, tostring(state.status), C.green)
    end
end

local function cycle_focus(state)
    if state.view == "transfer" then
        if state.focus == "transfer_to" then
            state.focus = "transfer_amount"
        elseif state.focus == "transfer_amount" then
            state.focus = "transfer_memo"
        else
            state.focus = "transfer_to"
        end
    else
        if state.focus == "account_name" then
            state.focus = "minecraft_name"
        else
            state.focus = "account_name"
        end
    end
end

function app.on_touch(ctx)
    local state = ctx.state
    ensure_state(state)
    if ctx.button_id == "bank_refresh" then
        state.loaded = false
        state.status = "Refreshing..."
        refresh(state)
        return true
    elseif ctx.button_id == "bank_open" then
        open_account(state)
        return true
    elseif ctx.button_id == "bank_transfer" then
        state.view = "transfer"
        state.focus = "transfer_to"
        state.error = nil
        state.status = nil
        return true
    elseif ctx.button_id == "bank_account" then
        state.view = "open"
        state.focus = "account_name"
        state.error = nil
        state.status = nil
        return true
    elseif ctx.button_id == "bank_send" then
        transfer(state)
        return true
    elseif ctx.button_id == "bank_back" then
        state.view = "home"
        state.error = nil
        return true
    end
    return false
end

local function append_char(state, char)
    local focus = state.focus or "minecraft_name"
    local value = field_value(state, focus)
    local max_len = focus == "transfer_memo" and 40 or 32
    if #value >= max_len then
        return
    end
    if focus == "minecraft_name" then
        char = tostring(char or ""):gsub("[^%w_]", "")
    elseif focus == "account_name" then
        char = tostring(char or ""):lower():gsub("[^%w_%-%.]", "")
    elseif focus == "transfer_amount" then
        char = tostring(char or ""):gsub("[^%d%.]", "")
    end
    if char ~= "" then
        state[focus] = value .. char
    end
end

function app.on_key(ctx)
    local state = ctx.state
    ensure_state(state)
    local event = ctx.event
    if not event then
        return false
    end
    if event.type == "char" then
        append_char(state, event.raw and event.raw[2] or "")
        state.error = nil
        return true
    end
    if event.type ~= "key" or not keys then
        return false
    end
    local key = event.raw and event.raw[2]
    local focus = state.focus or "minecraft_name"
    if key == keys.backspace then
        local value = field_value(state, focus)
        state[focus] = value:sub(1, math.max(0, #value - 1))
        return true
    elseif key == keys.tab then
        cycle_focus(state)
        return true
    elseif key == keys.enter then
        if state.view == "transfer" then
            transfer(state)
        elseif state.view == "open" then
            open_account(state)
        end
        return true
    end
    return false
end

function app.on_tick(ctx)
    local state = ctx.state
    ensure_state(state)
    if not state.loaded or state.view ~= "home" then
        return false
    end

    local current = ctx.frame and ctx.frame.now and (ctx.frame.now * 1000) or api.time()
    if current - (state.last_auto_refresh or 0) < AUTO_REFRESH_MS then
        return false
    end
    state.last_auto_refresh = current
    refresh(state)
    return true
end

return app
