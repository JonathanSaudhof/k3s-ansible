SHELL := /bin/bash
.DEFAULT_GOAL := help

PVE_SSH_USER  ?= root
PVE_TEMPLATES ?= pve:9000 pve2:9001
SERVERS       ?= 1
AGENTS        ?= 2
KUBECONFIG_OUT := kubeconfig-proxmox
INVENTORY     := inventories/proxmox/hosts.ini

TEMPLATE_ARGS ?=
ANSIBLE_EXTRA ?=
SECRETS       := $(wildcard proxmox_secrets.yml)
VARS = -e k3s_server_count=$(SERVERS) -e k3s_agent_count=$(AGENTS) \
       $(if $(SECRETS),-e @proxmox_secrets.yml) $(ANSIBLE_EXTRA)

.PHONY: help deps check template vms k3s up down nodes shell clean

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
	@for t in $(PVE_TEMPLATES); do \
		node=$${t%%:*}; vmid=$${t##*:}; \
		echo "==> $$node (vmid $$vmid)"; \
		ssh $(PVE_SSH_USER)@$$node "bash -s -- --vmid $$vmid $(TEMPLATE_ARGS)" \
			< scripts/create-k3s-template.sh || exit 1; \
	done

vms: ## Create the k3s VMs and write the inventory
	ansible-playbook proxmox_vms.yml $(VARS)

k3s: ## Install k3s on the provisioned VMs
	ansible-playbook install_k3s.yml $(ANSIBLE_EXTRA)

up: vms k3s ## Provision VMs and install k3s

# SERVERS/AGENTS must match the values used for `up` so the same VMIDs are targeted.
down: ## Destroy the k3s VMs (templates are kept)
	ansible-playbook proxmox_vms.yml -e vm_state=absent $(VARS)

nodes: ## Show the k3s cluster nodes
	KUBECONFIG=$(KUBECONFIG_OUT) kubectl get nodes -o wide

shell: ## SSH into the first k3s server
	@ssh k3s@$$(awk '/ansible_host=/{sub(/.*ansible_host=/, ""); print $$1; exit}' $(INVENTORY))

clean: ## Remove the generated inventory and kubeconfig
	rm -f $(KUBECONFIG_OUT) $(INVENTORY)
