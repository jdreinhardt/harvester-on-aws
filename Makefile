# =============================================================================
# Harvester on AWS -- AMI build pipeline
#
# The logic lives in the numbered scripts; this only fills the gaps between them
# (AWS resource lifecycle, SSH, snapshot polling) so the whole thing is one
# command. Running the scripts by hand as the readme describes still works.
#
#   make ami        build an AMI end to end and publish it to SSM
#   make teardown   remove the helper instance, volume and security group
#   make help       list targets
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

HARVESTER_VERSION ?= v1.8.2
VOLUME_SIZE       ?= 250
SSM_PARAMETER     ?= /harvester/ami/latest
# AMI names must be unique per account per region: register-image rejects a
# duplicate rather than overwriting, and it does so at the very END of the build.
# A timestamped name keeps successive builds from colliding; SSM_PARAMETER is the
# stable pointer.
BUILD_ID          ?= $(shell date +%Y%m%d-%H%M%S)
AMI_NAME          ?= harvester-$(HARVESTER_VERSION)-$(BUILD_ID)

# The helper must support nested virtualization: the install imports several GB
# of container images through a real RKE2 server, and software emulation makes
# that take days rather than an hour.
HELPER_TYPE       ?= m8i.4xlarge
# Root disk for the helper itself: it holds the Harvester ISO plus the QEMU and
# OVMF packages. The distro default (8 GiB on AL2023) is nowhere near enough --
# the ISO download dies with ENOSPC. Nothing here touches the 250 GiB target.
HELPER_ROOT_SIZE  ?= 60

# al2023 or ubuntu. Package names, the login user and the OVMF paths all differ.
# 01-build-instance.sh takes the OVMF paths as env vars, so switching distro is
# only these four values.
HELPER_OS         ?= al2023

ifeq ($(HELPER_OS),al2023)
HELPER_OS_SSM = /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
REMOTE        = ec2-user
PKG_INSTALL   = sudo dnf -y -q install qemu-system-x86 qemu-img edk2-ovmf zstd gdisk
OVMF_CODE     = /usr/share/OVMF/OVMF_CODE.fd
OVMF_VARS     = /usr/share/OVMF/OVMF_VARS.fd
else ifeq ($(HELPER_OS),ubuntu)
HELPER_OS_SSM = /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id
REMOTE        = ubuntu
PKG_INSTALL   = sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-system-x86 qemu-utils ovmf zstd gdisk
OVMF_CODE     = /usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS     = /usr/share/OVMF/OVMF_VARS_4M.fd
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
STATE             := .make
SSH_OPTS          := -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$(STATE)/known_hosts -o ConnectTimeout=10

.PHONY: help ami teardown clean rebuild check
.DEFAULT_GOAL := help

help:
	@echo "Harvester AMI pipeline"
	@echo ""
	@echo "  make ami        build an AMI end to end (~2 hours) and publish to SSM"
	@echo "  make teardown   delete the helper instance, volume and security group"
	@echo "  make rebuild    teardown + clear stamps so 'make ami' runs again"
	@echo "  make clean      teardown, plus discard local state"
	@echo ""
	@echo "Required:  SUBNET_ID=subnet-xxxx KEY_NAME=my-key"
	@echo "Optional:  HARVESTER_VERSION HELPER_OS HELPER_TYPE HELPER_ROOT_SIZE"
	@echo "           VOLUME_SIZE SSM_PARAMETER SSH_CIDR KEY_FILE"
	@echo "           HELPER_OS is al2023 (default) or ubuntu"
	@echo ""
	@echo "Resumable: progress is stamped under $(STATE)/, so a failed run picks up"
	@echo "where it stopped instead of repeating the install."

check:
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

# --- helper instance, volume, security group --------------------------------
$(STATE)/sg-id: check | $(STATE)
	@echo "==> security group (SSH from $(SSH_CIDR))"
	@VPC=$$($(AWS) ec2 describe-subnets --subnet-ids $(SUBNET_ID) --query 'Subnets[0].VpcId' --output text); \
	SG=$$($(AWS) ec2 create-security-group --group-name harvester-build-$$$$ \
		--description "Harvester AMI build helper" --vpc-id $$VPC --query GroupId --output text); \
	$(AWS) ec2 authorize-security-group-ingress --group-id $$SG \
		--protocol tcp --port 22 --cidr $(SSH_CIDR) >/dev/null; \
	echo $$SG > $@; echo "    $$SG"

$(STATE)/volume-id: check | $(STATE)
	@echo "==> $(VOLUME_SIZE) GiB volume"
	@AZ=$$($(AWS) ec2 describe-subnets --subnet-ids $(SUBNET_ID) --query 'Subnets[0].AvailabilityZone' --output text); \
	$(AWS) ec2 create-volume --size $(VOLUME_SIZE) --volume-type gp3 --availability-zone $$AZ \
		--tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=harvester-build}]' \
		--query VolumeId --output text > $@; \
	echo "    $$(cat $@)"

