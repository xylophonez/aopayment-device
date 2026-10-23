# p4 Interop

The old `process-ledger@1.0` adapter translated p4 ledger calls into local
process route calls. That worked, but it meant deployments needed an extra
trusted device whose only job was to sit between `p4@1.0` and the token ledger.

This standalone package makes `ao-payment@1.11` implement the p4 ledger surface
itself:

- `balance/3` handles p4 balance checks and durable admission reservations;
- `charge/3` consumes a reservation exactly once for a p4 response charge;
- `ledger-path` tells the device which local process ledger to read or push to.

The important signer detail is that payer identity comes from the AO message
signer, matching `simple-pay@1.0`. `ao-payment@1.11` checks explicit p4 targets
when p4 supplies them, then derives from the signed nested request using
`hb_message:signers/2`. It does not decide identity from whether a map contains
`commitments`.

The pre-push proof in `scripts/pre-push-test.sh` exercises the production-style
path: `p4@1.0` calls `ao-payment@1.11` by name from a Forge preloaded store, and
`ao-payment@1.11` pushes charges into a real local `process@1.0` ledger running
HyperBEAM's `hyper-token.lua` plus `hyper-token-p4.lua`.

For metered inference, use two request hooks in this order: a `simple-pay@1.0`
P4 hook whose offered route price equals `ao-payment-reservation-amount`, then a
`metering@1.0` P4 hook. Use only the metering hook on the response. The first
hook creates the reservation; it is an admission bound rather than a second
charge.

The node-level `ao-payment-ledger-path` and reservation amount are trusted.
Values embedded in a device base/request cannot override them. Charge calls
must be signed by an identity named in node configuration and target the
configured P4 recipient.

Before mutating the process ledger, `charge/3` stores the exact signed inner
charge and both relevant balances in the reservation record. The pinned
scheduler applies an identical signed inner message twice, so an interrupted
retry never resubmits it. The device completes the record only when the
expected debit and credit are visible; otherwise it fails closed with `503`.
On a provider or pricing error, no response charge arrives and the reservation
remains unavailable until its TTL expires.

The separate manual withdrawal route follows the same at-most-once boundary:
it stores the exact signed AO item before submitting it once. It accepts only
the configured operator or private boot secret and only the configured token
and beneficiary. Prepared or uncertain retries fail closed for reconciliation.
