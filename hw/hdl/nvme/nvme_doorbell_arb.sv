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

`include "axi_macros.svh"

import lynxTypes::*;

/**
 * @brief   NVMe doorbell DMA arbiter
 *
 * Merges two DMA write streams (host DMA and NVMe doorbells, or SQ and CQ doorbells)
 * onto a single DMA write channel.
 *
 * Requests are forwarded round-robin as soon as they arrive. As in mmu_arbiter and
 * axis_mux_host_sink, the data follows in request order: each request carries
 * ceil(len / beat size) beats, and tlast marks only the end of a transfer, so one
 * transfer can span several requests (e.g. an RDMA message split by the MMU).
 *
 * Completions (rsp.done) arrive for requests with req.last set, in request order, so the
 * port of each such request is queued and every completion is returned to that port.
 */
module nvme_doorbell_arb (
    input  logic        aclk,
    input  logic        aresetn,

    // Port 0: Host DMA
    dmaIntf.s           s_dma_req_0,
    AXI4S.s             s_axis_0,

    // Port 1: NVMe Doorbell DMA
    dmaIntf.s           s_dma_req_1,
    AXI4S.s             s_axis_1,

    // Output: Merged
    dmaIntf.m           m_dma_req,
    AXI4S.m             m_axis
);

    localparam integer SEQ_DEPTH = 2 * N_OUTSTANDING;
    localparam integer CPL_DEPTH = 64;

    // Data order and completion order, one entry per forwarded request
    metaIntf #(.STYPE(mux_host_t)) seq_in (.*), seq_out (.*);
    logic cpl_in_ready, cpl_out_valid, cpl_out_port;

    // Port of the forwarded request; held while the output waits, so the request stays stable
    logic sel, sel_C, hold_C, rr_C;
    logic fire;

    always_comb begin
        if (hold_C)
            sel = sel_C;
        else if (s_dma_req_0.valid && s_dma_req_1.valid)
            sel = !rr_C;
        else
            sel = s_dma_req_1.valid;
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            hold_C <= 1'b0;
            sel_C  <= 1'b0;
            rr_C   <= 1'b1;
        end else begin
            hold_C <= m_dma_req.valid && !m_dma_req.ready;
            sel_C  <= sel;
            if (fire) rr_C <= sel;
        end
    end

    // Request
    assign m_dma_req.valid   = (sel ? s_dma_req_1.valid : s_dma_req_0.valid) && seq_in.ready && cpl_in_ready;
    assign m_dma_req.req     = sel ? s_dma_req_1.req : s_dma_req_0.req;
    assign s_dma_req_0.ready = !sel && m_dma_req.ready && seq_in.ready && cpl_in_ready;
    assign s_dma_req_1.ready =  sel && m_dma_req.ready && seq_in.ready && cpl_in_ready;
    assign fire              = m_dma_req.valid && m_dma_req.ready;

    // Data sequence
    assign seq_in.valid     = fire;
    assign seq_in.data.vfid = sel;
    assign seq_in.data.len  = (m_dma_req.req.len - 1) >> BEAT_LOG_BITS;
    assign seq_in.data.last = m_dma_req.req.last;

    queue_stream #(
        .QTYPE(mux_host_t),
        .QDEPTH(SEQ_DEPTH)
    ) inst_seq_que (
        .aclk(aclk),
        .aresetn(aresetn),
        .val_snk(seq_in.valid),
        .rdy_snk(seq_in.ready),
        .data_snk(seq_in.data),
        .val_src(seq_out.valid),
        .rdy_src(seq_out.ready),
        .data_src(seq_out.data)
    );

    AXI4S axis_in [2] (.aclk(aclk), .aresetn(aresetn));
    `AXIS_ASSIGN(s_axis_0, axis_in[0])
    `AXIS_ASSIGN(s_axis_1, axis_in[1])

    axis_mux_host_sink #(
        .N_ID(2)
    ) inst_data_mux (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_mux(seq_out),
        .s_axis(axis_in),
        .m_axis(m_axis)
    );

    // Completion sequence
    queue_stream #(
        .QTYPE(logic),
        .QDEPTH(CPL_DEPTH)
    ) inst_cpl_que (
        .aclk(aclk),
        .aresetn(aresetn),
        .val_snk(fire && m_dma_req.req.last),
        .rdy_snk(cpl_in_ready),
        .data_snk(sel),
        .val_src(cpl_out_valid),
        .rdy_src(m_dma_req.rsp.done),
        .data_src(cpl_out_port)
    );

    always_comb begin
        s_dma_req_0.rsp = '0;
        s_dma_req_1.rsp = '0;
        s_dma_req_0.rsp.done = m_dma_req.rsp.done && cpl_out_valid && !cpl_out_port;
        s_dma_req_1.rsp.done = m_dma_req.rsp.done && cpl_out_valid &&  cpl_out_port;
    end

endmodule
