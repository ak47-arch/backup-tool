#!/bin/bash

#################################################################################
# Universal Directory Backup Tool
# Version: 2.0 (All 4 Milestones)
# Purpose: Create daily compressed backups with rolling retention for any file or directory
#################################################################################

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=false
DRY_RUN=false
CONFIG_FILE=""
DIRECT_SOURCE=""
DIRECT_TARGET=""
DIRECT_JOB_NAME=""
FORMAT="gz"
RETENTION_COUNT=30
FILTER_JOB=""
FAILED_JOBS=()
SUCCESSFUL_JOBS=()

#################################################################################
# Logging Functions
#################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $*" >&2
    fi
}

#################################################################################
# Validation Functions
#################################################################################

validate_source() {
    local source="$1"
    if [[ ! -e "$source" ]]; then
        log_error "Source path does not exist: $source"
        return 1
    fi
    if [[ ! -r "$source" ]]; then
        log_error "Source path is not readable: $source"
        return 1
    fi
    return 0
}

validate_target() {
    local target="$1"
    
    # Check if target exists
    if [[ -d "$target" ]]; then
        if [[ ! -w "$target" ]]; then
            log_error "Target directory is not writable: $target"
            return 1
        fi
    else
        # Try to create parent directory
        local parent_dir="$(dirname "$target")"
        if [[ ! -d "$parent_dir" ]]; then
            log_error "Parent directory of target does not exist: $parent_dir"
            return 1
        fi
        if [[ ! -w "$parent_dir" ]]; then
            log_error "Parent directory of target is not writable: $parent_dir"
            return 1
        fi
    fi
    return 0
}

validate_retention_count() {
    local count="$1"
    if ! [[ "$count" =~ ^[0-9]+$ ]] || [[ "$count" -lt 1 ]]; then
        log_error "Retention count must be a positive integer, got: $count"
        return 1
    fi
    return 0
}

validate_format() {
    local fmt="$1"
    if [[ "$fmt" != "gz"  && "$fmt" != "zst" ]]; then
        log_error "Invalid format: $fmt (must be gz or zst)"
        return 1
    fi
    return 0
}

#################################################################################
# Backup Functions
#################################################################################

get_timestamp() {
    date +"%Y%m%d_%H%M%S"
}

get_archive_extension() {
    local fmt="$1"
    if [[ "$fmt" == "gz" ]]; then
        echo "tar.gz"
    elif [[ "$fmt" == "zst" ]]; then
        echo "tar.zst"
    fi
}

create_backup_artifact() {
    local source="$1"
    local target_dir="$2"
    local job_name="$3"
    local format="$4"
    local excludes=("${@:5}")
    
    local timestamp=$(get_timestamp)
    local ext=$(get_archive_extension "$format")
    local artifact_name="${job_name}_${timestamp}.${ext}"
    local artifact_path="${target_dir}/${artifact_name}"
    local temp_artifact="${artifact_path}.tmp"
    
    # Ensure target directory exists
    mkdir -p "$target_dir" || {
        log_error "Failed to create target directory: $target_dir"
        return 1
    }
    
    local start_time=$(date +%s)
    
    # Build tar command with excludes
    local tar_cmd="tar"
    
    if [[ "$format" == "gz" ]]; then
        tar_cmd="$tar_cmd -czf"
    elif [[ "$format" == "zst" ]]; then
        tar_cmd="$tar_cmd -c --zstd -f"
    fi
    
    # Add source and temp path
    tar_cmd="$tar_cmd '$temp_artifact' -C '$(dirname "$source")' '$(basename "$source")'"
    
    # Add excludes
    for exclude in "${excludes[@]}"; do
        tar_cmd="$tar_cmd --exclude='$exclude'"
    done
    
    log_verbose "Tar command: $tar_cmd"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would create artifact: $artifact_path"
        return 0
    fi
    
    # Run tar command
    if eval "$tar_cmd"; then
        # Atomic rename
        mv "$temp_artifact" "$artifact_path" || {
            log_error "Failed to finalize artifact: $artifact_path"
            rm -f "$temp_artifact"
            return 1
        }
        
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local size=$(du -h "$artifact_path" | cut -f1)
        
        log_success "Backup created: $artifact_path (Size: $size, Duration: ${duration}s)"
        echo "$artifact_path"
        return 0
    else
        log_error "Failed to create backup artifact for job: $job_name"
        rm -f "$temp_artifact"
        return 1
    fi
}

create_checksum() {
    local artifact="$1"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would create checksum for: $artifact"
        return 0
    fi
    
    local checksum_file="${artifact}.sha256"
    if sha256sum "$artifact" > "$checksum_file"; then
        log_verbose "Created checksum: $checksum_file"
        return 0
    else
        log_warn "Failed to create checksum for: $artifact"
        return 1
    fi
}

