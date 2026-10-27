#!/usr/bin/env bash
# Mounts the persistent EBS data volume at first boot (cloud-init runcmd).
#   mount-data-volume <volume-id> <mount-point>
# Terraform attaches the volume after the instance starts, so this waits for it. A
# volume that already holds a filesystem (from a replaced instance) is never formatted.
set -euo pipefail

volume_id="$1"
mount_point="$2"
timeout_seconds="${MOUNT_TIMEOUT_SECONDS:-600}"

# Nitro instances name NVMe devices after the volume ID; Xen instances use the
# /dev/sdf name from the attachment, shown as /dev/xvdf.
candidates=("/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${volume_id//-/}" /dev/xvdf /dev/sdf)

device=""
for ((waited = 0; waited <= timeout_seconds; waited += 5)); do
    for candidate in "${candidates[@]}"; do
        if [[ -b "$candidate" ]]; then
            device="$(readlink -f "$candidate")"
            break 2
        fi
    done
    sleep 5
done

if [[ -z "$device" ]]; then
    echo "mount-data-volume: ${volume_id} was not attached within ${timeout_seconds}s" >&2
    exit 1
fi
udevadm settle

if ! blkid "$device" > /dev/null 2>&1; then
    echo "mount-data-volume: formatting blank volume ${volume_id} (${device})"
    mkfs.ext4 -q -L observability "$device"
fi

uuid="$(blkid -s UUID -o value "$device")"
mkdir -p "$mount_point"
if ! grep -q "^UUID=${uuid} " /etc/fstab; then
    # nofail: the host still boots for repairs if the volume is missing.
    echo "UUID=${uuid} ${mount_point} ext4 defaults,nofail,x-systemd.device-timeout=60s 0 2" >> /etc/fstab
fi
systemctl daemon-reload
mountpoint -q "$mount_point" || mount "$mount_point"

# Docker must never start without the volume: it would write to the root disk, and
# the data would disappear behind the mount later.
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/10-data-volume.conf << EOF
[Unit]
RequiresMountsFor=${mount_point}
EOF
systemctl daemon-reload

echo "mount-data-volume: ${volume_id} (${device}) mounted at ${mount_point}"
