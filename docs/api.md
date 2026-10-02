# API

## `ingest/3`

Verifies an AO token transfer, checks matching debit and credit notices, and
schedules a local `Credit-Notice` into the configured HyperBEAM ledger process.
The configured payment scope is authoritative. A caller may repeat matching
scope values but cannot change the token, deposit address, ledger identity, or
ledger route. Self-transfers and non-positive quantities are rejected. Imports
are durably keyed by token and AO message ID before the local notice is
scheduled. A retry observes settlement without scheduling the notice again.

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
- reads `<ledger-path>/now/balance/<target>` for the derived target;
- when `ao-payment-reservation-amount` is positive and the nested request has
  exactly one verified signer, atomically reserves that amount under the
  request's signed ID;
- subtracts other active reservations from the available balance.

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
- rejects unsigned, non-operator, missing-recipient, zero, and negative charge
  requests;
- rejects a measured charge above its reservation or current local balance;
- requires the recipient to match trusted node configuration;
- records a durable charge intent and pre-charge balances, pushes a sanitized
  node-signed request into `<ledger-path>/push` once, and records a terminal
  charged state;
- never resubmits an in-flight charge; a retry reconciles the payer and
  recipient balances or returns `503` when the outcome is ambiguous;
- treats replay of a completed matching charge as already charged and rejects a
  conflicting quantity or recipient.
