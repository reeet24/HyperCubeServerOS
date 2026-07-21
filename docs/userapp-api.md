# Tesserac User App API

Phone apps run inside the HyperCube phone shell and receive a global `HCAPI` object. Most built-in apps alias it as:

```lua
local api = HCAPI
local C = api.colors
```

Apps are Lua modules that return an `app` table. The phone app manager reads `app.manifest` and calls app lifecycle functions such as `render(ctx)`, `on_touch(ctx)`, and `on_key(ctx)` when present.

Rendering is driven by a stable frame loop rather than by input events. Input handlers update app state, and the shell presents the next frame on the configured cadence.

## App Layout

The app entrypoint is always `app.lua`.

Single-file app:

```text
appstore/apps/example/app.lua
appstore/apps/example/manifest
```

Multi-file app:

```text
appstore/apps/doom/app.lua
appstore/apps/doom/main.lua
appstore/apps/doom/lib/render.lua
appstore/apps/doom/assets/title.nfp
appstore/apps/doom/levels/e1m1.lua
```

User-installed apps are copied to the phone under `user/apps/<app_id>/`. The runtime treats that folder as the app's local code/assets bundle.

## Manifest

```lua
local app = {
    manifest = {
        title = "Example",
        label = "Ex",
        color = C.cyan,
        dock = true,
        render_mode = "exclusive",
        refresh_rate = 10,
    },
}
```

- `title`: Full app name shown by the shell.
- `label`: Short launcher label.
- `color`: App accent color.
- `dock`: `true` for docked apps.
- `render_mode`: Use `"exclusive"` for full-screen app rendering.
- `refresh_rate`: Optional frames per second while the app is active. Defaults to `10`, clamps from `1` to `30`. `fps` and `frame_rate` are accepted aliases.

Manifest files in `appstore/apps/<app_id>/manifest` use `textutils.serialize` table format:

```lua
{
    title = "Doom",
    label = "Doom",
    version = "0.1.0",
    author = "You",
    description = "A HyperCubeOS port.",
    entry = "app.lua",
    mutable_paths = {
        "mods",
        "config/user_settings.lua",
        "saves",
    },
}
```

`entry` is metadata for tooling and should remain `"app.lua"` unless the app manager is updated to support alternate entrypoints.

### App Integrity

Apps installed from the appstore include an encoded `.hcapp_integrity` record. The phone verifies protected file checksums before loading the app. If a protected file changes, the app fails to load with errors such as `AppChecksumMismatch:<path>` or `AppIntegrityMissing`.

Developers can allow modding by listing paths in `mutable_paths` in the appstore manifest. Mutable paths are installed normally but excluded from the app checksum, so users may edit them without breaking the app.

Rules:

- `app.lua` is always protected.
- `.hcapp_integrity` is reserved and cannot be packaged.
- A path entry protects/excludes that exact file or a whole folder prefix.
- Keep payment code, merchant usernames, entitlement checks, `api.bank.purchase` calls, and `api.bank.escrow` order logic outside mutable paths.
- Put mod files, config, saves, texture packs, and user scripts under mutable folders such as `mods/`, `config/`, or `saves/`.

## Context

Render and input functions receive `ctx`.

Common fields:

- `ctx.x`, `ctx.y`: Top-left drawing origin for the app.
- `ctx.width`, `ctx.height`: Available drawing area.
- `ctx.buttons`: Button hit-test table populated by `api.screen.button`.
- `ctx.button_id`: Button ID from the most recent touch event, when applicable.
- `ctx.screen_manager`: Present when using `api.screen.manager`.
- `ctx.frame`: Frame timing snapshot.

Use `ctx.x` and `ctx.y` for all coordinates so apps render correctly inside the phone shell.

### Frame Timing

`ctx.frame` is available in `render`, `on_touch`, `on_key`, and `on_tick`.

```lua
ctx.frame.now          -- current os.clock() time
ctx.frame.last         -- previous frame time
ctx.frame.dt           -- seconds since previous frame
ctx.frame.count        -- frame counter
ctx.frame.refresh_rate -- active FPS
ctx.frame.interval     -- target seconds per frame
```

Use `ctx.frame.dt` for movement, timers, and animation:

```lua
state.x = (state.x or 1) + 10 * ctx.frame.dt
```

### Lifecycle Hooks

Apps may define:

- `app.render(ctx)`: Draw the current state. Called every scheduled frame.
- `app.on_tick(ctx)`: Update simulation state once per scheduled frame before `render`.
- `app.on_touch(ctx)`: Handle touch and scroll input. Return `true` if state changed.
- `app.on_key(ctx)`: Handle key, char, paste, and key-up input. Return `true` if state changed.
- `app.on_resume(ctx)`: Called when the app opens.
- `app.on_pause(ctx)`: Called when the app closes or another app opens.

For games, put physics or animation updates in `on_tick` and drawing in `render`.

## Identity

`api.identity` contains the signed-in account identity available to the app:

