# UFFD postcopy restore investigation handoff

## Purpose

This branch packages the investigation of a Cloud Hypervisor on-demand
postcopy restore failure. It is intended to be checked out on another,
preferably bare-metal, host and handed to an agent that has no access to the
original conversation.

The short version is:

- Eager restore succeeds.
- On-demand restore through `offload_daemon` immediately triple-faults the
  restored guest and Cloud Hypervisor cold-reboots it.
- This reproduces with one vCPU and a diskless, networkless VM.
- Snapshot bytes written into the shared memfd were verified byte-for-byte.
- Touching the destination mapping before `UFFDIO_WAKE` did not fix it.
- Resolving with `UFFDIO_CONTINUE` instead of only `UFFDIO_WAKE` succeeded in
  the proof of concept.
- The successful `CONTINUE` result currently has only one 16-vCPU benchmark
  run. A stable 10-run bare-metal benchmark is still required.

## Branch state

The branch is based on:

```text
616bafbe8 block: io: Drop the redundant unsafe around the aio submit
```

The Cloud Hypervisor source remains at the clean baseline. The experimental
Rust changes are stored as patch files instead of being applied to the source:

```text
build/uffd-handoff/patches/minor-continue-telemetry.patch.gz
build/uffd-handoff/patches/serialized-worker-telemetry.patch.gz
```

This makes baseline reproduction possible immediately after checkout. Apply
one patch at a time on a new branch when testing a PoC.

Large and host-specific artifacts are intentionally not committed:

- VM images
- firmware and kernels
- snapshot `memory-*` files
- build products

They must be supplied or recreated on the target host.

## Relevant files

```text
UFFD_POSTCOPY_HANDOFF.md
build/dev-loop.sh
build/uffd-postcopy-bench.sh
build/uffd-integrity/run-controls.sh
build/uffd-issue-diagnostics/steps-to-reproduce.md
build/uffd-issue-diagnostics/diagnostics.txt
build/uffd-handoff/patches/
build/uffd-handoff/results/
```

The issue diagnostics include the original host information, VM
configuration, `cloud-hypervisor -v` output, `offload_daemon` output, and
binary version.

## Current data path

The failing local on-demand restore does not map the snapshot file directly
as guest RAM. The data path is:

```text
snapshot memory-N file
        |
        | pread by offload_daemon
        v
temporary daemon buffer
        |
        | write through daemon MAP_SHARED alias
        v
new empty memfd, also mapped by Cloud Hypervisor
```

The important implementation points are:

1. `offload_daemon restore --ondemand` creates an empty memfd for each memory
   slot.
2. It maps the memfd with `MAP_SHARED` and sends the fd to the destination
   VMM.
3. Cloud Hypervisor maps a received memory fd with `MAP_SHARED`.
4. Cloud Hypervisor registers the guest RAM VMA with userfaultfd in missing
   mode.
5. On a fault, Cloud Hypervisor sends the GPA and length to the daemon.
6. The daemon reads the snapshot page and writes it through its memfd alias.
7. The daemon responds without an inline payload.
8. Baseline Cloud Hypervisor only issues `UFFDIO_WAKE`.

The snapshot file and memfd are different backing objects. The daemon must
copy the page into the memfd before the destination can use it.

## UFFD semantics relevant to the fix

For a memfd, the backing object is shmem.

- A missing fault means there is no shmem folio for the file offset.
- A minor fault means the shmem folio exists, but the destination VMA has no
  PTE.
- `UFFDIO_COPY` creates and installs a page from an explicit source buffer.
- `UFFDIO_CONTINUE` installs a PTE for an existing shmem folio.
- `UFFDIO_WAKE` wakes blocked threads but does not install a page or PTE.

In the failing flow, the original event is normally missing. After the daemon
writes through the second mapping, the folio exists while the destination PTE
is still absent. At that point, `UFFDIO_CONTINUE` can install the PTE and wake
the original waiter.

The supported ABI for this approach is:

1. Negotiate `UFFD_FEATURE_MISSING_SHMEM` and
   `UFFD_FEATURE_MINOR_SHMEM` with `UFFDIO_API`.
