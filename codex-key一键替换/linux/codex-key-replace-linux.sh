#!/usr/bin/env bash
set -euo pipefail

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

get_current_base_url() {
  local path="$1"
  [ -f "$path" ] || return 0
  sed -n 's/^[[:space:]]*base_url[[:space:]]*=[[:space:]]*"\([^"]*\)".*$/\1/p' "$path" | head -n 1
}

get_current_openai_key() {
  local path="$1"
  [ -f "$path" ] || return 0
  sed -n 's/.*"OPENAI_API_KEY"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$path" | head -n 1
}

mask_secret() {
  local value="$1"
  local length
  if [ -z "$value" ]; then
    printf '<未找到>'
    return
  fi
  length=${#value}
  if [ "$length" -le 10 ]; then
    printf '***'
    return
  fi
  printf '%s...%s' "${value:0:6}" "${value:$((length - 4)):4}"
}

show_crs2_reference_config() {
  local current_base_url="$1"
  local current_openai_key="$2"

  printf '\n'
  printf '当前 CRS 2.0 参考配置（来自现有 config.toml/auth.json，key 已脱敏）：\n'
  if [ -n "$current_base_url" ]; then
    printf '  base_url = "%s"\n' "$current_base_url"
  else
    printf '  base_url = <未找到>\n'
  fi
  printf '  OPENAI_API_KEY = %s\n' "$(mask_secret "$current_openai_key")"
  printf '请输入新的 CRS 2.0 / OpenAI-compatible 配置；直接回车会沿用当前值。\n\n'
}

read_required_value() {
  local prompt="$1"
  local default_value="${2:-}"
  local value

  while true; do
    if [ -n "$default_value" ]; then
      read -r -p "$prompt [回车沿用当前值]: " value
    else
      read -r -p "$prompt: " value
    fi

    if [ -z "$value" ] && [ -n "$default_value" ]; then
      printf '%s' "$default_value"
      return
    fi
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return
    fi
    echo "输入不能为空，请重试。" >&2
  done
}

read_secret_value() {
  local prompt="$1"
  local default_value="${2:-}"
  local value

  while true; do
    if [ -n "$default_value" ]; then
      read -r -s -p "$prompt [回车沿用当前值]: " value
    else
      read -r -s -p "$prompt: " value
    fi
    printf '\n' >&2

    if [ -z "$value" ] && [ -n "$default_value" ]; then
      printf '%s' "$default_value"
      return
    fi
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return
    fi
    echo "输入不能为空，请重试。" >&2
  done
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

CURRENT_BASE_URL="$(get_current_base_url "$CONFIG_PATH")"
CURRENT_OPENAI_KEY="$(get_current_openai_key "$AUTH_PATH")"
show_crs2_reference_config "$CURRENT_BASE_URL" "$CURRENT_OPENAI_KEY"

BASE_URL="$(read_required_value "请输入 CRS 2.0 base_url（例如 https://your-crs-host:8443）" "$CURRENT_BASE_URL")"
OPENAI_API_KEY="$(read_secret_value "请输入 OPENAI_API_KEY / CRS 2.0 token（输入隐藏）" "$CURRENT_OPENAI_KEY")"

ensure_path "$CODEX_DIR" dir
ensure_path "$CONFIG_PATH" file
ensure_path "$AUTH_PATH" file

backup_if_exists "$CONFIG_PATH"
backup_if_exists "$AUTH_PATH"

escaped_base_url=$(escape_quotes "$BASE_URL")
escaped_openai_key=$(escape_json_string "$OPENAI_API_KEY")

cat > "$CONFIG_PATH" <<EOF
model_provider = "OpenAI"
model = "gpt-5.5"
review_model = "gpt-5.4"
model_reasoning_effort = "xhigh"
disable_response_storage = true
network_access = "enabled"

sandbox_mode = "danger-full-access"
approval_policy = "never"
# Normal mode:
# sandbox_mode = "workspace-write"
# approval_policy = "on-request"

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
