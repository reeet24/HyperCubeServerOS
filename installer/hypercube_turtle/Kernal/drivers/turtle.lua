local driver = {
    name = "turtle",
    version = "0.1.0",
}

local TurtleDriver = {}
TurtleDriver.__index = TurtleDriver
local unpack_args = unpack or table.unpack

local function call_native(name, ...)
    if not turtle or type(turtle[name]) ~= "function" then
        return false, "TurtleUnavailable"
    end
    return turtle[name](...)
end

function TurtleDriver.new()
    return setmetatable({
        available = turtle ~= nil,
        last_error = nil,
    }, TurtleDriver)
end

function TurtleDriver:call(name, ...)
    local results = { call_native(name, ...) }
    if results[1] == false then
        self.last_error = results[2]
    end
    return unpack_args(results)
end

function TurtleDriver:forward() return self:call("forward") end
function TurtleDriver:back() return self:call("back") end
function TurtleDriver:up() return self:call("up") end
function TurtleDriver:down() return self:call("down") end
function TurtleDriver:turn_left() return self:call("turnLeft") end
function TurtleDriver:turn_right() return self:call("turnRight") end
function TurtleDriver:dig() return self:call("dig") end
function TurtleDriver:dig_up() return self:call("digUp") end
function TurtleDriver:dig_down() return self:call("digDown") end
function TurtleDriver:place() return self:call("place") end
function TurtleDriver:place_up() return self:call("placeUp") end
function TurtleDriver:place_down() return self:call("placeDown") end
function TurtleDriver:attack() return self:call("attack") end
function TurtleDriver:attack_up() return self:call("attackUp") end
function TurtleDriver:attack_down() return self:call("attackDown") end
function TurtleDriver:detect() return self:call("detect") end
function TurtleDriver:detect_up() return self:call("detectUp") end
function TurtleDriver:detect_down() return self:call("detectDown") end
function TurtleDriver:suck(count) return self:call("suck", count) end
function TurtleDriver:suck_up(count) return self:call("suckUp", count) end
function TurtleDriver:suck_down(count) return self:call("suckDown", count) end
function TurtleDriver:drop(count) return self:call("drop", count) end
function TurtleDriver:drop_up(count) return self:call("dropUp", count) end
function TurtleDriver:drop_down(count) return self:call("dropDown", count) end
function TurtleDriver:select(slot) return self:call("select", slot) end
function TurtleDriver:refuel(count) return self:call("refuel", count) end

function TurtleDriver:fuel()
    if not turtle or not turtle.getFuelLevel then
        return nil, "TurtleUnavailable"
    end
    return turtle.getFuelLevel()
end

function TurtleDriver:selected()
    if not turtle or not turtle.getSelectedSlot then
        return nil, "TurtleUnavailable"
    end
    return turtle.getSelectedSlot()
end

function TurtleDriver:inventory()
    if not turtle then
        return nil, "TurtleUnavailable"
    end
    local slots = {}
    for slot = 1, 16 do
        slots[slot] = {
            count = turtle.getItemCount and turtle.getItemCount(slot) or 0,
            space = turtle.getItemSpace and turtle.getItemSpace(slot) or 0,
            detail = turtle.getItemDetail and turtle.getItemDetail(slot) or nil,
        }
    end
    return slots
end

function TurtleDriver:status()
    return {
        available = self.available,
        fuel = self:fuel(),
        selected = self:selected(),
        last_error = self.last_error,
    }
end

function driver.init()
    return TurtleDriver.new()
end

function driver.shutdown()
    return true
end

driver.TurtleDriver = TurtleDriver
driver.new = TurtleDriver.new

return driver
