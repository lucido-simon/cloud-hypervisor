#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STATE_DIR="$ROOT_DIR/build/uffd-bench"
STORE_DIR="$STATE_DIR/snapshot"
FIRMWARE_BASE_SOURCE=${BENCH_FIRMWARE_DISK:-"$ROOT_DIR/build/focal-server-cloudimg-amd64.raw"}
FIRMWARE_BASE_FORMAT=${BENCH_FIRMWARE_DISK_FORMAT:-raw}
FIRMWARE=${BENCH_FIRMWARE:-"$ROOT_DIR/build/hypervisor-fw"}
DIRECT_BASE_SOURCE=${BENCH_DIRECT_DISK:-"/home/simonlucido/workloads/jammy-server-cloudimg-amd64-custom-20241017-0.qcow2"}
DIRECT_BASE_FORMAT=${BENCH_DIRECT_DISK_FORMAT:-qcow2}
DIRECT_KERNEL=${BENCH_DIRECT_KERNEL:-"/home/simonlucido/workloads/vmlinux-x86_64"}
VM_DISK="$STATE_DIR/vm.qcow2"
BASELINE_DISK="$STATE_DIR/vm-baseline.qcow2"
CLOUD_INIT="$STATE_DIR/cloud-init.img"
SOURCE_API="$STATE_DIR/source-api.sock"
SNAPSHOT_SOCKET="$STATE_DIR/snapshot.sock"
SOURCE_CONSOLE="$STATE_DIR/source-console.log"
SOURCE_LOG="$STATE_DIR/source-vmm.log"
SNAPSHOT_LOG="$STATE_DIR/snapshot-daemon.log"
ACL_BACKUP="$STATE_DIR/userfaultfd.acl"
HARNESS_LOCK="$ROOT_DIR/build/.uffd-postcopy-bench.lock"

RUNS=${BENCH_RUNS:-10}
SAMPLE_SECONDS=${BENCH_SAMPLE_SECONDS:-12}
BOOT_TIMEOUT=${BENCH_BOOT_TIMEOUT:-240}
COMMAND_TIMEOUT=${BENCH_COMMAND_TIMEOUT:-120}
MEMORY_SIZE=${BENCH_MEMORY_SIZE:-1G}
VCPUS=${BENCH_VCPUS:-16}
BOOT_MODE=${BENCH_BOOT_MODE:-direct}
BENCH_LABEL=${BENCH_LABEL:-poc}
CURRENT_USER=$(id -un)
RESULTS_DIR="$STATE_DIR/results/$BENCH_LABEL"
RAW_CSV="$RESULTS_DIR/raw.csv"
SUMMARY_CSV="$RESULTS_DIR/summary.csv"

case "$BOOT_MODE" in
direct)
    BASE_SOURCE="$DIRECT_BASE_SOURCE"
    BASE_FORMAT="$DIRECT_BASE_FORMAT"
    ;;
firmware)
    BASE_SOURCE="$FIRMWARE_BASE_SOURCE"
    BASE_FORMAT="$FIRMWARE_BASE_FORMAT"
    ;;
*)
    BASE_SOURCE=""
    BASE_FORMAT=""
    ;;
esac

CH="$ROOT_DIR/target/release/cloud-hypervisor"
REMOTE="$ROOT_DIR/target/release/ch-remote"
OFFLOAD="$ROOT_DIR/target/release/offload_daemon"

SOURCE_PID=""
DEST_PID=""
SNAPSHOT_PID=""
RESTORE_PID=""
RECEIVE_PID=""
ACL_CHANGED=0
STATE_OWNED=0

die() {
    echo "error: $*" >&2
    exit 1
}

