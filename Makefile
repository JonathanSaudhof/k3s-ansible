SHELL := /bin/bash
.DEFAULT_GOAL := help

PVE_SSH_USER  ?= root
# SSH password for the Proxmox nodes; empty means key/agent auth. Needs sshpass.
# Pass it per run (PVE_SSH_PASSWORD=... make vms) or via proxmox_secrets.yml - never commit it.
PVE_SSH_PASSWORD ?=
export PVE_SSH_PASSWORD
export SSHPASS := $(PVE_SSH_PASSWORD)
SSH := $(if $(PVE_SSH_PASSWORD),sshpass -e ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password,ssh) -o StrictHostKeyChecking=accept-new
PVE_TEMPLATES ?= 192.168.178.15:9001 192.168.178.16:9002
SERVERS       ?= 1
AGENTS        ?= 2
KUBECONFIG_OUT := kubeconfig-proxmox
INVENTORY     := inventories/proxmox/hosts.ini

TEMPLATE_ARGS ?=
ANSIBLE_EXTRA ?=
SECRETS       := $(wildcard proxmox_secrets.yml)
# Only override the VM counts when SERVERS/AGENTS were actually passed in; otherwise
# proxmox_vms.yml derives them from the existing inventories/proxmox/hosts.ini.
VARS = $(if $(filter command\ line environment,$(origin SERVERS)),-e k3s_server_count=$(SERVERS)) \
       $(if $(filter command\ line environment,$(origin AGENTS)),-e k3s_agent_count=$(AGENTS)) \
       $(if $(SECRETS),-e @proxmox_secrets.yml) $(ANSIBLE_EXTRA)

.PHONY: help deps check template vms k3s up down nodes nfs-client shell clean

help: ## Show this help
	@echo "Usage: make <target> [SERVERS=3] [AGENTS=4] [ANSIBLE_EXTRA=--ask-vault-pass]"
	@echo
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

deps: ## Install the required Ansible collection
	ansible-galaxy collection install -r requirements.yml

check: ## Syntax-check the script and both playbooks
	bash -n scripts/create-k3s-template.sh
	ansible-playbook proxmox_vms.yml --syntax-check
	ansible-playbook install_k3s.yml --syntax-check

