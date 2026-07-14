# HyperCubeServer OS

HyperCubeServer is the main Tesserac server OS for ComputerCraft. It hosts the Tesserac rednet protocol, account identity, phone registration, user-scoped storage, web publishing, banking, messages, app store packages, software updates, and install media for HyperCube phones and turtles.

## Boot Flow

1. `startup.lua` loads `init.lua` and calls `HyperCube.boot()`.
2. `init.lua` starts file logging at `logs/kernel.log`.
3. The screen driver initializes if a terminal or monitor is available.
4. The rednet driver hosts protocol `tesserac` as `HyperCubeServer`.
5. The replicated disk database mounts from attached disk drives under `hypercube_db`.
6. Server services are constructed and registered.
7. The init system starts daemon tasks for the service handlers and event ticks.
8. `HyperCube.ensure_identity()` returns immediately on the server, then the GUI starts.

## Directory Layout

- `startup.lua`: ComputerCraft boot entrypoint.
- `init.lua`: Server OS composition root.
- `Kernal/`: Kernel APIs, drivers, process system, VFS, GUI, and services.
- `Kernal/drivers/`: Device and platform adapters such as rednet, screen, diskdb, and ramdisk.
- `Kernal/services/`: Tesserac service implementations.
- `appstore/`: Server-hosted app catalog and installable app packages.
- `installer/hypercube_phone/`: Source image packaged into the TPhone ROM.
- `installer/hypercube_turtle/`: Source image packaged for turtle installs.
- `logs/`: Local server logs.
- `package_server.lua`: In-game packaging helper.
- `package_server.py`: Host-side packaging helper.
- `hypercube_server_install`: Install stamp written by the pastebin installer.

## Dedicated Docs

- `docs/userapp-api.md`: Phone user app API and HCAPI reference.
- `docs/web-api.md`: HyperNet web API, HCTML publishing, routed origins, and moderation web routes.
- `docs/web-api-examples.md`: Copyable web publishing and origin examples.
- `docs/server-flow.md`: Full server boot, network, service, identity, banking, phone, web, moderation, and update flow.
- `docs/tos-draft.md`: Draft terms of service for phone and Tesserac users.

## GitHub Server Updates

Run `update_server.lua` on the main server computer to update source files from `reeet24/HyperCubeServerOS`.

Useful options:

- `update_server.lua --dry-run`: Fetch metadata and count files without changing anything.
- `update_server.lua --yes`: Update without the confirmation prompt.
- `update_server.lua --branch main`: Select a branch.
- `update_server.lua --root computer/0`: Force the server source root if auto-detection fails.

The updater replaces server source paths such as `Kernal`, `appstore`, `installer`, `docs`, `init.lua`, and `startup.lua`, while preserving local `logs`, `user`, `hypercube_db`, disk records, and admin tokens. Restart the server after updating.

## Kernel Pieces

- `context.lua`: Security context records for users, processes, groups, origin, and sandbox permissions.
- `acl.lua`: Access-control helpers.
- `process_manager.lua`: Coroutine process registry with PID, status, parent, and daemon support.
- `scheduler.lua`: Cooperative scheduler.
- `init_system.lua`: Startup task registration and daemon launch.
- `event_bus.lua`: Namespaced event emission and listening.
- `syscall.lua` and `syswrap.lua`: Controlled syscall routing and wrapped APIs.
- `vfs_api.lua` and `filehandle.lua`: Virtual filesystem abstraction and file handles.
- `module_loader.lua`: Kernel module loading.
- `program_runner.lua`: Sandboxed app/program execution.
- `stdlib.lua`: Safer standard library surface for programs.
- `logger.lua`: Persistent and sink-based logging.
- `gui.lua`: Server and phone UI shell.

## Drivers

- `rednet.lua`: Hosts or connects to the Tesserac rednet protocol. On the server it handles discovery, handshake rejection, identity registration, database requests, web requests, phone service calls, and registered service handlers.
- `screen.lua`: Terminal or monitor display initialization.
- `diskdb.lua`: Replicated disk-backed key/value database.
- `ramdisk.lua`: In-memory filesystem backend.

## Server Services

- `tesseracid.lua`: Account, password hash, session token, device registration, device scopes, and local identity persistence.
- `web.lua`: Domain registration, static HCTML publishing, origin routing, and page lookup.
- `hctml.lua`: HCTML compiler/renderer.
- `phone_numbers.lua`: Phone subscription, billing, messages, inbox, and payment state.
- `banking_server.lua`: Bank of Ba$h server integration.
- `chirper_server.lua`: Chirper timeline service.
- `train_schedule_server.lua`: CMR train schedule service.
- `appstore.lua`: App catalog and package serving.
- `installer.lua`: Phone/turtle install media and update package builder.
- `software_updates.lua`: Update status, ROM package download, and chunked ROM transfer.

