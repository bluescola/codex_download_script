#!/usr/bin/env bash
set -euo pipefail

installer="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../opencode-一键安装包/linux" && pwd)/install-opencode-linux.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export HOME="$test_root/home"
mkdir -p "$HOME"
mkdir -p "$test_root/old-bin"
printf '#!/usr/bin/env bash\nprintf "1.18.18\\n"\n' > "$test_root/old-bin/opencode"
chmod +x "$test_root/old-bin/opencode"
export PATH="$test_root/old-bin:$PATH"

node() { [[ "$1" == --version ]] && printf 'v24.0.0\n'; }
npm() {
  if [[ "$1" == --version ]]; then
    printf '11.0.0\n'
    return
  fi
  printf '%s\n' "$*" >> "$HOME/npm-args"
  mkdir -p "$HOME/.local/share/opencode/npm/bin"
  printf '#!/usr/bin/env bash\nprintf "2.0.0\\n"\n' > "$HOME/.local/share/opencode/npm/bin/opencode"
  chmod +x "$HOME/.local/share/opencode/npm/bin/opencode"
}
export -f node npm

printf '1\n' | bash "$installer" --registry https://registry.example.invalid
test -x "$HOME/.local/share/opencode/npm/bin/opencode"
test "$("$HOME/.local/share/opencode/npm/bin/opencode" --version)" = 2.0.0
test "$(grep -Fc -- '--registry https://registry.example.invalid' "$HOME/npm-args")" = 1
test "$(grep -Fc '# >>> opencode npm >>>' "$HOME/.bashrc")" = 1
test "$(grep -Fc '# >>> opencode npm >>>' "$HOME/.profile")" = 1
test "$(grep -Fc 'https://opencode.ai/config.json' "$HOME/.config/opencode/opencode.json")" = 1

printf '1\n' | bash "$installer" --registry https://registry.example.invalid --force-opencode-reinstall
test "$(grep -Fc '# >>> opencode npm >>>' "$HOME/.bashrc")" = 1
test "$(grep -Fc '# >>> opencode npm >>>' "$HOME/.profile")" = 1
printf 'OpenCode Linux smoke test passed\n'
