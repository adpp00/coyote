# Coyote Example 16: NVMe -> TCP Pipelined Read
Welcome to the sixteenth Coyote example! In this example we stream data from an NVMe SSD out over a TCP socket, fully on the FPGA: the vFPGA listens on a TCP port, parses an incoming request for `(naddr_base, total_read_len)`, schedules a pipelined burst of NVMe reads into an HBM ring buffer, and concurrently DMA-reads completed ring slots back into the TCP TX stream. This is the first SCENIC example that uses the new raw TCP socket API exposed to user logic. As with all Coyote examples, a brief description of the core Coyote concepts covered is included below; how to synthesize hardware, compile the examples and load the bitstream/driver is explained in the top-level example README at `Coyote/examples/README.md`.

## Table of contents
[Example Overview](#example-overview)

[Hardware Concepts](#hardware-concepts)

[Software Concepts](#software-concepts)

[Additional Information](#additional-information)

## Example overview
The vFPGA contains four independent processes that cooperate via an HBM-backed ring buffer:

1. **P1 — Auto RX FSM** consumes `tcp_notify`, issues `tcp_rd_pkg` for any pending payload and waits for `tcp_rx_meta`. It tracks the active TCP session id.
2. **P2 — NVMe Issuer** waits for a one-beat request packet on `axis_tcp_recv` (`{total_read_len, naddr_base}`), pulses an ACK request, then issues `total_read_len / chunk_size` NVMe reads into HBM, advancing `nv_ip` (the issue pointer) on every accepted command. Up to `MAX_OUTSTANDING` commands stay in flight.
3. **P3 — NVMe CPL** advances the write pointer `wp` on every completion and emits a `LOCAL_READ` DMA descriptor on `sq_rd` that pulls the completed slot from HBM back into `axis_card_recv[0]`.
4. **P4 — TX FSM** first emits the ACK (`tcp_tx_meta` + 1-beat data), then for each ready slot streams `dma_per_slot` DMA blocks from `axis_card_recv[0]` into `axis_tcp_send`, advancing the read pointer `rp` slot-by-slot.

A `START` write to `CTRL` latches the SW-configured parameters (HBM base, chunk size, slot count, DMA block size, namespace, max outstanding) and kicks off a single TCP listen on `LISTEN_PORT`. Each subsequent client request is auto-handled — the FSMs reset their counters when both P2 (`NV_DONE`) and P4 (`TX_DONE`) reach the end of a transfer.

A high-level walk-through of a single client transfer:

1. The host claims the requested NVMe SSD via `coyote::cThread::initNVMe()`, allocates a huge-page-backed HBM ring buffer and programs the pipeline CSRs (ring base/size, chunk and DMA block sizes, namespace, max outstanding).
2. The host writes `START` to `CTRL`; the vFPGA latches the parameters, asserts `tcp_listen_req` and polls the `STATUS` register for `listen_ok`.
3. A TCP client connects to `LISTEN_PORT` and sends one 64 B request packet describing `(naddr_base, total_read_len)`.
4. P2 parses the request, signals P4 to send a one-beat ACK and starts issuing NVMe reads into the HBM ring.
5. Each NVMe completion advances `wp` (P3) and emits a `LOCAL_READ` DMA descriptor that pulls the slot back into the user logic.
6. P4 forwards `dma_per_slot` 64 B beats per DMA block on `axis_tcp_send`, advancing `rp` once a whole slot has been sent.
7. When both `nv_state == NV_DONE` and `tx_state == TX_DONE` the pipeline resets to `NV_META` / `TX_IDLE` and the next client request can be handled without SW intervention.

The HBM ring buffer decouples NVMe read latency from TCP TX latency: as long as `nv_ip` does not catch up with `rp`, the SSD is read at line rate and TCP TX is fed continuously.

## Hardware concepts
### Raw TCP socket API on `user_logic`
This example exercises the new raw TCP socket API added to `design_user_logic`:
- `tcp_listen_req` / `tcp_listen_rsp` — bind a server port and observe the bind result
- `tcp_open_req` / `tcp_open_rsp` — open a client connection (unused here)
- `tcp_close_req` — close an open session (unused here)
- `tcp_notify` — incoming session activity (`sid`, `len`, `closed`)
- `tcp_rd_pkg` — request the TCP stack to pull `len` bytes for session `sid` into `axis_tcp_recv`
- `tcp_rx_meta` — handshake confirming the RX data is on the way
- `tcp_tx_meta` / `tcp_tx_stat` — request a TX packet of `len` bytes and observe the send status

The interface is wired directly to the network-side raw API of `tcp_slice_array_dyn`, bypassing the high-level `tcp_arbiter` (which still drives the existing `tcp_sq`/`tcp_rq` interface for examples that prefer the convenience layer). The raw API ports are added to the templates `hw/templates/common/user_logic_tmplt.txt`, `user_wrapper_tmplt.txt` and `dynamic_top_tmplt.txt`.

### NVMe submission interface (`m_nvme_sq`)
NVMe submission requests are sent as `req_t` values with `strm == STRM_NVME`, `last == 1`. The relevant fields are:
- `dev_id`  : NVMe device index assigned by the driver
- `nsid`    : namespace identifier
- `vaddr`   : HBM slot base address for this command
- `len`     : transfer length (one `chunk_size`)
- `naddr`   : NVMe LBA byte offset within the per-region LBA range
- `writeRead`: `0` for read

### HBM-backed ring buffer
The vFPGA tracks three 32-bit pointers — `nv_ip` (issue), `wp` (write) and `rp` (read) — that index a circular buffer of `N_SLOTS` slots, each `CHUNK_SIZE` bytes. All slot base addresses are accumulated incrementally so the issue path has no variable shifts.

### Auto RX FSM + meta-driven TX FSM
P1 keeps the TCP RX side drained without any SW involvement. P2 reads exactly one 64 B request beat per client request, P4 emits one 64 B ACK packet (`{chunk_size, 0}`) followed by `dma_per_slot` data packets per slot. SW only writes the CSRs and polls the progress counters.

## Software concepts
### `coyote::cThread::initNVMe(bdf, nsid, size)`
Claims an NVMe SSD identified by its PCI BDF for this vFPGA region. The returned `nvmeInitIoctl` exposes the FPGA `dev_id`, the namespace's `lba_size`, total `nsze`, the reserved LBA range and the device's `mdts` (used to clamp the chunk size).

### `coyote::cThread::closeNVMe(dev_id)`
Releases the LBA range reserved by `initNVMe()` for this region.

### `coyote::cThread::isNVMeRegistered(bdf, nsid)`
Non-throwing query used to discover whether a given `(BDF, NSID)` pair is already registered for this region.

### `coyote::cThread::setCSR` / `getCSR`
Program and read the AXI-Lite control registers exported by `nvme_tcp_pipe_read_ctrl`. The register map matches `enum class PipeRegister` in `sw/src/main.cpp`.

## Additional information
### Command line parameters
- `[--bdf | -b] <BDF>` PCI BDF of the NVMe SSD to claim. **Required.**
- `[--port | -p] <port>` TCP listen port. Default: `5002`.
- `[--chunk | -c] <size>` Bytes per ring slot (suffixes: `K`, `M`, `G`). Default: `128K`.
- `[--dma | -d] <size>` DMA read granularity for TCP TX. Default: `4K`.
- `[--ring | -r] <size>` Total HBM ring buffer size. Default: `128M`.
- `[--alloc | -a] <size>` NVMe LBA allocation request. Default: `128M`.
- `[--outstanding | -o] <n>` Max in-flight NVMe commands. Default: `56`.
- `[--vfpga | -v] <id>` vFPGA ID to run on. Default: `0`.

### Example invocations
Stream from a single SSD on the default port:
```
bin/test -b 0000:01:00.0
```

Use a larger ring and 32 KB DMA blocks:
```
bin/test -b 0000:01:00.0 -r 256M -c 256K -d 32K
```

### Request packet format (client -> FPGA)
A single 64-byte AXI-Stream beat:
- `tdata[63:0]`   : `naddr_base` — NVMe LBA byte offset to read from
- `tdata[127:64]` : `total_read_len` — bytes to stream back

The FPGA acknowledges with a 64 B reply (`{chunk_size, 0}`) followed by `total_read_len / chunk_size` slots of pipelined data.
