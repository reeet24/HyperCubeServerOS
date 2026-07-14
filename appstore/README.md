Dynamic HyperCube App Store

Put server-hosted apps in:

  appstore/apps/<app_id>/app.lua

Optionally add:

  appstore/apps/<app_id>/manifest

Manifest files use textutils.serialize/textutils.unserialize table format:

  {
    title = "My App",
    label = "Mine",
    version = "1.0.0",
    author = "Me",
    description = "Installs from the server app store."
  }

The server scans this folder on each appstore.list and appstore.download request.
Open the phone App Store and press Refresh after adding or replacing an app.
