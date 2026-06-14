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

module axi_card_mem_2ch_split #(
    parameter int SPLIT_BIT     = 12,   // 4KB page interleave
    parameter int W_ROUTE_DEPTH = 16    // Outstanding AW tracking FIFO depth
)(
    input  logic    aclk,
    input  logic    aresetn,

    AXI4.s          s_axi,       // single input
    AXI4.m          m_axi_0,     // output port 0 (even pages)
    AXI4.m          m_axi_1      // output port 1 (odd pages)
);

    // ================================================================
    // AR channel: route based on araddr[SPLIT_BIT]
    // ================================================================
    logic ar_sel;
    assign ar_sel = s_axi.araddr[SPLIT_BIT];

    // Port 0
    assign m_axi_0.araddr   = s_axi.araddr;
    assign m_axi_0.arburst  = s_axi.arburst;
    assign m_axi_0.arcache  = s_axi.arcache;
    assign m_axi_0.arid     = s_axi.arid;
    assign m_axi_0.arlen    = s_axi.arlen;
    assign m_axi_0.arlock   = s_axi.arlock;
    assign m_axi_0.arprot   = s_axi.arprot;
    assign m_axi_0.arqos    = s_axi.arqos;
    assign m_axi_0.arregion = s_axi.arregion;
    assign m_axi_0.arsize   = s_axi.arsize;
    assign m_axi_0.arvalid  = s_axi.arvalid && !ar_sel;

    // Port 1
    assign m_axi_1.araddr   = s_axi.araddr;
    assign m_axi_1.arburst  = s_axi.arburst;
    assign m_axi_1.arcache  = s_axi.arcache;
    assign m_axi_1.arid     = s_axi.arid;
    assign m_axi_1.arlen    = s_axi.arlen;
    assign m_axi_1.arlock   = s_axi.arlock;
    assign m_axi_1.arprot   = s_axi.arprot;
    assign m_axi_1.arqos    = s_axi.arqos;
    assign m_axi_1.arregion = s_axi.arregion;
    assign m_axi_1.arsize   = s_axi.arsize;
    assign m_axi_1.arvalid  = s_axi.arvalid && ar_sel;

    assign s_axi.arready = ar_sel ? m_axi_1.arready : m_axi_0.arready;

    // ================================================================
    // AW channel: route based on awaddr[SPLIT_BIT]
    // ================================================================
    logic aw_sel;
    assign aw_sel = s_axi.awaddr[SPLIT_BIT];

    assign m_axi_0.awaddr   = s_axi.awaddr;
    assign m_axi_0.awburst  = s_axi.awburst;
    assign m_axi_0.awcache  = s_axi.awcache;
    assign m_axi_0.awid     = s_axi.awid;
    assign m_axi_0.awlen    = s_axi.awlen;
    assign m_axi_0.awlock   = s_axi.awlock;
    assign m_axi_0.awprot   = s_axi.awprot;
    assign m_axi_0.awqos    = s_axi.awqos;
    assign m_axi_0.awregion = s_axi.awregion;
    assign m_axi_0.awsize   = s_axi.awsize;
    assign m_axi_0.awvalid  = s_axi.awvalid && !aw_sel && !w_route_full;

    assign m_axi_1.awaddr   = s_axi.awaddr;
    assign m_axi_1.awburst  = s_axi.awburst;
    assign m_axi_1.awcache  = s_axi.awcache;
    assign m_axi_1.awid     = s_axi.awid;
    assign m_axi_1.awlen    = s_axi.awlen;
    assign m_axi_1.awlock   = s_axi.awlock;
    assign m_axi_1.awprot   = s_axi.awprot;
    assign m_axi_1.awqos    = s_axi.awqos;
    assign m_axi_1.awregion = s_axi.awregion;
    assign m_axi_1.awsize   = s_axi.awsize;
    assign m_axi_1.awvalid  = s_axi.awvalid && aw_sel && !w_route_full;

    logic aw_accepted;
    assign s_axi.awready = !w_route_full && (aw_sel ? m_axi_1.awready : m_axi_0.awready);
    assign aw_accepted   = s_axi.awvalid && s_axi.awready;

    // ================================================================
    // W route FIFO: tracks which port each AW went to
    // so W data follows the same port
    // ================================================================
    logic                w_route_full;
    logic                w_route_empty;
    logic                w_route_sel;    // current head: 0 or 1
    logic [$clog2(W_ROUTE_DEPTH)-1:0] w_wr_ptr, w_rd_ptr;
    logic [$clog2(W_ROUTE_DEPTH):0]   w_count;
    logic                w_route_mem [W_ROUTE_DEPTH];

    assign w_route_full  = (w_count == W_ROUTE_DEPTH);
    assign w_route_empty = (w_count == 0);
    assign w_route_sel   = w_route_mem[w_rd_ptr];

    // Pop on last W beat accepted
    logic w_pop;
    assign w_pop = !w_route_empty && s_axi.wvalid && s_axi.wlast &&
                   (w_route_sel ? m_axi_1.wready : m_axi_0.wready);

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            w_wr_ptr <= '0;
            w_rd_ptr <= '0;
            w_count  <= '0;
        end else begin
            if (aw_accepted) begin
                w_route_mem[w_wr_ptr] <= aw_sel;
                w_wr_ptr <= w_wr_ptr + 1;
            end
            if (w_pop)
                w_rd_ptr <= w_rd_ptr + 1;

            case ({aw_accepted, w_pop})
                2'b10:   w_count <= w_count + 1;
                2'b01:   w_count <= w_count - 1;
                default: ;
            endcase
        end
    end

    // ================================================================
    // W channel: route based on w_route FIFO head
    // ================================================================
    assign m_axi_0.wdata  = s_axi.wdata;
    assign m_axi_0.wstrb  = s_axi.wstrb;
    assign m_axi_0.wlast  = s_axi.wlast;
    assign m_axi_0.wvalid = !w_route_empty && s_axi.wvalid && !w_route_sel;

    assign m_axi_1.wdata  = s_axi.wdata;
    assign m_axi_1.wstrb  = s_axi.wstrb;
    assign m_axi_1.wlast  = s_axi.wlast;
    assign m_axi_1.wvalid = !w_route_empty && s_axi.wvalid && w_route_sel;

    assign s_axi.wready = !w_route_empty &&
                           (w_route_sel ? m_axi_1.wready : m_axi_0.wready);

    // ================================================================
    // R channel: round-robin arbiter
    // ================================================================
    logic r_last_sel;  // last port that won arbitration

    logic r_sel;
    always_comb begin
        if (m_axi_0.rvalid && m_axi_1.rvalid)
            r_sel = r_last_sel;  // alternate
        else if (m_axi_1.rvalid)
            r_sel = 1'b1;
        else
            r_sel = 1'b0;        // port 0 or neither
    end

    always_ff @(posedge aclk) begin
        if (!aresetn)
            r_last_sel <= 1'b0;
        else if (s_axi.rvalid && s_axi.rready)
            r_last_sel <= !r_sel;  // next time, prefer the other port
    end

    assign s_axi.rdata  = r_sel ? m_axi_1.rdata  : m_axi_0.rdata;
    assign s_axi.rid    = r_sel ? m_axi_1.rid    : m_axi_0.rid;
    assign s_axi.rlast  = r_sel ? m_axi_1.rlast  : m_axi_0.rlast;
    assign s_axi.rresp  = r_sel ? m_axi_1.rresp  : m_axi_0.rresp;
    assign s_axi.rvalid = m_axi_0.rvalid || m_axi_1.rvalid;

    assign m_axi_0.rready = !r_sel && s_axi.rready;
    assign m_axi_1.rready = r_sel  && s_axi.rready;

    // ================================================================
    // B channel: round-robin arbiter
    // ================================================================
    logic b_last_sel;

    logic b_sel;
    always_comb begin
        if (m_axi_0.bvalid && m_axi_1.bvalid)
            b_sel = b_last_sel;
        else if (m_axi_1.bvalid)
            b_sel = 1'b1;
        else
            b_sel = 1'b0;
    end

    always_ff @(posedge aclk) begin
        if (!aresetn)
            b_last_sel <= 1'b0;
        else if (s_axi.bvalid && s_axi.bready)
            b_last_sel <= !b_sel;
    end

    assign s_axi.bid    = b_sel ? m_axi_1.bid    : m_axi_0.bid;
    assign s_axi.bresp  = b_sel ? m_axi_1.bresp  : m_axi_0.bresp;
    assign s_axi.bvalid = m_axi_0.bvalid || m_axi_1.bvalid;

    assign m_axi_0.bready = !b_sel && s_axi.bready;
    assign m_axi_1.bready = b_sel  && s_axi.bready;

endmodule
