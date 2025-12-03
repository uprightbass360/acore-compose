# AzerothCore RealmMaster - Cleanup TODO

## Overview
This document outlines systematic cleanup opportunities using the proven methodology from our successful consolidation. Each phase must be validated and tested incrementally without breaking existing functionality.

## Methodology
1. **Analyze** - Map dependencies and usage patterns
2. **Consolidate** - Create shared libraries/templates
3. **Replace** - Update scripts to use centralized versions
4. **Test** - Validate each change incrementally
5. **Document** - Track changes and dependencies

---

## Phase 1: Complete Script Function Consolidation
**Priority: HIGH** | **Risk: LOW** | **Impact: HIGH**

### Status
✅ **Completed**: Master scripts (deploy.sh, build.sh, cleanup.sh) + 4 critical scripts
🔄 **Remaining**: 10+ scripts with duplicate logging functions

### Remaining Scripts to Consolidate
```bash
# Root level scripts
./changelog.sh                     # Has: info(), warn(), err()
./update-latest.sh                 # Has: info(), ok(), warn(), err()

# Backup system scripts
./scripts/bash/backup-export.sh    # Has: info(), ok(), warn(), err()
./scripts/bash/backup-import.sh    # Has: info(), ok(), warn(), err()

# Database scripts
./scripts/bash/db-guard.sh         # Has: info(), warn(), err()
./scripts/bash/db-health-check.sh  # Has: info(), ok(), warn(), err()

# Module & verification scripts
./scripts/bash/verify-sql-updates.sh        # Has: info(), warn(), err()
./scripts/bash/manage-modules.sh           # Has: info(), ok(), warn(), err()
./scripts/bash/repair-storage-permissions.sh # Has: info(), warn(), err()
./scripts/bash/test-phase1-integration.sh  # Has: info(), ok(), warn(), err()
```

### Implementation Plan
**Step 1.1**: Consolidate Root Level Scripts (changelog.sh, update-latest.sh)
- Add lib/common.sh sourcing with error handling
- Remove duplicate function definitions
- Test functionality with `--help` flags

**Step 1.2**: Consolidate Backup System Scripts
- Update backup-export.sh and backup-import.sh
- Ensure backup operations still work correctly
- Test with dry-run flags where available

**Step 1.3**: Consolidate Database Scripts
- Update db-guard.sh and db-health-check.sh
- **CRITICAL**: These run in containers - verify mount paths work
- Test with existing database connections

**Step 1.4**: Consolidate Module & Verification Scripts
- Update manage-modules.sh, verify-sql-updates.sh, repair-storage-permissions.sh
- Test module staging and SQL verification workflows
- Verify test-phase1-integration.sh still functions

### Validation Tests
```bash
# Test each script category after consolidation
./changelog.sh --help
./update-latest.sh --help
./scripts/bash/backup-export.sh --dry-run
./scripts/bash/manage-modules.sh --list
```

---

## Phase 2: Docker Compose YAML Anchor Completion
**Priority: HIGH** | **Risk: MEDIUM** | **Impact: HIGH**

### Status
✅ **Completed**: Basic YAML anchors, 2 authserver services consolidated
🔄 **Remaining**: 4 worldserver services, database services, volume patterns

### Current Docker Compose Analysis
```yaml
# Services needing consolidation:
- ac-worldserver-standard      # ~45 lines → can reduce to ~10
- ac-worldserver-playerbots    # ~45 lines → can reduce to ~10
- ac-worldserver-modules       # ~45 lines → can reduce to ~10
- ac-authserver-modules        # ~30 lines → can reduce to ~8

# Database services with repeated patterns:
- ac-db-import                 # Repeated volume mounts
- ac-db-guard                  # Similar environment variables
- ac-db-init                   # Similar MySQL connection patterns

# Volume mount patterns repeated 15+ times:
- ${STORAGE_CONFIG_PATH}:/azerothcore/env/dist/etc
- ${STORAGE_LOGS_PATH}:/azerothcore/logs
- ${BACKUP_PATH}:/backups
```

### Implementation Plan
**Step 2.1**: Complete Worldserver Service Consolidation
- Extend x-worldserver-common anchor to cover all variants
- Consolidate ac-worldserver-standard, ac-worldserver-playerbots, ac-worldserver-modules
- Test each Docker profile: `docker compose --profile services-standard config`

**Step 2.2**: Database Services Consolidation
- Create x-database-common anchor for shared database configurations
- Create x-database-volumes anchor for repeated volume patterns
- Update ac-db-import, ac-db-guard, ac-db-init services

