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
 * @brief   NVMe card window split of axi_main
 *
 * Card window to m_axi_card, the rest to m_axi_ctrl.
 */
module nvme_card_split #(
    parameter integer N_OUTSTANDING = 64,
    parameter integer W_DEPTH = 32
)(
    input  logic    aclk,
    input  logic    aresetn,

    AXI4.s          s_axi,
    AXI4.m          m_axi_ctrl,
    AXI4.m          m_axi_card
);

localparam integer PTR_BITS = $clog2(N_OUTSTANDING);
localparam logic [63:0] CARD_END = NVME_CARD_WIN_BASE + NVME_CARD_WIN_SIZE;

// AR / R
logic ar_card;
assign ar_card = (s_axi.araddr >= NVME_CARD_WIN_BASE) && (s_axi.araddr < CARD_END);

// Outstanding reads
logic                       rd_card [N_OUTSTANDING];
logic [AXI_ID_BITS-1:0]     rd_id   [N_OUTSTANDING];
logic [PTR_BITS-1:0]        rd_wr_ptr, rd_rd_ptr;
logic [PTR_BITS:0]          rd_cnt;
logic                       rd_full, rd_empty, rd_head_card;
logic                       ar_fire, r_done;

assign rd_full      = (rd_cnt == N_OUTSTANDING);
assign rd_empty     = (rd_cnt == 0);
assign rd_head_card = rd_card[rd_rd_ptr];

assign m_axi_ctrl.araddr   = s_axi.araddr;
assign m_axi_ctrl.arburst  = s_axi.arburst;
assign m_axi_ctrl.arcache  = s_axi.arcache;
assign m_axi_ctrl.arid     = s_axi.arid;
assign m_axi_ctrl.arlen    = s_axi.arlen;
assign m_axi_ctrl.arlock   = s_axi.arlock;
assign m_axi_ctrl.arprot   = s_axi.arprot;
assign m_axi_ctrl.arqos    = s_axi.arqos;
assign m_axi_ctrl.arregion = s_axi.arregion;
assign m_axi_ctrl.arsize   = s_axi.arsize;
assign m_axi_ctrl.arvalid  = s_axi.arvalid && !ar_card && !rd_full;

assign m_axi_card.araddr   = s_axi.araddr - NVME_CARD_WIN_BASE + NVME_CARD_MEM_BASE;
assign m_axi_card.arburst  = s_axi.arburst;
assign m_axi_card.arcache  = s_axi.arcache;
assign m_axi_card.arid     = '0;
assign m_axi_card.arlen    = s_axi.arlen;
assign m_axi_card.arlock   = s_axi.arlock;
assign m_axi_card.arprot   = s_axi.arprot;
assign m_axi_card.arqos    = s_axi.arqos;
assign m_axi_card.arregion = '0;
assign m_axi_card.arsize   = s_axi.arsize;
assign m_axi_card.arvalid  = s_axi.arvalid && ar_card && !rd_full;

assign s_axi.arready = !rd_full && (ar_card ? m_axi_card.arready : m_axi_ctrl.arready);

assign s_axi.rdata    = rd_head_card ? m_axi_card.rdata  : m_axi_ctrl.rdata;
assign s_axi.rresp    = rd_head_card ? m_axi_card.rresp  : m_axi_ctrl.rresp;
assign s_axi.rlast    = rd_head_card ? m_axi_card.rlast  : m_axi_ctrl.rlast;
assign s_axi.rid      = rd_id[rd_rd_ptr];
assign s_axi.rvalid   = !rd_empty && (rd_head_card ? m_axi_card.rvalid : m_axi_ctrl.rvalid);
assign m_axi_ctrl.rready = !rd_empty && !rd_head_card && s_axi.rready;
assign m_axi_card.rready = !rd_empty &&  rd_head_card && s_axi.rready;

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
            rd_card[rd_wr_ptr] <= ar_card;
            rd_id[rd_wr_ptr]   <= s_axi.arid;
            rd_wr_ptr          <= rd_wr_ptr + 1'b1;
        end
        if (r_done)
            rd_rd_ptr <= rd_rd_ptr + 1'b1;
        rd_cnt <= rd_cnt + ar_fire - r_done;
    end
end

// W queue
typedef struct packed {
    logic [AXI_DATA_BITS-1:0]   data;
    logic [AXI_DATA_BITS/8-1:0] strb;
    logic                       last;
} w_beat_t;

w_beat_t    w_in, w_out;
logic       w_valid, w_ready;

assign w_in = '{data: s_axi.wdata, strb: s_axi.wstrb, last: s_axi.wlast};

axi_stripe_nvme_buf #(
    .QTYPE(w_beat_t),
    .QDEPTH(W_DEPTH)
) inst_w_que (
    .aclk(aclk),
    .aresetn(aresetn),
    .val_snk(s_axi.wvalid),
    .rdy_snk(s_axi.wready),
    .data_snk(w_in),
    .val_src(w_valid),
    .rdy_src(w_ready),
    .data_src(w_out)
);

