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
 * @brief   1:2 AXI4-Lite demultiplexer
 *
 * Routes the slave port to m_axi_0 (addr[SPLIT_BIT] == 0) or m_axi_1
 * (addr[SPLIT_BIT] == 1). One read and one write outstanding at a time.
 */
module nvme_cnfg_axil_split #(
    parameter integer SPLIT_BIT = 14
)(
    input  logic    aclk,
    input  logic    aresetn,

    AXI4L.s         s_axi,
    AXI4L.m         m_axi_0,
    AXI4L.m         m_axi_1
);

// AR / R channels
logic ar_sel;
assign ar_sel = s_axi.araddr[SPLIT_BIT];

logic ar_pending;
logic ar_target;

// AR
assign m_axi_0.araddr  = s_axi.araddr;
assign m_axi_0.arprot  = s_axi.arprot;
assign m_axi_0.arqos   = s_axi.arqos;
assign m_axi_0.arregion= s_axi.arregion;
assign m_axi_0.arvalid = s_axi.arvalid && !ar_sel && !ar_pending;

assign m_axi_1.araddr  = s_axi.araddr;
assign m_axi_1.arprot  = s_axi.arprot;
assign m_axi_1.arqos   = s_axi.arqos;
assign m_axi_1.arregion= s_axi.arregion;
assign m_axi_1.arvalid = s_axi.arvalid && ar_sel && !ar_pending;

assign s_axi.arready = !ar_pending && (ar_sel ? m_axi_1.arready : m_axi_0.arready);

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        ar_pending <= 1'b0;
        ar_target  <= 1'b0;
    end
    else begin
        if (s_axi.arvalid && s_axi.arready) begin
            ar_pending <= 1'b1;
            ar_target  <= ar_sel;
        end
        else if (s_axi.rvalid && s_axi.rready) begin
            ar_pending <= 1'b0;
        end
    end
end

assign s_axi.rdata    = ar_target ? m_axi_1.rdata    : m_axi_0.rdata;
assign s_axi.rresp    = ar_target ? m_axi_1.rresp    : m_axi_0.rresp;
assign s_axi.rvalid   = ar_target ? m_axi_1.rvalid   : m_axi_0.rvalid;
assign m_axi_0.rready = !ar_target && s_axi.rready;
assign m_axi_1.rready =  ar_target && s_axi.rready;

// AW / W / B channels
logic aw_sel;
assign aw_sel = s_axi.awaddr[SPLIT_BIT];

logic aw_pending;
logic w_done;
logic aw_target;

// AW
assign m_axi_0.awaddr   = s_axi.awaddr;
assign m_axi_0.awprot   = s_axi.awprot;
assign m_axi_0.awqos    = s_axi.awqos;
assign m_axi_0.awregion = s_axi.awregion;
assign m_axi_0.awvalid  = s_axi.awvalid && !aw_sel && !aw_pending;

assign m_axi_1.awaddr   = s_axi.awaddr;
assign m_axi_1.awprot   = s_axi.awprot;
assign m_axi_1.awqos    = s_axi.awqos;
assign m_axi_1.awregion = s_axi.awregion;
assign m_axi_1.awvalid  = s_axi.awvalid && aw_sel && !aw_pending;

assign s_axi.awready = !aw_pending && (aw_sel ? m_axi_1.awready : m_axi_0.awready);

// W
logic w_target;
logic w_open;
assign w_target = aw_pending ? aw_target : aw_sel;
assign w_open   = !w_done && (aw_pending || s_axi.awvalid);

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        aw_pending <= 1'b0;
        w_done     <= 1'b0;
        aw_target  <= 1'b0;
    end
    else begin
        if (s_axi.bvalid && s_axi.bready) begin
            aw_pending <= 1'b0;
            w_done     <= 1'b0;
        end
        else begin
            if (s_axi.awvalid && s_axi.awready) begin
                aw_pending <= 1'b1;
                aw_target  <= aw_sel;
            end
            if (s_axi.wvalid && s_axi.wready) begin
                w_done <= 1'b1;
            end
        end
    end
end

assign m_axi_0.wdata  = s_axi.wdata;
assign m_axi_0.wstrb  = s_axi.wstrb;
assign m_axi_0.wvalid = s_axi.wvalid && w_open && !w_target;

assign m_axi_1.wdata  = s_axi.wdata;
assign m_axi_1.wstrb  = s_axi.wstrb;
assign m_axi_1.wvalid = s_axi.wvalid && w_open && w_target;

assign s_axi.wready = w_open && (w_target ? m_axi_1.wready : m_axi_0.wready);

assign s_axi.bresp    = aw_target ? m_axi_1.bresp    : m_axi_0.bresp;
assign s_axi.bvalid   = aw_target ? m_axi_1.bvalid   : m_axi_0.bvalid;
assign m_axi_0.bready = !aw_target && s_axi.bready;
assign m_axi_1.bready =  aw_target && s_axi.bready;

endmodule
