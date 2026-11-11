#!/usr/bin/env bash
# scripts/update-dns.sh [--create-only]
#
# Points this host's Cloudflare A record (CF_RECORD_NAME) at this VM's
# current public IP, creating the record if it doesn't exist yet.
#
# Two callers:
#   - the pasted boot script, right after restore.sh: a Rackspace Spot VM
#     recreated after a lost bid has a new public IP, so the record is
#     repointed at it (or created, if it was never made or got deleted).
#   - templates/resume-backup.sh, with --create-only, when a running host
#     is enrolled over SSH: a host with no record yet gets one, so enrolling
#     a VM that has no DNS name needs no trip to the Cloudflare dashboard.
#     An existing record is never repointed in this mode: the operator may
#     be enrolling (or re-running against) a VM that isn't the one the name
#     is meant to serve, and silently moving live traffic is worse than a
#     warning. A mismatch is reported on stderr and the script exits 0.
#
# A record that already points at this VM's IP is left untouched.
#
# Like restore.sh, this deliberately has no error-swallowing: `set -euo
# pipefail`, no `|| true`. A failure at any step -- IP lookup, record
# lookup, create or update -- propagates as this script's own non-zero
# exit.
#
# Required environment:
#   CF_API_TOKEN     -- Cloudflare API token, used as a bearer token
#   CF_ZONE_ID        -- Cloudflare zone id containing the record
#   CF_RECORD_NAME    -- fully-qualified hostname of the A record
#
# The token needs DNS edit permission on the zone (creating a record needs
# the same permission as updating one).
set -euo pipefail

create_only=0
case "${1:-}" in
  "") ;;
  --create-only) create_only=1 ;;
  *)
    echo "usage: update-dns.sh [--create-only]" >&2
    exit 2
    ;;
esac

_UPDATE_DNS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
# shellcheck disable=SC1091
source "$_UPDATE_DNS_LIB_DIR/os-detect.sh"

# Neither curl nor jq is guaranteed to be preinstalled on a freshly created
# VM's minimal base image, so, mirroring how install-restic.sh ensures curl
# before relying on it, make sure both are present before this script's
# first use of each below.
ensure_pkg curl
ensure_pkg jq

CF_API_BASE="https://api.cloudflare.com/client/v4"

cf_api() {
  # cf_api <method> <path> [json-body]
  local method="$1" path="$2" body="${3:-}"
  local args=(-fsSL -X "$method"
    -H "Authorization: Bearer ${CF_API_TOKEN}"
    -H "Content-Type: application/json")
  if [[ -n "$body" ]]; then
    args+=(--data "$body")
  fi
  curl "${args[@]}" "${CF_API_BASE}/zones/${CF_ZONE_ID}${path}"
}

# --- discover this host's current public IP ---
public_ip="$(curl -fsSL https://api.ipify.org)"
if ! [[ "$public_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo "update-dns.sh: public IP lookup returned something that isn't an IPv4 address: ${public_ip}" >&2
  exit 1
fi

# --- look up the existing A record by name ---
lookup_response="$(cf_api GET "/dns_records?type=A&name=${CF_RECORD_NAME}")"
record_id="$(printf '%s' "$lookup_response" | jq -r '.result[0].id // empty')"
record_ip="$(printf '%s' "$lookup_response" | jq -r '.result[0].content // empty')"

if [[ -z "$record_id" ]]; then
  body="$(jq -cn --arg name "$CF_RECORD_NAME" --arg ip "$public_ip" \
    '{type: "A", name: $name, content: $ip, ttl: 1, proxied: false}')"
  cf_api POST "/dns_records" "$body" > /dev/null
  echo "update-dns.sh: created A record ${CF_RECORD_NAME} -> ${public_ip}"
elif [[ "$record_ip" == "$public_ip" ]]; then
  echo "update-dns.sh: ${CF_RECORD_NAME} already points at ${public_ip}"
elif [[ "$create_only" -eq 1 ]]; then
  echo "update-dns.sh: WARNING: ${CF_RECORD_NAME} points at ${record_ip}, not this host's ${public_ip}; left unchanged" >&2
else
  body="$(jq -cn --arg ip "$public_ip" '{content: $ip}')"
  cf_api PATCH "/dns_records/${record_id}" "$body" > /dev/null
  echo "update-dns.sh: updated A record ${CF_RECORD_NAME}: ${record_ip} -> ${public_ip}"
fi
