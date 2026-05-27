#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$script_dir/../../Codex-Mac-一键安装包/setup_no_proxy_mac.sh" "$@"
