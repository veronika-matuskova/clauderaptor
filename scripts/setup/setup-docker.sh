#!/usr/bin/env bash
# Installs Docker Engine inside WSL (Ubuntu), replacing Docker Desktop's WSL integration.
# systemd socket-activates the daemon: the first `docker` command starts it, so agents
# never need to start anything (or sudo). Safe to re-run: skips steps that are already done.
set -euo pipefail

# Docker Desktop's integration puts its own `docker` on PATH and would replace ours when it starts
if p="$(type -P docker)" && [[ "$(readlink -f "$p")" == */docker-desktop/* ]]; then
  cat >&2 <<EOF
'docker' here is Docker Desktop's ($p). Turn its WSL integration off first:
  1. Docker Desktop > Settings > Resources > WSL integration: untick
     "Enable integration with my default WSL distro" and "${WSL_DISTRO_NAME:-this distro}", then Apply
  2. Quit Docker Desktop (or uninstall it)
  3. In PowerShell run 'wsl --shutdown', open a new WSL terminal and re-run $0
EOF
  exit 1
fi

# Check the platform before any sudo, so an unsupported machine fails before anything is written
OS_RELEASE="${SETUP_OS_RELEASE:-/etc/os-release}"
# shellcheck source=/dev/null
os_id="$(. "$OS_RELEASE" 2>/dev/null && echo "${ID:-}")"
if [ "$os_id" != ubuntu ]; then
  echo "this script supports Ubuntu (WSL) only; $OS_RELEASE says ID=${os_id:-unknown}" >&2; exit 1
fi
if [ ! -d "${SETUP_SYSTEMD_DIR:-/run/systemd/system}" ]; then
  echo "systemd isn't running: add '[boot] systemd=true' to /etc/wsl.conf, run 'wsl --shutdown' in PowerShell, open a new terminal and re-run $0" >&2
  exit 1
fi

# --- Docker Engine from Docker's official apt repo ---
if ! command -v dockerd >/dev/null 2>&1; then
  echo "installing Docker Engine..."
  sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
  sudo chmod go+r /etc/apt/keyrings/docker.asc
  # shellcheck source=/dev/null
  codename="$(. "$OS_RELEASE" && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "Docker Engine already installed: $(dockerd --version)"
fi

# --- Use docker without sudo (applies to new login sessions) ---
me="$(id -un)"
if ! id -nG "$me" | grep -qw docker; then
  sudo usermod -aG docker "$me"
  echo "added $me to the docker group"
fi

# --- Start the daemon on demand: connecting to /var/run/docker.sock starts docker.service ---
if ! systemctl is-enabled --quiet docker.socket 2>/dev/null; then
  sudo systemctl enable --now docker.socket
fi

# Docker Desktop leaves "credsStore": "desktop.exe" behind; without Desktop every pull fails on it
cfg="$HOME/.docker/config.json"
if grep -q '"credsStore": *"desktop.exe"' "$cfg" 2>/dev/null; then
  python3 - "$cfg" <<'EOF'
import json, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
del cfg["credsStore"]
with open(sys.argv[1], "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
EOF
  echo "removed Docker Desktop's credsStore from $cfg"
fi

if out="$(docker info 2>&1)"; then
  echo "docker is ready: server $(docker version --format '{{.Server.Version}}')"
elif ! id -nG | grep -qw docker && id -nG "$me" | grep -qw docker && out="$(sg docker -c 'docker info' 2>&1)"; then
  # Just joined the group: docker works, but only shells started from now on have the group
  echo "docker is ready. Open a new terminal to use it without sudo (this one started before you joined the docker group)."
else
  echo "$out" >&2  # from the sg retry if it ran, so a real daemon error isn't hidden behind "permission denied"
  echo "docker info failed. If it says permission denied, open a new terminal so the docker group applies (if that's not enough, run 'wsl --shutdown' in PowerShell)." >&2
  exit 1
fi
