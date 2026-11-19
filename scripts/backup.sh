#!/usr/bin/env bash
# Back up the database and Drupal files to Azure Blob Storage, from your own machine.
#
# Usage: scripts/backup.sh
#
# 1. Here: mints a 60-minute, write-only, user-delegation SAS for the `backups` container
#    (az, Entra ID login; no account keys). It is sent to the VM over ssh stdin, never stored.
# 2. On the VM, runs scripts/vm-backup.sh: `drush sql-dump --gzip` and a tar of the files volume
#    (minus generated css/js/php caches) into /srv/backups/<UTC timestamp>/, then azcopy to
#    backups/<timestamp>/. The 3 newest local copies are kept; Azure deletes blobs after 30 days.
# The VM also backs itself up daily (scripts/install-backup-timer.sh); this is for ad-hoc backups.
# Prints the timestamp to pass to scripts/restore.sh.
# shellcheck disable=SC2034  # some variables only reach the VM through remote_vars
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

[ $# -eq 0 ] || { sed -n '2,12p' "$0"; exit 0; }

need_vm; need_storage
CONTAINER_URL="https://$STORAGE_ACCOUNT.blob.core.windows.net/$BACKUP_CONTAINER"
SAS="$(container_sas cw 60)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

{ remote_vars APP_DIR CONTAINER_URL SAS TS; cat scripts/vm-backup.sh; } | vm_script

