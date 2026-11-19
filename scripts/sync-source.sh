#!/usr/bin/env bash
# Copy the Imagine Alice content (the only books settings.php imports) to the VM.
#
# Usage: scripts/sync-source.sh [CONTENT_DIR]
#   CONTENT_DIR  local Imagine content folder (default: ~/Developer/imagine/content)
#
# Sends classics/<slug>/ and text/<slug>.json for the three Alice books to
# /srv/imagine-source on the VM, keeping the same layout (compose mounts it read-only into php).
# rsync, so re-running only sends what changed; files deleted locally are deleted remotely.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

CONTENT_DIR="${1:-$HOME/Developer/imagine/content}"
BOOKS=(alice-in-wonderland alice-au-pays-des-merveilles alice-im-wunderland)

paths=()
for b in "${BOOKS[@]}"; do
  [ -d "$CONTENT_DIR/classics/$b" ] || die "missing $CONTENT_DIR/classics/$b"
  [ -f "$CONTENT_DIR/text/$b.json" ] || die "missing $CONTENT_DIR/text/$b.json"
  paths+=("classics/$b" "text/$b.json")
done

need_vm
echo "Syncing ${#BOOKS[@]} books from $CONTENT_DIR to $VM_HOST:$SOURCE_DIR_REMOTE"
# Relative paths from inside CONTENT_DIR + --relative keep classics/ and text/ (works with
# GNU rsync and macOS openrsync alike).
cd "$CONTENT_DIR"
rsync -az --relative --delete --stats \
  --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r --exclude=.DS_Store \
  -e "ssh $(printf '%q ' "${SSH_OPTS[@]}")" \
  "${paths[@]}" "$VM_USER@$VM_HOST:$SOURCE_DIR_REMOTE/"
vm_ssh "du -sh $SOURCE_DIR_REMOTE; ls $SOURCE_DIR_REMOTE/classics $SOURCE_DIR_REMOTE/text"
