#!/usr/bin/env bash
set -euo pipefail

read -r -p "请输入 base_url: " BASE_URL
read -r -p "请输入 CRS_OAI_KEY: " CRS_OAI_KEY

CODEX_DIR="$HOME/.codex"
CONFIG_PATH="$CODEX_DIR/config.toml"

confirm_create() {
  local target="$1"
  local reply
  read -r -p "未找到 ${target}，是否创建？[y/N]: " reply
  case "$reply" in
    [yY]) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ ! -d "$CODEX_DIR" ]]; then
  if confirm_create "$CODEX_DIR"; then
    mkdir -p "$CODEX_DIR"
  else
    echo "已中止：需要 $CODEX_DIR"
    exit 1
  fi
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  if confirm_create "$CONFIG_PATH"; then
    touch "$CONFIG_PATH"
  else
    echo "已中止：需要 $CONFIG_PATH"
    exit 1
  fi
fi

# Pick a shell rc file to persist CRS_OAI_KEY.
# macOS default shell is zsh; fall back to bash if needed.
RC_PATH="$HOME/.zshrc"
if [[ "${SHELL:-}" == *"bash" ]]; then
  RC_PATH="$HOME/.bashrc"
fi

if [[ ! -f "$RC_PATH" ]]; then
  if confirm_create "$RC_PATH"; then
    touch "$RC_PATH"
  else
    echo "已中止：需要 $RC_PATH"
    exit 1
  fi
fi

escape_quotes() {
  printf '%s' "$1" | sed 's/"/\\"/g'
}

escaped_base_url="$(escape_quotes "$BASE_URL")"
escaped_key="$(escape_quotes "$CRS_OAI_KEY")"

base_line="base_url = \"${escaped_base_url}\""
requires_line="requires_openai_auth = false"
key_line="export CRS_OAI_KEY=\"${escaped_key}\""

requires_was_true=0
if [[ -f "$CONFIG_PATH" ]] && grep -qiE '^[[:space:]]*requires_openai_auth[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$CONFIG_PATH"; then
  requires_was_true=1
fi

upsert_toml_kv() {
  local file="$1"
  local key="$2"
  local newline="$3"
  local tmp

  tmp="$(mktemp)"
  awk -v k="$key" -v nl="$newline" '
    BEGIN{found=0}
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      print nl
      found=1
      next
    }
    { print }
    END{
      if (!found) {
        if (NR>0) print ""
        print nl
      }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

upsert_export_line() {
  local file="$1"
  local newline="$2"
  local tmp

  tmp="$(mktemp)"
  awk -v nl="$newline" '
    BEGIN{found=0}
    $0 ~ "^[[:space:]]*export[[:space:]]+CRS_OAI_KEY=" {
      print nl
      found=1
      next
    }
    { print }
    END{
      if (!found) {
        if (NR>0) print ""
        print nl
      }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

upsert_toml_kv "$CONFIG_PATH" "base_url" "$base_line"
upsert_toml_kv "$CONFIG_PATH" "requires_openai_auth" "$requires_line"
upsert_export_line "$RC_PATH" "$key_line"

echo "已更新：$CONFIG_PATH"
echo "已更新：$RC_PATH"
echo "推荐：打开一个新的终端窗口使其生效。"
echo "如需在当前终端生效（二选一）："
echo "  # 方式 A（推荐）：source 你的 rc 文件：source \"$RC_PATH\""
echo "  # 方式 B：临时 export（仅当前终端会话）："
echo "  export CRS_OAI_KEY=\"${escaped_key}\""
if [[ "$requires_was_true" -eq 1 ]]; then
  echo "提示：requires_openai_auth 原为 true，已改为 false。"
fi
