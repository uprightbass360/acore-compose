#!/bin/bash
#
# High-level orchestrator for module-aware deployments.
# 1. Ensures AzerothCore source repo is present
# 2. Runs ac-modules to sync/clean module checkout and configs
# 3. Rebuilds source images when C++ modules demand it
# 4. Stages target compose profile and optionally tails worldserver logs

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
ENV_PATH="$ROOT_DIR/.env"
TARGET_PROFILE=""
WATCH_LOGS=1
KEEP_RUNNING=0
WORLD_LOG_SINCE=""
ASSUME_YES=0

REMOTE_MODE=0
REMOTE_HOST=""
REMOTE_USER=""
REMOTE_PORT="22"
REMOTE_IDENTITY=""
REMOTE_PROJECT_DIR=""
REMOTE_SKIP_STORAGE=0
REMOTE_ARGS_PROVIDED=0

COMPILE_MODULE_VARS=(
  MODULE_AOE_LOOT MODULE_LEARN_SPELLS MODULE_FIREWORKS MODULE_INDIVIDUAL_PROGRESSION MODULE_AHBOT MODULE_AUTOBALANCE
  MODULE_TRANSMOG MODULE_NPC_BUFFER MODULE_DYNAMIC_XP MODULE_SOLO_LFG MODULE_1V1_ARENA MODULE_PHASED_DUELS
  MODULE_BREAKING_NEWS MODULE_BOSS_ANNOUNCER MODULE_ACCOUNT_ACHIEVEMENTS MODULE_AUTO_REVIVE MODULE_GAIN_HONOR_GUARD
  MODULE_TIME_IS_TIME MODULE_POCKET_PORTAL MODULE_RANDOM_ENCHANTS MODULE_SOLOCRAFT MODULE_PVP_TITLES MODULE_NPC_BEASTMASTER
  MODULE_NPC_ENCHANTER MODULE_INSTANCE_RESET MODULE_LEVEL_GRANT MODULE_ARAC MODULE_ASSISTANT MODULE_REAGENT_BANK
  MODULE_CHALLENGE_MODES MODULE_OLLAMA_CHAT MODULE_PLAYER_BOT_LEVEL_BRACKETS MODULE_STATBOOSTER MODULE_DUNGEON_RESPAWN
  MODULE_SKELETON_MODULE MODULE_BG_SLAVERYVALLEY MODULE_AZEROTHSHARD MODULE_WORGOBLIN
)

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info(){ printf '%b\n' "${BLUE}ℹ️  $*${NC}"; }
ok(){ printf '%b\n' "${GREEN}✅ $*${NC}"; }
warn(){ printf '%b\n' "${YELLOW}⚠️  $*${NC}"; }
err(){ printf '%b\n' "${RED}❌ $*${NC}"; }

show_deployment_header(){
  printf '\n%b\n' "${BLUE}⚔️  AZEROTHCORE REALM DEPLOYMENT ⚔️${NC}"
  printf '%b\n' "${BLUE}═══════════════════════════════════════${NC}"
  printf '%b\n\n' "${BLUE}🏰 Bringing Your Realm Online 🏰${NC}"
}

show_step(){
  local step="$1" total="$2" message="$3"
  printf '%b\n' "${YELLOW}🔧 Step ${step}/${total}: ${message}...${NC}"
}

show_realm_ready(){
  printf '\n%b\n' "${GREEN}⚔️ The realm has been forged! ⚔️${NC}"
  printf '%b\n' "${GREEN}🏰 Adventurers may now enter your world${NC}"
  printf '%b\n\n' "${GREEN}🗡️ May your server bring epic adventures!${NC}"
}

show_remote_plan(){
  local plan_host="${REMOTE_HOST:-<host>}"
  local plan_user="${REMOTE_USER:-<user>}"
  local plan_dir="${REMOTE_PROJECT_DIR:-~/acore-compose}"

  printf '\n%b\n' "${BLUE}🧭 Remote Deployment Plan${NC}"
  printf '%b\n' "${YELLOW}├─ Validate build status locally${NC}"
  printf '%b\n' "${YELLOW}└─ Package & sync to ${plan_user}@${plan_host}:${plan_dir}${NC}"
}

