Dynamic layer
====================

Architecture
-----------------------------------

Shared virtual memory
-----------------------------------

Network Services - TCP/IP
-----------------------------------

Network Services - RDMA RoCEv2
-----------------------------------

Coyote comes with a RDMA-stack that is fully compatible to the RoCEv2 networking standard and therefore allows communication with commodity NICs (i.e. tested with Mellanox ConnectX-5 cards.). 
It is proven to run at 100 Gbit / s in a switched network, allowing for low latency and high throughput comparable to ASIC-based NICs such as the aforementioned. 

The architecture of this networking stack is defined in a block diagram as follows: 

.. figure:: img/RDMA_Block_Diagram.png

The packet processing pipeline is coded in Vitis-HLS and included in "roce_v2_ip", consisting of separate modules for the IPv4-, UDP- and InfiniBand-Headers. In the top-level-module "roce_stack.sv", this pipeline is then combined with HDL-coded ICRC-calculation and RDMA-flow control.

For actual usage besides pure packet processing, this networking stack is integrated into the Coyote-shell to provide access to memory, host streams and the networking datapath from the CMACs. This system design is depicted as following: 

.. figure:: img/Balboa_Stack_Overview-1.png

The actual RDMA-logic as discussed in this part is the blue `roce_stack`. The integration of this part of the design into the rest of the shell is managed via well-defined interfaces: 

**Network Data Path**
The two ports `s_axis_rx` and `m_axis_tx` are 512-bit AXI4-Stream interfaces and used to transfer network traffic from the shell to the RDMA-stack. With the Ethernet-Header already processed in earlier parts of the networking environment, the RDMA-core expects a leading IP-Header, followed by a UDP- and InfiniBand-Header, payload and a final ICRC-checksum.

**Meta Interfaces for Connection Setup**
RDMA operates on so-called Queue Pairs at remote communication nodes. The initial connection between Queues has to be established out-of-band (i.e. via TCP/IP) by the hosts. To exchanged meta-information then needs to be communicated to the RDMA-stack via the two meta-interfaces `s_axis_qp_interface` and `s_axis_qp_conn_interface`. The interface definition in HLS looks like this:
.. code-block:: c++
    
    typedef enum {RESET, INIT, READY_RECV, READY_SEND, SQ_ERROR, ERROR} qpState;

    struct qpContext {
	    qpState		newState;
	    ap_uint<24> qp_num;
	    ap_uint<24> remote_psn;
	    ap_uint<24> local_psn;
	    ap_uint<16> r_key;
	    ap_uint<48> virtual_address;
    };
    
    struct ifConnReq {
	    ap_uint<16> qpn;
        ap_uint<24> remote_qpn;
        ap_uint<128> remote_ip_address;
        ap_uint<16> remote_udp_port;
    };

    hls::stream<qpContext>&	s_axis_qp_interface,
    hls::stream<ifConnReq>&	s_axis_qp_conn_interface,

**Issuing RDMA commands**
The actual RDMA-operations are handled between the shell and the RDMA-core through the interfaces `s_rdma_sq` for initiated RDMA-operations and `m_rdma_ack` to signal automatically generated ACKs from the stack to the shell.

Definition of s_rdma_sq:
* 20 Bit `rsrvd`
* 64 Bit `message_size`
* 64 Bit `local vaddr`
* 64 Bit `remote vaddr`
* 4 Bit `offs`
* 24 Bit `ssn`
* 4 Bit `cmplt`
* 4 Bit `last`
* 4 Bit `mode`
* 4 Bit `host`
* 12 Bit `qpn`
* 8 Bit `opcode` (i.e. RDMA_WRITE, RDMA_READ, RDMA_SEND etc.)

Definition of m_rdma_ack:
* 24 Bit `ssn`
* 4 Bit `vfid`
* 8 Bit `pid`
* 4 Bit `cmplt`
* 4 Bit `rd`

**Memory Interface**
The RDMA stack communicates with the QDMA-core for access to the host memory. Therefore, the memory-control interfaces `m_rdma_rd_req` and `m_rdma_wr_req` are designed to hold all information required for communication with this core. The two data interfaces for transportation of memory content `m_axis_rdma_wr` and `s_axis_rdma_rd` are 512-Bit AXI4-Stream interfaces. 

