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
 * @brief   NVMe HBM stripe mapper over several memory channels
 *
 * Fragment f to channel f mod N_CHAN.
 */
module axi_stripe_nvme_multi #(
    parameter integer N_STAGES = 1,
    parameter integer N_CHAN = 2
) (
    input  logic        aclk,
    input  logic        aresetn,

    AXI4.s              s_axi,
    AXI4.m              m_axi [N_CHAN]
);

localparam integer N_CHAN_BITS   = clog2s(N_CHAN);
localparam integer BEAT_LOG_BITS = $clog2(AXI_DATA_BITS / 8);
localparam integer FRAG_LOG_BITS = $clog2(STRIPE_FRAG_SIZE);
localparam integer FRAG_BEATS    = STRIPE_FRAG_SIZE >> BEAT_LOG_BITS;
localparam integer MAX_BEATS     = (FRAG_BEATS < 256) ? FRAG_BEATS : 256;
localparam integer N_FRAG_OUTS   = 2 * N_OUTSTANDING;
localparam integer ORD_DEPTH     = N_CHAN * N_FRAG_OUTS;
localparam integer WR_BUF_BEATS  = (MAX_BEATS > 32) ? MAX_BEATS : 32;
localparam integer RD_BUF_BEATS  = (MAX_BEATS > 64) ? MAX_BEATS : 64;
localparam integer OUTS_BITS     = $clog2(N_FRAG_OUTS) + 1;
localparam integer CRED_BITS     = $clog2(RD_BUF_BEATS) + 1;

localparam logic [AXI_ADDR_BITS-1:0] MEM_BASE  = MEM_OFFSET;
localparam logic [AXI_ADDR_BITS-1:0] FRAG_MASK = STRIPE_FRAG_SIZE - 1;

typedef struct packed {
    logic [AXI_ID_BITS-1:0]     id;
    logic [1:0]                 burst;
    logic [3:0]                 cache;
    logic [0:0]                 lock;
    logic [2:0]                 prot;
    logic [3:0]                 qos;
    logic [3:0]                 region;
    logic [2:0]                 size;
} side_t;

// Order
typedef struct packed {
    logic [N_CHAN_BITS-1:0]     chan;
    logic                       last;
    logic [AXI_ID_BITS-1:0]     id;
} ord_t;

// W route
typedef struct packed {
    logic [N_CHAN_BITS-1:0]     chan;
    logic [7:0]                 len;
} route_t;

typedef struct packed {
    logic [AXI_DATA_BITS-1:0]   data;
    logic [AXI_DATA_BITS/8-1:0] strb;
    logic                       last;
} wr_beat_t;

typedef struct packed {
    logic [AXI_DATA_BITS-1:0]   data;
    logic [1:0]                 resp;
    logic                       last;
} rd_beat_t;

