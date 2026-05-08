#!/usr/bin/env bash
set -euo pipefail

# One-click wrapper for macOS (double-click in Finder to run).
# If macOS blocks it, run in Terminal once:
#   chmod +x "./一键-替换codex-key.command"
# Then double-click again.

script_dir="$(cd "$(dirname "$0")" && pwd)"

bash "$script_dir/codex-key-replace-mac.sh"

echo
read -r -p "Press Enter to close..."

