# Run the crio/ and containerd/ runtime tests in disposable QEMU VMs, as their
# setup installs system packages and needs a reboot. Host needs qemu-system-x86,
# qemu-utils, cloud-image-utils and /dev/kvm; no root.
#
#   make crio | containerd     # VM up, copy dir, setup, reboot, test
#   make stop-crio | stop-containerd
#   make clean                 # stop both, delete build/vm

SHELL := /bin/bash
BUILD := ../build/vm

# Ubuntu 24.04 cloud image, release 20261017
IMAGE_URL := https://cloud-images.ubuntu.com/noble/20261017/noble-server-cloudimg-amd64.img
IMAGE_SHA256 := 04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94
IMAGE := $(BUILD)/noble.img

PORT_crio := 2220
PORT_containerd := 2221
VM = VM_DIR=$(BUILD)/$(1) VM_NAME=signing-$(1) VM_PORT=$(PORT_$(1)) \
	VM_BASE=$(IMAGE) VM_MEM=6144 ./vm.sh

.PHONY: all check-tools crio containerd stop-crio stop-containerd clean

all:
	@echo "targets: crio containerd stop-crio stop-containerd clean"

check-tools:
	@for t in qemu-system-x86_64 qemu-img cloud-localds ssh curl; do \
		type -a $$t &>/dev/null || { echo "error: $$t missing"; exit 1; }; done
	@test -w /dev/kvm || { echo "error: /dev/kvm not writable"; exit 1; }

$(IMAGE):
	@mkdir -p $(BUILD)
	curl -sSfL -o $@.tmp $(IMAGE_URL)
	echo "$(IMAGE_SHA256)  $@.tmp" | sha256sum -c --quiet
	mv $@.tmp $@

crio containerd: check-tools $(IMAGE)
	$(call VM,$@) start
	$(call VM,$@) ssh 'cloud-init status --wait >/dev/null; command -v make >/dev/null || \
		{ sudo apt-get update -qq && sudo apt-get install -y -qq make; }'
	tar -C .. -cf - $@ | $(call VM,$@) ssh 'tar -xf - -C ~'
	$(call VM,$@) ssh 'cd ~/$@ && make setup'
	-$(call VM,$@) ssh 'sudo reboot'
	sleep 15
	$(call VM,$@) wait
	$(call VM,$@) ssh 'cd ~/$@ && make test'
	@echo "[OK] $@ runtime verification passed in the VM"

stop-crio stop-containerd: stop-%:
	$(call VM,$*) stop

clean: stop-crio stop-containerd
	rm -rf $(BUILD)
