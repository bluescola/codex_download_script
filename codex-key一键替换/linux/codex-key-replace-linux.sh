#!/usr/bin/env bash
set -euo pipefail

read -r -p "请输入 base_url: " BASE_URL
read -r -s -p "请输入 CRS_OAI_KEY（隐藏输入）: " CRS_OAI_KEY
printf '\n'

BASE_URL="$(printf '%s' "$BASE_URL" | tr -d '\000-\037\177')"
CRS_OAI_KEY="$(printf '%s' "$CRS_OAI_KEY" | tr -d '\000-\037\177')"
if [[ -z "$BASE_URL" || -z "$CRS_OAI_KEY" ]]; then
  echo "base_url 和 CRS_OAI_KEY 不能为空" >&2
  exit 1
fi

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CONFIG_PATH="$CODEX_DIR/config.toml"
AUTH_PATH="$CODEX_DIR/auth.json"
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

toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

shell_single_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

backup_if_exists() {
  local path="$1"
  if [[ -f "$path" ]]; then
    cp -f "$path" "${path}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

write_default_config() {
  local file="$1"
  local base_url="$2"
  cat > "$file" <<CFG
model_provider = "crs"
model = "gpt-5.2"
model_reasoning_effort = "xhigh"
disable_response_storage = true
preferred_auth_method = "apikey"

sandbox_mode = "workspace-write"
approval_policy = "on-request"

[model_providers.crs]
name = "crs"
base_url = "$base_url"
wire_api = "responses"
requires_openai_auth = false
env_key = "CRS_OAI_KEY"

[features]
tui_app_server = false
apps = false
CFG
}

upsert_toml_section_kv() {
  local file="$1"
  local section="$2"
  local key="$3"
  local newline="$4"
  local tmp
  tmp="$(mktemp)"

  awk -v section="$section" -v key="$key" -v newline="$newline" '
    function is_section(line) { return line ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/ }
    function section_name(line, s) {
      s=line
      sub(/^[[:space:]]*\[/, "", s)
      sub(/\][[:space:]]*$/, "", s)
      return s
    }
    BEGIN { in_target=0; section_found=0; key_written=0 }
    is_section($0) {
      if (in_target && !key_written) {
        print newline
        key_written=1
      }
      in_target=(section_name($0) == section)
      if (in_target) {
        section_found=1
        key_written=0
      }
      print
      next
    }
    in_target && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      if (!key_written) {
        print newline
        key_written=1
      }
      next
    }
    { print }
    END {
      if (in_target && !key_written) {
        print newline
      }
      if (!section_found) {
        print ""
        print "[" section "]"
        print newline
      }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

upsert_export_line() {
  local file="$1"
  local key="$2"
  local value="$3"
  local quoted tmp
  quoted="$(shell_single_quote "$value")"
  tmp="$(mktemp)"

  if [[ -f "$file" ]]; then
    awk -v key="$key" -v quoted="$quoted" '
      BEGIN { done=0 }
      $0 ~ "^[[:space:]]*export[[:space:]]+" key "=" {
        if (!done) {
          print "export " key "=" quoted
          done=1
        }
        next
      }
      { print }
      END {
        if (!done) {
          print ""
          print "export " key "=" quoted
        }
      }
    ' "$file" > "$tmp"
  else
    printf 'export %s=%s\n' "$key" "$quoted" > "$tmp"
  fi
  mv "$tmp" "$file"
}

if [[ ! -d "$CODEX_DIR" ]]; then
  if confirm_create "$CODEX_DIR"; then
    mkdir -p "$CODEX_DIR"
  else
    echo "已中止：需要 $CODEX_DIR"
    exit 1
  fi
fi

escaped_base_url="$(toml_escape "$BASE_URL")"

if [[ -f "$CONFIG_PATH" ]]; then
  backup_if_exists "$CONFIG_PATH"
else
  if confirm_create "$CONFIG_PATH"; then
    write_default_config "$CONFIG_PATH" "$escaped_base_url"
  else
    echo "已中止：需要 $CONFIG_PATH"
    exit 1
  fi
fi

if [[ ! -f "$BASHRC_PATH" ]]; then
  if confirm_create "$BASHRC_PATH"; then
    touch "$BASHRC_PATH"
  else
    echo "已中止：需要 $BASHRC_PATH"
    exit 1
  fi
fi

requires_was_true=0
if grep -qiE '^[[:space:]]*requires_openai_auth[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$CONFIG_PATH"; then
  requires_was_true=1
fi

upsert_toml_section_kv "$CONFIG_PATH" "model_providers.crs" "base_url" "base_url = \"$escaped_base_url\""
upsert_toml_section_kv "$CONFIG_PATH" "model_providers.crs" "requires_openai_auth" "requires_openai_auth = false"
upsert_export_line "$BASHRC_PATH" "CRS_OAI_KEY" "$CRS_OAI_KEY"
upsert_export_line "$BASHRC_PATH" "CODEX_HOME" "$CODEX_DIR"

if [[ -f "$AUTH_PATH" ]]; then
  backup_if_exists "$AUTH_PATH"
fi
cat > "$AUTH_PATH" <<'AUTH'
{
  "OPENAI_API_KEY": null
}
AUTH

echo "已更新：$CONFIG_PATH"
echo "已确认：$AUTH_PATH"
echo "已更新：$BASHRC_PATH"
echo "如需在当前终端生效，请执行：source ~/.bashrc"
if [[ "$requires_was_true" -eq 1 ]]; then
  echo "提示：requires_openai_auth 原为 true，已改为 false。"
fi
