SHELL := /bin/bash

# Load .env (copy .env.example) and export everything to child processes.
-include .env
export

export KUBECONFIG ?= $(CURDIR)/kubeconfig

.PHONY: deps provision server firewall k3s kubeconfig bootstrap backup-sealing-key

## Install local dependencies (Ansible collections + hcloud python lib)
deps:
	python3 -m pip install --user hcloud
	ansible-galaxy collection install -r ansible/requirements.yml

## Create the Hetzner server + firewall and install k3s (full run)
provision:
	cd ansible && ansible-playbook playbooks/site.yml

## Only create/update the Hetzner server + firewall
server:
	cd ansible && ansible-playbook playbooks/01-provision.yml

## Refresh firewall rules with the current public IP (dynamic IP changed)
firewall:
	cd ansible && ansible-playbook playbooks/01-provision.yml --tags firewall

## Only (re)configure the node and install/upgrade k3s
k3s:
	cd ansible && ansible-playbook playbooks/02-k3s.yml

## Re-fetch the kubeconfig from the node
kubeconfig:
	cd ansible && ansible-playbook playbooks/02-k3s.yml --tags kubeconfig

## One-time: install ArgoCD and apply the root app (GitOps takes over from there)
bootstrap:
	./scripts/bootstrap-argocd.sh

## Save the sealed-secrets master key (store it in a password manager!)
backup-sealing-key:
	kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > master.key
	@echo "master.key written — store it in a password manager, then delete the file."