// AW / W / B
logic aw_card;
assign aw_card = (s_axi.awaddr >= NVME_CARD_WIN_BASE) && (s_axi.awaddr < CARD_END);

// Outstanding writes
logic                       w_card [N_OUTSTANDING];
logic [PTR_BITS-1:0]        w_wr_ptr, w_rd_ptr;
logic [PTR_BITS:0]          w_cnt;
logic                       b_card [N_OUTSTANDING];
logic [AXI_ID_BITS-1:0]     b_id   [N_OUTSTANDING];
logic [PTR_BITS-1:0]        b_wr_ptr, b_rd_ptr;
logic [PTR_BITS:0]          b_cnt;
logic                       aw_full, w_empty, b_empty, w_head_card, b_head_card;
logic                       aw_fire, w_done, b_done;

assign aw_full     = (w_cnt == N_OUTSTANDING) || (b_cnt == N_OUTSTANDING);
assign w_empty     = (w_cnt == 0);
assign b_empty     = (b_cnt == 0);
assign w_head_card = w_card[w_rd_ptr];
assign b_head_card = b_card[b_rd_ptr];

assign m_axi_ctrl.awaddr   = s_axi.awaddr;
assign m_axi_ctrl.awburst  = s_axi.awburst;
assign m_axi_ctrl.awcache  = s_axi.awcache;
assign m_axi_ctrl.awid     = s_axi.awid;
assign m_axi_ctrl.awlen    = s_axi.awlen;
assign m_axi_ctrl.awlock   = s_axi.awlock;
assign m_axi_ctrl.awprot   = s_axi.awprot;
assign m_axi_ctrl.awqos    = s_axi.awqos;
assign m_axi_ctrl.awregion = s_axi.awregion;
assign m_axi_ctrl.awsize   = s_axi.awsize;
assign m_axi_ctrl.awvalid  = s_axi.awvalid && !aw_card && !aw_full;

assign m_axi_card.awaddr   = s_axi.awaddr - NVME_CARD_WIN_BASE + NVME_CARD_MEM_BASE;
assign m_axi_card.awburst  = s_axi.awburst;
assign m_axi_card.awcache  = s_axi.awcache;
assign m_axi_card.awid     = '0;
assign m_axi_card.awlen    = s_axi.awlen;
assign m_axi_card.awlock   = s_axi.awlock;
assign m_axi_card.awprot   = s_axi.awprot;
assign m_axi_card.awqos    = s_axi.awqos;
assign m_axi_card.awregion = '0;
assign m_axi_card.awsize   = s_axi.awsize;
assign m_axi_card.awvalid  = s_axi.awvalid && aw_card && !aw_full;

assign s_axi.awready = !aw_full && (aw_card ? m_axi_card.awready : m_axi_ctrl.awready);

assign m_axi_ctrl.wdata  = w_out.data;
assign m_axi_ctrl.wstrb  = w_out.strb;
assign m_axi_ctrl.wlast  = w_out.last;
assign m_axi_ctrl.wvalid = w_valid && !w_empty && !w_head_card;

assign m_axi_card.wdata  = w_out.data;
assign m_axi_card.wstrb  = w_out.strb;
assign m_axi_card.wlast  = w_out.last;
assign m_axi_card.wvalid = w_valid && !w_empty && w_head_card;

assign w_ready = !w_empty && (w_head_card ? m_axi_card.wready : m_axi_ctrl.wready);

assign s_axi.bresp    = b_head_card ? m_axi_card.bresp : m_axi_ctrl.bresp;
assign s_axi.bid      = b_id[b_rd_ptr];
assign s_axi.bvalid   = !b_empty && (b_head_card ? m_axi_card.bvalid : m_axi_ctrl.bvalid);
assign m_axi_ctrl.bready = !b_empty && !b_head_card && s_axi.bready;
assign m_axi_card.bready = !b_empty &&  b_head_card && s_axi.bready;

assign aw_fire = s_axi.awvalid && s_axi.awready;
assign w_done  = w_valid && w_ready && w_out.last;
assign b_done  = s_axi.bvalid && s_axi.bready;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        w_wr_ptr <= '0;
        w_rd_ptr <= '0;
        w_cnt    <= '0;
        b_wr_ptr <= '0;
        b_rd_ptr <= '0;
        b_cnt    <= '0;
    end
    else begin
        if (aw_fire) begin
            w_card[w_wr_ptr] <= aw_card;
            w_wr_ptr         <= w_wr_ptr + 1'b1;
            b_card[b_wr_ptr] <= aw_card;
            b_id[b_wr_ptr]   <= s_axi.awid;
            b_wr_ptr         <= b_wr_ptr + 1'b1;
        end
        if (w_done)
            w_rd_ptr <= w_rd_ptr + 1'b1;
        if (b_done)
            b_rd_ptr <= b_rd_ptr + 1'b1;
        w_cnt <= w_cnt + aw_fire - w_done;
        b_cnt <= b_cnt + aw_fire - b_done;
    end
end

endmodule
