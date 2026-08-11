local printer_driver = {}

local function find_printer()
    if not peripheral or not peripheral.getNames or not peripheral.getType or not peripheral.wrap then
        return nil, "PeripheralUnavailable"
    end
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "printer" then
            local printer = peripheral.wrap(name)
            if printer then
                return printer, name
            end
        end
    end
    return nil, "PrinterNotFound"
end

local function wrap_lines(text, width)
    width = math.max(1, tonumber(width) or 25)
    local lines = {}
    for raw_line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        if raw_line == "" then
            lines[#lines + 1] = ""
        else
            local remaining = raw_line
            while #remaining > width do
                lines[#lines + 1] = remaining:sub(1, width)
                remaining = remaining:sub(width + 1)
            end
            lines[#lines + 1] = remaining
        end
    end
    if #lines == 0 then
        lines[1] = ""
    end
    return lines
end

function printer_driver.status()
    local printer, name = find_printer()
    if not printer then
        return false, name
    end
    return true, {
        name = name,
        paper = printer.getPaperLevel and printer.getPaperLevel() or nil,
        ink = printer.getInkLevel and printer.getInkLevel() or nil,
    }
end

function printer_driver.print(text, options)
    local printer, name = find_printer()
    if not printer then
        return false, name
    end
    if not printer.newPage or not printer.endPage or not printer.write or not printer.setCursorPos then
        return false, "InvalidPrinter"
    end

    options = options or {}
    local title = tostring(options.title or "HyperCube Document")
    local page_width, page_height = 25, 21
    if printer.getPageSize then
        local w, h = printer.getPageSize()
        page_width = tonumber(w) or page_width
        page_height = tonumber(h) or page_height
    end

    local lines = wrap_lines(text, page_width)
    local page = 0
    local index = 1
    while index <= #lines do
        local ok, err = printer.newPage()
        if not ok then
            return false, err or "NewPageFailed"
        end
        page = page + 1
        if printer.setPageTitle then
            printer.setPageTitle(title .. (page > 1 and (" " .. tostring(page)) or ""))
        end
        for y = 1, page_height do
            if index > #lines then
                break
            end
            printer.setCursorPos(1, y)
            printer.write(lines[index])
            index = index + 1
        end
        ok, err = printer.endPage()
        if not ok then
            return false, err or "EndPageFailed"
        end
    end

    return true, {
        printer = name,
        pages = page,
        lines = #lines,
    }
end

return printer_driver
