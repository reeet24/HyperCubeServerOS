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

## Escrow For Markets

Use `api.bank.escrow` when a market needs to hold buyer funds until a buy or sell order is fulfilled.

Escrow lifecycle:

1. Buyer creates escrow for a seller. The buyer's spendable balance is charged immediately.
2. Market app waits for item delivery or order fulfillment.
3. Buyer releases escrow, which pays the seller.
4. Buyer or seller can refund or cancel a held escrow, which returns the held funds to the buyer.

Escrow IDs are idempotent. Retrying `create` with the same `escrow_id` for the same buyer/account returns the existing escrow instead of charging again.

### `api.bank.escrow.create(options)`

Creates a held escrow payment.

```lua
local escrow_id = api.app_id .. ":order:" .. tostring(order_id)
local ok, result_or_err = api.bank.escrow.create({
    seller = "seller_username",
    amount = 32,
    escrow_id = escrow_id,
    item_id = "diamond_pickaxe",
    memo = "Market order " .. tostring(order_id),
    account_name = "main",
})
```

Create options:

- `seller`: Required seller recipient, by username or account owner ID.
- `amount`: Required TC amount, rounded to 1/64 TC.
- `escrow_id`: Required idempotency key.
- `item_id`: Required item/order identifier.
- `memo`: Optional history memo.
- `account_name`: Optional buyer source account, default `main`.
- `app_id`: Optional app identifier. Defaults to the calling app id.

Common errors:

- `EscrowIdRequired`
- `EscrowIdInUse`
- `ItemIdRequired`
- `AccountRequired`
- `RecipientNotFound`
- `InvalidAmount`
- `InsufficientFunds`
- `CannotEscrowToSelf`

### `api.bank.escrow.status(escrow_id)`

Returns a single escrow visible to the signed-in buyer or seller.

```lua
local ok, escrow = api.bank.escrow.status(escrow_id)
```

### `api.bank.escrow.list()`

Returns escrows where the signed-in user is the buyer or seller.

```lua
local ok, result = api.bank.escrow.list()
if ok then
    for _, escrow in ipairs(result.escrows) do
        print(escrow.escrow_id .. " " .. escrow.status)
    end
end
```

### `api.bank.escrow.release(escrow_id, memo)`

Releases a held escrow to the seller. Only the buyer can release.

```lua
local ok, result_or_err = api.bank.escrow.release(escrow_id, "Order delivered")
```

Common errors:

- `EscrowNotFound`
- `EscrowReleaseRequiresBuyer`
- `EscrowAlreadyRefunded`
- `EscrowNotHeld`
- `SellerAccountRequired`

### `api.bank.escrow.refund(escrow_id, memo)`

Refunds a held escrow to the buyer. The buyer or seller can refund.

```lua
local ok, result_or_err = api.bank.escrow.refund(escrow_id, "Order cancelled")
```

Common errors:

- `EscrowNotFound`
- `EscrowAccessDenied`
- `EscrowAlreadyReleased`
- `EscrowNotHeld`
- `BuyerAccountRequired`

### `api.bank.escrow.cancel(escrow_id, memo)`

Alias for `refund`, intended for unfilled market orders.

Escrow records include:

```lua
{
    escrow_id = "market:order:123",
    status = "held", -- held, released, refunded
    buyer = "buyer_account_owner",
    seller = "seller_account_owner",
    amount = 32,
    currency = "TC",
    item_id = "diamond_pickaxe",
    app_id = "market",
}
```

## Raw HyperNet Messages

The phone app API wraps these network messages:

- `bank.open` -> `bank.open.result`
- `bank.status` -> `bank.status.result`
- `bank.history` -> `bank.history.result`
- `bank.transfer` -> `bank.transfer.result`
- `bank.purchase` -> `bank.purchase.result`
- `bank.escrow.create` -> `bank.escrow.create.result`
- `bank.escrow.status` -> `bank.escrow.status.result`
- `bank.escrow.list` -> `bank.escrow.list.result`
- `bank.escrow.release` -> `bank.escrow.release.result`
- `bank.escrow.refund` -> `bank.escrow.refund.result`
- `bank.escrow.cancel` -> `bank.escrow.cancel.result`

Raw requests are useful for trusted infrastructure and diagnostics, but normal phone apps should prefer `HCAPI.bank`.

## Trusted Deposit And ATM APIs

Physical cash operations are restricted to trusted business devices. A phone app cannot call these successfully unless it is running on a trusted ATM or branch device with the correct business identity and device trust record:

- `bank.deposit`
- `bank.withdraw`
- `bank.atm.fee`
- `bank.branch.trust`
- `bank.branch.revoke`

These APIs are for ATMs and bank branches, not ordinary user apps.
