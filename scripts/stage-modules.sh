#!/bin/bash

# ac-compose helper to automatically stage modules and trigger source builds when needed.

set -e

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

show_staging_header(){
  echo -e "\n${BLUE}    ⚔️  REALM STAGING SYSTEM  ⚔️${NC}"
  echo -e "${BLUE}    ══════════════════════════════${NC}"
  echo -e "${BLUE}         🎯 Configuring Your Realm 🎯${NC}\n"
}

show_staging_step(){
  local step="$1" message="$2"
  echo -e "${YELLOW}🔧 ${step}: ${message}...${NC}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

usage(){
  cat <<EOF
Usage: $(basename "$0") [options] [PROFILE]

Automatically detect and stage modules for AzerothCore.

Arguments:
  PROFILE              Target profile (standard, playerbots, or auto-detect)

Options:
  --force-rebuild      Force a source rebuild even if not needed
  --yes, -y            Skip interactive confirmation prompts
  -h, --help           Show this help

Examples:
  $(basename "$0")                    # Auto-detect profile based on enabled modules
  $(basename "$0") playerbots         # Force playerbots profile
  $(basename "$0") --force-rebuild    # Force rebuild and auto-detect
EOF
}

read_env(){
  local key="$1" default="$2" env_path="$ENV_FILE" value
  if [ -f "$env_path" ]; then
    value="$(grep -E "^${key}=" "$env_path" | tail -n1 | cut -d'=' -f2- | tr -d '\r')"
  fi
  if [ -z "$value" ]; then
    value="$default"
  fi
  echo "$value"
}

confirm(){
  local prompt="$1" default="$2" reply
  if [ "$ASSUME_YES" = "1" ]; then
    return 0
  fi
  while true; do
    if [ "$default" = "y" ]; then
      read -r -p "$prompt [Y/n]: " reply
      reply="${reply:-y}"
    else
      read -r -p "$prompt [y/N]: " reply
      reply="${reply:-n}"
    fi
    case "$reply" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
    esac
  done
}

# Parse arguments
ASSUME_YES=0
FORCE_REBUILD=0
TARGET_PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1; shift;;
    --force-rebuild) FORCE_REBUILD=1; shift;;
    -h|--help) usage; exit 0;;
    standard|playerbots) TARGET_PROFILE="$1"; shift;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "❌ Docker CLI not found in PATH."
  exit 1
fi

