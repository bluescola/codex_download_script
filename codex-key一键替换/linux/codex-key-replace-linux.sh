#!/usr/bin/env bash
set -euo pipefail

read -r -p "请输入 base_url: " BASE_URL
read -r -p "请输入 CRS_OAI_KEY: " CRS_OAI_KEY

CODEX_DIR="$HOME/.codex"
CONFIG_PATH="$CODEX_DIR/config.toml"
BASHRC_PATH="$HOME/.bashrc"

confirm_create() {
  local target="$1"
  local reply
  read -r -p "未找到 $target，是否创建？[y/N]: " reply
  case "$reply" in
    [yY]) return 0 ;;
    *) return 1 ;;
  esac
}

if [ ! -d "$CODEX_DIR" ]; then
  if confirm_create "$CODEX_DIR"; then
    mkdir -p "$CODEX_DIR"
  else
    echo "已中止：需要 $CODEX_DIR"
    exit 1
  fi
fi

if [ ! -f "$CONFIG_PATH" ]; then
  if confirm_create "$CONFIG_PATH"; then
    touch "$CONFIG_PATH"
  else
    echo "已中止：需要 $CONFIG_PATH"
    exit 1
  fi
fi

if [ ! -f "$BASHRC_PATH" ]; then
  if confirm_create "$BASHRC_PATH"; then
    touch "$BASHRC_PATH"
  else
    echo "已中止：需要 $BASHRC_PATH"
    exit 1
  fi
fi

escape_quotes() {
  printf '%s' "$1" | sed 's/"/\\"/g'
}

escaped_base_url=$(escape_quotes "$BASE_URL")
escaped_key=$(escape_quotes "$CRS_OAI_KEY")

base_line="base_url = \"$escaped_base_url\""
key_line="export CRS_OAI_KEY=\"$escaped_key\""
requires_line="requires_openai_auth = false"
requires_was_true=0
if [ -f "$CONFIG_PATH" ] && grep -qiE '^[[:space:]]*requires_openai_auth[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$CONFIG_PATH"; then
  requires_was_true=1
fi

if grep -qE '^[[:space:]]*base_url[[:space:]]*=' "$CONFIG_PATH"; then
  sed -i "s|^[[:space:]]*base_url[[:space:]]*=.*|$base_line|" "$CONFIG_PATH"
else
  printf '\n%s\n' "$base_line" >> "$CONFIG_PATH"
fi

if grep -qE '^[[:space:]]*requires_openai_auth[[:space:]]*=' "$CONFIG_PATH"; then
  sed -i "s|^[[:space:]]*requires_openai_auth[[:space:]]*=.*|$requires_line|" "$CONFIG_PATH"
else
  printf '\n%s\n' "$requires_line" >> "$CONFIG_PATH"
fi

if grep -qE '^[[:space:]]*export[[:space:]]+CRS_OAI_KEY=' "$BASHRC_PATH"; then
  sed -i "s|^[[:space:]]*export[[:space:]]+CRS_OAI_KEY=.*|$key_line|" "$BASHRC_PATH"
else
  printf '\n%s\n' "$key_line" >> "$BASHRC_PATH"
fi

# This only affects the current script process.
# shellcheck disable=SC1090
source "$BASHRC_PATH" || true

echo "已更新：$CONFIG_PATH"
echo "已更新：$BASHRC_PATH"
echo "已执行：source ~/.bashrc（仅影响当前脚本进程）"
echo "如需在当前终端生效，请执行：source ~/.bashrc"
if [ "$requires_was_true" -eq 1 ]; then
  echo "提示：requires_openai_auth 原为 true，已改为 false。"
fi