# k3s on Proxmox

Builds an Ubuntu 24.04 cloud-init template on each Proxmox node, then provisions a k3s
cluster of VMs on top of it. Everything runs from your laptop.

## Prerequisites

- Two Proxmox nodes (`pve`, `pve2`) in a cluster, with `local-zfs` storage and `vmbr0`.
- Passwordless `ssh root@pve` / `ssh root@pve2` from your laptop.
- `libguestfs-tools` on each Proxmox node: `apt-get install -y libguestfs-tools`
- Locally: `ansible-core`, `make`, and `kubectl`.
- An SSH keypair at `~/.ssh/id_ed25519.pub` (override with `vm_ssh_pubkey_file`).

## Setup

```sh
make deps                          # install the community.general collection
ansible-vault create proxmox_secrets.yml   # add: vault_proxmox_password: <password>
```

Then pass `ANSIBLE_EXTRA=--ask-vault-pass` to any target that talks to the Proxmox API.

## Usage

```sh
make template                     # build the VM template on pve (9000) and pve2 (9001)
make up SERVERS=3 AGENTS=4        # create VMs, then install k3s
make nodes                        # kubectl get nodes -o wide
make down                         # destroy the VMs; templates are kept
```

`make template` only needs to run once per node. Re-running is a no-op unless you pass
`TEMPLATE_ARGS=--force`.

> `SERVERS`/`AGENTS` only matter the first time (or to grow/shrink the cluster). Once
> `inventories/proxmox/hosts.ini` exists, `proxmox_vms.yml` derives the counts, names,
> VMIDs and nodes from it, so plain `make down` (no args) targets exactly what's there.


### All targets

| Target | Description |
| --- | --- |
| `make help` | List targets |
| `make deps` | Install the required Ansible collection |
| `make check` | Syntax-check the script and both playbooks |
| `make template` | Build the VM template on every Proxmox node, over SSH |
| `make vms` | Create the VMs and write the inventory |
| `make k3s` | Install k3s on the provisioned VMs |
| `make up` | `vms` + `k3s` |
| `make down` | Destroy the VMs |
| `make nodes` | Show the cluster nodes |
| `make nfs-client` | Mount the NFS share on all k3s nodes |
| `make shell` | SSH into the first k3s server |
| `make clean` | Remove the generated inventory and kubeconfig |

Make variables: `SERVERS`, `AGENTS`, `PVE_TEMPLATES`, `PVE_SSH_USER`, `TEMPLATE_ARGS`,
`ANSIBLE_EXTRA` (e.g. `ANSIBLE_EXTRA=--ask-vault-pass`).

## Credentials

Two independent channels:

| Channel | Used by | Auth |
| --- | --- | --- |
| Proxmox API | `make vms` / `make down` | API token (recommended) or password |
| SSH to the nodes | `make template` | SSH key |

### API token

Create a dedicated user and token on a Proxmox node. `--privsep 0` lets the token inherit
the user's roles instead of needing its own ACLs.

```sh
pveum user add ansible@pve
pveum acl modify /                        --user ansible@pve --role PVEVMAdmin
pveum acl modify /storage                 --user ansible@pve --role PVEDatastoreUser
pveum acl modify /sdn/zones/localnetwork  --user ansible@pve --role PVESDNUser
pveum user token add ansible@pve k3s --privsep 0
```

The secret is printed **once**. Put it in `proxmox_secrets.yml`:

```yaml
vault_proxmox_user: ansible@pve
vault_proxmox_token_id: k3s
vault_proxmox_token_secret: <the printed secret>
```

Then `ansible-vault encrypt proxmox_secrets.yml`. The Makefile includes the file
automatically when it exists; add `ANSIBLE_EXTRA=--ask-vault-pass` once it's encrypted.

Env-var equivalents, if you'd rather not keep a file: `PROXMOX_TOKEN_ID`,
`PROXMOX_TOKEN_SECRET`, plus `-e proxmox_api_user=ansible@pve`.

### Password fallback

Without a token, `vault_proxmox_password` / `PROXMOX_PASSWORD` is used with
`proxmox_api_user` (default `root@pam`).

`proxmox_secrets.yml` and the generated kubeconfig are gitignored.

## Configuration

Defaults live in the `vars:` block of `proxmox_vms.yml`; override any of them with `-e`.

| Variable | Default | |
| --- | --- | --- |
| `k3s_server_count` / `k3s_agent_count` | count of `[server]`/`[agent]` in the existing inventory, else `3`/`0` | |
| `proxmox_nodes` | `[pve, pve2]` | VMs are placed round-robin across these |
| `proxmox_templates` | `{pve: 9000, pve2: 9001}` | ZFS is node-local, so each node needs its own template |
| `proxmox_storage` | `local-zfs` | |
| `vmid_base` | `200` | VMIDs are assigned sequentially from here, for new VMs only |
| `vm_ip_base` | `192.168.178.150` | Static IPs assigned sequentially from here, for new VMs only |
| `vm_gateway` / `vm_nameserver` | `192.168.178.1` | |
| `vm_user` | `k3s` | |
| `k3s_server_spec` | `{cores: 2, memory: 4096, disk: 32}` | |
| `k3s_agent_spec` | `{cores: 4, memory: 8192, disk: 64}` | |

