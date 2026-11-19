#!/usr/bin/env bash
# Shared settings for scripts/*.sh. Sourced, not run. Every value can be overridden from the
# environment, e.g. VM_HOST=1.2.3.4 scripts/deploy.sh
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

RG="${RG:-rg-imagine-demo}"
VM_NAME="${VM_NAME:-vm-imagine-demo}"
VM_USER="${VM_USER:-azureuser}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/imagine_demo}"
APP_DIR="${APP_DIR:-/srv/drupal-imagine-demo}"
SOURCE_DIR_REMOTE="${SOURCE_DIR_REMOTE:-/srv/imagine-source}"
REPO_URL="${REPO_URL:-https://github.com/thaungsunyein/drupal-imagine-demo.git}"
BACKUP_CONTAINER="${BACKUP_CONTAINER:-backups}"

die() { echo "error: $*" >&2; exit 1; }

# need_vm: sets VM_HOST to the VM's public IP (via az) unless already set.
need_vm() {
  if [ -z "${VM_HOST:-}" ]; then
    command -v az >/dev/null || die "az CLI not found; set VM_HOST"
    VM_HOST="$(az vm show -d -g "$RG" -n "$VM_NAME" --query publicIps -o tsv)"
    [ -n "$VM_HOST" ] || die "could not find the public IP of $VM_NAME in $RG"
  fi
}

# need_storage: sets STORAGE_ACCOUNT to the account in $RG unless already set.
need_storage() {
  if [ -z "${STORAGE_ACCOUNT:-}" ]; then
    STORAGE_ACCOUNT="$(az storage account list -g "$RG" --query '[0].name' -o tsv)"
    [ -n "$STORAGE_ACCOUNT" ] || die "no storage account in $RG; set STORAGE_ACCOUNT"
  fi
}

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30)

# vm_ssh <remote command...>: run a command on the VM (call need_vm first).
vm_ssh() {
  # shellcheck disable=SC2029  # remote command is meant to be expanded here
  ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_HOST" "$@"
}

# vm_script: run the bash script read from stdin on the VM. It is saved to a private temp file
# first and run with stdin=/dev/null, so commands like `docker compose exec` cannot swallow the
# rest of the script, and secrets in it stay off the process list. The file is removed after.
vm_script() {
  # shellcheck disable=SC2016  # expanded on the VM
  vm_ssh 'f=$(mktemp) && trap "rm -f \"$f\"" EXIT && cat > "$f" && bash "$f" </dev/null'
}

# utc_in_minutes <n>: ISO time n minutes from now (BSD and GNU date).
utc_in_minutes() {
  date -u -v+"$1"M +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "+$1 minutes" +%Y-%m-%dT%H:%MZ
}

# container_sas <permissions> <minutes>: user-delegation SAS (Entra ID, no account key) for the
# backups container. Needs Storage Blob Data Contributor, which infra/main.bicep grants.
container_sas() {
  az storage container generate-sas --auth-mode login --as-user \
    --account-name "$STORAGE_ACCOUNT" --name "$BACKUP_CONTAINER" \
    --permissions "$1" --expiry "$(utc_in_minutes "$2")" --https-only -o tsv
}

# remote_vars NAME...: prints "NAME=<quoted value>" lines to prepend to a script sent over ssh
# stdin, so values (including SAS tokens) never appear in a process list or in git.
remote_vars() {
  local n
  for n in "$@"; do printf '%s=%q\n' "$n" "${!n}"; done
}
