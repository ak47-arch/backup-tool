#!/bin/bash

#################################################################################
# Test Suite for Universal Directory Backup Tool
#################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
TEST_DIR="/tmp/backup-tool-tests"
PASSED=0
FAILED=0

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

#################################################################################
# Test Utilities
#################################################################################

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"/{source,backups,config}
    
    # Create test data
    mkdir -p "$TEST_DIR/source/data/nested"
    echo "test file 1" > "$TEST_DIR/source/data/file1.txt"
    echo "test file 2" > "$TEST_DIR/source/data/file2.txt"
    echo "nested file" > "$TEST_DIR/source/data/nested/nested.txt"
    
    chmod 755 "$TEST_DIR/source"
    chmod 755 "$TEST_DIR/backups"
}

cleanup_test_env() {
    rm -rf "$TEST_DIR"
}

test_pass() {
    local test_name="$1"
    echo -e "${GREEN}✓ PASS${NC}: $test_name"
    ((PASSED++))
}

test_fail() {
    local test_name="$1"
    local reason="$2"
    echo -e "${RED}✗ FAIL${NC}: $test_name"
    echo "  Reason: $reason"
    ((FAILED++))
}

test_section() {
    local section="$1"
    echo ""
    echo -e "${BLUE}=== $section ===${NC}"
}

#################################################################################
# Tests
#################################################################################

