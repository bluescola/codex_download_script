#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
test_root="$(mktemp -d "$tmp_parent/codex-restart-test.XXXXXX")"
cleanup() {
  if [[ "$test_root" == "$tmp_parent"/codex-restart-test.* && -d "$test_root" ]]; then
    rm -rf -- "$test_root"
  fi
}
trap cleanup EXIT

mkdir -p "$test_root/bin" "$test_root/home/.codex"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$MOCK_UNAME"' > "$test_root/bin/uname"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ "$CUSTOM_KEY" == fixture-key && "$CODEX_HOME" == "$EXPECTED_CODEX_HOME" ]] || exit 3' \
  'printf "%s\n" "$*" >> "$CALL_LOG"' \
  'case "$*" in' \
  '  --version) printf "%s\n" "codex-cli test" ;;' \
  '  "app-server daemon version") printf "%s\n" "{\"status\":\"running\"}" ;;' \
  '  "app-server daemon stop"|"app-server daemon start") ;;' \
  '  *) exit 2 ;;' \
  'esac' > "$test_root/bin/codex"
chmod +x "$test_root/bin/uname" "$test_root/bin/codex"

export HOME="$test_root/home"
export PATH="$test_root/bin:$PATH"
export EXPECTED_CODEX_HOME="$HOME/.codex"
export CUSTOM_KEY=fixture-key
unset CODEX_HOME CRS_OAI_KEY || true

for platform in Linux Darwin; do
  export MOCK_UNAME="$platform"
  export CALL_LOG="$test_root/$platform.calls"
  if [[ "$platform" == Linux ]]; then
    script="$repo_root/Codex-Linux-一键安装包/restart-codex-app-server-linux.sh"
  else
    script="$repo_root/Codex-Mac-一键安装包/restart-codex-app-server-mac.sh"
  fi

  bash "$script" --force > "$test_root/$platform.output"
  expected=$'--version\napp-server daemon stop\napp-server daemon start\napp-server daemon version'
  actual="$(< "$CALL_LOG")"
  [[ "$actual" == "$expected" ]] || {
    printf 'Unexpected %s command sequence:\n%s\n' "$platform" "$actual" >&2
    exit 1
  }
done

printf '%s\n' 'Linux/macOS app-server restart smoke test passed'