Definition of `m_rdma_rd_req` / `m_rdma_wr_req`: 
* 4 Bit `vfid`
* 48 Bit `vaddr`
* 4 Bit `sync`
* 4 Bit `stream`
* 8 Bit `pid`
* 28 Bit `len`
* 4 Bit `host`
* 12 Bit `dest`
* 4 Bit `ctl`

**Examples of RDMA WRITE-Flow**
The following flow chart shows an exemplaric RDMA WRITE-exchange between a remote node with an ASIC-based NIC and a local node with a FPGA-NIC implementing the RDMA-stack. It depicts the FPGA-internal communication between RDMA-stack and shell as well as the network data-exchange between the two nodes: 

.. figure:: img/RDMA_Flow_Mem-1.png

.. _nvme-storage:

Storage Services - NVMe
-----------------------------------

Coyote can attach NVMe SSDs to the shell, so that vFPGAs read and write SSD blocks directly, without the CPU on the data path.
The shell keeps the NVMe I/O submission queues (SQ), completion queues (CQ) and PRP lists in on-chip BRAM.
A vFPGA hands the shell a request (device, namespace, byte offset, buffer virtual address, length); the shell checks the region's permission, translates the buffer through the region's MMU, builds the NVMe command, rings the SSD doorbell and routes the completion back to the region.
The SSD moves the data directly to or from the buffer, which can be in host memory or, if the shell exposes card memory to the SSD, in HBM/DDR (SSD-FPGA peer-to-peer).
The driver claims the SSD and grants each vFPGA its own range of logical blocks (LBAs), which the hardware enforces on every request.

Configuration
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

NVMe is configured with the following CMake options:

==================== ========= ===================================================================================
Option               Default   Description
==================== ========= ===================================================================================
``EN_NVME``          0         Enable the NVMe stack in the shell and the NVMe interfaces in every vFPGA.
``NVME_TYPE``        HOST      Connection type, ``HOST`` or ``PL`` (see below).
``NVME_QUEUE_DEPTH`` 64        Entries per I/O queue: 64, 128 or 256, for both connection types. Admin queues always have 64 entries.
``NVME_NUM_DEVICES`` 1         Number of SSD slots instantiated in the shell: 1 to 16 for ``HOST``, 1 for ``PL``.
==================== ========= ===================================================================================

``validation_checks_hw()`` derives three further flags, which should not be set by hand: ``EN_NVME_HOST``, ``EN_NVME_PL`` and ``EN_NVME_CARD``.
``EN_NVME_CARD`` is set when the SSD can reach card memory: ``NVME_TYPE=HOST`` on the U55C or U280 with ``EN_MEM=1``, or ``NVME_TYPE=PL`` with ``EN_MEM=1``.
In that case one additional memory channel is reserved for the SSD's port into card memory.
All NVMe options are written to the shell's ``export.cmake``, so applications built with ``BUILD_APP=1`` inherit them from the shell.
At load time, the driver reads the enable bit, the connection type, the queue depth and the number of device slots from the shell configuration register.

A typical configuration for a host-attached SSD on the U55C:

.. code-block:: cmake

    set(FDEV_NAME "u55c")
    set(EN_STRM 1)              # Host memory buffers
    set(EN_MEM 1)               # Card memory (HBM) buffers; requires a static layer rebuild, see below
    set(EN_NVME 1)
    set(NVME_TYPE "HOST")
    set(NVME_QUEUE_DEPTH 128)
    set(NVME_NUM_DEVICES 2)     # Two SSDs

Connection types and static-layer requirements
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

========================== ================ ======================= =====================================================
Connection                 Platforms        Buffer locations        Static layer
========================== ================ ======================= =====================================================
HOST, host memory only     U55C, U280, V80  Host memory             Shipped checkpoint (``BUILD_SHELL=1``)
HOST with ``EN_NVME_CARD`` U55C, U280       Host and card memory    Rebuilt (``BUILD_STATIC=1``, ``BUILD_SHELL=0``)
PL                         V80              Host and card memory    Rebuilt (``BUILD_STATIC=1``, ``BUILD_SHELL=0``)
========================== ================ ======================= =====================================================

