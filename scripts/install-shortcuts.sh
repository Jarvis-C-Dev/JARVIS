#!/usr/bin/env bash
# Installs the `jarvis` and `jarvis-mock` commands (macOS and Linux).
#   scripts/install-shortcuts.sh              install
#   scripts/install-shortcuts.sh --uninstall  remove
#
# It links scripts/jarvis into ~/.local/bin under both names, and adds ~/.local/bin to your
# PATH in your shell's startup file if it is not there yet. Nothing else is touched.
set -euo pipefail

here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${JARVIS_BIN_DIR:-$HOME/.local/bin}"
marker="# added by JARVIS scripts/install-shortcuts.sh"

# The startup file of the shell the person actually uses.
case "$(basename "${SHELL:-}")" in
  zsh) rc="$HOME/.zshrc" ;;
  bash) if [ "$(uname)" = "Darwin" ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
  *) rc="$HOME/.profile" ;;
esac
rc="${JARVIS_RC_FILE:-$rc}"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$bin/jarvis" "$bin/jarvis-mock"
  echo "Removed jarvis and jarvis-mock from $bin."
  echo "The PATH line in $rc (marked '$marker') is harmless; delete it if you like."
  exit 0
fi

mkdir -p "$bin"
chmod +x "$here/jarvis"
ln -sf "$here/jarvis" "$bin/jarvis"
ln -sf "$here/jarvis" "$bin/jarvis-mock"
echo "Linked $bin/jarvis and $bin/jarvis-mock -> $here/jarvis"

case ":$PATH:" in
  *":$bin:"*) echo "$bin is already on your PATH." ;;
  *)
    if [ -f "$rc" ] && grep -qF "$marker" "$rc"; then
      echo "$bin is already added to $rc."
    else
      printf '\n%s\nexport PATH="%s:$PATH"\n' "$marker" "$bin" >> "$rc"
      echo "Added $bin to your PATH in $rc."
    fi
    ;;
esac

# A shell alias beats a command of the same name, so an old one would hide the new command.
if [ -f "$rc" ] && grep -Eq '^alias jarvis(-mock)?=' "$rc"; then
  echo
  echo "Heads up: $rc still has an old 'alias jarvis' line, which takes priority."
  echo "Remove it, then open a new Terminal window:"
  if [ "$(uname)" = "Darwin" ]; then
    echo "  sed -i '' -E '/^alias jarvis(-mock)?=/d' \"$rc\""
  else
    echo "  sed -i -E '/^alias jarvis(-mock)?=/d' \"$rc\""
  fi
fi

echo
echo "Open a NEW Terminal window, then type:  jarvis   or   jarvis-mock"
