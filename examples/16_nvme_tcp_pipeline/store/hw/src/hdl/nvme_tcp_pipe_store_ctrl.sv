/**
 * nvme_tcp_pipe_store_ctrl — AXI-Lite control register parser
 *
 * Register Map (AXIL_DATA_BITS = 64):
 *   0 (W1S) : CTRL            - bit0=START
 *   1 (RO)  : STATUS          - [7:0]=fsm states, [8]=listen_ok
 *   2 (WR)  : LISTEN_PORT     - TCP listen port
 *   3 (WR)  : HBM_BASE        - Ring buffer base vaddr
 *   4 (WR)  : CHUNK_BITS      - log2(chunk_size), [4:0] (host precomputes)
 *   5 (WR)  : SLOT_MASK       - n_slots - 1, [31:0] (host precomputes)
 *   6 (WR)  : NSID            - NVMe namespace ID
 *   7 (RO)  : TIMER           - Cycle counter
 *   8 (RO)  : NVME_SENT       - NVMe commands issued
 *   9 (RO)  : NVME_DONE       - NVMe completions received
 *  10 (RO)  : LAST_ERROR      - Last NVMe error code
 *  11 (RO)  : BYTES_TOTAL     - Total bytes processed
 *  12 (RO)  : WR_PTR          - Current write slot index
 *  13 (RO)  : RD_NVME_PTR     - Current NVMe read slot index
 */

import lynxTypes::*;

module nvme_tcp_pipe_store_ctrl (
    input  logic                        aclk,
    input  logic                        aresetn,

    AXI4L.s                             axi_ctrl,

    // Outputs (to user logic)
    output logic [1:0]                  bench_ctrl,
    output logic [15:0]                 listen_port,
    output logic [VADDR_BITS-1:0]       hbm_base,
    output logic [4:0]                  chunk_bits,
    output logic [31:0]                 slot_mask,
    output logic [63:0]                 nsid,

    // Inputs (from user logic)
    input  logic [7:0]                  status_bits,
    input  logic                        listen_ok,
    input  logic [63:0]                 timer,
    input  logic [31:0]                 nvme_sent,
    input  logic [31:0]                 nvme_done,
    input  logic [15:0]                 last_error,
    input  logic [63:0]                 bytes_total,
    input  logic [31:0]                 wr_ptr,
    input  logic [31:0]                 rd_nvme_ptr
);

localparam integer N_REGS = 14;
localparam integer ADDR_MSB = $clog2(N_REGS);
localparam integer ADDR_LSB = $clog2(AXIL_DATA_BITS/8);
localparam integer AXI_ADDR_BITS = ADDR_LSB + ADDR_MSB;

logic [AXI_ADDR_BITS-1:0] axi_awaddr;
logic axi_awready;
logic [AXI_ADDR_BITS-1:0] axi_araddr;
logic axi_arready;
logic [1:0] axi_bresp;
logic axi_bvalid;
logic axi_wready;
logic [AXIL_DATA_BITS-1:0] axi_rdata;
logic [1:0] axi_rresp;
logic axi_rvalid;
logic aw_en;

logic [N_REGS-1:0][AXIL_DATA_BITS-1:0] ctrl_reg;
logic ctrl_reg_rden;
logic ctrl_reg_wren;

localparam integer REG_CTRL        = 0;
localparam integer REG_STATUS      = 1;
localparam integer REG_LISTEN_PORT = 2;
localparam integer REG_HBM_BASE   = 3;
localparam integer REG_CHUNK_BITS  = 4;
localparam integer REG_SLOT_MASK   = 5;
localparam integer REG_NSID        = 6;
localparam integer REG_TIMER       = 7;
localparam integer REG_NVME_SENT   = 8;
localparam integer REG_NVME_DONE   = 9;
localparam integer REG_LAST_ERROR  = 10;
localparam integer REG_BYTES_TOTAL = 11;
localparam integer REG_WR_PTR      = 12;
localparam integer REG_RD_NVME_PTR = 13;

// ============================================================
// Write
// ============================================================
assign ctrl_reg_wren = axi_wready && axi_ctrl.wvalid && axi_awready && axi_ctrl.awvalid;

always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        ctrl_reg <= '0;
    end
    else begin
        ctrl_reg[REG_CTRL] <= '0;  // W1S: auto-clear

        if (ctrl_reg_wren) begin
            case (axi_awaddr[ADDR_LSB+:ADDR_MSB])
                REG_CTRL,
                REG_LISTEN_PORT,
                REG_HBM_BASE,
                REG_CHUNK_BITS,
                REG_SLOT_MASK,
                REG_NSID: begin
                    for (int i = 0; i < (AXIL_DATA_BITS/8); i++) begin
                        if (axi_ctrl.wstrb[i])
                            ctrl_reg[axi_awaddr[ADDR_LSB+:ADDR_MSB]][(i*8)+:8] <= axi_ctrl.wdata[(i*8)+:8];
                    end
                end
                default: ;
            endcase
        end
    end