## Rednet Protocol

The server hosts protocol `tesserac` with hostnames:

- `HyperCubeServer`
- `TesseracServer`
- `tesserac-server`

Important message groups:

- Discovery: `server.lookup`, `server.announce`
- Handshake: `hello`, `welcome`, `server.reject`
- Identity: `identify`, `auth.resolve`, `auth.signup`, `auth.signin`, `device.register`, `device.list`
- Database: `db.status`, `db.get`, `db.set`, `db.delete`
- Web: `web.register`, `web.publish`, `web.resolve`, `web.get`, `web.request`, `web.list`
- Banking: `bank.open`, `bank.status`, `bank.history`, `bank.transfer`, `bank.deposit`, `bank.withdraw`, `bank.atm.fee`, `bank.branch.trust`, `bank.branch.revoke`
- Moderation: `moderation.report`, `moderation.report.list`, `moderation.authorize`
- Phone: `phone.status`, `phone.subscribe`, `phone.pay`, `phone.send`, `phone.inbox`, `phone.sync`, `phone.chats`, `phone.chat`, `phone.chat.delete`
- Updates: `update.status`, `update.download`, `update.chunk`

The ROM integrity gate runs before registered service handlers. The only handler family allowed before ROM approval is `update.*`, so a rejected phone can download the correct ROM but cannot reach app store, banking, Chirper, train, account, database, web, or phone APIs.

## Phone ROM Integrity Gate

The production phone gate is enforced by the server, not just the phone.

The server calculates the expected TPhone ROM checksum from `installer/hypercube_phone` during boot:

1. `Kernal/services/installer.lua` builds a deterministic ROM payload.
2. `init.lua` calls `HyperCube.installer:update_metadata()`.
3. `HyperCube.network.expected_phone_rom_checksum` is set to the server's current TPhone ROM checksum.

When a phone sends `hello`, it must include:

- `role = "phone"`
- `device = "TPhone"`
- `rom_checksum = <checksum of local hypercube.rom>`

The server then:

- accepts only if the checksum matches `expected_phone_rom_checksum`;
- replies with `welcome { ok = true }` on success;
- replies with `welcome { ok = false, error = "MissingROMChecksum" }` when no checksum is supplied;
- replies with `welcome { ok = false, error = "ROMChecksumMismatch" }` when the ROM is not the server-approved ROM;
- stores the sender as rejected and answers later main-server messages with `server.reject`.

This blocks invalid phones from identity registration, sign-in, device registration, database access, web publishing, phone services, banking, Chirper, and other main-server APIs. `update.*` remains available so the phone can repair itself by downloading the approved ROM.

## Deterministic ROM Builds

The ROM builder sets the ROM payload `built_at` field to `0`. Install timestamps are written to `hypercube_install`, but the ROM bytes are stable for the same source tree and software version. This is required because checksum validation is meaningless if the same source creates a different ROM every time it is packaged.

The checksum algorithm is the lightweight Adler-style checksum already used elsewhere in the OS. It is suitable for integrity/version matching inside this Minecraft network. It is not cryptographic authentication.

## Phone Update Flow

The phone image in `installer/hypercube_phone` does the following:

1. Reads `hypercube.rom`.
2. Computes the local ROM checksum.
3. Sends the checksum in the rednet `hello`.
4. If the server rejects the ROM, the phone records `network.status = "rejected"` and blocks TesseracID setup.
5. The updater calls `update.status`.
6. If the version is old or the local checksum differs from the server checksum, the phone downloads the server ROM.
7. The downloaded ROM checksum is verified before writing.
8. The phone writes `hypercube.rom`, updates `startup.lua`, writes `hypercube_version`, and reboots.

## Installer Service

`Kernal/services/installer.lua` packages install images from source directories.

Profiles:

- `phone`: `installer/hypercube_phone`, OS `HyperCube`, device `TPhone`
- `business_phone`: `installer/hypercube_phone`, OS `HyperCube`, device `TBusinessPhone`
- `turtle`: `installer/hypercube_turtle`, OS `HyperCube`, device `Turtle`

Installed media includes:

- `hypercube.rom`: Encrypted packed ROM image.
- `startup.lua`: ROM loader.
- `hypercube_install`: Serialized install metadata.

The ROM loader decrypts `hypercube.rom`, installs it into memory as `HC_ROM`, overrides `require` and `loadfile` to read from the memory ROM, loads `init.lua`, boots the OS, ensures identity, and starts the GUI.

