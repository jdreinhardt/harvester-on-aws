# =============================================================================
# Harvester on AWS -- AMI build pipeline
#
# The logic lives in the numbered scripts; this only fills the gaps between them
# (AWS resource lifecycle, SSH, snapshot polling) so the whole thing is one
# command. Running the scripts by hand as the readme describes still works.
#
#   make ami        build an AMI end to end and publish it to SSM
#   make ami-all    build amd64 and arm64 at the same time
#   make teardown   remove the helper instance, volume and security group
#   make help       list targets
#
# ARCH selects the target architecture: amd64 (default) or arm64. They are
# fully independent -- separate helper instance, volume, security group, state
# directory, AMI name and SSM parameter -- so two builds can run at once
# without a terminal multiplexer. `make ami-all` does exactly that and writes
# each build's output to its own log.
#
# Everything happens on a helper instance in AWS, including the QEMU install:
# 01-build-instance.sh --device writes straight to the attached EBS volume, so
# there is no raw image file, no zstd, and no S3 round trip.
#
# Progress is tracked with stamp files under $(STATE), so an interrupted run
# resumes rather than repeating the ~1 hour install.
# =============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# --- architecture -------------------------------------------------------
# amd64 builds on a virtualized instance with nested virtualization; arm64 has
# to build on bare metal, because no virtualized Graviton type offers it.
ARCH              ?= amd64

ifeq ($(ARCH),amd64)
AWS_ARCH           = x86_64
HELPER_TYPE       ?= m8i.4xlarge
# Enhanced networking via the ixgbevf driver. x86 only -- Graviton is ENA-only,
# and the flag has no meaning there.
SRIOV              = --sriov-net-support simple
else ifeq ($(ARCH),arm64)
AWS_ARCH           = arm64
# Graviton2 metal, verified. c7g/c8g metal types work too and are larger.
HELPER_TYPE       ?= c6g.metal
SRIOV              =
else
$(error ARCH must be amd64 or arm64, got "$(ARCH)")
endif

# Nested virtualization is an opt-in flag for VIRTUALIZED instances. A metal
# instance has the real CPU and REJECTS the flag rather than ignoring it, so
# key off the instance type rather than the architecture -- that stays correct
# if someone points an amd64 build at a metal type.
ifeq ($(findstring .metal,$(HELPER_TYPE)),.metal)
NESTED_VIRT        =
else
NESTED_VIRT        = --cpu-options NestedVirtualization=enabled
endif

HARVESTER_VERSION ?= v1.9.0
VOLUME_SIZE       ?= 250
# Architecture is its own path segment, before the version, so a build of one
# architecture can never repoint the parameter the other one reads.
SSM_PARAMETER     ?= /harvester/ami/$(ARCH)/latest
# AMI names must be unique per account per region: register-image rejects a
# duplicate rather than overwriting, and it does so at the very END of the build.
# A timestamped name keeps successive builds from colliding; SSM_PARAMETER is the
# stable pointer.
BUILD_ID          ?= $(shell date +%Y%m%d-%H%M%S)
AMI_NAME          ?= harvester-$(HARVESTER_VERSION)-$(ARCH)-$(BUILD_ID)

# HELPER_TYPE is set per-architecture above. Whatever it is, it must give the
# helper a real /dev/kvm: the install imports several GB of container images
# through a real RKE2 server, and software emulation makes that take days
# rather than an hour.
# Root disk for the helper itself: it holds the Harvester ISO plus the QEMU and
# OVMF packages. The distro default (8 GiB on AL2023) is nowhere near enough --
# the ISO download dies with ENOSPC. Nothing here touches the 250 GiB target.
HELPER_ROOT_SIZE  ?= 60

# al2023 or ubuntu. The helper AMI, package names, login user and firmware
# paths all vary by distro AND by architecture -- four combinations.
# 01-build-instance.sh takes the firmware paths as env vars (still named OVMF_*
# on both arches, though on arm64 they point at AAVMF/edk2-aarch64 images), so
# nothing else in the pipeline is distro- or arch-aware.
HELPER_OS         ?= al2023

