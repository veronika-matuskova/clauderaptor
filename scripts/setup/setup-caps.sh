#!/usr/bin/env bash
# Lets capped.sh cap CPU: delegates the cpu controller to systemd user managers, which by default (systemd 249,
# Ubuntu 22.04) get only memory and pids. Without it, capped.slice's CPUQuota is accepted and not enforced.
# Writes /etc/systemd/system/user@.service.d/delegate.conf (sudo) and reloads systemd. It applies from the
# next start of your user manager: run 'wsl --shutdown' in PowerShell and open a new terminal.
# Safe to re-run: does nothing when the cpu controller is already delegated or the drop-in is already there.
set -euo pipefail
CONTROLLERS="${SETUP_CGROUP_CONTROLLERS:-/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers}"
DROPIN="${SETUP_DELEGATE_DROPIN:-/etc/systemd/system/user@.service.d/delegate.conf}"
CONF=$'[Service]\nDelegate=cpu cpuset io memory pids'

if [ ! -d "${SETUP_SYSTEMD_DIR:-/run/systemd/system}" ]; then
  echo "systemd isn't running: add '[boot] systemd=true' to /etc/wsl.conf, run 'wsl --shutdown' in PowerShell, open a new terminal and re-run $0" >&2
  exit 1
fi
if [[ " $(cat "$CONTROLLERS" 2>/dev/null) " == *" cpu "* ]]; then
  echo "the cpu controller is delegated: capped.sh's CPU cap applies"; exit 0
fi
if [ "$(cat "$DROPIN" 2>/dev/null)" = "$CONF" ]; then
  echo "$DROPIN is there, but your user manager started before it: run 'wsl --shutdown' in PowerShell and open a new terminal"
  exit 0
fi
sudo mkdir -p "$(dirname "$DROPIN")"
printf '%s\n' "$CONF" | sudo tee "$DROPIN" >/dev/null
sudo systemctl daemon-reload
echo "wrote $DROPIN. To apply it, run 'wsl --shutdown' in PowerShell and open a new terminal"
