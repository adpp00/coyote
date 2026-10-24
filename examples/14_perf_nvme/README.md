# Coyote Example 14: NVMe SSD Bandwidth Test
Welcome to the fourteenth Coyote example! In this example we measure the read and write bandwidth of one or more NVMe SSDs that have been claimed by the FPGA shell, with NVMe submission queues (SQ), completion queues (CQ) and PRP lists living in FPGA BRAM. As with all Coyote examples, a brief description of the core Coyote concepts covered in this example are included below. How to synthesize hardware, compile the examples and load the bitstream/driver is explained in the top-level example README in `Coyote/examples/README.md`. Please refer to that file for general Coyote guidance. A complete description of the NVMe stack, its configuration options and its interfaces can be found in the Coyote documentation (*Dynamic layer: Storage Services - NVMe* and *Device driver: NVMe IOCTLs*).

## Table of contents
[Example Overview](#example-overview)

[Prerequisites](#prerequisites)

[Hardware Concepts](#hardware-concepts)

[Software Concepts](#software-concepts)

[Additional Information](#additional-information)

[Results](#results)

## Example overview
This example exercises the NVMe stack added to the Coyote shell. The vFPGA contains a bench engine that, on a `start_rd` or `start_wr` pulse, issues `N_REPS` NVMe commands per active device, with up to `MAX_OUTSTANDING` in flight at a time, and measures the wall-clock cycles between go pulse and the last completion (per device). The software side claims one or more NVMe SSDs via `coyote::cThread::initNVMe()`, programs the per-run parameters into CSRs, kicks off the bench engine and reads back the aggregated bandwidth.

A high-level walk-through of a single run:

1. The host claims the requested NVMe SSDs via `initNVMe()` (`IOCTL_NVME_INIT`). For a host-attached SSD, the driver takes over the PCI device, brings up the controller, sets up an admin queue, identifies the namespace and creates an I/O SQ/CQ whose memory lives in FPGA BRAM. For a PL-attached SSD, the shell's setup engine has already done this, and the driver reads the discovered namespace from the shell. The kernel returns the assigned `dev_id` (one per device), the namespace info (LBA size, NSZE, MDTS) and the LBA range reserved for this vFPGA.
2. The host allocates the buffer (host memory, or HBM with `--fpga-mem`), writes the benchmark CSRs (buffer virtual address, chunk size, number of repetitions per device, starting byte offset within the reserved range, device mask, namespace, max outstanding and the Coyote thread ID in `PID_REG`, used by the shell to translate the buffer address) and pulses `CTRL_REG`.
3. Per-device FSMs in the vFPGA build `nvme_req_t` requests and feed them to a round-robin arbiter, which forwards them to the shell NVMe pipeline on the dedicated `m_nvme_sq` interface.
4. The shell checks the region's permission, translates the buffer address, builds the PRP entries, and stores the NVMe SQE. It enqueues an assignment response on `s_nvme_cq_rsp` before requesting the SQ doorbell. The SSD then transfers the payload to/from the buffer (host memory by default, HBM with `--fpga-mem`).
5. Completions flow back through the CQ BRAM, are decoded into `nvme_cqe_t`, and route to the owning region as `s_nvme_cpl`. Each per-device FSM consumes completions targeting its `dev_id`, decrements its inflight counter and increments its done counter. When all devices have reached `dev_done >= N_REPS` with no inflight commands, the bench is complete.
6. The host polls `DONE_REG` until it matches the expected count and reads `TIMER_REG` to compute the aggregated bandwidth.

The bench engine supports running a subset of devices via the `DEV_MASK` register, so the same hardware build can sweep individual devices or all devices in parallel without re-synthesizing.

## Prerequisites
### Supported boards and connection types
| Board | `NVME_TYPE` | Buffers | Static layer |
| --- | --- | --- | --- |
| U55C, U280 | `HOST` | Host memory | Shipped checkpoint (default shell flow) |
| U55C, U280 | `HOST` | Host memory and HBM (`--fpga-mem`) | Rebuilt: `-DBUILD_STATIC=1 -DBUILD_SHELL=0` |
| V80 | `HOST` | Host memory only | Shipped checkpoint (default shell flow) |
| V80 | `PL` | Host memory and HBM (`--fpga-mem`) | Rebuilt: `-DBUILD_STATIC=1 -DBUILD_SHELL=0` |

- **Host-attached SSDs (`HOST`)**: the SSD sits in a PCIe slot of the host, and the SSD and the FPGA exchange commands, completions and data with PCIe peer-to-peer transactions, so the host must allow peer-to-peer traffic between the two devices.
- **SSD to HBM on the U55C/U280**: the hardware of this example enables card memory (`EN_MEM = 1`), so on the U55C and U280 the shell maps HBM at offsets 256 MB to 16 GB of the FPGA's bypass BAR, where the SSD can reach it. This needs a 16 GB bypass BAR, but the BAR is part of the static layer, and the shipped static checkpoint only has a 256 MB BAR. To use `--fpga-mem`, the static layer must therefore be rebuilt with `-DBUILD_STATIC=1 -DBUILD_SHELL=0`. A shell built against the shipped checkpoint works with host-memory buffers; the driver sees the 256 MB BAR and leaves card memory disabled, so with `--fpga-mem` every command fails with local error 3. As with any static build, program the FPGA with the full bitstream; such a shell cannot be loaded through shell reconfiguration on top of the shipped static layer.
- **V80, `HOST`**: works with the shipped static layer, for host-memory buffers only; card memory is not exposed to the SSD (CMake prints a warning), and with `--fpga-mem` every command fails with local error 3, which the benchmark reports as `err=0x3`.
- **V80, `PL`**: the SSD is connected to an MCIO port and the FPGA is the PCIe root complex. The shipped V80 static checkpoint does not expose the MCIO ports, so CMake rejects the default shell flow; build with `-DBUILD_STATIC=1 -DBUILD_SHELL=0`. Only one SSD is supported.

### Building the hardware
The hardware configuration in `hw/CMakeLists.txt` enables host streams, card memory and NVMe. The NVMe options can be passed to CMake:
- `-DNVME_TYPE=HOST|PL` connection type (default `HOST`).
- `-DNVME_NUM_DEVICES=N` number of SSD slots in the shell (default 1). Set it to the number of SSDs you want to test; this example supports up to 4 (`BENCH_MAX_DEVS`). PL supports only 1.
- `-DNVME_QUEUE_DEPTH=64|128|256` I/O queue depth (default 64).

For example:
```bash
# U55C, host-attached SSDs, host-memory buffers only, linked against the shipped static layer
cmake ../ -DFDEV_NAME=u55c -DNVME_NUM_DEVICES=2

# U55C, host-attached SSDs, also HBM buffers (--fpga-mem); rebuilds the static layer
cmake ../ -DFDEV_NAME=u55c -DNVME_NUM_DEVICES=2 -DBUILD_STATIC=1 -DBUILD_SHELL=0

# V80, PL-attached SSD; rebuilds the static layer
cmake ../ -DFDEV_NAME=v80 -DNVME_TYPE=PL -DBUILD_STATIC=1 -DBUILD_SHELL=0
```

### Host set-up
- **Root privileges**: `initNVMe()` and `closeNVMe()` require `CAP_SYS_ADMIN`, so run the benchmark as root (e.g., with `sudo`).
- **Unbind the SSD from the kernel `nvme` driver** (`HOST` only): the Coyote driver only claims SSDs that are not bound to any driver, and fails with `EBUSY` otherwise. Never unbind a disk that holds a mounted file system, such as the boot disk.
  ```bash
  # Find the SSD's BDF and the driver it is bound to
  lspci -D | grep -i "non-volatile"
  readlink /sys/bus/pci/devices/<BDF>/driver

  # Unbind it from the nvme driver
  echo <BDF> | sudo tee /sys/bus/pci/drivers/nvme/unbind
  ```
  After a PCI rescan, the kernel may bind the `nvme` driver again; unbind it again before running the example. Once claimed, the SSD stays with the Coyote driver until the driver is unloaded (or the shell is reconfigured). After that, it can be handed back with `echo <BDF> | sudo tee /sys/bus/pci/drivers/nvme/bind`.
- **Use a scratch SSD**: the write benchmark overwrites the LBA range reserved by `initNVMe()`. Ranges are allocated first-fit from LBA 0 of the namespace, so the run destroys any partition table or file system on the SSD.
- **Hugepages**: as in the other examples, the buffer is allocated with hugepages (`CoyoteAllocType::HPF`).
- **No simulation**: NVMe is not simulated. In a simulation build (`-DEN_SIM=ON`), `initNVMe()`, `closeNVMe()` and `isNVMeRegistered()` throw a "not supported in simulation" error.

## Hardware concepts
### NVMe submission interface (`m_nvme_sq`)
NVMe requests have their own type, `nvme_req_t`, and their own interface, `m_nvme_sq`, which only exists in shells built with `EN_NVME = 1`. They do not use `req_t` (`sq_rd`/`sq_wr`), and there is no NVMe stream type. The fields of `nvme_req_t` are:
- `dev_id`   : NVMe device ID returned by `initNVMe()` (`0..NVME_NUM_DEVICES-1`)
- `nsid`     : namespace identifier (typically `1` for a single-namespace SSD; 4 bits wide)
- `naddr`    : byte offset within this region's LBA range (must be a multiple of `lba_size`)
- `writeRead`: `1` for WRITE (buffer to SSD), `0` for READ (SSD to buffer)
- `vaddr`    : buffer virtual address, translated by the region's MMU (any dword-aligned address; the PRPs follow the 4 KB pages it touches)
- `len`      : transfer length in bytes (a non-zero multiple of `lba_size`)
- `pid`      : Coyote thread ID whose mappings are used to translate `vaddr`
- `vfid`     : set by the shell; ignored on input

The bench engine fills `pid` from the `PID_REG` CSR, which the software sets to `coyote_thread.getCtid()`, the ID of the thread that allocated the buffer. Each request maps to exactly one NVMe command; the shell does not split requests, and a PRP list holds 32 entries, so a request covers at most 33 pages (132 KB if page-aligned). The software therefore clamps the chunk size to 128 KB and to the SSD's MDTS.

### NVMe response and completion interfaces (`s_nvme_cq_rsp` and `s_nvme_cpl`)
Completions arrive as `nvme_cqe_t` (`dev_id[3:0]`, `cid[7:0]`, `status[14:0]`, `phase`), where `status` is the NVMe status field of the completion entry (0 on success). The bench engine demuxes them by `dev_id` to update per-device counters. Completions can arrive out of submission order.

The 16-bit `s_nvme_cq_rsp` channel returns one response per accepted request, in submission order within the region:

| Device | Assigned CID (success only) | Local error |
| --- | --- | --- |
| `[15:12]` | `[11:4]` | `[3:0]` |

The layout is the same at every queue depth. The CID field is 8 bits wide, as in `nvme_cqe_t`; at depth 64 or 128 its upper bits are zero (`NVME_RSP_ERROR_BITS` = 4, `NVME_RSP_CID_BITS` = 8). The local errors are:
- `0`: success; the command was submitted and its completion will follow on `s_nvme_cpl`.
- `1`: unknown device or namespace (`dev_id` not below `NVME_NUM_DEVICES`, or no device registered under `dev_id`/`nsid`).
- `3`: PRP preparation failure: a buffer page cannot be mapped (the page fault for it failed), a page is in card memory but the shell does not expose card memory to the SSD (e.g., `--fpga-mem` on the V80 with `HOST`), or the request needs more than 32 PRP-list entries.
- `6`: permission/range failure: the region holds no range on the device (no `initNVMe()`, or after `closeNVMe()`), `len` is zero, or `naddr + len` exceeds the reserved range.

A request with a local error is not submitted, and no completion follows for it.

`-DNVME_QUEUE_DEPTH` sets the entries per I/O queue: 64, 128 or 256, for both HOST and PL. Admin queues have 64 entries. The driver reads the depth from the shell NVMe configuration CSR bits `[16:8]`, uses it for HOST queue creation and returns it to software in `nvmeInitIoctl::queue_depth`; it must not exceed the SSD's maximum queue size (`CAP.MQES`). At most `NVME_QUEUE_DEPTH - 1` commands are queued per device.

Set `-DNVME_NUM_DEVICES=N` to instantiate control state for `N` device slots, numbered `0..N-1`. The default is 1; HOST supports every integer from 1 through 16. A HOST build using multiple SSDs must reserve enough slots. PL currently supports only one physical SSD/queue pair, so CMake requires `NVME_NUM_DEVICES=1` when `EN_NVME=1` and `NVME_TYPE=PL`. Device IDs are four bits wide in requests, completions and the 16-bit assignment response. Requests to an inactive device slot return local error 1. Shell CSR bits `[24:20]` advertise the actual count, and the driver rejects claims beyond this capacity (`ENOSPC`).

Successful assignments do not count as completions. The benchmark ignores them and captures only a nonzero local error into the zero-extended `ERROR_REG`; note that a successful response can have a nonzero packed value, so only bits `[3:0]` are checked. Since a rejected request never completes, the benchmark counts it as finished when its error response arrives, so a run with local errors still ends; the software then prints `FAILED` with the error code instead of a bandwidth. The next run needs no reset.

An application can pair ordered responses with pending requests to learn their `(device, CID)` assignments. Response and completion delivery are independent under backpressure, and a CID can be reused while the completion of its previous use is still queued. The application must therefore handle a completion received before its assignment, and preserve the order of successive uses of the same `(device, CID)`. The count-based benchmark does not need such a mapping. Both channels must be drained: the bench engine keeps `s_nvme_cq_rsp` and `s_nvme_cpl` always ready.

### Per-device FSM + round-robin arbiter
The vFPGA instantiates `BENCH_MAX_DEVS` (default 4) independent FSMs. Each FSM owns its own inflight counter, send pointer and timer, and produces a single `dev_req` to a round-robin arbiter that feeds the shell on `m_nvme_sq`. This keeps the worst-case bandwidth bounded by the shell's single-NVMe-pipeline arbitration rather than by per-device serial issue. FSM `d` issues requests with `dev_id = d`, so the example supports devices with IDs 0 to 3.

## Software concepts
### `coyote::cThread::initNVMe(bdf, nsid, size)`
Claims an NVMe SSD identified by its PCI BDF for this vFPGA region and reserves `size` bytes of its namespace (rounded down to whole LBAs; less than one LBA reserves the whole namespace). The returned `nvmeInitIoctl` exposes the FPGA `dev_id`, the namespace's `lba_size`, total `nsze`, the reserved LBA range (`lba_offset`/`lba_count`) and the device's `mdts` (which the SW uses to clamp the chunk size). The SQ/CQ doorbell addresses are returned for informational purposes.

Requires root (`CAP_SYS_ADMIN`). Device IDs are assigned in claim order and stay the same until the driver is unloaded (or the shell is reconfigured). A second vFPGA claiming the same SSD gets the same `dev_id` and a disjoint range. Each region can hold one range per device: calling `initNVMe()` again for the same device without `closeNVMe()` fails with `EBUSY`. For a PL-attached SSD, `bdf` is ignored and `nsid` must be 1. On failure, the method throws a `std::runtime_error` that includes the cause (e.g., `EPERM`, `EBUSY`, `ENOSPC`).

### `coyote::cThread::closeNVMe(dev_id)`
Releases the LBA range reserved by `initNVMe()` for this region: the driver revokes the region's permission in hardware, so further requests from the region to this device fail with local error 6, and frees the range for later `initNVMe()` calls. The driver does the same for all remaining ranges when the last handle to the vFPGA is closed (e.g., when the process exits). Closing does not tear down the controller, even when no region holds a range on it any more: the SSD stays claimed, with its I/O queues in place, until the Coyote driver is unloaded (or the shell is reconfigured). Requires root (`CAP_SYS_ADMIN`).

### `coyote::cThread::isNVMeRegistered(bdf, nsid)`
Non-throwing query used to discover whether a given `(BDF, NSID)` pair is registered for this region. It only reports this region's allocations: a device claimed by another region is reported as not registered. The returned `nvmeInitIoctl` has `result == 0` and this region's `lba_offset`/`lba_count` when registered, and `result == -ENOENT` otherwise. It throws only if the ioctl itself fails (e.g., NVMe is not enabled in the loaded shell), and does not require root. Useful for idempotent setup paths.

## Additional information
### Command line parameters
- `[--bdf | -b] <BDF>` PCI BDF of the NVMe SSD to claim. Repeat the flag for multi-device tests (the shell must be built with enough device slots, `-DNVME_NUM_DEVICES`). Required for `HOST`; for a PL-attached SSD it is ignored and can be omitted.
- `[--total | -t] <size>` Total transfer per device (suffixes: `K`, `M`, `G`). The buffer is allocated with a 32-bit size, so it must not exceed `UINT32_MAX` bytes (4 GB - 1); `4G` or more is rejected. Default: `64M`.
- `[--chunk | -c] <size>` Size of each NVMe command; clamped to 128 KB and to the SSD's MDTS, and must be a multiple of the LBA size. Default: `4K`.
- `[--alloc | -a] <size>` Per-device LBA allocation request (default: `total`).
- `[--outstanding | -o] <n>` Maximum in-flight commands per device, from 1 to `NVME_QUEUE_DEPTH - 1` (63 at the default depth). Default: `16`.
- `[--vfpga | -v] <id>` vFPGA ID to run on. Default: `0`.
- `[--read-only | -r]` Run only the READ phase.
- `[--write-only | -w]` Run only the WRITE phase.
- `[--fpga-mem | -f]` Place the buffer in FPGA HBM, so that the SSD transfers data directly to/from HBM. Requires a shell that exposes card memory to the SSD (U55C/U280 with the rebuilt static layer, or the V80 with `PL`).
- `[--verify | -V]` Data integrity check: write a pattern to the SSD, clear the buffer, read it back and compare.

### Example invocations
Single SSD, 4 KB chunks:
```
sudo bin/test -b 0000:01:00.0
```

Two SSDs in parallel, 128 KB chunks, 1 GB total per device (shell built with `-DNVME_NUM_DEVICES=2` or more):
```
sudo bin/test -b 0000:01:00.0 -b 0000:02:00.0 -c 128K -t 1G
```

Write-only sweep on one SSD with 32 in-flight commands:
```
sudo bin/test -b 0000:01:00.0 -o 32 -w
```

Buffer in HBM, with a data integrity check:
```
sudo bin/test -b 0000:01:00.0 -c 128K -f -V
```

## Results
The benchmark reports the aggregated bandwidth as `N_REPS * chunk * devices / (TIMER_REG cycles * 4 ns)`, i.e., assuming a 250 MHz shell clock, in binary units (1 GB = 2^30 bytes).

Measured with `-t 1G` per run (V80 rows are pending).

| Board | Vivado version | SSD model | Number of SSDs | `NVME_TYPE` / buffer | Chunk size | Queue depth (`NVME_QUEUE_DEPTH`) | Outstanding (`-o`) | Read bandwidth | Write bandwidth |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| U55C | 2024.2 | FADU Delta U.2 1.92TB | 1 | `HOST` / host memory | 4K | 64 | 16 | 2.19 GB/s | 2.76 GB/s |
| U55C | 2024.2 | FADU Delta U.2 1.92TB | 1 | `HOST` / host memory | 16K | 64 | 16 | 2.47 GB/s | 2.84 GB/s |
| U55C | 2024.2 | FADU Delta U.2 1.92TB | 1 | `HOST` / host memory | 64K | 64 | 16 | 2.60 GB/s | 2.93 GB/s |
| U55C | 2024.2 | FADU Delta U.2 1.92TB | 1 | `HOST` / host memory | 128K | 64 | 16 | 2.66 GB/s | 2.97 GB/s |
| U55C | 2024.2 | FADU Delta U.2 1.92TB | 1 | `HOST` / host memory | 4K | 64 | 64 | 2.32 GB/s | 2.75 GB/s |
| U55C | 2024.2 | FADU Delta U.2 1.92TB | 1 | `HOST` / host memory | 16K | 64 | 64 | 2.66 GB/s | 2.94 GB/s |
| U55C | 2024.2 | FADU Delta U.2 1.92TB | 1 | `HOST` / host memory | 64K | 64 | 64 | 2.64 GB/s | 2.91 GB/s |
| U55C | 2024.2 | FADU Delta U.2 1.92TB | 1 | `HOST` / host memory | 128K | 64 | 64 | 2.66 GB/s | 2.95 GB/s |
| V80 | TBD | TBD | TBD | `PL` / host memory | TBD | TBD | TBD | TBD | TBD |
