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

    if not reply then
        state.status = "Offline"
        state.error = request_err or "NoReply"
        state.page = nil
        return false
    end
    if not reply.ok then
        state.status = "Error"
        state.error = reply.error or "PageLoadFailed"
        state.page = nil
        return false
    end

    state.domain = domain
    state.path = path
    state.page = reply.result
    state.status = "Loaded"
    state.error = nil
    state.scroll = 0
    api.fs.write("last_address.txt", state.address)
    return true
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
        state.links[id] = normalize_link(state.domain, line.action or line.href or text)
        ctx.buttons[id] = api.screen.button(id, ctx.x, ctx.y + row, math.min(ctx.width, math.max(8, #text + 2)), text, {
            fg = color(line.fg, C.black),
            bg = color(line.bg, C.yellow),
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
        local wrapped = wrap_text(line.text or "", ctx.width)
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
        return true
    elseif ctx.button_id and state.links and state.links[ctx.button_id] then
        state.address = state.links[ctx.button_id]
        state.address_selected = false
        load_page(state)
        return true
    end
    return false
end

function app.on_key(ctx)
    local state = ctx.state
    ensure_state(state)
    local event = ctx.event
    if event.type == "char" then
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
        state.address_selected = false
        load_page(state)
        return true
    elseif key == keys.backspace then
        if state.address_selected == false then
            return false
        end
        state.address = state.address:sub(1, math.max(0, #state.address - 1))
        return true
    elseif key == keys.delete then
        if state.address_selected == false then
            return false
        end
        state.address = ""
        return true
    elseif key == keys.tab then
        state.address_selected = not state.address_selected
        return true
    elseif key == keys.escape then
        state.address_selected = false
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
