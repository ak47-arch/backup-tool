# Universal Directory Backup Tool

Full-featured, standalone backup utility for creating daily compressed backups of arbitrary directories with automatic rolling retention.

## Features

✓ **Direct and Config Modes** - Backup single directory or manage multiple jobs via YAML config  
✓ **Multiple Compressions** - tar.gz (default) or zstd for better compression  
✓ **Automatic Retention** - Keep latest N backups per job, automatically prune oldest  
✓ **Safe & Atomic** - Temporary file + atomic rename prevents partial artifacts  
✓ **Checksums** - Optional SHA256 checksums for integrity verification  
✓ **Excludes** - Skip patterns per job (e.g., `*.tmp`, `cache/*`)  
✓ **Structured Output** - Per-job summaries with artifact paths, sizes, retention counts  
✓ **Dry-Run Mode** - Preview what would happen without creating artifacts  
✓ **Verbose Logging** - Detailed logs for unattended scheduler runs  
✓ **Scheduling Ready** - Designed for cron or systemd timers with catchup support  

## Installation

### Option 1: System-wide Installation

```bash
sudo mkdir -p /opt/backup-tool/{examples,docs}
sudo cp backup.sh /opt/backup-tool/
sudo chmod 755 /opt/backup-tool/backup.sh
```

### Option 2: Local Installation

```bash
mkdir -p ~/backup-tool
cp backup.sh ~/backup-tool/
chmod 755 ~/backup-tool/backup.sh
```

## Quick Start

### Direct Mode - Single Directory

```bash
./backup.sh --source /data/photos --target /backups/photos --job-name photos
```

### Config Mode - Multiple Directories

Create `jobs.yaml`:
```yaml
defaults:
  compression: gz
  retention_count: 30
  enabled: true

jobs:
  - name: app_data
    enabled: true
    source_dir: /srv/myapp/data
    target_dir: /backups/app_data
    compression: gz
    retention_count: 30

  - name: database
    enabled: true
    source_dir: /var/lib/postgresql
    target_dir: /backups/database
    compression: zst
    retention_count: 60
    excludes:
      - "*.tmp"
      - "cache/*"
```

Run backup:
```bash
./backup.sh --config jobs.yaml
```

## Usage

### Basic Commands

```bash
# Direct mode
./backup.sh --source /data --target /backups/data --job-name mydata

# Config mode
./backup.sh --config /opt/backup-tool/jobs.yaml

# Backup specific job only
./backup.sh --config /opt/backup-tool/jobs.yaml --job database

# Dry-run (see what would happen)
./backup.sh --config /opt/backup-tool/jobs.yaml --dry-run --verbose

# Use zstd compression (better ratio)
./backup.sh --source /data --target /backups --job-name mydata --format zst

# Custom retention (keep 60 instead of 30)
./backup.sh --config jobs.yaml --retention 60

# Verbose output
./backup.sh --config jobs.yaml --verbose

# Help
./backup.sh --help
```

### Options Reference

| Option | Mode | Description | Default |
|--------|------|-------------|---------|
| `--source PATH` | Direct | Source directory to backup | Required |
| `--target PATH` | Direct | Target directory for backups | Required |
| `--job-name NAME` | Direct | Unique job identifier | Required |
| `--config FILE` | Config | YAML configuration file | - |
| `--format gz\|zst` | Both | Compression format | `gz` |
| `--retention N` | Both | Number of backups to keep | `30` |
| `--job NAME` | Config | Filter to specific job | All jobs |
| `--dry-run` | Both | Simulate without creating | - |
| `--verbose` | Both | Detailed logging | - |
| `--help` | Both | Show help message | - |

## Configuration File Schema

### YAML Structure