kill_and_wait() {
    local pid=${1:-}
    [[ -n "$pid" ]] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for _ in {1..100}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM

    kill_and_wait "$RECEIVE_PID"
    kill_and_wait "$RESTORE_PID"
    kill_and_wait "$DEST_PID"
    kill_and_wait "$SNAPSHOT_PID"
    kill_and_wait "$SOURCE_PID"
    if ((STATE_OWNED)); then
        rm -f "$STATE_DIR"/*.sock
    fi

    if ((ACL_CHANGED)); then
        sudo setfacl --restore="$ACL_BACKUP" || \
            echo "warning: failed to restore /dev/userfaultfd ACL from $ACL_BACKUP" >&2
    fi

    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

wait_for_process_file() {
    local pid=$1
    local path=$2
    local description=$3
    local timeout_s=$4
    local deadline=$((SECONDS + timeout_s))

    while [[ ! -e "$path" ]]; do
        kill -0 "$pid" 2>/dev/null || die "$description exited before creating $path"
        ((SECONDS < deadline)) || die "timed out waiting for $description to create $path"
        sleep 0.1
    done
}

wait_for_api() {
    local pid=$1
    local socket=$2
    local log=$3
    local deadline=$((SECONDS + COMMAND_TIMEOUT))

    while true; do
        if [[ -S "$socket" ]] && "$REMOTE" --api-socket "$socket" ping >/dev/null 2>&1; then
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            tail -n 80 "$log" >&2 || true
            die "VMM exited before its API became ready"
        fi
        ((SECONDS < deadline)) || {
            tail -n 80 "$log" >&2 || true
            die "timed out waiting for VMM API at $socket"
        }
        sleep 0.1
    done
}

wait_for_console_marker() {
    local pid=$1
    local marker=$2
    local deadline=$((SECONDS + BOOT_TIMEOUT))

    while ! grep -Fq "$marker" "$SOURCE_CONSOLE" 2>/dev/null; do
        if ! kill -0 "$pid" 2>/dev/null; then
            tail -n 80 "$SOURCE_LOG" >&2 || true
            die "source VMM exited before the guest workload became ready"
        fi
        ((SECONDS < deadline)) || {
            tail -n 80 "$SOURCE_CONSOLE" >&2 || true
            tail -n 80 "$SOURCE_LOG" >&2 || true
            die "timed out waiting for guest marker: $marker"
        }
        sleep 0.25
    done
}

wait_for_pid() {
    local pid=$1
    local description=$2
    local timeout_s=$3
    local deadline=$((SECONDS + timeout_s))

    while kill -0 "$pid" 2>/dev/null; do
        ((SECONDS < deadline)) || die "timed out waiting for $description (PID $pid)"
        sleep 0.1
    done
    wait "$pid"
}

require_commands() {
    local command
    for command in cargo qemu-img mkdosfs mcopy sudo setfacl getfacl sed awk sort cat \
        flock timeout; do
        command -v "$command" >/dev/null || die "missing required command: $command"
    done
    [[ -c /dev/kvm ]] || die "/dev/kvm is unavailable"
    [[ -r /dev/kvm && -w /dev/kvm ]] || die "current user cannot access /dev/kvm"
    [[ -c /dev/userfaultfd ]] || die "/dev/userfaultfd is unavailable; Linux 6.1+ is required"
    [[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || die "BENCH_RUNS must be a positive integer"
    [[ "$SAMPLE_SECONDS" =~ ^[1-9][0-9]*$ ]] || \
        die "BENCH_SAMPLE_SECONDS must be a positive integer"
    [[ "$VCPUS" =~ ^[1-9][0-9]*$ ]] || die "BENCH_VCPUS must be a positive integer"
    [[ "$BOOT_MODE" =~ ^(direct|firmware)$ ]] || \
        die "BENCH_BOOT_MODE must be either direct or firmware"
    [[ "$BENCH_LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
        die "BENCH_LABEL must contain only letters, digits, dots, underscores, or hyphens"
    [[ -r "$BASE_SOURCE" ]] || die "missing $BOOT_MODE boot disk: $BASE_SOURCE"
    if [[ "$BOOT_MODE" == direct ]]; then
        [[ -r "$DIRECT_KERNEL" ]] || die "missing direct-boot kernel: $DIRECT_KERNEL"
    else
        [[ -r "$FIRMWARE" ]] || die "missing firmware: $FIRMWARE"
    fi
}

check_dev_loop_stopped() {
    local pid_file="$ROOT_DIR/build/dev-loop/vm.pid"
    if [[ -s "$pid_file" ]] && kill -0 "$(<"$pid_file")" 2>/dev/null; then
        die "the development-loop VM is running; stop it with ./build/dev-loop.sh stop"
    fi
}

grant_userfaultfd_access() {
    getfacl --absolute-names /dev/userfaultfd >"$ACL_BACKUP"
    sudo -v
    sudo setfacl -m "u:$CURRENT_USER:rw" /dev/userfaultfd
    ACL_CHANGED=1
    [[ -r /dev/userfaultfd && -w /dev/userfaultfd ]] || \
        die "failed to grant $CURRENT_USER access to /dev/userfaultfd"
}

build_binaries() {
    echo "Building release binaries..."
    cargo build --release \
        --package cloud-hypervisor \
        --package offload_daemon
    [[ -x "$CH" && -x "$REMOTE" && -x "$OFFLOAD" ]] || \
        die "release build did not produce all required binaries"
}

create_cloud_init() {
    local seed_dir="$STATE_DIR/cloud-init"
    mkdir -p "$seed_dir"

    cat >"$seed_dir/meta-data" <<'EOF'
instance-id: uffd-postcopy-bench
local-hostname: uffd-bench
EOF

    cat >"$seed_dir/network-config" <<'EOF'
version: 2
ethernets: {}
EOF

    cat >"$seed_dir/user-data" <<EOF
#cloud-config
network:
  config: disabled
write_files:
  - path: /usr/local/bin/uffd-bench-workload.py
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/python3
      import multiprocessing as mp
      import os
      import sys

      WORKERS = $VCPUS
      BYTES_PER_WORKER = 24 * 1024 * 1024
      PAGE_SIZE = 4096

      def worker(worker_id, ready, start):
          os.sched_setaffinity(0, {worker_id})
          memory = bytearray(BYTES_PER_WORKER)
          for page, offset in enumerate(range(0, BYTES_PER_WORKER, PAGE_SIZE)):
              memory[offset] = (worker_id + page) & 0xff
          ready.put(worker_id)
          start.wait()

          generation = 0
          while True:
              for page, offset in enumerate(range(0, BYTES_PER_WORKER, PAGE_SIZE)):
                  memory[offset] = (memory[offset] + worker_id + page + generation) & 0xff
              generation = (generation + 1) & 0xff

      def main():
          mp.set_start_method("fork")
          ready = mp.Queue()
          start = mp.Event()
          children = [
              mp.Process(target=worker, args=(worker_id, ready, start))
              for worker_id in range(WORKERS)
          ]
          for child in children:
              child.start()
          for _ in children:
              ready.get(timeout=120)
          marker = f"UFFD_BENCH_READY workers={WORKERS} bytes_per_worker={BYTES_PER_WORKER}"
          try:
              with open("/dev/hvc0", "w", buffering=1) as console:
                  console.write(marker + "\n")
          except OSError as error:
              print(f"failed to write readiness marker to /dev/hvc0: {error}",
                    file=sys.stderr, flush=True)
              raise
          start.set()
          for child in children:
              child.join()

      if __name__ == "__main__":
          main()
  - path: /etc/systemd/system/uffd-bench-workload.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=Deterministic UFFD benchmark workload

      [Service]
      Type=simple
      ExecStart=/usr/bin/python3 -u /usr/local/bin/uffd-bench-workload.py
      Restart=no
      StandardOutput=journal+console
      StandardError=journal+console

      [Install]
      WantedBy=multi-user.target
runcmd:
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, uffd-bench-workload.service]
EOF

    rm -f "$CLOUD_INIT"
    mkdosfs -n CIDATA -C "$CLOUD_INIT" 8192 >/dev/null
    mcopy -oi "$CLOUD_INIT" -s \
        "$seed_dir/user-data" "$seed_dir/meta-data" "$seed_dir/network-config" ::
}

create_disks() {
    echo "Creating fresh benchmark overlay backed by $BASE_SOURCE..."
    # Discard a partial file left by older versions of this harness that
    # converted the downloaded qcow2 image before creating the overlay.
    rm -f "$STATE_DIR/base.qcow2" "$VM_DISK"
    qemu-img create -q -f qcow2 -F "$BASE_FORMAT" -b "$BASE_SOURCE" "$VM_DISK"
}

snapshot_source() {
    local -a boot_args
    if [[ "$BOOT_MODE" == direct ]]; then
        boot_args=(
            --kernel "$DIRECT_KERNEL"
            --cmdline "root=/dev/vda1 console=hvc0 rw systemd.journald.forward_to_console=1"
        )
    else
        boot_args=(--firmware "$FIRMWARE")
    fi

    echo "Booting $VCPUS-vCPU source VM in $BOOT_MODE mode..."
    rm -f "$SOURCE_API" "$SNAPSHOT_SOCKET" "$SOURCE_CONSOLE"
    "$CH" -v \
        --api-socket "$SOURCE_API" \
        "${boot_args[@]}" \
        --disk "path=$VM_DISK,image_type=qcow2,backing_files=on" \
        --disk "path=$CLOUD_INIT,image_type=raw,readonly=on" \
        --cpus "boot=$VCPUS" \
        --memory "size=$MEMORY_SIZE,shared=on" \
        --serial null \
        --console "file=$SOURCE_CONSOLE" \
        >"$SOURCE_LOG" 2>&1 &
    SOURCE_PID=$!

    wait_for_api "$SOURCE_PID" "$SOURCE_API" "$SOURCE_LOG"
    wait_for_console_marker "$SOURCE_PID" "UFFD_BENCH_READY workers=$VCPUS"
    sleep 2

    "$OFFLOAD" snapshot \
        --socket "$SNAPSHOT_SOCKET" \
        --output-dir "$STORE_DIR" \
        >"$SNAPSHOT_LOG" 2>&1 &
    SNAPSHOT_PID=$!
    wait_for_process_file "$SNAPSHOT_PID" "$SNAPSHOT_SOCKET" \
        "snapshot daemon" "$COMMAND_TIMEOUT"

    "$REMOTE" --api-socket "$SOURCE_API" pause
    timeout "${COMMAND_TIMEOUT}s" \
        "$REMOTE" --api-socket "$SOURCE_API" \
        send-migration "destination_url=unix:$SNAPSHOT_SOCKET,local=on"

    wait_for_pid "$SNAPSHOT_PID" "snapshot daemon" "$COMMAND_TIMEOUT"
    SNAPSHOT_PID=""
    wait_for_pid "$SOURCE_PID" "source VMM" "$COMMAND_TIMEOUT"
    SOURCE_PID=""

    cp --reflink=auto --sparse=always "$VM_DISK" "$BASELINE_DISK"
    qemu-img check -q "$BASELINE_DISK"
    echo "Snapshot and disk baseline are ready."
}

reset_vm_disk() {
    local replacement="$STATE_DIR/vm-replacement.qcow2"
    rm -f "$replacement"
    cp --reflink=auto --sparse=always "$BASELINE_DISK" "$replacement"
    mv -f "$replacement" "$VM_DISK"
}

warm_snapshot_store() {
    local file
    local -a memory_files
    shopt -s nullglob
    memory_files=("$STORE_DIR"/memory-*)
    shopt -u nullglob
    ((${#memory_files[@]} > 0)) || die "snapshot contains no memory slot files"

    # Keep storage-cache state consistent: otherwise run 1 is cold while the
    # remaining restores read pages already cached by the host.
    for file in "${memory_files[@]}"; do
        cat "$file" >/dev/null
    done
}

parse_telemetry() {
    local run=$1
    local log=$2
    local run_csv
    local parsed
    local target
    local matches
    local -a expected_targets=(0 10 25 50 100 250 500 1000 2000 5000 10000)
    run_csv="$RESULTS_DIR/run-$(printf '%02d' "$run").csv"
    parsed="$STATE_DIR/parsed-$(printf '%02d' "$run").csv"

    sed -nE \
        's/.*UFFD_PAGES target_ms=([0-9]+) elapsed_us=([0-9]+) cumulative=([0-9]+) delta=([0-9]+).*/\1,\2,\3,\4/p' \
        "$log" | awk -F, \
        '$1 ~ /^(0|10|25|50|100|250|500|1000|2000|5000|10000)$/ { print }' \
        >"$parsed"
    [[ -s "$parsed" ]] || {
        tail -n 120 "$log" >&2 || true
        die "run $run produced no UFFD_PAGES telemetry"
    }

    for target in "${expected_targets[@]}"; do
        matches=$(awk -F, -v target="$target" '$1 == target { count++ } END { print count + 0 }' \
            "$parsed")
        [[ "$matches" == 1 ]] || \
            die "run $run emitted $matches telemetry records for target_ms=$target; expected 1"
    done

    echo "run,target_ms,elapsed_us,cumulative,delta" >"$run_csv"
    awk -v run="$run" '{ print run "," $0 }' "$parsed" >>"$run_csv"
    tail -n +2 "$run_csv" >>"$RAW_CSV"
}