STORAGE_PATH="$(read_env STORAGE_PATH "./storage")"
if [[ "$STORAGE_PATH" != /* ]]; then
  STORAGE_PATH="$PROJECT_DIR/$STORAGE_PATH"
fi
MODULES_DIR="$STORAGE_PATH/modules"
SENTINEL_FILE="$MODULES_DIR/.requires_rebuild"

# Define module mappings (from rebuild-with-modules.sh)
declare -A MODULE_REPO_MAP=(
  [MODULE_AOE_LOOT]=mod-aoe-loot
  [MODULE_LEARN_SPELLS]=mod-learn-spells
  [MODULE_FIREWORKS]=mod-fireworks-on-level
  [MODULE_INDIVIDUAL_PROGRESSION]=mod-individual-progression
  [MODULE_AHBOT]=mod-ahbot
  [MODULE_AUTOBALANCE]=mod-autobalance
  [MODULE_TRANSMOG]=mod-transmog
  [MODULE_NPC_BUFFER]=mod-npc-buffer
  [MODULE_DYNAMIC_XP]=mod-dynamic-xp
  [MODULE_SOLO_LFG]=mod-solo-lfg
  [MODULE_1V1_ARENA]=mod-1v1-arena
  [MODULE_PHASED_DUELS]=mod-phased-duels
  [MODULE_BREAKING_NEWS]=mod-breaking-news-override
  [MODULE_BOSS_ANNOUNCER]=mod-boss-announcer
  [MODULE_ACCOUNT_ACHIEVEMENTS]=mod-account-achievements
  [MODULE_AUTO_REVIVE]=mod-auto-revive
  [MODULE_GAIN_HONOR_GUARD]=mod-gain-honor-guard
  [MODULE_TIME_IS_TIME]=mod-TimeIsTime
  [MODULE_POCKET_PORTAL]=mod-pocket-portal
  [MODULE_RANDOM_ENCHANTS]=mod-random-enchants
  [MODULE_SOLOCRAFT]=mod-solocraft
  [MODULE_PVP_TITLES]=mod-pvp-titles
  [MODULE_NPC_BEASTMASTER]=mod-npc-beastmaster
  [MODULE_NPC_ENCHANTER]=mod-npc-enchanter
  [MODULE_INSTANCE_RESET]=mod-instance-reset
  [MODULE_LEVEL_GRANT]=mod-quest-count-level
)

show_staging_header

# Check for enabled C++ modules that require compilation
compile_modules=()
for key in "${!MODULE_REPO_MAP[@]}"; do
  if [ "$(read_env "$key" "0")" = "1" ]; then
    compile_modules+=("${MODULE_REPO_MAP[$key]}")
  fi
done

# Check for playerbots mode
PLAYERBOT_ENABLED="$(read_env PLAYERBOT_ENABLED "0")"
MODULE_PLAYERBOTS="$(read_env MODULE_PLAYERBOTS "0")"

# Determine target profile if not specified
if [ -z "$TARGET_PROFILE" ]; then
  show_staging_step "Profile Detection" "Analyzing enabled modules"
if [ ${#compile_modules[@]} -gt 0 ]; then
    echo "🔧 Detected ${#compile_modules[@]} C++ modules requiring compilation:"
    for mod in "${compile_modules[@]}"; do
      echo "   • $mod"
    done
    TARGET_PROFILE="modules"
    echo "🧩 Using modules profile for custom source build"
  elif [ "$MODULE_PLAYERBOTS" = "1" ] || [ "$PLAYERBOT_ENABLED" = "1" ]; then
    TARGET_PROFILE="playerbots"
    echo "🤖 Playerbot profile enabled"
  else
    TARGET_PROFILE="standard"
    echo "✅ No special modules detected - using standard profile"
  fi
fi

echo "🎯 Target profile: services-$TARGET_PROFILE"

# Check if source rebuild is needed for modules profile
REBUILD_NEEDED=0
if [ "$TARGET_PROFILE" = "modules" ]; then
  # Check if source image exists
  if ! docker image inspect "acore/ac-wotlk-worldserver:modules-latest" >/dev/null 2>&1; then
    echo "📦 Custom worldserver image not found - rebuild needed"
    REBUILD_NEEDED=1
  elif [ -f "$SENTINEL_FILE" ]; then
    echo "🔄 Modules changed since last build - rebuild needed"
    REBUILD_NEEDED=1
  elif [ "$FORCE_REBUILD" = "1" ]; then
    echo "🔧 Force rebuild requested"
    REBUILD_NEEDED=1
  fi

  if [ "$REBUILD_NEEDED" = "1" ]; then
    show_staging_step "Source Rebuild" "Preparing custom build with modules"
    echo "🚀 Triggering source rebuild with modules..."
    if confirm "Proceed with source rebuild? (15-45 minutes)" n; then
      "$SCRIPT_DIR/rebuild-with-modules.sh" ${ASSUME_YES:+--yes}
    else
      echo "❌ Rebuild cancelled"
      exit 1
    fi
  else
    echo "✅ Custom worldserver image up to date"
  fi
fi

# Stage the services
show_staging_step "Service Orchestration" "Preparing realm services"
echo "🎬 Staging services with profile: services-$TARGET_PROFILE"

# Stop any currently running services
echo "🛑 Stopping current services..."
docker compose \
  --profile services-standard \
  --profile services-playerbots \
  --profile services-modules \
  --profile client-data \
  --profile client-data-bots \
  down 2>/dev/null || true

# Build list of profiles to start
PROFILE_ARGS=(--profile "services-$TARGET_PROFILE" --profile db --profile modules)
case "$TARGET_PROFILE" in
  standard) PROFILE_ARGS+=(--profile client-data) ;;
  playerbots) PROFILE_ARGS+=(--profile client-data-bots) ;;
  modules) PROFILE_ARGS+=(--profile client-data) ;;
esac

# Start the target profile
show_staging_step "Realm Activation" "Bringing services online"
echo "🟢 Starting services-$TARGET_PROFILE profile..."
docker compose "${PROFILE_ARGS[@]}" up -d

echo ""
echo -e "${GREEN}⚔️ Realm staging completed successfully! ⚔️${NC}"
echo -e "${GREEN}🏰 Profile: services-$TARGET_PROFILE${NC}"
echo -e "${GREEN}🗡️ Your realm is ready for adventure!${NC}"

# Show status
echo ""
echo "📊 Service Status:"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" | grep -E "(ac-worldserver|ac-authserver|NAME)" || true
