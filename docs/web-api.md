# Tesserac Web API

The Tesserac web system serves HyperNet pages and API-style origin requests through the main rednet protocol. It supports stored HCTML pages and routed origin servers.

## Concepts

- Domain: A normalized Tesserac web domain such as `example.tesserac`.
- Path: A normalized path such as `/` or `/reports`.
- Stored page: HCTML saved in the server database.
- Routed origin: A registered device that receives live `web.origin.request` messages.
- HCTML: HyperCube markup compiled by `Kernal/services/hctml.lua`.

The internal moderation portal is a built-in special case at `moderation.tesserac`.

## Authentication

Most web write operations require a signed-in TesseracID session attached by the phone API or supplied manually:

- `tesserac_id`
- `username`
- `session_token`

Additional device scopes:

- `web.publish`: Required for `web.publish`.
- `web.origin`: Required for registering a routed origin.

## Register a Domain

Message:

```lua
{
    type = "web.register",
    domain = "example.tesserac",
    title = "Example",
}
```

Result type: `web.register.result`

Registers a stored domain owned by the caller's TesseracID.

Errors include:

- `WebUnavailable`
- `AuthRequired`
- `InvalidDomain`
- `DomainTaken`

## Register a Routed Origin

Message:

```lua
{
    type = "web.register",
    domain = "live.tesserac",
    title = "Live App",
    origin = true,
    origin_label = "main process",
    supports_api = true,
}
```

Result type: `web.register.result`

When `origin = true`, the caller must have the `web.origin` device scope. The server stores the sender ID as the domain `origin_id`.

Routed domains receive `web.origin.request` messages when clients call `web.get` or `web.request`.

## Publish a Stored Page

Message:

```lua
{
    type = "web.publish",
    domain = "example.tesserac",
    path = "/",
    hctml = [[
<page title="Example">
<h1>Hello</h1>
<p>Welcome to Tesserac web.</p>
</page>
]],
}
```

Result type: `web.publish.result`

The server compiles HCTML before saving the page. Compile failures are returned as errors.

Errors include:

- `ScopeDenied:web.publish`
- `DomainNotFound`
- `Forbidden`
- HCTML compile errors

## Resolve a Domain

Message:

```lua
{
    type = "web.resolve",
    domain = "example.tesserac",
}
```

Result type: `web.resolve.result`

Returns the domain record, including ownership and origin metadata.

## Fetch a Page

Message:

```lua
{
    type = "web.get",
    domain = "example.tesserac",
    path = "/",
}
```

Result type: `web.get.result`

For stored pages, returns a public page result:

```lua
{
    domain = "example.tesserac",
    path = "/",
    title = "Example",
    rendered = { ... },
    content_type = nil,
    body = nil,
    status = nil,
    routed = false,
}
```

For routed origins, the server sends the origin device a `web.origin.request`, compiles the returned HCTML or body, and returns the public page result.

Set `raw = true` to receive the stored page record without public result filtering.

## API-Style Web Request

Message:

```lua
{
    type = "web.request",
    domain = "live.tesserac",
    path = "/api/status",
    method = "GET",
    headers = {},
    query = {},
    body = nil,
    timeout = 6,
}
```

Result type: `web.request.result`

`web.request` is intended for routed origins. If the domain has no origin, the server returns `NoOriginForDomain`.

## Routed Origin Request

Routed origin servers receive:

```lua
{
    type = "web.origin.request",
    request_id = "webreq_...",
    domain = "live.tesserac",
    path = "/",
    method = "GET",
    headers = {},
    query = {},
    body = nil,
    api = true,
}
```

The origin must reply with:

```lua
{
    type = "web.origin.response",
    request_id = "webreq_...",
    ok = true,
    content_type = "hctml",
    hctml = "<page title=\"Live\"><h1>Live</h1></page>",
    status = 200,
    headers = {},
}
```

Error response:

```lua
{
    type = "web.origin.response",
    request_id = "webreq_...",
    ok = false,
    error = "NotFound",
    status = 404,
}
```

Origin errors may surface as:

- `OriginUnavailable`
- `OriginTimeout`
- `OriginError`

## List Owned Domains

Message:

```lua
{
    type = "web.list",
}
```

Result type: `web.list.result`

Returns domains owned by the signed-in account.

## Browser Addresses

The phone browser accepts:

- `moderation.tesserac`
- `moderation.tesserac/reports`
- `hyper://moderation.tesserac/reports`
- `hc://moderation.tesserac/reports`
- `hcm://moderation.tesserac/reports`

Relative links beginning with `/` stay on the current domain.

## Moderation Portal

`moderation.tesserac` is served by the main server, not by a routed origin.

Routes:

- `/`: Home
- `/reports`: Flagged messages
- `/accounts`: Account lookup instructions
- `/accounts/<username>`: Lookup by Tesserac username
- `/accounts/<phone_number>`: Lookup by phone number
- `/accounts/<tesserac_id>`: Lookup by Tesserac ID
- `/accounts/<minecraft_name>`: Lookup by Minecraft name indexed by bank account
- `/authorize`: Authorized user list and instructions
- `/authorize/<username>`: Authorize another moderator

Only users in the moderation authorized list can view the portal. The default authorized account is `tesserac`.

## HCTML Notes

HCTML is intentionally small. Existing pages use tags such as:

- `<page title="...">`
- `<h1>...</h1>`
- `<h2>...</h2>`
- `<p>...</p>`
- `<list>...</list>`
- `<item>...</item>`
- `<link href="/path">Label</link>`

Always escape user-provided text before inserting it into HCTML.

