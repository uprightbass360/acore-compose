#!/bin/bash
#
# Docker utility library for AzerothCore RealmMaster scripts
# This library provides standardized Docker operations, container management,
# and deployment functions.
#
# Usage: source /path/to/scripts/bash/lib/docker-utils.sh
#

# Prevent multiple sourcing
if [ -n "${_DOCKER_UTILS_LIB_LOADED:-}" ]; then
  return 0
fi
_DOCKER_UTILS_LIB_LOADED=1

# Source common library for logging functions
DOCKER_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$DOCKER_UTILS_DIR/common.sh" ]; then
  source "$DOCKER_UTILS_DIR/common.sh"
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
# DOCKER CONTAINER MANAGEMENT
# =============================================================================

# Get container status
# Returns: running, exited, paused, restarting, removing, dead, created, or "not_found"
#
# Usage:
#   status=$(docker_get_container_status "ac-mysql")
#   if [ "$status" = "running" ]; then
#     echo "Container is running"
#   fi
#
docker_get_container_status() {
  local container_name="$1"

  if ! docker ps -a --format "table {{.Names}}\t{{.Status}}" | grep -q "^$container_name"; then
    echo "not_found"
    return 1
  fi

  docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null || echo "not_found"
}

# Check if container is running
# Returns 0 if running, 1 if not running or not found
#
# Usage:
#   if docker_is_container_running "ac-mysql"; then
#     echo "MySQL container is running"
#   fi
#
docker_is_container_running() {
  local container_name="$1"
  local status

  status=$(docker_get_container_status "$container_name")
  [ "$status" = "running" ]
}

# Wait for container to reach desired state
# Returns 0 if container reaches state within timeout, 1 if timeout
#
# Usage:
#   docker_wait_for_container_state "ac-mysql" "running" 30
#   docker_wait_for_container_state "ac-mysql" "exited" 10
#
docker_wait_for_container_state() {
  local container_name="$1"
  local desired_state="$2"
  local timeout="${3:-30}"
  local check_interval="${4:-2}"
  local elapsed=0

  info "Waiting for container '$container_name' to reach state '$desired_state' (timeout: ${timeout}s)"

  while [ $elapsed -lt $timeout ]; do
    local current_state
    current_state=$(docker_get_container_status "$container_name")

    if [ "$current_state" = "$desired_state" ]; then
      info "Container '$container_name' reached desired state: $desired_state"
      return 0
    fi

    sleep "$check_interval"
    elapsed=$((elapsed + check_interval))
  done

  err "Container '$container_name' did not reach state '$desired_state' within ${timeout}s (current: $current_state)"
  return 1
}

# Execute command in container with retry logic
# Handles container availability and connection issues
#
# Usage:
#   docker_exec_with_retry "ac-mysql" "mysql -uroot -ppassword -e 'SELECT 1'"
#   echo "SELECT 1" | docker_exec_with_retry "ac-mysql" "mysql -uroot -ppassword"
#
docker_exec_with_retry() {
  local container_name="$1"
  local command="$2"
  local max_attempts="${3:-3}"
  local retry_delay="${4:-2}"
  local interactive="${5:-false}"

  if ! docker_is_container_running "$container_name"; then
    err "Container '$container_name' is not running"
    return 1
  fi

  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    if [ "$interactive" = "true" ]; then
      if docker exec -i "$container_name" sh -c "$command"; then
        return 0
      fi
    else
      if docker exec "$container_name" sh -c "$command"; then
        return 0
      fi
    fi

    if [ $attempt -lt $max_attempts ]; then
      warn "Docker exec failed in '$container_name' (attempt $attempt/$max_attempts), retrying in ${retry_delay}s..."
      sleep "$retry_delay"
    fi

    attempt=$((attempt + 1))
  done

  err "Docker exec failed in '$container_name' after $max_attempts attempts"
  return 1
}

# =============================================================================
# DOCKER COMPOSE PROJECT MANAGEMENT
# =============================================================================

