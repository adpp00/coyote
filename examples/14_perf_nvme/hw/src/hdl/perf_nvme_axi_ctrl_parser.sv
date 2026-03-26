/**
 * perf_nvme_axi_ctrl_parser (multi-device)
 *
 * Register Map:
 *   0 (W1S) : CTRL            - bit0=READ, bit1=WRITE
 *   1 (RO)  : SENT            - Total REQs sent (all devices)
 *   2 (RO)  : DONE            - Total CPLs received (all devices)
 *   3 (RO)  : TIMER           - Clock cycles
 *   4 (WR)  : VADDR           - Card memory base address (shared)
 *   5 (WR)  : CHUNK_SIZE      - Bytes per NVMe command (shared)
 *   6 (WR)  : N_REPS          - Number of commands PER DEVICE
 *   7 (WR)  : LBA             - Starting byte offset (shared)
 *   8 (WR)  : DEV_MASK        - Bitmask of active devices (e.g., 0x000F)
 *   9 (WR)  : NSID            - Namespace ID (shared)
 *  10 (WR)  : MAX_OUTSTANDING - Max concurrent commands PER DEVICE
 *  11 (RO)  : ERROR           - Last error code
 */

import lynxTypes::*;

module perf_nvme_axi_ctrl_parser (
    input  logic                        aclk,
    input  logic                        aresetn,

    AXI4L.s                             axi_ctrl,

    // Outputs to benchmark logic (from SW)
    output logic [1:0]                  bench_ctrl,
    output logic [VADDR_BITS-1:0]       bench_vaddr,
    output logic [31:0]                 bench_chunk_size,
    output logic [31:0]                 bench_n_reps,
    output logic [63:0]                 bench_lba,
    output logic [15:0]                 bench_dev_mask,
    output logic [63:0]                 bench_nsid,
    output logic [31:0]                 bench_max_outstanding,

    // Inputs from benchmark logic (to SW)
    input  logic [31:0]                 bench_sent,
    input  logic [31:0]                 bench_done,
    input  logic [63:0]                 bench_timer,
    input  logic [15:0]                 last_error
);

/////////////////////////////////////
//          CONSTANTS             //
///////////////////////////////////
localparam integer N_REGS = 12;
localparam integer ADDR_MSB = $clog2(N_REGS);
localparam integer ADDR_LSB = $clog2(AXIL_DATA_BITS/8);
localparam integer AXI_ADDR_BITS = ADDR_LSB + ADDR_MSB;

/////////////////////////////////////
//       INTERNAL SIGNALS         //
///////////////////////////////////
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

/////////////////////////////////////
//         REGISTER MAP           //
///////////////////////////////////
localparam integer BENCH_CTRL_REG            = 0;
localparam integer BENCH_SENT_REG            = 1;
localparam integer BENCH_DONE_REG            = 2;
localparam integer BENCH_TIMER_REG           = 3;
localparam integer BENCH_VADDR_REG           = 4;
localparam integer BENCH_CHUNK_SIZE_REG      = 5;
localparam integer BENCH_N_REPS_REG          = 6;
localparam integer BENCH_LBA_REG             = 7;
localparam integer BENCH_DEV_MASK_REG        = 8;
localparam integer BENCH_NSID_REG            = 9;
localparam integer BENCH_MAX_OUTSTANDING_REG = 10;
localparam integer BENCH_ERROR_REG           = 11;

/////////////////////////////////////
//         WRITE PROCESS          //
///////////////////////////////////
assign ctrl_reg_wren = axi_wready && axi_ctrl.wvalid && axi_awready && axi_ctrl.awvalid;

always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        ctrl_reg <= '0;
    end
    else begin
        // Clear control register after one cycle (W1S)
        ctrl_reg[BENCH_CTRL_REG] <= '0;

        if (ctrl_reg_wren) begin
            case (axi_awaddr[ADDR_LSB+:ADDR_MSB])
                BENCH_CTRL_REG,
                BENCH_VADDR_REG,
                BENCH_CHUNK_SIZE_REG,
                BENCH_N_REPS_REG,
                BENCH_LBA_REG,
                BENCH_DEV_MASK_REG,
                BENCH_NSID_REG,
                BENCH_MAX_OUTSTANDING_REG: begin
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

