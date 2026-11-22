#!/usr/bin/env bash
# Installs and authenticates CLI tools Claude Code uses to work with repos (Ubuntu/WSL).
# Safe to re-run: skips steps that are already done.
set -euo pipefail

# --- GitHub CLI (gh) from the official apt repo ---
if ! command -v gh >/dev/null 2>&1; then
  echo "installing gh..."
  sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y gh
else
  echo "gh already installed: $(gh --version | head -1)"
fi

# --- shellcheck (lints this repo's *.sh scripts) ---
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "installing shellcheck..."
  sudo apt-get install -y shellcheck
else
  echo "shellcheck already installed"
fi

# --- Authenticate (interactive, browser/device-code flow) ---
if ! gh auth status >/dev/null 2>&1; then
  gh auth login --hostname github.com --git-protocol https --web
else
  echo "gh already authenticated"
fi

# Use gh as git's credential helper for github.com (overrides other helpers for that host only)
gh auth setup-git

# --- Sign commits and tags with an SSH key, so GitHub shows them as "Verified" ---
# Dedicated signing-only key (GitHub won't accept it for push/auth). No passphrase, so
# non-interactive commits (e.g. from Claude Code) can sign without a prompt.
SIGNING_KEY="$HOME/.ssh/id_ed25519_signing"
EMAIL="$(git config --global user.email || true)"
if [ -z "$EMAIL" ]; then
  echo "set your commit email first: git config --global user.email <email on your GitHub account>" >&2
  exit 1
fi
if [ ! -f "$SIGNING_KEY.pub" ]; then
  echo "creating SSH signing key $SIGNING_KEY..."
  [ -d "$HOME/.ssh" ] || mkdir -m 700 "$HOME/.ssh"
  ssh-keygen -q -t ed25519 -N "" -C "$EMAIL" -f "$SIGNING_KEY"
fi
read -r ktype kdata _ < "$SIGNING_KEY.pub"
pubkey="$ktype $kdata"

# Is the key on GitHub already? The account's public list of signing keys needs no token scope,
# so a re-run on a set-up machine starts no auth flow.
login="$(gh api user --jq .login)"
if grep -qxF "$pubkey" <<<"$(gh api --paginate "users/$login/ssh_signing_keys" --jq '.[].key')"; then
  echo "signing key already on GitHub"
else
  # Uploading needs an extra token scope (interactive, browser/device-code flow)
  if [[ "$(gh auth status 2>&1)" != *admin:ssh_signing_key* ]]; then
    gh auth refresh --hostname github.com --scopes admin:ssh_signing_key
  fi
  gh ssh-key add "$SIGNING_KEY.pub" --type signing --title "$HOSTNAME commit signing"
fi
# Drop that scope again, also when an earlier run left it (interactive, browser/device-code flow)
if [[ "$(gh auth status 2>&1)" == *admin:ssh_signing_key* ]]; then
  echo "removing the admin:ssh_signing_key scope: the gh token every tool and agent uses shouldn't manage signing keys"
  gh auth refresh --hostname github.com --remove-scopes admin:ssh_signing_key
fi

git config --global gpg.format ssh
git config --global user.signingkey "$SIGNING_KEY.pub"
git config --global commit.gpgsign true
git config --global tag.gpgsign true
# Lets `git log --show-signature` verify signatures locally
ALLOWED="$HOME/.config/git/allowed_signers"
mkdir -p "${ALLOWED%/*}"
grep -qF "$pubkey" "$ALLOWED" 2>/dev/null || echo "$EMAIL $pubkey" >> "$ALLOWED"
git config --global gpg.ssh.allowedSignersFile "$ALLOWED"
echo "commits and tags are signed with $SIGNING_KEY"

gh auth status
