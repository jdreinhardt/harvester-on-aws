- Launch helper instance in AWS. Attach additional 251 GiB (image size + 1) volume to instance. Attach IAM role with S3 access.
  - volume is 1GiB larger than source volume to account for extra bits that cause partition corruption

- Upload compressed disk image to S3

- Write image to extra disk

aws s3 cp s3://suse-virtualization-testing/harvester-v1.7.1-amd64.raw.zst - | zstd -dc | sudo dd of=/dev/nvme1n1 bs=1M status=progress

- Run `02-customize-instance` to update GRUB, set base setting and allow for parsing AWS user data

- Detach volume from helper instance and take snapshot

- Register snapshot as AMI

aws ec2 register-image --name "harvester-v1.7.1" --architecture x86_64 --boot-mode uefi --root-device-name /dev/sda1 --block-device-mapping "DeviceName=/dev/sda1,Ebs={SnapshotId=snap-066b3a58d46bb7a19,VolumeSize=251,VolumeType=gp3}" --ena-support --sriov-net-support simple

- Update the default parameters in `03-launch-instance` or pass them as parameters

- Run `03-launch-instance` which will create the instance, attach the security group, create a secondary IP address and attach it to the instance NIC.

- Use EC2 Serial Console to watch boot before SSH comes up.

-----

- Currently stuck with Rancher not deploying on its own. Script on deployed instance `/usr/local/bin/harvester-post-bootstrap.sh` can sort of bootstrap, but never finishes deploying. Must be missing something.

