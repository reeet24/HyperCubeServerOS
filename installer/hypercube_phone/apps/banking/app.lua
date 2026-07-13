local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "Bank of Ba$h",
        label = "Bank",
        color = C.green,
        dock = true,
        render_mode = "exclusive",
    },
}

local function truncate(text, width)
    text = tostring(text or "")
    if #text <= width then
        return text
    end
    if width <= 3 then
        return text:sub(1, width)
    end
    return text:sub(1, width - 3) .. "..."
end

local function write_line(ctx, row, text, fg)
    if api.screen.write_wrap then
        api.screen.write_wrap(ctx.x, ctx.y + row, text, ctx.width, 1, fg or C.white, C.black)
    else
        api.screen.write(ctx.x, ctx.y + row, truncate(text, ctx.width), fg or C.white, C.black)
    end
end

local function scroll_offset(text, width)
    text = tostring(text or "")
    width = math.max(1, tonumber(width) or 1)
    return math.max(0, #text - width + 1)
end

local function request(message, expected)
    return api.hypernet.request(message, expected, 8)
end

local function ensure_state(state)
    if state.ready then
        return
    end
    state.ready = true
    state.view = "home"
    state.to = api.fs.read("to.txt") or ""
    state.amount = api.fs.read("amount.txt") or ""
    state.memo = api.fs.read("memo.txt") or ""
    state.field = "to"
    state.account = nil
    state.history = nil
    state.checked = false
    state.error = nil
    state.hscroll = {}
    state.router = nil
end

local function refresh(state)
    state.checked = true
    local reply, err = request({
        type = "bank.status",
    }, "bank.status.result")
    if reply and reply.ok then
        state.account = reply.result
        state.error = nil
    else
        state.account = nil
        state.error = (reply and reply.error) or err or "BankUnavailable"
    end

    if state.account and state.account.open ~= false then
        local history = request({
            type = "bank.history",
        }, "bank.history.result")
        if history and history.ok then
            state.history = history.result
        end
    end
end

local function open_account(state)
    state.error = "Opening..."
    local reply, err = request({
        type = "bank.open",
        username = api.identity.username,
    }, "bank.open.result")
    if reply and reply.ok then
        state.account = reply.result
        state.checked = true
        state.error = "Account opened"
        local history = request({
            type = "bank.history",
        }, "bank.history.result")
        if history and history.ok then
            state.history = history.result
        end
    else
        state.error = (reply and reply.error) or err or "OpenFailed"
    end
end

local function transfer(state)
    local amount = tonumber(state.amount)
    if not amount or amount <= 0 then
        state.error = "Invalid amount"
        return
    end
    local reply, err = request({
        type = "bank.transfer",
        to = state.to,
        amount = amount,
        memo = state.memo,
    }, "bank.transfer.result")
    if reply and reply.ok then
        state.error = "Sent"
        state.amount = ""
        state.memo = ""
        api.fs.write("amount.txt", "")
        api.fs.write("memo.txt", "")
        refresh(state)
    else
        state.error = (reply and reply.error) or err or "TransferFailed"
    end
end

local function draw_field(ctx, state, id, key, row, label, value, width)
    width = math.max(8, math.min(ctx.width, width or ctx.width))
    value = tostring(value or "")
    local active = state.field == key
    local bg = active and C.blue or C.gray
    local fg = C.white
    local label_text = tostring(label or "")
    local value_x = ctx.x + #label_text + 1
    local value_width = math.max(1, width - #label_text - 1)
    local offset = active and scroll_offset(value, value_width) or 0

    api.screen.rect(ctx.x, ctx.y + row, width, 1, bg)
    api.screen.write(ctx.x, ctx.y + row, label_text, fg, bg)
    if api.screen.write_scroll then
        api.screen.write_scroll(value_x, ctx.y + row, value_width, value, offset, fg, bg)
    else
        api.screen.write(value_x, ctx.y + row, truncate(value, value_width), fg, bg)
    end

    ctx.buttons[id] = {
        id = id,
        x = ctx.x,
        y = ctx.y + row,
        width = width,
        height = 1,
        contains = function(_, tx, ty)
            return tx >= ctx.x and tx < ctx.x + width and ty == ctx.y + row
        end,
    }
end

local function draw_open(ctx, state)
    write_line(ctx, 0, "Bank of Ba$h", C.yellow)
    write_line(ctx, 2, "A TesseracID is required.", C.lightGray)
    write_line(ctx, 3, "Signed in: " .. tostring(api.identity.username or api.identity.tesserac_id or "no"), C.white)
    ctx.buttons.bank_open = api.screen.button("bank_open", ctx.x, ctx.y + 5, 15, "Open Account", {
        fg = C.black,
        bg = C.yellow,
    })
end

local function draw_home(ctx, state)
    local account = state.account
    write_line(ctx, 0, "Bank of Ba$h", C.yellow)
    write_line(ctx, 1, "Owner: " .. tostring(account.username or account.owner), C.lightGray)
    write_line(ctx, 2, "Balance: " .. tostring(account.balance or 0) .. " TC", C.green)
    write_line(ctx, 3, "Account: " .. tostring(account.account_id), C.lightGray)

    ctx.buttons.bank_transfer_view = api.screen.button("bank_transfer_view", ctx.x, ctx.y + 5, 12, "Transfer", {
        fg = C.white,
        bg = C.blue,
    })
    ctx.buttons.bank_refresh = api.screen.button("bank_refresh", ctx.x + 14, ctx.y + 5, 10, "Refresh", {
        fg = C.white,
        bg = C.gray,
    })

    write_line(ctx, 7, "Recent", C.yellow)
    local items = state.history and state.history.transactions or {}
    local start = math.max(1, #items - 4)
    local row = 8
    for i = start, #items do
        local tx = items[i]
        local sign = tx.direction == "out" and "-" or "+"
        local text = sign .. tostring(tx.amount) .. " " .. tostring(tx.memo or tx.kind)
        if api.screen.write_wrap then
            api.screen.write_wrap(ctx.x, ctx.y + row, text, ctx.width, 1, C.lightGray, C.black)
        else
            write_line(ctx, row, text, C.lightGray)
        end
        row = row + 1
    end
end

local function draw_transfer(ctx, state)
    write_line(ctx, 0, "Send TC", C.yellow)
    draw_field(ctx, state, "bank_to", "to", 2, "To ", state.to, ctx.width)
    draw_field(ctx, state, "bank_amount", "amount", 4, "Amt ", state.amount, math.min(ctx.width, 18))
    draw_field(ctx, state, "bank_memo", "memo", 6, "Memo ", state.memo, ctx.width)
    ctx.buttons.bank_send = api.screen.button("bank_send", ctx.x, ctx.y + 8, 8, "Send", {
        fg = C.white,
        bg = C.green,
    })
    ctx.buttons.bank_cancel = api.screen.button("bank_cancel", ctx.x + 10, ctx.y + 8, 8, "Back", {
        fg = C.white,
        bg = C.gray,
    })
    write_line(ctx, 10, "Recipient: username or TesseracID", C.lightGray)
end

local function draw_error(ctx, state)
    if state.error then
        write_line(ctx, ctx.height - 1, tostring(state.error), state.error == "Sent" and C.green or C.red)
    end
end

local function ensure_router(state)
    if state.router then
        return state.router
    end
    local router = api.screen.manager("home")
    router:define("open", {
        state = state,
        render = function(ctx, page_state)
            draw_open(ctx, page_state)
            draw_error(ctx, page_state)
        end,
        on_touch = function(ctx, page_state, manager)
            if ctx.button_id == "bank_open" then
                open_account(page_state)
                if page_state.account and page_state.account.open ~= false then
                    page_state.view = "home"
                    manager:set("home")
                end
                return true
            end
            return false
        end,
    })
    router:define("home", {
        state = state,
        render = function(ctx, page_state)
            draw_home(ctx, page_state)
            draw_error(ctx, page_state)
        end,
        on_touch = function(ctx, page_state, manager)
            if ctx.button_id == "bank_transfer_view" then
                page_state.view = "transfer"
                manager:set("transfer")
                return true
            elseif ctx.button_id == "bank_refresh" then
                refresh(page_state)
                return true
            end
            return false
        end,
    })
    router:define("transfer", {
        state = state,
        render = function(ctx, page_state)
            draw_transfer(ctx, page_state)
            draw_error(ctx, page_state)
        end,
        on_touch = function(ctx, page_state, manager)
            if ctx.button_id == "bank_to" then
                page_state.field = "to"
                return true
            elseif ctx.button_id == "bank_amount" then
                page_state.field = "amount"
                return true
            elseif ctx.button_id == "bank_memo" then
                page_state.field = "memo"
                return true
            elseif ctx.button_id == "bank_send" then
                transfer(page_state)
                return true
            elseif ctx.button_id == "bank_cancel" then
                page_state.view = "home"
                manager:set("home")
                return true
            end
            return false
        end,
        on_key = function(ctx, page_state)
            local event = ctx.event
            if event.type == "char" then
                local ch = event.raw and event.raw[2] or ""
                if page_state.field == "amount" then
                    ch = ch:gsub("[^%d%.]", "")
                    if ch ~= "" and #page_state.amount < 10 then
                        page_state.amount = page_state.amount .. ch
                        api.fs.write("amount.txt", page_state.amount)
                    end
                elseif page_state.field == "memo" then
                    if #page_state.memo < 40 then
                        page_state.memo = page_state.memo .. ch
                        api.fs.write("memo.txt", page_state.memo)
                    end
                elseif #page_state.to < 32 then
                    page_state.to = page_state.to .. ch
                    api.fs.write("to.txt", page_state.to)
                end
                return true
            end

            local key = event.raw and event.raw[2]
            if key == keys.backspace then
                if page_state.field == "amount" then
                    page_state.amount = page_state.amount:sub(1, math.max(0, #page_state.amount - 1))
                    api.fs.write("amount.txt", page_state.amount)
                elseif page_state.field == "memo" then
                    page_state.memo = page_state.memo:sub(1, math.max(0, #page_state.memo - 1))
                    api.fs.write("memo.txt", page_state.memo)
                else
                    page_state.to = page_state.to:sub(1, math.max(0, #page_state.to - 1))
                    api.fs.write("to.txt", page_state.to)
                end
                return true
            elseif key == keys.tab then
                if page_state.field == "to" then
                    page_state.field = "amount"
                elseif page_state.field == "amount" then
                    page_state.field = "memo"
                else
                    page_state.field = "to"
                end
                return true
            elseif key == keys.enter then
                transfer(page_state)
                return true
            end
            return false
        end,
    })
    state.router = router
    return router
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)
    if not state.checked then
        refresh(state)
    end
    local router = ensure_router(state)
    if not state.account or state.account.open == false then
        router:set("open")
    elseif state.view == "transfer" then
        router:set("transfer")
    else
        router:set("home")
    end
    router:render(ctx)
end

function app.on_touch(ctx)
    local state = ctx.state
    ensure_state(state)
    return ensure_router(state):touch(ctx)
end

function app.on_key(ctx)
    local state = ctx.state
    ensure_state(state)
    return ensure_router(state):key(ctx)
end

return app
