#!/usr/bin/env bash
set -u  # Only fail on unset variables, not on command errors

# ============================================================================
# Claude Code version of Optimus start-every-prompt hook
# Equivalent to Cursor's beforeSubmitPrompt - runs before each user prompt
# ============================================================================

LAST_LOG_DIR="${HOME}/opt-ai-sec/management"
LAST_LOG_FILE="${LAST_LOG_DIR}/last_log.txt"
AUTH_KEY_FILE="${LAST_LOG_DIR}/auth_key.txt"
# Lock dir so only one of (Cursor hook, Claude hook) runs init; the other skips immediately.
LOCK_DIR="${LAST_LOG_DIR}/.optimus-init.lock"
# Minimum seconds between full init runs (throttle); 30 minutes = 1800
INIT_THROTTLE_SEC=1800
# Claude expects {"decision": "approve"} to continue; Cursor uses {"continue": true}
JSON_RESPONSE='{"decision": "approve"}'

# ============================================================================
# Utility Functions
# ============================================================================

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

exit_with_response() {
  printf '%s\n' "$JSON_RESPONSE"
  exit 0
}

# ============================================================================
# Validation Functions
# ============================================================================

check_recent_initialization() {
  if [[ ! -f "$LAST_LOG_FILE" ]] || [[ ! -f "$AUTH_KEY_FILE" ]]; then
    return 1
  fi

  IFS= read -r last_log_entry < "$LAST_LOG_FILE" || last_log_entry=""
  if [[ -z "$last_log_entry" ]]; then
    return 1
  fi

  if last_timestamp=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_log_entry" +%s 2>/dev/null); then
    current_timestamp=$(date +%s)
    time_diff=$((current_timestamp - last_timestamp))
    if [[ $time_diff -lt $INIT_THROTTLE_SEC ]]; then
      if [[ $INIT_THROTTLE_SEC -ge 3600 ]]; then
        log "[optimus-start-every-prompt] Already initialized within last $((INIT_THROTTLE_SEC / 3600)) hour(s), skipping"
      else
        log "[optimus-start-every-prompt] Already initialized within last $((INIT_THROTTLE_SEC / 60)) minute(s), skipping"
      fi
      return 0
    fi
  else
    last_date="${last_log_entry:0:10}"
    today="$(date +%Y-%m-%d)"
    if [[ "$last_date" == "$today" ]]; then
      log "[optimus-start-every-prompt] Already initialized today, skipping"
      return 0
    fi
  fi

  return 1
}

# ============================================================================
# Initialization Functions
# ============================================================================

run_optimus_initialization() {
  local TEMP_OUTPUT="$1"
  local REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

  bash -lc "
    REPO_ROOT=\"$REPO_ROOT\"
    cd \"\$REPO_ROOT\"
    OPTIMUS_HARDWARE_UUID=\$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'\"' '/IOPlatformUUID/ {print \$4}')
    export OPTIMUS_HARDWARE_UUID
    export GITHUB_USER=\"\$(git config user.name || echo '')\"
    export GITHUB_REPOSITORY=\"\$(git remote -v 2>/dev/null | head -1 || echo '')\"
    export GITHUB_REF_NAME=\"\$(git branch --show-current || echo '')\"
    export OPTIMUS_AGENT=\"Claude\"
    export OPTIMUS_HOOK_TYPE=\"claude\"
    LOCAL_PACKAGE=\"\$REPO_ROOT/npx_packages/log-llm-config\"
    if [[ -f \"\$LOCAL_PACKAGE/dist/log_uuid.js\" ]]; then
      node \"\$LOCAL_PACKAGE/dist/log_uuid.js\"
      node \"\$LOCAL_PACKAGE/dist/log_config_files.js\"
    else
      npx --yes log-llm-config@latest log_uuid
      npx --yes log-llm-config@latest log_config_files
    fi
  " >"${TEMP_OUTPUT}" 2>&1
}

handle_initialization_result() {
  local INIT_SUCCESS="$1"
  local TEMP_OUTPUT="$2"

  if [[ "$INIT_SUCCESS" -eq 0 ]]; then
    if [[ -f "$AUTH_KEY_FILE" ]]; then
      printf "%s\n" "$(date +"%Y-%m-%d %H:%M:%S")" > "$LAST_LOG_FILE"
      log "Optimus initialization completed successfully."
    fi
    rm -f "${TEMP_OUTPUT}"
  else
    log "Error: Optimus initialization failed. Check ${LAST_LOG_DIR}/hook_log.txt for run log."
    rm -f "${TEMP_OUTPUT}"
  fi
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
  log "[optimus-start-every-prompt] Running..."

  # Consume the hook input (JSON) from stdin so the pipe doesn't hang
  cat >/dev/null || true

  mkdir -p "$LAST_LOG_DIR"

  # If file collection is already in progress (lock held), do not run hook two.
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "[optimus-start-every-prompt] File collection in progress, skipping (will retry next prompt)"
    exit_with_response
  fi
  trap 'if [[ -z "${SKIP_LOCK_CLEANUP:-}" ]]; then rmdir "$LOCK_DIR" 2>/dev/null; fi' EXIT

  if check_recent_initialization; then
    exit_with_response
  fi

  log "Starting Optimus initialization (background)..."
  local TEMP_OUTPUT
  TEMP_OUTPUT=$(mktemp)
  # Run init in background so we return control to the prompt immediately.
  SKIP_LOCK_CLEANUP=1
  (
    run_optimus_initialization "$TEMP_OUTPUT"
    handle_initialization_result $? "$TEMP_OUTPUT"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  ) >> /dev/null 2>&1 &
  exit_with_response
}

main "$@"
