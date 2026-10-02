# AO Payment Device

Standalone HyperBEAM Forge package for `ao-payment@1.0`.

`ao-payment@1.0` verifies AO token payment notices, imports accepted payments
into a local HyperBEAM token ledger, exposes guarded AO withdrawals, and acts as
a native `p4@1.0` ledger device. It replaces the older `process-ledger@1.0`
adapter shape by speaking p4's `balance` and `charge` calls directly.

For paid inference it also provides durable per-request admission
reservations. A P4 request hook reserves the configured maximum before
execution, and the P4 response hook consumes the matching reservation exactly
once. Unused reservations expire after the configured TTL.

## Compatibility

- HyperBEAM pin: `178fec98d8f5ac3843534752d1047a8bed51df06`
- Device name: `ao-payment@1.0`
- Runtime ledger path: a local process route such as
  `/ledger~node-process@1.0`

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
HyperBEAM core devices plus `ao-payment@1.0`, starts a real HyperBEAM test node,
and proves:

- `ao-payment@1.0` loads by name from the preloaded store;
- `p4@1.0` can use it directly as `ledger-device`;
- an unfunded signed request is rejected;
- a funded signed request succeeds;
- p4 response charging debits the request signer and credits the operator;
- `p4@1.0/balance` derives the target from the signed request signer.

Install the local pre-push hook with:

```sh
scripts/install-git-hooks.sh
```

## p4 Configuration

Use `ao-payment@1.0` as the p4 ledger device and point it at the local ledger
process:

```erlang
#{
    <<"device">> => <<"p4@1.0">>,
    <<"pricing-device">> => <<"simple-pay@1.0">>,
    <<"ledger-device">> => <<"ao-payment@1.0">>,
    <<"ledger-path">> => <<"/ledger~node-process@1.0">>
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
    <<"ao-payment-ledger-path">> => <<"/ledger~node-process@1.0">>,
    <<"ao-payment-deposit-address">> => DepositAddress,
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

Keep `ao-payment-auto-withdraw=false`. Configure AO deposits to go directly to
the beneficiary. The manual `withdraw/3` API reports submission to the AO MU;
an HTTP acceptance is not settlement proof and is not used by the paid
inference flow.

## Publish

After tests pass, publish the Forge package artifacts generated under
`_build/devices/` with your normal ANS-104 item pipeline. Then pin the published
spec ID in your node's `name-resolvers` and trust the publisher address in
`trusted-device-signers`.