// Stripe address
function automatic logic [AXI_ADDR_BITS-1:0] stripe_addr(
    input logic [AXI_ADDR_BITS-1:0] addr
);
    logic [AXI_ADDR_BITS-1:0] rel;
    logic [AXI_ADDR_BITS-1:0] frag;
    begin
        rel  = addr - MEM_BASE;
        frag = rel >> FRAG_LOG_BITS;

        stripe_addr = MEM_BASE
                    + ((frag & AXI_ADDR_BITS'(N_STRIPE_CHAN - 1)) << MC_SIZE)
                    + ((frag >> N_STRIPE_CHAN_BITS) << FRAG_LOG_BITS)
                    + (rel & FRAG_MASK);
    end
endfunction

// Channel
function automatic logic [N_CHAN_BITS-1:0] frag_chan(
    input logic [AXI_ADDR_BITS-1:0] addr
);
    logic [AXI_ADDR_BITS-1:0] frag;
    begin
        frag      = (addr - MEM_BASE) >> FRAG_LOG_BITS;
        frag_chan = N_CHAN_BITS'(frag & AXI_ADDR_BITS'(N_CHAN - 1));
    end
endfunction

// Fragment length
function automatic logic [8:0] frag_len(
    input logic [AXI_ADDR_BITS-1:0] addr,
    input logic [8:0]               left
);
    logic [AXI_ADDR_BITS-1:0] room;
    begin
        room     = AXI_ADDR_BITS'(FRAG_BEATS) - (((addr - MEM_BASE) & FRAG_MASK) >> BEAT_LOG_BITS);
        frag_len = (AXI_ADDR_BITS'(left) < room) ? left : room[8:0];
    end
endfunction

// Next fragment
function automatic logic [AXI_ADDR_BITS-1:0] frag_next(
    input logic [AXI_ADDR_BITS-1:0] addr,
    input logic [8:0]               beats
);
    frag_next = {addr[AXI_ADDR_BITS-1:BEAT_LOG_BITS] + beats, {BEAT_LOG_BITS{1'b0}}};
endfunction

// -----------------------------------------------------------------------------------------------------------------------
// Register slices
// -----------------------------------------------------------------------------------------------------------------------
AXI4 s_axi_int ();
AXI4 m_axi_int [N_CHAN] ();

axi_reg_array #(.N_STAGES(N_STAGES)) inst_s_reg_arr (.aclk(aclk), .aresetn(aresetn), .s_axi(s_axi), .m_axi(s_axi_int));

for (genvar i = 0; i < N_CHAN; i++) begin : gen_m_reg
    axi_reg_array #(.N_STAGES(N_STAGES)) inst_m_reg_arr (.aclk(aclk), .aresetn(aresetn), .s_axi(m_axi_int[i]), .m_axi(m_axi[i]));
end

// -----------------------------------------------------------------------------------------------------------------------
// READS
// -----------------------------------------------------------------------------------------------------------------------

// Split
logic                       rd_act;
logic [AXI_ADDR_BITS-1:0]   rd_addr;
logic [8:0]                 rd_left;
side_t                      rd_side;

logic [N_CHAN_BITS-1:0]     rd_chan;
logic [8:0]                 rd_beats;
logic                       rd_issue, rd_fire;

logic [N_CHAN-1:0]          m_arready;

// Read credits
logic [CRED_BITS-1:0]       rd_cred [N_CHAN];

logic [N_CHAN-1:0]          rd_buf_valid, rd_buf_pop;
rd_beat_t                   rd_buf_in [N_CHAN];
rd_beat_t                   rd_buf_out [N_CHAN];

logic                       rd_ord_ready, rd_ord_valid, rd_ord_pop;
ord_t                       rd_ord_in, rd_ord_out;
logic                       rd_beat_fire;

assign rd_chan  = frag_chan(rd_addr);
assign rd_beats = frag_len(rd_addr, rd_left);

// Issue
assign rd_issue = rd_act && rd_ord_ready && (rd_cred[rd_chan] >= rd_beats);
assign rd_fire  = rd_issue && m_arready[rd_chan];

assign s_axi_int.arready = !rd_act;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        rd_act  <= 1'b0;
        rd_addr <= '0;
        rd_left <= '0;
        rd_side <= '0;
    end
    else begin
        if (s_axi_int.arvalid && s_axi_int.arready) begin
            rd_act  <= 1'b1;
            rd_addr <= s_axi_int.araddr;
            rd_left <= {1'b0, s_axi_int.arlen} + 1;
            rd_side <= '{id: s_axi_int.arid, burst: s_axi_int.arburst, cache: s_axi_int.arcache, lock: s_axi_int.arlock,
                         prot: s_axi_int.arprot, qos: s_axi_int.arqos, region: s_axi_int.arregion, size: s_axi_int.arsize};
        end
        else if (rd_fire) begin
            rd_act  <= (rd_beats != rd_left);
            rd_addr <= frag_next(rd_addr, rd_beats);
            rd_left <= rd_left - rd_beats;
        end
    end
end

assign rd_ord_in.chan = rd_chan;
assign rd_ord_in.last = (rd_beats == rd_left);
assign rd_ord_in.id   = rd_side.id;

queue_stream #(
    .QTYPE(ord_t),
    .QDEPTH(ORD_DEPTH)
) inst_rd_ord_que (
    .aclk(aclk),
    .aresetn(aresetn),
    .val_snk(rd_fire),
    .rdy_snk(rd_ord_ready),
    .data_snk(rd_ord_in),
    .val_src(rd_ord_valid),
    .rdy_src(rd_ord_pop),
    .data_src(rd_ord_out)
);

for (genvar i = 0; i < N_CHAN; i++) begin : gen_rd
    assign m_axi_int[i].araddr   = stripe_addr(rd_addr);
    assign m_axi_int[i].arburst  = rd_side.burst;
    assign m_axi_int[i].arcache  = rd_side.cache;
    assign m_axi_int[i].arid     = '0;
    assign m_axi_int[i].arlen    = rd_beats[7:0] - 1;
    assign m_axi_int[i].arlock   = rd_side.lock;
    assign m_axi_int[i].arprot   = rd_side.prot;
    assign m_axi_int[i].arqos    = rd_side.qos;
    assign m_axi_int[i].arregion = rd_side.region;
    assign m_axi_int[i].arsize   = rd_side.size;
    assign m_axi_int[i].arvalid  = rd_issue && (rd_chan == i);
    assign m_arready[i]          = m_axi_int[i].arready;

    always_ff @(posedge aclk) begin
        if (!aresetn)
            rd_cred[i] <= RD_BUF_BEATS;
        else
            rd_cred[i] <= rd_cred[i] - ((rd_fire && (rd_chan == i)) ? rd_beats : 0) + rd_buf_pop[i];
    end

    assign rd_buf_in[i].data = m_axi_int[i].rdata;
    assign rd_buf_in[i].resp = m_axi_int[i].rresp;
    assign rd_buf_in[i].last = m_axi_int[i].rlast;

    axi_stripe_nvme_buf #(
        .QTYPE(rd_beat_t),
        .QDEPTH(RD_BUF_BEATS)
    ) inst_rd_buf (
        .aclk(aclk),
        .aresetn(aresetn),
        .val_snk(m_axi_int[i].rvalid),
        .rdy_snk(m_axi_int[i].rready),
        .data_snk(rd_buf_in[i]),
        .val_src(rd_buf_valid[i]),
        .rdy_src(rd_buf_pop[i]),
        .data_src(rd_buf_out[i])
    );

    assign rd_buf_pop[i] = rd_beat_fire && (rd_ord_out.chan == i);
end

// R
assign s_axi_int.rvalid = rd_ord_valid && rd_buf_valid[rd_ord_out.chan];
assign s_axi_int.rdata  = rd_buf_out[rd_ord_out.chan].data;
assign s_axi_int.rresp  = rd_buf_out[rd_ord_out.chan].resp;
assign s_axi_int.rid    = rd_ord_out.id;
assign s_axi_int.rlast  = rd_buf_out[rd_ord_out.chan].last && rd_ord_out.last;

assign rd_beat_fire = s_axi_int.rvalid && s_axi_int.rready;
assign rd_ord_pop   = rd_beat_fire && rd_buf_out[rd_ord_out.chan].last;

// -----------------------------------------------------------------------------------------------------------------------
// WRITES
// -----------------------------------------------------------------------------------------------------------------------

// Split
logic                       wr_act;
logic [AXI_ADDR_BITS-1:0]   wr_addr;
logic [8:0]                 wr_left;
side_t                      wr_side;

logic [N_CHAN_BITS-1:0]     wr_chan;
logic [8:0]                 wr_beats;
logic                       wr_issue, wr_fire;

logic [N_CHAN-1:0]          m_awready;

// Outstanding writes
logic [OUTS_BITS-1:0]       wr_outs [N_CHAN];

logic                       wr_route_ready, wr_route_valid, wr_route_pop;
route_t                     wr_route_in, wr_route_out;
logic [7:0]                 wr_cnt;
logic                       wr_last, wr_beat_fire;

logic [N_CHAN-1:0]          wr_buf_ready;
wr_beat_t                   wr_buf_in;
wr_beat_t                   wr_buf_out [N_CHAN];

logic                       wr_ord_ready, wr_ord_valid, wr_ord_pop;
ord_t                       wr_ord_in, wr_ord_out;

logic [N_CHAN-1:0]          b_que_valid, b_que_pop;
logic [1:0]                 b_que_resp [N_CHAN];
logic [1:0]                 b_resp, b_resp_acc;

assign wr_chan  = frag_chan(wr_addr);
assign wr_beats = frag_len(wr_addr, wr_left);

// Issue
assign wr_issue = wr_act && wr_route_ready && wr_ord_ready && (wr_outs[wr_chan] < N_FRAG_OUTS);
assign wr_fire  = wr_issue && m_awready[wr_chan];

assign s_axi_int.awready = !wr_act;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        wr_act  <= 1'b0;
        wr_addr <= '0;
        wr_left <= '0;
        wr_side <= '0;
    end
    else begin
        if (s_axi_int.awvalid && s_axi_int.awready) begin
            wr_act  <= 1'b1;
            wr_addr <= s_axi_int.awaddr;
            wr_left <= {1'b0, s_axi_int.awlen} + 1;
            wr_side <= '{id: s_axi_int.awid, burst: s_axi_int.awburst, cache: s_axi_int.awcache, lock: s_axi_int.awlock,
                         prot: s_axi_int.awprot, qos: s_axi_int.awqos, region: s_axi_int.awregion, size: s_axi_int.awsize};
        end
        else if (wr_fire) begin
            wr_act  <= (wr_beats != wr_left);
            wr_addr <= frag_next(wr_addr, wr_beats);
            wr_left <= wr_left - wr_beats;
        end
    end
end

assign wr_route_in.chan = wr_chan;
assign wr_route_in.len  = wr_beats[7:0] - 1;

queue_stream #(
    .QTYPE(route_t),
    .QDEPTH(ORD_DEPTH)
) inst_wr_route_que (
    .aclk(aclk),
    .aresetn(aresetn),
    .val_snk(wr_fire),
    .rdy_snk(wr_route_ready),
    .data_snk(wr_route_in),
    .val_src(wr_route_valid),
    .rdy_src(wr_route_pop),
    .data_src(wr_route_out)
);

assign wr_ord_in.chan = wr_chan;
assign wr_ord_in.last = (wr_beats == wr_left);
assign wr_ord_in.id   = wr_side.id;

queue_stream #(
    .QTYPE(ord_t),
    .QDEPTH(ORD_DEPTH)
) inst_wr_ord_que (
    .aclk(aclk),
    .aresetn(aresetn),
    .val_snk(wr_fire),
    .rdy_snk(wr_ord_ready),
    .data_snk(wr_ord_in),
    .val_src(wr_ord_valid),
    .rdy_src(wr_ord_pop),
    .data_src(wr_ord_out)
);

// W
assign wr_last            = (wr_cnt == wr_route_out.len);
assign s_axi_int.wready   = wr_route_valid && wr_buf_ready[wr_route_out.chan];
assign wr_beat_fire       = s_axi_int.wvalid && s_axi_int.wready;
assign wr_route_pop       = wr_beat_fire && wr_last;

assign wr_buf_in.data     = s_axi_int.wdata;
assign wr_buf_in.strb     = s_axi_int.wstrb;
assign wr_buf_in.last     = wr_last;

always_ff @(posedge aclk) begin
    if (!aresetn)
        wr_cnt <= '0;
    else if (wr_beat_fire)
        wr_cnt <= wr_last ? '0 : wr_cnt + 1;
end

for (genvar i = 0; i < N_CHAN; i++) begin : gen_wr
    assign m_axi_int[i].awaddr   = stripe_addr(wr_addr);
    assign m_axi_int[i].awburst  = wr_side.burst;
    assign m_axi_int[i].awcache  = wr_side.cache;
    assign m_axi_int[i].awid     = '0;
    assign m_axi_int[i].awlen    = wr_beats[7:0] - 1;
    assign m_axi_int[i].awlock   = wr_side.lock;
    assign m_axi_int[i].awprot   = wr_side.prot;
    assign m_axi_int[i].awqos    = wr_side.qos;
    assign m_axi_int[i].awregion = wr_side.region;
    assign m_axi_int[i].awsize   = wr_side.size;
    assign m_axi_int[i].awvalid  = wr_issue && (wr_chan == i);
    assign m_awready[i]          = m_axi_int[i].awready;

    always_ff @(posedge aclk) begin
        if (!aresetn)
            wr_outs[i] <= '0;
        else
            wr_outs[i] <= wr_outs[i] + (wr_fire && (wr_chan == i)) - b_que_pop[i];
    end

    // W buffer
    axi_stripe_nvme_buf #(
        .QTYPE(wr_beat_t),
        .QDEPTH(WR_BUF_BEATS)
    ) inst_wr_buf (
        .aclk(aclk),
        .aresetn(aresetn),
        .val_snk(s_axi_int.wvalid && wr_route_valid && (wr_route_out.chan == i)),
        .rdy_snk(wr_buf_ready[i]),
        .data_snk(wr_buf_in),
        .val_src(m_axi_int[i].wvalid),
        .rdy_src(m_axi_int[i].wready),
        .data_src(wr_buf_out[i])
    );

    assign m_axi_int[i].wdata = wr_buf_out[i].data;
    assign m_axi_int[i].wstrb = wr_buf_out[i].strb;
    assign m_axi_int[i].wlast = wr_buf_out[i].last;

    queue_stream #(
        .QTYPE(logic[1:0]),
        .QDEPTH(N_FRAG_OUTS)
    ) inst_b_que (
        .aclk(aclk),
        .aresetn(aresetn),
        .val_snk(m_axi_int[i].bvalid),
        .rdy_snk(m_axi_int[i].bready),
        .data_snk(m_axi_int[i].bresp),
        .val_src(b_que_valid[i]),
        .rdy_src(b_que_pop[i]),
        .data_src(b_que_resp[i])
    );

    assign b_que_pop[i] = wr_ord_pop && (wr_ord_out.chan == i);
end

// B
assign b_resp = (b_que_resp[wr_ord_out.chan] > b_resp_acc) ? b_que_resp[wr_ord_out.chan] : b_resp_acc;

assign s_axi_int.bvalid = wr_ord_valid && b_que_valid[wr_ord_out.chan] && wr_ord_out.last;
assign s_axi_int.bresp  = b_resp;
assign s_axi_int.bid    = wr_ord_out.id;

assign wr_ord_pop = wr_ord_valid && b_que_valid[wr_ord_out.chan] && (!wr_ord_out.last || s_axi_int.bready);

always_ff @(posedge aclk) begin
    if (!aresetn)
        b_resp_acc <= '0;
    else if (wr_ord_pop)
        b_resp_acc <= wr_ord_out.last ? '0 : b_resp;
end

endmodule
