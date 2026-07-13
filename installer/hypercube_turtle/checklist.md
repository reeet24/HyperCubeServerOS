# HyperCube Turtle

- Boots as a headless HyperCube OS for ComputerCraft turtles.
- Includes `Kernal.drivers.turtle` for movement, inventory, fuel, detect, dig, place, suck, and drop operations.
- Loads turtle user apps from `apps/<id>/app.lua` and `user/apps/<id>/app.lua`.
- Provides `HCAPI.fs`, `HCAPI.hypernet`, `HCAPI.turtle`, `HCAPI.web`, `HCAPI.log`, and `HCAPI.time`.
- Includes the Dedicated Webserver app.

## Dedicated Webserver

The default webserver app registers a HyperNet origin domain and serves:

- `/` as an HCTML status page.
- `/api/status` as a text API endpoint with fuel, selected slot, and used inventory slots.

Apps can add routes:

```lua
api.web.page("/status", "<page title=\"Status\"><h1>Online</h1></page>")
api.web.api("/api/do-work", function(request)
  return {
    content_type = "text",
    body = "ok\n",
  }
end)
```

## Floppy Persistence

When the server installer is set to `Turtle` and installs to a floppy, the floppy `startup.lua` copies `startup.lua` and `hypercube.rom` onto the turtle on first boot, writes `hypercube_install`, then reboots into the local install.