maybe_select_deploy_target(){
  if [ "$REMOTE_MODE" -eq 1 ]; then
    return
  fi
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    return
  fi
  echo
  echo "Select deployment target:"
  echo "  1) Local host (current machine)"
  echo "  2) Remote host (package for SSH deployment)"
  local choice
  read -rp "Choice [1]: " choice
  case "${choice:-1}" in
    2)
      REMOTE_MODE=1
      REMOTE_ARGS_PROVIDED=0
      ;;
    *)
      ;;
  esac
}

collect_remote_details(){
  if [ "$REMOTE_MODE" -ne 1 ]; then
    return
  fi

  local interactive=0
  if [ -t 0 ] && [ "$ASSUME_YES" -ne 1 ]; then
    interactive=1
  fi

  if [ -z "$REMOTE_HOST" ] && [ "$interactive" -eq 1 ]; then
    while true; do
      read -rp "Remote host (hostname or IP): " REMOTE_HOST
      [ -n "$REMOTE_HOST" ] && break
      echo "  Please enter a hostname or IP."
    done
  fi

  if [ -z "$REMOTE_USER" ] && [ "$interactive" -eq 1 ]; then
    local default_user="$USER"
    read -rp "SSH username [${default_user}]: " REMOTE_USER
    REMOTE_USER="${REMOTE_USER:-$default_user}"
  fi
  if [ -z "$REMOTE_USER" ] && [ -n "$USER" ]; then
    REMOTE_USER="$USER"
  fi

  if [ -z "$REMOTE_PORT" ]; then
    REMOTE_PORT="22"
  fi
  if [ "$interactive" -eq 1 ]; then
    local port_input
    read -rp "SSH port [${REMOTE_PORT}]: " port_input
    REMOTE_PORT="${port_input:-$REMOTE_PORT}"
  fi

  if [ "$interactive" -eq 1 ]; then
    local identity_input
    local identity_prompt="SSH identity file (leave blank for default)"
    if [ -n "$REMOTE_IDENTITY" ]; then
      identity_prompt="${identity_prompt} [${REMOTE_IDENTITY}]"
    fi
    read -rp "${identity_prompt}: " identity_input
    [ -n "$identity_input" ] && REMOTE_IDENTITY="$identity_input"
  fi
  if [ -n "$REMOTE_IDENTITY" ]; then
    REMOTE_IDENTITY="${REMOTE_IDENTITY/#\~/$HOME}"
  fi

  if [ -z "$REMOTE_PROJECT_DIR" ]; then
    REMOTE_PROJECT_DIR="~/acore-compose"
  fi
  if [ "$interactive" -eq 1 ]; then
    local dir_input
    read -rp "Remote project directory [${REMOTE_PROJECT_DIR}]: " dir_input
    REMOTE_PROJECT_DIR="${dir_input:-$REMOTE_PROJECT_DIR}"
  fi

  if [ "$interactive" -eq 1 ] && [ "$REMOTE_ARGS_PROVIDED" -eq 0 ]; then
    local sync_answer
    read -rp "Sync storage directory to remote host? [Y/n]: " sync_answer
    sync_answer="${sync_answer:-Y}"
    case "${sync_answer,,}" in
      n|no) REMOTE_SKIP_STORAGE=1 ;;
      *) REMOTE_SKIP_STORAGE=0 ;;
    esac
  fi
}

validate_remote_configuration(){
  if [ "$REMOTE_MODE" -ne 1 ]; then
    return
  fi
  if [ -z "$REMOTE_HOST" ]; then
    err "Remote deployment requires a hostname or IP."
    exit 1
  fi
  if [ -z "$REMOTE_USER" ]; then
    err "Remote deployment requires an SSH username."
    exit 1
  fi
  REMOTE_PORT="${REMOTE_PORT:-22}"
  if ! [[ "$REMOTE_PORT" =~ ^[0-9]+$ ]]; then
    err "Invalid SSH port: $REMOTE_PORT"
    exit 1
  fi
  if [ -n "$REMOTE_IDENTITY" ]; then
    REMOTE_IDENTITY="${REMOTE_IDENTITY/#\~/$HOME}"
    if [ ! -f "$REMOTE_IDENTITY" ]; then
      err "Remote identity file not found: $REMOTE_IDENTITY"
      exit 1
    fi
  fi
  if [ -z "$REMOTE_PROJECT_DIR" ]; then
    REMOTE_PROJECT_DIR="~/acore-compose"
  fi
  if [ ! -f "$ROOT_DIR/scripts/migrate-stack.sh" ]; then
    err "Migration script not found: $ROOT_DIR/scripts/migrate-stack.sh"
    exit 1
  fi
}

