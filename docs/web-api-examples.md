# Tesserac Web API Examples

This file contains copyable examples for common web tasks.

## Publish a Simple Page From a Phone App

```lua
local api = HCAPI

local reply, err = api.hypernet.request({
    type = "web.register",
    domain = "hello.tesserac",
    title = "Hello",
}, "web.register.result", 6)

if not reply or not reply.ok then
    error((reply and reply.error) or err or "register failed")
end

reply, err = api.hypernet.request({
    type = "web.publish",
    domain = "hello.tesserac",
    path = "/",
    hctml = [[
<page title="Hello">
<h1>Hello</h1>
<p>This page was published from a Tesserac phone app.</p>
</page>
]],
}, "web.publish.result", 6)
```

## Fetch a Page

```lua
local reply, err = api.hypernet.request({
    type = "web.get",
    domain = "hello.tesserac",
    path = "/",
}, "web.get.result", 6)

if reply and reply.ok then
    local page = reply.result
    print(page.title)
end
```

## Minimal Routed Origin

```lua
local protocol = "tesserac"

rednet.host(protocol, "my-origin")
rednet.broadcast({
    type = "web.register",
    domain = "live.tesserac",
    title = "Live",
    origin = true,
    supports_api = true,
}, protocol)

while true do
    local sender, message = rednet.receive(protocol)
    if type(message) == "table" and message.type == "web.origin.request" then
        rednet.send(sender, {
            type = "web.origin.response",
            request_id = message.request_id,
            ok = true,
            content_type = "hctml",
            hctml = "<page title=\"Live\"><h1>Live</h1><p>Dynamic page.</p></page>",
            status = 200,
        }, protocol)
    end
end
```

