# User Server And Service API

User servers are lightweight HyperCube service hosts for player-run services. They install from the main server, sign in to a Tesserac account on first boot, then run service daemons from `user_services/<service_id>/service.lua`.

Each service can also expose a UI in `user_services/<service_id>/ui.lua`. The daemon starts after sign-in and stays running. The UI starts only when the user opens it from the user-server Services tab.

## File Layout

```text
user_services/<service_id>/manifest
user_services/<service_id>/service.lua
user_services/<service_id>/ui.lua
user_services_data/<service_id>/
```

`manifest` is a serialized Lua table. Supported fields:

- `title`: Display name in the Services tab.
- `description`: Short description for users.
- `version`: Service version string.
- `author`: Author display name.

Example:

```lua
{
    title = "Market Host",
    description = "Runs local market order tools.",
    version = "1.0.0",
    author = "YourName",
}
```

## Boot And Identity

On first boot, the user-server prompts for sign-in or sign-up. It registers with the main Tesserac server as a `user_server` device.

User-service daemons start only after authentication succeeds. This means `ServiceAPI.net` automatically sends requests through an authenticated rednet client.

The `user_server` device role currently has these scopes:

- `account.identity`
- `bank.access`
- `db.user`
- `web.origin`
- `web.publish`

## Daemon Services

`service.lua` runs inside a sandboxed process with `ServiceAPI` and `HCAPI` globals. `HCAPI` is an alias for `ServiceAPI` so simple service code can be shared with code that expects an HCAPI-like object.

Daemon code should yield regularly. A long loop that never yields will block other processes.

```lua
local api = ServiceAPI

api.log.info("market service started")
api.state.ticks = api.state.ticks or 0

while true do
    api.state.ticks = api.state.ticks + 1
    coroutine.yield("tick")
end
```

## UI Modules

`ui.lua` is loaded when the service is opened from the Services tab. It should return a table.

Supported functions:

- `app.render(ctx)`: Draw the UI. Called repeatedly while the UI is open.
- `app.on_event(ctx)`: Handle input. Return `false` to close the UI.

Example:

```lua
local api = ServiceAPI
local C = api.colors

local app = {}

function app.render(ctx)
    api.screen.clear(C.black)
    api.screen.write(2, 2, "Ticks: " .. tostring(api.state.ticks or 0), C.white, C.black)
    api.screen.write(2, 4, "Press Q to return", C.lightGray, C.black)
end

function app.on_event(ctx)
    if ctx.event.type == "key" and keys and ctx.event.raw and ctx.event.raw[2] == keys.q then
        return false
    end
    return true
end

return app
```

## ServiceAPI

### `ServiceAPI.identity`

The signed-in identity table for the user-server account.

Common fields:

- `tesserac_id`
- `username`
- `display_name`
- `session_token`
- `device`
- `account`

Do not print or expose `session_token` to users or web pages.

### `ServiceAPI.colors` and `ServiceAPI.colours`

Aliases for the ComputerCraft color table. Use these with `ServiceAPI.screen`.

### `ServiceAPI.state`

Shared in-memory state for this service ID. The daemon and UI receive the same table while the OS is running.

This is useful for counters, cached records, status messages, and data that does not need to survive reboot.

Persistent data should use `ServiceAPI.fs`.

### `ServiceAPI.log.info(message)`

Writes an info log line to the user-server log.

```lua
ServiceAPI.log.info("order book synced")
```

### `ServiceAPI.log.warn(message)`

Writes a warning log line to the user-server log.

```lua
ServiceAPI.log.warn("sync failed: " .. tostring(err))
```

## Service-Scoped Storage

Storage is rooted at:

```text
user_services_data/<service_id>/
```

Paths are relative to that folder. Absolute paths and `..` path traversal are rejected with `InvalidPath`.

### `ServiceAPI.fs.path(path)`

Returns the underlying service-scoped path for a relative path, or `nil, "InvalidPath"`.

Most services should prefer `read`, `write`, `list`, and `exists`.

### `ServiceAPI.fs.read(path)`

Reads a text file from service storage.

Returns:

- `data` on success
- `nil, "NotFound"` if missing
- `nil, "OpenFailed"` if the file cannot be opened
- `nil, "InvalidPath"` for unsafe paths

### `ServiceAPI.fs.write(path, data)`

Writes a text file to service storage, creating parent folders as needed.

Returns:

- `true` on success
- `false, "OpenFailed"` if the file cannot be opened
- `false, "InvalidPath"` for unsafe paths

### `ServiceAPI.fs.list(path)`

Lists files and folders under a service storage directory.

Pass `""` or omit the path to list the service storage root.

Returns:

- table of names on success
- empty table if the folder does not exist
- empty table plus an error for invalid paths

### `ServiceAPI.fs.exists(path)`

Returns `true` if a relative storage path exists, otherwise `false`.

## Network API

`ServiceAPI.net` uses the user-server's authenticated rednet client. Messages are sent to the main Tesserac server and automatically include the signed-in account identity when the rednet driver attaches it.

### `ServiceAPI.net.send(message)`

Sends a fire-and-forget message.

