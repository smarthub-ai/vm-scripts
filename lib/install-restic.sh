# scripts/lib/install-restic.sh
#
# Installs a pinned restic release. Source this file, then call
# `install_restic`.

# Reuse ensure_pkg from os-detect.sh rather than duplicating its
# package-manager logic here. Sourcing is idempotent, so this is safe even
# if the caller already sourced os-detect.sh itself.
_INSTALL_RESTIC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_INSTALL_RESTIC_LIB_DIR/os-detect.sh"

RESTIC_VERSION="${RESTIC_VERSION:-0.17.3}"
RESTIC_INSTALL_PATH="${RESTIC_INSTALL_PATH:-/usr/local/bin/restic}"

# _restic_pinned_sha256 <version> <arch>
#
# Prints the published SHA-256 of restic's restic_<version>_linux_<arch>.bz2
# release asset (from that release's SHA256SUMS file), or returns non-zero
# if this version/arch isn't pinned here. Bumping RESTIC_VERSION means
# adding its checksums here, from
# https://github.com/restic/restic/releases/download/v<version>/SHA256SUMS
_restic_pinned_sha256() {
  case "$1/$2" in
    0.17.3/amd64) echo "5097faeda6aa13167aae6e36efdba636637f8741fed89bbf015678334632d4d3" ;;
    0.17.3/arm64) echo "db27b803534d301cef30577468cf61cb2e242165b8cd6d8cd6efd7001be2e557" ;;
    *) return 1 ;;
  esac
}

# install_restic
#
# No-op if `restic` is already on PATH. Otherwise ensures curl and bzip2
# (which provides bunzip2; not on every minimal image, e.g. Rocky minimal)
# are present, downloads the pinned restic release (RESTIC_VERSION) for the
# detected CPU architecture, checks it against its pinned SHA-256 (see
# _restic_pinned_sha256; RESTIC_SHA256 overrides, and is required for a
# version not pinned there), decompresses it, and installs it to
# RESTIC_INSTALL_PATH. A checksum mismatch deletes the download and fails
# before anything is decompressed or installed.
install_restic() {
  if command -v restic >/dev/null 2>&1; then
    return 0
  fi

  ensure_pkg curl
  ensure_pkg bzip2

  local machine arch
  machine="$(uname -m)"
  case "$machine" in
    x86_64) arch="amd64" ;;
    aarch64) arch="arm64" ;;
    *)
      echo "install_restic: unsupported architecture: $machine" >&2
      return 1
      ;;
  esac

  local expected_sha256="${RESTIC_SHA256:-}"
  if [ -z "$expected_sha256" ]; then
    if ! expected_sha256="$(_restic_pinned_sha256 "$RESTIC_VERSION" "$arch")"; then
      echo "install_restic: no pinned SHA-256 for restic ${RESTIC_VERSION} (${arch}); set RESTIC_SHA256 to the checksum from that release's SHA256SUMS" >&2
      return 1
    fi
  fi

  # Built from $$ via pure parameter expansion (no `mktemp` call), so the
  # only external commands this function ever shells out to are uname,
  # curl, sha256sum, bunzip2 and install (plus rm, on a checksum mismatch).
  local tmp_bz2="${TMPDIR:-/tmp}/restic-install.$$.bz2"
  local tmp_bin="${tmp_bz2%.bz2}"
  local url="https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_${arch}.bz2"

  curl -fsSL "$url" -o "$tmp_bz2"

  local actual_sha256
  actual_sha256="$(sha256sum "$tmp_bz2")"
  actual_sha256="${actual_sha256%% *}"
  if [ "$actual_sha256" != "$expected_sha256" ]; then
    rm -f "$tmp_bz2"
    echo "install_restic: SHA-256 mismatch for $url (expected $expected_sha256, got $actual_sha256); refusing to install it" >&2
    return 1
  fi

  bunzip2 "$tmp_bz2"
  install -m 0755 "$tmp_bin" "$RESTIC_INSTALL_PATH"
}
