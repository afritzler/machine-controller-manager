# Copyright (c) 2018 SAP SE or an SAP affiliate company. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

IMAGE_REPOSITORY   := eu.gcr.io/gardener-project/gardener/machine-controller-manager
IMAGE_TAG          := $(shell cat VERSION)
COVERPROFILE       := test/output/coverprofile.out

CONTROL_NAMESPACE := default
CONTROL_KUBECONFIG := dev/target-kubeconfig.yaml
TARGET_KUBECONFIG := dev/target-kubeconfig.yaml

LEADER_ELECT 	   := "true"
MACHINE_SAFETY_OVERSHOOTING_PERIOD:=1m

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

###########################################
# Rules When K8s cluster is Gardener Shoot#
###########################################

.PHONY: downlaod-kubeconfigs
download-kubeconfigs:
	@echo "enter project name"; \
	read PROJECT; \
	echo "enter seed name"; \
	read SEED; \
	echo "enter shoot name"; \
	read SHOOT; \
	echo "enter cluster provider(gcp|aws|azure|vsphere|openstack|alicloud|metal|equinix-metal)"; \
	read PROVIDER; \
	./hack/local_setup.sh --SEED $$SEED --SHOOT $$SHOOT --PROJECT $$PROJECT --PROVIDER $$PROVIDER

.PHONY: local-mcm-up
local-mcm-up: download-kubeconfigs
	$(MAKE) start;

.PHONY: local-mcm-down
local-mcm-down: 
	@kubectl --kubeconfig=${CONTROL_KUBECONFIG} -n ${CONTROL_NAMESPACE} annotate --overwrite=true deployment/machine-controller-manager dependency-watchdog.gardener.cloud/ignore-scaling-
	@kubectl --kubeconfig=${CONTROL_KUBECONFIG} scale -n ${CONTROL_NAMESPACE} deployment/machine-controller-manager --replicas=1
	@rm ${CONTROL_KUBECONFIG}
	@rm ${TARGET_KUBECONFIG}

#########################################
# Rules for local development scenarios #
#########################################

.PHONY: start
start:
	@GO111MODULE=on go run \
			-mod=vendor \
			cmd/machine-controller-manager/controller_manager.go \
			--control-kubeconfig=${CONTROL_KUBECONFIG} \
			--target-kubeconfig=${TARGET_KUBECONFIG} \
			--namespace=${CONTROL_NAMESPACE} \
			--safety-up=2 \
			--safety-down=1 \
			--machine-creation-timeout=20m \
			--machine-drain-timeout=5m \
			--machine-pv-detach-timeout=2m \
			--machine-health-timeout=10m \
			--machine-safety-apiserver-statuscheck-timeout=30s \
			--machine-safety-apiserver-statuscheck-period=1m \
			--machine-safety-orphan-vms-period=30m \
			--machine-safety-overshooting-period=$(MACHINE_SAFETY_OVERSHOOTING_PERIOD) \
			--leader-elect=$(LEADER_ELECT) \
			--v=3

#################################################################
# Rules related to binary build, Docker image build and release #
#################################################################

.PHONY: revendor
revendor:
	@GO111MODULE=on go mod tidy -v
	@GO111MODULE=on go mod vendor -v

.PHONY: build
build:
	@.ci/build

.PHONY: release
release: build docker-image docker-login docker-push

.PHONY: docker-image
docker-image:
	@docker build -t $(IMAGE_REPOSITORY):$(IMAGE_TAG) --rm .

.PHONY: docker-login
docker-login:
	@gcloud auth activate-service-account --key-file .kube-secrets/gcr/gcr-readwrite.json

.PHONY: docker-push
docker-push:
	@if ! docker images $(IMAGE_REPOSITORY) | awk '{ print $$2 }' | grep -q -F $(IMAGE_TAG); then echo "$(IMAGE_REPOSITORY) version $(IMAGE_TAG) is not yet built. Please run 'make docker-images'"; false; fi
	@gcloud docker -- push $(IMAGE_REPOSITORY):$(IMAGE_TAG)

.PHONY: clean
clean:
	@rm -rf bin/

#####################################################################
# Rules for verification, formatting, linting, testing and cleaning #
#####################################################################

.PHONY: verify
verify: check test

.PHONY: check
check:
	@.ci/check

.PHONY: test
test:
	@.ci/test

.PHONY: test-unit
test-unit:
	@SKIP_INTEGRATION_TESTS=X .ci/test

.PHONY: test-integration
test-integration:
	@SKIP_UNIT_TESTS=X .ci/test

.PHONY: show-coverage
show-coverage:
	@if [ ! -f $(COVERPROFILE) ]; then echo "$(COVERPROFILE) is not yet built. Please run 'COVER=true make test'"; false; fi
	go tool cover -html $(COVERPROFILE)

.PHONY: test-clean
test-clean:
	@find . -name "*.coverprofile" -type f -delete
	@rm -f $(COVERPROFILE)

generate: controller-gen
	$(CONTROLLER_GEN) crd paths=./pkg/apis/machine/v1alpha1/... output:crd:dir=kubernetes/crds output:stdout
	@./hack/generate-code
	@./hack/api-reference/generate-spec-doc.sh

# find or download controller-gen
# download controller-gen if necessary
.PHONY: controller-gen
controller-gen:
ifeq (, $(shell which controller-gen))
	@{ \
	set -e ;\
	CONTROLLER_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$CONTROLLER_GEN_TMP_DIR ;\
	go mod init tmp ;\
	go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.9.2 ;\
	rm -rf $$CONTROLLER_GEN_TMP_DIR ;\
	}
CONTROLLER_GEN=$(GOBIN)/controller-gen
else
CONTROLLER_GEN=$(shell which controller-gen)
endif
