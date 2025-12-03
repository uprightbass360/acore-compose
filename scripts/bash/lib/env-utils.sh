#!/bin/bash
#
# Environment and file utility library for AzerothCore RealmMaster scripts
# This library provides enhanced environment variable handling, file operations,
# and path management functions.
#
# Usage: source /path/to/scripts/bash/lib/env-utils.sh
#

# Prevent multiple sourcing
if [ -n "${_ENV_UTILS_LIB_LOADED:-}" ]; then
  return 0
fi
_ENV_UTILS_LIB_LOADED=1

# Source common library for logging functions
ENV_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$ENV_UTILS_DIR/common.sh" ]; then
  source "$ENV_UTILS_DIR/common.sh"
elif command -v info >/dev/null 2>&1; then
  # Common functions already available
  :
else
  # Fallback logging functions
  info() { printf '\033[0;34mℹ️  %s\033[0m\n' "$*"; }
  warn() { printf '\033[1;33m⚠️  %s\033[0m\n' "$*" >&2; }
  err() { printf '\033[0;31m❌ %s\033[0m\n' "$*" >&2; }
  fatal() { err "$*"; exit 1; }
fi

# =============================================================================
# ENVIRONMENT VARIABLE MANAGEMENT
# =============================================================================

# Enhanced read_env function with advanced features
# Supports multiple .env files, environment variable precedence, and validation
#
# Usage:
#   value=$(env_read_with_fallback "MYSQL_PASSWORD" "default_password")
#   value=$(env_read_with_fallback "PORT" "" ".env.local" "validate_port")
#
env_read_with_fallback() {
  local key="$1"
  local default="${2:-}"
  local env_file="${3:-${ENV_PATH:-${DEFAULT_ENV_PATH:-.env}}}"
  local validator_func="${4:-}"
  local value=""

  # 1. Check if variable is already set in environment (highest precedence)
  if [ -n "${!key:-}" ]; then
    value="${!key}"
  else
    # 2. Read from .env file if it exists
    if [ -f "$env_file" ]; then
      # Extract value using grep and cut, handling various formats
      value="$(grep -E "^${key}=" "$env_file" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '\r')"

      # Remove inline comments (everything after # that's not inside quotes)
      value="$(echo "$value" | sed 's/[[:space:]]*#.*//' | sed 's/[[:space:]]*$//')"

      # Strip quotes if present
      if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        # Double quotes
        value="${value:1:-1}"
      elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        # Single quotes
        value="${value:1:-1}"
      fi
    fi

    # 3. Use default if still empty
    if [ -z "${value:-}" ]; then
      value="$default"
    fi
  fi

  # 4. Validate if validator function provided
  if [ -n "$validator_func" ] && command -v "$validator_func" >/dev/null 2>&1; then
    if ! "$validator_func" "$value"; then
      err "Validation failed for $key: $value"
      return 1
    fi
  fi

  printf '%s\n' "${value}"
}

# Read environment variable with type conversion
# Supports string, int, bool, and path types
#
# Usage:
#   port=$(env_read_typed "MYSQL_PORT" "int" "3306")
#   debug=$(env_read_typed "DEBUG" "bool" "false")
#   path=$(env_read_typed "DATA_PATH" "path" "/data")
#
env_read_typed() {
  local key="$1"
  local type="$2"
  local default="${3:-}"
  local value

  value=$(env_read_with_fallback "$key" "$default")

  case "$type" in
    int|integer)
      if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        err "Environment variable $key must be an integer: $value"
        return 1
      fi
      echo "$value"
      ;;
    bool|boolean)
      case "${value,,}" in
        true|yes|1|on|enabled) echo "true" ;;
        false|no|0|off|disabled) echo "false" ;;
        *) err "Environment variable $key must be boolean: $value"; return 1 ;;
      esac
      ;;
    path)
      # Expand relative paths to absolute
      if [ -n "$value" ]; then
        path_resolve_absolute "$value"
      fi
      ;;
    string|*)
      echo "$value"
      ;;
  esac
}

