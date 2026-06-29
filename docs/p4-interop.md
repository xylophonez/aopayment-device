# p4 Interop

The old `process-ledger@1.0` adapter translated p4 ledger calls into local
process route calls. That worked, but it meant deployments needed an extra
trusted device whose only job was to sit between `p4@1.0` and the token ledger.

This standalone package makes `ao-payment@1.0` implement the p4 ledger surface
itself:

- `balance/3` handles p4 balance checks;
- `charge/3` handles p4 response charges;
- `ledger-path` tells the device which local process ledger to read or push to.

The important signer detail is that payer identity comes from the AO message
signer, matching `simple-pay@1.0`. `ao-payment@1.0` checks explicit p4 targets
when p4 supplies them, then derives from the signed nested request using
`hb_message:signers/2`. It does not decide identity from whether a map contains
`commitments`.

The pre-push proof in `scripts/pre-push-test.sh` exercises the production-style
path: `p4@1.0` calls `ao-payment@1.0` by name from a Forge preloaded store, and
`ao-payment@1.0` pushes charges into a real local `process@1.0` ledger running
HyperBEAM's `hyper-token.lua` plus `hyper-token-p4.lua`.

