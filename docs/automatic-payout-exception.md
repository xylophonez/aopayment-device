# Scoped automatic payout restoration

Declared before edits on 2026-10-21:

- Splash level: 4 (existing non-core AO-payment device); no default behavior
  change for non-opt-in deployments. Candidate name: `ao-payment@1.11`.
- Ladder rung: (b), behavioral bypass. Adherence: exception.
- Gates: scope=agreed; precedent=`src/dev_aopayment.erl:767` (pre-edit charge
  intent persistence), `:1341` (durable at-most-once withdrawal submission);
  owners=`ao-payment` (reservation, ledger charge, withdrawal) and native `p4`
  (metering/admission); duplication=none.
- Approver: fn, 2026-10-21, in response to the scoped approval request:
  “This should be default, idk why it stopped?” Default applies to the staked
  bundler profile; the shared device's false/default path is preserved.
- Reason: config cannot bind an authoritative exact P4 charge to its automatic
  payout; the current device refuses auto-withdraw. Exposing data alone cannot
  restore this behavior. Existing reservation and guarded withdrawal mechanisms
  are composed internally, with no extra service, ledger or protocol.
- Expiry: 2026-11-21.
- Retirement: Sam-reviewed canonical AO-payment integration; re-review on every
  HyperBEAM dependency bump. No publication is authorized by this exception.
- Independent review: `/root/review_paid_parity`, completed 2026-10-21. No
  blocking funds, authorization or replay findings in the final diff. Reviewer
  independently ran all 45 EUnit tests successfully; their requested canonical
  pre-push payout invocation and README evidence bullets were added.

The latest fetched canonical integrity branch is 70de5d1; this work preserves
its authorization, reservation, replay and withdrawal uncertainty controls plus
the pre-existing local v0.11 DID normalization and build-pin fixes. GitHub main
is older than the canonical integrity branch; no dirty/divergent work was reset.

## v0.11 node signing compatibility

The request execution options hide node key material. The AO device must compose
`hb_http_server:with_node_committer/1` before selecting its wallet, matching
`hb_message:commit/3` (`src/core/resolver/hb_message.erl:454`) and the existing
restoration API (`src/core/http/hb_http_server.erl:882`). Otherwise its legacy
fallback file wallet overrides the real node signer. This adds no identity
mechanism or persistence: the existing node registry supplies its existing key.
Splash level 4; rung (b) compatibility exposure to the existing signing consumer;
shared explicit-wallet behavior retained. A regression verifies the registered
node signs both credit notices and withdrawals with request key material hidden.

## Recorded validation

- `build/payout-unit-r1.log`: exit 0, 41 tests.
- `build/payout-unit-r2.log`: exit 0, 45 tests, including native Lua charge,
  post-debit/pre-commit recovery, no-debit Lua error and request-scope signing.
- `build/payout-package-r1.log`: exit 0, isolated Forge package build.
- `build/payout-p4-flow-r1.log`: exit 0, actual HTTP native P4 with immutable
  local package pins; default-false and auto-payout flows both passed. The MU
  is a local mock: signed exact payout submission is proven, real AO settlement
  is not claimed by these tests.
- Full `scripts/pre-push-test.sh` passed in independent run r4, exit 0, with
  OTP 28.5, GCC 15, documented native compatibility flags and a viable initial
  preload. `build/canonical-prepush-review-result.json` records the exact
  environment and stages. Earlier r1/r2/r3 compiler, native-library and preload
  failures remain recorded; a bare default-environment invocation did not pass.

No commits, branches, tags, deployment services or funds were published or
mutated by this implementation subtask. Device integration and real settlement
remain root-agent work. The old wrong-wallet signed receipt cannot be repaired
through an existing import API; it must remain explicitly pending separate
operator reconciliation, rather than weakening receipt replay protection.

## Final readback

Ratings remain splash 4 / rung (b) behavioral exception for payout, with the
scoped v0.11 signing compatibility correction described above. No kernel or
canonical preloaded file changed. Branch `fix/andee-paid-v011-20261021` remains
at base commit `70de5d1`, with changes local and uncommitted.

Final implementation SHA-256:
`78d4cdb70082f52720aae8e89609416c06c255b58cc7746ac11eea2fbbd5e35b`.
Final validation: `build/payout-unit-r3.log` 45 tests, exit 0;
`build/payout-independent-review-unit-r1.log` 45 tests, exit 0;
`build/payout-package-r2.log` exit 0;
`build/payout-p4-flow-r2.log` default-false and automatic HTTP P4 flows, exit 0.
`git diff --check` and `bash -n scripts/pre-push-test.sh` exited 0.

Final isolated local package metadata: `build/payout-package.json`.
Spec `8OWE6FVW_CC8PntVCDaDHDbaFEFdbVV0TLdhqL0qgBI`, implementation
`QOsT7PX_BCkp_Na6RW16lIATivuu1tIj-vQCZhu5RVk`, name `ao-payment@1.11`.
Its read-only store is `build/payout-package-store`; no running package cache
was altered by this implementation subtask. Source hashes are recorded in
`build/payout-reviewed-sources.sha256`. Full standalone pre-push r4 passed with
the prerequisites above; its payment settlement responses are mocks.
