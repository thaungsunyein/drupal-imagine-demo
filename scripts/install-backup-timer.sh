#!/usr/bin/env bash
# Install (or update) the daily backup on the VM, from your own machine.
#
# Usage: scripts/install-backup-timer.sh [--run-now]
#   --run-now  also start one backup right away and show its log
#
# Copies scripts/vm-backup.sh to /usr/local/sbin/imagine-backup, writes /etc/imagine/backup.env
# (container URL only; no secret) and a systemd service + timer that runs it daily at about
# 02:30 UTC as azureuser. azcopy authenticates with the VM's managed identity, which
# infra/main.bicep allows to write to the backups container only.
# Status: systemctl list-timers imagine-backup.timer; logs: journalctl -u imagine-backup
# shellcheck disable=SC2034  # some variables only reach the VM through remote_vars
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

RUN_NOW=0
case "${1:-}" in
  --run-now) RUN_NOW=1 ;;
  -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
  "") ;;
  *) die "unknown option: $1" ;;
esac

need_vm; need_storage
CONTAINER_URL="https://$STORAGE_ACCOUNT.blob.core.windows.net/$BACKUP_CONTAINER"

vm_ssh 'sudo install -m 0755 /dev/stdin /usr/local/sbin/imagine-backup' < scripts/vm-backup.sh

{ remote_vars CONTAINER_URL VM_USER RUN_NOW; cat <<'REMOTE'
# shellcheck disable=SC2034  # some variables only reach the VM through remote_vars
set -euo pipefail
printf 'CONTAINER_URL=%s\n' "$CONTAINER_URL" | sudo tee /etc/imagine/backup.env >/dev/null
sudo tee /etc/systemd/system/imagine-backup.service >/dev/null <<UNIT
[Unit]
Description=Back up Drupal (database + files) to Azure Blob Storage
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
User=$VM_USER
Group=$VM_USER
EnvironmentFile=/etc/imagine/backup.env
ExecStart=/usr/local/sbin/imagine-backup
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=1h
UNIT
sudo tee /etc/systemd/system/imagine-backup.timer >/dev/null <<UNIT
[Unit]
Description=Daily Drupal backup to Azure Blob Storage

[Timer]
OnCalendar=*-*-* 02:30:00 UTC
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now imagine-backup.timer
systemctl list-timers imagine-backup.timer --no-pager
if [ "$RUN_NOW" = 1 ]; then
  echo "Running one backup now..."
  rc=0; sudo systemctl start imagine-backup.service || rc=$?
  journalctl -u imagine-backup --since "-15 min" --no-pager -o cat | tail -20
  exit "$rc"
fi
REMOTE
} | vm_script
