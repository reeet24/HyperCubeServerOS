# Tesserac Server Code Flow

This document describes how the main Tesserac server boots, accepts phones, routes HyperNet messages, and connects services.

The source tree intentionally uses `Kernal/` as the kernel directory name. Keep that spelling unless every `require("Kernal...")` call is changed.

## Top-Level Boot

1. `startup.lua` loads `init.lua`.
2. `init.lua` creates the `HyperCube` table, imports drivers and services, and defines `HyperCube.boot()`.
3. `HyperCube.boot()` starts logging, screen support, rednet, disk database, services, installer metadata, and background daemon tasks.
4. The server does not need a user TesseracID for itself, so `HyperCube.ensure_identity()` returns immediately.
5. The GUI starts and the server remains online while daemon processes handle work.

## Composition Root

`init.lua` is the server composition root. It owns the long-lived service objects:

- `HyperCube.network`: Rednet driver for protocol `tesserac`.
- `HyperCube.database`: DiskDB replicated key/value store.
- `HyperCube.web`: Web service.
- `HyperCube.phone`: Phone number and message service.
- `HyperCube.bank`: Bank of Ba$h service.
- `HyperCube.installer`: Install media and update packaging service.
- Other service modules such as app store, ATM monitor, moderation, documentation, and software updates.

Services are installed against `HyperCube` so they can share the same database, network driver, logger, and root context.

## Driver Layer

### Rednet Driver

`Kernal/drivers/rednet.lua` is the main network edge.

Responsibilities:

- Host protocol `tesserac`.
- Advertise server hostnames.
- Accept `hello` handshakes.
- Enforce phone ROM checksum integrity.
- Track client identity/session metadata.
- Handle core message families directly.
- Dispatch registered service handlers.

Important server-hosted names:

- `HyperCubeServer`
- `TesseracServer`
- `tesserac-server`

### DiskDB Driver

`Kernal/drivers/diskdb.lua` provides replicated persistent storage.

It splits attached disks into equal groups. Each group is a full replica of the keyspace, and each disk inside a group stores a shard of that keyspace. This gives more than one disk of capacity while still allowing parity and replica checks.

Service code uses:

- `database:get(key)`
- `database:set(key, value)`
- `database:delete(key)`
- `database:summary()`

There is no general service-level key scan API, so services that need lookup by multiple identifiers must maintain explicit indexes.

## Phone Connection Flow

1. Phone boots from `hypercube.rom`.
2. Phone network driver finds the Tesserac server.
3. Phone sends `hello` with role, device type, and ROM checksum.
4. Server compares checksum to `expected_phone_rom_checksum`.
5. If the checksum is missing or wrong, the client is rejected for normal APIs.
6. Rejected phones may still call `update.*`.
7. Accepted phones can sign in, register devices, and call scoped APIs.

This keeps app store, bank, phone, web, and database APIs restricted to the server-approved phone ROM.

## Identity Flow

`Kernal/services/tesseracid.lua` owns accounts, sessions, and devices.

Sign up:

1. Client sends `auth.signup`.
2. Server normalizes the username.
3. Server creates a Tesserac account record under `account:<username>`.
4. Server creates a Tesserac ID link under `account:tid:<tesserac_id>`.
5. Server registers the current device.
6. Server returns account identity and a session token.

Sign in:

1. Client sends `auth.signin`.
2. Server resolves username or `tid_...`.
3. Server checks the password hash.
4. Server creates a new session token.
5. Server registers or refreshes the current device.
6. Server returns public account and device data.

Sign out:

1. Client sends `auth.signout` with the current TesseracID session.
2. Server removes that session token and marks the device signed out.
3. Client deletes `user/tesseracid`, clears the local HCFS identity, and reboots to the sign-in flow.

Recovery:

1. A user selects recovery from the boot identity menu.
2. Client sends `auth.recovery.request` with the account username or `tid_...`, a new password hash, and device details.
3. Server stores a pending recovery request under `auth:recovery:<id>` and indexes it for the official `tesserac` account.
4. The official `tesserac` account opens Settings, refreshes pending requests, and sends `auth.recovery.approve`.
5. Server updates the account password hash, keeps the existing HCFS key, clears existing sessions, and marks registered devices as requiring recovery sign-in.
6. The user signs in with the new password after approval.

Sessions are validated by service code through `tesseracid.validate_session(...)`.

## Device Scopes

Device scopes limit what a signed-in device can do.

Examples:

- `account.identity`: Read account identity.
- `db.user`: Access user-scoped database APIs.
- `phone.access`: Use phone number and messaging APIs.
- `web.publish`: Publish stored HCTML pages.
- `web.origin`: Register routed web origins.
- `bank.access`: Use regular banking APIs.
- `bank.deposit`: Use trusted ATM/branch banking APIs.

Business-only devices such as ATMs and bank branches require business accounts for sensitive banking operations.

## HyperNet Message Flow

For a normal phone app request:

1. App calls `api.hypernet.request(message, expected_type, timeout)`.
2. HCAPI attaches identity and sets `hypernet = true`.
3. Phone network sends the rednet message.
4. Server rednet driver receives it.
5. Rednet driver checks rejection and scope rules.
6. A built-in handler or registered service processes the message.
7. Server sends a `*.result` response.
8. App receives the reply.