Returns:

- `true` on send
- `false, "NetworkUnavailable"` if rednet is not available
- `false, <error>` if discovery/send fails

### `ServiceAPI.net.request(message, expected_type, timeout)`

Sends a request and waits for a response.

Parameters:

- `message`: table to send.
- `expected_type`: response message type to wait for.
- `timeout`: optional seconds, default `5`.

Returns the response table on success, or `nil, <error>` on failure.

Example user DB write:

```lua
local reply, err = ServiceAPI.net.request({
    type = "db.set",
    key = "market/config",
    value = { enabled = true },
}, "db.set.result", 6)

if not reply or not reply.ok then
    ServiceAPI.log.warn("db.set failed: " .. tostring((reply and reply.error) or err))
end
```

Example web origin registration:

```lua
local reply, err = ServiceAPI.net.request({
    type = "web.register",
    domain = "market.example",
    origin = true,
    title = "Market",
    origin_label = "Market User Server",
}, "web.register.result", 8)
```

## Local Rednet API

`ServiceAPI.rednet` lets user-services host and use local ComputerCraft rednet protocols for non-HyperCube devices on the same modem network. `ServiceAPI.localnet` is an alias for the same API.

The Tesserac protocol used by the user-server itself is reserved. Calls using that protocol return `ReservedProtocol`.

### `ServiceAPI.rednet.host(protocol, hostname)`

Opens the modem and advertises a rednet host name on `protocol`.

Returns:

- `true, { protocol = protocol, hostname = hostname }` on success
- `false, "ReservedProtocol"` for the user-server's Tesserac protocol
- `false, "RednetUnavailable"` or `false, "NetworkUnavailable"` if no modem/rednet path is available

### `ServiceAPI.rednet.unhost(protocol, hostname)`

Stops advertising a hosted protocol. If `hostname` is omitted, the last hostname hosted by this service for that protocol is used.

### `ServiceAPI.rednet.send(target, message, protocol)`

Sends `message` to a ComputerCraft computer id using the given local protocol.

### `ServiceAPI.rednet.broadcast(message, protocol)`

Broadcasts `message` on the given local protocol.

### `ServiceAPI.rednet.receive(protocol, timeout)`

Receives one local message from `protocol`. `timeout` defaults to `0.05` seconds and is capped at `5` seconds so daemons cannot block forever by accident.

Returns:

- `{ sender = id, message = message, protocol = protocol }` on success
- `nil, "NoMessage"` on timeout
- `nil, <error>` on setup/validation failure

### `ServiceAPI.rednet.lookup(protocol, hostname)`

Looks up a ComputerCraft rednet host on a local protocol.

Example local echo service:

```lua
local api = ServiceAPI
api.rednet.host("market-local", "market-terminal")

while true do
    local event = api.rednet.receive("market-local", 0.25)
    if event and type(event.message) == "table" and event.message.type == "ping" then
        api.rednet.send(event.sender, {
            type = "pong",
            server = api.identity and api.identity.username,
        }, "market-local")
    end
    os.sleep(0)
end
```

## Screen API

The screen API draws to the user-server screen while a UI is open.

### `ServiceAPI.screen.write(x, y, text, fg, bg)`

Writes text at `x, y`.

Returns `true`, or `false, "ScreenUnavailable"`.

### `ServiceAPI.screen.clear(bg)`

Clears the screen. `bg` is optional.

Returns `true`, or `false, "ScreenUnavailable"`.

### `ServiceAPI.screen.size()`

Returns `width, height`.

If no screen is available, returns `0, 0`.

### `ServiceAPI.screen.button(id, x, y, width, label, options)`

Draws a one-row button using the kernel screen driver and returns a button hitbox.

`options` may include:

- `fg`: text color
- `bg`: background color

The returned hitbox has:

- `id`
- `x`
- `y`
- `width`
- `height`
- `contains(button, tx, ty)`

Service UIs normally let the UI event loop receive touch events through `app.on_event(ctx)` and can compare the event coordinates to stored buttons.

## UI Context

`app.render(ctx)` receives:

- `ctx.api`: the same `ServiceAPI`
- `ctx.state`: UI-local state table
- `ctx.screen`: raw screen driver object

`app.on_event(ctx)` receives:

- `ctx.api`
- `ctx.state`
- `ctx.screen`
- `ctx.event`

Important event shapes:

- Touch: `ctx.event.type == "touch"`, with `x` and `y`
- Key: `ctx.event.type == "key"`, with raw key data in `ctx.event.raw`
- Char: `ctx.event.type == "char"`, with raw character data in `ctx.event.raw`

Return `false` from `on_event` to close the UI and return to the user-server Services tab.

## Expected Limits

User-services have more capability than phone apps but are still not root OS code.

Expected constraints:

- No direct OS source modification API is exposed.
- File access is scoped to `user_services_data/<service_id>`.
- Tesserac service network access goes through the signed-in user-server rednet client.
- Local rednet access is limited to non-reserved protocols and intended for nearby ComputerCraft devices.
- Daemons must yield to keep the OS responsive.
- UI code only runs while opened from the Services tab.