usage(){
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --profile {standard|playerbots|modules}  Force target profile (default: auto-detect)
  --no-watch                               Do not tail worldserver logs after staging
  --keep-running                           Do not pre-stop runtime stack
  --yes, -y                                Auto-confirm deployment prompts
  --watch-logs                             Tail worldserver logs even if --no-watch was set earlier
  --log-tail LINES                         Override WORLD_LOG_TAIL (number of log lines to show)
  --once                                   Run status checks once (alias for --no-watch)
  --remote                                 Package deployment artifacts for a remote host
  --remote-host HOST                       Remote hostname or IP for migration
  --remote-user USER                       SSH username for remote migration
  --remote-port PORT                       SSH port for remote migration (default: 22)
  --remote-identity PATH                   SSH private key for remote migration
  --remote-project-dir DIR                 Remote project directory (default: ~/acore-compose)
  --remote-skip-storage                    Skip syncing the storage directory during migration
  -h, --help                               Show this help

This command automates deployment: sync modules, stage the correct compose profile,
and optionally watch worldserver logs.

Image Requirements:
This script assumes Docker images are already built. If you have custom modules:
• Run './build.sh' first to build custom images
• Standard AzerothCore images will be pulled automatically
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) TARGET_PROFILE="$2"; shift 2;;
    --no-watch) WATCH_LOGS=0; shift;;
    --keep-running) KEEP_RUNNING=1; shift;;
    --yes|-y) ASSUME_YES=1; shift;;
    --remote) REMOTE_MODE=1; REMOTE_ARGS_PROVIDED=1; shift;;
    --remote-host) REMOTE_HOST="$2"; REMOTE_MODE=1; REMOTE_ARGS_PROVIDED=1; shift 2;;
    --remote-user) REMOTE_USER="$2"; REMOTE_MODE=1; REMOTE_ARGS_PROVIDED=1; shift 2;;
    --remote-port) REMOTE_PORT="$2"; REMOTE_MODE=1; REMOTE_ARGS_PROVIDED=1; shift 2;;
    --remote-identity) REMOTE_IDENTITY="$2"; REMOTE_MODE=1; REMOTE_ARGS_PROVIDED=1; shift 2;;
    --remote-project-dir) REMOTE_PROJECT_DIR="$2"; REMOTE_MODE=1; REMOTE_ARGS_PROVIDED=1; shift 2;;
    --remote-skip-storage) REMOTE_SKIP_STORAGE=1; REMOTE_MODE=1; REMOTE_ARGS_PROVIDED=1; shift;;
    -h|--help) usage; exit 0;;
    *) err "Unknown option: $1"; usage; exit 1;;
  esac
done

require_cmd(){
  command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}

require_cmd docker

if [ "$REMOTE_MODE" -eq 1 ]; then
  if [ -z "$REMOTE_HOST" ]; then
    err "Remote deployment requires --remote-host to be specified"
    exit 1
  fi
  if [ -z "$REMOTE_USER" ]; then
    err "Remote deployment requires --remote-user to be specified"
    exit 1
  fi
  if [ -n "$REMOTE_IDENTITY" ]; then
    REMOTE_IDENTITY="${REMOTE_IDENTITY/#\~/$HOME}"
    if [ ! -f "$REMOTE_IDENTITY" ]; then
      err "Remote identity file not found: $REMOTE_IDENTITY"
      exit 1
    fi
  fi
  if [ ! -f "$ROOT_DIR/scripts/migrate-stack.sh" ]; then
    err "Migration script not found: $ROOT_DIR/scripts/migrate-stack.sh"
    exit 1
  fi
fi

