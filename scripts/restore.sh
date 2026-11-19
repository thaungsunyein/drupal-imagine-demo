#!/usr/bin/env bash
# Restore the database and Drupal files from a backup in Azure Blob Storage. DESTRUCTIVE.
#
# Usage: scripts/restore.sh [TIMESTAMP|latest] [--yes]
#   TIMESTAMP  a folder in the backups container, as printed by scripts/backup.sh
#              (default: latest). List them: scripts/restore.sh --list
#   --yes      do not ask for confirmation
#
# Mints a 60-minute read/list user-delegation SAS here and sends it over ssh stdin. On the VM:
# downloads backups/<TIMESTAMP>/ with azcopy, drops and re-imports the database, replaces the
# files volume contents, fixes ownership, rebuilds caches. Code is NOT rolled back; the backup's
# commit is in git-commit.txt (deploy that branch/commit first if the schema differs).
# shellcheck disable=SC2034  # some variables only reach the VM through remote_vars
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

TS=latest
YES=0
for arg in "$@"; do
  case "$arg" in
    --yes) YES=1 ;;
    --list) LIST=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) die "unknown option: $arg" ;;
    *) TS="$arg" ;;
  esac
done

list_backups() {
  need_storage
  az storage blob list --auth-mode login --account-name "$STORAGE_ACCOUNT" \
    -c "$BACKUP_CONTAINER" --query "[?ends_with(name,'/db.sql.gz')].name" -o tsv \
    | sed 's#/db.sql.gz$##' | sort
}
if [ "${LIST:-0}" = 1 ]; then list_backups; exit 0; fi
if [ "$TS" = latest ]; then
  TS="$(list_backups | tail -n 1)"
  [ -n "$TS" ] || die "no backups found in $BACKUP_CONTAINER"
fi

need_vm
if [ "$YES" != 1 ]; then
  read -r -p "Replace the database and files on $VM_HOST with backup $TS? Type 'restore': " answer
  [ "$answer" = restore ] || die "aborted"
fi

need_storage
CONTAINER_URL="https://$STORAGE_ACCOUNT.blob.core.windows.net/$BACKUP_CONTAINER"
SAS="$(container_sas rl 60)"

{ remote_vars APP_DIR CONTAINER_URL SAS TS; cat <<'REMOTE'
# shellcheck disable=SC2034  # some variables only reach the VM through remote_vars
set -euo pipefail
cd "$APP_DIR"
dc() { docker compose -f docker-compose.yml -f docker-compose.prod.yml "$@"; }
dir="/srv/backups/restore-$TS"
rm -rf "$dir"; mkdir -p "$dir"
export AZCOPY_LOG_LOCATION=/tmp/azcopy AZCOPY_JOB_PLAN_LOCATION=/tmp/azcopy
azcopy copy "$CONTAINER_URL/$TS/*?$SAS" "$dir/" --log-level=ERROR --output-level=essential
[ -s "$dir/db.sql.gz" ] && [ -s "$dir/files.tar.gz" ] || { echo "error: incomplete backup $TS" >&2; exit 1; }
echo "Backup $TS was taken at commit $(cat "$dir/git-commit.txt" 2>/dev/null || echo unknown); current: $(git rev-parse HEAD)"

echo "Restoring database"
dc exec -T php drush sql:drop -y
gunzip -c "$dir/db.sql.gz" | dc exec -T php drush sql:cli
echo "Restoring files"
dc exec -T -u root php sh -c 'find web/sites/default/files -mindepth 1 -delete'
dc exec -T -u root php tar -xzf - -C web/sites/default/files < "$dir/files.tar.gz"
dc exec -T -u root php chown -R www-data:www-data web/sites/default/files
dc exec -T php drush cache:rebuild
rm -rf "$dir"
echo "Restored $TS"
REMOTE
} | vm_script