**Host-attached SSDs (NVME_TYPE=HOST)**
The SSD sits in a PCIe slot of the host and must not be bound to any kernel driver (see the driver section below).
The Coyote driver initializes the controller and creates one I/O queue pair per SSD whose SQ and CQ live in FPGA BRAM, behind the FPGA's bypass BAR.
The SSD fetches commands and PRP lists from, and writes completions to, the FPGA with PCIe peer-to-peer transactions; the FPGA rings the SSD doorbells with peer-to-peer writes issued through the host DMA engine.
The host therefore has to allow peer-to-peer traffic between the SSD and the FPGA. With an IOMMU, the driver maps the FPGA BAR into the SSD's DMA domain and the SSD BAR into the FPGA's.
CMake accepts ``HOST`` on all UltraScale+ devices and on the V80. On devices other than the U55C and U280, card memory is not exposed to the SSD, and CMake prints a warning when ``EN_MEM`` is set.

The shipped U55C/U280 static layer has a 256 MB bypass BAR, which only covers the shell's control windows (including the NVMe SQ, CQ and PRP windows).
To let the SSD reach card memory, a shell with ``EN_NVME_CARD`` maps card memory at offsets 256 MB to 16 GB of a 16 GB bypass BAR.
The BAR size is a property of the static layer, so this requires rebuilding it with ``-DBUILD_STATIC=1 -DBUILD_SHELL=0`` (the BAR is only enlarged in builds with ``EN_NVME_CARD``).
A shell built against the shipped checkpoint keeps the 256 MB BAR: host-memory buffers work, and card-memory buffers are rejected. The driver only sets the ``CARD_WINDOW`` register of the NVMe configuration block when the bypass BAR covers the card window, and without it every card-memory page fails the request with error 3.
As with any static build, shells can only be swapped at run-time if they were linked against the same static layer.

On the V80, the shipped static layer exposes a 256 MB BAR (BAR4) without card memory, so host-attached SSDs work with the shipped checkpoint, for host-memory buffers only.
Requests whose buffer is in card memory fail with a PRP error (see below).

**PL-attached SSDs (NVME_TYPE=PL)**
On the V80, the SSD can be connected to an MCIO port, with the FPGA acting as the PCIe root complex (Gen5 x4 root port).
A setup engine in the shell enumerates the SSD, creates the admin and I/O queues and identifies namespace 1; the driver waits for it to finish and reads the discovered namespace parameters from the shell.
The SSD reaches host memory through the shell's host DMA path and, with ``EN_MEM=1``, card memory.
The shipped V80 static checkpoint does not expose the MCIO ports, so CMake rejects ``BUILD_SHELL=1``; build with ``-DBUILD_STATIC=1 -DBUILD_SHELL=0``. ``BUILD_APP=1`` against such a shell remains possible.
Currently, PL supports one SSD and one I/O queue pair, so ``NVME_NUM_DEVICES`` must be 1.

vFPGA interface
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

With ``EN_NVME=1``, every vFPGA has three additional interfaces:

=================== ==================== ============== ================================================================
Interface           Type                 Direction      Description
=================== ==================== ============== ================================================================
``m_nvme_sq``       ``nvme_req_t``       vFPGA -> shell NVMe read/write request.
``s_nvme_cq_rsp``   ``logic [15:0]``     shell -> vFPGA One response per accepted request, in submission order.
``s_nvme_cpl``      ``nvme_cqe_t``       shell -> vFPGA NVMe completion of a submitted command.
=================== ==================== ============== ================================================================

All three are ``metaIntf`` (valid/ready) interfaces; they should be tied off if unused (the commented-out tie-offs are in the generated ``user_logic``).
NVMe requests use their own type on a dedicated interface: the shared ``req_t`` used by ``sq_rd`` / ``sq_wr`` and ``STRM_BITS`` are unchanged by the NVMe stack, and there is no NVMe stream type.
The NVMe types are defined in ``lynxTypes`` only when ``EN_NVME=1``.

