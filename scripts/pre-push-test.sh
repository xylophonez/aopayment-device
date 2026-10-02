#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HB_REF="178fec98d8f5ac3843534752d1047a8bed51df06"
HB_DIR="${AOPAYMENT_HYPERBEAM_DIR:-$ROOT/_build/hyperbeam-$HB_REF}"
STORE="$ROOT/_build/hb178fec-aopayment-preloaded-store"
FLOW_EBIN="$ROOT/_build/aopayment-flow-ebin"

cd "$ROOT"

echo "==> standalone compile"
rebar3 compile

echo "==> standalone device eunit"
rebar3 eunit --module=dev_aopayment

echo "==> package and verify"
rebar3 device package
rebar3 device verify

if [ ! -d "$HB_DIR/.git" ]; then
    echo "==> clone HyperBEAM $HB_REF"
    rm -rf "$HB_DIR"
    git clone https://github.com/permaweb/HyperBEAM.git "$HB_DIR"
fi

echo "==> checkout HyperBEAM $HB_REF"
if ! git -C "$HB_DIR" cat-file -e "$HB_REF^{commit}" 2>/dev/null; then
    git -C "$HB_DIR" fetch origin "$HB_REF"
fi
git -C "$HB_DIR" checkout --detach "$HB_REF"

echo "==> compile HyperBEAM test profile"
(cd "$HB_DIR" && rebar3 as test compile)

echo "==> build combined preload with core devices plus ao-payment"
rm -rf "$STORE"
PRELOAD_OUTPUT="$(
    cd "$HB_DIR"
    rebar3 device preload --device-src "src/preloaded,$ROOT/src" --output-dir "$STORE"
)"
printf '%s\n' "$PRELOAD_OUTPUT"
INDEX="$(
    printf '%s\n' "$PRELOAD_OUTPUT" |
        sed -n 's/.*Index: \([^[:space:].]*\).*/\1/p' |
        tail -n 1
)"
if [ -z "$INDEX" ]; then
    echo "could not parse preloaded index" >&2
    exit 1
fi

echo "==> compile flow harness"
rm -rf "$FLOW_EBIN"
mkdir -p "$FLOW_EBIN"
ERL_PA_ARGS=()
for ebin in "$HB_DIR"/_build/test/lib/*/ebin; do
    ERL_PA_ARGS+=("-pa" "$ebin")
done
erlc \
    -o "$FLOW_EBIN" \
    "${ERL_PA_ARGS[@]}" \
    "$ROOT/scripts/aopayment_p4_flow.erl"

echo "==> run p4 flow through preloaded ao-payment@1.0"
export HB_PRELOADED_STORE="$STORE"
export HB_PRELOADED_DEVICES_INDEX="$INDEX"
export HB_PORT="${HB_PORT:-0}"
(
    cd "$HB_DIR"
    erl \
        -noshell \
        -pa "$FLOW_EBIN" \
        "${ERL_PA_ARGS[@]}" \
        -eval 'case aopayment_p4_flow:run() of ok -> halt(0); Other -> io:format("unexpected result: ~p~n", [Other]), halt(1) end.'
)

echo "==> pre-push checks passed"