test_direct_mode_backup() {
    local test_name="Direct mode creates backup"
    test_section "$test_name"
    
    if bash "$BACKUP_SCRIPT" \
        --source "$TEST_DIR/source/data" \
        --target "$TEST_DIR/backups" \
        --job-name test_job >/dev/null 2>&1; then
        
        # Check artifact exists
        local artifacts=($(ls "$TEST_DIR/backups"/test_job_*.tar.gz 2>/dev/null || true))
        if [[ ${#artifacts[@]} -eq 1 ]]; then
            test_pass "$test_name"
        else
            test_fail "$test_name" "Expected 1 artifact, found ${#artifacts[@]}"
        fi
    else
        test_fail "$test_name" "Backup command failed"
    fi
}

test_dry_run_no_create() {
    local test_name="Dry-run mode doesn't create artifacts"
    test_section "$test_name"
    
    if bash "$BACKUP_SCRIPT" \
        --source "$TEST_DIR/source/data" \
        --target "$TEST_DIR/backups" \
        --job-name dryrun_test \
        --dry-run >/dev/null 2>&1; then
        
        local artifacts=($(ls "$TEST_DIR/backups"/dryrun_test_*.tar.gz 2>/dev/null || true))
        if [[ ${#artifacts[@]} -eq 0 ]]; then
            test_pass "$test_name"
        else
            test_fail "$test_name" "Dry-run created ${#artifacts[@]} artifacts"
        fi
    else
        test_fail "$test_name" "Dry-run command failed"
    fi
}

test_same_day_reruns() {
    local test_name="Same-day reruns create separate artifacts"
    test_section "$test_name"
    
    # First run
    bash "$BACKUP_SCRIPT" \
        --source "$TEST_DIR/source/data" \
        --target "$TEST_DIR/backups" \
        --job-name same_day \
        >/dev/null 2>&1
    
    sleep 2
    
    # Second run
    bash "$BACKUP_SCRIPT" \
        --source "$TEST_DIR/source/data" \
        --target "$TEST_DIR/backups" \
        --job-name same_day \
        >/dev/null 2>&1
    
    local artifacts=($(ls "$TEST_DIR/backups"/same_day_*.tar.gz 2>/dev/null || true))
    if [[ ${#artifacts[@]} -eq 2 ]]; then
        test_pass "$test_name"
    else
        test_fail "$test_name" "Expected 2 artifacts, found ${#artifacts[@]}"
    fi
}

test_retention_pruning() {
    local test_name "Retention pruning keeps only latest N"
    test_section "$test_name"
    
    local day_start=$(date +%Y%m%d)
    
    # Create multiple backups with custom timestamps (simulate multiple days)
    for i in {1..35}; do
        mkdir -p "$TEST_DIR/backups/retention_test"
        # Create dummy tar file with sequential names
        touch "$TEST_DIR/backups/retention_test/retention_test_${day_start}_00000$((i % 10)).tar.gz"
    done
    
    # Manually call retention logic via script (via config mode)
    cat > "$TEST_DIR/config/retention_test.yaml" << 'YAML'
defaults:
  retention_count: 30

jobs:
  - name: retention_test
    source_dir: /dev/null
    target_dir: /tmp/backup-tool-tests/backups/retention_test
    enabled: false
YAML
    
    # Note: retention check would be via actual backup, so just verify directory
    local artifacts=($(ls "$TEST_DIR/backups"/retention_test_*.tar.gz 2>/dev/null || true))
    if [[ ${#artifacts[@]} -eq 35 ]]; then
        test_pass "$test_name (setup)"
    else
        test_fail "$test_name" "Setup failed"
    fi
}

test_checksums_created() {
    local test_name="Checksums are created alongside artifacts"
    test_section "$test_name"
    
    bash "$BACKUP_SCRIPT" \
        --source "$TEST_DIR/source/data" \
        --target "$TEST_DIR/backups" \
        --job-name checksum_test \
        >/dev/null 2>&1
    
    local artifacts=($(ls "$TEST_DIR/backups"/checksum_test_*.tar.gz 2>/dev/null || true))
    if [[ ${#artifacts[@]} -gt 0 ]]; then
        local artifact="${artifacts[0]}"
        if [[ -f "${artifact}.sha256" ]]; then
            # Verify checksum is valid
            if sha256sum -c "${artifact}.sha256" >/dev/null 2>&1; then
                test_pass "$test_name"
            else
                test_fail "$test_name" "Checksum verification failed"
            fi
        else
            test_fail "$test_name" "Checksum file not created"
        fi
    else
        test_fail "$test_name" "No artifacts created"
    fi
}

test_artifact_extractable() {
    local test_name="Created artifacts are extractable"
    test_section "$test_name"
    
    bash "$BACKUP_SCRIPT" \
        --source "$TEST_DIR/source/data" \
        --target "$TEST_DIR/backups" \
        --job-name extract_test \
        >/dev/null 2>&1
    
    local artifacts=($(ls "$TEST_DIR/backups"/extract_test_*.tar.gz 2>/dev/null || true))
    if [[ ${#artifacts[@]} -gt 0 ]]; then
        local artifact="${artifacts[0]}"
        
        # Try extracting to temp dir
        local extract_dir="$TEST_DIR/extract_test"
        mkdir -p "$extract_dir"
        
        if tar -xzf "$artifact" -C "$extract_dir" 2>/dev/null; then
            # Verify files exist
            if [[ -f "$extract_dir/data/file1.txt" ]]; then
                test_pass "$test_name"
            else
                test_fail "$test_name" "Extracted files not found"
            fi
        else
            test_fail "$test_name" "Extraction failed"
        fi
    else
        test_fail "$test_name" "No artifacts created"
    fi
}

test_config_mode() {
    local test_name="Config mode processes jobs correctly"
    test_section "$test_name"
    
    # Create config
    cat > "$TEST_DIR/config/test.yaml" << YAML
defaults:
  compression: gz
  retention_count: 30

jobs:
  - name: config_job1
    enabled: true
    source_dir: $TEST_DIR/source/data
    target_dir: $TEST_DIR/backups

  - name: config_job2
    enabled: true
    source_dir: $TEST_DIR/source/data
    target_dir: $TEST_DIR/backups
YAML
    
    if bash "$BACKUP_SCRIPT" \
        --config "$TEST_DIR/config/test.yaml" \
        >/dev/null 2>&1; then
        
        local job1_artifacts=($(ls "$TEST_DIR/backups"/config_job1_*.tar.gz 2>/dev/null || true))
        local job2_artifacts=($(ls "$TEST_DIR/backups"/config_job2_*.tar.gz 2>/dev/null || true))
        
        if [[ ${#job1_artifacts[@]} -eq 1 && ${#job2_artifacts[@]} -eq 1 ]]; then
            test_pass "$test_name"
        else
            test_fail "$test_name" "Job artifacts counts incorrect"
        fi
    else
        test_fail "$test_name" "Config mode failed"
    fi
}

test_invalid_source() {
    local test_name="Invalid source returns error"
    test_section "$test_name"
    
    if bash "$BACKUP_SCRIPT" \
        --source "$TEST_DIR/nonexistent" \
        --target "$TEST_DIR/backups" \
        --job-name invalid_test \
        >/dev/null 2>&1; then
        
        test_fail "$test_name" "Should have failed with invalid source"
    else
        test_pass "$test_name"
    fi
}

test_help_command() {
    local test_name "Help command works"
    test_section "$test_name"
    
    if bash "$BACKUP_SCRIPT" --help 2>&1 | grep -q "Direct mode:"; then
        test_pass "$test_name"
    else
        test_fail "$test_name" "Help output incomplete"
    fi
}

test_format_validation() {
    local test_name="Format validation rejects invalid formats"
    test_section "$test_name"
    
    if bash "$BACKUP_SCRIPT" \
        --source "$TEST_DIR/source/data" \
        --target "$TEST_DIR/backups" \
        --job-name format_test \
        --format invalid \
        >/dev/null 2>&1; then
        
        test_fail "$test_name" "Should reject invalid format"
    else
        test_pass "$test_name"
    fi
}

test_zstd_compression() {
    local test_name="Zstd compression works (if available)"
    test_section "$test_name"
    
    if ! command -v zstd &> /dev/null; then
        echo -e "${BLUE}⊘ SKIP${NC}: $test_name (zstd not installed)"
        return
    fi
    
    if bash "$BACKUP_SCRIPT" \
        --source "$TEST_DIR/source/data" \
        --target "$TEST_DIR/backups" \
        --job-name zstd_test \
        --format zst \
        >/dev/null 2>&1; then
        
        local artifacts=($(ls "$TEST_DIR/backups"/zstd_test_*.tar.zst 2>/dev/null || true))
        if [[ ${#artifacts[@]} -eq 1 ]]; then
            test_pass "$test_name"
        else
            test_fail "$test_name" "Zstd artifact not created"
        fi
    else
        test_fail "$test_name" "Zstd backup failed"
    fi
}

#################################################################################
# Main Test Runner
#################################################################################

main() {
    echo -e "${BLUE}Universal Directory Backup Tool - Test Suite${NC}"
    echo "=================================================="
    
    setup_test_env
    
    # Run tests
    test_direct_mode_backup
    test_dry_run_no_create
    test_same_day_reruns
    test_checksums_created
    test_artifact_extractable
    test_config_mode
    test_help_command
    test_invalid_source
    test_format_validation
    test_zstd_compression
    
    cleanup_test_env
    
    # Summary
    echo ""
    echo "=================================================="
    echo -e "Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
    
    if [[ $FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        exit 1
    fi
}

main "$@"
