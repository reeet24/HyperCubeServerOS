local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "Messages",
        label = "Msg",
        color = C.cyan,
        render_mode = "exclusive",
        refresh_rate = 10,
    },
}

local AUTO_REFRESH_MS = 5000

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

local function wrap_text(text, width)
    width = math.max(1, math.floor(tonumber(width) or 1))
    text = tostring(text or "")
    local lines = {}

    local function push_long_word(word)
        while #word > width do
            lines[#lines + 1] = word:sub(1, width)
            word = word:sub(width + 1)
        end
        return word
    end

    for raw_line in (text .. "\n"):gmatch("(.-)\n") do
        local line = ""
        for word in raw_line:gmatch("%S+") do
            word = push_long_word(word)
            if word ~= "" then
                if line == "" then
                    line = word
                elseif #line + 1 + #word <= width then
                    line = line .. " " .. word
                else
                    lines[#lines + 1] = line
                    line = word
                end
            end
        end
        if line ~= "" then
            lines[#lines + 1] = line
        elseif raw_line == "" then
            lines[#lines + 1] = ""
        end
    end

    if #lines > 0 and lines[#lines] == "" and text:sub(-1) ~= "\n" then
        lines[#lines] = nil
    end
    if #lines == 0 then
        lines[1] = ""
    end
    return lines
end

local function pad_to_width(text, width)
    text = tostring(text or "")
    if #text >= width then
        return text:sub(1, width)
    end
    return text .. string.rep(" ", width - #text)
end

local function write_line(ctx, row, text, fg)
    api.screen.write(ctx.x, ctx.y + row, truncate(text, ctx.width), fg or C.white, C.black)
end

local function compose_body_lines(state, width)
    return wrap_text(state.compose_body ~= "" and state.compose_body or "Msg", width)
end

local function compose_body_height(state, width, max_height)
    local lines = compose_body_lines(state, width)
    return math.max(1, math.min(max_height or 3, #lines))
end

local function draw_wrapped_field(ctx, id, row, label, value, active, max_height)
    local width = math.max(1, ctx.width)
    local label_width = #label
    local body_width = math.max(1, width - label_width)
    local lines = wrap_text(value, body_width)
    local height = math.max(1, math.min(max_height or #lines, #lines))
    local bg = active and C.blue or C.gray

    api.screen.rect(ctx.x, ctx.y + row, width, height, bg)
    for i = 1, height do
        local prefix = i == 1 and label or string.rep(" ", label_width)
        api.screen.write(ctx.x, ctx.y + row + i - 1, prefix .. pad_to_width(lines[i] or "", body_width), C.white, bg)
    end
    ctx.buttons[id] = {
        id = id,
        x = ctx.x,
        y = ctx.y + row,
        width = width,
        height = height,
        contains = function(_, tx, ty)
            return tx >= ctx.x and tx < ctx.x + width and ty >= ctx.y + row and ty < ctx.y + row + height
        end,
    }
    return height
end

local function clean_number(number)
    return tostring(number or ""):gsub("%D", ""):sub(1, 6)
end

local function clean_name(name)
    name = tostring(name or ""):gsub("[\r\n|]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        return "Contact"
    end
    return name:sub(1, 18)
end

local function load_contacts()
    local contacts = {}
    local raw = api.fs.read("contacts.txt") or ""
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        local number, name = line:match("^(%d%d%d%d%d%d)|(.*)$")
        if number then
            contacts[#contacts + 1] = {
                number = number,
                name = clean_name(name),
            }
        end
    end
    table.sort(contacts, function(a, b)
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    return contacts
end

local function save_contacts(state)
    local rows = {}
    for _, contact in ipairs(state.contacts or {}) do
        rows[#rows + 1] = tostring(contact.number) .. "|" .. clean_name(contact.name)
    end
    api.fs.write("contacts.txt", table.concat(rows, "\n"))
end

local function find_contact(state, number)
    number = clean_number(number)
    for index, contact in ipairs(state.contacts or {}) do
        if contact.number == number then
            return contact, index
        end
    end
    return nil
end

local function contact_label(state, number)
    local contact = find_contact(state, number)
    if contact then
        return contact.name
    end
    return tostring(number or "unknown")
end

local function save_contact(state, name, number)
    number = clean_number(number)
    if #number ~= 6 then
        return false, "InvalidPhoneNumber"
    end
    if state.edit_contact_number and state.edit_contact_number ~= number then
        for index, contact in ipairs(state.contacts or {}) do
            if contact.number == state.edit_contact_number then
                table.remove(state.contacts, index)
                break
            end
        end
    end
    local existing = find_contact(state, number)
    if existing then
        existing.name = clean_name(name)
    else
        state.contacts[#state.contacts + 1] = {
            name = clean_name(name),
            number = number,
        }
    end
    table.sort(state.contacts, function(a, b)
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    save_contacts(state)
    return true
end

local function delete_contact(state, number)
    local _, index = find_contact(state, number)
    if not index then
        return false, "ContactNotFound"
    end
    table.remove(state.contacts, index)
    save_contacts(state)
    return true
end

local function refresh_status(state)
    local ok, result = api.phone.status()
    if ok then
        state.status = result
        state.error = nil
        return true
    end
    state.status = nil
    state.error = result or "PhoneStatusFailed"
    return false
end

local function refresh_chats(state)
    local ok, result = api.phone.chats()
    if ok then
        state.chats = result and result.chats or {}
        state.chats_loaded = true
        state.error = nil
        return true
    end
    state.chats = {}
    state.chats_loaded = true
    state.error = result or "ChatsUnavailable"
    return false
end

local function open_chat(state, number)
    number = clean_number(number)
    if #number ~= 6 then
        state.error = "InvalidPhoneNumber"
        return false
    end
    local ok, result = api.phone.chat(number, true)
    if ok then
        state.active_number = number
        state.active_chat = result or { number = number, messages = {} }
        state.selected_message_index = nil
        state.compose_to = number
        api.fs.write("to.txt", number)
        state.error = nil
        refresh_chats(state)
        return true
    end
    state.error = result or "ChatUnavailable"
    return false
end

local function send_message(state)
    local to = clean_number(state.compose_to or state.active_number)
    if #to ~= 6 then
        state.error = "InvalidPhoneNumber"
        return false
    end
    if tostring(state.compose_body or "") == "" then
        state.error = "EmptyMessage"
        return false
    end
    local ok, result = api.phone.send(to, state.compose_body)
    if ok then
        state.compose_body = ""
        api.fs.write("body.txt", "")
        state.error = "Sent"
        open_chat(state, to)
        return true
    end
    state.error = result or "SendFailed"
    return false
end

local function delete_chat(state, number)
    number = clean_number(number)
    local ok, result = api.phone.delete_chat(number)
    if ok then
        state.error = "Chat deleted"
        if state.active_number == number then
            state.active_number = nil
            state.active_chat = nil
        end
        refresh_chats(state)
        return true
    end
    state.error = result or "DeleteFailed"
    return false
end

local function report_selected_message(state)
    local messages = state.active_chat and state.active_chat.messages or {}
    local selected = tonumber(state.selected_message_index)
    if not selected or not messages[selected] then
        selected = nil
        for i = #messages, 1, -1 do
            if messages[i].direction == "in" then
                selected = i
                break
            end
        end
    end
    local msg = selected and messages[selected] or nil
    if not msg then
        state.error = "Select a message"
        return false
    end
    local ok, result = api.phone.report_message(state.active_number or state.compose_to, {
        id = msg.id,
        from = msg.from,
        to = msg.to,
        body = msg.body,
        sent_at = msg.sent_at,
        direction = msg.direction,
    }, "harmful_message")
    if ok then
        state.error = "Reported"
        return true
    end
    state.error = result or "ReportFailed"
    return false
end

local function subscribe(state)
    local ok, result = api.phone.subscribe()
    if ok then
        state.status = result
        state.error = nil
    else
        state.error = result or "SubscribeFailed"
    end
end

local function pay_bill(state)
    local ok, result = api.phone.pay()
    if ok then
        state.status = result
        state.error = nil
    else
        state.error = result or "PaymentFailed"
    end
end

local function status_active(status)
    return status and status.has_number ~= false and status.active == true
end

local function ensure_state(state)
    if state.ready then
        return
    end
    state.ready = true
    state.contacts = load_contacts()
    state.chats = {}
    state.chats_loaded = false
    state.active_number = nil
    state.active_chat = nil
    state.selected_message_index = nil
    state.compose_to = api.fs.read("to.txt") or ""
    state.compose_body = api.fs.read("body.txt") or ""
    state.compose_field = "body"
    state.contact_name = ""
    state.contact_number = ""
    state.contact_field = "name"
    state.status = nil
    state.error = nil
    state.router = nil
    state.last_auto_refresh = 0
end

local function draw_tabs(ctx, active)
    local tabs = {
        { id = "msg_tab_chats", page = "chats", label = "Chats" },
        { id = "msg_tab_contacts", page = "contacts", label = "People" },
        { id = "msg_tab_bills", page = "bills", label = "Bills" },
    }
    local x = ctx.x
    for _, tab in ipairs(tabs) do
        local w = math.min(8, math.max(6, #tab.label + 2))
        ctx.buttons[tab.id] = api.screen.button(tab.id, x, ctx.y, w, tab.label, {
            fg = active == tab.page and C.black or C.white,
            bg = active == tab.page and C.yellow or C.gray,
        })
        x = x + w + 1
    end
end

local function draw_status_line(ctx, state)
    if state.error then
        write_line(ctx, ctx.height - 1, tostring(state.error), state.error == "Sent" and C.green or C.red)
    elseif state.status and state.status.number then
        write_line(ctx, ctx.height - 1, "Number " .. tostring(state.status.number), C.lightGray)
    end
end

local function page_chats_render(ctx, state)
    draw_tabs(ctx, "chats")
    if not state.status then
        refresh_status(state)
    end
    if status_active(state.status) and not state.chats_loaded then
        refresh_chats(state)
    end

    if not status_active(state.status) then
        write_line(ctx, 2, "Messages inactive", C.red)
        write_line(ctx, 3, "Open Bills to activate.", C.lightGray)
        ctx.buttons.msg_open_bills = api.screen.button("msg_open_bills", ctx.x, ctx.y + 5, 10, "Bills", {
            fg = C.black,
            bg = C.yellow,
        })
        draw_status_line(ctx, state)
        return
    end

    ctx.buttons.msg_compose = api.screen.button("msg_compose", ctx.x, ctx.y + 2, 10, "New", {
        fg = C.white,
        bg = C.green,
    })
    ctx.buttons.msg_refresh = api.screen.button("msg_refresh", ctx.x + 12, ctx.y + 2, 10, "Sync", {
        fg = C.white,
        bg = C.gray,
    })
    write_line(ctx, 4, "Conversations", C.yellow)
    if #state.chats == 0 then
        write_line(ctx, 5, "No chats yet.", C.lightGray)
    end
    local row = 5
    for i, chat in ipairs(state.chats or {}) do
        local number = chat.number
        local label = contact_label(state, number)
        local prefix = (chat.unread or 0) > 0 and "*" or " "
        local preview_lines = wrap_text(tostring(chat.last_message or ""), math.max(1, ctx.width - #prefix - #label - 2))
        local title = prefix .. label .. " " .. tostring(preview_lines[1] or "")
        ctx.buttons["msg_chat_" .. tostring(i)] = api.screen.button("msg_chat_" .. tostring(i), ctx.x, ctx.y + row, ctx.width, title, {
            fg = C.white,
            bg = (chat.unread or 0) > 0 and C.blue or C.gray,
        })
        row = row + 1
        if row >= ctx.height - 1 then
            break
        end
    end
    draw_status_line(ctx, state)
end

local function page_chats_touch(ctx, state, router)
    if ctx.button_id == "msg_compose" then
        state.compose_to = ""
        state.compose_field = "to"
        router:set("compose")
        return true
    elseif ctx.button_id == "msg_refresh" then
        refresh_chats(state)
        return true
    elseif ctx.button_id == "msg_open_bills" then
        router:set("bills")
        return true
    end
    local index = tostring(ctx.button_id or ""):match("^msg_chat_(%d+)$")
    if index then
        local chat = state.chats[tonumber(index)]
        if chat and open_chat(state, chat.number) then
            router:set("thread")
            return true
        end
    end
    return false
end

local function page_thread_render(ctx, state)
    local number = state.active_number or state.compose_to
    write_line(ctx, 0, contact_label(state, number), C.yellow)
    ctx.buttons.msg_thread_back = api.screen.button("msg_thread_back", ctx.x, ctx.y + 1, 8, "Back", {
        fg = C.white,
        bg = C.gray,
    })
    ctx.buttons.msg_report_message = api.screen.button("msg_report_message", ctx.x + 9, ctx.y + 1, 8, "Report", {
        fg = C.white,
        bg = C.orange,
    })
    ctx.buttons.msg_delete_chat = api.screen.button("msg_delete_chat", ctx.x + 18, ctx.y + 1, 8, "Del", {
        fg = C.white,
        bg = C.red,
    })

    local body_height = compose_body_height(state, math.max(1, ctx.width - 4), 3)
    local input_row = ctx.height - body_height - 3
    local send_row = input_row + body_height
    local messages = state.active_chat and state.active_chat.messages or {}
    local visible = math.max(1, input_row - 3)
    local rows = {}
    for msg_index, msg in ipairs(messages) do
        local arrow = msg.direction == "out" and ">" or "<"
        local lines = wrap_text(msg.body, math.max(1, ctx.width - 2))
        for line_index, line in ipairs(lines) do
            rows[#rows + 1] = {
                text = (line_index == 1 and arrow or " ") .. " " .. line,
                color = state.selected_message_index == msg_index and C.yellow
                    or (msg.direction == "out" and C.green or C.lightGray),
                msg_index = msg_index,
                selectable = line_index == 1,
            }
        end
    end
    local start = math.max(1, #rows - visible + 1)
    local row = 3
    for i = start, #rows do
        write_line(ctx, row, rows[i].text, rows[i].color)
        if rows[i].selectable then
            local id = "msg_select_" .. tostring(rows[i].msg_index)
            local button_y = ctx.y + row
            ctx.buttons[id] = {
                id = id,
                x = ctx.x,
                y = button_y,
                width = ctx.width,
                height = 1,
                contains = function(_, tx, ty)
                    return tx >= ctx.x and tx < ctx.x + ctx.width and ty == button_y
                end,
            }
        end
        row = row + 1
        if row >= input_row then
            break
        end
    end

    draw_wrapped_field(ctx, "msg_body", input_row, "Msg ", state.compose_body, state.compose_field == "body", body_height)
    ctx.buttons.msg_send = api.screen.button("msg_send", ctx.x, ctx.y + send_row, 8, "Send", {
        fg = C.white,
        bg = C.green,
    })
    draw_status_line(ctx, state)
end

local function page_thread_touch(ctx, state, router)
    if ctx.button_id == "msg_thread_back" then
        refresh_chats(state)
        router:set("chats")
        return true
    elseif ctx.button_id == "msg_delete_chat" then
        delete_chat(state, state.active_number)
        router:set("chats")
        return true
    elseif ctx.button_id == "msg_report_message" then
        report_selected_message(state)
        return true
    elseif ctx.button_id == "msg_body" then
        state.compose_field = "body"
        return true
    elseif ctx.button_id == "msg_send" then
        send_message(state)
        return true
    end
    local selected = tostring(ctx.button_id or ""):match("^msg_select_(%d+)$")
    if selected then
        state.selected_message_index = tonumber(selected)
        return true
    end
    return false
end

local function page_contacts_render(ctx, state)
    draw_tabs(ctx, "contacts")
    ctx.buttons.msg_add_contact = api.screen.button("msg_add_contact", ctx.x, ctx.y + 2, 13, "Add Contact", {
        fg = C.white,
        bg = C.green,
    })
    write_line(ctx, 4, "Local Contacts", C.yellow)
    if #state.contacts == 0 then
        write_line(ctx, 5, "No saved contacts.", C.lightGray)
    end
    local row = 5
    for i, contact in ipairs(state.contacts) do
        local id = "msg_contact_" .. tostring(i)
        ctx.buttons[id] = api.screen.button(id, ctx.x, ctx.y + row, math.min(ctx.width, 20), contact.name, {
            fg = C.white,
            bg = C.gray,
        })
        if ctx.width > 24 then
            api.screen.write(ctx.x + 22, ctx.y + row, contact.number, C.lightGray, C.black)
        end
        row = row + 1
        if row >= ctx.height - 1 then
            break
        end
    end
    draw_status_line(ctx, state)
end

local function page_contacts_touch(ctx, state, router)
    if ctx.button_id == "msg_add_contact" then
        state.contact_name = ""
        state.contact_number = ""
        state.contact_field = "name"
        state.edit_contact_number = nil
        router:set("edit_contact")
        return true
    end
    local index = tostring(ctx.button_id or ""):match("^msg_contact_(%d+)$")
    if index then
        local contact = state.contacts[tonumber(index)]
        if contact then
            state.contact_name = contact.name
            state.contact_number = contact.number
            state.edit_contact_number = contact.number
            state.contact_field = "name"
            router:set("contact_detail")
            return true
        end
    end
    return false
end

local function draw_field(ctx, id, row, label, value, active)
    ctx.buttons[id] = api.screen.button(id, ctx.x, ctx.y + row, math.min(ctx.width, math.max(12, #label + #tostring(value or "") + 2)), label .. tostring(value or ""), {
        fg = C.white,
        bg = active and C.blue or C.gray,
    })
end

local function page_contact_detail_render(ctx, state)
    write_line(ctx, 0, state.contact_name, C.yellow)
    write_line(ctx, 1, state.contact_number, C.lightGray)
    ctx.buttons.msg_contact_chat = api.screen.button("msg_contact_chat", ctx.x, ctx.y + 3, 10, "Message", {
        fg = C.white,
        bg = C.green,
    })
    ctx.buttons.msg_contact_edit = api.screen.button("msg_contact_edit", ctx.x + 12, ctx.y + 3, 8, "Edit", {
        fg = C.white,
        bg = C.blue,
    })
    ctx.buttons.msg_contact_delete = api.screen.button("msg_contact_delete", ctx.x, ctx.y + 5, 10, "Delete", {
        fg = C.white,
        bg = C.red,
    })
    ctx.buttons.msg_contact_back = api.screen.button("msg_contact_back", ctx.x + 12, ctx.y + 5, 8, "Back", {
        fg = C.white,
        bg = C.gray,
    })
    draw_status_line(ctx, state)
end

local function page_contact_detail_touch(ctx, state, router)
    if ctx.button_id == "msg_contact_chat" then
        if open_chat(state, state.contact_number) then
            router:set("thread")
        else
            state.compose_to = state.contact_number
            router:set("compose")
        end
        return true
    elseif ctx.button_id == "msg_contact_edit" then
        router:set("edit_contact")
        return true
    elseif ctx.button_id == "msg_contact_delete" then
        local ok, err = delete_contact(state, state.contact_number)
        state.error = ok and "Deleted" or err
        router:set("contacts")
        return true
    elseif ctx.button_id == "msg_contact_back" then
        router:set("contacts")
        return true
    end
    return false
end

local function page_edit_contact_render(ctx, state)
    write_line(ctx, 0, state.edit_contact_number and "Edit Contact" or "Add Contact", C.yellow)
    draw_field(ctx, "msg_contact_name", 2, "Name ", state.contact_name, state.contact_field == "name")
    draw_field(ctx, "msg_contact_number", 4, "Num ", state.contact_number, state.contact_field == "number")
    ctx.buttons.msg_save_contact = api.screen.button("msg_save_contact", ctx.x, ctx.y + 6, 8, "Save", {
        fg = C.white,
        bg = C.green,
    })
    ctx.buttons.msg_cancel_contact = api.screen.button("msg_cancel_contact", ctx.x + 10, ctx.y + 6, 8, "Cancel", {
        fg = C.white,
        bg = C.gray,
    })
    write_line(ctx, 8, "Tab switches field.", C.lightGray)
    draw_status_line(ctx, state)
end

local function page_edit_contact_touch(ctx, state, router)
    if ctx.button_id == "msg_contact_name" then
        state.contact_field = "name"
        return true
    elseif ctx.button_id == "msg_contact_number" then
        state.contact_field = "number"
        return true
    elseif ctx.button_id == "msg_cancel_contact" then
        router:set("contacts")
        return true
    elseif ctx.button_id == "msg_save_contact" then
        local ok, err = save_contact(state, state.contact_name, state.contact_number)
        state.error = ok and "Saved" or err
        if ok then
            router:set("contacts")
        end
        return true
    end
    return false
end

local function page_edit_contact_key(ctx, state, router)
    local event = ctx.event
    if event.type == "char" then
        local ch = event.raw and event.raw[2] or ""
        if state.contact_field == "number" then
            ch = ch:gsub("%D", "")
            if ch ~= "" and #state.contact_number < 6 then
                state.contact_number = state.contact_number .. ch
            end
        elseif #state.contact_name < 18 then
            state.contact_name = state.contact_name .. ch
        end
        return true
    end
    local key = event.raw and event.raw[2]
    if key == keys.backspace then
        if state.contact_field == "number" then
            state.contact_number = state.contact_number:sub(1, math.max(0, #state.contact_number - 1))
        else
            state.contact_name = state.contact_name:sub(1, math.max(0, #state.contact_name - 1))
        end
        return true
    elseif key == keys.tab then
        state.contact_field = state.contact_field == "name" and "number" or "name"
        return true
    elseif key == keys.enter then
        local ok, err = save_contact(state, state.contact_name, state.contact_number)
        state.error = ok and "Saved" or err
        if ok then
            router:set("contacts")
        end
        return true
    end
    return false
end

local function page_compose_render(ctx, state)
    write_line(ctx, 0, "New Message", C.yellow)
    draw_field(ctx, "msg_to", 2, "To ", state.compose_to, state.compose_field == "to")
    local body_height = draw_wrapped_field(ctx, "msg_body", 4, "Msg ", state.compose_body, state.compose_field == "body", 3)
    local controls_row = 5 + body_height
    ctx.buttons.msg_send_new = api.screen.button("msg_send_new", ctx.x, ctx.y + controls_row, 8, "Send", {
        fg = C.white,
        bg = C.green,
    })
    ctx.buttons.msg_cancel_compose = api.screen.button("msg_cancel_compose", ctx.x + 10, ctx.y + controls_row, 8, "Back", {
        fg = C.white,
        bg = C.gray,
    })
    draw_status_line(ctx, state)
end

local function page_compose_touch(ctx, state, router)
    if ctx.button_id == "msg_to" then
        state.compose_field = "to"
        return true
    elseif ctx.button_id == "msg_body" then
        state.compose_field = "body"
        return true
    elseif ctx.button_id == "msg_cancel_compose" then
        router:set("chats")
        return true
    elseif ctx.button_id == "msg_send_new" then
        if send_message(state) then
            router:set("thread")
        end
        return true
    end
    return false
end

local function compose_key(ctx, state, router)
    local event = ctx.event
    if event.type == "char" then
        local ch = event.raw and event.raw[2] or ""
        if state.compose_field == "to" then
            ch = ch:gsub("%D", "")
            if ch ~= "" and #state.compose_to < 6 then
                state.compose_to = state.compose_to .. ch
                api.fs.write("to.txt", state.compose_to)
            end
        elseif #state.compose_body < 240 then
            state.compose_body = state.compose_body .. ch
            api.fs.write("body.txt", state.compose_body)
        end
        return true
    end
    local key = event.raw and event.raw[2]
    if key == keys.backspace then
        if state.compose_field == "to" then
            state.compose_to = state.compose_to:sub(1, math.max(0, #state.compose_to - 1))
            api.fs.write("to.txt", state.compose_to)
        else
            state.compose_body = state.compose_body:sub(1, math.max(0, #state.compose_body - 1))
            api.fs.write("body.txt", state.compose_body)
        end
        return true
    elseif key == keys.tab then
        state.compose_field = state.compose_field == "to" and "body" or "to"
        return true
    elseif key == keys.enter then
        if send_message(state) then
            router:set("thread")
        end
        return true
    end
    return false
end

local function page_bills_render(ctx, state)
    draw_tabs(ctx, "bills")
    if not state.status then
        refresh_status(state)
    end
    local status = state.status
    if status and status.has_number then
        write_line(ctx, 2, "Number: " .. tostring(status.number), C.yellow)
        write_line(ctx, 3, "Weekly bill: " .. tostring(status.weekly_bill or 25), C.lightGray)
        write_line(ctx, 4, "Paid until: " .. tostring(status.paid_until or "?"), C.lightGray)
        write_line(ctx, 5, status.active and "Service active" or "Bill due", status.active and C.green or C.red)
    else
        write_line(ctx, 2, "No phone number.", C.red)
        write_line(ctx, 3, "Weekly bill: " .. tostring(status and status.weekly_bill or 25), C.lightGray)
        write_line(ctx, 4, "Bank account required.", C.lightGray)
        write_line(ctx, 5, "First week is free.", C.lightGray)
    end
    ctx.buttons.msg_subscribe = api.screen.button("msg_subscribe", ctx.x, ctx.y + 7, 12, status and status.has_number and "Pay Bill" or "Get Number", {
        fg = C.black,
        bg = C.yellow,
    })
    ctx.buttons.msg_bill_refresh = api.screen.button("msg_bill_refresh", ctx.x + 14, ctx.y + 7, 10, "Refresh", {
        fg = C.white,
        bg = C.gray,
    })
    draw_status_line(ctx, state)
end

local function page_bills_touch(ctx, state)
    if ctx.button_id == "msg_subscribe" then
        if state.status and state.status.has_number then
            pay_bill(state)
        else
            subscribe(state)
        end
        return true
    elseif ctx.button_id == "msg_bill_refresh" then
        refresh_status(state)
        refresh_chats(state)
        return true
    end
    return false
end

local function ensure_router(state)
    if state.router then
        return state.router
    end
    local router = api.screen.manager("chats")
    router:define("chats", { state = state, render = page_chats_render, on_touch = page_chats_touch })
    router:define("thread", { state = state, render = page_thread_render, on_touch = page_thread_touch, on_key = compose_key })
    router:define("contacts", { state = state, render = page_contacts_render, on_touch = page_contacts_touch })
    router:define("contact_detail", { state = state, render = page_contact_detail_render, on_touch = page_contact_detail_touch })
    router:define("edit_contact", { state = state, render = page_edit_contact_render, on_touch = page_edit_contact_touch, on_key = page_edit_contact_key })
    router:define("compose", { state = state, render = page_compose_render, on_touch = page_compose_touch, on_key = compose_key })
    router:define("bills", { state = state, render = page_bills_render, on_touch = page_bills_touch })
    state.router = router
    return router
end

local function handle_tab(ctx, router)
    if ctx.button_id == "msg_tab_chats" then
        router:set("chats")
        return true
    elseif ctx.button_id == "msg_tab_contacts" then
        router:set("contacts")
        return true
    elseif ctx.button_id == "msg_tab_bills" then
        router:set("bills")
        return true
    end
    return false
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)
    ensure_router(state):render(ctx)
end

function app.on_touch(ctx)
    local state = ctx.state
    ensure_state(state)
    local router = ensure_router(state)
    if handle_tab(ctx, router) then
        return true
    end
    return router:touch(ctx)
end

function app.on_key(ctx)
    local state = ctx.state
    ensure_state(state)
    return ensure_router(state):key(ctx)
end

function app.on_tick(ctx)
    local state = ctx.state
    ensure_state(state)

    local current = ctx.frame and ctx.frame.now and (ctx.frame.now * 1000) or api.time()
    if current - (state.last_auto_refresh or 0) < AUTO_REFRESH_MS then
        return false
    end
    state.last_auto_refresh = current

    if not state.status then
        return refresh_status(state)
    end
    if not status_active(state.status) then
        return refresh_status(state)
    end

    local changed = refresh_chats(state)
    if state.active_number then
        local selected = state.selected_message_index
        local ok, result = api.phone.chat(state.active_number, false)
        if ok then
            state.active_chat = result or { number = state.active_number, messages = {} }
            state.selected_message_index = selected
            state.error = nil
            changed = true
        else
            state.error = result or "ChatUnavailable"
            changed = true
        end
    end
    return changed
end

return app
