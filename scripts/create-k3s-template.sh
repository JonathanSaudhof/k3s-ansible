#!/usr/bin/env bash
# Build an Ubuntu cloud-init template for k3s VMs. Run as root ON a Proxmox node.
set -euo pipefail

VMID=9000
NAME=ubuntu-2404-k3s
STORAGE=local-zfs
BRIDGE=vmbr0
RELEASE=noble
SSH_KEY=""
CIUSER=k3s
DISK=32G
FORCE=0

usage() {
  cat <<EOF
Usage: $0 [options]
  --vmid ID        template VMID              (default: $VMID)
  --name NAME      template name              (default: $NAME)
  --storage NAME   storage for disk+cloudinit (default: $STORAGE)
  --bridge NAME    network bridge             (default: $BRIDGE)
  --release NAME   ubuntu codename            (default: $RELEASE)
  --ssh-key PATH   public key(s) on THIS node (default: none; proxmox_vms.yml sets per-VM keys)
  --ciuser NAME    default cloud-init user    (default: $CIUSER)
  --disk SIZE      root disk size             (default: $DISK)
  --force          destroy an existing VMID first
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid)    VMID="$2";    shift 2 ;;
    --name)    NAME="$2";    shift 2 ;;
    --storage) STORAGE="$2"; shift 2 ;;
    --bridge)  BRIDGE="$2";  shift 2 ;;
    --release) RELEASE="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --ciuser)  CIUSER="$2";  shift 2 ;;
    --disk)    DISK="$2";    shift 2 ;;
    --force)   FORCE=1;      shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root on a Proxmox node" >&2; exit 1; }
command -v qm >/dev/null || { echo "qm not found - not a Proxmox node?" >&2; exit 1; }
command -v virt-customize >/dev/null || { echo "missing: apt-get install -y libguestfs-tools" >&2; exit 1; }
[[ -z $SSH_KEY || -f $SSH_KEY ]] || { echo "ssh key file not found: $SSH_KEY" >&2; exit 1; }

if qm status "$VMID" &>/dev/null; then
  if [[ $FORCE -eq 1 ]]; then
    qm destroy "$VMID" --purge
  else
    echo "VMID $VMID already exists - nothing to do (use --force to rebuild)"
    exit 0
  fi
fi

# /var/lib/vz/import is provided by the 'Import' content type on storage 'local'.
IMPORT_DIR=/var/lib/vz/import
IMG_NAME="${RELEASE}-server-cloudimg-amd64.img"
BASE_IMG="$IMPORT_DIR/$IMG_NAME"
BASE_URL="https://cloud-images.ubuntu.com/${RELEASE}/current"
mkdir -p "$IMPORT_DIR"

if [[ ! -f $BASE_IMG ]]; then
  echo "==> downloading $IMG_NAME"
  wget -q --show-progress -O "$BASE_IMG.part" "$BASE_URL/$IMG_NAME"
  expected=$(wget -qO- "$BASE_URL/SHA256SUMS" | awk -v f="*$IMG_NAME" '$2 == f { print $1 }')
  [[ -n $expected ]] || { rm -f "$BASE_IMG.part"; echo "no checksum published for $IMG_NAME" >&2; exit 1; }
  actual=$(sha256sum "$BASE_IMG.part" | cut -d' ' -f1)
  [[ $expected == "$actual" ]] || { rm -f "$BASE_IMG.part"; echo "checksum mismatch" >&2; exit 1; }
  mv "$BASE_IMG.part" "$BASE_IMG"
fi

# Customise a copy so re-runs always start from the pristine download.
WORK_IMG=$(mktemp "$IMPORT_DIR/k3s-template.XXXXXX.img")
trap 'rm -f "$WORK_IMG"' EXIT
cp "$BASE_IMG" "$WORK_IMG"

echo "==> installing guest packages into image"
export LIBGUESTFS_BACKEND=direct
virt-customize -a "$WORK_IMG" \
  --install qemu-guest-agent,curl,open-iscsi,nfs-common \
  --run-command 'systemctl enable qemu-guest-agent' \
  --truncate /etc/machine-id   # else every clone shares one machine-id / DHCP identity

echo "==> creating template $VMID ($NAME)"
qm create "$VMID" \
  --name "$NAME" \
  --ostype l26 \
  --cores 2 \
  --memory 4096 \
  --net0 "virtio,bridge=$BRIDGE" \
  --scsihw virtio-scsi-single \
  --agent enabled=1 \
  --serial0 socket \
  --vga serial0

qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$WORK_IMG,discard=on,ssd=1"
qm set "$VMID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0 --ciuser "$CIUSER"
if [[ -n $SSH_KEY ]]; then
  qm set "$VMID" --sshkeys "$SSH_KEY"
fi
qm disk resize "$VMID" scsi0 "$DISK"
qm template "$VMID"

echo "==> done. Verify with: qm config $VMID"