# Get project name from environment or docker-compose.yml
# Returns the Docker Compose project name
#
# Usage:
#   project_name=$(docker_get_project_name)
#   echo "Project: $project_name"
#
docker_get_project_name() {
  # Check environment variable first
  if [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
    echo "$COMPOSE_PROJECT_NAME"
    return 0
  fi

  # Check for docker-compose.yml name directive
  if [ -f "docker-compose.yml" ] && command -v python3 >/dev/null 2>&1; then
    local project_name
    project_name=$(python3 -c "
import yaml
try:
    with open('docker-compose.yml', 'r') as f:
        data = yaml.safe_load(f)
    print(data.get('name', ''))
except:
    print('')
" 2>/dev/null)

    if [ -n "$project_name" ]; then
      echo "$project_name"
      return 0
    fi
  fi

  # Fallback to directory name
  basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g'
}

# List containers for current project
# Returns list of container names with optional filtering
#
# Usage:
#   containers=$(docker_list_project_containers)
#   running_containers=$(docker_list_project_containers "running")
#
docker_list_project_containers() {
  local status_filter="${1:-}"
  local project_name
  project_name=$(docker_get_project_name)

  local filter_arg=""
  if [ -n "$status_filter" ]; then
    filter_arg="--filter status=$status_filter"
  fi

  # Use project label to find containers
  docker ps -a $filter_arg --filter "label=com.docker.compose.project=$project_name" --format "{{.Names}}" 2>/dev/null
}

# Stop project containers gracefully
# Stops containers with configurable timeout
#
# Usage:
#   docker_stop_project_containers 30  # Stop with 30s timeout
#   docker_stop_project_containers     # Use default 10s timeout
#
docker_stop_project_containers() {
  local timeout="${1:-10}"
  local containers

  containers=$(docker_list_project_containers "running")
  if [ -z "$containers" ]; then
    info "No running containers found for project"
    return 0
  fi

  info "Stopping project containers with ${timeout}s timeout: $containers"
  echo "$containers" | xargs -r docker stop -t "$timeout"
}

# Start project containers
# Starts containers that are stopped but exist
#
# Usage:
#   docker_start_project_containers
#
docker_start_project_containers() {
  local containers

  containers=$(docker_list_project_containers "exited")
  if [ -z "$containers" ]; then
    info "No stopped containers found for project"
    return 0
  fi

  info "Starting project containers: $containers"
  echo "$containers" | xargs -r docker start
}

# =============================================================================
# DOCKER IMAGE MANAGEMENT
# =============================================================================

# Get image information for container
# Returns image name:tag for specified container
#
# Usage:
#   image=$(docker_get_container_image "ac-mysql")
#   echo "MySQL container using image: $image"
#
docker_get_container_image() {
  local container_name="$1"

  if ! docker_is_container_running "$container_name"; then
    # Try to get from stopped container
    docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null || echo "unknown"
  else
    docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null || echo "unknown"
  fi
}

# Check if image exists locally
# Returns 0 if image exists, 1 if not found
#
# Usage:
#   if docker_image_exists "mysql:8.0"; then
#     echo "MySQL image is available"
#   fi
#
docker_image_exists() {
  local image_name="$1"

  docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${image_name}$"
}

# Pull image with retry logic
# Handles temporary network issues and registry problems
#
# Usage:
#   docker_pull_image_with_retry "mysql:8.0"
#   docker_pull_image_with_retry "azerothcore/ac-wotlk-worldserver:latest" 5 10
#
docker_pull_image_with_retry() {
  local image_name="$1"
  local max_attempts="${2:-3}"
  local retry_delay="${3:-5}"

  if docker_image_exists "$image_name"; then
    info "Image '$image_name' already exists locally"
    return 0
  fi

  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    info "Pulling image '$image_name' (attempt $attempt/$max_attempts)"

    if docker pull "$image_name"; then
      info "Successfully pulled image '$image_name'"
      return 0
    fi

    if [ $attempt -lt $max_attempts ]; then
      warn "Failed to pull image '$image_name', retrying in ${retry_delay}s..."
      sleep "$retry_delay"
    fi

    attempt=$((attempt + 1))
  done

  err "Failed to pull image '$image_name' after $max_attempts attempts"
  return 1
}

# =============================================================================
# DOCKER COMPOSE OPERATIONS
# =============================================================================

# Validate docker-compose.yml configuration
# Returns 0 if valid, 1 if invalid or errors found
#
# Usage:
#   if docker_compose_validate; then
#     echo "Docker Compose configuration is valid"
#   fi
#
docker_compose_validate() {
  local compose_file="${1:-docker-compose.yml}"

  if [ ! -f "$compose_file" ]; then
    err "Docker Compose file not found: $compose_file"
    return 1
  fi

  if docker compose -f "$compose_file" config --quiet; then
    info "Docker Compose configuration is valid"
    return 0
  else
    err "Docker Compose configuration validation failed"
    return 1
  fi
}

# Get service status from docker-compose
# Returns service status or "not_found" if service doesn't exist
#
# Usage:
#   status=$(docker_compose_get_service_status "ac-mysql")
#
docker_compose_get_service_status() {
  local service_name="$1"
  local project_name
  project_name=$(docker_get_project_name)

  # Get container name for the service
  local container_name="${project_name}-${service_name}-1"

  docker_get_container_status "$container_name"
}

# Deploy with profile and options
# Wrapper around docker compose up with standardized options
#
# Usage:
#   docker_compose_deploy "services-standard" "--detach"
#   docker_compose_deploy "services-modules" "--no-deps ac-worldserver"
#
docker_compose_deploy() {
  local profile="${1:-services-standard}"
  local additional_options="${2:-}"

  if ! docker_compose_validate; then
    err "Cannot deploy: Docker Compose configuration is invalid"
    return 1
  fi

  info "Deploying with profile: $profile"

  # Use exec to replace current shell for proper signal handling
  if [ -n "$additional_options" ]; then
    docker compose --profile "$profile" up $additional_options
  else
    docker compose --profile "$profile" up --detach
  fi
}

# =============================================================================
# DOCKER SYSTEM UTILITIES
# =============================================================================

# Check Docker daemon availability
# Returns 0 if Docker is available, 1 if not
#
# Usage:
#   if docker_check_daemon; then
#     echo "Docker daemon is available"
#   fi
#
docker_check_daemon() {
  if docker info >/dev/null 2>&1; then
    return 0
  else
    err "Docker daemon is not available or accessible"
    return 1
  fi
}

# Get Docker system information
# Returns formatted system info for debugging
#
# Usage:
#   docker_print_system_info
#
docker_print_system_info() {
  info "Docker System Information:"

  if ! docker_check_daemon; then
    err "Cannot retrieve Docker system information - daemon not available"
    return 1
  fi

  local docker_version compose_version
  docker_version=$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo "unknown")
  compose_version=$(docker compose version --short 2>/dev/null || echo "unknown")

  info "  Docker Version: $docker_version"
  info "  Compose Version: $compose_version"
  info "  Project Name: $(docker_get_project_name)"

  local running_containers
  running_containers=$(docker_list_project_containers "running" | wc -l)
  info "  Running Containers: $running_containers"
}

# Cleanup unused Docker resources
# Removes stopped containers, unused networks, and dangling images
#
# Usage:
#   docker_cleanup_system true   # Include unused volumes
#   docker_cleanup_system false  # Preserve volumes (default)
#
docker_cleanup_system() {
  local include_volumes="${1:-false}"

  info "Cleaning up Docker system resources..."

  # Remove stopped containers
  local stopped_containers
  stopped_containers=$(docker ps -aq --filter "status=exited")
  if [ -n "$stopped_containers" ]; then
    info "Removing stopped containers"
    echo "$stopped_containers" | xargs docker rm
  fi

  # Remove unused networks
  info "Removing unused networks"
  docker network prune -f

  # Remove dangling images
  info "Removing dangling images"
  docker image prune -f

  # Remove unused volumes if requested
  if [ "$include_volumes" = "true" ]; then
    warn "Removing unused volumes (this may delete data!)"
    docker volume prune -f
  fi

  info "Docker system cleanup completed"
}

# =============================================================================
# CONTAINER HEALTH AND MONITORING
# =============================================================================

# Get container resource usage
# Returns CPU and memory usage statistics
#
# Usage:
#   docker_get_container_stats "ac-mysql"
#
docker_get_container_stats() {
  local container_name="$1"

  if ! docker_is_container_running "$container_name"; then
    err "Container '$container_name' is not running"
    return 1
  fi

  docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" "$container_name"
}

# Check container logs for errors
# Searches recent logs for error patterns
#
# Usage:
#   docker_check_container_errors "ac-mysql" 100
#
docker_check_container_errors() {
  local container_name="$1"
  local lines="${2:-50}"

  if ! docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
    err "Container '$container_name' not found"
    return 1
  fi

  info "Checking last $lines log lines for errors in '$container_name'"

  # Look for common error patterns
  docker logs --tail "$lines" "$container_name" 2>&1 | grep -i "error\|exception\|fail\|fatal" || {
    info "No obvious errors found in recent logs"
    return 0
  }
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Library loaded successfully
# Scripts can check for $_DOCKER_UTILS_LIB_LOADED to verify library is loaded