ifeq ($(HELPER_OS),al2023)
REMOTE        = ec2-user
ifeq ($(ARCH),amd64)
HELPER_OS_SSM = /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
PKG_INSTALL   = sudo dnf -y -q install qemu-system-x86 qemu-img edk2-ovmf zstd gdisk
OVMF_CODE     = /usr/share/OVMF/OVMF_CODE.fd
OVMF_VARS     = /usr/share/OVMF/OVMF_VARS.fd
else
HELPER_OS_SSM = /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64
PKG_INSTALL   = sudo dnf -y -q install qemu-system-aarch64 qemu-img edk2-aarch64 zstd gdisk
OVMF_CODE     = /usr/share/edk2/aarch64/QEMU_EFI.fd
OVMF_VARS     = /usr/share/edk2/aarch64/QEMU_VARS.fd
endif
else ifeq ($(HELPER_OS),ubuntu)
REMOTE        = ubuntu
ifeq ($(ARCH),amd64)
HELPER_OS_SSM = /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id
PKG_INSTALL   = sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-system-x86 qemu-utils ovmf zstd gdisk
OVMF_CODE     = /usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS     = /usr/share/OVMF/OVMF_VARS_4M.fd
else
HELPER_OS_SSM = /aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id
PKG_INSTALL   = sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-system-arm qemu-utils qemu-efi-aarch64 zstd gdisk
OVMF_CODE     = /usr/share/AAVMF/AAVMF_CODE.fd
OVMF_VARS     = /usr/share/AAVMF/AAVMF_VARS.fd
endif
else
$(error HELPER_OS must be al2023 or ubuntu, got "$(HELPER_OS)")
endif

RELEASE_BASE      ?= https://releases.rancher.com/harvester/$(HARVESTER_VERSION)

