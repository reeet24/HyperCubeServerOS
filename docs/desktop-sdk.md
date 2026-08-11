# HyperCube Desktop SDK

The HyperCube Desktop SDK is the official workflow for building desktop user apps from a HyperCube desktop device.

## Requirements

- Use a `TDesktop` or `TBusinessDesktop`.
- Enable dev mode first.
- Use the Terminal app or the HyperCube SDK app.

## Terminal Workflow

Create a new app:

```text
appnew my_app
```

This creates:

```text
/dev/apps/my_app/manifest
/dev/apps/my_app/app.lua
```

Run sandboxed Lua from Terminal:

```text
lua 1 + 2
run /dev/test.lua
```

Lint a file:

```text
applint /dev/apps/my_app/app.lua
```

Install a local UserFS app:

```text
appinstalllocal /dev/apps/my_app
```

Install and open it on desktop:

```text
apprun /dev/apps/my_app
```

Remote dev installs still work:

```text
appinstall pastebin <paste_id> [app_id]
appinstall github <owner/repo> <path> [branch] [app_id]
```

## App Shape

Every app needs an `app.lua` that returns an app table:

```lua
local api = HCAPI
local C = api.colors

local app = {
    manifest = {
        title = "My App",
        label = "App",
        devices = { "TDesktop", "TBusinessDesktop" },
        refresh_rate = 10,
    },
}

function app.render(ctx)
    api.screen.rect(ctx.x, ctx.y, ctx.width, ctx.height, C.black)
    api.screen.write(ctx.x + 1, ctx.y + 1, "Hello", C.yellow, C.black)
end

return app
```

## SDK App

The `HyperCube SDK` app is desktop-only. It can:

- scaffold a starter project;
- edit `app.lua`;
- lint the current source;
- show completion options;
- request the latest docs from `docs.tesserac`;
- install and run the app;
- open an embedded SDK terminal popup while dev mode is active.

The Docs tab fetches raw markdown pages from the main server through HyperNet, using `web.get` against `docs.tesserac/raw/<doc_id>`. It falls back to a short built-in summary when offline.

## Sandboxed Lua

Terminal `lua` and `run` use the same user-app sandbox style as installed apps. Code receives:

- `HCAPI` and `api`
- Lua primitives such as `math`, `string`, `table`, `coroutine`
- ComputerCraft constants such as `colors`, `colours`, `keys`, and `textutils`
- safe `os` time helpers

It does not receive direct root filesystem, shell, or unrestricted OS access. Use `HCAPI.fs` for app-local storage and `HCAPI.userfs` for desktop UserFS access.

## Completion

Press `Tab` in Terminal to show completions for common APIs such as:

- `HCAPI.screen.write`
- `HCAPI.screen.button`
- `HCAPI.fs.read`
- `HCAPI.userfs.write`
- `HCAPI.desktop.open_popup`
- `HCAPI.desktop.open_terminal`
- `HCAPI.bank.purchase`

The SDK app also includes a Completions tab.