``nvme_req_t`` is a 256-bit packed struct with the following fields, listed from the most-significant bit (default widths):

============= ======= =========================================================================================================
Field         Bits    Description
============= ======= =========================================================================================================
``dev_id``    4       Device ID returned by ``cThread::initNVMe()``.
``nsid``      4       Namespace ID, as passed to ``initNVMe()``.
``naddr``     48      Byte offset within the region's LBA allocation (not an absolute LBA); must be a multiple of the LBA size.
``writeRead`` 1       1: write the buffer to the SSD, 0: read from the SSD into the buffer.
``vaddr``     48      Virtual address of the buffer in host or card memory (dword aligned); PRPs follow the 4 KB pages it touches.
``len``       28      Transfer size in bytes; a non-zero multiple of the LBA size (see limitations for the maximum).
``pid``       6       Coyote thread ID (``cThread::getCtid()``) whose mappings are used to translate ``vaddr``.
``vfid``      4       Set by the shell; ignored on input.
``rsrvd``     113     Padding to 256 bits.
============= ======= =========================================================================================================

Assigning ``'0`` to the whole struct before setting the fields keeps the reserved bits defined.
The response on ``s_nvme_cq_rsp`` is a 16-bit word ``{device[15:12], CID[11:4], error[3:0]}``, with the same layout at every queue depth (``NVME_RSP_CID_BITS = 8``, ``NVME_RSP_ERROR_BITS = 4``).
The device field echoes the request's ``dev_id``; the CID is only valid when the error is 0, and is zero-extended at depths 64 and 128.
A successful response therefore has a non-zero value: only bits ``[3:0]`` indicate an error.

=========== =============================================================================================================================
Error code  Meaning
=========== =============================================================================================================================
0           Success: the command is stored in the SQ and its doorbell follows. A completion will arrive on ``s_nvme_cpl``.
1           No device: ``dev_id`` is not below ``NVME_NUM_DEVICES``, or no device is registered under (``dev_id``, ``nsid``).
3           PRP preparation failed: a page of the buffer could not be mapped (its page fault failed), a page is in card memory but the shell has no card window (``EN_NVME_CARD=0``), a host address is outside the 8 TiB host window (PL only), or the transfer needs more PRP-list entries than available.
6           Permission or range error: the region holds no permission for the device (no ``initNVMe()``, or after ``closeNVMe()``), ``len`` is zero, or ``naddr + len`` exceeds the region's allocation.
=========== =============================================================================================================================

For a non-zero error nothing is submitted and no completion follows. Code 2 (``NVME_NO_REMAINING_SQ_ENTRIES``) is defined in ``nvme_error_t``, but not produced: a full SQ backpressures ``m_nvme_sq`` instead.

``nvme_cqe_t`` is 32 bits wide:

============= ======= ==============================================================================================
Field         Bits    Description
============= ======= ==============================================================================================
``rsrvd``     4       Padding.
``dev_id``    4       Device that completed the command.
``cid``       8       Command ID, as reported in the assignment response; zero-extended at depths 64 and 128.
``status``    15      NVMe status field of the completion entry (DW3[31:17]); 0 means success.
``phase``     1       Phase tag of the completion entry.
============= ======= ==============================================================================================

A non-zero ``status`` is reported by the SSD, for example for a transfer above its maximum data transfer size (MDTS), which the shell does not check.

**Request, response and completion flow**

#. The vFPGA asserts ``m_nvme_sq.valid`` with an ``nvme_req_t``. Requests enter a 32-entry queue in front of the pipeline. ``m_nvme_sq`` is backpressured when that queue is full, which happens while the pipeline waits for a free SQ slot (at most ``NVME_QUEUE_DEPTH - 1`` unconsumed entries per device) or a free command ID. It is also backpressured directly when the region has used up its credits (multi-region shells only, see below) or, for PL, while the setup engine has not finished.
#. The shell checks the device, namespace and permission, allocates a command ID (CID), translates ``vaddr`` through the region's MMU and builds PRP1/PRP2 or a PRP list. It then stores the SQE in the SQ BRAM.
#. The shell enqueues the response on ``s_nvme_cq_rsp`` and then rings the SQ doorbell. Within a region, responses arrive in submission order, including errors.
#. The SSD fetches the SQE (and PRP list) from the FPGA, transfers the data and writes the completion entry into the CQ BRAM.
#. The shell polls the CQ, finds the owning region by (device, CID) and delivers the completion on ``s_nvme_cpl``. Completions can arrive in any order.