$(STATE)/instance-id: check $(STATE)/sg-id
	@echo "==> helper instance ($(HELPER_TYPE))"
	@OS_AMI=$$($(AWS) ssm get-parameter --name $(HELPER_OS_SSM) --query 'Parameter.Value' --output text); \
	ROOT_DEV=$$($(AWS) ec2 describe-images --image-ids $$OS_AMI --query 'Images[0].RootDeviceName' --output text); \
	echo "    $$OS_AMI root=$$ROOT_DEV"; \
	$(AWS) ec2 run-instances --image-id $$OS_AMI --instance-type $(HELPER_TYPE) \
		--subnet-id $(SUBNET_ID) --security-group-ids $$(cat $(STATE)/sg-id) \
		--key-name $(KEY_NAME) --associate-public-ip-address \
		--cpu-options "NestedVirtualization=enabled" \
		--block-device-mappings "DeviceName=$$ROOT_DEV,Ebs={VolumeSize=$(HELPER_ROOT_SIZE),VolumeType=gp3,DeleteOnTermination=true}" \
		--tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=harvester-build}]' \
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
	scp $(SSH_OPTS) -i $(KEY_FILE) scripts/01-build-instance.sh scripts/02-customize-instance.sh \
		$(REMOTE)@$$IP:~/scripts/ ; \
	ssh $(SSH_OPTS) -i $(KEY_FILE) $(REMOTE)@$$IP 'set -eu; \
		$(PKG_INSTALL) >/dev/null; \
		test -w /dev/kvm || { echo "ERROR: /dev/kvm missing or not writable."; \
			echo "       The instance needs --cpu-options NestedVirtualization=enabled,"; \
			echo "       which is launch-time only -- run 'make teardown' and retry."; exit 1; }; \
		mkdir -p artifacts; cd artifacts; \
		for f in harvester-$(HARVESTER_VERSION)-amd64.iso harvester-$(HARVESTER_VERSION)-vmlinuz-amd64 harvester-$(HARVESTER_VERSION)-initrd-amd64; do \
			[ -s "$$f" ] || curl -fsSL -O "$(RELEASE_BASE)/$$f"; \
		done'
	@touch $@

$(STATE)/built: $(STATE)/provisioned
	@echo "==> installing Harvester onto the volume (this takes ~1 hour)"
	@IP=$$($(AWS) ec2 describe-instances --instance-ids $$(cat $(STATE)/instance-id) \
		--query 'Reservations[0].Instances[0].PublicIpAddress' --output text); \
	ssh $(SSH_OPTS) -i $(KEY_FILE) $(REMOTE)@$$IP \
		"set -eu; DEV=\$$(lsblk -dbpno NAME,SIZE | grep -v \"\$$(lsblk -no pkname \$$(findmnt -no SOURCE /))\" | awk -v w=\$$(( $(VOLUME_SIZE) * 1073741824 )) '\$$2 >= w {print \$$1; exit}'); \
		 test -n \"\$$DEV\" || { echo 'ERROR: could not find the $(VOLUME_SIZE) GiB volume'; lsblk; exit 1; }; \
		 echo \"target device: \$$DEV\"; \
		 sudo HARVESTER_VERSION=$(HARVESTER_VERSION) OVMF_CODE=$(OVMF_CODE) OVMF_VARS_TEMPLATE=$(OVMF_VARS) \
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
	@$(AWS) ec2 register-image --name "$(AMI_NAME)" --architecture x86_64 \
		--virtualization-type hvm --boot-mode uefi --root-device-name /dev/sda1 \
		--block-device-mappings "DeviceName=/dev/sda1,Ebs={SnapshotId=$$(cat $<),VolumeSize=$(VOLUME_SIZE),VolumeType=gp3,DeleteOnTermination=true}" \
		--ena-support --sriov-net-support simple --imds-support v2.0 \
		--query ImageId --output text > $@
	@echo "    $$(cat $@)"
	@$(AWS) ssm put-parameter --name $(SSM_PARAMETER) --type String --overwrite \
		--value $$(cat $@) >/dev/null
	@echo "    published to $(SSM_PARAMETER)"

ami: $(STATE)/ami-id
	@echo ""
	@echo "AMI $$(cat $(STATE)/ami-id) is ready and $(SSM_PARAMETER) points at it."
	@echo "Run 'make teardown' to remove the helper instance and volume."

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
	@echo "==> build state cleared; 'make ami' will start from scratch"

# Keeps snapshot-id and ami-id: those name real resources the teardown does not
# touch, and losing the file would orphan them silently.
clean: teardown
	@rm -f $(STATE)/built $(STATE)/customized $(STATE)/known_hosts
	@echo "Local build state cleared. $(STATE)/snapshot-id and $(STATE)/ami-id kept."