template: ## Build the VM template on every Proxmox node, over SSH
	@if [ -n "$(PVE_SSH_PASSWORD)" ] && ! command -v sshpass >/dev/null; then \
		echo "PVE_SSH_PASSWORD is set but sshpass is not installed"; exit 1; \
	fi	@for t in $(PVE_TEMPLATES); do \
		node=$${t%%:*}; vmid=$${t##*:}; \
		echo "==> $$node (vmid $$vmid)"; \
		$(SSH) $(PVE_SSH_USER)@$$node "bash -s -- --vmid $$vmid $(TEMPLATE_ARGS)" \
			< scripts/create-k3s-template.sh || exit 1; \
	done

vms: ## Create the k3s VMs and write the inventory
	ansible-playbook proxmox_vms.yml $(VARS)

k3s: ## Install k3s on the provisioned VMs
	ansible-playbook install_k3s.yml $(ANSIBLE_EXTRA)

up: vms k3s ## Provision VMs and install k3s

# Without SERVERS/AGENTS, targets whatever's currently in the inventory.
down: ## Destroy the k3s VMs (templates are kept)
	ansible-playbook proxmox_vms.yml -e vm_state=absent $(VARS)

nodes: ## Show the k3s cluster nodes
	KUBECONFIG=$(KUBECONFIG_OUT) kubectl get nodes -o wide

nfs-client: ## Mount the NFS share on all k3s nodes
	ansible-playbook -i $(INVENTORY) setup_nfs_client.yml $(ANSIBLE_EXTRA)

shell: ## SSH into the first k3s server
	@ssh k3s@$$(awk '/ansible_host=/{sub(/.*ansible_host=/, ""); print $$1; exit}' $(INVENTORY))

clean: ## Remove the generated inventory and kubeconfig
	rm -f $(KUBECONFIG_OUT) $(INVENTORY)

# --- Hetzner (OpenTofu in hetzner/) ---------------------------------------------------------
# Reuses the existing server vm-k3s. Three tofu stages, applied in order by hetzner-up:
#   infra    firewall, IPs, DNS; wipe + Ubuntu reinstall (rebuild_generation) and k3s bootstrap
#   platform NetBird server, dashboard and reverse proxy on the VM's k3s (through the API tunnel)
#   netbird  NetBird network, homelab apps as reverse proxy services, router setup key; needs NB_PAT
# Needs curl, jq, kubectl, hetzner/{infra,platform}/terraform.tfvars (see the .examples) and
# HCLOUD_TOKEN (+ NB_PAT for stage 3) from .env (gitignored, see .env.example); a value there
# overrides the environment. First time: hetzner-init -> hetzner-import -> hetzner-up.
# `-include`: .env is optional, the tokens can also come from the environment.
-include .env
HCLOUD_TOKEN ?=
NB_PAT       ?=
export HCLOUD_TOKEN NB_PAT
HETZNER_STAGES     := infra platform netbird
TOFU                = tofu -chdir=hetzner/$(1)
HCLOUD             := hetzner/scripts/hcloud.sh
HETZNER_SERVER     ?= vm-k3s
HETZNER_KUBECONFIG := kubeconfig-hetzner
# Local port the k3s API is forwarded to; 6443 is closed on the public IP. Keep in sync with
# api_tunnel_port in hetzner/infra/variables.tf.
HETZNER_API_PORT   ?= 16443
TUNNEL_SOCKET      := /tmp/k3s-hetzner-tunnel.sock
tf_out  = $$($(call TOFU,infra) output -raw $(1))
SSH_HZ  = ssh -p $(call tf_out,ssh_port) $(call tf_out,admin_user)@$(call tf_out,public_ipv4)
KUBE_HZ = KUBECONFIG=$(HETZNER_KUBECONFIG)

.PHONY: hetzner-init hetzner-import hetzner-plan hetzner-up hetzner-infra hetzner-platform hetzner-netbird \
	hetzner-shell hetzner-tunnel hetzner-tunnel-up hetzner-tunnel-down hetzner-netbird-secrets

hetzner-init: ## Hetzner: install the OpenTofu providers of all stages
	@for s in $(HETZNER_STAGES); do $(call TOFU,$$s) init -upgrade || exit 1; done

hetzner-import: ## Hetzner: import vm-k3s and its primary IPs into tofu state
	$(HCLOUD) import $(HETZNER_SERVER)

hetzner-plan: ## Hetzner: show what the infra stage would change
	$(call TOFU,infra) plan

# The wipe only happens when rebuild_generation in hetzner/infra/terraform.tfvars was bumped.
hetzner-up: hetzner-infra hetzner-platform hetzner-netbird ## Hetzner: apply all stages (infra, platform, netbird)

hetzner-infra: ## Hetzner: firewall, DNS, (re)install Ubuntu + k3s, kubeconfig
	$(call TOFU,infra) apply

hetzner-platform: ## Hetzner: install NetBird on the VM's k3s
	@$(MAKE) --no-print-directory hetzner-tunnel-up
	$(call TOFU,platform) apply; rc=$$?; $(MAKE) --no-print-directory hetzner-tunnel-down; exit $$rc

# Skipped until NB_PAT is set: the PAT can only be created in the dashboard once NetBird runs.
hetzner-netbird: ## Hetzner: configure NetBird (network, public apps, router key); needs NB_PAT
	@if [ -z "$(NB_PAT)" ]; then \
		echo "NB_PAT not set: skipping the netbird stage. Log in to https://$(call tf_out,netbird_host)"; \
		echo "(make hetzner-netbird-secrets), create a service user with admin role + access token,"; \
		echo "put it in .env as NB_PAT=... and run make hetzner-netbird."; \
	else \
		$(call TOFU,netbird) apply; \
	fi

hetzner-shell: ## Hetzner: SSH into the VM (port 1337, key only)
	$(SSH_HZ)

hetzner-tunnel: ## Hetzner: forward the k3s API to localhost:16443 (keep running)
	$(SSH_HZ) -N -L $(HETZNER_API_PORT):127.0.0.1:6443

# Background variant for the platform stage: a control socket so it can be closed again.
hetzner-tunnel-up:
	@$(SSH_HZ) -S $(TUNNEL_SOCKET) -O check 2>/dev/null || \
		$(SSH_HZ) -f -N -M -S $(TUNNEL_SOCKET) -o ExitOnForwardFailure=yes -L $(HETZNER_API_PORT):127.0.0.1:6443

hetzner-tunnel-down:
	@$(SSH_HZ) -S $(TUNNEL_SOCKET) -O exit 2>/dev/null || true

# Back the store encryption key up to 1Password: without it the NetBird database is unreadable.
hetzner-netbird-secrets: ## Hetzner: print the NetBird owner login and store encryption key
	@echo "Dashboard:      $$($(call TOFU,platform) output -raw dashboard_url)"
	@echo "Owner:          $$($(call TOFU,platform) output -raw owner_email)"
	@echo "Password:       $$($(call TOFU,platform) output -raw owner_password)  (first start only)"
	@echo "Encryption key: $$($(call TOFU,platform) output -raw store_encryption_key)"
