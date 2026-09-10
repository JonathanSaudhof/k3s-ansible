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

## Layout

```
Makefile                          entry points
proxmox_vms.yml                   create/destroy VMs, writes the inventory
install_k3s.yml                   install k3s servers + agents, fetch kubeconfig
scripts/create-k3s-template.sh    build the cloud-init template (runs on a Proxmox node)
inventories/proxmox/hosts.ini     generated by `make vms`
kubeconfig-proxmox                generated by `make k3s`
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
