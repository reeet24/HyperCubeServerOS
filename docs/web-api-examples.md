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

## Routed Origin With Tesserac Sign-In

This example uses the `auth` table attached to `web.origin.request`. The `subject_token` is a private per-domain user ID, similar to the stable user ID a website gets from "Sign in with Google".

```lua
local protocol = "tesserac"
local domain = "market.tesserac"

rednet.host(protocol, "market-origin")
rednet.broadcast({
    type = "web.register",
    domain = domain,
    title = "Market",
    origin = true,
    supports_api = true,
}, protocol)

local function verify_subject(server_id, auth)
    if type(auth) ~= "table" or not auth.subject_token then
        return false, "SignInRequired"
    end
    rednet.send(server_id, {
        type = "web.auth.verify",
        domain = domain,
        subject_token = auth.subject_token,
    }, protocol)
    local sender, reply = rednet.receive(protocol, 5)
    if sender == server_id and type(reply) == "table" and reply.type == "web.auth.verify.result" and reply.ok then
        return true, reply.result
    end
    return false, reply and reply.error or "VerifyFailed"
end

while true do
    local sender, message = rednet.receive(protocol)
    if type(message) == "table" and message.type == "web.origin.request" then
        local signed_in, subject = verify_subject(sender, message.auth)
        local body
        if signed_in then
            body = "<page title=\"Market\"><h1>Market</h1><p>Signed in as "
                .. tostring(subject.display_name or subject.username or subject.subject_token)
                .. ".</p><p>Private site user: "
                .. tostring(subject.subject_token)
                .. "</p></page>"
        else
            body = "<page title=\"Market\"><h1>Market</h1><p>Please sign in to Tesserac before using the market.</p></page>"
        end

        rednet.send(sender, {
            type = "web.origin.response",
            request_id = message.request_id,
            ok = true,
            content_type = "hctml",
            hctml = body,
            status = signed_in and 200 or 401,
        }, protocol)
    end
end
```

Store website-specific user data under `subject.subject_token`, not under the viewer's raw Tesserac ID. The token is stable for your domain but cannot be used to identify the same person on other domains.
