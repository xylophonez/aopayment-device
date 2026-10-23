#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HB_REF=ad415bdaaf887fb76c0a8b4f54d91fab3f9fccd8
cd "$ROOT"
rebar3 compile
HB_DIR="${AOPAYMENT_HYPERBEAM_DIR:-$ROOT/_build/default/lib/hb}"
test "$(git -C "$HB_DIR" rev-parse HEAD)" = "$HB_REF"
rebar3 device test --with-core --module dev_aopayment
rebar3 device package
rebar3 device verify
STORE="$ROOT/_build/aopayment-flow-preloaded"
PRELOAD_OUTPUT="$(rebar3 device preload --with-core --output-dir "$STORE")"
printf '%s\n' "$PRELOAD_OUTPUT"
INDEX="$(printf '%s\n' "$PRELOAD_OUTPUT" | sed -n 's/.*Index: \([^[:space:].]*\).*/\1/p' | tail -n 1)"
test -n "$INDEX"
export HB_PRELOADED_STORE="$STORE" HB_PRELOADED_DEVICES_INDEX="$INDEX" HB_PORT=0
export ERL_LIBS="$ROOT/_build/default/lib"
FLOW_EBIN="$ROOT/_build/aopayment-flow-ebin"
mkdir -p "$FLOW_EBIN"
erlc -o "$FLOW_EBIN" "$ROOT/scripts/aopayment_p4_flow.erl"
cd "$HB_DIR"
# Actual native HTTP/P4/Lua plus a disposable mock MU. No external network.
unshare -Urn sh -c 'ip link set lo up; exec erl +S 4 -noshell -pa "$1" -eval '\''
    try
        ok = aopayment_p4_flow:run(),
        ok = aopayment_p4_flow:run_payout(),
        ok = aopayment_p4_flow:run_admission(),
        init:stop(0)
    catch C:R:S ->
        io:format("flow failed: ~p ~p ~p~n", [C,R,S]), init:stop(1)
    end.'\''' sh "$FLOW_EBIN"