# Required from the caller.
SUBNET_ID         ?=
KEY_NAME          ?=
KEY_FILE          ?= $(HOME)/.ssh/$(KEY_NAME).pem
# Defaults to this machine's public address, so SSH is not open to the world.
SSH_CIDR          ?= $(shell curl -s --max-time 10 https://checkip.amazonaws.com | tr -d '\n')/32

AWS               := aws
# Per-architecture, so two builds never share a stamp file.
STATE_ROOT        := .make
STATE             := $(STATE_ROOT)/$(ARCH)
SSH_OPTS          := -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$(STATE)/known_hosts -o ConnectTimeout=10

.PHONY: help ami ami-all teardown teardown-all clean rebuild check migrate
.DEFAULT_GOAL := help

help:
	@echo "Harvester AMI pipeline"
	@echo ""
	@echo "  make ami        build an AMI end to end (~2 hours) and publish to SSM"
	@echo "  make ami-all    build amd64 and arm64 at once, each logging to its own file"
	@echo "  make teardown   delete the helper instance, volume and security group"
	@echo "  make rebuild    teardown + clear stamps so 'make ami' runs again"
	@echo "  make clean      teardown, plus discard local state"
	@echo "  make teardown-all  teardown both architectures"
	@echo ""
	@echo "Required:  SUBNET_ID=subnet-xxxx KEY_NAME=my-key"
	@echo "Optional:  ARCH HARVESTER_VERSION HELPER_OS HELPER_TYPE HELPER_ROOT_SIZE"
	@echo "           VOLUME_SIZE SSM_PARAMETER SSH_CIDR KEY_FILE"
	@echo "           HELPER_OS is al2023 (default) or ubuntu"
	@echo "           ARCH is amd64 (default) or arm64; arm64 needs a .metal helper"
	@echo ""
	@echo "Per-arch:  state, tags, AMI name and SSM path all carry ARCH, so two"
	@echo "           builds can run at the same time without interfering."
	@echo ""
	@echo "Resumable: progress is stamped under $(STATE)/, so a failed run picks up"
	@echo "where it stopped instead of repeating the install."

check: migrate
	@test -n "$(SUBNET_ID)" || { echo "ERROR: set SUBNET_ID=subnet-xxxx"; exit 1; }
	@test -n "$(KEY_NAME)"  || { echo "ERROR: set KEY_NAME=my-key"; exit 1; }
	@test -f "$(KEY_FILE)"  || { echo "ERROR: key file $(KEY_FILE) not found (set KEY_FILE=)"; exit 1; }
	@command -v $(AWS) >/dev/null || { echo "ERROR: aws CLI not found"; exit 1; }
	@EXISTING=$$($(AWS) ec2 describe-images --owners self \
		--filters "Name=name,Values=$(AMI_NAME)" --query 'Images[0].ImageId' --output text 2>/dev/null); \
	test "$$EXISTING" = "None" -o -z "$$EXISTING" || { \
		echo "ERROR: an AMI named $(AMI_NAME) already exists ($$EXISTING)."; \
		echo "       Names are unique per account per region, so register-image would"; \
		echo "       fail at the END of a two-hour build. Set AMI_NAME=... or run"; \
		echo "       'aws ec2 deregister-image --image-id $$EXISTING' first."; exit 1; }

$(STATE):
	@mkdir -p $(STATE)

# A pre-arch build left its stamps directly in .make/. Those name a real
# snapshot and AMI -- the same reason `clean` keeps them -- so migrate rather
# than orphan. amd64 only: that is what the old pipeline built.
#
# Deliberately its own always-run target rather than part of the $(STATE)
# directory rule: that rule fires only when the directory is absent, and
# `ami-all` creates both directories up front, which would skip the migration
# permanently and silently.
migrate:
	@if [ "$(ARCH)" = amd64 ] && [ -f $(STATE_ROOT)/ami-id ] && [ ! -f $(STATE)/ami-id ]; then \
		mkdir -p $(STATE); \
		echo "==> migrating pre-arch build state into $(STATE)/"; \
		for f in ami-id snapshot-id built customized provisioned attached \
			  instance-id volume-id sg-id known_hosts; do \
			[ -e $(STATE_ROOT)/$$f ] && mv $(STATE_ROOT)/$$f $(STATE)/$$f || true; \
		done; \
	fi

# --- helper instance, volume, security group --------------------------------
# `check` is order-only (after the |) on purpose. It is phony, and a phony
# NORMAL prerequisite makes its target permanently out of date -- every
# `make ami` would then create a fresh security group, volume and instance and
# overwrite the stamp holding the previous one's id. Order-only still runs it
# first, without forcing the rebuild.
$(STATE)/sg-id: | check $(STATE)
	@echo "==> security group (SSH from $(SSH_CIDR))"
	@VPC=$$($(AWS) ec2 describe-subnets --subnet-ids $(SUBNET_ID) --query 'Subnets[0].VpcId' --output text); \
	SG=$$($(AWS) ec2 create-security-group --group-name harvester-build-$$$$ \
		--description "Harvester AMI build helper" --vpc-id $$VPC --query GroupId --output text); \
	$(AWS) ec2 authorize-security-group-ingress --group-id $$SG \
		--protocol tcp --port 22 --cidr $(SSH_CIDR) >/dev/null; \
	echo $$SG > $@; echo "    $$SG"

$(STATE)/volume-id: | check $(STATE)
	@echo "==> $(VOLUME_SIZE) GiB volume"
	@AZ=$$($(AWS) ec2 describe-subnets --subnet-ids $(SUBNET_ID) --query 'Subnets[0].AvailabilityZone' --output text); \
	$(AWS) ec2 create-volume --size $(VOLUME_SIZE) --volume-type gp3 --availability-zone $$AZ \
		--tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=harvester-build-$(ARCH)}]' \
		--query VolumeId --output text > $@; \
	echo "    $$(cat $@)"

$(STATE)/instance-id: $(STATE)/sg-id | check
	@echo "==> helper instance ($(HELPER_TYPE), $(ARCH))"
	@OS_AMI=$$($(AWS) ssm get-parameter --name $(HELPER_OS_SSM) --query 'Parameter.Value' --output text); \
	ROOT_DEV=$$($(AWS) ec2 describe-images --image-ids $$OS_AMI --query 'Images[0].RootDeviceName' --output text); \
	echo "    $$OS_AMI root=$$ROOT_DEV"; \
	$(AWS) ec2 run-instances --image-id $$OS_AMI --instance-type $(HELPER_TYPE) \
		--subnet-id $(SUBNET_ID) --security-group-ids $$(cat $(STATE)/sg-id) \
		--key-name $(KEY_NAME) --associate-public-ip-address \
		$(NESTED_VIRT) \
		--block-device-mappings "DeviceName=$$ROOT_DEV,Ebs={VolumeSize=$(HELPER_ROOT_SIZE),VolumeType=gp3,DeleteOnTermination=true}" \
		--tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=harvester-build-$(ARCH)}]' \
		--query 'Instances[0].InstanceId' --output text > $@; \
	echo "    $$(cat $@), waiting for it to run"
	@$(AWS) ec2 wait instance-running --instance-ids $$(cat $@)

