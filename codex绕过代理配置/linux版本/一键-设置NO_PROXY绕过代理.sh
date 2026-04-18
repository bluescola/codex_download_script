#!/usr/bin/env bash
set -euo pipefail

# One-click wrapper for Linux.
# If your file manager doesn't run shell scripts on double-click, run in a terminal:
#   chmod +x ./一键-设置NO_PROXY绕过代理.sh
#   ./一键-设置NO_PROXY绕过代理.sh

script_dir="$(cd "$(dirname "$0")" && pwd)"

bash "$script_dir/setup_no_proxy_linux.sh"

echo
read -r -p "Press Enter to close..."