#################################################################################
# Retention Functions
#################################################################################

get_managed_artifacts() {
    local target_dir="$1"
    local job_name="$2"
    
    if [[ ! -d "$target_dir" ]]; then
        return 0
    fi
    
    # Find artifacts matching job pattern: job_name_YYYYMMDD_HHMMSS.tar.gz or .tar.zst
    find "$target_dir" -maxdepth 1 -type f \
        \( -name "${job_name}_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].tar.gz" \
        -o -name "${job_name}_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].tar.zst" \) \
        | sort
}

enforce_retention() {
    local target_dir="$1"
    local job_name="$2"
    local retention_count="$3"
    
    local artifacts=($(get_managed_artifacts "$target_dir" "$job_name"))
    local total_count=${#artifacts[@]}
    
    if [[ $total_count -le $retention_count ]]; then
        log_verbose "Retention enforced: $total_count artifacts (within limit of $retention_count)"
        return 0
    fi
    
    local to_delete=$((total_count - retention_count))
    log_info "Pruning $to_delete oldest artifacts for job: $job_name (keeping $retention_count)"
    
    for ((i=0; i<$to_delete; i++)); do
        local artifact="${artifacts[$i]}"
        
        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY-RUN] Would delete: $artifact"
            # Also log checksum deletion
            if [[ -f "${artifact}.sha256" ]]; then
                log_info "[DRY-RUN] Would delete: ${artifact}.sha256"
            fi
        else
            log_verbose "Deleting: $artifact"
            rm -f "$artifact"
            
            # Also delete associated checksum if it exists
            if [[ -f "${artifact}.sha256" ]]; then
                rm -f "${artifact}.sha256"
            fi
        fi
    done
    
    return 0
}

#################################################################################
# Config File Parsing
#################################################################################