end

// ============================================================
// Read
// ============================================================
assign ctrl_reg_rden = axi_arready & axi_ctrl.arvalid & ~axi_rvalid;

always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        axi_rdata <= '0;
    end
    else if (ctrl_reg_rden) begin
        axi_rdata <= '0;
        case (axi_araddr[ADDR_LSB+:ADDR_MSB])
            REG_CTRL:        axi_rdata         <= ctrl_reg[REG_CTRL];
            REG_STATUS:      axi_rdata         <= {55'd0, listen_ok, status_bits};
            REG_LISTEN_PORT: axi_rdata[15:0]   <= ctrl_reg[REG_LISTEN_PORT][15:0];
            REG_HBM_BASE:    axi_rdata         <= ctrl_reg[REG_HBM_BASE];
            REG_CHUNK_BITS:  axi_rdata[4:0]    <= ctrl_reg[REG_CHUNK_BITS][4:0];
            REG_SLOT_MASK:   axi_rdata[31:0]   <= ctrl_reg[REG_SLOT_MASK][31:0];
            REG_NSID:        axi_rdata         <= ctrl_reg[REG_NSID];
            REG_TIMER:       axi_rdata         <= timer;
            REG_NVME_SENT:   axi_rdata[31:0]   <= nvme_sent;
            REG_NVME_DONE:   axi_rdata[31:0]   <= nvme_done;
            REG_LAST_ERROR:  axi_rdata[15:0]   <= last_error;
            REG_BYTES_TOTAL: axi_rdata         <= bytes_total;
            REG_WR_PTR:      axi_rdata[31:0]   <= wr_ptr;
            REG_RD_NVME_PTR: axi_rdata[31:0]   <= rd_nvme_ptr;
            default: ;
        endcase
    end
end

// ============================================================
// Output mapping
// ============================================================
always_comb begin
    bench_ctrl  = ctrl_reg[REG_CTRL][1:0];
    listen_port = ctrl_reg[REG_LISTEN_PORT][15:0];
    hbm_base    = ctrl_reg[REG_HBM_BASE][VADDR_BITS-1:0];
    chunk_bits  = ctrl_reg[REG_CHUNK_BITS][4:0];
    slot_mask   = ctrl_reg[REG_SLOT_MASK][31:0];
    nsid        = ctrl_reg[REG_NSID];
end

// ============================================================
// Standard AXI-Lite handshake
// ============================================================
assign axi_ctrl.awready = axi_awready;
assign axi_ctrl.arready = axi_arready;
assign axi_ctrl.bresp   = axi_bresp;
assign axi_ctrl.bvalid  = axi_bvalid;
assign axi_ctrl.wready  = axi_wready;
assign axi_ctrl.rdata   = axi_rdata;
assign axi_ctrl.rresp   = axi_rresp;
assign axi_ctrl.rvalid  = axi_rvalid;

always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        axi_awready <= 1'b0;
        axi_awaddr  <= '0;
        aw_en       <= 1'b1;
    end
    else begin
        if (~axi_awready && axi_ctrl.awvalid && axi_ctrl.wvalid && aw_en) begin
            axi_awready <= 1'b1;
            aw_en       <= 1'b0;
            axi_awaddr  <= axi_ctrl.awaddr;
        end
        else if (axi_ctrl.bready && axi_bvalid) begin
            aw_en       <= 1'b1;
            axi_awready <= 1'b0;
        end
        else begin
            axi_awready <= 1'b0;
        end
    end
end

always_ff @(posedge aclk) begin
    if (aresetn == 1'b0)
        axi_wready <= 1'b0;
    else if (~axi_wready && axi_ctrl.wvalid && axi_ctrl.awvalid && aw_en)
        axi_wready <= 1'b1;
    else
        axi_wready <= 1'b0;
end

always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        axi_bvalid <= 1'b0;
        axi_bresp  <= 2'b0;
    end
    else if (axi_awready && axi_ctrl.awvalid && ~axi_bvalid && axi_wready && axi_ctrl.wvalid) begin
        axi_bvalid <= 1'b1;
        axi_bresp  <= 2'b0;
    end
    else if (axi_ctrl.bready && axi_bvalid)
        axi_bvalid <= 1'b0;
end

always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        axi_arready <= 1'b0;
        axi_araddr  <= '0;
    end
    else if (~axi_arready && axi_ctrl.arvalid) begin
        axi_arready <= 1'b1;
        axi_araddr  <= axi_ctrl.araddr;
    end
    else
        axi_arready <= 1'b0;
end

always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        axi_rvalid <= 1'b0;
        axi_rresp  <= 2'b0;
    end
    else if (axi_arready && axi_ctrl.arvalid && ~axi_rvalid) begin
        axi_rvalid <= 1'b1;
        axi_rresp  <= 2'b0;
    end
    else if (axi_rvalid && axi_ctrl.rready)
        axi_rvalid <= 1'b0;
end

endmodule
