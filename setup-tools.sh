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

gh auth status
