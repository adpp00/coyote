/**
 * nvme_tcp_read_ctrl — AXI-Lite control register parser
 *
 * Register Map (AXIL_DATA_BITS = 64):
 *   0 (W1S) : CTRL            - bit0=START
 *   1 (RO)  : STATUS          - [4:0]=FSM state, [8]=listen_ok
 *   2 (WR)  : LISTEN_PORT     - TCP listen port
 *   3 (WR)  : MEM_BASE        - Card memory buffer base vaddr
 *   4 (WR)  : NSID            - NVMe namespace ID
 *   5 (WR)  : CHUNK_SIZE      - NVMe chunk size in bytes (default 4096)
 *   6 (RO)  : TIMER           - Cycle counter
 *   7 (RO)  : NVME_SENT       - NVMe commands issued (per block)
 *   8 (RO)  : NVME_DONE       - NVMe completions received (per block)
 *   9 (RO)  : LAST_ERROR      - Last NVMe error code
 *  10 (RO)  : BYTES_SENT      - Total TCP bytes sent
 *  11 (RO)  : NVME_LBA_OFF    - Current NVMe LBA byte offset
 */

import lynxTypes::*;

module nvme_tcp_read_ctrl (
    input  logic                        aclk,
    input  logic                        aresetn,

    AXI4L.s                             axi_ctrl,

    // Outputs (to user logic)
    output logic [1:0]                  bench_ctrl,
    output logic [15:0]                 listen_port,
    output logic [VADDR_BITS-1:0]       mem_base,
    output logic [63:0]                 nsid,
    output logic [31:0]                 chunk_size,

    // Inputs (from user logic)
    input  logic [3:0]                  fsm_state,
    input  logic                        listen_ok,
    input  logic [63:0]                 timer,
    input  logic [31:0]                 nvme_sent,
    input  logic [31:0]                 nvme_done,
    input  logic [15:0]                 last_error,
    input  logic [63:0]                 bytes_sent,
    input  logic [63:0]                 nvme_lba_off
);

localparam integer N_REGS = 12;
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
localparam integer REG_MEM_BASE   = 3;
localparam integer REG_NSID        = 4;
localparam integer REG_CHUNK_SIZE  = 5;
localparam integer REG_TIMER       = 6;
localparam integer REG_NVME_SENT   = 7;
localparam integer REG_NVME_DONE   = 8;
localparam integer REG_LAST_ERROR  = 9;
localparam integer REG_BYTES_SENT  = 10;
localparam integer REG_NVME_LBA   = 11;

// ============================================================
// Write
// ============================================================
assign ctrl_reg_wren = axi_wready && axi_ctrl.wvalid && axi_awready && axi_ctrl.awvalid;

always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        ctrl_reg <= '0;
    end
    else begin
        ctrl_reg[REG_CTRL] <= '0;

        if (ctrl_reg_wren) begin
            case (axi_awaddr[ADDR_LSB+:ADDR_MSB])
                REG_CTRL,
                REG_LISTEN_PORT,
                REG_MEM_BASE,
                REG_NSID,
                REG_CHUNK_SIZE: begin
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
            REG_STATUS:      axi_rdata         <= {55'd0, listen_ok, 4'd0, fsm_state};
            REG_LISTEN_PORT: axi_rdata[15:0]   <= ctrl_reg[REG_LISTEN_PORT][15:0];
            REG_MEM_BASE:    axi_rdata         <= ctrl_reg[REG_MEM_BASE];
            REG_NSID:        axi_rdata         <= ctrl_reg[REG_NSID];
            REG_CHUNK_SIZE:  axi_rdata[31:0]   <= ctrl_reg[REG_CHUNK_SIZE][31:0];
            REG_TIMER:       axi_rdata         <= timer;
            REG_NVME_SENT:   axi_rdata[31:0]   <= nvme_sent;
            REG_NVME_DONE:   axi_rdata[31:0]   <= nvme_done;
            REG_LAST_ERROR:  axi_rdata[15:0]   <= last_error;
            REG_BYTES_SENT:  axi_rdata         <= bytes_sent;
            REG_NVME_LBA:    axi_rdata         <= nvme_lba_off;
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
    mem_base    = ctrl_reg[REG_MEM_BASE][VADDR_BITS-1:0];
    nsid        = ctrl_reg[REG_NSID];
    chunk_size  = ctrl_reg[REG_CHUNK_SIZE][31:0];
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
