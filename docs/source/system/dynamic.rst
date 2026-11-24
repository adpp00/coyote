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
A vFPGA hands the shell a request; the shell checks the region's permission, translates the buffer through the region's MMU, builds the NVMe command, rings the SSD doorbell and routes the completion back to the region.
The SSD moves the data directly to or from the buffer, which can be in host memory or, if the shell exposes card memory to the SSD, in HBM.
The driver claims the SSD and grants each vFPGA its own range of logical blocks (LBAs), which the hardware enforces on every request.

**Configuration**
NVMe is enabled with ``EN_NVME = 1``. ``NVME_TYPE`` selects the connection type (``HOST`` or ``PL``), ``NVME_QUEUE_DEPTH`` the entries per I/O queue (64, 128 or 256) and ``NVME_NUM_DEVICES`` the number of SSD slots in the shell (1 to 16 for ``HOST``, 1 for ``PL``).
A typical configuration for two host-attached SSDs on the U55C:

.. code-block:: cmake

    set(FDEV_NAME "u55c")
    set(EN_STRM 1)
    set(EN_MEM 1)
    set(EN_NVME 1)
    set(NVME_TYPE "HOST")
    set(NVME_NUM_DEVICES 2)

**Host-attached SSDs (NVME_TYPE = HOST)**
The SSD sits in a PCIe slot of the host and must not be bound to any kernel driver.
Its I/O queues live in FPGA BRAM, and the SSD and the FPGA exchange commands, completions and data with PCIe peer-to-peer transactions, so the host must allow peer-to-peer traffic, with the IOMMU off or in passthrough mode.
Buffers in card memory are reached through a 128 MB window in the upper half of the 256 MB shell BAR: the PRP builder fills a page table for each command, and the shell translates each 4 KB page of the window to card memory.
On the U55C/U280 this works with the shipped static layers. On the V80, the static layer must be rebuilt with ``-DBUILD_STATIC=1 -DBUILD_SHELL=0`` (BAR4 settings of the CPM).

**PL-attached SSDs (NVME_TYPE = PL)**
On the V80, the SSD can be connected to an MCIO port, with the FPGA acting as the PCIe root complex.
A setup engine in the shell enumerates the SSD and creates its queues.
The shipped V80 static checkpoint does not expose the MCIO ports, so the static layer must be rebuilt (``-DBUILD_STATIC=1 -DBUILD_SHELL=0``). One SSD is supported.

**vFPGA interfaces**
With ``EN_NVME = 1``, every vFPGA has three additional ``metaIntf`` interfaces: ``m_nvme_sq`` for requests (``nvme_req_t``), ``s_nvme_cq_rsp`` for one 16-bit response per accepted request, in submission order, and ``s_nvme_cpl`` for the completions (``nvme_cqe_t``), which can arrive in any order.
NVMe requests do not use ``req_t`` (``sq_rd`` / ``sq_wr``). A request is issued as exactly one NVMe Read or Write command:

.. code-block:: systemverilog

    typedef struct packed {
        logic [N_NVME_BITS-1:0] dev_id; // FPGA device ID returned by cThread::initNVMe
        logic [NSID_BITS-1:0] nsid;     // Namespace ID
        logic [VADDR_BITS-1:0] naddr;   // Byte address within the region's LBA allocation
        logic writeRead;                // 1: write to the SSD, 0: read from the SSD
        logic [VADDR_BITS-1:0] vaddr;   // Virtual address of the host or card buffer
        logic [LEN_BITS-1:0] len;       // Transfer size in bytes (multiple of the LBA size)
        logic [PID_BITS-1:0] pid;       // cThread ctid of the buffer mapping
        logic [DEST_BITS-1:0] vfid;     // Set by the shell; ignored on input
        ...
    } nvme_req_t;

    typedef struct packed {
        logic [3:0]                 rsrvd;
        logic [N_NVME_BITS-1:0]     dev_id;
        logic [NVME_RSP_CID_BITS-1:0] cid;
        logic [14:0]                status; // NVMe status field, 0 on success
        logic                       phase;
    } nvme_cqe_t;

The response on ``s_nvme_cq_rsp`` is ``{device[15:12], CID[11:4], error[3:0]}``. The local errors are 0 (success), 1 (unknown device or namespace), 3 (PRP preparation failure, e.g. a buffer page that cannot be mapped or a request of more than 33 pages) and 6 (no permission, or a byte offset or length outside the region's range or not a multiple of the LBA size).
A request with a local error is not submitted, and no completion follows for it.
A vFPGA must drain both ``s_nvme_cq_rsp`` and ``s_nvme_cpl`` to keep submitting commands.
In shells with multiple vFPGAs, each (region, device) pair may have at most ``NVME_N_OUTSTANDING`` commands in flight, and regions are arbitrated by a credit arbiter that equalizes the granted bytes.

**Software API**
``cThread::initNVMe(bdf, nsid, size)`` claims the SSD for the vFPGA and reserves ``size`` bytes of the namespace; it returns the ``dev_id`` to use in ``nvme_req_t``, the LBA size and the reserved range.
``cThread::closeNVMe(dev_id)`` revokes the region's permission and frees the range, and ``cThread::isNVMeRegistered(bdf, nsid)`` queries whether the SSD is registered to the vFPGA.
``initNVMe()`` and ``closeNVMe()`` require root (``CAP_SYS_ADMIN``). The SSD stays claimed until the driver is unloaded or the shell is reconfigured.
Their use is shown in *Example 14: NVMe SSD Bandwidth Test*.
