#!/bin/bash
#
# MySQL utility library for AzerothCore RealmMaster scripts
# This library provides standardized MySQL operations, connection management,
# and database interaction functions.
#
# Usage: source /path/to/scripts/bash/lib/mysql-utils.sh
#

# Prevent multiple sourcing
if [ -n "${_MYSQL_UTILS_LIB_LOADED:-}" ]; then
  return 0
fi
_MYSQL_UTILS_LIB_LOADED=1

# Source common library for logging functions
MYSQL_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$MYSQL_UTILS_DIR/common.sh" ]; then
  source "$MYSQL_UTILS_DIR/common.sh"
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
# MYSQL CONNECTION CONFIGURATION
# =============================================================================

# Default MySQL configuration - can be overridden by environment
MYSQL_HOST="${MYSQL_HOST:-${CONTAINER_MYSQL:-ac-mysql}}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-${MYSQL_PW:-azerothcore}}"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-ac-mysql}"

# =============================================================================
# MYSQL CONNECTION FUNCTIONS
# =============================================================================

# Test MySQL connection with current configuration
# Returns 0 if connection successful, 1 if failed
#
# Usage:
#   if mysql_test_connection; then
#     echo "MySQL is available"
#   fi
#
mysql_test_connection() {
  local host="${1:-$MYSQL_HOST}"
  local port="${2:-$MYSQL_PORT}"
  local user="${3:-$MYSQL_USER}"
  local password="${4:-$MYSQL_ROOT_PASSWORD}"

  MYSQL_PWD="$password" mysql -h "$host" -P "$port" -u "$user" -e "SELECT 1" >/dev/null 2>&1
}

# Wait for MySQL to be ready with timeout
# Returns 0 if MySQL becomes available within timeout, 1 if timeout reached
#
# Usage:
#   mysql_wait_for_connection 60  # Wait up to 60 seconds
#   mysql_wait_for_connection     # Use default 30 second timeout
#
mysql_wait_for_connection() {
  local timeout="${1:-30}"
  local retry_interval="${2:-2}"
  local elapsed=0

  info "Waiting for MySQL connection (${MYSQL_HOST}:${MYSQL_PORT}) with ${timeout}s timeout..."

  while [ $elapsed -lt $timeout ]; do
    if mysql_test_connection; then
      info "MySQL connection established"
      return 0
    fi
    sleep "$retry_interval"
    elapsed=$((elapsed + retry_interval))
  done

  err "MySQL connection failed after ${timeout}s timeout"
  return 1
}

# Execute MySQL command with retry logic
# Handles both direct queries and piped input
#
# Usage:
#   mysql_exec_with_retry "database_name" "SELECT COUNT(*) FROM table;"
#   echo "SELECT 1;" | mysql_exec_with_retry "database_name"
#   mysql_exec_with_retry "database_name" < script.sql
#
mysql_exec_with_retry() {
  local database="$1"
  local query="${2:-}"
  local max_attempts="${3:-3}"
  local retry_delay="${4:-2}"

  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    if [ -n "$query" ]; then
      # Direct query execution
      if MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" "$database" -e "$query"; then
        return 0
      fi
    else
      # Input from pipe/stdin
      if MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" "$database"; then
        return 0
      fi
    fi

    if [ $attempt -lt $max_attempts ]; then
      warn "MySQL query failed (attempt $attempt/$max_attempts), retrying in ${retry_delay}s..."
      sleep "$retry_delay"
    fi

    attempt=$((attempt + 1))
  done

  err "MySQL query failed after $max_attempts attempts"
  return 1
}

# Execute MySQL query and return result (no table headers)
# Optimized for single values and parsing
#
# Usage:
#   count=$(mysql_query "acore_characters" "SELECT COUNT(*) FROM characters")
#   tables=$(mysql_query "information_schema" "SHOW TABLES")
#
mysql_query() {
  local database="$1"
  local query="$2"
  local host="${3:-$MYSQL_HOST}"
  local port="${4:-$MYSQL_PORT}"
  local user="${5:-$MYSQL_USER}"
  local password="${6:-$MYSQL_ROOT_PASSWORD}"

  MYSQL_PWD="$password" mysql -h "$host" -P "$port" -u "$user" -N -B "$database" -e "$query" 2>/dev/null
}

# =============================================================================
# DOCKER MYSQL FUNCTIONS
# =============================================================================

# Execute MySQL command inside Docker container
# Wrapper around docker exec with standardized MySQL connection
#
# Usage:
#   docker_mysql_exec "acore_auth" "SELECT COUNT(*) FROM account;"
#   echo "SELECT 1;" | docker_mysql_exec "acore_auth"
#
docker_mysql_exec() {
  local database="$1"
  local query="${2:-}"
  local container="${3:-$MYSQL_CONTAINER}"
  local password="${4:-$MYSQL_ROOT_PASSWORD}"

  if [ -n "$query" ]; then
    docker exec "$container" mysql -uroot -p"$password" "$database" -e "$query"
  else
    docker exec -i "$container" mysql -uroot -p"$password" "$database"
  fi
}

# Execute MySQL query in Docker container (no table headers)
# Optimized for single values and parsing
#
# Usage:
#   count=$(docker_mysql_query "acore_characters" "SELECT COUNT(*) FROM characters")
#
docker_mysql_query() {
  local database="$1"
  local query="$2"
  local container="${3:-$MYSQL_CONTAINER}"
  local password="${4:-$MYSQL_ROOT_PASSWORD}"

  docker exec "$container" mysql -uroot -p"$password" -N -B "$database" -e "$query" 2>/dev/null
}