Existing hosts keep their name, IP, VMID and node across re-runs (read back from
`inventories/proxmox/hosts.ini`); only newly added hosts get generated values.

```sh
make vms SERVERS=3 AGENTS=4 \
  ANSIBLE_EXTRA='-e {"k3s_agent_spec":{"cores":8,"memory":16384,"disk":100}}'
```

`SERVERS` must be 1, 3 or 5 — etcd needs an odd number for quorum. With 1 server there is
no control-plane HA.

## Hetzner (public VM)

`hetzner/` turns the existing Hetzner Cloud server **`vm-k3s`** into a single public k3s node running a
self-hosted [NetBird](https://netbird.io): management, signal, relay and STUN (combined `netbird-server`
with the embedded IdP), the dashboard, and the NetBird **reverse proxy**. The reverse proxy publishes
homelab apps from `../k3s-configuration` (Logto, AFFiNE, ...) to the internet: it reaches them over
WireGuard through a NetBird routing peer in the Proxmox cluster, so nothing at home is exposed.

```
internet -> auth.ez-lab.de (*.ez-lab.de) -> Traefik TLS passthrough -> netbird-proxy
         -> WireGuard -> netbird-router (Proxmox k3s) -> 192.168.178.27:3001 (Logto)
```

Everything runs from OpenTofu, in three stages (each its own root module and local state), because the
Kubernetes and NetBird providers need a cluster and a server that the stage before creates:

| Stage | What | Providers |
|---|---|---|
| `hetzner/infra` | server (imported), primary IPs, firewall, DNS; **wipe + Ubuntu 24.04 reinstall** (`rebuild_generation`), then `scripts/bootstrap.sh` (k3s) and `kubeconfig-hetzner` | hcloud |
| `hetzner/platform` | NetBird server, dashboard and reverse proxy on the VM's k3s, Traefik routes | kubernetes (through the API tunnel) |
| `hetzner/netbird` | NetBird network `homelab`, routing peer group + setup key, one reverse proxy service per app, the setup key as a Secret in the Proxmox cluster | netbird, kubernetes (`~/.kube/config`, `homelab_kubeconfig`) |

`hetzner/apps.json` lists the published apps (name -> LAN IP and port of their MetalLB service). The
netbird stage turns each into a reverse proxy service `<name>.ez-lab.de`; no DNS record per app is needed.

- **Firewall** (Hetzner Cloud Firewall), open from anywhere:
  - TCP 1337 (SSH, key only); TCP 22 (only used between a rebuild and bootstrap; nothing listens after)
  - TCP 80 and 443 (Traefik: dashboard, management/signal/relay, reverse proxy)
  - UDP 3478 (NetBird STUN)
  - ICMP
  The k3s API (6443) is closed; reach it with `make hetzner-tunnel`.
- **DNS** in the existing `ez-lab.de` zone, A + AAAA to the VM: `netbird` (dashboard, management) and
  the wildcard `*`, the reverse proxy's domain (`NB_PROXY_DOMAIN=ez-lab.de`). Every name without its own
  record now lands on NetBird; names with an explicit record (apex, `coolify`, ...) are unaffected.
- **Wipe/reinstall**: bump `rebuild_generation` in `hetzner/infra/terraform.tfvars` and apply. That's the
  confirmation; there's no prompt. `0` never rebuilds.
- **Bootstrap** (`hetzner/scripts/bootstrap.sh`, idempotent; re-runs after a rebuild or when it changes):
  - creates the `k3s` sudo user with root's SSH keys (Hetzner re-injects the keys from server creation on rebuild)
  - enables unattended-upgrades with reboots at 04:00
  - installs k3s; its bundled Traefik gets a `letsencrypt` resolver (HTTP-01), no websecure timeouts
    (long-lived gRPC/WebSocket) and ACME bypass for the reverse proxy's TLS-ALPN challenges
  - moves sshd to port 1337, key only, with root login off
- **NetBird** (`hetzner/platform`): plain manifests, pinned images (`netbird_version`, `dashboard_version`),
  sqlite on `local-path`. Traefik terminates TLS for `netbird.ez-lab.de` and passes every other SNI through
  to the proxy (PROXY protocol v2), which gets its own certificates. The proxy's token is minted with the
  server's admin CLI and goes straight into the `netbird-proxy-token` Secret, not into tofu state.