# Update or add environment variable in .env file with backup
# Creates backup and maintains file integrity
#
# Usage:
#   env_update_value "MYSQL_PASSWORD" "new_password"
#   env_update_value "DEBUG" "true" ".env.local"
#   env_update_value "PORT" "8080" ".env" "true"  # create backup
#
env_update_value() {
  local key="$1"
  local value="$2"
  local env_file="${3:-${ENV_PATH:-${DEFAULT_ENV_PATH:-.env}}}"
  local create_backup="${4:-false}"

  [ -n "$env_file" ] || return 0

  # Create backup if requested
  if [ "$create_backup" = "true" ] && [ -f "$env_file" ]; then
    file_create_backup "$env_file"
  fi

  # Create file if it doesn't exist
  if [ ! -f "$env_file" ]; then
    file_ensure_writable_dir "$(dirname "$env_file")"
    printf '%s=%s\n' "$key" "$value" >> "$env_file"
    return 0
  fi

  # Update existing or append new
  if grep -q "^${key}=" "$env_file"; then
    # Use platform-appropriate sed in-place editing
    local sed_opts=""
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed_opts="-i ''"
    else
      sed_opts="-i"
    fi

    # Use a temporary file for safer editing
    local temp_file="${env_file}.tmp.$$"
    sed "s|^${key}=.*|${key}=${value}|" "$env_file" > "$temp_file" && mv "$temp_file" "$env_file"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$env_file"
  fi

  info "Updated $key in $env_file"
}

# Load multiple environment files with precedence
# Later files override earlier ones
#
# Usage:
#   env_load_multiple ".env" ".env.local" ".env.production"
#
env_load_multiple() {
  local files=("$@")
  local loaded_count=0

  for env_file in "${files[@]}"; do
    if [ -f "$env_file" ]; then
      info "Loading environment from: $env_file"
      set -a
      # shellcheck disable=SC1090
      source "$env_file"
      set +a
      loaded_count=$((loaded_count + 1))
    fi
  done

  if [ $loaded_count -eq 0 ]; then
    warn "No environment files found: ${files[*]}"
    return 1
  fi

  info "Loaded $loaded_count environment file(s)"
  return 0
}

# =============================================================================
# PATH AND FILE UTILITIES
# =============================================================================

# Resolve path to absolute form with proper error handling
# Handles both existing and non-existing paths
#
# Usage:
#   abs_path=$(path_resolve_absolute "./relative/path")
#   abs_path=$(path_resolve_absolute "/already/absolute")
#
path_resolve_absolute() {
  local path="$1"
  local base_dir="${2:-$PWD}"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$base_dir" "$path" <<'PY'
import os, sys
base, path = sys.argv[1:3]
if not path:
    print(os.path.abspath(base))
elif os.path.isabs(path):
    print(os.path.normpath(path))
else:
    print(os.path.normpath(os.path.join(base, path)))
PY
  elif command -v realpath >/dev/null 2>&1; then
    if [ "${path:0:1}" = "/" ]; then
      echo "$path"
    else
      realpath -m "$base_dir/$path"
    fi
  else
    # Fallback manual resolution
    if [ "${path:0:1}" = "/" ]; then
      echo "$path"
    else
      echo "$base_dir/$path"
    fi
  fi
}

# Ensure directory exists and is writable with proper permissions
# Creates parent directories if needed
#
# Usage:
#   file_ensure_writable_dir "/path/to/directory"
#   file_ensure_writable_dir "/path/to/directory" "0755"
#
file_ensure_writable_dir() {
  local dir="$1"
  local permissions="${2:-0755}"

  if [ ! -d "$dir" ]; then
    if mkdir -p "$dir" 2>/dev/null; then
      info "Created directory: $dir"
      chmod "$permissions" "$dir" 2>/dev/null || warn "Could not set permissions on $dir"
    else
      err "Failed to create directory: $dir"
      return 1
    fi
  fi

  if [ ! -w "$dir" ]; then
    if chmod u+w "$dir" 2>/dev/null; then
      info "Made directory writable: $dir"
    else
      err "Directory not writable and cannot fix permissions: $dir"
      return 1
    fi
  fi

  return 0
}