```lua
api.identity.tesserac_id
api.identity.username
api.identity.display_name
```

Network requests made through `api.hypernet` automatically attach `tesserac_id`, `username`, and `session_token`.

## Banking

Apps can use `api.bank` for account status, transfers, idempotent in-app purchases, and escrow-backed market orders.

```lua
local ok, result = api.bank.purchase({
    to = "merchant_username",
    amount = 5,
    item_id = "extra_level_pack",
    purchase_id = api.app_id .. ":extra_level_pack:" .. tostring(api.time()),
    memo = "Extra level pack",
})
```

Use `api.bank.purchase` instead of raw transfers for purchases because `purchase_id` prevents duplicate charges on retry. For markets, use `api.bank.escrow.create`, `release`, `refund`, and `cancel` to hold buyer funds until an order is fulfilled. See `docs/banking-api.md` for the full banking contract.

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
- `api.phone.pay(purchase_id)`
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

Pass a stable `purchase_id` to `api.phone.pay` when building a payment UI. The Messages app persists that id before paying so a timeout/retry does not double-charge the weekly subscription.

## File API

Apps store data in their app-scoped HCFS directory through `api.fs`.

- `api.fs.read(path)`
- `api.fs.write(path, data)`
- `api.fs.list(path)`
- `api.fs.exists(path)`
- `api.fs.delete(path)`

Paths are scoped to the app ID. Apps cannot read another app's files through this API.

Use `api.fs` for saves, settings, caches, and user-created data. Do not use it for bundled read-only assets.

## App Bundle API

Installed multi-file apps can read files from their own app bundle through `api.app`.

- `api.app.read(path)`
- `api.app.list(path)`
- `api.app.exists(path)`

Example:

```lua
local title_image = api.app.read("assets/title.nfp")
local levels = api.app.list("levels")
```

Bundle paths are relative to `user/apps/<app_id>/` and reject parent-directory traversal. Apps cannot read another app's bundle through this API.

Use `api.app` for static assets included with the app package: paintutils images, level data, sprite sheets, map data, and local Lua modules.

## App-Local Modules

User apps can split code into local Lua modules and load them with `require`.

```lua
-- app.lua
local main = require("main")
return main.create_app(HCAPI)
```

```lua
-- main.lua
local render = require("lib.render")

local M = {}

function M.create_app(api)
    return {
        manifest = {
            title = "Doom",
            label = "Doom",
            render_mode = "exclusive",
            color = api.colors.red,
        },
        render = function(ctx)
            render.frame(ctx, api)
        end,
    }
end

return M
```

`require("lib.render")` loads `lib/render.lua` from the same installed app folder. It does not load arbitrary system files.

## App Store API

`api.apps.install(package)` installs an app package when the shell allows installs.

Returns `false, "InstallUnavailable"` if install support is not available.

### Package Format

Apps installed from the appstore must include the encoded `integrity_encoded` field generated by the server. Direct unsigned packages are rejected with `AppIntegrityRequired`.

Single-file appstore packages may still include `source` for compatibility:

```lua
{
    id = "notes",
    title = "Notes",
    version = "1.0.0",
    source = "local api = HCAPI\nreturn { manifest = { title = 'Notes' } }\n",
    integrity_encoded = "...",
}
```

Multi-file packages use `files`:

```lua
{
    id = "doom",
    title = "Doom",
    version = "0.1.0",
    author = "You",
    description = "A HyperCubeOS port.",
    mutable_paths = { "mods", "config", "saves" },
    integrity_encoded = "...",
    files = {
        { path = "app.lua", data = "return require('main')" },
        { path = "main.lua", data = "-- game code" },
        { path = "lib/render.lua", data = "-- renderer helpers" },
        { path = "assets/title.nfp", data = "-- paintutils image data" },
        { path = "levels/e1m1.lua", data = "return { name = 'E1M1' }" },
    },
}
```

The appstore download response includes both `source` for older single-file installers and `files` for multi-file installers. Current phone installs prefer the bundle and skip duplicate `source` writes when `files` already contains `app.lua`. The response also includes `integrity_encoded`, `protected_file_count`, and `mutable_paths`.

Reserved and invalid bundle paths:

- `manifest` is reserved.
- `.hcapp_integrity` is reserved.
- Empty paths are rejected.
- Parent traversal such as `../secret` is rejected.
- Absolute paths are normalized to app-relative paths.

### Server-Side App Folder

You can also publish by placing files directly on the server:

```text
appstore/apps/doom/app.lua
appstore/apps/doom/main.lua
appstore/apps/doom/lib/render.lua
appstore/apps/doom/assets/title.nfp
appstore/apps/doom/manifest
```

The server scans this folder on `appstore.list` and includes all files on `appstore.download`.

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
7. Use `api.app` for bundled read-only assets.
8. Split larger apps with app-local `require`.
9. Use `api.hypernet.request` for service calls not covered by `api.phone`.
