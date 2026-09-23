#!/usr/bin/env bash
# THROWAWAY SPIKE for #153. Deleted before the design PR merges.
#
# Boots an Ubuntu cloud image under QEMU and runs the spike scenarios over SSH,
# printing timings. Runs on Linux (kvm or tcg) and macOS (hvf or tcg).
#
# Usage: spike/vm/vm.sh <scenario>
#   scenarios: boot | kernel-switch | dkms | parallel | all
# Env:
#   ARCH      amd64 | arm64            (default: host arch)
#   FIRMWARE  bios | uefi              (default: bios on amd64, uefi on arm64)
#   RELEASE   noble                    (default: noble)
#   SERIAL    cloud image serial       (default: 20260911)
#   VARIANT   server | minimal         (default: server)
#   ACCEL     kvm | hvf | tcg          (default: detected)
#   CACHE_DIR image cache              (default: ~/.cache/vmtest-spike)
#   WORK_DIR  per-run scratch          (default: mktemp)
#   RESULTS   file to append timings   (default: $WORK_DIR/results.md)
#   PARALLEL  VM count for "parallel"  (default: 3)
set -euo pipefail

SCENARIO="${1:-all}"
RELEASE="${RELEASE:-noble}"
SERIAL="${SERIAL:-20260911}"
VARIANT="${VARIANT:-server}"
CACHE_DIR="${CACHE_DIR:-${HOME}/.cache/vmtest-spike}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
RESULTS="${RESULTS:-${WORK_DIR}/results.md}"
PARALLEL="${PARALLEL:-3}"
HOST_OS="$(uname -s)"

case "$(uname -m)" in
  x86_64 | amd64) HOST_ARCH=amd64 ;;
  arm64 | aarch64) HOST_ARCH=arm64 ;;
  *) echo "unsupported host arch" >&2; exit 1 ;;
esac
ARCH="${ARCH:-${HOST_ARCH}}"
if [[ "${ARCH}" == "arm64" ]]; then
  FIRMWARE="${FIRMWARE:-uefi}"
else
  FIRMWARE="${FIRMWARE:-bios}"
fi

if [[ -z "${ACCEL:-}" ]]; then
  ACCEL=tcg
  if [[ "${ARCH}" == "${HOST_ARCH}" ]]; then
    if [[ "${HOST_OS}" == "Linux" && -r /dev/kvm && -w /dev/kvm ]]; then
      ACCEL=kvm
    elif [[ "${HOST_OS}" == "Darwin" ]]; then
      ACCEL=hvf
    fi
  fi
fi

if [[ "${ACCEL}" == "tcg" ]]; then
  BOOT_TIMEOUT=2400
else
  BOOT_TIMEOUT=600
fi

