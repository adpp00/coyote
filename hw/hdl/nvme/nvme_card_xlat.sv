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
 * @brief   NVMe card window translation
 *
 * Window offsets to card memory addresses, one table entry per 4 KB page.
 * AXI bursts do not cross 4 KB, so each AR and AW needs one lookup.
 */
module nvme_card_xlat (
    input  logic                            aclk,
    input  logic                            aresetn,

    input  logic                            tbl_valid,
    input  logic [NVME_CARD_TBL_BITS-1:0]   tbl_idx,
    input  logic [NVME_CARD_PAGE_BITS-1:0]  tbl_page,

    AXI4.s                                  s_axi,
    AXI4.m                                  m_axi
);

typedef struct packed {
    logic [11:0]                off;
    logic [AXI_ID_BITS-1:0]     id;
    logic [7:0]                 len;
    logic [2:0]                 size;
    logic [1:0]                 burst;
    logic [3:0]                 cache;
    logic [0:0]                 lock;
    logic [2:0]                 prot;
    logic [3:0]                 qos;
    logic [3:0]                 region;
} ax_t;

// Page tables (one copy per channel)
logic [NVME_CARD_PAGE_BITS-1:0] ar_tbl [2**NVME_CARD_TBL_BITS];
logic [NVME_CARD_PAGE_BITS-1:0] aw_tbl [2**NVME_CARD_TBL_BITS];

always_ff @(posedge aclk) begin
    if (tbl_valid) begin
        ar_tbl[tbl_idx] <= tbl_page;
        aw_tbl[tbl_idx] <= tbl_page;
    end
end

// AR
ax_t                            ar_in, ar_a, ar_b;
logic                           ar_a_valid, ar_b_valid, ar_fire, ar_move;
logic [NVME_CARD_PAGE_BITS-1:0] ar_page;

assign ar_in = '{off: s_axi.araddr[11:0], id: s_axi.arid, len: s_axi.arlen, size: s_axi.arsize,
                 burst: s_axi.arburst, cache: s_axi.arcache, lock: s_axi.arlock, prot: s_axi.arprot,
                 qos: s_axi.arqos, region: s_axi.arregion};

assign ar_move = ar_a_valid && (!ar_b_valid || m_axi.arready);
assign s_axi.arready = !ar_a_valid || ar_move;
assign ar_fire = s_axi.arvalid && s_axi.arready;

always_ff @(posedge aclk) begin
    if (ar_fire)
        ar_page <= ar_tbl[s_axi.araddr[NVME_CARD_TBL_BITS+11:12]];
end

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        ar_a_valid <= 1'b0;
        ar_b_valid <= 1'b0;
    end
    else begin
        if (ar_fire) begin
            ar_a       <= ar_in;
            ar_a_valid <= 1'b1;
        end
        else if (ar_move) begin
            ar_a_valid <= 1'b0;
        end

        if (ar_move) begin
            ar_b               <= ar_a;
            m_axi.araddr       <= {{(64-PADDR_BITS){1'b0}}, ar_page, ar_a.off};
            ar_b_valid         <= 1'b1;
        end
        else if (m_axi.arready) begin
            ar_b_valid <= 1'b0;
        end
    end
end

assign m_axi.arvalid  = ar_b_valid;
assign m_axi.arid     = ar_b.id;
assign m_axi.arlen    = ar_b.len;
assign m_axi.arsize   = ar_b.size;
assign m_axi.arburst  = ar_b.burst;
assign m_axi.arcache  = ar_b.cache;
assign m_axi.arlock   = ar_b.lock;
assign m_axi.arprot   = ar_b.prot;
assign m_axi.arqos    = ar_b.qos;
assign m_axi.arregion = ar_b.region;

// AW
ax_t                            aw_in, aw_a, aw_b;
logic                           aw_a_valid, aw_b_valid, aw_fire, aw_move;
logic [NVME_CARD_PAGE_BITS-1:0] aw_page;

assign aw_in = '{off: s_axi.awaddr[11:0], id: s_axi.awid, len: s_axi.awlen, size: s_axi.awsize,
                 burst: s_axi.awburst, cache: s_axi.awcache, lock: s_axi.awlock, prot: s_axi.awprot,
                 qos: s_axi.awqos, region: s_axi.awregion};

assign aw_move = aw_a_valid && (!aw_b_valid || m_axi.awready);
assign s_axi.awready = !aw_a_valid || aw_move;
assign aw_fire = s_axi.awvalid && s_axi.awready;

always_ff @(posedge aclk) begin
    if (aw_fire)
        aw_page <= aw_tbl[s_axi.awaddr[NVME_CARD_TBL_BITS+11:12]];
end

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        aw_a_valid <= 1'b0;
        aw_b_valid <= 1'b0;
    end
    else begin
        if (aw_fire) begin
            aw_a       <= aw_in;
            aw_a_valid <= 1'b1;
        end
        else if (aw_move) begin
            aw_a_valid <= 1'b0;
        end

        if (aw_move) begin
            aw_b               <= aw_a;
            m_axi.awaddr       <= {{(64-PADDR_BITS){1'b0}}, aw_page, aw_a.off};
            aw_b_valid         <= 1'b1;
        end
        else if (m_axi.awready) begin
            aw_b_valid <= 1'b0;
        end
    end
end

assign m_axi.awvalid  = aw_b_valid;
assign m_axi.awid     = aw_b.id;
assign m_axi.awlen    = aw_b.len;
assign m_axi.awsize   = aw_b.size;
assign m_axi.awburst  = aw_b.burst;
assign m_axi.awcache  = aw_b.cache;
assign m_axi.awlock   = aw_b.lock;
assign m_axi.awprot   = aw_b.prot;
assign m_axi.awqos    = aw_b.qos;
assign m_axi.awregion = aw_b.region;

// W / B / R
assign m_axi.wdata  = s_axi.wdata;
assign m_axi.wstrb  = s_axi.wstrb;
assign m_axi.wlast  = s_axi.wlast;
assign m_axi.wvalid = s_axi.wvalid;
assign s_axi.wready = m_axi.wready;

assign s_axi.bid    = m_axi.bid;
assign s_axi.bresp  = m_axi.bresp;
assign s_axi.bvalid = m_axi.bvalid;
assign m_axi.bready = s_axi.bready;

assign s_axi.rid    = m_axi.rid;
assign s_axi.rdata  = m_axi.rdata;
assign s_axi.rresp  = m_axi.rresp;
assign s_axi.rlast  = m_axi.rlast;
assign s_axi.rvalid = m_axi.rvalid;
assign m_axi.rready = s_axi.rready;

endmodule
