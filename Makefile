# Set Shell to bash, otherwise some targets fail with dash/zsh etc.
SHELL := /bin/bash

# Disable built-in rules
MAKEFLAGS += --no-builtin-rules
MAKEFLAGS += --no-builtin-variables
.SUFFIXES:
.SECONDARY:
.DEFAULT_GOAL := help

# General variables
include Makefile.vars.mk
# KIND module
include kind/kind.mk
# Docs module
include docs/antora-preview.mk docs/antora-build.mk

help: ## Show this help
	@grep -E -h '\s##\s' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

lint: ## All-in-one linting
	@echo 'Check for uncommitted changes ...'
	git diff --exit-code

service-definition: export KUBECONFIG = $(KIND_KUBECONFIG)
service-definition: crossplane-setup k8up-setup prometheus-setup ## Install the compositions
	kubectl apply -f crossplane/stackgres/composite.yaml
	kubectl apply -f crossplane/stackgres/composition.yaml
	kubectl wait --for condition=Offered compositeresourcedefinition/xpostgresqlinstances.syn.tools
	kubectl apply -f crossplane/user/composite.yaml
	kubectl apply -f crossplane/user/composition.yaml
	kubectl wait --for condition=Offered compositeresourcedefinition/xpostgresqlusers.syn.tools

provision: export KUBECONFIG = $(KIND_KUBECONFIG)
provision: stackgres-setup
	kubectl apply -f service/prototype-instance.yaml

deprovision: export KUBECONFIG = $(KIND_KUBECONFIG)
deprovision: kind-setup ## Uninstall the service instance
	kubectl delete -f service/prototype-instance.yaml

crossplane-setup: $(crossplane_sentinel) ## Install local Kubernetes cluster and install Crossplane

$(crossplane_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(crossplane_sentinel): kind-setup
	helm repo add crossplane https://charts.crossplane.io/stable
	helm repo add mittwald https://helm.mittwald.de
	helm upgrade --install crossplane --create-namespace --namespace crossplane-system crossplane/crossplane --set "args[0]='--debug'" --set "args[1]='--enable-composition-revisions'" --wait
	helm upgrade --install secret-generator --create-namespace --namespace secret-generator mittwald/kubernetes-secret-generator --wait
	kubectl apply -f crossplane/helm/provider.yaml
	kubectl wait --for condition=Healthy provider.pkg.crossplane.io/provider-helm --timeout 60s
	kubectl apply -f crossplane/helm/provider-config.yaml
	kubectl create clusterrolebinding crossplane:provider-helm-admin --clusterrole cluster-admin --serviceaccount crossplane-system:$$(kubectl get sa -n crossplane-system -o custom-columns=NAME:.metadata.name --no-headers | grep provider-helm)
	kubectl create clusterrolebinding crossplane:cluster-admin --clusterrole cluster-admin --serviceaccount crossplane-system:crossplane
	kubectl apply -f crossplane/kubernetes/provider.yaml
	kubectl wait --for condition=Healthy provider.pkg.crossplane.io/provider-kubernetes --timeout 60s
	kubectl apply -f crossplane/kubernetes/provider-config.yaml
	kubectl create clusterrolebinding crossplane:provider-kubernetes-admin --clusterrole cluster-admin --serviceaccount crossplane-system:$$(kubectl get sa -n crossplane-system -o custom-columns=NAME:.metadata.name --no-headers | grep provider-kubernetes)
	kubectl apply -f crossplane/provider-sql/provider.yaml
	kubectl wait --for condition=Healthy provider.pkg.crossplane.io/provider-sql --timeout 60s
	@touch $@

minio-setup: export KUBECONFIG = $(KIND_KUBECONFIG)
minio-setup: crossplane-setup ## Install Minio Crossplane implementation
	kubectl apply -f minio/s3-composite.yaml
	kubectl apply -f minio/s3-composition.yaml
	kubectl wait --for condition=Established compositeresourcedefinition/xs3buckets.syn.tools

k8up-setup: minio-setup #$(k8up_sentinel) ## Install K8up operator

$(k8up_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(k8up_sentinel): kind-setup
	helm repo add appuio https://charts.appuio.ch
	kubectl apply -f https://github.com/k8up-io/k8up/releases/latest/download/k8up-crd.yaml
	helm upgrade --install k8up --create-namespace --namespace k8up-system appuio/k8up --wait
	kubectl -n k8up-system wait --for condition=Available deployment/k8up --timeout 60s
	@touch $@

prometheus-setup: $(prometheus_sentinel) ## Install Prometheus stack

$(prometheus_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(prometheus_sentinel): kind-setup-ingress
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm upgrade --install kube-prometheus \
		--create-namespace \
		--namespace prometheus-system \
		--wait \
		--values prometheus/values.yaml \
		prometheus-community/kube-prometheus-stack
	kubectl -n prometheus-system wait --for condition=Available deployment/kube-prometheus-kube-prome-operator --timeout 120s
	@echo -e "***\n*** Installed Prometheus in http://127.0.0.1.nip.io:8081/prometheus/ and AlertManager in http://127.0.0.1.nip.io:8081/alertmanager/.\n***"
	@touch $@

stackgres-setup: $(stackgres_sentinel) ## Setup the stackgres operator

$(stackgres_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(stackgres_sentinel): crossplane-setup service-definition
	kubectl create ns stackgres
	helm install --namespace stackgres stackgres-operator https://stackgres.io/downloads/stackgres-k8s/stackgres/latest/helm/stackgres-operator.tgz
	@touch $@

.PHONY: clean
clean: kind-clean ## Clean up local dev environment

tests: export KUBECONFIG = $(KIND_KUBECONFIG)
tests: stackgres-setup ## run tests with kuttl NOTE: no other insntance should be provisioned when running the tests!
	kubectl kuttl test ./test

provision-user: export KUBECONFIG = $(KIND_KUBECONFIG)
provision-user: provision ## creates a demo user
	kubectl apply -f service/prototype-user.yaml

deprovision-user: export KUBECONFIG = $(KIND_KUBECONFIG)
deprovision-user: ## remove demo user
	kubectl delete -f service/prototype-user.yaml

create-connection-test: export KUBECONFIG = $(KIND_KUBECONFIG)
create-connection-test: provision-user ## create a test pods to test the connection
	kubectl apply -f service/test-job.yaml

delete-connection-test: export KUBECONFIG = $(KIND_KUBECONFIG)
delete-connection-test: ## remove the test pod
	kubectl delete -f service/test-job.yaml