# Create timestamped backup of file
# Supports custom backup directory and compression
#
# Usage:
#   file_create_backup "/path/to/important.conf"
#   file_create_backup "/path/to/file" "/backup/dir" "gzip"
#
file_create_backup() {
  local file="$1"
  local backup_dir="${2:-$(dirname "$file")}"
  local compression="${3:-none}"

  if [ ! -f "$file" ]; then
    warn "File does not exist, skipping backup: $file"
    return 0
  fi

  file_ensure_writable_dir "$backup_dir"

  local filename basename backup_file
  filename=$(basename "$file")
  basename="${filename%.*}"
  local extension="${filename##*.}"

  # Create backup filename with timestamp
  if [ "$filename" = "$basename" ]; then
    # No extension
    backup_file="${backup_dir}/${filename}.backup.$(date +%Y%m%d_%H%M%S)"
  else
    # Has extension
    backup_file="${backup_dir}/${basename}.backup.$(date +%Y%m%d_%H%M%S).${extension}"
  fi

  case "$compression" in
    gzip|gz)
      if gzip -c "$file" > "${backup_file}.gz"; then
        info "Created compressed backup: ${backup_file}.gz"
      else
        err "Failed to create compressed backup: ${backup_file}.gz"
        return 1
      fi
      ;;
    none|*)
      if cp "$file" "$backup_file"; then
        info "Created backup: $backup_file"
      else
        err "Failed to create backup: $backup_file"
        return 1
      fi
      ;;
  esac

  return 0
}

# Set file permissions safely with validation
# Handles both numeric and symbolic modes
#
# Usage:
#   file_set_permissions "/path/to/file" "0644"
#   file_set_permissions "/path/to/script" "u+x"
#
file_set_permissions() {
  local file="$1"
  local permissions="$2"
  local recursive="${3:-false}"

  if [ ! -e "$file" ]; then
    err "File or directory does not exist: $file"
    return 1
  fi

  local chmod_opts=""
  if [ "$recursive" = "true" ] && [ -d "$file" ]; then
    chmod_opts="-R"
  fi

  if chmod $chmod_opts "$permissions" "$file" 2>/dev/null; then
    info "Set permissions $permissions on $file"
    return 0
  else
    err "Failed to set permissions $permissions on $file"
    return 1
  fi
}

# =============================================================================
# CONFIGURATION FILE UTILITIES
# =============================================================================

# Read value from template file with variable expansion support
# Enhanced version supporting more template formats
#
# Usage:
#   value=$(config_read_template_value "MYSQL_PASSWORD" ".env.template")
#   value=$(config_read_template_value "PORT" "config.template.yml" "yaml")
#
config_read_template_value() {
  local key="$1"
  local template_file="${2:-${TEMPLATE_FILE:-${TEMPLATE_PATH:-.env.template}}}"
  local format="${3:-env}"

  if [ ! -f "$template_file" ]; then
    err "Template file not found: $template_file"
    return 1
  fi

  case "$format" in
    env)
      local raw_line value
      raw_line=$(grep "^${key}=" "$template_file" 2>/dev/null | head -1)

      if [ -z "$raw_line" ]; then
        err "Key '$key' not found in template: $template_file"
        return 1
      fi

      value="${raw_line#*=}"
      value=$(echo "$value" | sed 's/^"\(.*\)"$/\1/')

      # Handle ${VAR:-default} syntax by extracting the default value
      if [[ "$value" =~ ^\$\{[^}]*:-([^}]*)\}$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi

      echo "$value"
      ;;
    yaml|yml)
      if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import yaml, sys
try:
    with open('$template_file', 'r') as f:
        data = yaml.safe_load(f)
    # Simple key lookup - can be enhanced for nested keys
    print(data.get('$key', ''))
except:
    sys.exit(1)
" 2>/dev/null
      else
        err "python3 required for YAML template parsing"
        return 1
      fi
      ;;
    *)
      err "Unsupported template format: $format"
      return 1
      ;;
  esac
}