run_restore() {
    local run=$1
    local run_id
    local api_socket
    local restore_socket
    local vmm_log
    local daemon_log
    local receive_log

    run_id=$(printf '%02d' "$run")
    api_socket="$STATE_DIR/restore-api-$run_id.sock"
    restore_socket="$STATE_DIR/restore-$run_id.sock"
    vmm_log="$RESULTS_DIR/run-$run_id-vmm.log"
    daemon_log="$RESULTS_DIR/run-$run_id-daemon.log"
    receive_log="$RESULTS_DIR/run-$run_id-receive.log"

    echo "Run $run/$RUNS: resetting disk and starting postcopy restore..."
    reset_vm_disk
    warm_snapshot_store
    rm -f "$api_socket" "$restore_socket"

    "$CH" -v --api-socket "$api_socket" >"$vmm_log" 2>&1 &
    DEST_PID=$!
    wait_for_api "$DEST_PID" "$api_socket" "$vmm_log"

    "$REMOTE" --api-socket "$api_socket" receive-migration \
        "receiver_url=unix:$restore_socket,memory_mode=postcopy" \
        >"$receive_log" 2>&1 &
    RECEIVE_PID=$!
    wait_for_process_file "$RECEIVE_PID" "$restore_socket" \
        "receive-migration" "$COMMAND_TIMEOUT"

    "$OFFLOAD" restore \
        --socket "$restore_socket" \
        --input-dir "$STORE_DIR" \
        --resume \
        --ondemand \
        >"$daemon_log" 2>&1 &
    RESTORE_PID=$!

    wait_for_pid "$RECEIVE_PID" "receive-migration" "$COMMAND_TIMEOUT"
    RECEIVE_PID=""

    sleep "$SAMPLE_SECONDS"
    "$REMOTE" --api-socket "$api_socket" shutdown-vmm >/dev/null 2>&1 || \
        kill "$DEST_PID" 2>/dev/null || true
    wait_for_pid "$DEST_PID" "destination VMM" "$COMMAND_TIMEOUT"
    DEST_PID=""
    wait_for_pid "$RESTORE_PID" "restore daemon" "$COMMAND_TIMEOUT"
    RESTORE_PID=""

    parse_telemetry "$run" "$vmm_log"
    rm -f "$api_socket" "$restore_socket"
}

