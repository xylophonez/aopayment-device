# API

## `ingest/3`

Verifies an AO token transfer, checks matching debit and credit notices, and
schedules a local `Credit-Notice` into the configured HyperBEAM ledger process.
Imports are keyed by token, ledger, message ID, slot, sender, recipient, and
quantity so repeated calls are idempotent.

## `verify/3`

Fetches AO schedule and compute-result data from the configured state endpoint
and validates that the AO token process emitted the expected payment notices.

## `withdraw/3`

Submits a guarded AO transfer from the node wallet to the configured
beneficiary. The route requires the boot-generated withdrawal secret so an
exposed node is not turned into an arbitrary signing endpoint.

## `balance/3`

Native p4 ledger API.

Input:

```erlang
#{<<"path">> => <<"balance">>, <<"target">> => Address}
```

or a p4 envelope containing a signed nested request:

```erlang
#{<<"path">> => <<"balance">>, <<"request">> => SignedRequest}
```

Behavior:

- fails with status `500` if `ledger-path` is missing;
- returns `0` if no target can be derived;
- reads `<ledger-path>/now/balance/<target>` for the derived target.

Signer derivation uses `hb_message:signers/2` on the AO message, following the
same source of truth as `simple-pay@1.0`; it does not derive payer identity from
the presence or shape of `commitments`.

## `charge/3`

Native p4 ledger API.

Input:

```erlang
#{
    <<"path">> => <<"charge">>,
    <<"quantity">> => Price,
    <<"account">> => RequestSigner,
    <<"recipient">> => OperatorAddress,
    <<"request">> => SignedRequest
}
```

Behavior:

- fails with status `500` if `ledger-path` is missing;
- pushes the p4 charge message into `<ledger-path>/push`;
- relies on the ledger process, for example `hyper-token-p4.lua`, to validate
  that the charge was signed by the node/admin.

