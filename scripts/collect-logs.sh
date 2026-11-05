#!/usr/bin/env bash
# Turns JARVIS's logs into one short report you can read, then paste into a GitHub issue.
#
#   scripts/collect-logs.sh                          last 2 hours
#   scripts/collect-logs.sh --since 30m --note "held the button, said what time is it, got nothing"
#   scripts/collect-logs.sh --copy                   also put the report on the clipboard (macOS)
#
# It only READS the app's log folder and only WRITES one file under the repository's git-ignored
# `logs/` folder. It sends nothing anywhere. The logs hold events and timings (key-shaped text is
# already masked, and they never hold your messages or any audio); this adds a second pass that
# also masks your home folder, 32-character hex ids (a Spotify Client ID), bearer tokens and
# email addresses. READ THE REPORT BEFORE YOU SHARE IT. Paste it into an issue comment; do not
# commit it. Works on macOS, Linux and Git Bash on Windows.
set -euo pipefail

since="2h"
note=""
dir=""
out=""
copy=0
max_lines=400

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --since) since="${2:-}"; shift 2 ;;
    --note) note="${2:-}"; shift 2 ;;
    --dir) dir="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --max-lines) max_lines="${2:-}"; shift 2 ;;
    --copy) copy=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --since is a number and a unit: 30m, 2h, 1d.
if ! [[ "$since" =~ ^([0-9]+)([mhd])$ ]]; then
  echo "--since must look like 30m, 2h or 1d (got '$since')." >&2
  exit 2
fi
amount="${BASH_REMATCH[1]}"
unit="${BASH_REMATCH[2]}"
case "$unit" in m) secs=$((amount * 60)) ;; h) secs=$((amount * 3600)) ;; d) secs=$((amount * 86400)) ;; esac
if ! [[ "$max_lines" =~ ^[0-9]+$ ]] || [ "$max_lines" -lt 1 ]; then
  echo "--max-lines must be a positive number." >&2
  exit 2
fi

# Where the app writes its logs (docs/privacy.md).
if [ -z "$dir" ]; then
  case "$(uname -s)" in
    Darwin) dir="$HOME/Library/Logs/com.jarvis.desktop" ;;
    Linux) dir="${XDG_DATA_HOME:-$HOME/.local/share}/com.jarvis.desktop/logs" ;;
    MINGW*|MSYS*|CYGWIN*) dir="${LOCALAPPDATA:-$HOME/AppData/Local}/com.jarvis.desktop/logs" ;;
    *) echo "Unknown system; pass --dir <log folder>." >&2; exit 1 ;;
  esac
fi

repo="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
[ -n "$out" ] || out="$repo/logs/report-$stamp.md"

# The oldest time to keep, as an ISO UTC string (those compare correctly as text).
now_epoch="$(date -u +%s)"
cutoff_epoch=$((now_epoch - secs))
if cutoff="$(date -u -r "$cutoff_epoch" +%Y-%m-%dT%H:%M:%S 2>/dev/null)"; then :; else
  cutoff="$(date -u -d "@$cutoff_epoch" +%Y-%m-%dT%H:%M:%S)"
fi

home_escaped="$(printf '%s' "$HOME" | sed 's/[][\.*^$/|]/\\&/g')"
redact() {
  sed -E \
    -e "s|$home_escaped|~|g" \
    -e 's/[0-9a-fA-F]{32}/***ID***/g' \
    -e 's/[Bb]earer +[A-Za-z0-9._~+\/=-]+/Bearer ***REDACTED***/g' \
    -e 's/sk-[A-Za-z0-9_-]{8,}/***REDACTED***/g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/***EMAIL***/g'
}

mkdir -p "$(dirname "$out")"

found_files=0
tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.all"' EXIT
if [ -d "$dir" ]; then
  for f in "$dir"/jarvis*.log; do
    [ -f "$f" ] || continue
    found_files=$((found_files + 1))
    cat "$f" >> "$tmp.all"
  done
fi

total=0
if [ -f "$tmp.all" ]; then
  # Keep lines whose "timestamp" is at or after the cutoff. A line with no timestamp is kept only
  # if it follows a kept one (a continuation), so a broken line never hides what came before it.
  awk -v cutoff="$cutoff" '
    {
      if (match($0, /"timestamp":"[^"]+"/)) {
        ts = substr($0, RSTART + 13, RLENGTH - 14)
        keep = (substr(ts, 1, 19) >= cutoff)
      }
      if (keep) print
    }' "$tmp.all" > "$tmp.window"
  total="$(wc -l < "$tmp.window" | tr -d ' ')"
  tail -n "$max_lines" "$tmp.window" | redact > "$tmp"
  rm -f "$tmp.window"
fi

count_level() { grep -c "\"level\":\"$1\"" "$tmp" 2>/dev/null || true; }
errors="$(count_level ERROR)"; warns="$(count_level WARN)"; infos="$(count_level INFO)"
shown="$(wc -l < "$tmp" | tr -d ' ')"

commit="not in a git checkout"
if command -v git >/dev/null 2>&1 && git -C "$repo" rev-parse --short HEAD >/dev/null 2>&1; then
  commit="$(git -C "$repo" rev-parse --short HEAD)$(git -C "$repo" diff --quiet 2>/dev/null || echo ' (local changes)')"
fi

{
  echo "# JARVIS log report"
  echo
  echo "- Made (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- System: $(uname -sm)"
  echo "- Repository commit: $commit"
  echo "- Window: last $since (from $cutoff UTC)"
  echo "- Log folder: $(printf '%s' "$dir" | redact)"
  echo
  echo "## What happened (the person's note)"
  echo
  if [ -n "$note" ]; then printf '%s\n' "$note" | redact; else echo "_No note given. Add one with --note \"what I did and what I saw\"._"; fi
  echo
  echo "## Summary"
  echo
  if [ "$found_files" -eq 0 ]; then
    echo "No log files found in that folder. The app may not have run, or the folder is somewhere else (use --dir)."
  elif [ "$total" -eq 0 ]; then
    echo "$found_files log file(s) found, but nothing in the last $since. Try a longer window, for example --since 1d."
  else
    echo "$total line(s) in the window; showing the newest $shown. ERROR: ${errors:-0}, WARN: ${warns:-0}, INFO: ${infos:-0}."
  fi
  echo
  echo "## Log lines (oldest first)"
  echo
  echo '```json'
  cat "$tmp"
  echo '```'
  echo
  echo "_Read this before sharing. It was masked for keys, your home folder, 32-character ids, bearer tokens and emails, but check it yourself. Paste it into a GitHub issue comment; do not commit it._"
} > "$out"

echo "Report written to: $out"
echo "Lines in window: $total (shown: $shown). ERROR: ${errors:-0}  WARN: ${warns:-0}"
if [ "$copy" -eq 1 ]; then
  if command -v pbcopy >/dev/null 2>&1; then pbcopy < "$out" && echo "Copied to the clipboard."
  elif command -v clip.exe >/dev/null 2>&1; then clip.exe < "$out" && echo "Copied to the clipboard."
  else echo "No clipboard tool found; open the file and copy it."; fi
fi
echo "Read it, then paste it into an issue comment. Do not commit it."
