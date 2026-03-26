/**
 * NVMe PRP List Controller
 *
 * Dual-port BRAM storing PRP (Physical Region Page) entries:
 *   - Port A (write): from nvme_manage_prp pipeline
 *   - Port B (read):  from AXI BRAM controller (host debug access)
 *
 * REFACTORED:
 *   - Parameter defaults from lynxTypes (NVME_QUEUE_BITS, PRP_ADDR_BITS, N_NVME_BITS)
 *   - Removed hardcoded magic numbers
 */

`timescale 1ns/1ps

import lynxTypes::*;

module nvme_prp_ctrl #(
    parameter integer NVME_QUEUE_BITS = lynxTypes::NVME_QUEUE_BITS,  // Default: 6 (64 entries)
    parameter integer PRP_ADDR_BITS   = lynxTypes::PRP_ADDR_BITS,    // Default: 9 (512 entries, 2MB MTU)
    parameter integer N_NVME_BITS     = lynxTypes::N_NVME_BITS       // Default: 2 (4 devices)
)(
    input  logic        aclk,
    input  logic        aresetn,

    metaIntf.s          s_prp,          // nvme_prp_write_t {addr, data}

    AXI4.s              s_prp_ctrl      // AXI slave for host read access
);

    // ================================================================
    // Derived Parameters
    // ================================================================
    // Internal BRAM address: {dev_id, queue_idx, prp_entry}
    localparam integer unsigned ADDR_BITS = N_NVME_BITS + NVME_QUEUE_BITS + PRP_ADDR_BITS;

    // AXI BRAM Controller (DATA_WIDTH=64) outputs byte addresses
    // Each AXI word = 8 bytes → byte offset bits = log2(8) = 3
    localparam integer unsigned PRP_DATA_BYTES  = 8;                              // 64-bit PRP entry
    localparam integer unsigned BRAM_BYTE_BITS  = $clog2(PRP_DATA_BYTES);         // = 3

    // External: NVMe spec requires PRP list to be 4KB page-aligned
    // Each queue occupies 4KB in BAR space, but only PRP_ADDR_BITS entries used internally
    localparam integer unsigned EXT_PAGE_BITS   = 12;                             // 4KB page
    localparam integer unsigned EXT_ADDR_WIDTH  = N_NVME_BITS + NVME_QUEUE_BITS + EXT_PAGE_BITS;

    // ================================================================
    // Internal Signals
    // ================================================================

    // Write port A (from s_prp pipeline)
    logic                      a_en;
    logic [PRP_DATA_BYTES-1:0] a_we;
    logic [ADDR_BITS-1:0]      a_addr;
    logic [63:0]               a_data_in;

    // Read port B (from AXI BRAM controller)
    logic                      bram_en_a;
    logic [EXT_ADDR_WIDTH-1:0] bram_addr_a;      // Full external byte address from AXI BRAM ctrl
    logic [ADDR_BITS-1:0]      b_addr;           // Entry index into RAM
    logic [63:0]               b_data_out;

    // 64-bit read data back to AXI BRAM Controller
    logic [63:0]               bram_rddata_wire;

    // ================================================================
    // AXI BRAM Controller (DATA_WIDTH=64)
    // ================================================================
    prp_axi_bram_ctrl inst_prp_bram_ctrl (
        .s_axi_aclk       (aclk),
        .s_axi_aresetn    (aresetn),

        .s_axi_awaddr     (s_prp_ctrl.awaddr[EXT_ADDR_WIDTH-1:0]),
        .s_axi_awlen      (s_prp_ctrl.awlen),
        .s_axi_awsize     (s_prp_ctrl.awsize),
        .s_axi_awburst    (s_prp_ctrl.awburst),
        .s_axi_awlock     (s_prp_ctrl.awlock),
        .s_axi_awcache    (s_prp_ctrl.awcache),
        .s_axi_awprot     (s_prp_ctrl.awprot),
        .s_axi_awvalid    (s_prp_ctrl.awvalid),
        .s_axi_awready    (s_prp_ctrl.awready),

        .s_axi_wdata      (s_prp_ctrl.wdata[63:0]),
        .s_axi_wstrb      (s_prp_ctrl.wstrb[PRP_DATA_BYTES-1:0]),
        .s_axi_wlast      (s_prp_ctrl.wlast),
        .s_axi_wvalid     (s_prp_ctrl.wvalid),
        .s_axi_wready     (s_prp_ctrl.wready),

        .s_axi_bresp      (s_prp_ctrl.bresp),
        .s_axi_bvalid     (s_prp_ctrl.bvalid),
        .s_axi_bready     (s_prp_ctrl.bready),

        .s_axi_araddr     (s_prp_ctrl.araddr[EXT_ADDR_WIDTH-1:0]),
        .s_axi_arlen      (s_prp_ctrl.arlen),
        .s_axi_arsize     (s_prp_ctrl.arsize),
        .s_axi_arburst    (s_prp_ctrl.arburst),
        .s_axi_arlock     (s_prp_ctrl.arlock),
        .s_axi_arcache    (s_prp_ctrl.arcache),
        .s_axi_arprot     (s_prp_ctrl.arprot),
        .s_axi_arvalid    (s_prp_ctrl.arvalid),
        .s_axi_arready    (s_prp_ctrl.arready),

        .s_axi_rdata      (s_prp_ctrl.rdata[63:0]),
        .s_axi_rresp      (s_prp_ctrl.rresp),
        .s_axi_rlast      (s_prp_ctrl.rlast),
        .s_axi_rvalid     (s_prp_ctrl.rvalid),
        .s_axi_rready     (s_prp_ctrl.rready),

        .bram_addr_a      (bram_addr_a),
        .bram_clk_a       (),
        .bram_wrdata_a    (),
        .bram_rddata_a    (bram_rddata_wire),
        .bram_en_a        (bram_en_a),
        .bram_rst_a       (),
        .bram_we_a        ()
    );

    // ================================================================
    // Address remapping: external 4KB page → internal PRP_ADDR_BITS entries
    // External byte addr: [EXT-1 : PAGE] = dev_id + sq_tail
    //                     [PAGE-1 : PRP+BYTE] = unused (always 0)
    //                     [PRP+BYTE-1 : BYTE] = entry_idx
    //                     [BYTE-1 : 0] = byte offset
    // Internal BRAM addr: {dev_id, sq_tail, entry_idx}
    // ================================================================
    assign b_addr = {bram_addr_a[EXT_ADDR_WIDTH-1 : EXT_PAGE_BITS],
                     bram_addr_a[PRP_ADDR_BITS+BRAM_BYTE_BITS-1 : BRAM_BYTE_BITS]};

    // ================================================================
    // Read data: direct connection (64-bit AXI ↔ 64-bit BRAM)
    // ================================================================
    assign bram_rddata_wire = b_data_out;

    // ================================================================
    // Write path: s_prp -> BRAM
    // ================================================================
    assign a_en      = s_prp.valid;
    assign a_we      = {PRP_DATA_BYTES{s_prp.valid}};
    assign a_addr    = s_prp.data.addr[ADDR_BITS-1:0];
    assign a_data_in = s_prp.data.data;
    assign s_prp.ready = 1'b1;

    // ================================================================
    // Dual-port BRAM (1-cycle read latency)
    // ================================================================
    ram_sdp_nc #(
        .ADDR_BITS (ADDR_BITS),
        .DATA_BITS (64)
    ) inst_prp_bram (
        .clk        (aclk),
        .a_en       (a_en),
        .a_we       (a_we),
        .a_addr     (a_addr),
        .a_data_in  (a_data_in),
        .b_en       (bram_en_a),
        .b_addr     (b_addr),
        .b_data_out (b_data_out)
    );

    // ================================================================
    // ILA Debug
    // ================================================================
// `define EN_ILA_NVME_PRP_CTRL
`ifdef EN_ILA_NVME_PRP_CTRL
    ila_nvme_prp_ctrl inst_ila_nvme_prp_ctrl (
        .clk    (aclk),
        .probe0 (s_prp.valid),                          // 1
        .probe1 (s_prp.ready),                          // 1
        .probe2 (s_prp.data.addr),                      // NVME_QUEUE_BITS+PRP_ADDR_BITS+N_NVME_BITS (15)
        .probe3 (s_prp.data.data[31:0]),                // 32
        .probe4 (bram_en_a),                            // 1
        .probe5 (b_addr),                               // ADDR_BITS (15)
        .probe6 (a_en),                                 // 1
        .probe7 (a_addr)                                // ADDR_BITS (15)
    );
`endif

endmodule