**Step 2.3**: Complete Authserver Consolidation
- Consolidate remaining ac-authserver-modules service
- Verify all three profiles work: standard, playerbots, modules

### Validation Tests
```bash
# Test all profiles generate valid configurations
docker compose --profile services-standard config --quiet
docker compose --profile services-playerbots config --quiet
docker compose --profile services-modules config --quiet

# Test actual deployment (non-destructive)
docker compose --profile services-standard up --dry-run
```

---

## Phase 3: Utility Function Libraries
**Priority: MEDIUM** | **Risk: MEDIUM** | **Impact: MEDIUM**

### Status
✅ **Completed**: All three utility libraries created and tested
✅ **Completed**: Integration with backup-import.sh as proof of concept
🔄 **Remaining**: Update remaining 14+ scripts to use new libraries

### Created Libraries

**✅ scripts/bash/lib/mysql-utils.sh** - COMPLETED
- MySQL connection management: `mysql_test_connection()`, `mysql_wait_for_connection()`
- Query execution: `mysql_exec_with_retry()`, `mysql_query()`, `docker_mysql_query()`
- Database utilities: `mysql_database_exists()`, `mysql_get_table_count()`
- Backup/restore: `mysql_backup_database()`, `mysql_restore_database()`
- Configuration: `mysql_validate_configuration()`, `mysql_print_configuration()`

**✅ scripts/bash/lib/docker-utils.sh** - COMPLETED
- Container management: `docker_get_container_status()`, `docker_wait_for_container_state()`
- Execution: `docker_exec_with_retry()`, `docker_is_container_running()`
- Project management: `docker_get_project_name()`, `docker_list_project_containers()`
- Image operations: `docker_get_container_image()`, `docker_pull_image_with_retry()`
- Compose integration: `docker_compose_validate()`, `docker_compose_deploy()`
- System utilities: `docker_check_daemon()`, `docker_cleanup_system()`

**✅ scripts/bash/lib/env-utils.sh** - COMPLETED
- Environment management: `env_read_with_fallback()`, `env_read_typed()`, `env_update_value()`
- Path utilities: `path_resolve_absolute()`, `file_ensure_writable_dir()`
- File operations: `file_create_backup()`, `file_set_permissions()`
- Configuration: `config_read_template_value()`, `config_validate_env()`
- System detection: `system_detect_os()`, `system_check_requirements()`

### Integration Status

**✅ Proof of Concept**: backup-import.sh updated with fallback compatibility
- Uses new utility functions when available
- Maintains backward compatibility with graceful fallbacks
- Tested and functional

### Remaining Implementation
**Step 3.4**: Update High-Priority Scripts
- backup-export.sh: Use mysql-utils and env-utils functions
- db-guard.sh: Use mysql-utils for database operations
- deploy-tools.sh: Use docker-utils for container management
- verify-deployment.sh: Use docker-utils for status checking

**Step 3.5**: Update Database Scripts
- db-health-check.sh: Use mysql-utils for health validation
- db-import-conditional.sh: Use mysql-utils and env-utils
- manual-backup.sh: Use mysql-utils backup functions

**Step 3.6**: Update Deployment Scripts
- migrate-stack.sh: Use docker-utils for remote operations
- stage-modules.sh: Use env-utils for path management
- rebuild-with-modules.sh: Use docker-utils for build operations

### Validation Tests - COMPLETED ✅
```bash
# Test MySQL utilities
source scripts/bash/lib/mysql-utils.sh
mysql_print_configuration  # ✅ PASSED

# Test Docker utilities
source scripts/bash/lib/docker-utils.sh
docker_print_system_info   # ✅ PASSED

# Test Environment utilities
source scripts/bash/lib/env-utils.sh
env_utils_validate         # ✅ PASSED

# Test integrated script
./backup-import.sh --help  # ✅ PASSED with new libraries
```

### Next Steps
- Continue with Step 3.4: Update backup-export.sh, db-guard.sh, deploy-tools.sh
- Implement progressive rollout with testing after each script update
- Complete remaining 11 scripts in dependency order

---

## Phase 4: Error Handling Standardization
**Priority: MEDIUM** | **Risk: LOW** | **Impact: MEDIUM**

### Analysis
**Current State**: Mixed error handling patterns across scripts
```bash
# Found patterns:
set -e                    # 45 scripts
set -euo pipefail        # 23 scripts
set -eu                  # 8 scripts
(no error handling)      # 12 scripts
```

### Implementation Plan
**Step 4.1**: Standardize Error Handling
- Add `set -euo pipefail` to all scripts where safe
- Add error traps for cleanup in critical scripts
- Implement consistent exit codes

