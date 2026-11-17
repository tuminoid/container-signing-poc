#!/usr/bin/env bash
# Disposable Ubuntu cloud-image VM for the crio/ and containerd/ runtime
# tests, run with plain QEMU/KVM and user-mode networking: no root on the
# host, everything under VM_DIR. SSH is forwarded to 127.0.0.1:VM_PORT.
# Same pattern as container-encryption-poc's crio/vm.sh.
#
# usage: vm.sh start | wait | stop | ssh <cmd>
# environment: VM_DIR, VM_NAME, VM_PORT, VM_BASE (cloud image), VM_MEM (MiB)

set -eu

DIR="${VM_DIR:?VM_DIR must point at the VM directory in build/}"
NAME="${VM_NAME:?VM_NAME}"
PORT="${VM_PORT:?VM_PORT}"
BASE="${VM_BASE:?VM_BASE}"
MEM="${VM_MEM:?VM_MEM}"
DISK="${DIR}/disk.qcow2"
SEED="${DIR}/seed.iso"
KEY="${DIR}/id_ed25519"
PID="${DIR}/qemu.pid"
SSH_OPTS=(-i "${KEY}" -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=5
    -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=${DIR}/known_hosts")

# The pidfile is trusted only if that PID is QEMU running this VM's disk;
# after a crash or host reboot it may name an unrelated process.
running() {
    local pid
    [[ -f "${PID}" ]] || return 1
    pid="$(cat "${PID}")"
    [[ -r "/proc/${pid}/cmdline" ]] &&
        tr '\0' ' ' <"/proc/${pid}/cmdline" | grep -q -- "-name ${NAME} .*file=${DISK},"
}

vm_ssh() {
    ssh "${SSH_OPTS[@]}" -p "${PORT}" poc@127.0.0.1 "$@"
}

wait_ssh() {
    for _ in $(seq 1 120); do
        vm_ssh true 2>/dev/null && { echo "OK: VM up, ssh -p ${PORT} poc@127.0.0.1"; return 0; }
        sleep 2
    done
    echo "error: VM did not come up, see ${DIR}/console.log"
    exit 1
}

start() {
    if running; then wait_ssh; return; fi
    rm -f "${PID}"
    mkdir -p "${DIR}"
    [[ -f "${KEY}" ]] || ssh-keygen -q -t ed25519 -N '' -C "poc@${NAME}" -f "${KEY}"
    if [[ ! -f "${DISK}" ]]; then
        qemu-img create -q -f qcow2 -F qcow2 -b "$(realpath "${BASE}")" "${DISK}" 30G
        rm -f "${DIR}/known_hosts"
        cat >"${DIR}/user-data" <<EOF
#cloud-config
users:
- name: poc
  sudo: ALL=(ALL) NOPASSWD:ALL
  shell: /bin/bash
  ssh_authorized_keys:
  - $(cat "${KEY}.pub")
ssh_pwauth: false
EOF
        cloud-localds "${SEED}" "${DIR}/user-data"
    fi
    qemu-system-x86_64 -name "${NAME}" -machine accel=kvm -cpu host -smp 4 -m "${MEM}" \
        -drive "file=${DISK},if=virtio,format=qcow2" \
        -drive "file=${SEED},if=virtio,format=raw,readonly=on" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${PORT}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -display none -serial "file:${DIR}/console.log" \
        -daemonize -pidfile "${PID}"
    wait_ssh
}

stop() {
    if running; then
        kill "$(cat "${PID}")"
        echo "OK: VM stopped"
    fi
    rm -f "${PID}"
}

case "${1:-}" in
    start) start ;;
    wait) wait_ssh ;;
    stop) stop ;;
    ssh) shift; vm_ssh "$@" ;;
    *) echo "usage: vm.sh start|wait|stop|ssh <cmd>"; exit 1 ;;
esac