$(STATE)/attached: $(STATE)/instance-id $(STATE)/volume-id
	@echo "==> attaching volume"
	@$(AWS) ec2 wait volume-available --volume-ids $$(cat $(STATE)/volume-id)
	@$(AWS) ec2 attach-volume --volume-id $$(cat $(STATE)/volume-id) \
		--instance-id $$(cat $(STATE)/instance-id) --device /dev/sdf >/dev/null
	@$(AWS) ec2 wait volume-in-use --volume-ids $$(cat $(STATE)/volume-id)
	@touch $@

# --- build and customise on the helper --------------------------------------
$(STATE)/provisioned: $(STATE)/attached
	@echo "==> waiting for SSH, then installing QEMU/OVMF and fetching artifacts"
	@IP=$$($(AWS) ec2 describe-instances --instance-ids $$(cat $(STATE)/instance-id) \
		--query 'Reservations[0].Instances[0].PublicIpAddress' --output text); \
	for i in $$(seq 1 40); do \
		ssh $(SSH_OPTS) -i $(KEY_FILE) $(REMOTE)@$$IP true 2>/dev/null && break || sleep 15; \
	done; \
	ssh $(SSH_OPTS) -i $(KEY_FILE) $(REMOTE)@$$IP 'mkdir -p ~/scripts'; \
	scp $(SSH_OPTS) -i $(KEY_FILE) scripts/00-fetch-artifacts.sh scripts/01-build-instance.sh \
		scripts/02-customize-instance.sh $(REMOTE)@$$IP:~/scripts/ ; \
	ssh $(SSH_OPTS) -i $(KEY_FILE) $(REMOTE)@$$IP 'set -eu; \
		$(PKG_INSTALL) >/dev/null; \
		test -w /dev/kvm || { echo "ERROR: /dev/kvm missing or not writable."; \
			echo "       A virtualized helper needs --cpu-options NestedVirtualization=enabled,"; \
			echo "       which is launch-time only. A .metal helper should have KVM natively;"; \
			echo "       if it does not, the instance type is wrong for $(ARCH)."; \
			echo "       Either way: 'make teardown ARCH=$(ARCH)' and retry."; exit 1; }; \
		HARVESTER_VERSION=$(HARVESTER_VERSION) ARCH=$(ARCH) RELEASE_BASE=$(RELEASE_BASE) \
			./scripts/00-fetch-artifacts.sh'
	@touch $@

$(STATE)/built: $(STATE)/provisioned
	@echo "==> installing Harvester onto the volume (this takes ~1 hour)"
	@IP=$$($(AWS) ec2 describe-instances --instance-ids $$(cat $(STATE)/instance-id) \
		--query 'Reservations[0].Instances[0].PublicIpAddress' --output text); \
	ssh $(SSH_OPTS) -i $(KEY_FILE) $(REMOTE)@$$IP \
		"set -eu; DEV=\$$(lsblk -dbpno NAME,SIZE | grep -v \"\$$(lsblk -no pkname \$$(findmnt -no SOURCE /))\" | awk -v w=\$$(( $(VOLUME_SIZE) * 1073741824 )) '\$$2 >= w {print \$$1; exit}'); \
		 test -n \"\$$DEV\" || { echo 'ERROR: could not find the $(VOLUME_SIZE) GiB volume'; lsblk; exit 1; }; \
		 echo \"target device: \$$DEV\"; \
		 sudo HARVESTER_VERSION=$(HARVESTER_VERSION) ARCH=$(ARCH) \
			OVMF_CODE=$(OVMF_CODE) OVMF_VARS_TEMPLATE=$(OVMF_VARS) \
			./scripts/01-build-instance.sh --device \$$DEV"
	@touch $@

