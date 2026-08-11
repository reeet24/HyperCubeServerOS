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

Desktop storage commands:

```text
drives
formatdrive <drive> [label]
mounts
```

Formatted drives receive a `.hypercube_desktop_drive` marker plus `hypercube/apps` and `hypercube/appdata` folders. When a formatted drive is mounted, desktop app installs prefer that drive. Removing the disk hides apps installed on it until the disk is reinserted.

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

- manage projects under `/dev/apps`;
- create starter projects with app, lib, assets, and manifest files;
- browse and edit multiple project files;
- edit package metadata through the manifest panel and SDK terminal commands;
- lint every Lua file in the active project;
- show build/package details before installation;
- install and run the active project as a dev app;
- request the latest docs and search results from `docs.tesserac`;
- show API completions and insert completions into the editor;
- open an embedded SDK terminal popup while dev mode is active, with an in-window terminal tab as fallback.

The Docs tab fetches raw markdown pages from the main server through HyperNet, using `web.get` against `docs.tesserac/raw/<doc_id>`. It falls back to a short built-in summary when offline.

SDK terminal commands:

```text
help
new <id>
load <id>
file <relative_path>
save
lint
install
run
set title <value>
set label <value>
set version <value>
set desc <value>
doc <doc_id>
search <query>
lua <code>
```

## Sandboxed Lua

Terminal `lua` and `run` use the same user-app sandbox style as installed apps. Code receives:

- `HCAPI` and `api`
- Lua primitives such as `math`, `string`, `table`, `coroutine`
- ComputerCraft constants such as `colors`, `colours`, `keys`, and `textutils`
- safe `os` time helpers

It does not receive direct root filesystem, shell, or unrestricted OS access. Use `HCAPI.fs` for encrypted account storage, `HCAPI.storage` for app-private install-local data, and `HCAPI.userfs` for desktop UserFS access.

## Completion

Press `Tab` in Terminal to show completions for common APIs such as:

- `HCAPI.screen.write`
- `HCAPI.screen.button`
- `HCAPI.screen.line`
- `HCAPI.screen.tri`
- `HCAPI.screen.quad`
- `HCAPI.fs.read`
- `HCAPI.storage.write`
- `HCAPI.userfs.write`
- `HCAPI.desktop.open_popup`
- `HCAPI.desktop.open_terminal`
- `HCAPI.bank.purchase`

The SDK app also includes a Completions tab.
