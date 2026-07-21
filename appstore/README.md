Dynamic HyperCube App Store

Put server-hosted apps in:

  appstore/apps/<app_id>/app.lua

Apps may include extra files:

  appstore/apps/<app_id>/lib/render.lua
  appstore/apps/<app_id>/assets/title.nfp
  appstore/apps/<app_id>/levels/e1m1.lua

Optionally add:

  appstore/apps/<app_id>/manifest

Manifest files use textutils.serialize/textutils.unserialize table format:

  {
    title = "My App",
    label = "Mine",
    version = "1.0.0",
    author = "Me",
    description = "Installs from the server app store.",
    entry = "app.lua"
  }

The server scans this folder on each appstore.list and appstore.download request.
Open the phone App Store and press Refresh after adding or replacing an app.

Publish API packages can also send a bundle:

  {
    type = "appstore.publish",
    id = "doom",
    title = "Doom",
    version = "0.1.0",
    files = {
      { path = "app.lua", data = "return require('main')" },
      { path = "main.lua", data = "-- game code" },
      { path = "assets/title.nfp", data = "-- paintutils image data" },
    }
  }

Inside an installed app:

  local main = require("main")
  local image = HCAPI.app.read("assets/title.nfp")

App-local require only loads Lua files from that app's installed folder.