## Built-In Rednet Message Families

The rednet driver handles these directly:

- Discovery: `server.lookup`, `server.announce`
- Handshake: `hello`, `welcome`, `server.reject`
- Identity: `identify`, `auth.resolve`, `auth.signup`, `auth.signin`, `auth.signout`, `auth.recovery.*`, `device.register`, `device.list`
- Database: `db.status`, `db.get`, `db.set`, `db.delete`
- Web: `web.register`, `web.publish`, `web.resolve`, `web.get`, `web.request`, `web.list`
- Phone: `phone.status`, `phone.subscribe`, `phone.pay`, `phone.send`, `phone.inbox`, `phone.sync`, `phone.chats`, `phone.chat`, `phone.chat.delete`
- Updates: `update.status`, `update.download`, `update.chunk`

Installed service handlers handle:

- Banking: `bank.*`
- Moderation: `moderation.*`
- ATM monitor: `atm.*`
- App store: `appstore.*`
- App store, moderation, documentation, ATM, banking, phone, web, database, and update service families

## Web Flow

Stored page flow:

1. User registers a domain with `web.register`.
2. User publishes HCTML with `web.publish`.
3. Browser calls `web.get`.
4. Server loads `web:page:<domain>:<path>` and returns rendered page data.

Routed origin flow:

1. Origin device registers with `web.register`, `origin = true`.
2. Browser calls `web.get` or `web.request`.
3. Server sends `web.origin.request` to the origin device.
4. Origin replies with `web.origin.response`.
5. Server compiles HCTML or returns the body result.

The moderation portal at `moderation.tesserac` is served directly by `moderation_server.lua` before normal origin routing.

## Phone Service Flow

`phone_numbers.lua` manages phone subscriptions and messages.

Subscription:

1. Phone calls `phone.subscribe`.
2. Server requires an open bank account for the TesseracID.
3. First subscription assigns a number and sets one free week.
4. Later renewals charge the linked bank account weekly through `bank.purchase`.
5. Clients may pass `purchase_id` to `phone.pay` for retry-safe renewals.

Messaging:

1. Sender calls `phone.send`.
2. Server validates sender number and recipient number.
3. Message is written into recipient inbox and server-side chat records.
4. Recipient syncs through `phone.sync`, `phone.chats`, or `phone.chat`.

Message reports are sent to moderation through `moderation.report`.

## Banking Flow

`banking_server.lua` exposes network handlers and `banking.lua` implements account behavior.

Regular user operations:

- `bank.open`: Opens an account. Requires `minecraft_name`.
- `bank.status`: Returns public account state.
- `bank.history`: Returns recent transaction history.
- `bank.transfer`: Transfers TC between accounts.
- `bank.purchase`: Idempotent in-app purchase transfer keyed by `purchase_id`.

Trusted ATM/branch operations:

- `bank.deposit`
- `bank.withdraw`
- `bank.atm.fee`
- `bank.branch.trust`
- `bank.branch.revoke`

Trusted operations require:

- A valid session.
- A business account.
- A device role of `bank_branch` or `atm`.
- The `bank.deposit` scope.
- A server trust record for the device.

## Moderation Flow

`moderation_server.lua` handles both API reports and the authenticated web portal.

Report flow:

1. User selects a message in the Messages app.
2. App calls `api.phone.report_message(...)`.
3. Server validates `phone.access`.
4. Report is stored under `moderation:report:<id>`.
5. Report ID is added to `moderation:reports:index`.

Admin portal flow:

1. Authorized user opens `moderation.tesserac`.
2. Server validates `account.identity`.
3. Server checks `moderation:authorized`.
4. User can view reports, authorize moderators, and look up accounts.

The default authorized account is `tesserac`.

## Update Flow

`software_updates.lua` and `installer.lua` keep phone ROMs aligned with the server.

1. Server packages deterministic install images from local `installer/...` source or from the GitHub-backed in-memory installer cache.
2. Server stores the expected phone ROM checksum and refreshes it when update metadata/package requests rebuild the phone ROM.
3. Phone asks `update.status`.
4. If needed, phone downloads chunks with `update.download` and `update.chunk`.
5. Phone verifies checksum before writing the new ROM and rebooting.

`update.*` remains available even when a phone is rejected for ROM mismatch.
When `server_config.installer.source_mode` is `github`, the server updater skips local `installer/...` files. `installer.lua` checks the configured GitHub installer tree hash, downloads the installer tree into memory only when needed, and drops the cache after the configured idle timeout.

When `server_config.appstore.source_mode` is `github`, seed appstore apps under `appstore/apps` are also skipped by server updates. `appstore.lua` checks the configured GitHub appstore tree hash, serves GitHub-backed seed apps from memory, and drops the cache after the configured idle timeout. Apps published through the appstore API remain in the sharded appstore DiskDB.

## Where To Add New Work

- New phone app: `installer/hypercube_phone/apps/<app_id>/app.lua`
- New app API helper: `installer/hypercube_phone/Kernal/services/hcapi.lua`
- New core server service: `Kernal/services/<service>.lua`, installed from `init.lua`
- New network handler family: register through `hypercube.network:register_handler(...)`
- New persistent lookup by non-primary key: create an explicit database index record
- New web portal page: add a route in `moderation_server.lua` or publish HCTML through `web.publish`
