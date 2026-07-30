#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_PATH=$(realpath "${BASH_SOURCE[0]}")
STATE_DIR="$ROOT_DIR/build/dev-loop"
TARGET_DIR=${CARGO_TARGET_DIR:-"$ROOT_DIR/target"}
CH_BINARY="$TARGET_DIR/debug/cloud-hypervisor"
FIRMWARE=${CH_FIRMWARE:-"$ROOT_DIR/build/hypervisor-fw"}
BASE_DISK=${CH_BASE_DISK:-"$ROOT_DIR/build/focal-server-cloudimg-amd64.raw"}
CLOUD_INIT=${CH_CLOUD_INIT:-"$STATE_DIR/cloud-init.img"}
OVERLAY="$STATE_DIR/root-overlay.qcow2"
PID_FILE="$STATE_DIR/vm.pid"
FINGERPRINT_FILE="$STATE_DIR/cloud-hypervisor.fingerprint"
CONSOLE_LOG="$STATE_DIR/console.log"
VMM_LOG="$STATE_DIR/vmm.log"

vm_is_running() {
    [[ -s "$PID_FILE" ]] && kill -0 "$(<"$PID_FILE")" 2>/dev/null
}

stop_vm() {
    if vm_is_running; then
        local pid
        pid=$(<"$PID_FILE")
        kill "$pid" 2>/dev/null || true
        for _ in {1..50}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
}

changes_only_affect_other_binaries() {
    local common_path=${WATCHEXEC_COMMON_PATH:-}
    local found=false variable value path absolute_path relative_path
    local -a paths

    for variable in \
        WATCHEXEC_CREATED_PATH \
        WATCHEXEC_REMOVED_PATH \
        WATCHEXEC_RENAMED_PATH \
        WATCHEXEC_WRITTEN_PATH \
        WATCHEXEC_META_CHANGED_PATH; do
        value=${!variable:-}
        [[ -n "$value" ]] || continue
        IFS=: read -r -a paths <<<"$value"
        for path in "${paths[@]}"; do
            [[ -n "$path" ]] || continue
            if [[ -n "$common_path" ]]; then
                absolute_path="${common_path%/}/${path#/}"
            elif [[ "$path" = /* ]]; then
                absolute_path="$path"
            else
                absolute_path="$ROOT_DIR/$path"
            fi
            relative_path=$(realpath -m --relative-to="$ROOT_DIR" "$absolute_path")
            case "$relative_path" in
            # api_client/* | \
                cloud-hypervisor/src/bin/* | \
                offload_daemon/* | \
                performance-metrics/* | \
                vhost_user_block/* | \
                vhost_user_net/*)
                found=true
                ;;
            *) return 1 ;;
            esac
        done
    done

    [[ "$found" == true ]]
}

restart_vm_if_needed() {
    [[ -x "$CH_BINARY" ]] || return 0

    local fingerprint previous=""
    fingerprint=$(stat -c '%i:%s:%y' "$CH_BINARY")
    [[ -r "$FINGERPRINT_FILE" ]] && previous=$(<"$FINGERPRINT_FILE")

    if changes_only_affect_other_binaries; then
        printf '%s\n' "$fingerprint" >"$FINGERPRINT_FILE"
        echo "only another project binary changed; leaving the VM unchanged"
        return 0
    fi

    if [[ "$fingerprint" == "$previous" ]] && vm_is_running; then
        echo "cloud-hypervisor was not relinked; leaving the VM running"
        return 0
    fi

    stop_vm
    sudo -n setcap cap_net_admin+ep "$CH_BINARY"
    rm -f "$OVERLAY" "$CONSOLE_LOG" "$VMM_LOG"
    qemu-img create -q -f qcow2 -F raw -b "$BASE_DISK" "$OVERLAY"

    rm -f "$PID_FILE"
    setsid "$SCRIPT_PATH" run-vm </dev/null &

    for _ in {1..20}; do
        [[ -s "$PID_FILE" ]] && break
        sleep 0.05
    done
    sleep 0.2
    if ! vm_is_running; then
        echo "cloud-hypervisor exited during startup; see $VMM_LOG" >&2
        return 1
    fi

    printf '%s\n' "$fingerprint" >"$FINGERPRINT_FILE"
    echo "VM started (PID $(<"$PID_FILE")); console: $CONSOLE_LOG"
}

run_vm() {
    printf '%s\n' "$$" >"$PID_FILE"
    exec > >(tee -a "$VMM_LOG") 2>&1
    exec "$CH_BINARY" \
        -vv \
        --firmware "$FIRMWARE" \
        --disk "path=$OVERLAY,image_type=qcow2,backing_files=on" \
        --disk "path=$CLOUD_INIT,image_type=raw,readonly=on" \
        --cpus boot=2 \
        --memory size=512M \
        --net "tap=,mac=12:34:56:78:90:ab,ip=192.168.249.1,mask=255.255.255.0" \
        --api-socket /tmp/cloud-hypervisor.sock \
        --serial null \
        --console "file=$CONSOLE_LOG"
}

run_watch() {
    for command in cargo-watch qemu-img setsid sudo setcap tee; do
        command -v "$command" >/dev/null || {
            echo "Missing required command: $command" >&2
            return 1
        }
    done
    [[ -r "$FIRMWARE" ]] || { echo "Missing firmware: $FIRMWARE" >&2; return 1; }
    [[ -r "$BASE_DISK" ]] || { echo "Missing base disk: $BASE_DISK" >&2; return 1; }

    mkdir -p "$STATE_DIR"
    if [[ ! -r "$CLOUD_INIT" ]]; then
        "$ROOT_DIR/scripts/create-cloud-init.sh" --output "$CLOUD_INIT"
    fi

    sudo -v
    stop_vm

    local sudo_keepalive_pid restart_command
    while sleep 60; do sudo -n -v || exit; done &
    sudo_keepalive_pid=$!

    cleanup() {
        local status=$?
        trap - EXIT INT TERM
        kill "$sudo_keepalive_pid" 2>/dev/null || true
        stop_vm
        exit "$status"
    }
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    printf -v restart_command '%q restart' "$SCRIPT_PATH"
    cd "$ROOT_DIR"
    cargo watch --experimental--env-changes \
        -x 'build --workspace' \
        -s "$restart_command"
}

case "${1:-watch}" in
watch) run_watch ;;
restart) restart_vm_if_needed ;;
run-vm) run_vm ;;
stop) stop_vm ;;
*) echo "Usage: $0 [watch|restart|run-vm|stop]" >&2; exit 2 ;;
esac
