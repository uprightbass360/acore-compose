#!/bin/bash
# ac-compose
set -e
trap 'echo "    ❌ SQL helper error (line ${LINENO}): ${BASH_COMMAND}" >&2' ERR

CUSTOM_SQL_ROOT="/tmp/scripts/sql/custom"
ALT_CUSTOM_SQL_ROOT="/scripts/sql/custom"

SQL_SUCCESS_LOG=()
SQL_FAILURE_LOG=()
TEMP_SQL_FILES=()

render_sql_file_for_execution(){
  local src="$1"
  local pb_db="${DB_PLAYERBOTS_NAME:-acore_playerbots}"
  local rendered="$src"

  if command -v python3 >/dev/null 2>&1; then
    local temp
    temp="$(mktemp)"
    local result
    result="$(python3 - "$src" "$temp" "$pb_db" <<'PY'
import sys, pathlib, re
src, dest, pb_db = sys.argv[1:]
text = pathlib.Path(src).read_text()
original = text
text = text.replace("{{PLAYERBOTS_DB}}", pb_db)
pattern = re.compile(r'(?<![.`])\bplayerbots\b')
text = pattern.sub(f'`{pb_db}`.playerbots', text)
pathlib.Path(dest).write_text(text)
print("changed" if text != original else "unchanged", end="")
PY
)"
    if [ "$result" = "changed" ]; then
      rendered="$temp"
      TEMP_SQL_FILES+=("$temp")
    else
      rm -f "$temp"
    fi
  fi

  echo "$rendered"
}

log_sql_success(){
  local target_db="$1"
  local sql_file="$2"
  SQL_SUCCESS_LOG+=("${target_db}::${sql_file}")
}

log_sql_failure(){
  local target_db="$1"
  local sql_file="$2"
  SQL_FAILURE_LOG+=("${target_db}::${sql_file}")
}

mysql_exec(){
  local mysql_port="${MYSQL_PORT:-3306}"
  if command -v mariadb >/dev/null 2>&1; then
    mariadb --ssl=false -h "${CONTAINER_MYSQL}" -P "$mysql_port" -u root -p"${MYSQL_ROOT_PASSWORD}" "$@"
    return
  fi
  if command -v mysql >/dev/null 2>&1; then
    mysql --ssl-mode=DISABLED -h "${CONTAINER_MYSQL}" -P "$mysql_port" -u root -p"${MYSQL_ROOT_PASSWORD}" "$@"
    return
  fi
  echo "    ❌ Neither mariadb nor mysql client is available for SQL execution" >&2
  return 127
}

playerbots_table_exists(){
  local pb_db="${DB_PLAYERBOTS_NAME:-acore_playerbots}"
  local count
  count="$(mysql_exec -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${pb_db}' AND table_name='playerbots';" 2>/dev/null || echo 0)"
  [ "${count}" != "0" ]
}

run_custom_sql_group(){
  local subdir="$1" target_db="$2" label="$3"
  local dir="${CUSTOM_SQL_ROOT}/${subdir}"
  if [ ! -d "$dir" ] && [ -d "${ALT_CUSTOM_SQL_ROOT}/${subdir}" ]; then
    dir="${ALT_CUSTOM_SQL_ROOT}/${subdir}"
  fi
  [ -d "$dir" ] || return 0
  while IFS= read -r sql_file; do
    local base_name
    base_name="$(basename "$sql_file")"
    local rendered
    rendered="$(render_sql_file_for_execution "$sql_file")"
    if grep -q '\bplayerbots\b' "$rendered"; then
      if ! playerbots_table_exists; then
        echo "  Skipping ${label}: ${base_name} (playerbots table missing)"
        continue
      fi
    fi
    echo "  Executing ${label}: ${base_name}"
    local sql_output
    sql_output="$(mktemp)"
    if mysql_exec "${target_db}" < "$rendered" >"$sql_output" 2>&1; then
      echo "    ✅ Successfully executed ${base_name}"
      log_sql_success "$target_db" "$sql_file"
    else
      echo "    ❌ Failed to execute $sql_file"
      sed 's/^/      /' "$sql_output"
      log_sql_failure "$target_db" "$sql_file"
    fi
    rm -f "$sql_output"
  done < <(LC_ALL=C find "$dir" -type f -name "*.sql" | sort) || true
}

