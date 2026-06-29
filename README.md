# AO Payment Device

Standalone HyperBEAM Forge package for `ao-payment@1.0`.

`ao-payment@1.0` verifies AO token payment notices, imports accepted payments
into a local HyperBEAM token ledger, exposes guarded AO withdrawals, and acts as
a native `p4@1.0` ledger device. It replaces the older `process-ledger@1.0`
adapter shape by speaking p4's `balance` and `charge` calls directly.

## Compatibility

- HyperBEAM pin: `4177b91993b2f590f4906bc9ca548724f8408875`
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

`balance/3` reads `ledger-path/now/balance/<target>`. The target is resolved in
this order: explicit `target`, nested request `target`, nested request signer,
then raw request signer.

`charge/3` pushes the node-signed p4 charge request to the configured ledger
process route.

## AO Import Configuration

The AO import path verifies AO token transfer notices against a configured
state endpoint before scheduling a local `Credit-Notice`.

Common node options:

```erlang
#{
    <<"ao-payment-token">> => <<"0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc">>,
    <<"ao-payment-mainnet-url">> => <<"https://state.forward.computer">>,
    <<"ao-payment-ledger">> => LedgerProcessId,
    <<"ao-payment-ledger-path">> => <<"/ledger~node-process@1.0">>,
    <<"ao-payment-deposit-address">> => DepositAddress,
    <<"operator">> => OperatorAddress
}
```

## Publish

After tests pass, publish the Forge package artifacts generated under
`_build/devices/` with your normal ANS-104 item pipeline. Then pin the published
spec ID in your node's `name-resolvers` and trust the publisher address in
`trusted-device-signers`.