**Step 4.2**: Add Script Validation Framework
- Create validation helper functions
- Add dependency checking to critical scripts
- Implement graceful degradation where possible

### Target Pattern
```bash
#!/bin/bash
set -euo pipefail

# Error handling setup
trap 'echo "❌ Error on line $LINENO" >&2' ERR
trap 'cleanup_on_exit' EXIT

# Source libraries with validation
source_lib_or_exit() {
  local lib_path="$1"
  if ! source "$lib_path" 2>/dev/null; then
    echo "❌ FATAL: Cannot load $lib_path" >&2
    exit 1
  fi
}
```

---

## Phase 5: Configuration Template Consolidation
**Priority: LOW** | **Risk: LOW** | **Impact: LOW**

### Analysis
**Found**: 71 instances of duplicate color definitions across scripts
**Found**: Multiple .env template patterns that could be standardized

### Implementation Plan
**Step 5.1**: Color Definition Consolidation
- Ensure all scripts use lib/common.sh colors exclusively
- Remove remaining duplicate color definitions
- Add color theme support (optional)

**Step 5.2**: Configuration Template Cleanup
- Consolidate environment variable patterns
- Create shared configuration validation
- Standardize default value patterns

---

## Implementation Priority Order

### **Week 1: High Impact, Low Risk**
- [ ] Phase 1.1-1.2: Consolidate remaining root and backup scripts
- [ ] Phase 2.1: Complete worldserver YAML anchor consolidation
- [ ] Validate: All major scripts and Docker profiles work

### **Week 2: Complete Core Consolidation**
- [ ] Phase 1.3-1.4: Consolidate database and module scripts
- [ ] Phase 2.2-2.3: Complete database service and authserver consolidation
- [ ] Validate: Full deployment pipeline works end-to-end

### **Week 3: Utility Libraries**
- [ ] Phase 3.1: Create and implement MySQL utility library
- [ ] Phase 3.2: Create and implement Docker utility library
- [ ] Validate: Scripts using new libraries function correctly

### **Week 4: Polish and Standardization**
- [ ] Phase 3.3: Complete environment utility library
- [ ] Phase 4.1-4.2: Standardize error handling
- [ ] Phase 5.1-5.2: Final cleanup of colors and configs
- [ ] Validate: Complete system testing

---

## Validation Framework

### **Incremental Testing**
Each phase must pass these tests before proceeding:

**Script Functionality Tests:**
```bash
# Master scripts
./deploy.sh --help && ./build.sh --help && ./cleanup.sh --help

# Docker compose validation
docker compose config --quiet

# Profile validation
for profile in services-standard services-playerbots services-modules; do
  docker compose --profile $profile config --quiet
done
```

**Integration Tests:**
```bash
# End-to-end validation (non-destructive)
./deploy.sh --profile services-standard --dry-run --no-watch
./scripts/bash/verify-deployment.sh --profile services-standard
```

**Regression Prevention:**
- Git commit after each completed phase
- Tag successful consolidations
- Maintain rollback procedures

---

## Risk Mitigation

### **Container Script Dependencies**
- **High Risk**: Scripts mounted into containers (db-guard.sh, backup-scheduler.sh)
- **Mitigation**: Test container mounting before consolidating
- **Validation**: Verify scripts work inside container environment

### **Remote Deployment Impact**
- **Medium Risk**: SSH deployment scripts (migrate-stack.sh)
- **Mitigation**: Test remote deployment on non-production host
- **Validation**: Verify remote script sourcing works correctly

### **Docker Compose Version Compatibility**
- **Medium Risk**: Advanced YAML anchors may not work on older versions
- **Mitigation**: Add version detection and warnings
- **Validation**: Test on minimum supported Docker Compose version

---

## Success Metrics

### **Quantitative Goals**
- Reduce duplicate logging functions from 14 → 0 scripts
- Reduce Docker compose file from ~1000 → ~600 lines
- Reduce color definitions from 71 → 1 centralized location
- Consolidate MySQL connection patterns from 22 → 1 library

### **Qualitative Goals**
- Single source of truth for common functionality
- Consistent user experience across all scripts
- Maintainable and extensible architecture
- Clear dependency relationships
- Robust error handling and validation

### **Completion Criteria**
- [ ] All scripts source centralized libraries exclusively
- [ ] No duplicate function definitions remain
- [ ] Docker compose uses YAML anchors for all repeated patterns
- [ ] Comprehensive test suite validates all functionality
- [ ] Documentation updated to reflect new architecture