## App Store

Server-hosted app packages live in `appstore/apps`.

Current packages:

- `chirper`: Short-post timeline backed by TesseracID.
- `idlecube`: Incremental idle game.
- `notes`: Local notes stored through HCFS.
- `trains`: CMR train timetable.

Phone built-in apps live in `installer/hypercube_phone/apps` and include account, app store, banking, browser, logs, messages, network, services, and settings.

## App Screen API

Phone apps receive `HCAPI.screen`, which includes primitive drawing helpers plus `api.screen.manager(default_screen)`.

Use the manager when an app has multiple pages. Define each page once with `render`, `on_touch`, and `on_key`, then switch the active page with `manager:set("page_id")`.

Example:

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
    state = state,
    render = function(ctx)
        api.screen.write(ctx.x, ctx.y, "Details", C.yellow, C.black)
    end,
})
router:render(ctx)
```

`Messages` uses this for Chats, Chat Thread, Contacts, Contact Detail, Edit Contact, Compose, and Bills. `Banking` uses it for Open Account, Home, and Transfer. The server GUI uses the same pattern internally for Logs, Processes, and Installer.

Apps can also use `HCAPI.phone` for phone-service calls:

- `api.phone.status()`
- `api.phone.subscribe()`
- `api.phone.pay()`
- `api.phone.send(to, body)`
- `api.phone.sync()`
- `api.phone.chats()`
- `api.phone.chat(number, mark_read)`
- `api.phone.delete_chat(number)`

Phone subscriptions require an open Bank of Ba$h account linked to the caller's TesseracID before a number is assigned. Opening a bank account with `bank.open` requires a `minecraft_name` field so moderation can connect financial accounts to in-game identities. The first phone subscription grants one free week by setting `paid_until = now() + WEEK_MS` without charging. Later `phone.pay` renewals debit the linked bank account for the weekly bill before extending service. Phone billing failures return stable API errors such as `BankAccountRequired`, `InsufficientFunds`, `NoPhoneNumber`, and `PhoneBillDue`.

Contacts are intentionally phone-side app data stored in the phone's HCFS. Chat history is server-side under `phone:chats:<tesserac_id>`. Incoming messages are first queued in `phone:inbox:<tesserac_id>` and folded into server-side chats by `phone.sync`, `phone.chats`, or `phone.chat`, which lets offline recipients receive and sync messages when they open the app.

Bank of Ba$h branches and ATMs can deposit cash through `bank.deposit` and charge withdrawals through `bank.withdraw`, but only from a trusted branch device owned by a business account:

1. Create or sign into a business TesseracID using the `business_phone` install profile.
2. Sign in from the branch computer and register that device as role `bank_branch` or `atm` so its own session receives the `bank.deposit` scope.
3. On the server filesystem, create `banking/admin_token` with a private admin token.
4. Trust the branch device by sending `bank.branch.trust` with `device_id`, optional `label`, and `admin_token`.
5. The branch can then call `bank.deposit` with `to` (recipient TesseracID or bank username), `amount`, `deposit_id`, and optional `memo`/`source`.

Deposits, withdrawals, and ATM fees require the `bank.deposit` device scope, a trusted-device record, and a business account owner. Failed ATM calls return clear errors such as `BusinessAccountRequired`, `ScopeDenied:bank.deposit`, `TrustedServerRequired`, `DepositIdRequired`, `WithdrawalIdRequired`, `FeeIdRequired`, `RecipientNotFound`, or `InvalidAmount`. `deposit_id`, `withdrawal_id`, and `fee_id` are idempotent per trusted branch device.

The standalone ATM charges non-owner customers `min(3% of the transaction, 3 TC)`. The fee is a separate account debit, not subtracted from withdrawn cash or deposited cash. One third goes to the configured official Tesserac bank account, and the remaining two thirds go to the ATM owner's bank account.

ATMs report vault balance and coin counts to the server with `atm.report`. The server stores the latest snapshot under the ATM device ID and sends a Tesserac phone alert to the configured official account when a coin count drops below `low_coin_thresholds` or when vault balance reaches `alert_balance_threshold`. Alerts are state-based, so the same low/high condition is only texted once until it clears and happens again.

The standalone ATM also has a maintenance screen. Insert the ATM owner's business phone or the configured official account phone, then use `Maint` to load coins from the barrel into the vault or remove entered value from the vault without changing any bank balance. The same screen shows current vault balance, coin counts, and today's server-side ATM stats including fee profit and transaction counts.

Message reports can be filed from the Messages app by selecting a message in a thread and pressing `Report`. Reports are stored by the server moderation service and exposed through the authenticated internal HyperNet portal `moderation.tesserac`. The authorized list defaults to the `tesserac` account. Authorized users can open `moderation.tesserac/authorize` for instructions and navigate to `moderation.tesserac/authorize/<username>` to authorize another account. The home page links to `/reports` for flagged messages and `/accounts` for account lookup. Account lookup supports `/accounts/<username>`, `/accounts/<phone_number>`, `/accounts/<tesserac_id>`, and `/accounts/<minecraft_name>`. The official `tesserac` account can close bank accounts with incorrect Minecraft signup names from the lookup result. Authorized accounts can also request structured report data with `moderation.report.list`.

## Database

The server uses grouped, replicated disk storage through `diskdb.lua`. `min_replicas` is the number of replica groups. Disks are sorted into equal-sized groups, each group stores the same keyspace, and each disk inside a group stores only the shard assigned to a key. For example, six disks with `min_replicas = 2` become two replica groups with three shards each, giving about three disks worth of capacity with two complete copies. Extra disks that cannot fit evenly into the groups are reported as spares.

Expected disk layout:

- `disk/<n>/hypercube_db/records/*.db`
- `disk/<n>/hypercube_db/parity/*.par`

Known record key families:

- `account:<username>`
- `account:tid:<tesserac_id>`
- `device:<device_id>`
- `service:<tesserac_id>:<key>`
- `phone:account:<tesserac_id>`
- `phone:number:<number>`
- `phone:inbox:<tesserac_id>`
- `phone:chats:<tesserac_id>`
- `bank:trusted_depositor:<device_id>`
- `bank:deposit:<device_id>:<deposit_id>`
- `atm:status:<device_id>`
- `atm:stats:<device_id>:<day>`
- `moderation:reports:index`
- `moderation:report:<report_id>`
- `moderation:authorized`
- `bank:minecraft:<minecraft_name>`
- `bank:closed:<tesserac_id>`

The server is configured with `min_replicas = 2`, so production should keep enough mounted disk drives for two equal replica groups. Existing full-replica records are still readable; when records are read or written, Disk DB repairs them into the current shard placement.

## Identity And Scopes

TesseracID stores accounts, sessions, and registered devices. Device scopes limit what authenticated devices can access.

Default phone scopes include:

- `account.identity`
- `app.install`
- `bank.access`
- `chirper.access`
- `db.user`
- `phone.access`
- `web.publish`

Default turtle/webserver scopes are smaller and focus on origin/web or turtle capabilities.

Bank branch and ATM device roles are intentionally narrow and include:

- `account.identity`
- `bank.deposit`

## Production Checklist

- Attach and open a wireless modem on the server.
- Attach at least two disk drives containing the replicated `hypercube_db`.
- Boot `computer/0/startup.lua`.
- Confirm `logs/kernel.log` includes `rednet hosting`, `diskdb`, and `phone ROM checksum`.
- Reinstall or update phones after ROM integrity changes so they send `rom_checksum`.
- Treat `ROMChecksumMismatch`, `MissingROMChecksum`, and `ServerROMChecksumUnavailable` as production blockers.
- Keep `installer/hypercube_phone` as the source of truth for the approved phone OS.
- Rebuild/reinstall phone media after changing the phone source image.
- Do not edit a deployed phone ROM manually; use the server installer or update service.

## Operational Notes

- Existing older phones that do not send a ROM checksum will be rejected by the server as `MissingROMChecksum`.
- Rejected phones can still use update endpoints, but they cannot register identity or access main server APIs.
- A changed phone source tree changes the expected server checksum. Deployed phones must update to match.
- The checksum gate validates the packed ROM image, not mutable user files such as `user/tesseracid` or logs.
- The server log is the first place to inspect rejection causes.

## Packaging

Use `package_server.lua` in ComputerCraft or `package_server.py` from the host to create pastebin/install packages for the server tree. The package helpers include the server OS, app store, installer images, startup files, and checklist while excluding logs, users, database files, and generated package output.

## Troubleshooting

- `ServerNotFound`: Check modem, hostname, and protocol.
- `MissingROMChecksum`: The phone ROM is too old or the phone is not sending checksum metadata.
- `ROMChecksumMismatch`: The phone's `hypercube.rom` does not match `installer/hypercube_phone` on the server.
- `ServerROMChecksumUnavailable`: The server could not build update metadata from the installer source.
- `DatabaseUnavailable`: Check disk drives and `hypercube_db` replicas.
- `TesseracID required`: The phone cannot proceed until identity is created or loaded, and ROM integrity must pass first.
