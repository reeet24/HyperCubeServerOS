local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "HyperWeb",
        label = "Web",
        color = C.cyan,
        dock = true,
        render_mode = "exclusive",
        refresh_rate = 10,
    },
}

local COLOR_NAMES = {
    black = C.black,
    white = C.white,
    gray = C.gray,
    grey = C.gray,
    lightgray = C.lightGray,
    lightgrey = C.lightGray,
    blue = C.blue,
    cyan = C.cyan,
    green = C.green,
    red = C.red,
    yellow = C.yellow,
    purple = C.purple,
    orange = C.orange,
}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

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

local function color(value, fallback)
    if type(value) == "number" then
        return value
    end
    value = tostring(value or ""):lower()
    return COLOR_NAMES[value] or fallback
end

local function parse_address(address)
    address = trim(address)
    address = address:gsub("^hyper://", "")
    address = address:gsub("^hc://", "")
    address = address:gsub("^hcm://", "")
    address = address:gsub("^/+", "")
    if address == "" then
        return nil, nil, "AddressRequired"
    end

    local domain, path = address:match("^([^/]+)(/.*)$")
    if not domain then
        domain = address
        path = "/"
    end
    return domain, path
end

local function normalize_link(current_domain, href)
    href = trim(href)
    if href == "" then
        return nil
    end
    href = href:gsub("^hyper://", "")
    href = href:gsub("^hc://", "")
    href = href:gsub("^hcm://", "")
    if href:sub(1, 1) == "/" then
        return tostring(current_domain or "") .. href
    end
    return href
end

local function field_key(line)
    return tostring(line.form_id or "_") .. ":" .. tostring(line.name or line.id or "")
end

local function field_label(line, fallback)
    return tostring(line.label or line.placeholder or line.name or fallback or "Field")
end

local function field_value(state, line)
    state.form_values = state.form_values or {}
    local key = field_key(line)
    if state.form_values[key] == nil then
        if line.value ~= nil then
            state.form_values[key] = tostring(line.value)
        elseif line.selected ~= nil then
            state.form_values[key] = tostring(line.selected)
        else
            state.form_values[key] = ""
        end
    end
    return state.form_values[key]
end

local function set_field_value(state, line, value)
    state.form_values = state.form_values or {}
    state.form_values[field_key(line)] = tostring(value or "")
end

local function form_action_address(state, action)
    action = trim(action)
    if action == "" then
        action = state.path or "/"
    end
    return normalize_link(state.domain, action)
end

local function collect_form_body(state, form_id)
    local body = {}
    local rendered = state.page and state.page.rendered
    for _, line in ipairs(rendered and rendered.lines or {}) do
        if tostring(line.form_id or "") == tostring(form_id or "") and line.name and (line.kind == "input" or line.kind == "textarea" or line.kind == "select") then
            body[tostring(line.name)] = field_value(state, line)
        end
    end
    return body
end

local function apply_web_result(state, address, reply, request_err)
    if not reply then
        state.status = "Offline"
        state.error = request_err or "NoReply"
        return false
    end
    if not reply.ok then
        state.status = "Error"
        state.error = reply.error or "RequestFailed"
        return false
    end
    state.address = address or state.address
    state.page = reply.result
    state.status = "Loaded"
    state.error = nil
    state.scroll = 0
    state.focus_field = nil
    state.form_values = {}
    if state.address and state.address ~= "" then
        api.fs.write("last_address.txt", state.address)
    end
    return true
end

local function write(ctx, row, text, fg, bg)
    api.screen.write(ctx.x, ctx.y + row, truncate(text, ctx.width), fg or C.white, bg or C.black)
end

local function load_page(state)
    local domain, path, err = parse_address(state.address)
    if not domain then
        state.error = err
        state.page = nil
        return false
    end

    state.status = "Loading..."
    state.error = nil
    local reply, request_err = api.hypernet.request({
        type = "web.get",
        domain = domain,
        path = path,
    }, "web.get.result", 6)

    state.domain = domain
    state.path = path
    return apply_web_result(state, state.address, reply, request_err)