read_env(){
  local key="$1" default="${2:-}"
  local value=""
  if [ -f "$ENV_PATH" ]; then
    value="$(grep -E "^${key}=" "$ENV_PATH" | tail -n1 | cut -d'=' -f2- | tr -d '\r')"
  fi
  if [ -z "$value" ]; then
    value="$default"
  fi
  echo "$value"
}

resolve_project_name(){
  local raw_name="$(read_env COMPOSE_PROJECT_NAME "acore-compose")"
  local sanitized
  sanitized="$(echo "$raw_name" | tr '[:upper:]' '[:lower:]')"
  sanitized="${sanitized// /-}"
  sanitized="$(echo "$sanitized" | tr -cd 'a-z0-9_-')"
  if [[ -z "$sanitized" ]]; then
    sanitized="acore-compose"
  elif [[ ! "$sanitized" =~ ^[a-z0-9] ]]; then
    sanitized="ac${sanitized}"
  fi
  echo "$sanitized"
}

filter_empty_lines(){
  awk '
    /^[[:space:]]*$/ {
      empty_count++
      if (empty_count <= 1) print
    }
    /[^[:space:]]/ {
      empty_count = 0
      print
    }
  '
}

compose(){
  local project_name
  project_name="$(resolve_project_name)"
  # Add --quiet for less verbose output, filter excessive empty lines
  docker compose --project-name "$project_name" -f "$COMPOSE_FILE" "$@" | filter_empty_lines
}

