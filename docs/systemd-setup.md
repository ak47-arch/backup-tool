# Systemd Service Setup for Backup Tool

This guide sets up the backup tool as a systemd service with automatic scheduling and catchup capability.

## Features

- **Time-based Triggering** - Runs daily at 10:00 PM (22:00)
- **Persistent Scheduling** - Catches up on missed runs if system was offline
- **Automatic Restart** - Restarts on failure
- **Logging** - Full integration with systemd journal
- **Status Monitoring** - Easy status checks and log viewing

## Installation

### 1. Create the Service File

Create `/etc/systemd/system/backup-tool.service`:

```ini
[Unit]
Description=Universal Directory Backup Tool
After=local-fs.target
Wants=backup-tool.timer

[Service]
Type=oneshot
User=root
Group=root
ExecStart=/opt/backup-tool/backup.sh --config /opt/backup-tool/jobs.yaml
StandardOutput=journal
StandardError=journal
SyslogIdentifier=backup-tool
Restart=no

# Ensure logs are saved even if backup fails
StandardOutputDirective=create
StandardErrorDirective=create
```

### 2. Create the Timer File

Create `/etc/systemd/system/backup-tool.timer`:

```ini
[Unit]
Description=Daily Backup Timer
Requires=backup-tool.service

[Timer]
OnCalendar=*-*-* 22:00:00
Persistent=true
Unit=backup-tool.service

[Install]
WantedBy=timers.target
```

### 3. Set Permissions

```bash
sudo chmod 644 /etc/systemd/system/backup-tool.service
sudo chmod 644 /etc/systemd/system/backup-tool.timer
```

### 4. Enable and Start Timer

```bash
# Reload systemd daemon
sudo systemctl daemon-reload

# Enable timer to start at boot
sudo systemctl enable backup-tool.timer

# Start timer immediately
sudo systemctl start backup-tool.timer

# Verify it's running
sudo systemctl status backup-tool.timer
```

## Operations

### Check Timer Status

```bash
sudo systemctl status backup-tool.timer

# Output example:
# ● backup-tool.timer - Daily Backup Timer
#   Loaded: loaded (/etc/systemd/system/backup-tool.timer; enabled; vendor preset: enabled)
#   Active: active (waiting) since Thu 2026-05-04 20:15:42 UTC; 1h 45min ago
#   Trigger: Thu 2026-05-04 22:00:00 UTC; 30min left
#   Triggers: ● backup-tool.service
```

### Check Last Run

```bash
sudo journalctl -u backup-tool.service -n 50 --no-pager

# Or follow logs in real-time (before scheduled run)
sudo journalctl -u backup-tool.service -f
```

### Manual Trigger (for testing)

```bash
# Run the service immediately (doesn't wait for timer)
sudo systemctl start backup-tool.service

# Check it  
sudo systemctl status backup-tool.service -l

# View output
sudo journalctl -u backup-tool.service -n 20 --no-pager
```

### Disable Timer

```bash
sudo systemctl stop backup-tool.timer
sudo systemctl disable backup-tool.timer
```

### Check Next Run Time

```bash
sudo systemctl list-timers backup-tool.timer

# Output example:
# NEXT                        LEFT     LAST                        PASSED   UNIT                 ACTIVATES
# Thu 2026-05-04 22:00:00 UTC 2min 3s  Thu 2026-05-04 22:00:00 UTC now      backup-tool.timer    backup-tool.service
```

## Persistent Scheduling

The timer includes `Persistent=true`, which means:

- If the system is **off at 10 PM**, the backup will run **as soon as the system boots**
- This prevents missed backups when the machine is shut down or sleeping
- The system will catch up on all missed runs