# Function to execute SQL files for a module
module_sql_run_module(){
  local module_key="$1"
  local module_dir="$2"
  local module_name="${MODULE_NAME[$module_key]:-}"
  if [ -z "$module_name" ]; then
    module_name="$module_dir"
  fi
  local world_db="${DB_WORLD_NAME:-acore_world}"
  local auth_db="${DB_AUTH_NAME:-acore_auth}"
  local characters_db="${DB_CHARACTERS_NAME:-acore_characters}"
  local playerbots_db="${DB_PLAYERBOTS_NAME:-acore_playerbots}"
  local character_set="${MYSQL_CHARACTER_SET:-utf8mb4}"
  local collation="${MYSQL_COLLATION:-utf8mb4_unicode_ci}"
  execute_sql_file_in_db(){
    local target_db="$1"
    local sql_file="$2"
    local label="$3"
    local rendered
    rendered="$(render_sql_file_for_execution "$sql_file")"

    if grep -q '\bplayerbots\b' "$rendered"; then
      if ! playerbots_table_exists; then
        echo "  Skipping ${label}: ${base_name} (playerbots table missing)"
        return 0
      fi
    fi

    local base_name
    base_name="$(basename "$sql_file")"
    echo "  Executing ${label}: ${base_name}"
    local sql_output
    sql_output="$(mktemp)"
    if mysql_exec "${target_db}" < "$rendered" >"$sql_output" 2>&1; then
      echo "    ✅ Successfully executed ${base_name}"
      log_sql_success "$target_db" "$sql_file"
    else
      echo "    ❌ Failed to execute $sql_file"
      sed 's/^/      /' "$sql_output"
      log_sql_failure "$target_db" "$sql_file"
    fi
    rm -f "$sql_output"
  }

  local run_sorted_sql

  run_sorted_sql() {
    local dir="$1"
    local target_db="$2"
    local label="$3"
    local skip_regex="${4:-}"
    [ -d "$dir" ] || return
    while IFS= read -r sql_file; do
      local base_name
      base_name="$(basename "$sql_file")"
      if [ -n "$skip_regex" ] && [[ "$base_name" =~ $skip_regex ]]; then
        echo "  Skipping ${label}: ${base_name}"
        continue
      fi
      execute_sql_file_in_db "$target_db" "$sql_file" "$label"
    done < <(LC_ALL=C find "$dir" -type f -name "*.sql" | sort) || true
  }

  echo "Processing SQL scripts for $module_name..."

  if [ "$module_key" = "MODULE_PLAYERBOTS" ]; then
    echo "  Ensuring database ${playerbots_db} exists..."
    if mysql_exec -e "CREATE DATABASE IF NOT EXISTS \`${playerbots_db}\` CHARACTER SET ${character_set} COLLATE ${collation};" >/dev/null 2>&1; then
      echo "    ✅ Playerbots database ready"
    else
      echo "    ❌ Failed to ensure playerbots database"
    fi
  fi

  # Find and execute SQL files in the module
  if [ -d "$module_dir/data/sql" ]; then
    # Execute world database scripts
    if [ -d "$module_dir/data/sql/world" ]; then
      while IFS= read -r sql_file; do
        execute_sql_file_in_db "$world_db" "$sql_file" "world SQL"
      done < <(find "$module_dir/data/sql/world" -type f -name "*.sql") || true
    fi
    run_sorted_sql "$module_dir/data/sql/db-world" "${world_db}" "world SQL"

    # Execute auth database scripts
    if [ -d "$module_dir/data/sql/auth" ]; then
      while IFS= read -r sql_file; do
        execute_sql_file_in_db "$auth_db" "$sql_file" "auth SQL"
      done < <(find "$module_dir/data/sql/auth" -type f -name "*.sql") || true
    fi
    run_sorted_sql "$module_dir/data/sql/db-auth" "${auth_db}" "auth SQL"

    # Execute character database scripts
    if [ -d "$module_dir/data/sql/characters" ]; then
      while IFS= read -r sql_file; do
        execute_sql_file_in_db "$characters_db" "$sql_file" "characters SQL"
      done < <(find "$module_dir/data/sql/characters" -type f -name "*.sql") || true
    fi
    run_sorted_sql "$module_dir/data/sql/db-characters" "${characters_db}" "characters SQL"

    # Execute playerbots database scripts
    if [ "$module_key" = "MODULE_PLAYERBOTS" ] && [ -d "$module_dir/data/sql/playerbots" ]; then
      local pb_root="$module_dir/data/sql/playerbots"
      run_sorted_sql "$pb_root/base" "$playerbots_db" "playerbots SQL"
      run_sorted_sql "$pb_root/custom" "$playerbots_db" "playerbots SQL"
      run_sorted_sql "$pb_root/updates" "$playerbots_db" "playerbots SQL"
      run_sorted_sql "$pb_root/archive" "$playerbots_db" "playerbots SQL"
      echo "  Skipping playerbots create scripts (handled by automation)"
    fi

    # Execute base SQL files (common pattern)
    while IFS= read -r sql_file; do
      execute_sql_file_in_db "$world_db" "$sql_file" "base SQL"
    done < <(find "$module_dir/data/sql" -maxdepth 1 -type f -name "*.sql") || true
  fi

  # Look for SQL files in other common locations
  if [ -d "$module_dir/sql" ]; then
    while IFS= read -r sql_file; do
      execute_sql_file_in_db "$world_db" "$sql_file" "module SQL"
    done < <(find "$module_dir/sql" -type f -name "*.sql") || true
  fi

  return 0
}

