#!/usr/bin/env bash
# Create the production .env on the VM with fresh random secrets.
#
# Usage: scripts/init-env.sh [--force]
#   --force  overwrite an existing .env. Only safe BEFORE the database volume exists:
#            MariaDB keeps the passwords it was first started with (see docs/deploy.md,
#            "Rotating secrets").
#
# Writes /srv/drupal-imagine-demo/.env (mode 600, owned by azureuser). The secrets are generated
# on the VM with openssl and never leave it.
# shellcheck disable=SC2034  # some variables only reach the VM through remote_vars
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

FORCE=0
case "${1:-}" in
  --force) FORCE=1 ;;
  -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
  "") ;;
  *) die "unknown option: $1" ;;
esac

need_vm
{ remote_vars APP_DIR SOURCE_DIR_REMOTE FORCE; cat <<'REMOTE'
# shellcheck disable=SC2034  # some variables only reach the VM through remote_vars
set -euo pipefail
mkdir -p "$APP_DIR"
env_file="$APP_DIR/.env"
if [ -e "$env_file" ] && [ "$FORCE" != 1 ]; then
  echo "$env_file already exists; not touching it (use --force)"; exit 0
fi
umask 077
cat > "$env_file" <<ENV
# Production settings for cms.storyheroapp.com. Generated $(date -u +%FT%TZ). Never commit.
DB_NAME=drupal
DB_USER=drupal
DB_PASSWORD=$(openssl rand -hex 24)
DB_ROOT_PASSWORD=$(openssl rand -hex 24)
HASH_SALT=$(openssl rand -base64 48 | tr -d '\n=' | tr '+/' '-_')
TRUSTED_HOSTS='^cms\.storyheroapp\.com\$'
IMAGINE_SOURCE=$SOURCE_DIR_REMOTE
TLS_DIR=/etc/imagine/tls
UID=$(id -u)
GID=$(id -g)
ENV
chmod 600 "$env_file"
echo "Wrote $env_file:"
sed -E 's/^(DB_PASSWORD|DB_ROOT_PASSWORD|HASH_SALT)=.*/\1=<secret>/' "$env_file"
REMOTE
} | vm_script
