#!/usr/bin/env bash
# scripts/setup-backup.sh
#
# Idempotently turns scheduled restic backups on for this VM: writes the
# restic repository credentials, the list of paths to back up, a small run
# script, and a systemd timer/service pair that invokes it every 2 hours.
#
# Safe to re-run: re-writing the env/paths/run-script/unit files is
# harmless, and `restic init` only runs when `restic snapshots` reports the
# repository isn't yet initialized (so a second run never re-inits an
# already-initialized repo).
#
# Required environment (already exported by the caller -- see
# scripts/lib/host-config.sh -- this script never reads hosts/ itself):
#   WASABI_ENDPOINT WASABI_BUCKET WASABI_PREFIX
#   WASABI_RW_ACCESS_KEY WASABI_RW_SECRET_KEY RESTIC_PASSWORD
#   RETENTION_HOURLY RETENTION_DAILY RETENTION_WEEKLY
#   BACKUP_PATHS (newline-joined list of paths to back up)
#
# Testable side effects are redirected under these env-var-overridable
# roots (defaults match where they'd really live on the VM):
#   VM_BACKUP_ETC      -- env file + paths file
#   SYSTEMD_UNIT_DIR   -- vm-backup.service / vm-backup.timer
#   VM_BACKUP_BIN_DIR  -- vm-backup-run.sh
set -euo pipefail

_SETUP_BACKUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
# shellcheck disable=SC1091
source "$_SETUP_BACKUP_LIB_DIR/os-detect.sh"
# shellcheck disable=SC1091
source "$_SETUP_BACKUP_LIB_DIR/install-restic.sh"

VM_BACKUP_ETC="${VM_BACKUP_ETC:-/etc/vm-backup}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
VM_BACKUP_BIN_DIR="${VM_BACKUP_BIN_DIR:-/usr/local/bin}"

# The retention values are baked literally into the generated run script
# below, so refuse anything but a plain non-negative integer up front,
# before anything is installed or written.
for retention_var in RETENTION_HOURLY RETENTION_DAILY RETENTION_WEEKLY; do
  case "${!retention_var}" in
    ''|*[!0-9]*)
      echo "setup-backup.sh: $retention_var must be a non-negative integer, got: ${!retention_var}" >&2
      exit 1
      ;;
  esac
done

install_restic

mkdir -p "$VM_BACKUP_ETC" "$SYSTEMD_UNIT_DIR" "$VM_BACKUP_BIN_DIR"

RESTIC_REPOSITORY="s3:${WASABI_ENDPOINT}/${WASABI_BUCKET}/${WASABI_PREFIX}"
export RESTIC_REPOSITORY
export AWS_ACCESS_KEY_ID="$WASABI_RW_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$WASABI_RW_SECRET_KEY"
export RESTIC_PASSWORD="$RESTIC_PASSWORD"

# --- env file: holds the Wasabi RW credential and the restic password, so
# it must land at mode 0600 with no window where it's readable at a wider
# mode or where a pre-planted symlink at the target path gets written
# through. `mktemp` opens its file with mode 0600 at creation time (not via
# a later chmod), the explicit chmod below is just defense in depth, and the
# final `mv` within the same directory is an atomic rename -- it replaces
# whatever (file or symlink) sits at the destination rather than following
# it, and there is no instant at which the real path holds a partially
# written or wrong-mode file. ---
umask 077
tmp_env="$(mktemp "$VM_BACKUP_ETC/.env.XXXXXX")"
cat > "$tmp_env" <<ENVFILE
RESTIC_REPOSITORY=${RESTIC_REPOSITORY}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
RESTIC_PASSWORD=${RESTIC_PASSWORD}
ENVFILE
chmod 600 "$tmp_env"
mv -f "$tmp_env" "$VM_BACKUP_ETC/env"

# --- paths file: not secret, no special mode needed ---
tmp_paths="$(mktemp "$VM_BACKUP_ETC/.paths.XXXXXX")"
printf '%s\n' "$BACKUP_PATHS" > "$tmp_paths"
mv -f "$tmp_paths" "$VM_BACKUP_ETC/paths.txt"

# --- run script: the retention numbers are baked in literally (so they're
# visible in the published script and don't depend on any env var being set
# at run time); the restic repository/credentials are NOT baked in here --
# they come from the systemd-sourced EnvironmentFile below, so this file
# never contains a secret.
#
# ONE `restic backup --files-from` call per run, never one call per path:
# each `restic backup` invocation makes its own snapshot, and restore.sh
# restores `latest` -- the single newest snapshot. With one snapshot per
# path, `latest` would be just the last path's snapshot and a restore would
# silently bring back only that one path. A single call makes every run
# exactly one snapshot covering every path, so `latest` is the whole host.
#
# restic exits 3 when it did save a snapshot but couldn't read some source
# files (a file vanished or is unreadable mid-run). That snapshot is real
# and usable, so pruning must still happen -- otherwise one persistently
# unreadable file would stop `forget` from ever running again. The run
# script still exits 3 afterwards, so systemd records the run as failed.
# Any other non-zero exit (no snapshot saved: repo unreachable, bad
# credential, ...) skips `forget` and exits straight away. (A path listed
# in paths.txt that doesn't exist at all is only warned about by restic and
# skipped; the rest are still backed up.) ---
tmp_run="$(mktemp "$VM_BACKUP_BIN_DIR/.vm-backup-run.XXXXXX")"
cat > "$tmp_run" <<RUNSCRIPT
#!/usr/bin/env bash
set -euo pipefail

backup_rc=0
restic backup --files-from "${VM_BACKUP_ETC}/paths.txt" || backup_rc=\$?
if [ "\$backup_rc" -ne 0 ] && [ "\$backup_rc" -ne 3 ]; then
  exit "\$backup_rc"
fi

restic forget --prune --keep-hourly ${RETENTION_HOURLY} --keep-daily ${RETENTION_DAILY} --keep-weekly ${RETENTION_WEEKLY}

exit "\$backup_rc"
RUNSCRIPT
chmod 755 "$tmp_run"
mv -f "$tmp_run" "$VM_BACKUP_BIN_DIR/vm-backup-run.sh"

# --- systemd unit pair ---
cat > "$SYSTEMD_UNIT_DIR/vm-backup.service" <<SERVICE
[Unit]
Description=vm-backup restic backup

[Service]
Type=oneshot
EnvironmentFile=${VM_BACKUP_ETC}/env
ExecStart=${VM_BACKUP_BIN_DIR}/vm-backup-run.sh
SERVICE

cat > "$SYSTEMD_UNIT_DIR/vm-backup.timer" <<TIMER
[Unit]
Description=Run vm-backup every 2 hours

[Timer]
OnCalendar=*-*-* 0/2:00:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER

# --- initialize the repo, once: `restic snapshots` fails on a repository
# that hasn't been `restic init`-ed yet, so use that to decide. ---
if ! restic snapshots >/dev/null 2>&1; then
  restic init
fi

systemctl daemon-reload
systemctl enable --now vm-backup.timer
