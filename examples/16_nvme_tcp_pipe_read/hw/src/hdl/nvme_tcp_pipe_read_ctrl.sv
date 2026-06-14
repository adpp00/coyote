/**
 * This file is part of the Coyote <https://github.com/fpgasystems/Coyote>
 *
 * MIT Licence
 * Copyright (c) 2021-2026, Systems Group, ETH Zurich
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:

 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.

 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

/**
 * nvme_tcp_pipe_read_ctrl - AXI-Lite control register parser
 *
 * Register map (AXIL_DATA_BITS = 64):
 *   0  (W1S) : CTRL            - bit0 = START
 *   1  (RO)  : STATUS          - [1:0]=arx_state, [4:2]=nv_state, [5]=listen_ok, [9:6]=tx_state
 *   2  (WR)  : LISTEN_PORT     - TCP listen port
 *   3  (WR)  : HBM_BASE        - Ring buffer base vaddr
 *   4  (WR)  : CHUNK_SIZE      - Bytes per slot
 *   5  (WR)  : N_SLOTS         - Ring buffer slot count
 *   6  (WR)  : DMA_BLOCK_SIZE  - DMA read granularity for TCP TX (e.g. 32768)
 *   7  (WR)  : DMA_PER_SLOT    - chunk_size / dma_block_size (SW pre-computed)
 *   8  (WR)  : NSID            - NVMe namespace ID
 *   9  (RO)  : TIMER           - Cycle counter
 *  10  (RO)  : NVME_SENT       - NVMe commands issued
 *  11  (RO)  : NVME_DONE       - NVMe completions received
 *  12  (RO)  : LAST_ERROR      - Last NVMe error code
 *  13  (RO)  : BYTES_TOTAL     - Total TCP bytes sent
 *  14  (RO)  : WR_PTR          - Current NVMe write pointer
 *  15  (RO)  : RD_PTR          - Current TX read pointer
 *  16  (WR)  : MAX_OUTSTANDING - Max inflight NVMe commands (default 56)
 */

import lynxTypes::*;

module nvme_tcp_pipe_read_ctrl (
    input  logic                        aclk,
    input  logic                        aresetn,

    AXI4L.s                             axi_ctrl,

    // Outputs (to user logic)
    output logic [1:0]                  bench_ctrl,
    output logic [15:0]                 listen_port,
    output logic [VADDR_BITS-1:0]       hbm_base,
    output logic [31:0]                 chunk_size,
    output logic [31:0]                 n_slots,
    output logic [31:0]                 dma_block_size,
    output logic [31:0]                 dma_per_slot,
    output logic [63:0]                 nsid,
    output logic [31:0]                 max_outstanding,

    // Inputs (from user logic)
    input  logic [10:0]                 status_bits,
    input  logic                        listen_ok,
    input  logic [63:0]                 timer,
    input  logic [31:0]                 nvme_sent,
    input  logic [31:0]                 nvme_done,
    input  logic [15:0]                 last_error,
    input  logic [63:0]                 bytes_total,
    input  logic [31:0]                 wr_ptr,
    input  logic [31:0]                 rd_ptr
);

localparam integer N_REGS = 20;
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

localparam integer REG_CTRL            = 0;
localparam integer REG_STATUS          = 1;
localparam integer REG_LISTEN_PORT     = 2;
localparam integer REG_HBM_BASE        = 3;
localparam integer REG_CHUNK_SIZE      = 4;
localparam integer REG_N_SLOTS         = 5;
localparam integer REG_DMA_BLOCK_SIZE  = 6;
localparam integer REG_DMA_PER_SLOT    = 7;
localparam integer REG_NSID            = 8;
localparam integer REG_TIMER           = 9;
localparam integer REG_NVME_SENT       = 10;
localparam integer REG_NVME_DONE       = 11;
localparam integer REG_LAST_ERROR      = 12;
localparam integer REG_BYTES_TOTAL     = 13;
localparam integer REG_WR_PTR          = 14;
localparam integer REG_RD_PTR          = 15;
localparam integer REG_MAX_OUTSTANDING = 16;

// ============================================================
// Write
// ============================================================
assign ctrl_reg_wren = axi_wready && axi_ctrl.wvalid && axi_awready && axi_ctrl.awvalid;

always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        ctrl_reg <= '0;
    end
    else begin
        ctrl_reg[REG_CTRL] <= '0; // W1S: auto-clear

        if (ctrl_reg_wren) begin
            case (axi_awaddr[ADDR_LSB+:ADDR_MSB])
                REG_CTRL,
                REG_LISTEN_PORT,
                REG_HBM_BASE,
                REG_CHUNK_SIZE,
                REG_N_SLOTS,
                REG_DMA_BLOCK_SIZE,
                REG_DMA_PER_SLOT,
                REG_NSID,
                REG_MAX_OUTSTANDING: begin
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
            REG_CTRL:            axi_rdata        <= ctrl_reg[REG_CTRL];
            REG_STATUS:          axi_rdata[10:0]  <= status_bits;
            REG_LISTEN_PORT:     axi_rdata[15:0]  <= ctrl_reg[REG_LISTEN_PORT][15:0];
            REG_HBM_BASE:        axi_rdata        <= ctrl_reg[REG_HBM_BASE];
            REG_CHUNK_SIZE:      axi_rdata[31:0]  <= ctrl_reg[REG_CHUNK_SIZE][31:0];
            REG_N_SLOTS:         axi_rdata[31:0]  <= ctrl_reg[REG_N_SLOTS][31:0];
            REG_DMA_BLOCK_SIZE:  axi_rdata[31:0]  <= ctrl_reg[REG_DMA_BLOCK_SIZE][31:0];
            REG_DMA_PER_SLOT:    axi_rdata[31:0]  <= ctrl_reg[REG_DMA_PER_SLOT][31:0];
            REG_NSID:            axi_rdata        <= ctrl_reg[REG_NSID];
            REG_TIMER:           axi_rdata        <= timer;
            REG_NVME_SENT:       axi_rdata[31:0]  <= nvme_sent;
            REG_NVME_DONE:       axi_rdata[31:0]  <= nvme_done;
            REG_LAST_ERROR:      axi_rdata[15:0]  <= last_error;
            REG_BYTES_TOTAL:     axi_rdata        <= bytes_total;
            REG_WR_PTR:          axi_rdata[31:0]  <= wr_ptr;
            REG_RD_PTR:          axi_rdata[31:0]  <= rd_ptr;
            REG_MAX_OUTSTANDING: axi_rdata[31:0]  <= ctrl_reg[REG_MAX_OUTSTANDING][31:0];
            default: ;
        endcase
    end
end

// ============================================================
// Output mapping
// ============================================================
always_comb begin
    bench_ctrl      = ctrl_reg[REG_CTRL][1:0];
    listen_port     = ctrl_reg[REG_LISTEN_PORT][15:0];
    hbm_base        = ctrl_reg[REG_HBM_BASE][VADDR_BITS-1:0];
    chunk_size      = ctrl_reg[REG_CHUNK_SIZE][31:0];
    n_slots         = ctrl_reg[REG_N_SLOTS][31:0];
    dma_block_size  = ctrl_reg[REG_DMA_BLOCK_SIZE][31:0];
    dma_per_slot    = ctrl_reg[REG_DMA_PER_SLOT][31:0];
    nsid            = ctrl_reg[REG_NSID];
    max_outstanding = ctrl_reg[REG_MAX_OUTSTANDING][31:0];
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
