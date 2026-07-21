# Tesserac Banking API

Bank of Ba$h accounts are TesseracID-linked TC accounts. A user may open multiple named accounts under the same TesseracID; `main` is the default account used by phone services unless an API call supplies another `account_name`.

New bank accounts start with `0 TC`.

## Account Model

Each account stores:

- `owner`: TesseracID that owns the account.
- `username`: Tesserac username at account creation.
- `account_name`: Named account, defaulting to `main`.
- `minecraft_name`: Required Minecraft username.
- `balance`: TC balance, rounded to 1/64 TC.
- `currency`: `TC`.

Accounts are resolved by TesseracID for the signed-in user. Recipients can be addressed by TesseracID owner or username.

## Phone App API

Phone apps should use `HCAPI.bank` rather than sending raw HyperNet banking messages.

```lua
local api = HCAPI

local ok, account_or_err = api.bank.status("main")
```

The built-in Messages app uses the same purchase backend for weekly phone subscription renewals. It calls `api.phone.pay(purchase_id)`, and the server records that renewal through `bank.purchase`.

### `api.bank.open(account_name, minecraft_name)`

Opens or completes setup for an account.

```lua
local ok, result = api.bank.open("main", "MinecraftUser")
```

Common errors:

- `MinecraftNameRequired`
- `InvalidMinecraftName`
- `InvalidAccountName`
- `BankRequestFailed`

### `api.bank.status(account_name)`

Returns the public account state for the signed-in user.

```lua
local ok, account = api.bank.status("main")
if ok then
    print(account.balance)
end
```

Common errors:

- `AccountRequired`
- `AuthRequired`

### `api.bank.history(account_name)`

Returns recent account transactions.

```lua
local ok, history = api.bank.history("main")
```

### `api.bank.transfer(to, amount, memo, account_name)`

Transfers TC from the signed-in user's account to another account.

```lua
local ok, result = api.bank.transfer("merchant_username", 5, "Tip", "main")
```

Use this for user-initiated transfers. For in-app purchases, prefer `api.bank.purchase`.

Common errors:

- `AccountRequired`
- `RecipientRequired`
- `RecipientNotFound`
- `InvalidAmount`
- `InsufficientFunds`
- `CannotTransferToSelf`

## In-App Purchases

Use `api.bank.purchase(options)` for app purchases. Purchases are idempotent by `purchase_id`, so retrying the same purchase after a timeout will return the same completed result instead of charging the user again.

For appstore apps, keep purchase calls and merchant recipients in protected files. The appstore installer verifies protected file checksums before load, so changing payment routing in `app.lua` or another protected module prevents the app from starting. Mod files should live under manifest-declared `mutable_paths`.

```lua
local purchase_id = api.app_id .. ":skin_red:" .. tostring(api.time())
local ok, result_or_err = api.bank.purchase({
    to = "merchant_username",
    amount = 12.5,
    item_id = "skin_red",
    purchase_id = purchase_id,
    memo = "Red skin",
    account_name = "main",
})

if ok then
    api.fs.write("owned_skin_red.txt", "true")
else
    -- Show result_or_err to the user.
end
```

Purchase options:

- `to`: Required merchant recipient, usually a business username.
- `amount`: Required TC amount, rounded to 1/64 TC.
- `item_id`: Required item/SKU identifier.
- `purchase_id`: Required idempotency key. Reuse the same key for retries of the same intended purchase.
- `memo`: Optional history memo.
- `account_name`: Optional source account, default `main`.
- `app_id`: Optional app identifier. Defaults to the calling app id.

Purchase result:

```lua
{
    transaction_id = "iap_...",
    purchase_id = "app:item:...",
    item_id = "skin_red",
    app_id = "example",
    amount = 12.5,
    account = { balance = 87.5, currency = "TC" },
    merchant = { username = "merchant_username", account_name = "main" },
}
```

Common errors:

- `PurchaseIdRequired`
- `ItemIdRequired`
- `AccountRequired`
- `RecipientNotFound`
- `InvalidAmount`
- `InsufficientFunds`
- `CannotPurchaseFromSelf`
- `PurchasePending`
- `PurchaseFailed`

## Raw HyperNet Messages

The phone app API wraps these network messages:

- `bank.open` -> `bank.open.result`
- `bank.status` -> `bank.status.result`
- `bank.history` -> `bank.history.result`
- `bank.transfer` -> `bank.transfer.result`
- `bank.purchase` -> `bank.purchase.result`

Raw requests are useful for trusted infrastructure and diagnostics, but normal phone apps should prefer `HCAPI.bank`.

## Trusted Deposit And ATM APIs

Physical cash operations are restricted to trusted business devices. A phone app cannot call these successfully unless it is running on a trusted ATM or branch device with the correct business identity and device trust record:

- `bank.deposit`
- `bank.withdraw`
- `bank.atm.fee`
- `bank.branch.trust`
- `bank.branch.revoke`

These APIs are for ATMs and bank branches, not ordinary user apps.