parse_yaml_value() {
    local line="$1"
    local key="$2"

    local trimmed="$line"
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    [[ "$trimmed" == "- "* ]] && trimmed="${trimmed#- }"

    if [[ "$trimmed" == "$key:"* ]]; then
        local value="${trimmed#*:}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        value="${value%\"}"
        value="${value#\"}"
        echo "$value"
        return 0
    fi
    return 1
}

is_job_section() {
    local line="$1"
    [[ "$line" == "  - name:"* ]]
}

is_list_start() {
    local line="$1"
    [[ "$line" == "jobs:" ]]
}

process_config_file() {
    local config="$1"
    
    if [[ ! -f "$config" ]]; then
        log_error "Config file not found: $config"
        return 1
    fi
    
    log_verbose "Processing config file: $config"
    
    # Parse defaults
    local default_compression="gz"
    local default_retention=30
    local default_enabled=true
    
    local in_defaults=false
    local in_jobs=false
    local in_job=false
    
    local job_name=""
    local job_enabled=true
    local job_source=""
    local job_target=""
    local job_compression=""
    local job_retention=""
    local job_excludes=()
    
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        
        # Detect sections
        if [[ "$line" == "defaults:" ]]; then
            in_defaults=true
            in_jobs=false
            continue
        fi
        
        if [[ "$line" == "jobs:" ]]; then
            in_defaults=false
            in_jobs=true
            continue
        fi
        
        # Parse defaults section
        if [[ "$in_defaults" == true ]]; then
            local value
            if value=$(parse_yaml_value "$line" "compression"); then
                default_compression="$value"
            fi
            if value=$(parse_yaml_value "$line" "retention_count"); then
                default_retention="$value"
            fi
            if value=$(parse_yaml_value "$line" "enabled"); then
                default_enabled="$value"
            fi
        fi
        
        # Detect job start
        if is_job_section "$line"; then
            # Save previous job if exists
            if [[ -n "$job_name" ]]; then
                process_job "$job_name" "$job_enabled" "$job_source" "$job_target" \
                    "$job_compression" "$job_retention" "${job_excludes[@]}"
                job_excludes=()
            fi
            
            in_job=true
            job_enabled="$default_enabled"
            job_compression="$default_compression"
            job_retention="$default_retention"
            job_excludes=()
            
            local value
            if value=$(parse_yaml_value "$line" "name"); then
                job_name="$value"
            fi
        fi
        
        # Parse job fields
        if [[ "$in_job" == true ]]; then
            local value
            if value=$(parse_yaml_value "$line" "enabled"); then
                job_enabled="$value"
            fi
            if value=$(parse_yaml_value "$line" "source_dir"); then
                job_source="$value"
            fi
            if value=$(parse_yaml_value "$line" "target_dir"); then
                job_target="$value"
            fi
            if value=$(parse_yaml_value "$line" "compression"); then
                job_compression="$value"
            fi
            if value=$(parse_yaml_value "$line" "retention_count"); then
                job_retention="$value"
            fi
            
            # Parse excludes list
            if [[ "$line" == *"excludes:"* ]]; then
                # Read next lines until we hit a non-exclude line
                while IFS= read -r exclude_line; do
                    # Skip empty lines
                    [[ -z "${exclude_line// }" ]] && continue
                    
                    # Stop if we hit another field
                    if [[ "$exclude_line" == *":"* ]] && [[ ! "$exclude_line" =~ ^[[:space:]]*- ]]; then
                        # This is a new field, break and process it in next iteration
                        # This is a simplification; full implementation would buffer this
                        break
                    fi
                    
                    # Parse exclude pattern
                    if [[ "$exclude_line" =~ ^[[:space:]]*-[[:space:]]*\"(.*)\" ]]; then
                        job_excludes+=("${BASH_REMATCH[1]}")
                    elif [[ "$exclude_line" =~ ^[[:space:]]*-[[:space:]]*(.*) ]]; then
                        job_excludes+=("${BASH_REMATCH[1]}")
                    fi
                done < <(tail -n +$((LINENO+1)) "$config")
            fi
        fi
    done < "$config"
    
    # Process last job
    if [[ -n "$job_name" ]]; then
        process_job "$job_name" "$job_enabled" "$job_source" "$job_target" \
            "$job_compression" "$job_retention" "${job_excludes[@]}"
    fi
}

process_job() {
    local job_name="$1"
    local job_enabled="$2"
    local job_source="$3"
    local job_target="$4"
    local job_compression="$5"
    local job_retention="$6"
    shift 6
    local job_excludes=("$@")
    
    # Skip if job is disabled
    if [[ "$job_enabled" == "false" || "$job_enabled" == "False" ]]; then
        log_verbose "Skipping disabled job: $job_name"
        return 0
    fi
    
    # Skip if filtering and this job doesn't match
    if [[ -n "$FILTER_JOB" && "$job_name" != "$FILTER_JOB" ]]; then
        return 0
    fi
    
    # Use defaults if not specified
    [[ -z "$job_compression" ]] && job_compression="gz"
    [[ -z "$job_retention" ]] && job_retention=30
    
    log_info "Processing job: $job_name"
    
    # Validate job configuration
    if ! validate_source "$job_source"; then
        FAILED_JOBS+=("$job_name")
        return 1
    fi
    
    if ! validate_target "$job_target"; then
        FAILED_JOBS+=("$job_name")
        return 1
    fi
    
    if ! validate_format "$job_compression"; then
        FAILED_JOBS+=("$job_name")
        return 1
    fi
    
    if ! validate_retention_count "$job_retention"; then
        FAILED_JOBS+=("$job_name")
        return 1
    fi
    
    # Create backup
    if create_backup_artifact "$job_source" "$job_target" "$job_name" "$job_compression" "${job_excludes[@]}"; then
        # Create checksum
        local last_artifact=$(get_managed_artifacts "$job_target" "$job_name" | tail -1)
        if [[ -n "$last_artifact" ]]; then
            create_checksum "$last_artifact"
        fi
        
        # Enforce retention
        enforce_retention "$job_target" "$job_name" "$job_retention"
        
        SUCCESSFUL_JOBS+=("$job_name")
    else
        FAILED_JOBS+=("$job_name")
    fi
}

#################################################################################
# Direct Mode Processing
#################################################################################

process_direct_mode() {
    local source="$DIRECT_SOURCE"
    local target="$DIRECT_TARGET"
    local job_name="$DIRECT_JOB_NAME"
    
    log_info "Running in direct mode for job: $job_name"
    
    if ! validate_source "$source"; then
        FAILED_JOBS+=("$job_name")
        return 1
    fi
    
    if ! validate_target "$target"; then
        FAILED_JOBS+=("$job_name")
        return 1
    fi
    
    if ! validate_format "$FORMAT"; then
        FAILED_JOBS+=("$job_name")
        return 1
    fi
    
    if ! validate_retention_count "$RETENTION_COUNT"; then
        FAILED_JOBS+=("$job_name")
        return 1
    fi
    
    # Create backup
    if create_backup_artifact "$source" "$target" "$job_name" "$FORMAT"; then
        # Create checksum
        local last_artifact=$(get_managed_artifacts "$target" "$job_name" | tail -1)
        if [[ -n "$last_artifact" ]]; then
            create_checksum "$last_artifact"
        fi
        
        # Enforce retention
        enforce_retention "$target" "$job_name" "$RETENTION_COUNT"
        
        SUCCESSFUL_JOBS+=("$job_name")
    else
        FAILED_JOBS+=("$job_name")
    fi
}

#################################################################################
# Structured Output
#################################################################################

output_job_summary() {
    local job_name="$1"
    local target_dir="$2"
    
    local artifacts=($(get_managed_artifacts "$target_dir" "$job_name"))
    local retained_count=${#artifacts[@]}
    
    if [[ ${#artifacts[@]} -gt 0 ]]; then
        local latest_artifact="${artifacts[-1]}"
        local size=$(du -h "$latest_artifact" 2>/dev/null | cut -f1)
        echo "  - Job: $job_name"
        echo "    Latest Artifact: $(basename "$latest_artifact")"
        echo "    Size: $size"
        echo "    Retained Count: $retained_count"
    fi
}

output_structured_summary() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY-RUN MODE - No artifacts created"
    fi
    
    echo ""
    echo "=== Backup Summary ==="
    echo "Successful jobs: ${#SUCCESSFUL_JOBS[@]}"
    for job in "${SUCCESSFUL_JOBS[@]}"; do
        echo "  ✓ $job"
    done
    
    if [[ ${#FAILED_JOBS[@]} -gt 0 ]]; then
        echo "Failed jobs: ${#FAILED_JOBS[@]}"
        for job in "${FAILED_JOBS[@]}"; do
            echo "  ✗ $job"
        done
    fi
    echo "===================="
}

#################################################################################
# Help Function
#################################################################################

print_help() {
    cat << EOF
Universal Directory Backup Tool v2.0

USAGE:
  Direct mode:
    $0 --source /path/src --target /path/dst --job-name myjob [OPTIONS]

  Config mode:
    $0 --config /path/jobs.yaml [OPTIONS]

OPTIONS:
  --source PATH         Source file or directory to backup (direct mode)
  --target PATH         Target directory for backups (direct mode)
  --job-name NAME       Unique job name (direct mode)
  --config FILE         YAML config file (config mode)
  --format gz|zst       Compression format (default: gz)
  --retention N         Number of backups to retain (default: 30)
  --job NAME           Filter to specific job from config (config mode)
  --dry-run            Simulate without creating artifacts
  --verbose            Enable verbose logging
  --help               Show this help message

EXAMPLES:
  # Direct mode backup
  $0 --source /data/photos --target /backups/photos --job-name photos

  # Config mode backup
  $0 --config /opt/backup-tool/jobs.yaml

  # Dry-run to see what would happen
  $0 --config /opt/backup-tool/jobs.yaml --dry-run --verbose

  # Backup specific job with zstd compression
  $0 --config /opt/backup-tool/jobs.yaml --job myapp --format zst

EOF
}

#################################################################################
# Main Function
#################################################################################

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)
                DIRECT_SOURCE="$2"
                shift 2
                ;;
            --target)
                DIRECT_TARGET="$2"
                shift 2
                ;;
            --job-name)
                DIRECT_JOB_NAME="$2"
                shift 2
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --format)
                FORMAT="$2"
                shift 2
                ;;
            --retention)
                RETENTION_COUNT="$2"
                shift 2
                ;;
            --job)
                FILTER_JOB="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                print_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                print_help
                exit 1
                ;;
        esac
    done
    
    # Validate mode selection
    if [[ -n "$CONFIG_FILE" && -n "$DIRECT_SOURCE" ]]; then
        log_error "Cannot use both --config and --source/--target modes"
        exit 1
    fi
    
    if [[ -z "$CONFIG_FILE" && -z "$DIRECT_SOURCE" ]]; then
        log_error "Must specify either --config or --source/--target"
        print_help
        exit 1
    fi
    
    # Validate format
    if ! validate_format "$FORMAT"; then
        exit 1
    fi
    
    # Validate retention count
    if ! validate_retention_count "$RETENTION_COUNT"; then
        exit 1
    fi
    
    # Execute appropriate mode
    if [[ -n "$CONFIG_FILE" ]]; then
        process_config_file "$CONFIG_FILE"
    else
        # Validate direct mode inputs
        if [[ -z "$DIRECT_SOURCE" || -z "$DIRECT_TARGET" || -z "$DIRECT_JOB_NAME" ]]; then
            log_error "Direct mode requires: --source, --target, and --job-name"
            exit 1
        fi
        process_direct_mode
    fi
    
    # Output summary
    output_structured_summary
    
    # Exit with appropriate code
    if [[ ${#FAILED_JOBS[@]} -gt 0 ]]; then
        exit 1
    fi
    
    exit 0
}

# Run main if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
