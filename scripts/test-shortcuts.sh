#!/usr/bin/env bash
# Tests scripts/jarvis and scripts/install-shortcuts.sh in a throwaway HOME with a fake
# `pnpm`, so nothing real is installed or started. Run: scripts/test-shortcuts.sh
set -euo pipefail

here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

export HOME="$tmp/home" SHELL=/bin/zsh
mkdir -p "$HOME" "$tmp/fakebin"
# Stand-ins that record what they were asked to do.
for tool in pnpm cargo; do
  cat > "$tmp/fakebin/$tool" <<'FAKE'
#!/usr/bin/env bash
echo "$(basename "$0") $* | VITE_TRANSPORT=${VITE_TRANSPORT:-unset} | pwd=$(pwd)" >> "$FAKE_LOG"
FAKE
  chmod +x "$tmp/fakebin/$tool"
done
export FAKE_LOG="$tmp/log"
: > "$FAKE_LOG"

# A copy of the repo layout, so `git pull` and the PATH check act on a scratch checkout.
repo="$tmp/JARVIS"
mkdir -p "$repo/scripts"
cp "$here/jarvis" "$here/install-shortcuts.sh" "$repo/scripts/"
git -C "$repo" init -q -b main
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m init

# --- install -----------------------------------------------------------------------------
PATH="$tmp/fakebin:/usr/bin:/bin" "$repo/scripts/install-shortcuts.sh" > "$tmp/install1.txt"
[ -L "$HOME/.local/bin/jarvis" ] || fail "jarvis link missing"
[ -L "$HOME/.local/bin/jarvis-mock" ] || fail "jarvis-mock link missing"
ok "both commands are linked"
grep -q '.local/bin' "$HOME/.zshrc" || fail "PATH line missing in .zshrc"
ok "PATH added to the zsh startup file"

PATH="$tmp/fakebin:/usr/bin:/bin" "$repo/scripts/install-shortcuts.sh" > "$tmp/install2.txt"
[ "$(grep -c 'added by JARVIS' "$HOME/.zshrc")" = 1 ] || fail "PATH line was added twice"
ok "installing twice adds the PATH line once"

# --- an old alias is reported, not silently overridden ------------------------------------
echo "alias jarvis='cd ~/JARVIS'" >> "$HOME/.zshrc"
alias_out="$(PATH="$tmp/fakebin:/usr/bin:/bin" "$repo/scripts/install-shortcuts.sh")"
# (Output is captured first: `grep -q` closing a pipe early would fail under pipefail.)
case "$alias_out" in *"old 'alias jarvis'"*) ;; *) fail "old alias not reported" ;; esac
ok "an old alias line is reported"
sed -i.bak -E '/^alias jarvis(-mock)?=/d' "$HOME/.zshrc" && rm -f "$HOME/.zshrc.bak"

# --- running it ---------------------------------------------------------------------------
run() { (cd "$tmp" && PATH="$HOME/.local/bin:$tmp/fakebin:/usr/bin:/bin" "$@" 2>&1); }

out="$(run jarvis)"
grep -q "pnpm tauri dev | VITE_TRANSPORT=unset | pwd=$repo" "$FAKE_LOG" || fail "jarvis did not run 'pnpm tauri dev' in the repo: $(cat "$FAKE_LOG")"
echo "$out" | grep -q "starting JARVIS" || fail "jarvis banner"
ok "jarvis starts the real app, in the repo, from another folder"

: > "$FAKE_LOG"
out="$(run jarvis-mock)"
grep -q "pnpm tauri dev | VITE_TRANSPORT=mock" "$FAKE_LOG" || fail "jarvis-mock did not set VITE_TRANSPORT=mock: $(cat "$FAKE_LOG")"
echo "$out" | grep -q "MOCK" || fail "jarvis-mock banner"
ok "jarvis-mock starts the mock app"

grep -q "pnpm install --silent" "$FAKE_LOG" || fail "install step missing"
ok "dependencies are installed first"

# --- updating is only done when it is safe -------------------------------------------------
: > "$FAKE_LOG"
echo dirty > "$repo/file.txt"
out="$(run jarvis)"; case "$out" in *"local changes: not updating"*) ;; *) fail "dirty tree should not update: $out" ;; esac
rm "$repo/file.txt"
ok "local changes: no update"

git -C "$repo" checkout -q -b feature
out="$(run jarvis)"; case "$out" in *"on branch 'feature', not 'main': not updating"*) ;; *) fail "feature branch should not update: $out" ;; esac
git -C "$repo" checkout -q main
ok "another branch: no update"

out="$(JARVIS_NO_UPDATE=1 run jarvis)"; case "$out" in *"not updating (JARVIS_NO_UPDATE=1)"*) ;; *) fail "opt-out ignored: $out" ;; esac
ok "JARVIS_NO_UPDATE=1 skips the update"

# main, clean, but no remote: starts anyway and says why
out="$(run jarvis)"; case "$out" in *"could not update"*) ;; *) fail "a failed pull should not stop the app: $out" ;; esac
ok "a failed update still starts the app"

# --- a missing tool is a clear error -------------------------------------------------------
if (cd "$tmp" && PATH="$HOME/.local/bin:/usr/bin:/bin" jarvis > "$tmp/missing.txt" 2>&1); then
  fail "should fail without pnpm"
fi
grep -q "'pnpm' was not found" "$tmp/missing.txt" || fail "missing-tool message: $(cat "$tmp/missing.txt")"
ok "a missing tool gives a clear message"

# --- uninstall ------------------------------------------------------------------------------
PATH="$tmp/fakebin:/usr/bin:/bin" "$repo/scripts/install-shortcuts.sh" --uninstall >/dev/null
[ ! -e "$HOME/.local/bin/jarvis" ] && [ ! -e "$HOME/.local/bin/jarvis-mock" ] || fail "uninstall left links"
ok "uninstall removes both commands"

echo "All shortcut checks passed."