summarize_results() {
    echo "target_ms,runs,mean_cumulative,min_cumulative,max_cumulative,mean_delta" \
        >"$SUMMARY_CSV"
    awk -F, '
        NR > 1 {
            target = $2
            count[target]++
            cumulative[target] += $4
            delta[target] += $5
            if (!(target in min) || $4 < min[target]) min[target] = $4
            if (!(target in max) || $4 > max[target]) max[target] = $4
        }
        END {
            for (target in count) {
                printf "%d,%d,%.2f,%d,%d,%.2f\n", target, count[target],
                    cumulative[target] / count[target], min[target], max[target],
                    delta[target] / count[target]
            }
        }
    ' "$RAW_CSV" | sort -t, -k1,1n >>"$SUMMARY_CSV"
}

main() {
    require_commands
    check_dev_loop_stopped

    exec 9>"$HARNESS_LOCK"
    flock -n 9 || die "another benchmark harness is already running"
    mkdir -p "$STATE_DIR/results"
    # Snapshot and VM state are shared by all labels and are regenerated for
    # every invocation. Keep other labeled result directories intact.
    rm -rf "$STORE_DIR" "$STATE_DIR/cloud-init" "$RESULTS_DIR"
    rm -f "$STATE_DIR"/*.qcow2 "$STATE_DIR"/*.iso "$STATE_DIR"/*.sock \
        "$STATE_DIR"/*.log "$STATE_DIR"/*.acl "$STATE_DIR"/parsed-*.csv
    mkdir -p "$RESULTS_DIR" "$STORE_DIR"
    STATE_OWNED=1

    grant_userfaultfd_access
    build_binaries
    create_cloud_init
    create_disks
    snapshot_source

    echo "run,target_ms,elapsed_us,cumulative,delta" >"$RAW_CSV"
    for run in $(seq 1 "$RUNS"); do
        run_restore "$run"
    done
    summarize_results

    echo "Benchmark label: $BENCH_LABEL"
    echo "Boot mode: $BOOT_MODE"
    echo "Raw results: $RAW_CSV"
    echo "Per-run results: $RESULTS_DIR/run-NN.csv"
    echo "Summary: $SUMMARY_CSV"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
