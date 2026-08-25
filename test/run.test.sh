#!/usr/bin/env bash
# Tests for bin/protonvpn-run, the output cap that stands between the Proton VPN
# CLI and Quickshell's unbounded StdioCollector.

run="$(cd "$(dirname "$0")/../bin" && pwd)/protonvpn-run"
fail=0

eq() { # label got want
  if [ "$2" = "$3" ]; then echo "ok   $1 = $2"
  else echo "FAIL $1"; echo "  got  $2"; echo "  want $3"; fail=$((fail + 1)); fi
}

# A response under the cap must come back whole and byte-identical: the cap is
# not allowed to cost anything in the normal case.
small=$(bash "$run" bash -c 'printf "Status: Connected\nLoad: 57%%\n"')
eq 'passes small output through' "$small" "$(printf 'Status: Connected\nLoad: 57%%\n')"

# Both streams are capped, and independently: a flood on one must not eat the
# other's budget.
out=$(bash "$run" bash -c 'yes AAAAAAAA | head -c 500000' | wc -c)
eq 'caps stdout' "$out" 65536
err=$(bash "$run" bash -c 'yes BBBBBBBB | head -c 500000 >&2' 2>&1 >/dev/null | wc -c)
eq 'caps stderr' "$err" 65536
both=$(bash "$run" bash -c 'yes A | head -c 500000; yes B | head -c 500000 >&2' 2>/dev/null | wc -c)
eq 'stderr flood does not shrink stdout' "$both" 65536

PROTONVPN_MAX_BYTES=100 bash "$run" bash -c 'yes | head -c 5000' >/dev/null 2>&1
eq 'limit is overridable' "$(PROTONVPN_MAX_BYTES=100 bash "$run" bash -c 'yes | head -c 5000' | wc -c)" 100

# Exit codes are read by the panel, so they have to survive the pipeline. 127
# in particular is how it tells "the CLI is not installed" apart from "the CLI
# refused to do that".
bash "$run" true; eq 'exit 0 survives' "$?" 0
bash "$run" bash -c 'exit 3'; eq 'exit 3 survives' "$?" 3
bash "$run" definitely-not-a-real-binary 2>/dev/null; eq 'exit 127 survives' "$?" 127

# Truncation must not look like success, or a reader would parse half a record
# as if it were the whole thing.
bash "$run" bash -c 'yes | head -c 500000' >/dev/null 2>&1
eq 'truncated call is non-zero' "$([ $? -ne 0 ] && echo yes || echo no)" yes

bash "$run" >/dev/null 2>&1; eq 'no command is a usage error' "$?" 2

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "$fail FAILED"; exit 1; fi
