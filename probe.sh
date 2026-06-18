#!/bin/bash
set -euo pipefail
cd /Users/pfeodrippe/dev/tlzig

MAX_STATES=${MAX_STATES:-200000}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-180}
PASS=0
FAIL=0
SKIP=0
TOTAL=0
FAIL_FILE=$(mktemp)

echo "Probing configs with max_states=$MAX_STATES timeout=${TIMEOUT_SECONDS}s"

run_with_timeout() {
    LC_ALL=C LANG=C /usr/bin/perl -e '
        use strict;
        use warnings;
        my $seconds = shift @ARGV;
        $SIG{ALRM} = sub {
            print STDERR "probe timeout after ${seconds}s\n";
            exit 124;
        };
        alarm $seconds;
        exec @ARGV or die "exec failed: $!\n";
    ' "$TIMEOUT_SECONDS" "$@"
}

while IFS= read -r cfg; do
    TOTAL=$((TOTAL+1))
    dir=$(dirname "$cfg")
    base=$(basename "$cfg" .cfg)
    tla="$dir/$base.tla"
    if [ ! -f "$tla" ]; then
        SKIP=$((SKIP+1))
        echo "SKIP $cfg (no $tla)"
        continue
    fi
    if run_with_timeout ./zig-out/bin/tlzig --spec "$tla" --cfg "$cfg" --max-states "$MAX_STATES" --unlimited-memory --arena-bytes 1073741824 --eval-arena-bytes 1073741824 > /tmp/probe.out 2>&1; then
        PASS=$((PASS+1))
        echo "PASS $cfg $(tail -1 /tmp/probe.out)"
    elif grep -q "InvariantViolated" /tmp/probe.out && grep -q "distinct=" /tmp/probe.out; then
        # Invariant violations are expected behavior for specs designed to find them.
        # TLC also exits non-zero for these. Count as pass if we got distinct states.
        PASS=$((PASS+1))
        echo "PASS $cfg (inv-violated) $(grep -o 'distinct=[0-9]*' /tmp/probe.out)"
    elif grep -q "PropertyViolated" /tmp/probe.out && grep -q "distinct=" /tmp/probe.out; then
        # Property violations are also expected behavior for some specs.
        PASS=$((PASS+1))
        echo "PASS $cfg (prop-violated) $(grep -o 'distinct=[0-9]*' /tmp/probe.out)"
    else
        FAIL=$((FAIL+1))
        err=$(tail -5 /tmp/probe.out | tr '\n' ' ')
        echo "FAIL $cfg: $err"
        echo "$cfg: $err" >> "$FAIL_FILE"
    fi
done < <(find vendor/tlaplus-examples/specifications -name "*.cfg" | sort)

echo ""
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP TOTAL=$TOTAL"
echo ""
echo "Failure summary:"
sort "$FAIL_FILE" | sed -E 's/:.*(error\.[^ ]+).*/: \1/' | sort | uniq -c | sort -rn | head -30
rm "$FAIL_FILE"
