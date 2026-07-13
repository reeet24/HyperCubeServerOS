local hctml = {}

local ALLOWED_TAGS = {
    page = true,
    h1 = true,
    h2 = true,
    p = true,
    br = true,
    card = true,
    list = true,
    item = true,
    link = true,
    button = true,
    code = true,
}

local SELF_CLOSING = {
    br = true,
}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function decode_entities(value)
    value = tostring(value or "")
    value = value:gsub("&lt;", "<")
    value = value:gsub("&gt;", ">")
    value = value:gsub("&quot;", "\"")
    value = value:gsub("&apos;", "'")
    value = value:gsub("&amp;", "&")
    return value
end

local function parse_attrs(raw)
    local attrs = {}
    raw = tostring(raw or "")
    for key, value in raw:gmatch("([%w_%-]+)%s*=%s*\"(.-)\"") do
        attrs[key:lower()] = decode_entities(value)
    end
    for key, value in raw:gmatch("([%w_%-]+)%s*=%s*'(.-)'") do
        attrs[key:lower()] = decode_entities(value)
    end
    return attrs
end

local function text_node(value)
    value = decode_entities(value)
    if value == "" then
        return nil
    end
    return {
        type = "text",
        text = value,
    }
end

local function append(parent, node)
    parent.children = parent.children or {}
    parent.children[#parent.children + 1] = node
end

function hctml.parse(source)
    if type(source) ~= "string" then
        return nil, "InvalidHcTML"
    end
    if #source > 12000 then
        return nil, "DocumentTooLarge"
    end

    local root = {
        type = "root",
        children = {},
    }
    local stack = { root }
    local pos = 1

    while true do
        local start_pos, end_pos, token = source:find("<(.-)>", pos)
        if not start_pos then
            local tail = text_node(source:sub(pos))
            if tail then
                append(stack[#stack], tail)
            end
            break
        end

        local before = text_node(source:sub(pos, start_pos - 1))
        if before then
            append(stack[#stack], before)
        end

        token = trim(token)
        local closing = token:sub(1, 1) == "/"
        local self_close = token:sub(-1) == "/"
        if closing then
            token = trim(token:sub(2))
        end
        if self_close then
            token = trim(token:sub(1, -2))
        end

        local tag, raw_attrs = token:match("^([%w]+)%s*(.-)$")
        if not tag then
            return nil, "InvalidTag"
        end
        tag = tag:lower()
        if not ALLOWED_TAGS[tag] then
            return nil, "UnsupportedTag:" .. tag
        end

        if closing then
            local current = stack[#stack]
            if current.type ~= tag then
                return nil, "MismatchedTag:" .. tag
            end
            stack[#stack] = nil
        else
            local node = {
                type = tag,
                attrs = parse_attrs(raw_attrs),
                children = {},
            }
            append(stack[#stack], node)
            if not self_close and not SELF_CLOSING[tag] then
                stack[#stack + 1] = node
            end
        end

        pos = end_pos + 1
    end

    if #stack ~= 1 then
        return nil, "UnclosedTag:" .. tostring(stack[#stack].type)
    end

    return root
end

local function collect_text(node, out)
    out = out or {}
    if node.type == "text" then
        out[#out + 1] = node.text
    end
    for _, child in ipairs(node.children or {}) do
        collect_text(child, out)
    end
    return table.concat(out)
end

local function compact_text(node)
    return trim((collect_text(node):gsub("%s+", " ")))
end

local function first_page(root)
    for _, child in ipairs(root.children or {}) do
        if child.type == "page" then
            return child
        end
    end
    return root
end

local function push_line(lines, text, kind, node)
    text = tostring(text or "")
    if text == "" and kind ~= "break" then
        return
    end

    local attrs = node and node.attrs or {}
    lines[#lines + 1] = {
        text = text,
        kind = kind or "text",
        fg = attrs.fg,
        bg = attrs.bg,
        align = attrs.align,
        href = attrs.href,
        action = attrs.action,
    }
end

local function render_node(node, lines)
    if node.type == "text" then
        local text = trim(node.text:gsub("%s+", " "))
        if text ~= "" then
            push_line(lines, text, "text", node)
        end
        return
    end

    if node.type == "br" then
        push_line(lines, "", "break", node)
        return
    end

    if node.type == "h1" or node.type == "h2" or node.type == "p" or node.type == "code" then
        push_line(lines, compact_text(node), node.type, node)
        return
    end

    if node.type == "link" then
        push_line(lines, compact_text(node), "link", node)
        return
    end

    if node.type == "button" then
        push_line(lines, compact_text(node), "button", node)
        return
    end

    if node.type == "item" then
        push_line(lines, "- " .. compact_text(node), "item", node)
        return
    end

    if node.type == "card" then
        push_line(lines, compact_text(node), "card", node)
        return
    end

    for _, child in ipairs(node.children or {}) do
        render_node(child, lines)
    end
end

function hctml.render(ast)
    if type(ast) ~= "table" then
        return nil, "InvalidAst"
    end

    local page = first_page(ast)
    local lines = {}
    for _, child in ipairs(page.children or {}) do
        render_node(child, lines)
    end

    return {
        title = (page.attrs and page.attrs.title) or "Untitled",
        lines = lines,
    }
end

function hctml.compile(source)
    local ast, parse_err = hctml.parse(source)
    if not ast then
        return nil, parse_err
    end

    local rendered, render_err = hctml.render(ast)
    if not rendered then
        return nil, render_err
    end

    return {
        ast = ast,
        rendered = rendered,
    }
end

return hctml
