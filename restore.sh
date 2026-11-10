#!/usr/bin/env bash
# scripts/restore.sh
#
# Runs on a freshly recreated VM, before anything else, to pull the last
# backup down from the restic repository over the read-only Wasabi
# credential. Whatever the boot script runs next (the DNS update) must never
# run after a failed restore -- and the operator's later manual
# backup-resume step must not either -- so this script
# deliberately has no error-swallowing: `set -euo pipefail`, no `|| true`
# around the restic call, and no trap that suppresses the exit code. A
# `restic restore` failure (bad credential, network issue, repo doesn't
# exist) propagates straight out as this script's own non-zero exit code.
#
# Required environment (already exported by the caller -- see
# scripts/lib/host-config.sh -- this script never reads hosts/ itself):
#   WASABI_ENDPOINT WASABI_BUCKET WASABI_PREFIX
#   WASABI_RO_ACCESS_KEY WASABI_RO_SECRET_KEY RESTIC_PASSWORD
set -euo pipefail

_RESTORE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
# shellcheck disable=SC1091
source "$_RESTORE_LIB_DIR/os-detect.sh"
# shellcheck disable=SC1091
source "$_RESTORE_LIB_DIR/install-restic.sh"

install_restic

export RESTIC_REPOSITORY="s3:${WASABI_ENDPOINT}/${WASABI_BUCKET}/${WASABI_PREFIX}"
export AWS_ACCESS_KEY_ID="$WASABI_RO_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$WASABI_RO_SECRET_KEY"
export RESTIC_PASSWORD="$RESTIC_PASSWORD"

# --no-lock: by default `restic restore` first writes a shared lock object
# under the repository's locks/ prefix. The read-only Wasabi key this
# script uses can't write anything (that's the point of it), so without
# --no-lock every real restore fails at its first step with "unable to
# create lock in backend: ... permission denied". Skipping the lock is
# safe here: the restore only reads, and the host whose backup job could
# be writing to this repository is the dead one being replaced.
#
# `latest` is the newest snapshot, and that covers every backed-up path
# because the backup run script takes exactly one snapshot per run (see
# setup-backup.sh).
restic restore latest --no-lock --target /
