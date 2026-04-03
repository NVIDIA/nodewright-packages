#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# fetched from: https://github.com/awslabs/amazon-eks-ami/blob/main/templates/shared/runtime/bin/setup-local-disks

set -o errexit
set -o pipefail
set -o nounset

if [ "$(id --user)" -ne 0 ]; then
  echo "Must be run as root"
  exit 1
fi

err_report() {
  echo "Exited with error on line $1"
}
trap 'err_report $LINENO' ERR

print_help() {
  echo "usage: $0 <raid0 | mount | none>"
  echo "Sets up Amazon EC2 Instance Store NVMe disks"
  echo ""
  echo "-d, --dir directory to mount the filesystem(s) (default: /mnt/k8s-disks/)"
  echo "--no-bind-kubelet disable bind mounting kubelet dir onto MD raid device"
  echo "--no-bind-containerd disable bind mounting containerd dir onto MD raid device"
  echo "--no-bind-pods-logs disable bind mounting /var/log/pods onto MD raid device"
  echo "--no-bind-mounts disable all bind mounting onto MD raid device, only create and mount MD device"
  echo "-h, --help print this help"
}

# Sets up a RAID-0 of NVMe instance storage disks, moves
# the contents of /var/lib/kubelet and /var/lib/containerd
# to the new mounted RAID, and bind mounts the kubelet and
# containerd state directories.
maybe_raid0() {
  local md_name="kubernetes"
  local md_device="/dev/md/${md_name}"
  local md_config="/.aws/mdadm.conf"
  local array_mount_point="${MNT_DIR}/0"
  mkdir -p "$(dirname "${md_config}")"

  if [[ ! -s "${md_config}" ]]; then
    mdadm --create --force --verbose \
      "${md_device}" \
      --level=0 \
      --name="${md_name}" \
      --raid-devices="${#EPHEMERAL_DISKS[@]}" \
      "${EPHEMERAL_DISKS[@]}"
    sleep 5
    while [ -n "$(mdadm --detail "${md_device}" | grep -ioE 'State :.*resyncing')" ]; do
      echo "Raid is resyncing..."
      sleep 1
    done
    mdadm --detail --scan > "${md_config}"
  fi

  local current_md_device=$(find /dev/md/ -type l -regex ".*/${md_name}_+[0-9a-z]*$" | tail -n1)
  echo "md_device is '${md_device}' and current_md_device is '${current_md_device}'"
  if [[ ! -z ${current_md_device} ]]; then
    md_device="${current_md_device}"
  fi

  if [[ -z "$(lsblk "${md_device}" -o fstype --noheadings)" ]]; then
    echo "running mkfs.xfs -f -l su=8b ${md_device}"
    mkfs.xfs -f -l su=8b "${md_device}"
  fi

  mkdir -p "${array_mount_point}"

  local dev_uuid=$(blkid -s UUID -o value "${md_device}")
  local mount_unit_name="$(systemd-escape --path --suffix=mount "${array_mount_point}")"
  local device_unit_name="dev-md-${md_name}.device"
  cat > "/etc/systemd/system/${mount_unit_name}" << EOF
[Unit]
Description=Mount EC2 Instance Store NVMe disk RAID0
Requires=${device_unit_name}
After=${device_unit_name}
[Mount]
What=UUID=${dev_uuid}
Where=${array_mount_point}
Type=xfs
Options=defaults,noatime
[Install]
WantedBy=multi-user.target
EOF
  systemd-analyze verify "${mount_unit_name}"
  systemctl enable "${mount_unit_name}" --now

  prev_running=""
  needs_linked=""
  BIND_MOUNTS=()

  if [[ "${BIND_KUBELET}" == "true" ]]; then
    BIND_MOUNTS+=("kubelet")
  fi
  if [[ "${BIND_CONTAINERD}" == "true" ]]; then
    BIND_MOUNTS+=("containerd")
  fi

  for unit in "${BIND_MOUNTS[@]}"; do
    if [[ "$(systemctl is-active var-lib-${unit}.mount)" != "active" ]]; then
      if systemctl is-active "${unit}" > /dev/null 2>&1; then
        prev_running+=" ${unit}"
      fi
      needs_linked+=" /var/lib/${unit}"
    fi
  done

  if [[ "${BIND_VAR_LOG_PODS}" == "true" ]]; then
    if [[ "$(systemctl is-active var-log-pods.mount)" != "active" ]]; then
      if systemctl is-active "kubelet" > /dev/null 2>&1; then
        prev_running+=" kubelet"
      fi
      needs_linked+=" /var/log/pods"
    fi
  fi

  if [[ ! -z "${prev_running}" ]]; then
    systemctl stop ${prev_running}
  fi

  for mount_point in ${needs_linked}; do
    local unit="$(basename "${mount_point}")"
    local array_mount_point_unit="${array_mount_point}/${unit}"
    mkdir -p "${mount_point}"
    echo "Copying ${mount_point}/ to ${array_mount_point_unit}/"
    cp -a "${mount_point}/" "${array_mount_point_unit}/"
    local mount_unit_name="$(systemd-escape --path --suffix=mount "${mount_point}")"
    cat > "/etc/systemd/system/${mount_unit_name}" << EOF
[Unit]
Description=Mount ${unit} on EC2 Instance Store NVMe RAID0
[Mount]
What=${array_mount_point_unit}
Where=${mount_point}
Type=none
Options=bind
[Install]
WantedBy=multi-user.target
EOF
    systemd-analyze verify "${mount_unit_name}"
    systemctl enable "${mount_unit_name}" --now
  done

  if [[ ! -z "${prev_running}" ]]; then
    systemctl start ${prev_running}
  fi
}