# Build detection logic
detect_build_needed(){
  local reasons=()

  # Check sentinel file
  if modules_need_rebuild; then
    reasons+=("Module changes detected (sentinel file present)")
  fi

  # Check if any C++ modules are enabled but modules-latest images don't exist
  local any_cxx_modules=0
  local var
  for var in "${COMPILE_MODULE_VARS[@]}"; do
    if [ "$(read_env "$var" "0")" = "1" ]; then
      any_cxx_modules=1
      break
    fi
  done

  if [ "$any_cxx_modules" = "1" ]; then
    local authserver_modules_image
    local worldserver_modules_image
    authserver_modules_image="$(read_env AC_AUTHSERVER_IMAGE_MODULES "uprightbass360/azerothcore-wotlk-playerbots:authserver-modules-latest")"
    worldserver_modules_image="$(read_env AC_WORLDSERVER_IMAGE_MODULES "uprightbass360/azerothcore-wotlk-playerbots:worldserver-modules-latest")"

    if ! docker image inspect "$authserver_modules_image" >/dev/null 2>&1; then
      reasons+=("C++ modules enabled but authserver modules image $authserver_modules_image is missing")
    fi
    if ! docker image inspect "$worldserver_modules_image" >/dev/null 2>&1; then
      reasons+=("C++ modules enabled but worldserver modules image $worldserver_modules_image is missing")
    fi
  fi

  if [ ${#reasons[@]} -gt 0 ]; then
    printf '%s\n' "${reasons[@]}"
  fi
}

stop_runtime_stack(){
  info "Stopping runtime stack to avoid container name conflicts"
  compose \
    --profile services-standard \
    --profile services-playerbots \
    --profile services-modules \
    --profile db \
    --profile client-data \
    --profile client-data-bots \
    --profile modules \
    down 2>/dev/null || true
}

# Deployment sentinel management
mark_deployment_complete(){
  local storage_path
  storage_path="$(read_env STORAGE_PATH_LOCAL "./local-storage")"
  if [[ "$storage_path" != /* ]]; then
    # Remove leading ./ if present
    storage_path="${storage_path#./}"
    storage_path="$ROOT_DIR/$storage_path"
  fi
  local sentinel="$storage_path/modules/.last_deployed"
  if ! mkdir -p "$(dirname "$sentinel")" 2>/dev/null; then
    warn "Cannot create local-storage directory. Deployment tracking may not work properly."
    return 0
  fi
  date > "$sentinel"
}

modules_need_rebuild(){
  local storage_path
  storage_path="$(read_env STORAGE_PATH_LOCAL "./local-storage")"
  if [[ "$storage_path" != /* ]]; then
    # Remove leading ./ if present
    storage_path="${storage_path#./}"
    storage_path="$ROOT_DIR/$storage_path"
  fi
  local sentinel="$storage_path/modules/.requires_rebuild"
  [[ -f "$sentinel" ]]
}

# Build prompting logic
prompt_build_if_needed(){
  local build_reasons_output
  build_reasons_output=$(detect_build_needed)

  if [ -z "$build_reasons_output" ]; then
    return 0  # No build needed
  fi

  local build_reasons
  readarray -t build_reasons <<< "$build_reasons_output"

  # Check if auto-rebuild is enabled
  local auto_rebuild
  auto_rebuild="$(read_env AUTO_REBUILD_ON_DEPLOY "0")"
  if [ "$auto_rebuild" = "1" ]; then
    warn "Auto-rebuild enabled, running build process..."
    if (cd "$ROOT_DIR" && ./build.sh --yes); then
      ok "Build completed successfully"
      return 0
    else
      err "Build failed"
      return 1
    fi
  fi

  # Interactive prompt
  echo
  warn "Build appears to be required:"
  local reason
  for reason in "${build_reasons[@]}"; do
    warn "  • $reason"
  done
  echo

  if [ -t 0 ]; then
    local reply
    read -r -p "Run build now? [y/N]: " reply
    reply="${reply:-n}"
    case "$reply" in
      [Yy]*)
        if (cd "$ROOT_DIR" && ./build.sh --yes); then
          ok "Build completed successfully"
          return 0
        else
          err "Build failed"
          return 1
        fi
        ;;
      *)
        err "Build required but declined. Run './build.sh' manually before deploying or re-run this script."
        return 1
        ;;
    esac
  else
    err "Build required but running non-interactively. Run './build.sh'  manually before deploying or re-run this script."
    return 1
  fi
}


determine_profile(){
  if [ -n "$TARGET_PROFILE" ]; then
    echo "$TARGET_PROFILE"
    return
  fi

  local module_playerbots
  local playerbot_enabled
  module_playerbots="$(read_env MODULE_PLAYERBOTS "0")"
  playerbot_enabled="$(read_env PLAYERBOT_ENABLED "0")"
  if [ "$module_playerbots" = "1" ] || [ "$playerbot_enabled" = "1" ]; then
    echo "playerbots"
    return
  fi

  local var
  for var in "${COMPILE_MODULE_VARS[@]}"; do
    if [ "$(read_env "$var" "0")" = "1" ]; then
      echo "modules"
      return
    fi
  done

  echo "standard"
}

run_remote_migration(){
  local args=(--host "$REMOTE_HOST" --user "$REMOTE_USER")

  if [ -n "$REMOTE_PORT" ] && [ "$REMOTE_PORT" != "22" ]; then
    args+=(--port "$REMOTE_PORT")
  fi

  if [ -n "$REMOTE_IDENTITY" ]; then
    args+=(--identity "$REMOTE_IDENTITY")
  fi

  if [ -n "$REMOTE_PROJECT_DIR" ]; then
    args+=(--project-dir "$REMOTE_PROJECT_DIR")
  fi

  if [ "$REMOTE_SKIP_STORAGE" -eq 1 ]; then
    args+=(--skip-storage)
  fi

  if [ "$ASSUME_YES" -eq 1 ]; then
    args+=(--yes)
  fi

  (cd "$ROOT_DIR" && ./scripts/migrate-stack.sh "${args[@]}")
}


stage_runtime(){
  local args=(--yes)
  if [ -n "$TARGET_PROFILE" ]; then
    args+=("$TARGET_PROFILE")
  fi
  info "Staging runtime environment via stage-modules.sh ${args[*]}"
  (cd "$ROOT_DIR" && ./scripts/stage-modules.sh "${args[@]}")
}

tail_world_logs(){
  info "Tailing worldserver logs (Ctrl+C to stop)"
  local args=(--follow)
  if [ -n "$WORLD_LOG_SINCE" ]; then
    args+=(--since "$WORLD_LOG_SINCE")
  fi
  local tail_opt="${WORLD_LOG_TAIL:-0}"
  args+=(--tail "$tail_opt")
  if ! docker logs "${args[@]}" ac-worldserver; then
    warn "Worldserver logs unavailable; container may not be running."
  fi
}

wait_for_worldserver_ready(){
  local timeout="${WORLD_READY_TIMEOUT:-180}" start
  start="$(date +%s)"
  info "Waiting for worldserver to become ready (timeout: ${timeout}s)"
  info "First deployment may take 10-15 minutes while client-data is extracted"
  while true; do
    if ! docker ps --format '{{.Names}}' | grep -qx "ac-worldserver"; then
      info "Worldserver container is not running yet; retrying..."
    else
      local health
      health="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' ac-worldserver 2>/dev/null || echo none)"
      case "$health" in
        healthy)
          WORLD_LOG_SINCE="$(docker inspect --format='{{.State.StartedAt}}' ac-worldserver 2>/dev/null)"
          ok "Worldserver reported healthy"
          return 0
          ;;
        none)
          if docker inspect --format='{{.State.Status}}' ac-worldserver 2>/dev/null | grep -q '^running$'; then
            WORLD_LOG_SINCE="$(docker inspect --format='{{.State.StartedAt}}' ac-worldserver 2>/dev/null)"
            ok "Worldserver running (no healthcheck configured)"
            return 0
          fi
          ;;
        unhealthy)
          info "Worldserver starting up - waiting for client-data to complete..."
          info "This may take several minutes on first deployment while data files are extracted"
          ;;
      esac
    fi
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      info "Worldserver is still starting up after ${timeout}s. This is normal for first deployments."
      info "Client-data extraction can take 10-15 minutes. Check progress with './status.sh' or container logs."
      return 1
    fi
    sleep 3
  done
}

main(){
  if [ "$ASSUME_YES" -ne 1 ]; then
    if [ -t 0 ]; then
      read -r -p "Proceed with AzerothCore deployment? [y/N]: " reply
      reply="${reply:-n}"
    else
      warn "No --yes flag provided and standard input is not interactive; aborting deployment."
      exit 1
    fi
    case "$reply" in
      [Yy]*) info "Deployment confirmed."; ;;
      *) err "Deployment cancelled."; exit 1 ;;
    esac
  else
    info "Auto-confirming deployment (--yes supplied)."
  fi

  show_deployment_header

  maybe_select_deploy_target
  collect_remote_details
  validate_remote_configuration

  if [ "$REMOTE_MODE" -eq 1 ]; then
    local remote_steps=2
    show_remote_plan
    show_step 1 "$remote_steps" "Checking build requirements"
    if ! prompt_build_if_needed; then
      err "Build required but not completed. Remote deployment cancelled."
      exit 1
    fi

    show_step 2 "$remote_steps" "Migrating deployment to $REMOTE_HOST"
    if run_remote_migration; then
      ok "Remote deployment package prepared for $REMOTE_USER@$REMOTE_HOST."
      local remote_dir="${REMOTE_PROJECT_DIR:-~/acore-compose}"
      info "Run the following on the remote host to complete deployment:"
      printf '  %bcd %s && ./deploy.sh --yes --no-watch%b\n' "$YELLOW" "$remote_dir" "$NC"
      exit 0
    else
      err "Remote migration failed."
      exit 1
    fi
  fi

  show_step 1 4 "Checking build requirements"
  if ! prompt_build_if_needed; then
    err "Build required but not completed. Deployment cancelled."
    exit 1
  fi

  if [ "$KEEP_RUNNING" -ne 1 ]; then
    show_step 2 4 "Stopping runtime stack"
    stop_runtime_stack
  fi

  show_step 3 4 "Bringing your realm online"
  info "Pulling images and waiting for containers to become healthy; this may take a few minutes on first deploy."
  stage_runtime

  show_step 4 4 "Finalizing deployment"
  mark_deployment_complete

  show_realm_ready

  if [ "$WATCH_LOGS" -eq 1 ]; then
    if wait_for_worldserver_ready; then
      info "Watching your realm come to life (Ctrl+C to stop watching)"
      tail_world_logs
    else
      info "Worldserver still initializing. Client-data extraction may still be in progress."
      info "Use './status.sh' to monitor progress or 'docker logs ac-worldserver' to view startup logs."
    fi
  else
    ok "Realm deployment completed. Use './status.sh' to monitor your realm."
  fi
}

main
