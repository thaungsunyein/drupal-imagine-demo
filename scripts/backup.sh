#!/usr/bin/env bash
# Back up the database and Drupal files to Azure Blob Storage, from your own machine.
#
# Usage: scripts/backup.sh
#
# 1. Here: mints a 60-minute, write-only, user-delegation SAS for the `backups` container
#    (az, Entra ID login; no account keys). It is sent to the VM over ssh stdin, never stored.
# 2. On the VM: `drush sql-dump --gzip` and a tar of the files volume (minus generated css/js/php
#    caches) into /srv/backups/<UTC timestamp>/, then azcopy to backups/<timestamp>/.
#    The 3 newest local copies are kept; Azure deletes blobs after 30 days (lifecycle rule).
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

{ remote_vars APP_DIR CONTAINER_URL SAS TS; cat <<'REMOTE'
# shellcheck disable=SC2034  # some variables only reach the VM through remote_vars
set -euo pipefail
cd "$APP_DIR"
dc() { docker compose -f docker-compose.yml -f docker-compose.prod.yml "$@"; }
dir="/srv/backups/$TS"
mkdir -p "$dir"
echo "Dumping database"
dc exec -T php drush sql-dump --structure-tables-key=common --gzip --result-file="/tmp/db-$TS.sql"
dc cp "php:/tmp/db-$TS.sql.gz" "$dir/db.sql.gz"
dc exec -T php rm -f "/tmp/db-$TS.sql.gz"
echo "Archiving files"
dc exec -T php tar -czf - -C web/sites/default/files \
  --exclude=./css --exclude=./js --exclude=./php . > "$dir/files.tar.gz"
git rev-parse HEAD > "$dir/git-commit.txt"
ls -lh "$dir"
echo "Uploading to $CONTAINER_URL/$TS/"
export AZCOPY_LOG_LOCATION=/tmp/azcopy AZCOPY_JOB_PLAN_LOCATION=/tmp/azcopy
azcopy copy "$dir/*" "$CONTAINER_URL/$TS/?$SAS" --log-level=ERROR --output-level=essential
# Keep the newest 3 local backups.
find /srv/backups -mindepth 1 -maxdepth 1 -type d | sort | head -n -3 | xargs -r rm -rf
REMOTE
} | vm_script

echo "Backup done: $TS"
