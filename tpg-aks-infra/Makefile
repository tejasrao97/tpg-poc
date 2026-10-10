# Convenience targets. Run from the repository root.
TF ?= terraform
SHELL := /bin/bash
INVENTORY ?= inventory/clusters.yaml
RUN := ./scripts/run.sh

.PHONY: help init fmt plan apply destroy deploy deploy-terraform \
        install-terraform existing-terraform install-precreated existing-precreated \
        check-existing-hub vault vault-unseal addons verify access wf-logs test

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-22s %s\n", $$1, $$2}'

init: ## terraform init
	$(TF) -chdir=terraform init

fmt: ## terraform fmt
	$(TF) -chdir=terraform fmt -recursive

plan: ## terraform plan
	$(TF) -chdir=terraform plan -out=tfplan

apply: ## terraform apply (uses the saved plan)
	$(TF) -chdir=terraform apply tfplan

deploy: ## Local deployment, every step (deploy-scripts/deploy.sh all)
	deploy-scripts/deploy.sh all

deploy-terraform: ## Terraform-enabled deployment from the jumpbox (deploy-scripts/terraform-enabled-deploy.sh all)
	deploy-scripts/terraform-enabled-deploy.sh all

install-terraform: ## Scenario: Terraform clusters, install Argo on the hub
	$(RUN) --hub install --targets terraform

existing-terraform: ## Scenario: Terraform clusters, hub already has Argo
	$(RUN) --hub existing --targets terraform

install-precreated: ## Scenario: pre-created clusters, install Argo on the hub
	$(RUN) --hub install --targets precreated --inventory $(INVENTORY)

existing-precreated: ## Scenario: pre-created clusters, hub already has Argo
	$(RUN) --hub existing --targets precreated --inventory $(INVENTORY)

check-existing-hub: ## Read-only check of an existing Argo hub (pre-created inventory)
	$(RUN) --hub existing --targets precreated --inventory $(INVENTORY) --check-only

vault: ## Vault and the hub Vault Secrets Operator only (Terraform inventory)
	$(RUN) --hub install --targets terraform --only vault

vault-unseal: ## Unseal Vault after vault-0 restarted (unseal mode shamir; Terraform inventory)
	$(RUN) --hub install --targets terraform --only vault-unseal

access: ## Print every UI endpoint and login (terminal only; Terraform inventory)
	$(RUN) --hub install --targets terraform --only access

addons: ## Helm add-on releases only (Terraform inventory; MONITORING_OPTION from env.sh)
	$(RUN) --hub install --targets terraform --only addons

verify: ## Read-only verification (Terraform inventory)
	$(RUN) --hub install --targets terraform --only verify

wf-logs: ## Archived logs of one workflow run: make wf-logs WF=tpg-upgrade-z5jls
	@test -n "$(WF)" || { echo "set WF=<workflow name>"; exit 2; }
	./scripts/wf-logs.sh $(WF)

test: ## Offline tests (verify summary, preflight storage check, shared library with tpg-fleet, Argo CD RBAC, vault-secret.sh, jumpbox: setup, provisioning, fleet repository push, Vault keys file; deploy-scripts)
	tests/verify/run.sh
	tests/preflight/run.sh
	tests/shared-lib/run.sh
	tests/argocd-rbac/run.sh
	tests/vault-secret/run.sh
	tests/jumpbox/run.sh
	tests/deploy-scripts/run.sh

destroy: ## terraform destroy (deletes the resource group, all clusters and every backup)
	$(TF) -chdir=terraform destroy
