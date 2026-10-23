# AO Payment Device

Standalone HyperBEAM Forge package for `ao-payment@1.11`.

`ao-payment@1.11` verifies AO token payment notices, imports accepted payments
into a local HyperBEAM token ledger, exposes guarded AO withdrawals, and acts as
a native `p4@1.0` ledger device. It replaces the older `process-ledger@1.0`
adapter shape by speaking p4's `balance` and `charge` calls directly.

For paid inference it also provides durable per-request admission
reservations. Admission reserves the lesser of available credit and the configured
cap, returning that numeric amount for P4 to compare with its quote before
execution. The P4 response hook consumes the matching reservation exactly once.
Unused reservations, including rejected over-price requests, expire after the
configured TTL. This source revision requires a new package/pin before release.

## Compatibility

- HyperBEAM pin: `ad415bdaaf887fb76c0a8b4f54d91fab3f9fccd8`
- Device name: `ao-payment@1.11`
- Runtime ledger path: a local process route such as
  `/~node-process@1.0/ledger`

## Build

```sh
rebar3 compile
rebar3 device package
rebar3 device verify
```

## Test

Run the full pre-push proof:

```sh
scripts/pre-push-test.sh
```

That script compiles this repo, packages and verifies the Forge archive, clones
HyperBEAM at the pinned commit, builds a combined preloaded store containing
HyperBEAM core devices plus `ao-payment@1.11`, starts a real HyperBEAM test node,
and proves:

- `ao-payment@1.11` loads by name from the preloaded store;
- `p4@1.0` can use it directly as `ledger-device`;
- an unfunded signed request is rejected;
- a funded signed request succeeds;
- p4 response charging debits the request signer and credits the operator;
- `p4@1.0/balance` derives the target from the signed request signer;
- default-false configuration makes no MU payout request;
- opt-in automatic payout submits exactly the charged amount to the configured
  beneficiary, signed by the node wallet (local mock MU, not real settlement);
- replayed upload requests neither charge nor submit a second payout.

Install the local pre-push hook with:

```sh
scripts/install-git-hooks.sh
```

## p4 Configuration

Use `ao-payment@1.11` as the p4 ledger device and point it at the local ledger
process:

```erlang
#{
    <<"device">> => <<"p4@1.0">>,
    <<"pricing-device">> => <<"simple-pay@1.0">>,
    <<"ledger-device">> => <<"ao-payment@1.11">>,
    <<"ledger-path">> => <<"/~node-process@1.0/ledger">>
}
```

Set `ao-payment-ledger-path` in trusted node configuration. A request cannot
override that route. With a positive `ao-payment-reservation-amount`,
`balance/3` atomically reserves that amount for a verified, singly signed
nested request and reports only unreserved credit to concurrent requests.

`charge/3` accepts only a positive, operator-signed P4 charge to the configured
P4 recipient. It checks the measured amount against the reservation and current
balance, persists a sanitized node-signed charge plus the pre-charge balances,
and pushes it into the configured ledger once. A completed request is not
charged again, and the same signed request cannot reuse an active reservation.

HyperBEAM's pinned process scheduler does not deduplicate an identical signed
charge submitted twice. For that reason, an interrupted charge is never
resubmitted automatically. A retry marks it complete only when the expected
payer debit and recipient credit are both visible; otherwise it returns
`503` for operator reconciliation.

## AO Import Configuration

The AO import path verifies AO token transfer notices against a configured
state endpoint before scheduling a local `Credit-Notice`.

Common node options:

```erlang
#{
    <<"ao-payment-token">> => <<"0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc">>,
    <<"ao-payment-mainnet-url">> => <<"https://state.forward.computer">>,
    <<"ao-payment-ledger-path">> => <<"/~node-process@1.0/ledger">>,
    <<"ao-payment-deposit-address">> => DepositAddress,
    <<"ao-payment-withdraw-recipient">> => BeneficiaryAddress,
    <<"ao-payment-reservation-amount">> => MaximumCharge,
    <<"ao-payment-reservation-ttl-ms">> => 600000,
    <<"ao-payment-auto-withdraw">> => false,
    <<"operator">> => OperatorAddress,
    <<"p4-recipient">> => BeneficiaryAddress
}
```

