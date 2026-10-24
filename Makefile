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
# Reuses the existing server vm-k3s. Needs curl, jq, hetzner/terraform.tfvars (see the .example) and
# HCLOUD_TOKEN from .env (gitignored, see .env.example); a value there overrides the environment.
# Order: init -> import -> plan -> rebuild -> bootstrap -> apply.
# `-include`: .env is optional, the token can also come from the environment.
-include .env
HCLOUD_TOKEN ?=
export HCLOUD_TOKEN
TOFU               := tofu -chdir=hetzner
HCLOUD             := hetzner/scripts/hcloud.sh
HETZNER_SERVER     ?= vm-k3s
# Let's Encrypt account email for Traefik; only needed by hetzner-bootstrap.
ACME_EMAIL         ?=
# rebuild/bootstrap run before the first apply, when there are no tofu outputs yet; keep these in
# sync with ssh_port/admin_user in hetzner/variables.tf.
HETZNER_SSH_PORT   ?= 1337
HETZNER_ADMIN      ?= k3s
HETZNER_KUBECONFIG := kubeconfig-hetzner
# Local port the k3s API is forwarded to; 6443 is closed on the public IP.
HETZNER_API_PORT   ?= 16443
PANGOLIN_VERSION   := 0.1.0-alpha.1
CNPG_VERSION       ?= 0.28.0
tf_out  = $$($(TOFU) output -raw $(1))
SSH_HZ  = ssh -p $(call tf_out,ssh_port) $(call tf_out,admin_user)@$(call tf_out,public_ipv4)
KUBE_HZ = KUBECONFIG=$(HETZNER_KUBECONFIG)
# pangolin-kube-controller's NetworkPolicy has to allow the API server, which k3s serves on the
# node's public IP; gerbil.startupMode is passed per target.
PANGOLIN_HELM = $(KUBE_HZ) helm upgrade --install pangolin fossorial/pangolin \
	--version $(PANGOLIN_VERSION) --namespace pangolin \
	--values hetzner/helm-values/pangolin-values.yaml \
	--set networkPolicy.controller.egress.kubernetesApi.cidr=$(call tf_out,public_ipv4)/32 \
	--set networkPolicy.controller.egress.kubernetesApi.port=6443

.PHONY: hetzner-init hetzner-import hetzner-plan hetzner-rebuild hetzner-bootstrap hetzner-apply hetzner-shell hetzner-kubeconfig hetzner-tunnel \
	hetzner-install-cnpg hetzner-install-pangolin hetzner-pangolin-setup-token hetzner-pangolin-ready

hetzner-init: ## Hetzner: install the OpenTofu providers
	$(TOFU) init

hetzner-import: ## Hetzner: import vm-k3s and its primary IPs into tofu state
	$(HCLOUD) import $(HETZNER_SERVER)

hetzner-plan: ## Hetzner: show what tofu would change
	$(TOFU) plan

# WARNING: erases all data on the server (asks for the server name to confirm).
hetzner-rebuild: ## Hetzner: wipe vm-k3s and reinstall Ubuntu 24.04
	SSH_PORT=$(HETZNER_SSH_PORT) $(HCLOUD) rebuild $(HETZNER_SERVER)

# Runs as root on port 22, so do it before hetzner-apply closes 22. The script ends by moving sshd
# to the custom port and turning root login off.
hetzner-bootstrap: ## Hetzner: harden the rebuilt server and install k3s (ACME_EMAIL=...)
	@test -n "$(ACME_EMAIL)" || { echo "ACME_EMAIL is required"; exit 1; }
	ssh -o StrictHostKeyChecking=accept-new root@$$($(HCLOUD) ip $(HETZNER_SERVER)) \
		ADMIN_USER=$(HETZNER_ADMIN) SSH_PORT=$(HETZNER_SSH_PORT) ACME_EMAIL=$(ACME_EMAIL) \
		bash -s < hetzner/scripts/bootstrap.sh

hetzner-apply: ## Hetzner: apply firewall, IPs, DNS and server settings
	$(TOFU) apply

hetzner-shell: ## Hetzner: SSH into the VM (port 1337, key only)
	$(SSH_HZ)

hetzner-kubeconfig: ## Hetzner: fetch the kubeconfig (use with hetzner-tunnel)
	$(SSH_HZ) sudo cat /etc/rancher/k3s/k3s.yaml \
		| sed 's#https://127.0.0.1:6443#https://127.0.0.1:$(HETZNER_API_PORT)#; s#: default$$#: hetzner#' \
		> $(HETZNER_KUBECONFIG)
	chmod 600 $(HETZNER_KUBECONFIG)

hetzner-tunnel: ## Hetzner: forward the k3s API to localhost:16443 (keep running)
	$(SSH_HZ) -N -L $(HETZNER_API_PORT):127.0.0.1:6443

hetzner-install-cnpg: ## Hetzner: install the CloudNativePG operator
	helm repo add cnpg https://cloudnative-pg.github.io/charts # no-op when already added
	helm repo update cnpg
	$(KUBE_HZ) helm upgrade --install cnpg cnpg/cloudnative-pg \
		--version $(CNPG_VERSION) --namespace cnpg-system --create-namespace \
		--wait --timeout 5m
	$(KUBE_HZ) kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cloudnative-pg -n cnpg-system --timeout=300s

# First install: Gerbil stays at 0 replicas until the admin account exists (hetzner-pangolin-ready).
hetzner-install-pangolin: ## Hetzner: install Pangolin (needs hetzner-install-cnpg)
	helm repo add fossorial https://charts.fossorial.io # no-op when already added
	helm repo update fossorial
	$(KUBE_HZ) kubectl apply -k hetzner/apps/pangolin
	@# Created once so the secret never rotates on re-runs; back it up to 1Password.
	@if ! $(KUBE_HZ) kubectl get secret pangolin-app-secret -n pangolin >/dev/null 2>&1; then \
		$(KUBE_HZ) kubectl create secret generic pangolin-app-secret -n pangolin \
			--from-literal=SERVER_SECRET="$$(openssl rand -hex 32)"; \
	fi
	$(PANGOLIN_HELM) --set gerbil.startupMode=delayed --wait --timeout 10m
	$(KUBE_HZ) kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=pangolin -n pangolin --timeout=300s
	@echo "Open https://$(call tf_out,pangolin_host)/auth/initial-setup, token: make hetzner-pangolin-setup-token"

hetzner-pangolin-setup-token: ## Hetzner: print Pangolin's first-run setup token
	$(KUBE_HZ) kubectl logs -n pangolin deploy/pangolin -c pangolin \
		| sed -n '/SETUP TOKEN GENERATED/,/================================/p'

hetzner-pangolin-ready: ## Hetzner: start Gerbil after the Pangolin initial setup
	$(PANGOLIN_HELM) --set gerbil.startupMode=normal --wait --timeout 10m
	$(KUBE_HZ) kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=gerbil -n pangolin --timeout=300s