2. Register the range with `UFFDIO_REGISTER_MODE_MISSING |
   UFFDIO_REGISTER_MODE_MINOR`.
3. Check that `UFFDIO_CONTINUE` is present in the range ioctl mask returned by
   `UFFDIO_REGISTER`.
4. Populate the memfd page through the alias.
5. Issue `UFFDIO_CONTINUE` and validate the reported mapped length.

Without minor registration, prefaulted shmem pages are mapped automatically
on access and no minor event is delivered. Current kernels may mechanically
allow `UFFDIO_CONTINUE` after a missing-only registration, but the kernel
explicitly removes `UFFDIO_CONTINUE` from the advertised range ioctl mask.
Do not rely on that behavior for an upstream solution.

`UFFD_FEATURE_MISSING_SHMEM` was introduced in Linux 4.11.
`UFFDIO_CONTINUE` and hugetlb minor faults arrived in Linux 5.13.
`UFFD_FEATURE_MINOR_SHMEM` arrived in Linux 5.14. `/dev/userfaultfd` is
available on Linux 6.1 and newer; Cloud Hypervisor can otherwise fall back to
the `userfaultfd(2)` syscall if host policy permits it.

## Failure signature

The failing VMM log contains this sequence within roughly one millisecond:

```text
Event: source = vm event = restored
Event: source = vm event = resuming
Guest likely triple-faulted
VmExit::Reset
Event: source = vm event = rebooting
Event: source = vm event = rebooted
```

The `resumed` event can appear after the triple fault because the vCPU and VMM
threads race. It is not proof that the restored guest ran successfully.

The daemon usually reports page requests followed by EOF or `Broken pipe`.

## Why the guest appears to recover

The triple fault is reported by KVM as `VmExit::Reset`. The VMM event loop
calls `vm_reboot()` in `vmm/src/lib.rs`.

`vm_reboot()`:

1. Takes and shuts down the restored VM.
2. Stops the UFFD handler and closes the daemon fault connection.
3. Drops the restored guest RAM and device state.
4. Retains only the VM configuration.
5. Creates a new VM with fresh memory.
6. Reloads the firmware or kernel and boots the disk normally.

The apparent recovery is an unintended cold boot, not a successful restore.
This is also why the existing integration test missed the bug: it waits for
SSH and checks devices, both of which can succeed after the cold boot. It does
not reject `VmExit::Reset`, `rebooting`, or a changed boot identity. In
on-demand mode it also drops the daemon child without checking its status.

## Experiment results

### Baseline on-demand restore

Result: **FAIL**.

- Reproduced with 1, 2, 4, 8, and 16 vCPUs.
- Reproduced after removing telemetry.
- Reproduced with a 1-vCPU, 256 MiB direct-kernel VM with no disk and no
  network device.
- Reproduced with ordinary image-backed guests.
- Representative log:
  `build/uffd-handoff/results/baseline-1vcpu/run-01-vmm.log`.

### Eager restore

Result: **PASS**.

The guest remained alive without a reset. This shows that the saved CPU,
device, and memory state is usable when RAM is populated before resume.

Logs are under `build/uffd-handoff/results/eager/`.

### Full prefault while paused

Result: **PASS**.

The destination was restored paused, all pages were populated, and the VM was
then resumed. No reset occurred. This strongly isolates the failure to the
on-demand fault resolution path.

The control also compared the first 4095 completed pages in the destination
memfd against the snapshot:

```text
pages_compared=4095
equal_pages=4095
first_mismatch=None
```

Results are under `build/uffd-handoff/results/integrity-controls/`.

### Resume with the daemon stopped

The VM did not reset while the daemon was stopped and fault servicing was
blocked. It reset after the daemon continued and faults were resolved through
the baseline `WAKE` path. This is another indication that the bad transition
occurs when fault waiters are released.

### Volatile read before WAKE

Result: **FAIL**.

After the daemon response, the UFFD handler performed a volatile read from
the destination VMA before `UFFDIO_WAKE`. The reads completed and logged data,
but the guest still triple-faulted.