Example scenario:
- Timer scheduled for 10:00 PM daily
- System is powered off from 9 PM Monday to 6 AM Wednesday
- Backup runs immediately at 6 AM Wednesday (catching up Tuesday's missed run)

## Logging and Monitoring

### View All Backup Logs

```bash
sudo journalctl -u backup-tool.service --since "2 days ago"
```

### Log to File (additional logging)

Create `/etc/systemd/system/backup-tool.service.d/override.conf`:

```ini
[Service]
StandardOutput=journal
StandardError=journal
SyslogIdentifier=backup-tool
# Optional: also write to /var/log
ExecStartPost=/usr/bin/logger -t backup-tool -f /var/log/backup-tool.log
```

Then reload:
```bash
sudo systemctl daemon-reload
```

### Monitor Real-Time

```bash
# Watch backups as they run (if you're awake at 10 PM!)
watch -n 5 'sudo journalctl -u backup-tool.service -n 5'
```

## Troubleshooting

### Timer Not Running

```bash
# Check if enabled
sudo systemctl is-enabled backup-tool.timer

# Check if active
sudo systemctl is-active backup-tool.timer

# Check for errors
sudo systemctl status backup-tool.timer -l

# Force reload
sudo systemctl daemon-reload
sudo systemctl restart backup-tool.timer
```

### Service Fails to Start

```bash
# Check service status
sudo systemctl status backup-tool.service

# View detailed logs
sudo journalctl -u backup-tool.service --no-pager -l

# Test configuration manually
/opt/backup-tool/backup.sh --config /opt/backup-tool/jobs.yaml --verbose
```

### Permission Issues

```bash
# Ensure backup user can access jobs.yaml
sudo ls -la /opt/backup-tool/jobs.yaml

# If running as non-root, ensure user has permissions
sudo chown backup:backup /opt/backup-tool/jobs.yaml
sudo chmod 600 /opt/backup-tool/jobs.yaml
```

### Logs Not Appearing

```bash
# Verify systemd logging is enabled
sudo journalctl --verify

# Check systemd configuration
cat /etc/systemd/journald.conf | grep -i storage

# Ensure journal persists across boots
sudo mkdir -p /var/log/journal
sudo systemctl restart systemd-journald
```

## Integration with Monitoring

### Nagios/Icinga Check

```bash
#!/bin/bash
# Check if backup ran in last 25 hours

LAST_RUN=$(sudo journalctl -u backup-tool.service --since "25 hours ago" | tail -1 | wc -l)

if [[ $LAST_RUN -eq 0 ]]; then
    echo "CRITICAL: No backup ran in last 25 hours"
    exit 2
elif grep -q "\[ERROR\]" <(sudo journalctl -u backup-tool.service --since "1 day ago"); then
    echo "WARNING: Backup had errors in last 24 hours"
    exit 1
else
    echo "OK: Backup ran successfully in last 24 hours"
    exit 0
fi
```

### Prometheus Metrics Export

```bash
#!/bin/bash
# Export backup metrics to Prometheus

BACKUP_COUNT=$(ls /backups/*/[0-9]*.tar.gz 2>/dev/null | wc -l)
LAST_RUN=$(sudo journalctl -u backup-tool.service -1 --no-pager | grep "SUCCESS" | tail -1 | cut -d' ' -f1-)

echo "backup_tool_total_artifacts $BACKUP_COUNT"
echo "backup_tool_last_success_timestamp $(date -d "$LAST_RUN" +%s)"
```

## Advanced Configuration

### Run Multiple Times Per Day

Modify `backup-tool.timer`:

```ini
[Timer]
OnCalendar=*-*-* 06:00:00
OnCalendar=*-*-* 14:00:00
OnCalendar=*-*-* 22:00:00
Persistent=true
```

### Different Time in Winter vs Summer

```ini
[Timer]
OnCalendar=*-1-*--*-3-* 21:00:00  # Winter: 9 PM
OnCalendar=*-4-*--*-10-* 22:00:00 # Summer: 10 PM
Persistent=true
```

### Random Jitter (prevent thundering herd)

```ini
[Timer]
OnCalendar=*-*-* 22:00:00
RandomizedDelaySec=5m
Persistent=true
```

This adds up to 5 minutes of random delay to the scheduled time.

## Migration from Cron

If you previously used cron:

```bash
# Remove from crontab
crontab -e
# Delete the backup line

# Verify it's gone
crontab -l

# Verify systemd timer is working
sudo systemctl status backup-tool.timer
```

The systemd approach is superior because:
- Persistent scheduling catches missed runs
- Better logging integration
- Easier to manage with `systemctl`
- Can be coordinated with other systemd services

## References

- [Systemd Timer Documentation](https://www.freedesktop.org/software/systemd/man/systemd.timer.html)
- [Systemd Service Documentation](https://www.freedesktop.org/software/systemd/man/systemd.service.html)
- [Calendar Format](https://www.freedesktop.org/software/systemd/man/systemd.time.html)
