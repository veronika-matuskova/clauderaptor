#!/usr/bin/env bash
# Installs the stats app as the raptor-stats command: a link to dashboard.sh in ${XDG_BIN_HOME:-~/.local/bin}.
#   install.sh              install (or repoint) the link
#   install.sh --uninstall  remove it, only if it is this app's link
# Separate from clauderaptor's setup: run it only if you want the app. Nothing is copied, so a git pull updates it.
set -euo pipefail
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
bin="${XDG_BIN_HOME:-$HOME/.local/bin}"
link="$bin/raptor-stats"
target="$here/dashboard.sh"

case "${1:-}" in
  "")
    if [ -e "$link" ] && ! [ -L "$link" ]; then
      echo "install.sh: $link exists and is not a link; move it away first" >&2; exit 1
    fi
    mkdir -p "$bin"
    ln -sfn "$target" "$link"
    echo "installed: $link -> $target"
    case ":$PATH:" in
      *":$bin:"*) echo "run: raptor-stats" ;;
      *) echo "note: $bin is not on your PATH; add it (e.g. in ~/.profile) to run raptor-stats" ;;
    esac
    ;;
  --uninstall)
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
      rm "$link"; echo "removed: $link"
    elif [ -e "$link" ] || [ -L "$link" ]; then
      echo "install.sh: $link is not this app's link; left as it is" >&2; exit 1
    else
      echo "not installed: no $link"
    fi
    ;;
  -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "install.sh: unknown argument: $1 (see --help)" >&2; exit 2 ;;
esac
