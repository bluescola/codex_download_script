#!/usr/bin/env bash
set -euo pipefail

read -r -p "请输入 base_url: " BASE_URL
read -r -p "请输入 OPENAI_API_KEY: " OPENAI_API_KEY

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CONFIG_PATH="$CODEX_DIR/config.toml"
AUTH_PATH="$CODEX_DIR/auth.json"

confirm_create() {
  local target="$1"
  local reply
  read -r -p "未找到 $target，是否创建？[y/N]: " reply
  case "$reply" in
    [yY]) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_path() {
  local target="$1"
  local kind="$2"
  if [ -e "$target" ]; then
    return 0
  fi

  if confirm_create "$target"; then
    if [ "$kind" = "dir" ]; then
      mkdir -p "$target"
    else
      touch "$target"
    fi
  else
    echo "已中止：需要 $target"
    exit 1
  fi
}

backup_if_exists() {
  local path="$1"
  if [ -f "$path" ]; then
    cp -f "$path" "${path}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

escape_quotes() {
  printf '%s' "$1" | sed 's/"/\\"/g'
}

escape_json_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

remove_legacy_env_from_file() {
  local file="$1"
  local tmp
  [ -f "$file" ] || return 0

  tmp="$(mktemp)"
  awk '
    $0 ~ "^[[:space:]]*export[[:space:]]+CRS_OAI_KEY=" { next }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

ensure_path "$CODEX_DIR" dir
ensure_path "$CONFIG_PATH" file
ensure_path "$AUTH_PATH" file

backup_if_exists "$CONFIG_PATH"
backup_if_exists "$AUTH_PATH"

escaped_base_url=$(escape_quotes "$BASE_URL")
escaped_openai_key=$(escape_json_string "$OPENAI_API_KEY")

cat > "$CONFIG_PATH" <<EOF
model_provider = "OpenAI"
model = "gpt-5.4"
review_model = "gpt-5.4"
model_reasoning_effort = "xhigh"
disable_response_storage = true
network_access = "enabled"

sandbox_mode = "workspace-write"
approval_policy = "on-request"
# High risk: only use approval_policy = "never" if you fully understand the risk.

[model_providers.OpenAI]
name = "OpenAI"
base_url = "${escaped_base_url}"
wire_api = "responses"
requires_openai_auth = true

[features]
tui_app_server = false
apps = false

[notice.model_migrations]
"gpt-5.1-codex-max" = "gpt-5.4"
"gpt-5.2" = "gpt-5.4"
EOF

printf '{\n  "OPENAI_API_KEY": "%s"\n}\n' "$escaped_openai_key" > "$AUTH_PATH"

remove_legacy_env_from_file "$HOME/.bashrc"
remove_legacy_env_from_file "$HOME/.zshrc"
unset CRS_OAI_KEY || true

echo "已更新：$CONFIG_PATH"
echo "已更新：$AUTH_PATH"
echo "已按当前 CRS 2.0 / OpenAI-compatible 格式重写配置。"