Applications that track individual commands can pair the ordered responses with their pending requests to learn each request's (device, CID), and then match completions on (device, CID).
Responses and completions are delivered independently, so a completion can arrive before its response.
A CID is freed as soon as its completion enters the region's completion queue, so it can be reused while that completion still waits to be consumed; within a region, the responses and completions of successive uses of a (device, CID) arrive in the order of those uses.
Count-based applications (such as *Example 14: NVMe SSD Bandwidth Test*) do not need this mapping.
Both ``s_nvme_cq_rsp`` and ``s_nvme_cpl`` must be drained: a full response queue stalls the submission pipeline, and a full completion queue stalls completion processing for all regions.

In shells with multiple vFPGAs, each (region, device) pair may have at most ``NVME_N_OUTSTANDING = 8`` commands in flight; a credit is returned when the vFPGA accepts the command's completion or its error response.
Regions are arbitrated into the single submission pipeline by a credit arbiter that equalizes the number of granted bytes across regions. With one vFPGA, the number of commands in flight is bounded by the queue depth.

Shell internals
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The NVMe stack (``hw/hdl/nvme``, top level ``nvme_top.sv``) is a single pipeline shared by all regions and devices:
``nvme_req_parser`` latches the arbitrated request and queries ``nvme_info_table``, which holds the per-(device, namespace) information, the per-(region, device) permission entries (byte offset and size), the SQ pointers and the per-device CID pool.
``nvme_prp_dispatch`` turns the byte offset into the starting LBA (``(lba_offset + naddr) >> log2(LBA size)``) and the block count, and ``nvme_prp_builder`` translates the buffer.
Translations go to a dedicated NVMe port of the region's read TLB (``s_nvme_req`` in ``tlb_fsm.sv``), which is arbitrated round-robin with regular requests, returns one physical address per 4 KB segment and tags each page as host or card memory.
A translation that misses in the TLB raises a regular page fault; the driver maps the pages wherever they currently are (host or card memory) and never migrates them, since the SSD may still be transferring other pages of the same buffer.
PRP lists are stored in ``nvme_prp_ctrl`` (one 4 KB page per CID, of which 32 entries are stored, and a fixed 1 MB stride per device), and ``nvme_sqe_builder`` emits the SQE, the response and the doorbell request.
``nvme_sq_ctrl`` and ``nvme_cq_ctrl`` keep the queues in BRAM and serve them to the SSD over AXI; ``nvme_cq_ctrl`` polls the CQs using the phase tag.
``nvme_cq_head_tracker`` batches CQ head doorbells (HOST: 4 entries or an 80-cycle timeout; PL: 16 entries at depth 64, 32 otherwise, or a 1,000-cycle timeout), and ``nvme_doorbell_arb`` merges SQ and CQ doorbells into host DMA writes (HOST) or AXI writes to the root port (PL).
CIDs are owned independently of SQ slots: SQ space is released by the SQ head reported in completions, while a CID is returned to its device's free list only by a matching completion (or by a command that failed during PRP preparation).
After reset or queue re-creation, the CID pool takes ``NVME_QUEUE_DEPTH`` clock cycles to initialize, during which submissions wait.
The driver programs device information and permissions through the ``nvme_cnfg_slave`` register bank (shell BAR + ``0x4000``); revoking a permission clears its valid bit, so further requests of that region fail with error 6.

Driver and software API
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The software API consists of three ``cThread`` methods, each wrapping one ioctl (see :ref:`nvme-ioctls` for the ioctl-level details):

