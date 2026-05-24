#!/bin/bash

#################################################################################
# Installation Script for Universal Directory Backup Tool
#################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_PATH="${1:-/opt/backup-tool}"
SYSTEMD_SETUP="${2:-yes}"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

#################################################################################
# Checks
#################################################################################

check_bash_version() {
    if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
        log_error "Bash 4.0 or higher required (you have $BASH_VERSION)"
        exit 1
    fi
    log_success "Bash version: $BASH_VERSION"
}

check_tar() {
    if ! command -v tar &> /dev/null; then
        log_error "tar not found. Install tar: sudo apt install tar"
        exit 1
    fi
    log_success "tar available"
}

check_root_for_system() {
    if [[ "$INSTALL_PATH" == "/opt/"* ]]; then
        if [[ $EUID -ne 0 ]]; then
            log_error "System-wide installation requires root"
            echo "Run: sudo $0"
            exit 1
        fi
    fi
}

#################################################################################
# Installation
#################################################################################

install_files() {
    log_info "Creating installation directory: $INSTALL_PATH"
    mkdir -p "$INSTALL_PATH"
    mkdir -p "$INSTALL_PATH/examples"
    mkdir -p "$INSTALL_PATH/docs"
    
    log_info "Installing backup.sh"
    cp "$SCRIPT_DIR/backup.sh" "$INSTALL_PATH/"
    chmod 755 "$INSTALL_PATH/backup.sh"
    
    log_info "Installing documentation"
    cp -v "$SCRIPT_DIR/README.md" "$INSTALL_PATH/" || true
    cp -v "$SCRIPT_DIR/CHANGELOG.md" "$INSTALL_PATH/" || true
    cp -v "$SCRIPT_DIR/LICENSE" "$INSTALL_PATH/" || true
    
    log_info "Installing examples"
    cp -v "$SCRIPT_DIR/examples/"*.yaml "$INSTALL_PATH/examples/" 2>/dev/null || true
    
    log_info "Installing docs"
    cp -v "$SCRIPT_DIR/docs/"*.md "$INSTALL_PATH/docs/" 2>/dev/null || true
    
    log_success "Files installed to: $INSTALL_PATH"
}

setup_backups_directory() {
    local backup_dir="/backups"
    if [[ ! -d "$backup_dir" ]]; then
        log_info "Creating backups directory: $backup_dir"
        mkdir -p "$backup_dir"
        chmod 755 "$backup_dir"
    fi
    log_success "Backups directory ready: $backup_dir"
}

setup_systemd() {
    if [[ "$SYSTEMD_SETUP" != "yes" ]]; then
        log_info "Skipping systemd setup"
        return
    fi
    
    if [[ ! -d /etc/systemd/system ]]; then
        log_warn "Systemd not found, skipping service setup"
        return
    fi
    
    log_info "Installing systemd service files"
    
    # Service file
    cat > /etc/systemd/system/backup-tool.service << 'UNIT'
[Unit]
Description=Universal Directory Backup Tool
After=local-fs.target

[Service]
Type=oneshot
User=root
ExecStart=/opt/backup-tool/backup.sh --config /opt/backup-tool/jobs.yaml
StandardOutput=journal
StandardError=journal
SyslogIdentifier=backup-tool

[Install]
WantedBy=multi-user.target
UNIT
    log_success "Created /etc/systemd/system/backup-tool.service"
    
    # Timer file
    cat > /etc/systemd/system/backup-tool.timer << 'TIMER'
[Unit]
Description=Daily Backup Timer
Requires=backup-tool.service

[Timer]
OnCalendar=*-*-* 22:00:00
Persistent=true
Unit=backup-tool.service

[Install]
WantedBy=timers.target
TIMER
    log_success "Created /etc/systemd/system/backup-tool.timer"
    
    # Reload and enable
    log_info "Reloading systemd daemon"
    systemctl daemon-reload
    
    log_info "Enabling backup-tool.timer"
    systemctl enable backup-tool.timer
    
    log_info "Starting backup-tool.timer"
    systemctl start backup-tool.timer
    
    log_success "Systemd timer installed and started"
    log_info "Check status: systemctl status backup-tool.timer"
}

create_default_config() {
    local config_file="$INSTALL_PATH/jobs.yaml"
    
    if [[ -f "$config_file" ]]; then
        log_warn "Config already exists: $config_file"
        return
    fi
    
    log_info "Creating default configuration"
    cat > "$config_file" << 'YAML'
defaults:
  compression: gz
  retention_count: 30
  enabled: true

jobs:
  # Example: Application data
  - name: app_data
    enabled: true
    source_dir: /srv/myapp/data
    target_dir: /backups/app_data
    compression: gz
    retention_count: 30
    excludes:
      - "*.tmp"
      - "cache/*"

  # Example: System configuration
  - name: etc_backup
    enabled: true
    source_dir: /etc
    target_dir: /backups/etc
    compression: gz
    retention_count: 120
YAML
    
    chmod 600 "$config_file"
    log_success "Created default configuration: $config_file"
    log_warn "Edit this file to add your backup jobs"
}

#################################################################################
# Verification
#################################################################################

verify_installation() {
    log_info "Verifying installation"
    
    if [[ ! -x "$INSTALL_PATH/backup.sh" ]]; then
        log_error "Backup script not executable"
        return 1
    fi
    
    # Test help
    if ! "$INSTALL_PATH/backup.sh" --help >/dev/null 2>&1; then
        log_error "Help command failed"
        return 1
    fi
    
    # Test dry-run
    if ! "$INSTALL_PATH/backup.sh" --source /tmp --target /tmp --job-name test --dry-run >/dev/null 2>&1; then
        log_error "Dry-run test failed"
        return 1
    fi
    
    log_success "Installation verified"
    return 0
}

#################################################################################
# Main
#################################################################################

main() {
    echo -e "${BLUE}Universal Directory Backup Tool - Installation${NC}"
    echo "=================================================="
    
    check_bash_version
    check_tar
    check_root_for_system
    
    install_files
    setup_backups_directory
    setup_systemd
    create_default_config
    
    if verify_installation; then
        echo ""
        echo -e "${GREEN}Installation complete!${NC}"
        echo ""
        echo "Next steps:"
        echo "1. Edit configuration: $INSTALL_PATH/jobs.yaml"
        echo "2. Test backup: $INSTALL_PATH/backup.sh --config $INSTALL_PATH/jobs.yaml --dry-run"
        echo "3. Run backup: $INSTALL_PATH/backup.sh --config $INSTALL_PATH/jobs.yaml"
        echo ""
        
        if [[ "$SYSTEMD_SETUP" == "yes" && -d /etc/systemd/system ]]; then
            echo "Systemd timer installed:"
            echo "  - Check status: systemctl status backup-tool.timer"
            echo "  - View logs: journalctl -u backup-tool.service -n 50"
            echo "  - Manual run: systemctl start backup-tool.service"
        fi
    else
        log_error "Installation verification failed"
        exit 1
    fi
}

main "$@"