end

local function submit_form(state, form_id)
    local form = state.forms and state.forms[tostring(form_id or "")]
    if not form then
        state.status = "FormMissing"
        return false
    end
    local address = form_action_address(state, form.action)
    local domain, path, err = parse_address(address or "")
    if not domain then
        state.status = "Error"
        state.error = err
        return false
    end

    state.status = "Submitting..."
    state.error = nil
    local reply, request_err = api.hypernet.request({
        type = "web.request",
        domain = domain,
        path = path,
        method = form.method or "GET",
        body = collect_form_body(state, form_id),
    }, "web.request.result", 8)
    if reply and reply.ok then
        state.domain = domain
        state.path = path
    end
    return apply_web_result(state, address, reply, request_err)
end

local function ensure_state(state)
    if state.ready then
        return
    end
    state.ready = true
    state.address = api.fs.read("last_address.txt") or ""
    state.status = "Ready"
    state.cursor = #state.address + 1
    state.links = {}
    state.fields = {}
    state.forms = {}
    state.form_values = {}
    state.scroll = 0
    state.max_scroll = 0
    state.address_selected = true
end

local function draw_address_bar(ctx, state)
    local label = "URL "
    local label_width = #label
    local body_width = math.max(1, ctx.width - label_width)
    local value = state.address ~= "" and state.address or "hyper://"
    local lines = wrap_text(value, body_width)
    local selected = state.address_selected ~= false
    local height = selected and math.max(1, math.min(3, #lines)) or 1
    local bg = selected and C.blue or C.gray

    api.screen.rect(ctx.x, ctx.y, ctx.width, height, bg)
    for i = 1, height do
        local prefix = i == 1 and label or string.rep(" ", label_width)
        api.screen.write(ctx.x, ctx.y + i - 1, prefix .. pad_to_width(lines[i] or "", body_width), C.white, bg)
    end
    ctx.buttons.address = {
        id = "address",
        x = ctx.x,
        y = ctx.y,
        width = ctx.width,
        height = height,
        contains = function(_, tx, ty)
            return tx >= ctx.x and tx < ctx.x + ctx.width and ty >= ctx.y and ty < ctx.y + height
        end,
    }

    local controls_row = height
    ctx.buttons.load = api.screen.button("load", ctx.x, ctx.y + controls_row, 6, "Go", {
        fg = C.black,
        bg = C.yellow,
    })
    ctx.buttons.clear = api.screen.button("clear", ctx.x + 7, ctx.y + controls_row, 7, "Clear", {
        fg = C.white,
        bg = C.red,
    })
    ctx.buttons.focus = api.screen.button("focus", ctx.x + 15, ctx.y + controls_row, 8, selected and "Edit" or "URL", {
        fg = C.white,
        bg = selected and C.blue or C.gray,
    })
    return height + 2
end

local function draw_line(ctx, state, row, line, index)
    local text = tostring(line.text or "")
    local kind = tostring(line.kind or "text")
    local fg = color(line.fg, C.white)
    local bg = color(line.bg, C.black)

    if kind == "h1" then
        write(ctx, row, text, color(line.fg, C.yellow), bg)
    elseif kind == "h2" then
        write(ctx, row, text, color(line.fg, C.cyan), bg)
    elseif kind == "card" then
        api.screen.rect(ctx.x, ctx.y + row, ctx.width, 1, color(line.bg, C.gray))
        write(ctx, row, text, color(line.fg, C.white), color(line.bg, C.gray))
    elseif kind == "link" then
        local id = "link_" .. tostring(index)
        state.links[id] = normalize_link(state.domain, line.href or text)
        ctx.buttons[id] = api.screen.button(id, ctx.x, ctx.y + row, math.min(ctx.width, math.max(6, #text + 2)), text, {
            fg = color(line.fg, C.white),
            bg = color(line.bg, C.blue),
        })
    elseif kind == "button" then
        local id = "action_" .. tostring(index)
        if line.form_id and (line.type == "submit" or line.action == "submit" or not line.action) then
            state.forms[tostring(line.form_id)] = {
                action = line.form_action,
                method = line.form_method or "GET",
            }
            state.links[id] = {
                kind = "submit",
                form_id = line.form_id,
            }
        else
            state.links[id] = normalize_link(state.domain, line.action or line.href or text)
        end
        ctx.buttons[id] = api.screen.button(id, ctx.x, ctx.y + row, math.min(ctx.width, math.max(8, #text + 2)), text, {
            fg = color(line.fg, C.black),
            bg = color(line.bg, C.yellow),
        })
    elseif kind == "input" or kind == "textarea" then
        if line.form_id then
            state.forms[tostring(line.form_id)] = {
                action = line.form_action,
                method = line.form_method or "GET",
            }
        end
        local id = "field_" .. tostring(index)
        local key = field_key(line)
        local focused = state.focus_field == key
        local value = field_value(state, line)
        local label = field_label(line, kind == "textarea" and "Text" or "Input")
        local display = label .. ": " .. (value ~= "" and value or tostring(line.placeholder or ""))
        state.fields[id] = {
            key = key,
            line = line,
        }
        ctx.buttons[id] = {
            id = id,
            x = ctx.x,
            y = ctx.y + row,
            width = ctx.width,
            height = 1,
            contains = function(_, tx, ty)
                return tx >= ctx.x and tx < ctx.x + ctx.width and ty == ctx.y + row
            end,
        }
        api.screen.rect(ctx.x, ctx.y + row, ctx.width, 1, focused and C.blue or C.gray)
        write(ctx, row, display .. (focused and "_" or ""), C.white, focused and C.blue or C.gray)
    elseif kind == "select" then
        if line.form_id then
            state.forms[tostring(line.form_id)] = {
                action = line.form_action,
                method = line.form_method or "GET",
            }
        end
        local id = "field_" .. tostring(index)
        local value = field_value(state, line)
        local options = line.options or {}
        if value == "" and options[1] then
            value = tostring(options[1].value or options[1].label or "")
            set_field_value(state, line, value)
        end
        local label = field_label(line, "Select")
        local shown = value
        for _, option in ipairs(options) do
            if tostring(option.value or "") == tostring(value) then
                shown = tostring(option.label or option.value or value)
                break
            end
        end
        state.fields[id] = {
            key = field_key(line),
            line = line,
            select = true,
        }
        ctx.buttons[id] = api.screen.button(id, ctx.x, ctx.y + row, math.min(ctx.width, math.max(8, #label + #shown + 5)), label .. ": " .. shown, {
            fg = C.white,
            bg = C.purple,
        })
    elseif kind == "break" then
        return
    else
        write(ctx, row, text, fg, bg)
    end
end

function app.render(ctx)
    local state = ctx.state
    ensure_state(state)
    state.links = {}
    state.fields = {}
    state.forms = {}

    local content_top = draw_address_bar(ctx, state)
    write(ctx, content_top, state.status or "", C.lightGray)

    if state.error then
        write(ctx, content_top + 2, tostring(state.error), C.red)
        return
    end

    local rendered = state.page and state.page.rendered
    if not rendered then
        return
    end

    write(ctx, content_top + 2, rendered.title or state.address, C.yellow)
    local content = {}
    for i, line in ipairs(rendered.lines or {}) do
        local control = line.kind == "input" or line.kind == "textarea" or line.kind == "select" or line.kind == "button" or line.kind == "link"
        local wrapped = control and { line.text or "" } or wrap_text(line.text or "", ctx.width)
        if #wrapped == 0 then
            wrapped = { "" }
        end
        for _, text in ipairs(wrapped) do
            content[#content + 1] = {
                line = line,
                text = text,
                index = i,
            }
        end
    end

    local row_start = content_top + 4
    local visible = math.max(1, ctx.height - row_start)
    state.max_scroll = math.max(0, #content - visible)
    state.scroll = math.max(0, math.min(state.scroll or 0, state.max_scroll))

    local row = row_start
    for i = state.scroll + 1, math.min(#content, state.scroll + visible) do
        local item = content[i]
        local line = {}
        for key, value in pairs(item.line or {}) do
            line[key] = value
        end
        line.text = item.text
        draw_line(ctx, state, row, line, item.index)
        row = row + 1
    end
end

function app.on_touch(ctx)
    local state = ctx.state
    ensure_state(state)
    if ctx.event and ctx.event.type == "scroll" then
        state.scroll = math.max(0, math.min((state.scroll or 0) + (ctx.event.direction or 0), state.max_scroll or 0))
        return true
    elseif ctx.button_id == "load" then
        state.address_selected = false
        load_page(state)
        return true
    elseif ctx.button_id == "clear" then
        state.address = ""
        state.status = "Ready"
        state.error = nil
        state.page = nil
        state.address_selected = true
        return true
    elseif ctx.button_id == "address" or ctx.button_id == "focus" then
        state.address_selected = true
        state.focus_field = nil
        return true
    elseif ctx.button_id and state.fields and state.fields[ctx.button_id] then
        local field = state.fields[ctx.button_id]
        state.address_selected = false
        if field.select then
            local line = field.line or {}
            local options = line.options or {}
            if #options > 0 then
                local current = field_value(state, line)
                local next_index = 1
                for index, option in ipairs(options) do
                    if tostring(option.value or "") == tostring(current) then
                        next_index = index + 1
                        break
                    end
                end
                if next_index > #options then
                    next_index = 1
                end
                set_field_value(state, line, options[next_index].value or options[next_index].label or "")
            end
            state.focus_field = nil
        else
            state.focus_field = field.key
            state.focus_line = field.line
        end
        return true
    elseif ctx.button_id and state.links and state.links[ctx.button_id] then
        local target = state.links[ctx.button_id]
        state.address_selected = false
        state.focus_field = nil
        if type(target) == "table" and target.kind == "submit" then
            submit_form(state, target.form_id)
        else
            state.address = target
            load_page(state)
        end
        return true
    end
    return false
end

function app.on_key(ctx)
    local state = ctx.state
    ensure_state(state)
    local event = ctx.event
    if event.type == "char" then
        if state.focus_field and state.focus_line then
            local ch = event.raw and event.raw[2] or ""
            local value = field_value(state, state.focus_line)
            if #value < tonumber(state.focus_line.maxlength or 512) then
                set_field_value(state, state.focus_line, value .. ch)
            end
            return true
        end
        if state.address_selected == false then
            return false
        end
        local ch = event.raw and event.raw[2] or ""
        if #state.address < 64 then
            state.address = state.address .. ch
        end
        return true
    end

    local key = event.raw and event.raw[2]
    if key == keys.enter then
        if state.focus_field and state.focus_line and state.focus_line.kind == "textarea" then
            return true
        end
        if state.focus_field and state.focus_line and state.focus_line.form_id and state.focus_line.kind ~= "textarea" then
            submit_form(state, state.focus_line.form_id)
            return true
        end
        state.address_selected = false
        state.focus_field = nil
        load_page(state)
        return true
    elseif key == keys.backspace then
        if state.focus_field and state.focus_line then
            local value = field_value(state, state.focus_line)
            set_field_value(state, state.focus_line, value:sub(1, math.max(0, #value - 1)))
            return true
        end
        if state.address_selected == false then
            return false
        end
        state.address = state.address:sub(1, math.max(0, #state.address - 1))
        return true
    elseif key == keys.delete then
        if state.focus_field and state.focus_line then
            set_field_value(state, state.focus_line, "")
            return true
        end
        if state.address_selected == false then
            return false
        end
        state.address = ""
        return true
    elseif key == keys.tab then
        state.address_selected = not state.address_selected
        state.focus_field = nil
        return true
    elseif key == keys.escape then
        state.address_selected = false
        state.focus_field = nil
        return true
    elseif key == keys.up then
        state.scroll = math.max(0, (state.scroll or 0) - 1)
        return true
    elseif key == keys.down then
        state.scroll = math.min(state.max_scroll or 0, (state.scroll or 0) + 1)
        return true
    end

    return false
end

return app
