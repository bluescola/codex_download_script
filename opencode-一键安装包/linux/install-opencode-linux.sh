#!/usr/bin/env bash
set -euo pipefail

OPENCODE_TARGET_OS=linux
export OPENCODE_TARGET_OS
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$script_dir/../shared/install-opencode.sh" "$@"