When `ao-payment-ledger` is omitted, the device resolves the signed ledger
process identity from `ao-payment-ledger-path`. Import requests provide only
the AO message ID, slot, sender, quantity, and optional intended local
recipient. Token, deposit address, ledger identity, and ledger route come from
trusted node configuration; conflicting request values are rejected.

Imported receipt and reservation state is stored through HyperBEAM's local
store before any credit scheduling or charge mutation. A fresh receipt is
scheduled once. Retries only observe settlement and never schedule the
`Credit-Notice` again, so an ambiguous interruption fails closed instead of
minting a second local credit. AO transfers whose sender is the configured
deposit address are rejected because a self-transfer does not fund the node.

Automatic beneficiary payouts are opt-in in the shared device (default
`ao-payment-auto-withdraw=false`). The staked bundler profile enables them with
`ao-payment-auto-withdraw=true`, a positive reservation maximum, node-wallet
AO deposit address, and an explicit `ao-payment-withdraw-recipient`. A signed
request must be reserved before its charge; payer-to-self charges cannot fund
payouts. Before debiting, the existing reservation stores the payout's exact
amount, token, beneficiary and deterministic ID bound to the node wallet,
deposit address, ledger, payer and signed request. The debit must be observed
and its charged state persisted before any payout submission.

First completion, a reconciled charge and an operator retry of a completed
charge use the same guarded `withdraw/3` path. Its private-secret/operator
signature and configured token/recipient checks remain in force. A changed
configuration cannot redirect a stored payout: incompatible policy or identity
leaves it pending. Changing the auto-withdraw flag does not erase already
committed payout obligations. Local operator ledger credit is accounting
history, not a second source of AO backing after payout.

A payout failure does not undo a successful paid request. An operator may
repeat the original signed `charge/3` request to inspect its `payout` receipt
and resume a not-yet-prepared payout without charging again. Normal HTTP
upload replay remains rejected at admission; it is not a recovery interface.
The withdrawal stores its exact signed item before one MU submission. Prepared
or uncertain withdrawals never automatically resubmit, including a crash
between MU acceptance and recording its response. Such cases require operator
reconciliation against the stored message ID. There is no background retry
service and no claim of eventual automatic payout across an ambiguous crash.
`submitted` and `already-submitted` mean MU acceptance, never confirmed AO
settlement. Verify token debit/credit notices separately for settlement proof.

The manual `withdraw/3` route remains operator/private-secret guarded. Use a
unique `withdraw-id` for each intended manual transfer.

## Publish

After tests pass, publish the Forge package artifacts generated under
`_build/devices/` with your normal ANS-104 item pipeline. Then pin the published
spec ID in your node's `name-resolvers` and trust the publisher address in
`trusted-device-signers`.

## HyperBEAM v0.11 / device 1.11

This release targets HyperBEAM-dev RC4 `ad415bdaaf887fb76c0a8b4f54d91fab3f9fccd8`.
Use `ao-payment@1.11` with newly built specification and implementation IDs; old
immutable packages are not replaced by updating source. Keep one payment
implementation active for a ledger during an upgrade: the account locks are
scoped to the loaded archive module. Preserve the private ledger and payment
state, and restart onto the selected implementation.

The internal `p4-recipient` may be the node's clearing account; the external
`ao-payment-withdraw-recipient` is the user-selected payout beneficiary. Disabling
automatic payout does not erase an already committed payout liability: an
operator retry of that charged request can still reconcile its recorded intent.
Submission receipts do not prove public-chain settlement.

Run `scripts/pre-push-test.sh` with OTP28.5 and the native build prerequisites.
It compiles, tests source and packaged devices, verifies the archive, then runs
the real HTTP/P4/Lua admission/debit/payout/replay cases in a disposable Linux
user/network namespace. The local MU is synthetic and has no external network.
On GCC15 hosts the pinned HyperBEAM native build needs
`CFLAGS=-Wno-error=incompatible-pointer-types`; this release does not patch the kernel.
