# scripts/lib/os-detect.sh
#
# OS package-manager detection and package installation. Source this file,
# then call `detect_pkg_manager` and/or `ensure_pkg <pkg_name>`.

# Captured once at source time, so that a caller who only overrides
# OS_RELEASE_FILE as a prefix on the `source` command itself (rather than
# exporting it for the rest of the shell) still has that override honored by
# later calls to detect_pkg_manager/ensure_pkg. A later, explicit
# OS_RELEASE_FILE=... prefix on the call itself still takes precedence (see
# detect_pkg_manager below).
_OS_DETECT_OS_RELEASE_FILE_DEFAULT="${OS_RELEASE_FILE:-/etc/os-release}"

# detect_pkg_manager
#
# Prints "apt" or "dnf" to stdout based on the ID/ID_LIKE fields of
# ${OS_RELEASE_FILE:-/etc/os-release}. Exits non-zero with a message on
# stderr if the file is missing or names an unsupported OS.
detect_pkg_manager() {
  local os_release_file="${OS_RELEASE_FILE:-$_OS_DETECT_OS_RELEASE_FILE_DEFAULT}"

  if [ ! -f "$os_release_file" ]; then
    echo "detect_pkg_manager: os-release file not found: $os_release_file" >&2
    return 1
  fi

  # Source in a subshell per field (rather than in this function's scope) so
  # we only ever read ID/ID_LIKE and never leak the file's other vars
  # (NAME, VERSION_ID, PRETTY_NAME, ...) into the caller's shell.
  local id id_like
  id="$(. "$os_release_file" 2>/dev/null; printf '%s' "${ID:-}")"
  id_like="$(. "$os_release_file" 2>/dev/null; printf '%s' "${ID_LIKE:-}")"

  case " $id $id_like " in
    *" ubuntu "*|*" debian "*)
      echo "apt"
      return 0
      ;;
  esac

  case " $id $id_like " in
    *" rocky "*|*" rhel "*|*" fedora "*|*" centos "*|*" almalinux "*)
      echo "dnf"
      return 0
      ;;
  esac

  echo "detect_pkg_manager: unsupported OS (ID=$id, ID_LIKE=$id_like) in $os_release_file" >&2
  return 1
}

# Retry policy for package-manager calls (env-overridable, mainly so tests
# can run without sleeping). On a VM's first boot cloud-init and
# unattended-upgrades commonly hold the apt/dpkg lock for a while; the
# defaults below wait out roughly 5 minutes of that, on top of apt's own
# DPkg::Lock::Timeout wait, before giving up.
ENSURE_PKG_ATTEMPTS="${ENSURE_PKG_ATTEMPTS:-20}"
ENSURE_PKG_RETRY_DELAY="${ENSURE_PKG_RETRY_DELAY:-15}"

# Set once `apt-get update` has succeeded in this process, so package
# lists are refreshed once per script, not once per package. Kept across a
# re-source of this file (install-restic.sh sources it again).
_OS_DETECT_APT_UPDATED="${_OS_DETECT_APT_UPDATED:-0}"

# _ensure_pkg_retry <cmd> [args...]
# Runs <cmd>, retrying up to ENSURE_PKG_ATTEMPTS times in total with
# ENSURE_PKG_RETRY_DELAY seconds between tries. Returns non-zero if every
# attempt fails.
_ensure_pkg_retry() {
  local attempt=1
  until "$@"; do
    if [ "$attempt" -ge "$ENSURE_PKG_ATTEMPTS" ]; then
      echo "ensure_pkg: giving up after $attempt attempt(s): $*" >&2
      return 1
    fi
    echo "ensure_pkg: attempt $attempt failed, retrying in ${ENSURE_PKG_RETRY_DELAY}s: $*" >&2
    sleep "$ENSURE_PKG_RETRY_DELAY"
    attempt=$((attempt + 1))
  done
}

# ensure_pkg <pkg_name>
#
# No-op if `command -v "$pkg_name"` already succeeds. Otherwise installs it
# via the package manager detect_pkg_manager reports for this OS. On apt,
# the package lists are refreshed first (once per process): fresh Ubuntu
# cloud images ship with empty lists, so a bare `apt-get install` fails
# there. apt runs with DEBIAN_FRONTEND=noninteractive (exported only to
# apt-get itself, via `local -x`) and waits up to 300s for the dpkg lock;
# every package-manager call is retried (see _ensure_pkg_retry).
ensure_pkg() {
  local pkg_name="$1"

  if command -v "$pkg_name" >/dev/null 2>&1; then
    return 0
  fi

  local pkg_manager
  pkg_manager="$(detect_pkg_manager)" || return 1

  case "$pkg_manager" in
    apt)
      local -x DEBIAN_FRONTEND=noninteractive
      if [ "$_OS_DETECT_APT_UPDATED" != "1" ]; then
        _ensure_pkg_retry apt-get -o DPkg::Lock::Timeout=300 update || return 1
        _OS_DETECT_APT_UPDATED=1
      fi
      _ensure_pkg_retry apt-get -o DPkg::Lock::Timeout=300 install -y "$pkg_name"
      ;;
    dnf)
      _ensure_pkg_retry dnf install -y "$pkg_name"
      ;;
  esac
}