$(STATE)/customized: $(STATE)/built
	@echo "==> customising for AWS"
	@IP=$$($(AWS) ec2 describe-instances --instance-ids $$(cat $(STATE)/instance-id) \
		--query 'Reservations[0].Instances[0].PublicIpAddress' --output text); \
	ssh $(SSH_OPTS) -i $(KEY_FILE) $(REMOTE)@$$IP \
		"set -eu; DEV=\$$(lsblk -dbpno NAME,SIZE | grep -v \"\$$(lsblk -no pkname \$$(findmnt -no SOURCE /))\" | awk -v w=\$$(( $(VOLUME_SIZE) * 1073741824 )) '\$$2 >= w {print \$$1; exit}'); \
		 sudo ./scripts/02-customize-instance.sh \$$DEV"
	@touch $@

# --- snapshot, register, publish --------------------------------------------
# NOT `aws ec2 wait snapshot-completed`: every EC2 waiter gives up after 40
# attempts at 15s, i.e. 10 minutes, and a first snapshot of a 250 GiB volume
# routinely takes an hour.
$(STATE)/snapshot-id: $(STATE)/customized
	@echo "==> detaching volume and snapshotting"
	@$(AWS) ec2 detach-volume --volume-id $$(cat $(STATE)/volume-id) >/dev/null
	@$(AWS) ec2 wait volume-available --volume-ids $$(cat $(STATE)/volume-id)
	@$(AWS) ec2 create-snapshot --volume-id $$(cat $(STATE)/volume-id) \
		--description "$(AMI_NAME)" --query SnapshotId --output text > $@
	@echo "    $$(cat $@) -- polling until complete, can take an hour"
	@until [ "$$($(AWS) ec2 describe-snapshots --snapshot-ids $$(cat $@) \
		--query 'Snapshots[0].State' --output text)" = completed ]; do \
		printf '\r    %s%%   ' "$$($(AWS) ec2 describe-snapshots --snapshot-ids $$(cat $@) \
			--query 'Snapshots[0].Progress' --output text | tr -d '%%')"; sleep 30; \
	done; echo ""

$(STATE)/ami-id: $(STATE)/snapshot-id
	@echo "==> registering AMI"
	@$(AWS) ec2 register-image --name "$(AMI_NAME)" --architecture $(AWS_ARCH) \
		--virtualization-type hvm --boot-mode uefi --root-device-name /dev/sda1 \
		--block-device-mappings "DeviceName=/dev/sda1,Ebs={SnapshotId=$$(cat $<),VolumeSize=$(VOLUME_SIZE),VolumeType=gp3,DeleteOnTermination=true}" \
		--ena-support $(SRIOV) --imds-support v2.0 \
		--query ImageId --output text > $@
	@echo "    $$(cat $@)"
	@$(AWS) ssm put-parameter --name $(SSM_PARAMETER) --type String --overwrite \
		--value $$(cat $@) >/dev/null
	@echo "    published to $(SSM_PARAMETER)"

ami: $(STATE)/ami-id
	@echo ""
	@echo "AMI $$(cat $(STATE)/ami-id) is ready and $(SSM_PARAMETER) points at it."
	@echo "Run 'make teardown ARCH=$(ARCH)' to remove the helper instance and volume."

# Both architectures at once. Nothing is shared -- separate instance, volume,
# security group, state directory, AMI name and SSM parameter -- so this needs
# no terminal multiplexer and no -j. Each build's output goes to its own log
# rather than being interleaved on one terminal, because a two-hour build with
# a live snapshot percentage is unreadable mixed with another.
#
# SSH_CIDR and BUILD_ID are passed down so the sub-makes do not each re-run the
# checkip curl, and so both AMIs carry the same build id. Command-line
# variables (SUBNET_ID, KEY_NAME, ...) propagate to sub-makes on their own.
ami-all:
	@echo "==> building amd64 and arm64 in parallel"
	@echo "    follow with:  tail -f $(STATE_ROOT)/amd64/build.log"
	@echo "                  tail -f $(STATE_ROOT)/arm64/build.log"
	@echo ""
	@mkdir -p $(STATE_ROOT)/amd64 $(STATE_ROOT)/arm64; RC=0; \
		$(MAKE) --no-print-directory ami ARCH=amd64 SSH_CIDR=$(SSH_CIDR) BUILD_ID=$(BUILD_ID) \
			>$(STATE_ROOT)/amd64/build.log 2>&1 & A=$$!; \
		$(MAKE) --no-print-directory ami ARCH=arm64 SSH_CIDR=$(SSH_CIDR) BUILD_ID=$(BUILD_ID) \
			>$(STATE_ROOT)/arm64/build.log 2>&1 & B=$$!; \
		wait $$A || RC=1; \
		wait $$B || RC=1; \
		echo ""; \
		for a in amd64 arm64; do \
			if [ -f $(STATE_ROOT)/$$a/ami-id ]; then \
				echo "  $$a  $$(cat $(STATE_ROOT)/$$a/ami-id)"; \
			else \
				echo "  $$a  FAILED -- see $(STATE_ROOT)/$$a/build.log"; \
			fi; \
		done; \
		exit $$RC

