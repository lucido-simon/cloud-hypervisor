# Steps to reproduce

Build Cloud Hypervisor and boot an existing VM with an API socket and shared
memory:

```bash
cargo build --release --package cloud-hypervisor --package offload_daemon

CH=$PWD/target/release/cloud-hypervisor
REMOTE=$PWD/target/release/ch-remote
DAEMON=$PWD/target/release/offload_daemon
WORK=$(mktemp -d /tmp/ch-uffd-repro.XXXXXX)

$CH -v --api-socket "$WORK/source-api.sock" \
    --memory size=1G,shared=on \
    --firmware /path/to/firmware --disk path=/path/to/vm-image \
    >"$WORK/source.log" 2>&1 &
```

After the guest boots, snapshot it:

```bash
$DAEMON snapshot --socket "$WORK/snapshot.sock" \
    --output-dir "$WORK/snapshot" >"$WORK/snapshot-daemon.log" 2>&1 &
until test -S "$WORK/snapshot.sock"; do sleep 0.1; done

$REMOTE --api-socket "$WORK/source-api.sock" pause
$REMOTE --api-socket "$WORK/source-api.sock" send-migration \
    "destination_url=unix:$WORK/snapshot.sock,local=on"
```

Allow access to userfaultfd, then restore with on-demand postcopy:

```bash
getfacl -p /dev/userfaultfd >"$WORK/userfaultfd.acl"
sudo setfacl -m "u:$(id -un):rw" /dev/userfaultfd

$CH -v --api-socket "$WORK/dest-api.sock" \
    >"$WORK/dest.log" 2>&1 &
until $REMOTE --api-socket "$WORK/dest-api.sock" ping >/dev/null 2>&1; do
    sleep 0.1
done

$REMOTE --api-socket "$WORK/dest-api.sock" receive-migration \
    "receiver_url=unix:$WORK/restore.sock,memory_mode=postcopy" &
until test -S "$WORK/restore.sock"; do sleep 0.1; done

$DAEMON restore --socket "$WORK/restore.sock" \
    --input-dir "$WORK/snapshot" --resume --ondemand \
    >"$WORK/restore-daemon.log" 2>&1
```

The migration reports success, but the restored guest immediately resets:

```text
Guest likely triple-faulted
VmExit::Reset
```

Full VMM and daemon logs are under `$WORK`.

```bash
$REMOTE --api-socket "$WORK/dest-api.sock" shutdown-vmm || true
sudo setfacl --restore="$WORK/userfaultfd.acl"
```