This rules out "the normal Cloud Hypervisor process PTE was never installed"
as the complete explanation. KVM still has its own GFN-to-PFN/EPT/NPT fault
resolution path.

Logs are under `build/uffd-handoff/results/volatile-read/`.

### Full 4 KiB page comparison before WAKE

Result: **FAIL**, with all compared bytes correct.

For diagnostics, the daemon returned the expected snapshot page inline while
also writing the shared memfd. Cloud Hypervisor compared all 4096 bytes in its
mapping before waking the fault.

Before reset, 58 pages were served and every page matched byte-for-byte. There
were zero mismatches. The guest still triple-faulted.

This eliminates corruption between the snapshot read and the destination
mapping for the pages involved.

Logs are under `build/uffd-handoff/results/page-compare/`.

### Inline UFFDIO_COPY

Result: **PASS** in the diagnostic implementation.

The daemon sent page bytes inline and Cloud Hypervisor resolved missing faults
with `UFFDIO_COPY`. A 16-vCPU VM remained alive and completed background
prefault. The temporary COPY patch was discarded and is not preserved here;
the logs are under `build/uffd-handoff/results/inline-copy-16vcpu/`.

### UFFDIO_CONTINUE

Result: **PASS** in the current PoC.

The PoC negotiates shmem minor support, registers shared ranges for missing
and minor faults, has the daemon populate the memfd alias, and resolves with
`UFFDIO_CONTINUE`. It intentionally has no COPY fallback and does not attempt
to make duplicate or concurrent fault handling production-ready.

It passed:

- the minimal 1-vCPU diskless restore;
- one 16-vCPU, 1 GiB benchmark restore;
- background prefault completion.

The patch is:

```text
build/uffd-handoff/patches/minor-continue-telemetry.patch.gz
```

The 16-vCPU run served 103,140 guest-demand pages. Selected cumulative counts:

```text
10 ms:        4
100 ms:    2,139
500 ms:   14,431
1 s:      28,224
2 s:      56,455
5 s:     103,137
10 s:    103,140
```

This is only one run and is not stable benchmark data. Run 10 repetitions on
bare metal before drawing performance conclusions.

### Serialized worker PoC

The earlier user PoC moved UFFD work into a small worker pool while
serializing access to the socket-backed page source with a mutex. It also
contains timing telemetry. It predates the confirmed `CONTINUE` solution and
therefore still needs to be rebased or combined carefully.

The patch is:

```text
build/uffd-handoff/patches/serialized-worker-telemetry.patch.gz
```

Do not apply both patches simultaneously without resolving their overlapping
changes in `vmm/src/memory_manager.rs`.

## Current conclusion

The evidence supports this diagnosis:

- The snapshot is valid.
- The daemon reads the expected page.
- The shared memfd contains the expected full 4 KiB page.
- Cloud Hypervisor can read the page through its own VMA.
- Waking the blocked fault without using a page-delivery ioctl is insufficient
  for this KVM restore path.
- Formal resolution with `UFFDIO_COPY` or `UFFDIO_CONTINUE` works.

The production-oriented direction is `UFFDIO_CONTINUE` because the daemon
already populated the shared memfd and sending/copying the page a second time
is unnecessary.

## Git history

The relevant behavior was introduced by:

```text
60398f11ffb5c4ce1211aaf05f7d324918ce4a32
offload_daemon: Add --ondemand restore mode

282d1c989d9744b094e8e1c1beb225480f4d60f1
vmm: Add SocketUffdMemorySource implementation

48ba1f141762515b60416ba439f1b4c4bbf9635b
vmm: Add postcopy support to receive-migration
```

The code is present in release `v53.0`. Release `v52` does not contain this
flow. Remote TCP postcopy sends page data inline and uses `UFFDIO_COPY`, so it
is not the same failing path.

## Bare-metal host setup

Start by checking:

```bash
uname -a
cat /etc/os-release
test -r /dev/kvm && test -w /dev/kvm
ls -l /dev/userfaultfd
grep -E 'userfaultfd|kvm' /proc/misc
```

Recommended host requirements:

- x86_64 with KVM;
- kernel 6.1 or newer for `/dev/userfaultfd`;
- `acl`, `qemu-img`, `dosfstools`, `mtools`, `python3`, `rg`, `flock`, and
  `timeout`;