maybe_mount() {
  idx=1
  for dev in "${EPHEMERAL_DISKS[@]}"; do
    if [[ -z "$(lsblk "${dev}" -o fstype --noheadings)" ]]; then
      mkfs.xfs -l su=8b "${dev}"
    fi
    if [[ ! -z "$(lsblk "${dev}" -o MOUNTPOINT --noheadings)" ]]; then
      echo "${dev} is already mounted."
      continue
    fi
    local mount_point="${MNT_DIR}/${idx}"
    local mount_unit_name="$(systemd-escape --path --suffix=mount "${mount_point}")"
    mkdir -p "${mount_point}"
    cat > "/etc/systemd/system/${mount_unit_name}" << EOF
    [Unit]
    Description=Mount EC2 Instance Store NVMe disk ${idx}
    [Mount]
    What=${dev}
    Where=${mount_point}
    Type=xfs
    Options=defaults,noatime
    [Install]
    WantedBy=multi-user.target
EOF
    systemd-analyze verify "${mount_unit_name}"
    systemctl enable "${mount_unit_name}" --now
    idx=$((idx + 1))
  done
}

MNT_DIR="/mnt/k8s-disks"
BIND_KUBELET="true"
BIND_CONTAINERD="true"
BIND_VAR_LOG_PODS="true"

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -h | --help)
      print_help
      exit 0
      ;;
    -d | --dir)
      MNT_DIR="$2"
      shift
      shift
      ;;
    --no-bind-kubelet)
      BIND_KUBELET="false"
      shift
      ;;
    --no-bind-containerd)
      BIND_CONTAINERD="false"
      shift
      ;;
    --no-bind-pods-logs)
      BIND_VAR_LOG_PODS="false"
      shift
      ;;
    --no-bind-mounts)
      BIND_KUBELET="false"
      BIND_CONTAINERD="false"
      BIND_VAR_LOG_PODS="false"
      shift
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

set +u
set -- "${POSITIONAL[@]}"
DISK_SETUP="$1"
set -u

if [[ "${DISK_SETUP}" != "raid0" && "${DISK_SETUP}" != "mount" && "${DISK_SETUP}" != "none" ]]; then
  echo "Valid disk setup options are: raid0, mount, or none"
  exit 1
fi

if [ "${DISK_SETUP}" = "none" ]; then
  echo "disk setup is 'none', nothing to do!"
  exit 0
fi

if [ ! -d /dev/disk/by-id/ ]; then
  echo "no ephemeral disks found!"
  exit 0
fi

disks=($(find -L /dev/disk/by-id/ -xtype l -name '*NVMe_Instance_Storage_*'))
if [[ "${#disks[@]}" -eq 0 ]]; then
  echo "no NVMe instance storage disks found!"
  exit 0
fi

EPHEMERAL_DISKS=($(realpath "${disks[@]}" | sort -u))

case "${DISK_SETUP}" in
  "raid0")
    maybe_raid0
    echo "Successfully setup RAID-0 consisting of ${EPHEMERAL_DISKS[@]}"
    ;;
  "mount")
    maybe_mount
    echo "Successfully setup disk mounts consisting of ${EPHEMERAL_DISKS[@]}"
    ;;
esac
