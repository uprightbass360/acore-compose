#!/bin/bash
# Refresh the module metadata after a database restore so runtime staging knows
# to re-copy SQL files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common library for standardized logging
if ! source "$SCRIPT_DIR/lib/common.sh" 2>/dev/null; then
  echo "❌ FATAL: Cannot load $SCRIPT_DIR/lib/common.sh" >&2
  exit 1
fi

# Specialized prefixed logging for this restoration context
restore_info() { info "🔧 [restore-stage] $*"; }
restore_warn() { warn "[restore-stage] $*"; }

# Maintain compatibility with existing function calls
info() { restore_info "$*"; }
warn() { restore_warn "$*"; }

MODULES_DIR="${MODULES_DIR:-/modules}"
MODULES_META_DIR="${MODULES_DIR}/.modules-meta"
RESTORE_FLAG="${MODULES_META_DIR}/.restore-prestaged"

if [ ! -d "$MODULES_DIR" ]; then
  warn "Modules directory not found at ${MODULES_DIR}; skipping restore-time staging prep."
  exit 0
fi

mkdir -p "$MODULES_META_DIR" 2>/dev/null || true
touch "$RESTORE_FLAG"
echo "restore_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$RESTORE_FLAG"

info "Flagged ${RESTORE_FLAG} to force staging on next ./scripts/bash/stage-modules.sh run."
