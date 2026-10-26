#!/usr/bin/env bash
# Hetzner Cloud API helpers for reusing an existing server, driven by the Makefile.
#   hcloud.sh ip        <server>         print the server's public IPv4
#   hcloud.sh import    <server>         import the server and its primary IPs into OpenTofu state
#   hcloud.sh rebuild   <server> [--yes] WIPE the server's disk and reinstall ubuntu-24.04
#   hcloud.sh bootstrap <server>         run bootstrap.sh on it and write the kubeconfig
# Needs HCLOUD_TOKEN, curl and jq. rebuild/bootstrap are run by tofu (infra/main.tf); --yes skips
# the confirmation there, since bumping rebuild_generation already is the confirmation.
set -euo pipefail

API=https://api.hetzner.cloud/v1
IMAGE=${IMAGE:-ubuntu-24.04}
cmd=${1:?usage: hcloud.sh ip|import|rebuild|bootstrap <server>}
name=${2:?server name}
: "${HCLOUD_TOKEN:?export HCLOUD_TOKEN first}"
# Callable from anywhere, so tofu is pointed at hetzner/infra explicitly.
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
TOFU="tofu -chdir=$SCRIPTS/../infra"

api() {
  curl -fsS -H "Authorization: Bearer $HCLOUD_TOKEN" -H "Content-Type: application/json" "$@"
}

server=$(api "$API/servers?name=$name" | jq -e '.servers[0]') || {
  echo "Server '$name' not found in this project." >&2
  exit 1
}
id=$(jq -r '.id' <<<"$server")

wait_action() {
  local action=$1 status
  while :; do
    status=$(api "$API/actions/$action" | jq -r '.action.status')
    case $status in
      success) return 0 ;;
      error) echo "Action $action failed." >&2; return 1 ;;
    esac
    sleep 3
  done
}

# Skips addresses that are already tracked, so re-running is harmless.
import_once() {
  local addr=$1 import_id=$2
  if $TOFU state list 2>/dev/null | grep -qx "$addr"; then
    echo "$addr already in state"
  else
    $TOFU import "$addr" "$import_id"
  fi
}

case $cmd in
  ip)
    jq -r '.public_net.ipv4.ip' <<<"$server"
    ;;

  import)
    jq -r '"Found \(.name) (id \(.id)): \(.server_type.name) in \(.datacenter.location.name)"' <<<"$server"
    echo "Set server_type and location in terraform.tfvars to match: a different type means a resize,"
    echo "a different location would mean a new server (blocked by prevent_destroy)."
    import_once hcloud_server.k3s "$id"
    ipv4_id=$(jq -r '.public_net.ipv4.id // empty' <<<"$server")
    ipv6_id=$(jq -r '.public_net.ipv6.id // empty' <<<"$server")
    # A missing primary IP isn't an error: tofu then creates and assigns a new one on apply.
    if [ -n "$ipv4_id" ]; then import_once hcloud_primary_ip.ipv4 "$ipv4_id"; fi
    if [ -n "$ipv6_id" ]; then import_once hcloud_primary_ip.ipv6 "$ipv6_id"; fi
    ;;

  rebuild)
    ip=$(jq -r '.public_net.ipv4.ip' <<<"$server")
    echo "WARNING: this erases ALL data on '$name' ($ip) and reinstalls $IMAGE."
    if [ "${3:-}" != "--yes" ]; then
      read -r -p "Type the server name to confirm: " answer
      [ "$answer" = "$name" ] || { echo "Aborted."; exit 1; }
    fi

    resp=$(api -X POST "$API/servers/$id/actions/rebuild" -d "{\"image\": \"$IMAGE\"}")
    wait_action "$(jq -r '.action.id' <<<"$resp")"
    # Hetzner only returns a root password when the server was created without SSH keys; then the
    # bootstrap can't log in with a key and you need the Hetzner console instead.
    if [ "$(jq -r '.root_password' <<<"$resp")" != "null" ]; then
      echo "Server has no SSH keys: root password is $(jq -r '.root_password' <<<"$resp")" >&2
      echo "Add your key to /root/.ssh/authorized_keys via the console before make hetzner-bootstrap." >&2
    fi
    # The rebuilt server has new host keys; drop the stale entries for both SSH ports.
    ssh-keygen -R "$ip" >/dev/null 2>&1 || true
    ssh-keygen -R "[$ip]:${SSH_PORT:-1337}" >/dev/null 2>&1 || true
    echo "Rebuilt $name. Waiting for SSH on $ip:22 ..."
    for _ in $(seq 100); do nc -z -w 3 "$ip" 22 2>/dev/null && break; sleep 3; done
    nc -z -w 3 "$ip" 22 2>/dev/null || {
      echo "Port 22 still closed after 5 min: does a firewall attached to $name block it?" >&2
      exit 1
    }
    echo "SSH is up."
    ;;

  bootstrap)
    : "${ADMIN_USER:?}" "${SSH_PORT:?}" "${ACME_EMAIL:?}" "${KUBECONFIG_OUT:?}" "${API_PORT:?}"
    ip=$(jq -r '.public_net.ipv4.ip' <<<"$server")
    env="ADMIN_USER=$ADMIN_USER SSH_PORT=$SSH_PORT ACME_EMAIL=$ACME_EMAIL"
    ssh_opts=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5)
    admin_ssh=(ssh "${ssh_opts[@]}" -p "$SSH_PORT" "$ADMIN_USER@$ip")
    # A fresh image only lets root in on 22, a finished bootstrap only the admin user on SSH_PORT. A
    # run that died after writing the sshd config leaves only the admin user on 22 (socket-activated
    # sshd picks up the new config, but not the port).
    login=()
    for candidate in "$ADMIN_USER:$SSH_PORT" "$ADMIN_USER:22" "root:22"; do
      try=(-p "${candidate#*:}" "${candidate%%:*}@$ip")
      if ssh "${ssh_opts[@]}" "${try[@]}" true 2>/dev/null; then login=("${try[@]}"); break; fi
    done
    [ ${#login[@]} -gt 0 ] || { echo "No SSH login works on $ip (tried $ADMIN_USER on $SSH_PORT/22, root on 22)." >&2; exit 1; }
    echo "Bootstrapping via ssh ${login[*]}"
    # $env is meant to expand here: it's passed to the remote sudo.
    # shellcheck disable=SC2029
    ssh "${ssh_opts[@]}" "${login[@]}" "sudo $env bash -s" < "$SCRIPTS/bootstrap.sh"
    # Points at the local end of `make hetzner-tunnel`; the API isn't reachable on the public IP.
    "${admin_ssh[@]}" sudo cat /etc/rancher/k3s/k3s.yaml \
      | sed "s#https://127.0.0.1:6443#https://127.0.0.1:$API_PORT#; s#: default\$#: hetzner#" \
      > "$KUBECONFIG_OUT"
    chmod 600 "$KUBECONFIG_OUT"
    echo "Wrote $KUBECONFIG_OUT."
    ;;

  *)
    echo "unknown command: $cmd" >&2
    exit 1
    ;;
esac