# Validate configuration against schema
# Supports basic validation rules
#
# Usage:
#   config_validate_env ".env" "required:MYSQL_PASSWORD,PORT;optional:DEBUG"
#
config_validate_env() {
  local env_file="$1"
  local rules="${2:-}"

  if [ ! -f "$env_file" ]; then
    err "Environment file not found: $env_file"
    return 1
  fi

  if [ -z "$rules" ]; then
    info "No validation rules specified"
    return 0
  fi

  local validation_failed=false

  # Parse validation rules
  IFS=';' read -ra rule_sets <<< "$rules"
  for rule_set in "${rule_sets[@]}"; do
    IFS=':' read -ra rule_parts <<< "$rule_set"
    local rule_type="${rule_parts[0]}"
    local variables="${rule_parts[1]}"

    case "$rule_type" in
      required)
        IFS=',' read -ra req_vars <<< "$variables"
        for var in "${req_vars[@]}"; do
          if ! grep -q "^${var}=" "$env_file" || [ -z "$(env_read_with_fallback "$var" "" "$env_file")" ]; then
            err "Required environment variable missing or empty: $var"
            validation_failed=true
          fi
        done
        ;;
      optional)
        # Optional variables - just log if missing
        IFS=',' read -ra opt_vars <<< "$variables"
        for var in "${opt_vars[@]}"; do
          if ! grep -q "^${var}=" "$env_file"; then
            info "Optional environment variable not set: $var"
          fi
        done
        ;;
    esac
  done

  if [ "$validation_failed" = "true" ]; then
    err "Environment validation failed"
    return 1
  fi

  info "Environment validation passed"
  return 0
}

# =============================================================================
# SYSTEM UTILITIES
# =============================================================================

# Detect operating system and distribution
# Returns standardized OS identifier
#
# Usage:
#   os=$(system_detect_os)
#   if [ "$os" = "ubuntu" ]; then
#     echo "Running on Ubuntu"
#   fi
#
system_detect_os() {
  local os="unknown"

  if [ -f /etc/os-release ]; then
    # Source os-release for distribution info
    local id
    id=$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    case "$id" in
      ubuntu|debian|centos|rhel|fedora|alpine|arch)
        os="$id"
        ;;
      *)
        os="linux"
        ;;
    esac
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    os="macos"
  elif [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" ]]; then
    os="windows"
  fi

  echo "$os"
}

# Check system requirements
# Validates required commands and versions
#
# Usage:
#   system_check_requirements "docker:20.0,python3:3.6"
#
system_check_requirements() {
  local requirements="${1:-}"

  if [ -z "$requirements" ]; then
    return 0
  fi

  local check_failed=false

  IFS=',' read -ra req_list <<< "$requirements"
  for requirement in "${req_list[@]}"; do
    IFS=':' read -ra req_parts <<< "$requirement"
    local command="${req_parts[0]}"
    local min_version="${req_parts[1]:-}"

    if ! command -v "$command" >/dev/null 2>&1; then
      err "Required command not found: $command"
      check_failed=true
      continue
    fi

    if [ -n "$min_version" ]; then
      # Basic version checking - can be enhanced
      info "Found $command (version checking not fully implemented)"
    else
      info "Found required command: $command"
    fi
  done

  if [ "$check_failed" = "true" ]; then
    err "System requirements check failed"
    return 1
  fi

  info "System requirements check passed"
  return 0
}

# =============================================================================
# INITIALIZATION AND VALIDATION
# =============================================================================

# Validate environment utility configuration
# Checks that utilities are working correctly
#
# Usage:
#   env_utils_validate
#
env_utils_validate() {
  info "Validating environment utilities..."

  # Test path resolution
  local test_path
  test_path=$(path_resolve_absolute "." 2>/dev/null)
  if [ -z "$test_path" ]; then
    err "Path resolution utility not working"
    return 1
  fi

  # Test directory operations
  if ! file_ensure_writable_dir "/tmp/env-utils-test.$$"; then
    err "Directory utility not working"
    return 1
  fi
  rmdir "/tmp/env-utils-test.$$" 2>/dev/null || true

  info "Environment utilities validation successful"
  return 0
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Library loaded successfully
# Scripts can check for $_ENV_UTILS_LIB_LOADED to verify library is loaded