/////////////////////////////////////
//         READ PROCESS           //
///////////////////////////////////
assign ctrl_reg_rden = axi_arready & axi_ctrl.arvalid & ~axi_rvalid;

always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        axi_rdata <= '0;
    end
    else begin
        if (ctrl_reg_rden) begin
            axi_rdata <= '0;

            case (axi_araddr[ADDR_LSB+:ADDR_MSB])
                BENCH_SENT_REG:
                    axi_rdata[31:0] <= bench_sent;
                BENCH_DONE_REG:
                    axi_rdata[31:0] <= bench_done;
                BENCH_TIMER_REG:
                    axi_rdata <= bench_timer;
                BENCH_ERROR_REG:
                    axi_rdata[15:0] <= last_error;
                default: ;
            endcase
        end
    end
end

/////////////////////////////////////
//       OUTPUT ASSIGNMENT        //
///////////////////////////////////
always_comb begin
    bench_ctrl            = ctrl_reg[BENCH_CTRL_REG][1:0];
    bench_vaddr           = ctrl_reg[BENCH_VADDR_REG][VADDR_BITS-1:0];
    bench_chunk_size      = ctrl_reg[BENCH_CHUNK_SIZE_REG][31:0];
    bench_n_reps          = ctrl_reg[BENCH_N_REPS_REG][31:0];
    bench_lba             = ctrl_reg[BENCH_LBA_REG];
    bench_dev_mask        = ctrl_reg[BENCH_DEV_MASK_REG][15:0];
    bench_nsid            = ctrl_reg[BENCH_NSID_REG];
    bench_max_outstanding = ctrl_reg[BENCH_MAX_OUTSTANDING_REG][31:0];
end

/////////////////////////////////////
//     STANDARD AXI CONTROL       //
///////////////////////////////////
assign axi_ctrl.awready = axi_awready;
assign axi_ctrl.arready = axi_arready;
assign axi_ctrl.bresp   = axi_bresp;
assign axi_ctrl.bvalid  = axi_bvalid;
assign axi_ctrl.wready  = axi_wready;
assign axi_ctrl.rdata   = axi_rdata;
assign axi_ctrl.rresp   = axi_rresp;
assign axi_ctrl.rvalid  = axi_rvalid;

// awready and awaddr
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

// wready
always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        axi_wready <= 1'b0;
    end
    else begin
        if (~axi_wready && axi_ctrl.wvalid && axi_ctrl.awvalid && aw_en) begin
            axi_wready <= 1'b1;
        end
        else begin
            axi_wready <= 1'b0;
        end
    end
end

// bvalid and bresp
always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        axi_bvalid <= 1'b0;
        axi_bresp  <= 2'b0;
    end
    else begin
        if (axi_awready && axi_ctrl.awvalid && ~axi_bvalid && axi_wready && axi_ctrl.wvalid) begin
            axi_bvalid <= 1'b1;
            axi_bresp  <= 2'b0;
        end
        else begin
            if (axi_ctrl.bready && axi_bvalid) begin
                axi_bvalid <= 1'b0;
            end
        end
    end
end

// arready and araddr
always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        axi_arready <= 1'b0;
        axi_araddr  <= '0;
    end
    else begin
        if (~axi_arready && axi_ctrl.arvalid) begin
            axi_arready <= 1'b1;
            axi_araddr  <= axi_ctrl.araddr;
        end
        else begin
            axi_arready <= 1'b0;
        end
    end
end

// rvalid and rresp
always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        axi_rvalid <= 1'b0;
        axi_rresp  <= 2'b0;
    end
    else begin
        if (axi_arready && axi_ctrl.arvalid && ~axi_rvalid) begin
            axi_rvalid <= 1'b1;
            axi_rresp  <= 2'b0;
        end
        else if (axi_rvalid && axi_ctrl.rready) begin
            axi_rvalid <= 1'b0;
        end
    end
end

endmodule
