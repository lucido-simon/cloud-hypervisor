#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SNAPSHOT=${UFFD_SNAPSHOT_DIR:-"$ROOT/build/uffd-minimal/snapshot"}
RUN_ID=$(date +%Y%m%d-%H%M%S)
OUT_ROOT=${UFFD_INTEGRITY_OUTPUT_ROOT:-"$ROOT/build/uffd-integrity"}
OUT="$OUT_ROOT/$RUN_ID"
CH="$ROOT/target/release/cloud-hypervisor"
REMOTE="$ROOT/target/release/ch-remote"
OFFLOAD="$ROOT/target/release/offload_daemon"
ACL_BACKUP="$OUT/userfaultfd.acl"

PIDS=()
ACL_CHANGED=0

die() {
    echo "error: $*" >&2
    exit 1
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    local pid
    for pid in "${PIDS[@]}"; do
        kill -CONT "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
    done
    sleep 0.1
    for pid in "${PIDS[@]}"; do
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    if ((ACL_CHANGED)); then
        sudo setfacl --restore="$ACL_BACKUP"
    fi
    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

wait_for_api() {
    local pid=$1 socket=$2 log=$3
    for _ in {1..300}; do
        if [[ -S "$socket" ]] && "$REMOTE" --api-socket "$socket" ping >/dev/null 2>&1; then
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || {
            tail -n 80 "$log" >&2 || true
            die "VMM exited before API became ready"
        }
        sleep 0.1
    done
    die "timed out waiting for API $socket"
}

wait_for_socket() {
    local pid=$1 socket=$2
    for _ in {1..300}; do
        [[ -S "$socket" ]] && return 0
        kill -0 "$pid" 2>/dev/null || die "process $pid exited before creating $socket"
        sleep 0.1
    done
    die "timed out waiting for socket $socket"
}

wait_for_log() {
    local pid=$1 log=$2 text=$3
    for _ in {1..12000}; do
        grep -Fq "$text" "$log" 2>/dev/null && return 0
        kill -0 "$pid" 2>/dev/null || {
            tail -n 80 "$log" >&2 || true
            die "process $pid exited before logging: $text"
        }
        sleep 0.005
    done
    die "timed out waiting for log marker: $text"
}

wait_pid() {
    local pid=$1 description=$2
    for _ in {1..1200}; do
        kill -0 "$pid" 2>/dev/null || {
            wait "$pid"
            return
        }
        sleep 0.1
    done
    die "timed out waiting for $description (PID $pid)"
}

start_receiver() {
    local name=$1 mode=$2
    local api="$OUT/$name-api.sock"
    local socket="$OUT/$name-restore.sock"
    local vmm_log="$OUT/$name-vmm.log"
    local receive_log="$OUT/$name-receive.log"

    rm -f "$api" "$socket"
    "$CH" -v --api-socket "$api" >"$vmm_log" 2>&1 &
    RECEIVER_PID=$!
    PIDS+=("$RECEIVER_PID")
    wait_for_api "$RECEIVER_PID" "$api" "$vmm_log"

    if [[ "$mode" == postcopy ]]; then
        "$REMOTE" --api-socket "$api" receive-migration \
            "receiver_url=unix:$socket,memory_mode=postcopy" >"$receive_log" 2>&1 &
    else
        "$REMOTE" --api-socket "$api" receive-migration \
            "receiver_url=unix:$socket" >"$receive_log" 2>&1 &
    fi
    RECEIVE_PID=$!
    PIDS+=("$RECEIVE_PID")
    wait_for_socket "$RECEIVE_PID" "$socket"

    RECEIVER_API=$api
    RESTORE_SOCKET=$socket
    RECEIVER_LOG=$vmm_log
}

stop_receiver() {
    "$REMOTE" --api-socket "$RECEIVER_API" shutdown-vmm >/dev/null 2>&1 || true
    wait_pid "$RECEIVER_PID" "receiver VMM"
}

run_eager_control() {
    echo "Running eager control..."
    start_receiver eager eager

    "$OFFLOAD" restore --socket "$RESTORE_SOCKET" --input-dir "$SNAPSHOT" --resume \
        >"$OUT/eager-daemon.log" 2>&1 &
    local daemon_pid=$!
    PIDS+=("$daemon_pid")
    wait_pid "$RECEIVE_PID" "eager receive-migration"
    wait_pid "$daemon_pid" "eager restore daemon"

    sleep 3
    if rg -a -q "triple-faulted|VmExit::Reset" "$RECEIVER_LOG"; then
        echo "eager=FAIL reset observed" | tee "$OUT/eager-result.txt"
    else
        echo "eager=PASS no reset for 3 seconds" | tee "$OUT/eager-result.txt"
    fi
    stop_receiver
}

find_memfd() {
    local pid=$1 fd target
    for fd in /proc/"$pid"/fd/*; do
        target=$(readlink "$fd" 2>/dev/null || true)
        if [[ "$target" == *offload-slot-0* ]]; then
            echo "$fd"
            return 0
        fi
    done
    return 1
}

compare_completed_prefix() {
    local daemon_pid=$1
    local memfd
    memfd=$(find_memfd "$daemon_pid") || die "could not locate offload slot memfd"

    python3 - "$SNAPSHOT/memory-0" "$memfd" "$OUT/prefix-comparison.txt" <<'PY'
import hashlib
import pathlib
import sys

snapshot_path, memfd_path, output_path = sys.argv[1:]
pages = 4095
page_size = 4096
snapshot_hash = hashlib.sha256()
memfd_hash = hashlib.sha256()
equal_pages = 0
zero_pages = 0
nonzero_pages = 0
first_mismatch = None

with open(snapshot_path, "rb", buffering=0) as snapshot, open(memfd_path, "rb", buffering=0) as memfd:
    for page in range(pages):
        expected = snapshot.read(page_size)
        delivered = memfd.read(page_size)
        snapshot_hash.update(expected)
        memfd_hash.update(delivered)
        if expected == bytes(page_size):
            zero_pages += 1
        else:
            nonzero_pages += 1
        if expected == delivered:
            equal_pages += 1
        elif first_mismatch is None:
            first_mismatch = page

result = (
    f"pages_compared={pages}\n"
    f"equal_pages={equal_pages}\n"
    f"zero_pages={zero_pages}\n"
    f"nonzero_pages={nonzero_pages}\n"
    f"first_mismatch={first_mismatch}\n"
    f"snapshot_sha256={snapshot_hash.hexdigest()}\n"
    f"delivered_sha256={memfd_hash.hexdigest()}\n"
)
pathlib.Path(output_path).write_text(result, encoding="utf-8")
print(result, end="")
if equal_pages != pages:
    raise SystemExit(1)
PY
}

run_paused_prefault_control() {
    echo "Running paused postcopy/full-prefault control..."
    start_receiver paused-prefault postcopy

    "$OFFLOAD" restore --socket "$RESTORE_SOCKET" --input-dir "$SNAPSHOT" --ondemand \
        >"$OUT/paused-prefault-daemon.log" 2>&1 &
    local daemon_pid=$!
    PIDS+=("$daemon_pid")

    wait_for_log "$daemon_pid" "$OUT/paused-prefault-daemon.log" "PageFault #4096:"
    kill -STOP "$daemon_pid"
    compare_completed_prefix "$daemon_pid"
    kill -CONT "$daemon_pid"

    wait_pid "$RECEIVE_PID" "postcopy receive-migration"
    wait_pid "$daemon_pid" "full background prefault"

    "$REMOTE" --api-socket "$RECEIVER_API" resume
    sleep 3
    if rg -a -q "triple-faulted|VmExit::Reset" "$RECEIVER_LOG"; then
        echo "paused_prefault=FAIL reset observed" | tee "$OUT/paused-prefault-result.txt"
    else
        echo "paused_prefault=PASS no reset after full prefault and resume" \
            | tee "$OUT/paused-prefault-result.txt"
    fi
    stop_receiver
}

run_stalled_resume_control() {
    echo "Running resume-with-stalled-daemon control..."
    start_receiver stalled-resume postcopy

    "$OFFLOAD" restore --socket "$RESTORE_SOCKET" --input-dir "$SNAPSHOT" --ondemand \
        >"$OUT/stalled-resume-daemon.log" 2>&1 &
    local daemon_pid=$!
    PIDS+=("$daemon_pid")

    wait_for_log "$daemon_pid" "$OUT/stalled-resume-daemon.log" "PageFault #4096:"
    kill -STOP "$daemon_pid"
    wait_pid "$RECEIVE_PID" "stalled postcopy receive-migration"

    timeout 5 "$REMOTE" --api-socket "$RECEIVER_API" resume
    sleep 1
    if rg -a -q "triple-faulted|VmExit::Reset" "$RECEIVER_LOG"; then
        echo "stalled_resume=FAIL reset while daemon stopped" \
            | tee "$OUT/stalled-resume-window.txt"
    else
        echo "stalled_resume=PASS no reset while daemon stopped for 1 second" \
            | tee "$OUT/stalled-resume-window.txt"
    fi

    kill -CONT "$daemon_pid"
    if ! wait_pid "$daemon_pid" "stalled restore daemon"; then
        echo "restore_daemon_exit=nonzero" >>"$OUT/stalled-resume-window.txt"
    fi
    sleep 2
    if rg -a -q "triple-faulted|VmExit::Reset" "$RECEIVER_LOG"; then
        echo "stalled_resume_final=FAIL reset observed" | tee "$OUT/stalled-resume-result.txt"
    else
        echo "stalled_resume_final=PASS guest survived after daemon continued" \
            | tee "$OUT/stalled-resume-result.txt"
    fi
    stop_receiver
}

main() {
    command -v rg >/dev/null || die "rg is required"
    [[ -x "$CH" && -x "$REMOTE" && -x "$OFFLOAD" ]] || die "release binaries are missing"
    [[ -r "$SNAPSHOT/memory-0" ]] || die "minimal snapshot is missing"
    [[ -c /dev/userfaultfd ]] || die "/dev/userfaultfd is missing"

    mkdir -p "$OUT"
    getfacl --absolute-names /dev/userfaultfd >"$ACL_BACKUP"
    sudo setfacl -m "u:$(id -un):rw" /dev/userfaultfd
    ACL_CHANGED=1

    sha256sum "$SNAPSHOT"/* >"$OUT/snapshot-sha256.txt"
    run_eager_control
    run_paused_prefault_control
    run_stalled_resume_control
    echo "$OUT" | tee "$ROOT/build/uffd-integrity/latest"
}

main "$@"
