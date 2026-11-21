# shellcheck shell=bash
# Tests for claude/statusline.py: feeds sample status JSON, checks the rendered text.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

SL="$ROOT/claude/statusline.py"
strip() { sed 's/\x1b\[[0-9;]*m//g'; }   # drop colour codes

git init -q -b main "$TMP/r"; git -C "$TMP/r" commit -q --allow-empty -m init
now=$(date +%s)
json() { cat <<EOF
{"model":{"display_name":"Opus"},"thinking":{"enabled":true},"effort":{"level":"xhigh"},
 "workspace":{"current_dir":"$TMP/r"},
 "context_window":{"total_input_tokens":150500,"context_window_size":1000000,"used_percentage":15},
 "cost":{"total_duration_ms":3725000,"total_cost_usd":1.234},
 "rate_limits":{"five_hour":{"used_percentage":30,"resets_at":$((now + 7290))},"seven_day":{"used_percentage":90}}}
EOF
}

out="$(json | python3 "$SL" | strip)"
assert_contains "model and effort" "$out" "Opus | xhigh |"
assert_contains "token counts"     "$out" "150.5k/1M (15%)"
assert_contains "duration"         "$out" "1h 2m"
# shellcheck disable=SC2016  # literal dollar sign, not an expansion
assert_contains "cost"             "$out" '$1.23'
assert_contains "branch, clean"    "$out" "| main | ✓"
assert_contains "5h limit + reset" "$out" "5h: 70% - 2h 1m"
assert_contains "7d limit"         "$out" "7d: 10%"
assert_contains "limit separator in bar" "$out" "│"
assert "three lines" test "$(json | python3 "$SL" | wc -l)" -eq 2   # 2 newlines = 3 lines

touch "$TMP/r/new"
assert_contains "dirty marker" "$(json | python3 "$SL" | strip)" "| main | ✗"

assert "git does not leave index.lock" test ! -e "$TMP/r/.git/index.lock"
assert "no raw ESC bytes in source" bash -c "! grep -q $'\x1b' '$SL'"

out="$(echo 'not json' | python3 "$SL" 2>&1)"; rc=$?
assert "bad input: exits 0" test "$rc" -eq 0
assert_contains "bad input: limits shown as --" "$(echo "$out" | strip)" "7d: -- | 5h: --"

finish
