#!/usr/bin/env bash
# Checks scripts/collect-logs.sh against fixture logs in a temporary folder. Run: scripts/test-collect-logs.sh
set -euo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/collect-logs.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails + 1)); fi; }

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000000Z 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000000Z; }
now="$(date -u +%s)"
recent="$(iso $((now - 600)))"      # 10 minutes ago
old="$(iso $((now - 86400)))"       # a day ago

logs="$tmp/logs"; mkdir -p "$logs"
cat > "$logs/jarvis.2026-11-05.log" <<LOG
{"timestamp":"$old","level":"INFO","fields":{"message":"voice: old line that must be left out"}}
{"timestamp":"$recent","level":"INFO","fields":{"message":"voice: capture ended","why":"a pause after speech","seconds":"2.1","peak":"0.31"}}
{"timestamp":"$recent","level":"WARN","fields":{"message":"home $HOME/Library/x and client 0123456789abcdef0123456789ABCDEF done"}}
{"timestamp":"$recent","level":"ERROR","fields":{"message":"call failed Bearer abc.def-ghi_jkl and sk-ant-api03-PLANTEDKEY12345 for me@example.com"}}
LOG

out="$tmp/report.md"
HOME="$tmp/home" bash "$script" --dir "$logs" --since 2h --note "I held the button and nothing came out. mail me@example.com" --out "$out" >/dev/null

check "writes the report" "[ -f '$out' ]"
check "keeps lines inside the window" "grep -q 'capture ended' '$out'"
check "leaves out lines outside the window" "! grep -q 'must be left out' '$out'"
check "counts one error and one warning" "grep -q 'ERROR: 1, WARN: 1' '$out'"
check "masks a planted key" "! grep -q 'PLANTEDKEY' '$out'"
check "masks a bearer token" "! grep -q 'abc.def-ghi' '$out'"
check "masks a 32-character id" "! grep -qi '0123456789abcdef0123456789abcdef' '$out'"
check "masks email addresses, in the note too" "! grep -q 'example.com' '$out'"
check "includes the person's note" "grep -q 'held the button' '$out'"

# Home folder is masked.
mkdir -p "$tmp/home"
cat > "$logs/jarvis.2026-11-06.log" <<LOG
{"timestamp":"$recent","level":"INFO","fields":{"message":"path $tmp/home/secret-folder/file"}}
LOG
HOME="$tmp/home" bash "$script" --dir "$logs" --since 2h --out "$out" >/dev/null
check "masks the home folder" "! grep -q '$tmp/home' '$out' && grep -q '~/secret-folder' '$out'"

# The cap keeps the newest lines.
for i in $(seq 1 50); do
  echo "{\"timestamp\":\"$recent\",\"level\":\"INFO\",\"fields\":{\"message\":\"line-$i\"}}" >> "$logs/jarvis.2026-11-06.log"
done
HOME="$tmp/home" bash "$script" --dir "$logs" --since 2h --max-lines 5 --out "$out" >/dev/null
check "caps at the newest lines" "grep -q 'line-50' '$out' && ! grep -q 'line-1\"' '$out' && grep -q 'showing the newest 5' '$out'"

# Plain messages when there is nothing to show.
HOME="$tmp/home" bash "$script" --dir "$tmp/nothing" --out "$out" >/dev/null
check "says when there is no log folder" "grep -q 'No log files found' '$out'"
rm -f "$logs"/*.log; echo '{"timestamp":"2000-01-01T00:00:00Z","level":"INFO","fields":{}}' > "$logs/jarvis.2000-01-01.log"
HOME="$tmp/home" bash "$script" --dir "$logs" --out "$out" >/dev/null
check "says when the window is empty" "grep -q 'nothing in the last 2h' '$out'"

# Bad input is refused.
check "refuses a bad --since" "! bash '$script' --since banana --dir '$logs' --out '$out' >/dev/null 2>&1"
check "refuses an unknown option" "! bash '$script' --nope >/dev/null 2>&1"

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "All checks passed."
