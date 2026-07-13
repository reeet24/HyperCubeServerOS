# Tesserac User App API

Phone apps run inside the HyperCube phone shell and receive a global `HCAPI` object. Most built-in apps alias it as:

```lua
local api = HCAPI
local C = api.colors
```

Apps are Lua modules that return an `app` table. The phone app manager reads `app.manifest` and calls app lifecycle functions such as `render(ctx)`, `on_touch(ctx)`, and `on_key(ctx)` when present.

## Manifest

```lua
local app = {
    manifest = {
        title = "Example",
        label = "Ex",
        color = C.cyan,
        dock = true,
        render_mode = "exclusive",
    },
}
```

- `title`: Full app name shown by the shell.
- `label`: Short launcher label.
- `color`: App accent color.
- `dock`: `true` for docked apps.
- `render_mode`: Use `"exclusive"` for full-screen app rendering.

## Context

Render and input functions receive `ctx`.

Common fields:

- `ctx.x`, `ctx.y`: Top-left drawing origin for the app.
- `ctx.width`, `ctx.height`: Available drawing area.
- `ctx.buttons`: Button hit-test table populated by `api.screen.button`.
- `ctx.button_id`: Button ID from the most recent touch event, when applicable.
- `ctx.screen_manager`: Present when using `api.screen.manager`.

Use `ctx.x` and `ctx.y` for all coordinates so apps render correctly inside the phone shell.

## Identity

`api.identity` contains the signed-in account identity available to the app:

```lua
api.identity.tesserac_id
api.identity.username
api.identity.display_name
```

Network requests made through `api.hypernet` automatically attach `tesserac_id`, `username`, and `session_token`.

## Colors

`api.colors` exposes ComputerCraft color constants with stable names:

- `black`, `white`, `gray`, `lightGray`
- `blue`, `cyan`, `green`, `red`
- `yellow`, `purple`, `orange`

## Screen API

### `api.screen.size()`

Returns `width, height`. Returns `0, 0` if the screen is unavailable.

### `api.screen.write(x, y, text, fg, bg)`

Writes one line of text.

Returns `true` or `false, "ScreenUnavailable"`.

### `api.screen.write_scroll(x, y, width, text, offset, fg, bg)`

Writes a horizontally scrolled one-line view of `text`.

- `width` is clamped to at least 1.
- `offset` is zero-based.

### `api.screen.wrap(text, width)`

Wraps text into a list of lines using the same wrapping logic as built-in phone apps.

Use this for previews, message bodies, URL bars, and any input that can grow across rows.

### `api.screen.write_wrap(x, y, text, width, height, fg, bg, offset)`

Wraps and writes text across multiple rows.

Returns:

```lua
true, lines
```

`offset` is a zero-based line offset for vertical scrolling.

### `api.screen.rect(x, y, width, height, bg)`

Fills a rectangle with `bg`.

### `api.screen.button(id, x, y, width, label, options)`

Draws a button and registers its hit area.

Typical use:

```lua
ctx.buttons.save = api.screen.button("save", ctx.x, ctx.y + 4, 8, "Save")
```

Then in touch handling:

```lua
if ctx.button_id == "save" then
    save()
    return true
end
```

## Screen Manager

Use `api.screen.manager(default_screen)` for multi-page apps.

```lua
local router = api.screen.manager("home")

router:define("home", {
    state = state,
    render = function(ctx, page_state, manager)
        api.screen.write(ctx.x, ctx.y, "Home", C.yellow, C.black)
        ctx.buttons.next = api.screen.button("next", ctx.x, ctx.y + 2, 8, "Next")
    end,
    on_touch = function(ctx, page_state, manager)
        if ctx.button_id == "next" then
            manager:set("details")
            return true
        end
        return false
    end,
})

router:define("details", {
    render = function(ctx)
        api.screen.write(ctx.x, ctx.y, "Details", C.yellow, C.black)
    end,
})
```

Manager methods:

- `manager:define(id, definition)`: Registers a screen.
- `manager:current()`: Returns `screen, id`.
- `manager:set(id, params)`: Switches screens and calls leave/enter hooks.
- `manager:back(fallback)`: Returns to history or fallback.
- `manager:render(ctx)`: Renders the active screen.
- `manager:touch(ctx)`: Sends touch to active screen.
- `manager:key(ctx)`: Sends key input to active screen.

Screen definitions may include:

- `state`
- `render(ctx, state, manager)`
- `on_touch(ctx, state, manager)`
- `on_key(ctx, state, manager)`
- `on_enter(state, params, manager)`
- `on_leave(state, manager)`

## HyperNet API

### `api.hypernet.request(message, expected_type, timeout)`

Sends a request to the Tesserac server and waits for `expected_type`.

```lua
local reply, err = api.hypernet.request({
    type = "phone.status",
}, "phone.status.result", 6)

if reply and reply.ok then
    -- reply.result
end
```

All messages sent through this function get:

- `hypernet = true`
- signed-in Tesserac identity fields

### `api.hypernet.send(message)`

Sends a message without waiting for a response.

### `api.hypernet.summary()`

Returns network status information, or `{ status = "offline" }`.

## Phone API

These helpers wrap HyperNet phone-service requests and return `ok, result_or_error`.

- `api.phone.status()`
- `api.phone.subscribe()`
- `api.phone.pay()`
- `api.phone.send(to, body)`
- `api.phone.sync()`
- `api.phone.chats()`
- `api.phone.chat(number, mark_read)`
- `api.phone.delete_chat(number)`
- `api.phone.report_message(chat_number, message, reason)`

Example:

```lua
local ok, result = api.phone.send("123456", "Hello")
if not ok then
    api.screen.write(ctx.x, ctx.y, tostring(result), C.red, C.black)
end
```

## File API

Apps store data in their app-scoped HCFS directory through `api.fs`.

- `api.fs.read(path)`
- `api.fs.write(path, data)`
- `api.fs.list(path)`
- `api.fs.exists(path)`
- `api.fs.delete(path)`

Paths are scoped to the app ID. Apps cannot read another app's files through this API.

## App Store API

`api.apps.install(package)` installs an app package when the shell allows installs.

Returns `false, "InstallUnavailable"` if install support is not available.

## Dev API

The terminal app and dev helpers require phone dev mode.

- `api.dev.is_enabled()`
- `api.dev.enable()`
- `api.dev.eval(source)`

Dev mode is intended for trusted development phones only. Do not expose dev-mode workflows to normal users.

## Recommended App Pattern

1. Keep app state in a local `state` table.
2. Use `api.screen.manager` for multi-page apps.
3. Draw only inside `ctx.x`, `ctx.y`, `ctx.width`, and `ctx.height`.
4. Register all buttons through `api.screen.button`.
5. Use `api.screen.wrap` or `api.screen.write_wrap` for user text.
6. Use `api.fs` for app data.
7. Use `api.hypernet.request` for service calls not covered by `api.phone`.