# Check if MySQL container is healthy and accepting connections
#
# Usage:
#   if docker_mysql_is_ready; then
#     echo "MySQL container is ready"
#   fi
#
docker_mysql_is_ready() {
  local container="${1:-$MYSQL_CONTAINER}"
  local password="${2:-$MYSQL_ROOT_PASSWORD}"

  docker exec "$container" mysqladmin ping -uroot -p"$password" >/dev/null 2>&1
}

# =============================================================================
# DATABASE UTILITY FUNCTIONS
# =============================================================================

# Check if database exists
# Returns 0 if database exists, 1 if not found
#
# Usage:
#   if mysql_database_exists "acore_world"; then
#     echo "World database found"
#   fi
#
mysql_database_exists() {
  local database_name="$1"
  local result

  result=$(mysql_query "information_schema" "SELECT COUNT(*) FROM SCHEMATA WHERE SCHEMA_NAME='$database_name'" 2>/dev/null || echo "0")
  [ "$result" -gt 0 ] 2>/dev/null
}

# Get table count for database(s)
# Supports both single database and multiple database patterns
#
# Usage:
#   count=$(mysql_get_table_count "acore_world")
#   count=$(mysql_get_table_count "acore_auth,acore_characters")
#
mysql_get_table_count() {
  local databases="$1"
  local schema_list

  # Convert comma-separated list to SQL IN clause format
  schema_list=$(echo "$databases" | sed "s/,/','/g" | sed "s/^/'/" | sed "s/$/'/")

  mysql_query "information_schema" "SELECT COUNT(*) FROM tables WHERE table_schema IN ($schema_list)"
}

# Get database connection string for applications
# Returns connection string in format: host;port;user;password;database
#
# Usage:
#   conn_str=$(mysql_get_connection_string "acore_auth")
#
mysql_get_connection_string() {
  local database="$1"
  local host="${2:-$MYSQL_HOST}"
  local port="${3:-$MYSQL_PORT}"
  local user="${4:-$MYSQL_USER}"
  local password="${5:-$MYSQL_ROOT_PASSWORD}"

  printf '%s;%s;%s;%s;%s\n' "$host" "$port" "$user" "$password" "$database"
}

# =============================================================================
# BACKUP AND RESTORE UTILITIES
# =============================================================================

# Create database backup using mysqldump
# Supports both compressed and uncompressed output
#
# Usage:
#   mysql_backup_database "acore_characters" "/path/to/backup.sql"
#   mysql_backup_database "acore_world" "/path/to/backup.sql.gz" "gzip"
#
mysql_backup_database() {
  local database="$1"
  local output_file="$2"
  local compression="${3:-none}"
  local container="${4:-$MYSQL_CONTAINER}"
  local password="${5:-$MYSQL_ROOT_PASSWORD}"

  info "Creating backup of $database -> $output_file"

  case "$compression" in
    gzip|gz)
      docker exec "$container" mysqldump -uroot -p"$password" "$database" | gzip > "$output_file"
      ;;
    none|*)
      docker exec "$container" mysqldump -uroot -p"$password" "$database" > "$output_file"
      ;;
  esac
}

# Restore database from backup file
# Handles both compressed and uncompressed files automatically
#
# Usage:
#   mysql_restore_database "acore_characters" "/path/to/backup.sql"
#   mysql_restore_database "acore_world" "/path/to/backup.sql.gz"
#
mysql_restore_database() {
  local database="$1"
  local backup_file="$2"
  local container="${3:-$MYSQL_CONTAINER}"
  local password="${4:-$MYSQL_ROOT_PASSWORD}"

  if [ ! -f "$backup_file" ]; then
    err "Backup file not found: $backup_file"
    return 1
  fi

  info "Restoring $database from $backup_file"

  case "$backup_file" in
    *.gz)
      gzip -dc "$backup_file" | docker exec -i "$container" mysql -uroot -p"$password" "$database"
      ;;
    *.sql)
      docker exec -i "$container" mysql -uroot -p"$password" "$database" < "$backup_file"
      ;;
    *)
      warn "Unknown backup file format, treating as uncompressed SQL"
      docker exec -i "$container" mysql -uroot -p"$password" "$database" < "$backup_file"
      ;;
  esac
}

# =============================================================================
# VALIDATION AND DIAGNOSTICS
# =============================================================================

# Validate MySQL configuration and connectivity
# Comprehensive health check for MySQL setup
#
# Usage:
#   mysql_validate_configuration
#
mysql_validate_configuration() {
  info "Validating MySQL configuration..."

  # Check required environment variables
  if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
    err "MYSQL_ROOT_PASSWORD is not set"
    return 1
  fi

  # Test basic connectivity
  if ! mysql_test_connection; then
    err "Cannot connect to MySQL at ${MYSQL_HOST}:${MYSQL_PORT}"
    return 1
  fi

  # Check Docker container if using container setup
  if docker ps --format "table {{.Names}}" | grep -q "$MYSQL_CONTAINER"; then
    if ! docker_mysql_is_ready; then
      err "MySQL container $MYSQL_CONTAINER is not ready"
      return 1
    fi
    info "MySQL container $MYSQL_CONTAINER is healthy"
  fi

  info "MySQL configuration validation successful"
  return 0
}

# Print MySQL configuration summary
# Useful for debugging and verification
#
# Usage:
#   mysql_print_configuration
#
mysql_print_configuration() {
  info "MySQL Configuration Summary:"
  info "  Host: $MYSQL_HOST"
  info "  Port: $MYSQL_PORT"
  info "  User: $MYSQL_USER"
  info "  Container: $MYSQL_CONTAINER"
  info "  Password: $([ -n "$MYSQL_ROOT_PASSWORD" ] && echo "***SET***" || echo "***NOT SET***")"
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Library loaded successfully
# Scripts can check for $_MYSQL_UTILS_LIB_LOADED to verify library is loaded