mkdir -p "${CACHE_DIR}" "${WORK_DIR}"
LABEL="${RELEASE}/${ARCH}/${FIRMWARE}/${VARIANT}/${ACCEL}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# record <what> <seconds> [note]
record() {
  printf '| %s | %s | %s | %ss | %s |\n' "${LABEL}" "${SCENARIO}" "$1" "$2" "${3:-}" >>"${RESULTS}"
  log "TIMING ${LABEL} $1: $2s ${3:-}"
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# ---------------------------------------------------------------- image

image_name() {
  if [[ "${VARIANT}" == "minimal" ]]; then
    echo "ubuntu-24.04-minimal-cloudimg-${ARCH}.img"
  else
    echo "ubuntu-24.04-server-cloudimg-${ARCH}.img"
  fi
}

image_base_url() {
  if [[ "${VARIANT}" == "minimal" ]]; then
    echo "https://cloud-images.ubuntu.com/minimal/releases/${RELEASE}/release-${SERIAL}"
  else
    echo "https://cloud-images.ubuntu.com/releases/${RELEASE}/release-${SERIAL}"
  fi
}

fetch_image() {
  local name url dest sums want got start
  name="$(image_name)"
  url="$(image_base_url)"
  dest="${CACHE_DIR}/${SERIAL}-${name}"
  if [[ -f "${dest}" ]]; then
    log "image cached: ${dest}"
    echo "${dest}"
    return
  fi
  start="${SECONDS}"
  sums="$(curl -fsSL "${url}/SHA256SUMS")"
  want="$(printf '%s\n' "${sums}" | awk -v n="*${name}" '$2 == n {print $1}')"
  [[ -n "${want}" ]] || { echo "no checksum for ${name}" >&2; exit 1; }
  curl -fsSL -o "${dest}.part" "${url}/${name}"
  got="$(sha256 "${dest}.part")"
  if [[ "${got}" != "${want}" ]]; then
    echo "checksum mismatch for ${name}: ${got} != ${want}" >&2
    exit 1
  fi
  mv "${dest}.part" "${dest}"
  record "image download+verify" "$((SECONDS - start))" "$(du -h "${dest}" | cut -f1)"
  echo "${dest}"
}

# ---------------------------------------------------------------- seed

make_key() {
  [[ -f "${WORK_DIR}/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -f "${WORK_DIR}/id_ed25519" -C vmtest-spike
}

make_seed() {
  local dir="${WORK_DIR}/seed" out="${WORK_DIR}/seed.iso"
  [[ -f "${out}" ]] && return
  mkdir -p "${dir}"
  cat >"${dir}/meta-data" <<EOF
instance-id: vmtest-spike
local-hostname: vmtest
EOF
  cat >"${dir}/user-data" <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat "${WORK_DIR}/id_ed25519.pub")
package_update: false
package_upgrade: false
runcmd:
  - [systemctl, disable, --now, apt-daily.timer, apt-daily-upgrade.timer, unattended-upgrades.service]
EOF
  if command -v cloud-localds >/dev/null 2>&1; then
    cloud-localds "${out}" "${dir}/user-data" "${dir}/meta-data"
  elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -quiet -output "${out}" -volid cidata -joliet -rock "${dir}/user-data" "${dir}/meta-data"
  elif command -v hdiutil >/dev/null 2>&1; then
    hdiutil makehybrid -quiet -o "${out}" -iso -joliet -default-volume-name cidata "${dir}"
  else
    echo "need cloud-localds, genisoimage or hdiutil" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------- firmware

find_first() {
  local f
  for f in "$@"; do
    if [[ -f "${f}" ]]; then
      echo "${f}"
      return
    fi
  done
  echo "none of: $*" >&2
  return 1
}

brew_share() { echo "$(brew --prefix 2>/dev/null || echo /opt/homebrew)/share/qemu"; }

firmware_args() {
  # $1 = vars file to use (per VM)
  local vars="$1" code tmpl
  if [[ "${FIRMWARE}" != "uefi" ]]; then
    return
  fi
  if [[ "${ARCH}" == "arm64" ]]; then
    code="$(find_first /usr/share/AAVMF/AAVMF_CODE.fd "$(brew_share)/edk2-aarch64-code.fd")"
    tmpl="$(find_first /usr/share/AAVMF/AAVMF_VARS.fd "$(brew_share)/edk2-arm-vars.fd")"
  else
    code="$(find_first /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd "$(brew_share)/edk2-x86_64-code.fd")"
    tmpl="$(find_first /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd "$(brew_share)/edk2-i386-vars.fd")"
  fi
  if [[ ! -f "${vars}" ]]; then
    cp "${tmpl}" "${vars}"
    # pflash units must be the same size as the code image.
    if [[ "$(wc -c <"${vars}")" -lt "$(wc -c <"${code}")" ]]; then
      truncate -s "$(wc -c <"${code}" | tr -d ' ')" "${vars}"
    fi
  fi
  printf '%s\n' -drive "if=pflash,format=raw,unit=0,readonly=on,file=${code}" -drive "if=pflash,format=raw,unit=1,file=${vars}"
}

# ---------------------------------------------------------------- vm

# vm_start <name> <disk> <port>; writes pid to $WORK_DIR/<name>.pid
vm_start() {
  local name="$1" disk="$2" port="$3" bin machine cpu smp mem
  smp="${VM_CPUS:-2}"
  mem="${VM_MEM:-4096}"
  if [[ "${ARCH}" == "arm64" ]]; then
    bin=qemu-system-aarch64
    machine="virt,accel=${ACCEL}"
  else
    bin=qemu-system-x86_64
    machine="q35,accel=${ACCEL}"
  fi
  if [[ "${ACCEL}" == "tcg" ]]; then
    cpu=max
    [[ "${ARCH}" == "arm64" ]] && cpu="max,pauth-impdef=on"
  else
    cpu=host
  fi
  local fw=()
  local line
  while IFS= read -r line; do fw+=("${line}"); done < <(firmware_args "${WORK_DIR}/${name}.vars.fd")
  "${bin}" \
    -name "${name}" \
    -machine "${machine}" -cpu "${cpu}" -smp "${smp}" -m "${mem}" \
    ${fw[@]+"${fw[@]}"} \
    -drive "if=none,id=root,file=${disk},format=qcow2,discard=unmap" \
    -device virtio-blk-pci,drive=root,bootindex=0 \
    -drive "if=none,id=seed,file=${WORK_DIR}/seed.iso,format=raw,readonly=on" \
    -device virtio-blk-pci,drive=seed \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${port}-:22" \
    -device virtio-net-pci,netdev=n0 \
    -device virtio-rng-pci \
    -display none -monitor none \
    -serial "file:${WORK_DIR}/${name}.console.log" \
    -pidfile "${WORK_DIR}/${name}.pid" \
    -daemonize
}

vm_ssh() {
  local port="$1"
  shift
  ssh -F /dev/null -q \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
    -o BatchMode=yes -o LogLevel=ERROR \
    -i "${WORK_DIR}/id_ed25519" -p "${port}" ubuntu@127.0.0.1 "$@"
}

wait_ssh() {
  local port="$1" deadline=$((SECONDS + BOOT_TIMEOUT))
  until vm_ssh "${port}" true 2>/dev/null; do
    if ((SECONDS > deadline)); then
      echo "ssh on ${port} not ready after ${BOOT_TIMEOUT}s" >&2
      return 1
    fi
    sleep 2
  done
}

boot_id() { vm_ssh "$1" cat /proc/sys/kernel/random/boot_id; }

# reboot_vm <port>; asserts boot_id changed
reboot_vm() {
  local port="$1" before after start
  before="$(boot_id "${port}")"
  start="${SECONDS}"
  vm_ssh "${port}" sudo systemd-run --quiet --on-active=1 systemctl reboot
  local deadline=$((SECONDS + BOOT_TIMEOUT))
  while true; do
    after="$(boot_id "${port}" 2>/dev/null || true)"
    if [[ -n "${after}" && "${after}" != "${before}" ]]; then
      break
    fi
    if ((SECONDS > deadline)); then
      echo "reboot on ${port} did not complete in ${BOOT_TIMEOUT}s" >&2
      return 1
    fi
    sleep 2
  done
  record "reboot (ssh back, boot_id changed)" "$((SECONDS - start))"
}

vm_stop() {
  local name="$1" port="$2" pid
  vm_ssh "${port}" sudo systemd-run --quiet --on-active=1 systemctl poweroff 2>/dev/null || true
  pid="$(cat "${WORK_DIR}/${name}.pid" 2>/dev/null || true)"
  if [[ -n "${pid}" ]]; then
    local i
    for i in $(seq 1 60); do
      kill -0 "${pid}" 2>/dev/null || return 0
      sleep 1
    done
    kill "${pid}" 2>/dev/null || true
  fi
}

free_port() {
  # crude: base + offset; fine for a spike
  echo $((22000 + RANDOM % 20000))
}

# ---------------------------------------------------------------- prepared overlay

PREPARED=""

prepare() {
  local base start port
  base="$(fetch_image)"
  make_key
  make_seed
  PREPARED="${WORK_DIR}/prepared.qcow2"
  if [[ -f "${PREPARED}" ]]; then
    return
  fi
  qemu-img create -q -f qcow2 -F qcow2 -b "${base}" "${PREPARED}" 20G
  port="$(free_port)"
  start="${SECONDS}"
  vm_start prepared "${PREPARED}" "${port}"
  wait_ssh "${port}"
  record "first boot to ssh (cloud-init)" "$((SECONDS - start))"
  vm_ssh "${port}" cloud-init status --wait >/dev/null || true
  record "first boot to cloud-init done" "$((SECONDS - start))"
  vm_ssh "${port}" 'uname -r; systemd-analyze || true; systemd-analyze blame | head -8 || true; lsblk; df -h /; ls /sys/firmware/efi >/dev/null 2>&1 && echo EFI || echo BIOS' >&2 || true
  start="${SECONDS}"
  vm_stop prepared "${port}"
  record "shutdown" "$((SECONDS - start))"
  # the per-VM vars file travels with the prepared overlay
  [[ -f "${WORK_DIR}/prepared.vars.fd" ]] && cp "${WORK_DIR}/prepared.vars.fd" "${WORK_DIR}/prepared.vars.fd.orig"
}

# clone <name>: per-test overlay on the prepared image
clone() {
  local name="$1"
  qemu-img create -q -f qcow2 -F qcow2 -b "${PREPARED}" "${WORK_DIR}/${name}.qcow2"
  [[ -f "${WORK_DIR}/prepared.vars.fd.orig" ]] && cp "${WORK_DIR}/prepared.vars.fd.orig" "${WORK_DIR}/${name}.vars.fd"
  echo "${WORK_DIR}/${name}.qcow2"
}

# start_clone <name> -> prints port
start_clone() {
  local name="$1" disk port start
  disk="$(clone "${name}")"
  port="$(free_port)"
  start="${SECONDS}"
  vm_start "${name}" "${disk}" "${port}"
  wait_ssh "${port}"
  record "overlay boot to ssh" "$((SECONDS - start))"
  echo "${port}"
}

# ---------------------------------------------------------------- scenarios

# Picks generic kernels available in the archive. Prints "<older> <newer>" ABI strings
# relative to the running kernel (either may be empty).
pick_kernels() {
  vm_ssh "$1" 'bash -s' <<'EOF'
set -euo pipefail
running="$(uname -r)"
flavor="generic"
case "$(uname -m)" in aarch64) ;; esac
mapfile -t all < <(apt-cache search --names-only "^linux-image-[0-9.]+-[0-9]+-${flavor}\$" | awk '{print $1}' | sed "s/^linux-image-//" | sort -V)
older=""; newer=""
for k in "${all[@]}"; do
  if [[ "$(printf '%s\n%s\n' "$k" "$running" | sort -V | head -1)" == "$k" && "$k" != "$running" ]]; then older="$k"; fi
  if [[ -z "$newer" && "$(printf '%s\n%s\n' "$k" "$running" | sort -V | head -1)" == "$running" && "$k" != "$running" ]]; then newer="$k"; fi
done
# newest available rather than the next one up, to mimic unattended-upgrades
for k in "${all[@]}"; do
  if [[ "$(printf '%s\n%s\n' "$k" "$running" | sort -V | tail -1)" == "$k" && "$k" != "$running" ]]; then newer="$k"; fi
done
echo "running=${running} older=${older} newer=${newer} count=${#all[@]}" >&2
echo "${older} ${newer}"
EOF
}

scenario_boot() {
  local port
  port="$(start_clone boot)"
  reboot_vm "${port}"
  vm_stop boot "${port}"
}

scenario_kernel_switch() {
  local port start kernels target
  port="$(start_clone kswitch)"
  start="${SECONDS}"
  vm_ssh "${port}" sudo apt-get update -qq
  record "apt-get update" "$((SECONDS - start))"
  kernels="$(pick_kernels "${port}")"
  target="${kernels%% *}"
  [[ -n "${target}" ]] || target="${kernels##* }"
  log "kernel-switch target: ${target}"
  local pkgs="linux-image-${target} linux-headers-${target} linux-modules-${target} linux-modules-extra-${target}"
  start="${SECONDS}"
  vm_ssh "${port}" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --download-only ${pkgs}" >/dev/null
  record "kernel download-only (4 pkgs)" "$((SECONDS - start))"
  start="${SECONDS}"
  vm_ssh "${port}" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ${pkgs}" >/dev/null
  record "kernel install from cache (4 pkgs, incl initramfs+grub hooks)" "$((SECONDS - start))" "${target}"
  vm_ssh "${port}" 'echo "--- /etc/default/grub"; grep -v "^#" /etc/default/grub | grep .; echo "--- grub.d"; head -50 /etc/default/grub.d/* 2>/dev/null; echo "--- menu"; sudo grep -E "^(menuentry|submenu|\s+menuentry)" /boot/grub/grub.cfg | cut -c1-160' >&2 || true
  start="${SECONDS}"
  vm_ssh "${port}" "sudo bash -s" <<EOF
set -euo pipefail
update-grub 2>/dev/null
sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=saved|' /etc/default/grub
grub-set-default "Advanced options for Ubuntu>Ubuntu, with Linux ${target}"
update-grub 2>/dev/null
grub-editenv list
EOF
  record "grub steps (as install_kernel.sh)" "$((SECONDS - start))"
  reboot_vm "${port}"
  local booted
  booted="$(vm_ssh "${port}" uname -r)"
  if [[ "${booted}" == "${target}" ]]; then
    record "kernel-switch result" 0 "PASS booted ${booted}"
  else
    record "kernel-switch result" 0 "FAIL booted ${booted}, wanted ${target}"
  fi
  vm_stop kswitch "${port}"
}

scenario_dkms() {
  local port start kernels newer status
  port="$(start_clone dkms)"
  vm_ssh "${port}" sudo apt-get update -qq
  start="${SECONDS}"
  vm_ssh "${port}" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dkms" >/dev/null
  record "install dkms" "$((SECONDS - start))"
  vm_ssh "${port}" "sudo bash -s" <<'EOF'
set -euo pipefail
src=/usr/src/failmod-1.0
mkdir -p "${src}"
cat >"${src}/failmod.c" <<'C'
#include <linux/module.h>
#error "failmod: this DKMS module always fails to build (vmtest spike)"
MODULE_LICENSE("GPL");
C
cat >"${src}/Makefile" <<'M'
obj-m := failmod.o
M
cat >"${src}/dkms.conf" <<'D'
PACKAGE_NAME="failmod"
PACKAGE_VERSION="1.0"
BUILT_MODULE_NAME[0]="failmod"
DEST_MODULE_LOCATION[0]="/updates/dkms"
AUTOINSTALL="yes"
D
dkms add -m failmod -v 1.0
dkms status
EOF
  kernels="$(pick_kernels "${port}")"
  newer="${kernels##* }"
  [[ -n "${newer}" ]] || newer="${kernels%% *}"
  log "dkms scenario: installing second kernel ${newer}"
  start="${SECONDS}"
  status=0
  vm_ssh "${port}" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y linux-image-${newer} linux-headers-${newer} linux-modules-${newer} linux-modules-extra-${newer}" >"${WORK_DIR}/dkms-install.log" 2>&1 || status=$?
  record "install second kernel with failing dkms" "$((SECONDS - start))" "apt exit ${status}"
  tail -40 "${WORK_DIR}/dkms-install.log" >&2
  vm_ssh "${port}" 'bash -s' <<'EOF' >&2 || true
echo "--- non-ii packages"; dpkg -l | awk 'NR>5 && $1 != "ii"' | cut -c1-120
echo "--- dpkg --audit"; dpkg --audit || true
echo "--- /var/lib/dpkg/updates"; ls -la /var/lib/dpkg/updates
echo "--- apt-get update"; sudo apt-get update -qq; echo "exit $?"
echo "--- apt-get install -y hello"; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq hello 2>&1 | tail -5; echo "exit ${PIPESTATUS[0]}"
echo "--- dpkg --configure -a"; sudo dpkg --configure -a 2>&1 | tail -8; echo "exit ${PIPESTATUS[0]}"
echo "--- grub default"; sudo grub-editenv list; grep ^GRUB_DEFAULT /etc/default/grub
EOF
  reboot_vm "${port}"
  record "dkms result" 0 "booted $(vm_ssh "${port}" uname -r) (running before: see log), wanted-new ${newer}"
  vm_stop dkms "${port}"
}

scenario_parallel() {
  local i pids=() start
  start="${SECONDS}"
  for i in $(seq 1 "${PARALLEL}"); do
    (
      port="$(start_clone "par${i}")"
      vm_ssh "${port}" sudo apt-get update -qq
      k="$(pick_kernels "${port}" 2>/dev/null)"
      t="${k%% *}"
      [[ -n "${t}" ]] || t="${k##* }"
      s="${SECONDS}"
      vm_ssh "${port}" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq linux-image-${t} linux-headers-${t} linux-modules-${t} linux-modules-extra-${t}" >/dev/null
      record "parallel[${i}/${PARALLEL}] kernel install" "$((SECONDS - s))"
      reboot_vm "${port}"
      vm_stop "par${i}" "${port}"
    ) &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do wait "${i}"; done
  record "parallel x${PARALLEL} wall clock (boot+update+install+reboot)" "$((SECONDS - start))"
}

# ---------------------------------------------------------------- main

log "label=${LABEL} work=${WORK_DIR}"
[[ -f "${RESULTS}" ]] || printf '| config | scenario | step | time | note |\n| --- | --- | --- | --- | --- |\n' >"${RESULTS}"
prepare
case "${SCENARIO}" in
  boot) scenario_boot ;;
  kernel-switch) scenario_kernel_switch ;;
  dkms) scenario_dkms ;;
  parallel) scenario_parallel ;;
  all)
    SCENARIO=boot scenario_boot
    SCENARIO=kernel-switch scenario_kernel_switch
    SCENARIO=dkms scenario_dkms
    ;;
  *) echo "unknown scenario ${SCENARIO}" >&2; exit 2 ;;
esac
cat "${RESULTS}"
