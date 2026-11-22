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
 * @brief   Stream queue in distributed RAM, entries not reset
 */
module axi_stripe_nvme_buf #(
    parameter type QTYPE = logic[63:0],
    parameter integer QDEPTH = 32
) (
    input  logic        aclk,
    input  logic        aresetn,

    input  logic        val_snk,
    output logic        rdy_snk,
    input  QTYPE        data_snk,

    output logic        val_src,
    input  logic        rdy_src,
    output QTYPE        data_src
);

localparam integer PNTR_BITS = $clog2(QDEPTH);

(* ram_style = "distributed" *) logic [$bits(QTYPE)-1:0] mem [QDEPTH];

logic [PNTR_BITS-1:0]   wr_pntr, rd_pntr;
logic [PNTR_BITS:0]     n_entries;
logic                   wr, rd;

assign rdy_snk = (n_entries != QDEPTH);
assign val_src = (n_entries != 0);

assign wr = val_snk && rdy_snk;
assign rd = val_src && rdy_src;

always_ff @(posedge aclk) begin
    if (wr)
        mem[wr_pntr] <= data_snk;
end

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        wr_pntr   <= '0;
        rd_pntr   <= '0;
        n_entries <= '0;
    end
    else begin
        if (wr)
            wr_pntr <= wr_pntr + 1;
        if (rd)
            rd_pntr <= rd_pntr + 1;

        if (wr && !rd)
            n_entries <= n_entries + 1;
        else if (rd && !wr)
            n_entries <= n_entries - 1;
    end
end

assign data_src = mem[rd_pntr];

endmodule
