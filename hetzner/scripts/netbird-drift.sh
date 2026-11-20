#!/usr/bin/env bash
# Checks NetBird against hetzner/netbird/ in two ways:
#   1. objects on the server that tofu doesn't manage (made in the dashboard) - tofu can't see these
#   2. `tofu plan`: drift on the objects it does manage
# Exit 0 = in sync, 1 = unmanaged objects or drift. Needs NB_PAT, curl, jq.
# Not covered: peers and users; they register or are invited, not configured in code.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${NB_PAT:?NB_PAT not set (see .env.example)}"

host=$(tofu -chdir=infra output -raw netbird_host)
api() { curl -sf -H "Authorization: Token $NB_PAT" "https://$host/api/$1"; }

# IDs tofu knows: in state, or about to be imported by an import block ("<network>/<id>" -> <id>).
managed=$(
  tofu -chdir=netbird show -json | jq -r '.. | objects | select(.mode? == "managed") | .values.id // empty'
  { grep -ho 'id *= *"[^"]*"' netbird/*.tf || true; } | sed 's/.*"\(.*\)"/\1/; s|.*/||'
)

unmanaged() { # <label>; reads "id<TAB>name" rows, prints those whose id tofu doesn't know
  local id name
  while IFS=$'\t' read -r id name; do
    [ -n "$id" ] && ! grep -qxF "$id" <<<"$managed" && echo "  unmanaged $1: $name ($id)"
  done
  return 0
}

found=$(
  api groups          | jq -r '.[] | select(.name != "All") | [.id, .name] | @tsv' | unmanaged group
  api policies        | jq -r '.[] | [.id, .name] | @tsv'                         | unmanaged policy
  api setup-keys      | jq -r '.[] | select(.valid) | [.id, .name] | @tsv'         | unmanaged "setup key"
  api routes          | jq -r '.[] | [.id, .network_id] | @tsv'                   | unmanaged route
  api dns/nameservers | jq -r '.[] | [.id, .name] | @tsv'                         | unmanaged nameserver
  api posture-checks  | jq -r '.[] | [.id, .name] | @tsv'                         | unmanaged "posture check"
  api reverse-proxies/services | jq -r '.[] | [.id, .domain] | @tsv'              | unmanaged "proxy service"
  nets=$(api networks)
  jq -r '.[] | [.id, .name] | @tsv' <<<"$nets" | unmanaged network
  for net in $(jq -r '.[].id' <<<"$nets"); do
    api "networks/$net/resources" | jq -r '.[] | [.id, .name] | @tsv'                   | unmanaged "network resource"
    api "networks/$net/routers"   | jq -r '.[] | [.id, (.peer // "peer groups")] | @tsv' | unmanaged "network router"
  done
)

rc=0
echo "== objects not in tofu"
if [ -n "$found" ]; then echo "$found"; rc=1; else echo "  none"; fi

echo "== tofu plan (drift on managed objects)"
plan=$(mktemp)
trap 'rm -f "$plan"' EXIT
set +e; tofu -chdir=netbird plan -detailed-exitcode -no-color >"$plan" 2>&1; prc=$?; set -e
case $prc in
  0) echo "  no changes" ;;
  2) grep -E '^  # .* will be|^Plan:' "$plan" | sed 's/^  # /  /'; rc=1 ;;
  *) cat "$plan"; exit 1 ;;
esac
exit $rc
