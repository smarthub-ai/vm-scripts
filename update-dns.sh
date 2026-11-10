#!/usr/bin/env bash
# scripts/update-dns.sh
#
# Runs right after restore.sh, as the last step of the pasted boot script
# (resuming backups is a separate, later, manual step -- see
# templates/resume-backup.sh): a Rackspace Spot VM that was recreated after
# a lost bid gets a new public IP, so this script discovers that IP and
# repoints the host's Cloudflare A record at it. restic/Wasabi are not
# involved at all here.
#
# Like restore.sh, this deliberately has no error-swallowing: `set -euo
# pipefail`, no `|| true`, and an explicit failure (not just "pipeline
# exits non-zero") when the Cloudflare record lookup comes back empty. A
# failure at any of the three steps -- IP lookup, record lookup, or the
# PATCH -- must propagate as this script's own non-zero exit, since a
# swallowed failure here would leave DNS and the restore sequence in an
# inconsistent state.
#
# Required environment:
#   CF_API_TOKEN     -- Cloudflare API token, used as a bearer token
#   CF_ZONE_ID        -- Cloudflare zone id containing the record
#   CF_RECORD_NAME    -- fully-qualified hostname of the A record to update
set -euo pipefail

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

# --- discover this host's current public IP ---
public_ip="$(curl -fsSL https://api.ipify.org)"

# --- look up the existing A record's id by name ---
lookup_response="$(curl -fsSL \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "${CF_API_BASE}/zones/${CF_ZONE_ID}/dns_records?type=A&name=${CF_RECORD_NAME}")"

record_id="$(printf '%s' "$lookup_response" | jq -r '.result[0].id // empty')"

if [[ -z "$record_id" ]]; then
  echo "update-dns.sh: no A record found for ${CF_RECORD_NAME}" >&2
  exit 1
fi

# --- patch the record with the discovered IP ---
curl -fsSL \
  -X PATCH \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "{\"content\": \"${public_ip}\"}" \
  "${CF_API_BASE}/zones/${CF_ZONE_ID}/dns_records/${record_id}" > /dev/null