Prerequisites:
- `opentofu`, `kubectl`, `curl`, `jq` and `nc`.
- The `ez-lab.de` zone in the Hetzner Console DNS, in the same project as `vm-k3s`.
- An API token for that project with read/write access, in `.env` as `HCLOUD_TOKEN=...`
  (`cp .env.example .env`; gitignored, read by the Makefile and exported to tofu and the scripts).
- A working kubeconfig for the Proxmox cluster in `~/.kube/config` (same as `../k3s-configuration`), or set `homelab_kubeconfig` in `hetzner/netbird/terraform.tfvars`.

```sh
cp .env.example .env                # then set HCLOUD_TOKEN
cp hetzner/infra/terraform.tfvars.example hetzner/infra/terraform.tfvars        # acme_email, ...
cp hetzner/platform/terraform.tfvars.example hetzner/platform/terraform.tfvars  # owner_email
make hetzner-init
make hetzner-import               # prints vm-k3s' type and location; put both into terraform.tfvars
make hetzner-plan                 # expect: firewall + DNS added, server/IPs updated in place, 0 destroyed
# set rebuild_generation = 1 to wipe and reinstall (skip on a server that is already bootstrapped)
make hetzner-up                   # infra + platform; netbird is skipped until NB_PAT is set
                                  # (moves *.ez-lab.de to NetBird)
make hetzner-netbird-secrets      # owner login; back the encryption key up to 1Password
# https://netbird.ez-lab.de: Team -> Service Users -> new user (Admin) -> create token -> .env NB_PAT=...
make hetzner-netbird              # network, router setup key, one reverse proxy service per app
make -C ../k3s-configuration install-netbird-router
make hetzner-shell                # ssh -p 1337 k3s@<ip>
```

Notes:
- **Check the plan before applying.** If `hetzner-plan` wants to replace `hcloud_server.k3s`, fix
  `terraform.tfvars` first (usually `location`). `prevent_destroy` makes tofu refuse a replacement anyway.
  A different `server_type` resizes the server, which means a short downtime.
- **Wildcard:** `*.ez-lab.de` used to point at 91.99.223.121. Anything still hosted there needs its own
  record in the zone, or it now ends up at the NetBird proxy (which answers unknown names with an error).
- **Hetzner returns a root password on rebuild** if `vm-k3s` was created without SSH keys. Then add your
  key to `/root/.ssh/authorized_keys` through the Hetzner console and apply again.
- **Old cloud-init data:** the rebuild may re-run the server's original creation-time user_data on first
  boot. Bootstrap overrides the relevant settings.
- **Secrets in state:** `hetzner/platform/terraform.tfstate` holds the NetBird owner password and store
  encryption key, `hetzner/netbird/terraform.tfstate` the setup key. All state is local and gitignored;
  back it up (the encryption key is needed to read the NetBird database), or move it to a remote backend.
- **Adding an app:** add it to `hetzner/apps.json` and run `make hetzner-up`. The app's own login stays in
  charge; the proxy adds no authentication.
- After a rebuild, NetBird starts with an empty database: create a new PAT and re-run the netbird stage
  (its state then refers to deleted objects; `rm hetzner/netbird/terraform.tfstate` first).
- There's no destroy target: the server is reused, and `prevent_destroy` protects it. To give it up,
  remove the lifecycle block deliberately.

## Layout

```
Makefile                          entry points
proxmox_vms.yml                   create/destroy VMs, writes the inventory
install_k3s.yml                   install k3s servers + agents, fetch kubeconfig
setup_nfs_client.yml              mount the NFS share on all k3s nodes (node-level; the
                                   in-cluster StorageClass is installed from ../k3s-configuration)
scripts/create-k3s-template.sh    build the cloud-init template (runs on a Proxmox node)
inventories/proxmox/hosts.ini     generated by `make vms`
kubeconfig-proxmox                generated by `make k3s`
hetzner/{infra,platform,netbird}  OpenTofu stages for vm-k3s on Hetzner (OS, k3s, NetBird)
hetzner/apps.json                 homelab apps published through the NetBird reverse proxy
hetzner/scripts/                  Hetzner API helper and bootstrap script
kubeconfig-hetzner                written by the infra stage
```

`hosts.ini` and `prepare_my_cluster.yml` are the parked Raspberry Pi cluster. Nothing
references them.

## Notes

- Check `sparse 1` on `local-zfs` (`grep -A6 'zfspool: local-zfs' /etc/pve/storage.cfg`),
  otherwise a 64G agent disk is thick-provisioned on creation.
- Make sure the IP range from `vm_ip_base` sits outside your router's DHCP pool.
- The template truncates `/etc/machine-id`; without it every clone shares a DHCP identity.
- `local` needs its `Import` content type enabled — the cloud image is staged in
  `/var/lib/vz/import/`. VM disks go on `local-zfs`, which is what actually needs `Disk image`.