teardown-all:
	@$(MAKE) --no-print-directory teardown ARCH=amd64
	@$(MAKE) --no-print-directory teardown ARCH=arm64

# --- cleanup ----------------------------------------------------------------
# Retries, and the stamp is kept when a delete fails. The ENI can take a few
# seconds to release after the instance terminates, so delete-security-group
# returns DependencyViolation if tried immediately -- and an unconditional
# `rm -f` after `|| true` would orphan the group while discarding the only
# record of its id. That matters most for unattended runs.
teardown:
	@if [ -f $(STATE)/instance-id ]; then \
		echo "==> terminating $$(cat $(STATE)/instance-id)"; \
		$(AWS) ec2 terminate-instances --instance-ids $$(cat $(STATE)/instance-id) >/dev/null; \
		$(AWS) ec2 wait instance-terminated --instance-ids $$(cat $(STATE)/instance-id); \
		rm -f $(STATE)/instance-id $(STATE)/attached $(STATE)/provisioned; \
	fi
	@if [ -f $(STATE)/volume-id ]; then \
		V=$$(cat $(STATE)/volume-id); echo "==> deleting $$V"; \
		OK=0; for i in 1 2 3 4 5 6; do \
			if $(AWS) ec2 delete-volume --volume-id $$V >/dev/null 2>&1; then OK=1; break; fi; \
			sleep 10; \
		done; \
		if [ $$OK = 1 ]; then rm -f $(STATE)/volume-id; \
		else echo "    WARNING: could not delete $$V -- keeping $(STATE)/volume-id so it is not lost"; fi; \
	fi
	@if [ -f $(STATE)/sg-id ]; then \
		G=$$(cat $(STATE)/sg-id); echo "==> deleting $$G"; \
		OK=0; for i in 1 2 3 4 5 6; do \
			if $(AWS) ec2 delete-security-group --group-id $$G >/dev/null 2>&1; then OK=1; break; fi; \
			sleep 10; \
		done; \
		if [ $$OK = 1 ]; then rm -f $(STATE)/sg-id; \
		else echo "    WARNING: could not delete $$G -- keeping $(STATE)/sg-id so it is not lost"; fi; \
	fi

# Start a fresh build. `ami` is a no-op once $(STATE)/ami-id exists, so this is
# what you want after a successful run -- e.g. to rebuild against a fixed
# configure.sh. The snapshot and AMI from the previous build are NOT deleted;
# they are printed so they can be removed deliberately.
rebuild: teardown
	@echo "==> previous build left these in place:"
	@if [ -f $(STATE)/snapshot-id ]; then echo "      snapshot $$(cat $(STATE)/snapshot-id)"; fi
	@if [ -f $(STATE)/ami-id ];      then echo "      AMI      $$(cat $(STATE)/ami-id)"; fi
	@rm -f $(STATE)/built $(STATE)/customized $(STATE)/provisioned $(STATE)/attached \
	       $(STATE)/snapshot-id $(STATE)/ami-id $(STATE)/known_hosts
	@echo "==> $(ARCH) build state cleared; 'make ami ARCH=$(ARCH)' will start from scratch"

# Keeps snapshot-id and ami-id: those name real resources the teardown does not
# touch, and losing the file would orphan them silently.
clean: teardown
	@rm -f $(STATE)/built $(STATE)/customized $(STATE)/known_hosts
	@echo "Local build state cleared. $(STATE)/snapshot-id and $(STATE)/ami-id kept."
