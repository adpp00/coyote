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
 * @brief   NVMe doorbell DMA arbiter
 *
 * Merges the SQ and CQ doorbell DMA streams onto a single DMA write channel.
 */
module nvme_doorbell_arb (
    input  logic        aclk,
    input  logic        aresetn,

    // Port 0: Host DMA (higher priority in tie)
    dmaIntf.s           s_dma_req_0,
    AXI4S.s             s_axis_0,

    // Port 1: NVMe Doorbell DMA
    dmaIntf.s           s_dma_req_1,
    AXI4S.s             s_axis_1,

    // Output: Merged
    dmaIntf.m           m_dma_req,
    AXI4S.m             m_axis
);

    // State machine

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_GRANT_0_REQ,
        ST_GRANT_0_DATA,
        ST_GRANT_1_REQ,
        ST_GRANT_1_DATA
    } state_t;

    state_t state_C, state_N;

    // Last grant for round-robin (0 = port 0 was last, 1 = port 1 was last)
    logic last_grant_C, last_grant_N;

    // State machine transitions

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            state_C <= ST_IDLE;
            last_grant_C <= 1'b0;
        end else begin
            state_C <= state_N;
            last_grant_C <= last_grant_N;
        end
    end

    // Next state logic

    always_comb begin
        state_N = state_C;
        last_grant_N = last_grant_C;

        case (state_C)
            ST_IDLE: begin
                // Round-robin arbitration
                if (last_grant_C == 1'b1) begin
                    // Last was port 1, check port 0 first
                    if (s_dma_req_0.valid) begin
                        state_N = ST_GRANT_0_REQ;
                    end else if (s_dma_req_1.valid) begin
                        state_N = ST_GRANT_1_REQ;
                    end
                end else begin
                    // Last was port 0, check port 1 first
                    if (s_dma_req_1.valid) begin
                        state_N = ST_GRANT_1_REQ;
                    end else if (s_dma_req_0.valid) begin
                        state_N = ST_GRANT_0_REQ;
                    end
                end
            end

            ST_GRANT_0_REQ: begin
                if (m_dma_req.valid && m_dma_req.ready) begin
                    state_N = ST_GRANT_0_DATA;
                end
            end

            ST_GRANT_1_REQ: begin
                if (m_dma_req.valid && m_dma_req.ready) begin
                    state_N = ST_GRANT_1_DATA;
                end
            end

            ST_GRANT_0_DATA: begin
                if (m_axis.tvalid && m_axis.tready && m_axis.tlast) begin
                    last_grant_N = 1'b0;
                    state_N = ST_IDLE;
                end
            end

            ST_GRANT_1_DATA: begin
                if (m_axis.tvalid && m_axis.tready && m_axis.tlast) begin
                    last_grant_N = 1'b1;
                    state_N = ST_IDLE;
                end
            end

            default: begin
                state_N = ST_IDLE;
            end
        endcase
    end

    // Output muxing - DMA Request
    // READY depends on the registered grant and downstream READY only.
    // Keep it outside payload muxing to avoid combinational handshake feedback.
    assign s_dma_req_0.ready = (state_C == ST_GRANT_0_REQ) && m_dma_req.ready;
    assign s_dma_req_1.ready = (state_C == ST_GRANT_1_REQ) && m_dma_req.ready;
    assign s_axis_0.tready = (state_C == ST_GRANT_0_DATA) && m_axis.tready;
    assign s_axis_1.tready = (state_C == ST_GRANT_1_DATA) && m_axis.tready;

    always_comb begin
        // Default: tie-off
        m_dma_req.valid = 1'b0;
        m_dma_req.req = '0;

        case (state_C)
            ST_GRANT_0_REQ: begin
                m_dma_req.valid = s_dma_req_0.valid;
                m_dma_req.req = s_dma_req_0.req;
            end

            ST_GRANT_1_REQ: begin
                m_dma_req.valid = s_dma_req_1.valid;
                m_dma_req.req = s_dma_req_1.req;
            end

            default: begin
                // Keep defaults
            end
        endcase
    end

    // DMA response routing
    always_comb begin
        s_dma_req_0.rsp = '0;
        s_dma_req_1.rsp = '0;

        case (state_C)
            ST_GRANT_0_REQ, ST_GRANT_0_DATA: begin
                s_dma_req_0.rsp = m_dma_req.rsp;
            end

            ST_GRANT_1_REQ, ST_GRANT_1_DATA: begin
                s_dma_req_1.rsp = m_dma_req.rsp;
            end

            default: begin
                // Keep defaults
            end
        endcase
    end

    // Output muxing - AXI4S Data

    always_comb begin
        // Default: tie-off
        m_axis.tvalid = 1'b0;
        m_axis.tdata = '0;
        m_axis.tkeep = '0;
        m_axis.tlast = 1'b0;

        case (state_C)
            ST_GRANT_0_DATA: begin
                m_axis.tvalid = s_axis_0.tvalid;
                m_axis.tdata = s_axis_0.tdata;
                m_axis.tkeep = s_axis_0.tkeep;
                m_axis.tlast = s_axis_0.tlast;
            end

            ST_GRANT_1_DATA: begin
                m_axis.tvalid = s_axis_1.tvalid;
                m_axis.tdata = s_axis_1.tdata;
                m_axis.tkeep = s_axis_1.tkeep;
                m_axis.tlast = s_axis_1.tlast;
            end

            default: begin
                // Keep defaults
            end
        endcase
    end

endmodule
