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

`timescale 1ns / 1ps

import lynxTypes::*;

/**
 * @brief   Single-ID view of the CPM PL AXI master (BAR4)
 */
module nvme_pl_axi_order #(
    parameter integer ID_BITS       = 16,
    parameter integer N_OUTSTANDING = 64
)(
    input  logic    aclk,
    input  logic    aresetn,

    AXI4.s          s_axi,
    AXI4.m          m_axi
);

localparam integer PTR_BITS = $clog2(N_OUTSTANDING);

// AR / R
logic [ID_BITS-1:0]     rd_id [N_OUTSTANDING];
logic [PTR_BITS-1:0]    rd_wr_ptr, rd_rd_ptr;
logic [PTR_BITS:0]      rd_cnt;
logic                   rd_full;
logic                   ar_fire, r_done;

assign rd_full = (rd_cnt == N_OUTSTANDING);

assign m_axi.araddr   = s_axi.araddr;
assign m_axi.arburst  = s_axi.arburst;
assign m_axi.arcache  = s_axi.arcache;
assign m_axi.arid     = '0;
assign m_axi.arlen    = s_axi.arlen;
assign m_axi.arlock   = s_axi.arlock;
assign m_axi.arprot   = s_axi.arprot;
assign m_axi.arqos    = s_axi.arqos;
assign m_axi.arregion = s_axi.arregion;
assign m_axi.arsize   = s_axi.arsize;
assign m_axi.arvalid  = s_axi.arvalid && !rd_full;
assign s_axi.arready  = m_axi.arready && !rd_full;

assign s_axi.rdata  = m_axi.rdata;
assign s_axi.rresp  = m_axi.rresp;
assign s_axi.rlast  = m_axi.rlast;
assign s_axi.rid    = rd_id[rd_rd_ptr];
assign s_axi.rvalid = m_axi.rvalid;
assign m_axi.rready = s_axi.rready;

assign ar_fire = s_axi.arvalid && s_axi.arready;
assign r_done  = s_axi.rvalid && s_axi.rready && s_axi.rlast;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        rd_wr_ptr <= '0;
        rd_rd_ptr <= '0;
        rd_cnt    <= '0;
    end
    else begin
        if (ar_fire) begin
            rd_id[rd_wr_ptr] <= s_axi.arid;
            rd_wr_ptr        <= rd_wr_ptr + 1'b1;
        end
        if (r_done)
            rd_rd_ptr <= rd_rd_ptr + 1'b1;
        rd_cnt <= rd_cnt + ar_fire - r_done;
    end
end

// AW / W / B
logic [ID_BITS-1:0]     wr_id [N_OUTSTANDING];
logic [PTR_BITS-1:0]    wr_wr_ptr, wr_rd_ptr;
logic [PTR_BITS:0]      wr_cnt;
logic                   wr_full;
logic                   aw_fire, b_done;

assign wr_full = (wr_cnt == N_OUTSTANDING);

assign m_axi.awaddr   = s_axi.awaddr;
assign m_axi.awburst  = s_axi.awburst;
assign m_axi.awcache  = s_axi.awcache;
assign m_axi.awid     = '0;
assign m_axi.awlen    = s_axi.awlen;
assign m_axi.awlock   = s_axi.awlock;
assign m_axi.awprot   = s_axi.awprot;
assign m_axi.awqos    = s_axi.awqos;
assign m_axi.awregion = s_axi.awregion;
assign m_axi.awsize   = s_axi.awsize;
assign m_axi.awvalid  = s_axi.awvalid && !wr_full;
assign s_axi.awready  = m_axi.awready && !wr_full;

assign m_axi.wdata  = s_axi.wdata;
assign m_axi.wstrb  = s_axi.wstrb;
assign m_axi.wlast  = s_axi.wlast;
assign m_axi.wvalid = s_axi.wvalid;
assign s_axi.wready = m_axi.wready;

assign s_axi.bresp  = m_axi.bresp;
assign s_axi.bid    = wr_id[wr_rd_ptr];
assign s_axi.bvalid = m_axi.bvalid;
assign m_axi.bready = s_axi.bready;

assign aw_fire = s_axi.awvalid && s_axi.awready;
assign b_done  = s_axi.bvalid && s_axi.bready;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        wr_wr_ptr <= '0;
        wr_rd_ptr <= '0;
        wr_cnt    <= '0;
    end
    else begin
        if (aw_fire) begin
            wr_id[wr_wr_ptr] <= s_axi.awid;
            wr_wr_ptr        <= wr_wr_ptr + 1'b1;
        end
        if (b_done)
            wr_rd_ptr <= wr_rd_ptr + 1'b1;
        wr_cnt <= wr_cnt + aw_fire - b_done;
    end
end

endmodule