- Rust stable plus nightly rustfmt;
- a bootable image with systemd and Python 3 for the benchmark workload;
- a PVH-capable kernel for direct boot, or Cloud Hypervisor firmware.

Temporarily grant access to userfaultfd and always restore the original ACL:

```bash
getfacl --absolute-names /dev/userfaultfd >/tmp/userfaultfd.acl
sudo setfacl -m "u:$(id -un):rw" /dev/userfaultfd

# Run tests here.

sudo setfacl --restore=/tmp/userfaultfd.acl
```

The harnesses perform this backup and restoration automatically.

## Baseline reproduction on the new host

Follow:

```text
build/uffd-issue-diagnostics/steps-to-reproduce.md
```

Use the VM image and boot arguments already available on the host. Preserve
the snapshot directory because the integrity controls consume it.

Verify the failure explicitly instead of relying on guest reachability:

```bash
rg -a -n 'triple-faulted|VmExit::Reset|event = (rebooting|rebooted)' \
    /path/to/destination-vmm.log
```

Expected baseline result: at least one triple fault, reset, and cold reboot.

If the baseline passes on bare metal, stop and investigate the nested-KVM
difference before benchmarking patches.

## Running the integrity controls

Build release binaries, create a snapshot, then run:

```bash
UFFD_SNAPSHOT_DIR=/absolute/path/to/snapshot \
    ./build/uffd-integrity/run-controls.sh
```

The script runs:

- eager restore;
- paused restore followed by full background prefault and resume;
- resume while the daemon is temporarily stopped;
- snapshot-to-memfd prefix comparison.

It prints the result directory and writes it under `build/uffd-integrity` by
default. Override that with `UFFD_INTEGRITY_OUTPUT_ROOT`.

The snapshot configuration embeds kernel, firmware, initramfs, disk, and
device paths. Those paths must remain valid on the same host.

## Testing the CONTINUE PoC

Create a new topic branch from this handoff branch, then apply the patch:

```bash
git switch -c test/minor-continue
gzip -dc build/uffd-handoff/patches/minor-continue-telemetry.patch.gz \
    | git apply --check
gzip -dc build/uffd-handoff/patches/minor-continue-telemetry.patch.gz \
    | git apply

cargo +nightly fmt --all -- --check
cargo check --workspace --features kvm
cargo build --release --package cloud-hypervisor --package offload_daemon
```

The PoC intentionally panics or fails restore if the host cannot negotiate
minor shmem support or `UFFDIO_CONTINUE`. It does not fall back to COPY.

Run the minimal/manual reproduction first. Success means:

- no `triple-faulted` log;
- no `VmExit::Reset`;
- no `rebooting` or `rebooted` event;
- the restored guest remains alive;
- the UFFD handler eventually reports background prefault completion.

The patch also adds `UFFDIO_CONTINUE` to the VMM seccomp ioctl allowlist. If
the code works with `--seccomp false` but fails with default seccomp, inspect
that rule first.

## Running the 16-vCPU benchmark

The benchmark script creates a cloud-init workload, snapshots it, repeatedly
restores it, and parses `UFFD_PAGES` telemetry. The telemetry PoC must be
applied; the clean baseline has no such log records and the parser will stop
with `produced no UFFD_PAGES telemetry`.

Direct-kernel example:

```bash
BENCH_DIRECT_DISK=/absolute/path/to/guest.qcow2 \
BENCH_DIRECT_DISK_FORMAT=qcow2 \
BENCH_DIRECT_KERNEL=/absolute/path/to/vmlinux \
BENCH_BOOT_MODE=direct \
BENCH_VCPUS=16 \
BENCH_MEMORY_SIZE=1G \
BENCH_RUNS=1 \
BENCH_LABEL=baremetal-smoke \
    ./build/uffd-postcopy-bench.sh
```

The direct-boot command line assumes the root filesystem is `/dev/vda1`.
Adjust `snapshot_source()` if the image uses a different root partition.

Firmware example:

```bash
BENCH_FIRMWARE_DISK=/absolute/path/to/guest.raw \
BENCH_FIRMWARE_DISK_FORMAT=raw \
BENCH_FIRMWARE=/absolute/path/to/hypervisor-fw \
BENCH_BOOT_MODE=firmware \
BENCH_VCPUS=16 \
BENCH_RUNS=1 \
BENCH_LABEL=baremetal-smoke-firmware \
    ./build/uffd-postcopy-bench.sh
```

After a successful smoke run, collect stable data:

```bash
BENCH_DIRECT_DISK=/absolute/path/to/guest.qcow2 \
BENCH_DIRECT_KERNEL=/absolute/path/to/vmlinux \
BENCH_BOOT_MODE=direct \
BENCH_VCPUS=16 \
BENCH_RUNS=10 \
BENCH_LABEL=minor-continue-baremetal-10x \
    ./build/uffd-postcopy-bench.sh
```

Results are written to:

```text
build/uffd-bench/results/<label>/raw.csv
build/uffd-bench/results/<label>/run-NN.csv
build/uffd-bench/results/<label>/summary.csv
build/uffd-bench/results/<label>/run-NN-vmm.log
build/uffd-bench/results/<label>/run-NN-daemon.log
```

Before accepting benchmark results, scan every VMM log:

```bash
rg -a -n 'triple-faulted|VmExit::Reset|event = (rebooting|rebooted)' \
    build/uffd-bench/results/minor-continue-baremetal-10x
```

This command must return no matches.

## Development loop

`build/dev-loop.sh` is the earlier source iteration helper. It:

- watches the workspace with `cargo watch`;
- rebuilds the workspace;
- sets `cap_net_admin` on the debug Cloud Hypervisor binary;
- restarts a small VM only when Cloud Hypervisor-related sources changed;
- leaves the VM running when only another project binary changed;
- runs Cloud Hypervisor with `-vv`;
- mirrors stdout and stderr into `build/dev-loop/vmm.log`.

Configure it with:

```bash
CH_FIRMWARE=/absolute/path/to/hypervisor-fw \
CH_BASE_DISK=/absolute/path/to/base.raw \
    ./build/dev-loop.sh watch
```

Stop it before running the benchmark harness:

```bash
./build/dev-loop.sh stop
```

## Production concerns not solved by the PoC

The current `CONTINUE` patch demonstrates correctness but is not a finished
upstream patch. A production implementation must address:

- duplicate faults for one page;
- concurrent faults from multiple vCPUs;
- races between background prefault and guest-demand faults;
- partial range results and retryable errors from `UFFDIO_CONTINUE`;
- clear behavior when minor shmem support is unavailable;
- all architectures and hypervisor backends;
- seccomp policy;
- migration compatibility and protocol versioning;
- an integration test that distinguishes restored execution from cold boot.

The integration test should inspect the VMM event stream or logs for resets
and should preserve a guest-side boot identity across snapshot/restore. Merely
waiting for SSH is insufficient.

## Suggested next-agent sequence

1. Read this file and `CONTRIBUTING.md`.
2. Verify the branch and host environment.
3. Reproduce the clean baseline failure on bare metal.
4. Run the eager and full-prefault controls.
5. Apply the minor/continue patch on a new topic branch.
6. Verify a 1-vCPU minimal restore with no reset.
7. Verify a 16-vCPU image-backed restore with no reset.
8. Run one telemetry benchmark as a smoke test.
9. Run 10 benchmark repetitions.
10. Save raw logs, CSVs, kernel version, CPU model, and CH version.
11. Only then start hardening concurrent and duplicate fault handling.

## Useful log queries

Failure or accidental cold boot:

```bash
rg -a -n 'triple-faulted|VmExit::Reset|event = (rebooting|rebooted)' LOG
```

Restore lifecycle:

```bash
rg -a -n 'event = (restoring|restored|resuming|resumed|shutdown)' LOG
```

UFFD activity:

```bash
rg -a -n 'UFFD|PageFault|UFFD_PAGES' LOG
```

Host details to retain with results:

```bash
target/release/cloud-hypervisor --version
uname -a
cat /etc/os-release
lscpu
```