# Main function to execute SQL for all enabled modules
execute_module_sql_scripts() {
  # Install MariaDB client if not available
  which mariadb >/dev/null 2>&1 || {
    echo "Installing MariaDB client..."
    apk add --no-cache mariadb-client >/dev/null 2>&1 || echo "Warning: Could not install MariaDB client"
  }

  SQL_SUCCESS_LOG=()
  SQL_FAILURE_LOG=()

  # Iterate modules from manifest metadata
  local key module_dir enabled
  local world_db="${DB_WORLD_NAME:-acore_world}"
  local auth_db="${DB_AUTH_NAME:-acore_auth}"
  local characters_db="${DB_CHARACTERS_NAME:-acore_characters}"
  for key in "${MODULE_KEYS[@]}"; do
    module_dir="${MODULE_NAME[$key]:-}"
    [ -n "$module_dir" ] || continue
    [ -d "$module_dir" ] || continue

    enabled="${MODULE_ENABLED[$key]:-0}"
    if [ "$enabled" != "1" ]; then
      continue
    fi

    if [ "$module_dir" = "mod-pocket-portal" ]; then
      echo '⚠️  Skipping mod-pocket-portal SQL: module disabled until C++20 patch is applied.'
      continue
    fi

    module_sql_run_module "$key" "$module_dir"
  done

  run_custom_sql_group world "${world_db}" "custom world SQL"
  run_custom_sql_group auth "${auth_db}" "custom auth SQL"
  run_custom_sql_group characters "${characters_db}" "custom characters SQL"

  echo "SQL execution summary:"
  if [ ${#SQL_SUCCESS_LOG[@]} -gt 0 ]; then
    echo "  ✅ Applied:"
    for entry in "${SQL_SUCCESS_LOG[@]}"; do
      IFS='::' read -r db file <<< "$entry"
      echo "     • [$db] $file"
    done
  else
    echo "  ✅ Applied: none"
  fi
  if [ ${#SQL_FAILURE_LOG[@]} -gt 0 ]; then
    echo "  ❌ Failed:"
    for entry in "${SQL_FAILURE_LOG[@]}"; do
      IFS='::' read -r db file <<< "$entry"
      echo "     • [$db] $file"
    done
  else
    echo "  ❌ Failed: none"
  fi

  if [ ${#TEMP_SQL_FILES[@]} -gt 0 ]; then
    rm -f "${TEMP_SQL_FILES[@]}" 2>/dev/null || true
    TEMP_SQL_FILES=()
  fi

  return 0
}