```yaml
defaults:
  # Default compression format: gz or zst
  compression: gz
  
  # Default retention count (global override)
  retention_count: 30
  
  # All jobs enabled by default
  enabled: true

jobs:
  - name: job_unique_name
    # Enable/disable this job (inheritance from defaults)
    enabled: true
    
    # Source directory (must exist, must be readable)
    source_dir: /path/to/source
    
    # Target directory for backups (must be writable or creatable)
    target_dir: /path/to/backups
    
    # Compression: gz or zst (overrides defaults)
    compression: gz
    
    # Retention count (overrides defaults)
    retention_count: 30
    
    # Exclude patterns (glob-style)
    excludes:
      - "*.tmp"
      - "*.log"
      - "cache/*"
      - "node_modules/*"
```

### Validation Rules

- Job names are **unique** across config
- Source directory **must exist** and be **readable**
- Target directory **must be writable** (created if needed)
- Retention count **must be ≥ 1** (integer)
- Compression **must be `gz` or `zst`**
- Excludes use **glob patterns**

## Artifact Naming

Artifacts are named deterministically for easy sorting and management:

```
<job>_YYYYMMDD_HHMMSS.tar.gz
```

Example:
```
app_data_20260504_223015.tar.gz
database_20260504_223045.tar.zst
```

### Checksums

Optional SHA256 checksums stored alongside artifacts:
```
app_data_20260504_223015.tar.gz.sha256
```

Content:
```
a1b2c3d4e5f6... app_data_20260504_223015.tar.gz
```

## Scheduling

### Cron Example (daily at 10 PM)

```cron
0 22 * * * /opt/backup-tool/backup.sh --config /opt/backup-tool/jobs.yaml >> /var/log/backup-tool.log 2>&1
```

### Systemd Timer (with catchup)

See [systemd-setup.md](docs/systemd-setup.md) for complete setup.

Key features:
- Runs at 10:00 PM daily
- Catches up if system was off at scheduled time
- Persistent=true ensures missed runs execute on next boot
- Status monitoring with `systemctl status backup-tool.timer`

## Retention Policy

The tool implements robust rolling retention:

1. **Enumeration** - Find all managed artifacts for job (exact prefix + known extensions)
2. **Sorting** - Sort oldest to newest by timestamp
3. **Pruning** - Delete oldest until count equals configured retention
4. **Safety** - Only deletes matching managed artifacts, unrelated files untouched

Example: With retention=30 and 35 artifacts:
- 5 oldest artifacts deleted
- 30 newest retained

Checksums (`.sha256` files) are deleted alongside artifacts.

## Restore Procedures

### Manual Restore from Recent Backup

```bash
# List available backups
ls -lh /backups/app_data/

# Extract backup to staging
mkdir -p /tmp/restore
cd /tmp/restore
tar -xzf /backups/app_data/app_data_20260504_223015.tar.gz

# Verify contents
ls -la

# Restore to live (after validation)
sudo cp -r app_data/* /srv/myapp/data/
```

### Restore with Checksum Verification

```bash
# Verify integrity before extracting
cd /backups/app_data/
sha256sum -c app_data_20260504_223015.tar.gz.sha256

# Extract only if checksum passes
tar -xzf app_data_20260504_223015.tar.gz
```

### Automated Restore (Production Cutover)

```bash
#!/bin/bash
BACKUP_DIR="/backups/app_data"
LATEST_BACKUP=$(ls $BACKUP_DIR/*.tar.gz | sort | tail -1)
STAGING="/tmp/restore"

# Verify backup
sha256sum -c "$LATEST_BACKUP.sha256" || exit 1

# Extract
mkdir -p $STAGING
tar -xzf "$LATEST_BACKUP" -C $STAGING

# Backup current live
sudo cp -r /srv/myapp/data /srv/myapp/data.backup.pre-restore

# Restore
sudo rm -rf /srv/myapp/data/*
sudo cp -r $STAGING/app_data/* /srv/myapp/data/

# Verify
if [[ -f /srv/myapp/data/.sentinel ]]; then
  echo "Restore successful"
  exit 0
else
  echo "Restore failed - rolling back"
  sudo cp -r /srv/myapp/data.backup.pre-restore/* /srv/myapp/data/
  exit 1
fi
```