* ``nvmeInitIoctl initNVMe(const std::string& bdf, uint32_t nsid, uint64_t size)``: claims the SSD for the calling vFPGA and reserves ``size`` bytes of the namespace (rounded down to whole LBAs; a size below one LBA reserves the whole namespace).
  The returned ``nvmeInitIoctl`` contains the ``dev_id`` to use in ``nvme_req_t``, the LBA size, the namespace size (``nsze``, in LBAs), the reserved range (``lba_offset``, ``lba_count``, in LBAs), the SSD's MDTS in bytes and, for information, the doorbell addresses.
  For PL, ``bdf`` is ignored and ``nsid`` must be the namespace identified by the setup engine (1).
  Throws ``std::runtime_error`` with the cause (e.g., ``EPERM``, ``EBUSY``, ``ENOSPC``) if the ioctl fails.

* ``void closeNVMe(uint32_t dev_id)``: revokes the region's permission in hardware and frees its LBA range.

* ``nvmeInitIoctl isNVMeRegistered(const std::string& bdf, uint32_t nsid)``: queries whether (``bdf``, ``nsid``) is registered to the calling vFPGA. It returns ``result == 0`` with the region's range, or ``result == -ENOENT``, and throws only if the ioctl itself fails (e.g., NVMe is not enabled in the loaded shell). For PL, ``bdf`` is ignored and only ``nsid`` is matched.

``initNVMe()`` and ``closeNVMe()`` require root (``CAP_SYS_ADMIN``), since claiming an SSD resets its controller and grants access to its blocks.
For a host-attached SSD, the first ``initNVMe()`` on a (BDF, namespace) pair checks that the device is an NVMe controller not bound to any driver, claims its BARs, enables the controller, identifies the namespace and creates the I/O queue pair in FPGA BRAM (the queue depth must not exceed the SSD's maximum, ``CAP.MQES``).
Device IDs are assigned in claim order, up to ``NVME_NUM_DEVICES``.
Further vFPGAs claiming the same SSD reuse its ``dev_id`` and receive a disjoint range (first fit).
Each vFPGA holds at most one range per device: calling ``initNVMe()`` again without ``closeNVMe()`` fails with ``EBUSY``.
``closeNVMe()`` and the release of the last handle to a vFPGA (e.g., when the process exits) revoke the region's permissions and make its ranges available again.
The controller and its queues, however, stay claimed until the driver is unloaded or the shell is reconfigured; only then can the SSD be given back to the kernel ``nvme`` driver.
To unbind an SSD from the kernel driver before claiming it:

.. code-block:: bash

    # Find the SSD and the driver it is bound to
    lspci -D | grep -i "non-volatile"
    readlink /sys/bus/pci/devices/<BDF>/driver

    # Unbind it (never unbind a disk that holds a mounted file system)
    echo <BDF> | sudo tee /sys/bus/pci/drivers/nvme/unbind

    # After unloading the Coyote driver, the SSD can be handed back to the kernel
    echo <BDF> | sudo tee /sys/bus/pci/drivers/nvme/bind

Limitations
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

* Each request is issued as exactly one NVMe Read or Write command; the shell does not split requests. A PRP list holds 32 entries, so a request covers at most 33 pages (132 KB if page-aligned). Larger requests fail with error 3. Requests must also respect the SSD's MDTS, which is not checked in hardware.
* ``vaddr`` must be dword aligned, and ``naddr`` and ``len`` must be multiples of the LBA size. Apart from zero lengths, this is not checked.
* Each SSD has one I/O queue pair, shared by all vFPGAs. Only the NVM Read and Write commands are available to vFPGAs; there is no flush, deallocate or admin command interface.
* All devices and regions share one submission pipeline: a request that waits for a free SQ slot or CID on one device also delays the requests behind it, including those to other devices and from other regions.
* The ``nsid`` field of ``nvme_req_t`` is 4 bits wide.
* PL-attached SSDs: one SSD per FPGA, I/O queue 1 and a doorbell stride of 4 bytes are assumed, and the static layer must be rebuilt.
* Host-attached SSDs: card-memory buffers require the rebuilt U55C/U280 static layer and are not available on the V80.
* NVMe is not supported in the simulation environment; the simulation ``cThread`` NVMe methods throw.