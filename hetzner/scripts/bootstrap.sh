#!/usr/bin/env bash
# Turns a freshly rebuilt Ubuntu 24.04 server into the single-node k3s host for NetBird.
# Runs ON the server as root, piped over SSH by `hcloud.sh bootstrap` (terraform_data.bootstrap):
#   ssh root@<ip> ADMIN_USER=k3s SSH_PORT=1337 ACME_EMAIL=... bash -s < bootstrap.sh
# Safe to re-run. The SSH port switch happens last, so this session isn't cut off half-way.
set -euo pipefail

: "${ADMIN_USER:?}" "${SSH_PORT:?}" "${ACME_EMAIL:?}"
K3S_CHANNEL=${K3S_CHANNEL:-stable}
K3S_VERSION=${K3S_VERSION:-}

# The admin user gets root's keys, which Hetzner injects on rebuild from the server's creation.
if [ ! -s /root/.ssh/authorized_keys ]; then
  echo "No SSH keys in /root/.ssh/authorized_keys; refusing to continue (would lock you out)." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
apt-get install -y unattended-upgrades curl

# --- admin user ---------------------------------------------------------------------------------
id "$ADMIN_USER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash --groups sudo "$ADMIN_USER"
passwd --lock "$ADMIN_USER" >/dev/null
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" /root/.ssh/authorized_keys "/home/$ADMIN_USER/.ssh/authorized_keys"
echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$ADMIN_USER"
chmod 440 "/etc/sudoers.d/90-$ADMIN_USER"

# --- unattended upgrades ------------------------------------------------------------------------
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > /etc/apt/apt.conf.d/52unattended-upgrades-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

# --- k3s ----------------------------------------------------------------------------------------
# The API is only reached through `make hetzner-tunnel` (localhost), never on the public IP.
mkdir -p /etc/rancher/k3s /var/lib/rancher/k3s/server/manifests
cat > /etc/rancher/k3s/config.yaml <<'EOF'
tls-san:
  - 127.0.0.1
secrets-encryption: true
write-kubeconfig-mode: "0600"
EOF

# k3s applies everything in this directory. Configures the bundled Traefik, NetBird's ingress
# (hetzner/platform): a "letsencrypt" resolver with ACME state on a PVC for netbird.<zone>; no
# timeouts on websecure, which carries NetBird's long-lived gRPC and relay WebSocket streams; and
# ACME bypass, so the reverse proxy's own tls-alpn-01 challenges reach it through TLS passthrough.
cat > /var/lib/rancher/k3s/server/manifests/traefik-config.yaml <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    persistence:
      enabled: true
      storageClass: local-path
      size: 128Mi
    certificatesResolvers:
      letsencrypt:
        acme:
          email: "${ACME_EMAIL}"
          storage: /data/acme.json
          httpChallenge:
            entryPoint: web
    ports:
      websecure:
        transport:
          respondingTimeouts:
            readTimeout: 0
            writeTimeout: 0
            idleTimeout: 0
    additionalArguments:
      - --entryPoints.websecure.allowACMEByPass=true
EOF

if ! systemctl is-active --quiet k3s; then
  if [ -n "$K3S_VERSION" ]; then
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server
  else
    curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="$K3S_CHANNEL" sh -s - server
  fi
fi

# --- sshd: key only, custom port ----------------------------------------------------------------
# sshd_config.d is read in order and the first value wins, so 10- beats the image's 50-cloud-init.
cat > /etc/ssh/sshd_config.d/10-hardening.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
AllowUsers ${ADMIN_USER}
EOF
# Socket activation only creates sshd's privilege separation directory when a connection spawns
# sshd, and `sshd -t` refuses to run without it.
install -d -m 755 /run/sshd
sshd -t
# Ubuntu 24.04 socket-activates sshd, which ignores Port in sshd_config without a generator
# re-run; running sshd as a plain service makes the port setting authoritative. Existing sessions
# (this one) survive the restart.
systemctl disable --now ssh.socket
systemctl enable ssh.service
systemctl restart ssh.service

echo "Bootstrap done: ssh -p ${SSH_PORT} ${ADMIN_USER}@<ip> (root login and port 22 are now off)."