### Rollback Procedure

```bash
# If restore goes wrong, keep backup of pre-restore state
sudo cp -r /srv/myapp/data /srv/myapp/data.broken
sudo cp -r /srv/myapp/data.backup.pre-restore/* /srv/myapp/data/

# Verify rollback
ls /srv/myapp/data/
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All jobs successful |
| `1` | One or more jobs failed |

Multi-job mode continues all jobs even if one fails, then exits 1 if any failed.

## Logging

### Default Output (stderr)

```
[INFO] Running in direct mode for job: photos
[SUCCESS] Backup created: /backups/photos/photos_20260504_223015.tar.gz (Size: 2.3G, Duration: 45s)
[INFO] Pruning 5 oldest artifacts for job: photos (keeping 30)
=====================
Successful jobs: 1
  ✓ photos
====================
```

### Dry-Run + Verbose

```bash
./backup.sh --config jobs.yaml --dry-run --verbose
```

Output shows exactly what would happen without creating files.

### Syslog Integration for Cron

```cron
# Automatically logged to syslog by cron
0 22 * * * /opt/backup-tool/backup.sh --config /opt/backup-tool/jobs.yaml 2>&1 | logger -t backup-tool
```

Check logs:
```bash
journalctl -u backup-tool.service  # systemd
grep backup-tool /var/log/syslog   # syslog
```

## Troubleshooting

### Job Fails: "Source directory does not exist"

```bash
# Check source actually exists and has correct permissions
ls -la /path/to/source
# Fix: Update config with correct path
```

### Compression Fails: zst command not found

```bash
# Install zstandard
sudo apt-get install zstandard  # Debian/Ubuntu
sudo yum install zstandard      # RHEL/CentOS
brew install zstandard          # macOS

# Test
zstd --version
```

### Permission Denied on Target

```bash
# Ensure backup user can write to target
sudo chown backupuser:backupgroup /backups
sudo chmod 755 /backups

# Or run as user with write permission
sudo -u backupuser /opt/backup-tool/backup.sh --config jobs.yaml
```

### Restore Extracts to Wrong Location

The tool backs up directory contents. When extracting, you get:
```bash
tar -xzf backup.tar.gz -C /target/
# This creates: /target/directoryname/*
```

Account for this in restore scripts:
```bash
tar -xzf backup.tar.gz -C /tmp/
ls /tmp/  # Contains extracted directory name
```

## Testing

Run the test suite:
```bash
bash tests/test_all.sh
```

Tests cover:
- Direct mode backup creation
- Config mode with multiple jobs
- Same-day reruns create separate artifacts
- Retention pruning keeps exactly N artifacts
- Checksums are created and verified
- Unrelated files in target untouched
- Permission denied errors handled correctly
- Dry-run mode doesn't create artifacts

## Performance

Typical performance on modern hardware:

| Size | Compression | Duration |
|------|-------------|----------|
| 100 MB | gz | 2-5 sec |
| 1 GB | gz | 15-30 sec |
| 10 GB | gz | 2-5 min |
| 100 GB | zst | 5-15 min |

For large directories (>50GB), consider:
- Using zst compression (better ratio)
- Increasing retention count if storage permits
- Scheduling at off-peak hours
- Using excludes to skip unnecessary directories

## Security Considerations

1. **File Permissions** - Backup contains source permissions; set umask appropriately
2. **Disk Permission** - Ensure only authorized users can access /backups
3. **Checksum Verification** - Always verify checksums before production restore
4. **Encryption** - For sensitive data, encrypt backups:
   ```bash
   tar -czf - /data | gpg -e > backup.tar.gz.gpg
   ```
5. **Offsite Backups** - Replicate backups to remote storage for disaster recovery

## License

MIT License - See LICENSE file

## Contributing

Feedback and issues welcome. For bug reports:
1. Run with `--dry-run --verbose`
2. Include command and output
3. Include OS and backup size info

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release notes and version history.
