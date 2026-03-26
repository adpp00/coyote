/**
 * NVMe SSD Bandwidth Test (multi-device concurrent)
 *
 * Two-phase approach:
 *   FILL:   round-robin, send max_outstanding commands per device
 *   STEADY: completion-driven — on CQE for dev X, send next cmd to dev X
 *   DRAIN:  wait for remaining completions
 *
 * No priority scan. Completion dev_id directly drives next send.
 * Assumes dev_ids are 0..BENCH_MAX_DEVS-1.
 */

import lynxTypes::*;

localparam int BENCH_MAX_DEVS = 4;

///////////////////////////////////////
//      BENCHMARK CONTROL BITS      //
/////////////////////////////////////
logic [1:0] bench_ctrl;
parameter integer START_RD = 0;
parameter integer START_WR = 1;

///////////////////////////////////////
//     PARAMETERS FROM SW           //
/////////////////////////////////////
logic [VADDR_BITS-1:0] bench_vaddr;
logic [31:0]           bench_chunk_size;
logic [31:0]           bench_n_reps;        // per device
logic [63:0]           bench_lba;
logic [15:0]           bench_dev_mask;
logic [63:0]           bench_nsid;
logic [31:0]           bench_max_outstanding; // per device

///////////////////////////////////////
//     BENCHMARK STATUS (to SW)     //
/////////////////////////////////////
logic [31:0] bench_sent;     // total across all devices
logic [31:0] bench_done;     // total across all devices
logic [63:0] bench_timer;
logic [15:0] last_error;

///////////////////////////////////////
//      LATCHED PARAMETERS          //
/////////////////////////////////////
logic [VADDR_BITS-1:0]  latch_vaddr;
logic [63:0]            latch_lba;
logic [31:0]            latch_chunk_size;
logic [31:0]            latch_n_reps;
logic [31:0]            latch_max_outstanding;
logic                   latch_is_write;
logic [BENCH_MAX_DEVS-1:0] latch_dev_mask;
logic [NSID_BITS-1:0]   latch_nsid;

///////////////////////////////////////
//     PER-DEVICE STATE             //
/////////////////////////////////////
logic [VADDR_BITS-1:0]  dev_vaddr  [BENCH_MAX_DEVS];
logic [63:0]            dev_offset [BENCH_MAX_DEVS];
logic [31:0]            dev_sent   [BENCH_MAX_DEVS];
logic [31:0]            dev_done   [BENCH_MAX_DEVS];

///////////////////////////////////////
//           FSM                    //
/////////////////////////////////////
typedef enum logic [2:0] {
    ST_IDLE,
    ST_FILL,
    ST_STEADY,
    ST_DRAIN
} state_t;

state_t state_C;

// NVMe request
logic           nvme_req_valid;
nvme_user_req_t nvme_req;

// FILL phase: round-robin index and per-device fill count
logic [$clog2(BENCH_MAX_DEVS)-1:0] fill_dev;
logic [31:0]                         fill_count [BENCH_MAX_DEVS];

// STEADY phase: completion-driven send
logic                                cpl_send_pending;
logic [N_NVME_BITS-1:0]             cpl_send_dev;

///////////////////////////////////////
//   COMBINATIONAL: aggregate       //
/////////////////////////////////////
always_comb begin
    bench_sent = '0;
    bench_done = '0;
    for (int d = 0; d < BENCH_MAX_DEVS; d++) begin
        if (latch_dev_mask[d]) begin
            bench_sent = bench_sent + dev_sent[d];
            bench_done = bench_done + dev_done[d];
        end
    end
end

///////////////////////////////////////
//   COMBINATIONAL: all done/sent   //
/////////////////////////////////////
logic all_devs_done;
logic all_devs_sent;

always_comb begin
    all_devs_done = 1'b1;
    all_devs_sent = 1'b1;
    for (int d = 0; d < BENCH_MAX_DEVS; d++) begin
        if (latch_dev_mask[d]) begin
            if (dev_done[d] < latch_n_reps) all_devs_done = 1'b0;
            if (dev_sent[d] < latch_n_reps) all_devs_sent = 1'b0;
        end
    end
end

///////////////////////////////////////
//   COMBINATIONAL: fill done check //
/////////////////////////////////////
logic fill_done;
always_comb begin
    fill_done = 1'b1;
    for (int d = 0; d < BENCH_MAX_DEVS; d++) begin
        if (latch_dev_mask[d] && fill_count[d] < latch_max_outstanding)
            fill_done = 1'b0;
    end
end

///////////////////////////////////////
//   COMBINATIONAL: next fill dev   //
/////////////////////////////////////
// Advance fill_dev to next active device (simple wrap)
logic [$clog2(BENCH_MAX_DEVS)-1:0] fill_dev_next;
always_comb begin
    fill_dev_next = fill_dev + 1;
end

///////////////////////////////////////
//     AXI CONTROL PARSER           //
/////////////////////////////////////
perf_nvme_axi_ctrl_parser inst_axi_ctrl_parser (
    .aclk(aclk),
    .aresetn(aresetn),
    .axi_ctrl(axi_ctrl),
    .bench_ctrl(bench_ctrl),
    .bench_vaddr(bench_vaddr),
    .bench_chunk_size(bench_chunk_size),
    .bench_n_reps(bench_n_reps),
    .bench_lba(bench_lba),
    .bench_dev_mask(bench_dev_mask),
    .bench_nsid(bench_nsid),
    .bench_max_outstanding(bench_max_outstanding),
    .bench_sent(bench_sent),
    .bench_done(bench_done),
    .bench_timer(bench_timer),
    .last_error(last_error)
);

///////////////////////////////////////
//     FSM SEQUENTIAL LOGIC         //
/////////////////////////////////////
always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        state_C          <= ST_IDLE;
        nvme_req_valid   <= 1'b0;
        nvme_req         <= '0;
        last_error       <= 16'd0;
        bench_timer      <= '0;
        fill_dev         <= '0;
        cpl_send_pending <= 1'b0;
        cpl_send_dev     <= '0;

        latch_vaddr           <= '0;
        latch_lba             <= '0;
        latch_chunk_size      <= '0;
        latch_n_reps          <= '0;
        latch_max_outstanding <= '0;
        latch_is_write        <= 1'b0;
        latch_dev_mask        <= '0;
        latch_nsid            <= '0;

        for (int d = 0; d < BENCH_MAX_DEVS; d++) begin
            dev_vaddr[d]  <= '0;
            dev_offset[d] <= '0;
            dev_sent[d]   <= '0;
            dev_done[d]   <= '0;
            fill_count[d] <= '0;
        end
    end
    else begin
        // Clear request valid after accepted
        if (nvme_req_valid && m_nvme_cmd_req.ready)
            nvme_req_valid <= 1'b0;

        // === Completion path (all active states) ===
        if (state_C != ST_IDLE && s_nvme_cpl.valid && s_nvme_cpl.ready) begin
            dev_done[s_nvme_cpl.data.dev_id[$clog2(BENCH_MAX_DEVS)-1:0]]
                <= dev_done[s_nvme_cpl.data.dev_id[$clog2(BENCH_MAX_DEVS)-1:0]] + 1;
        end

        if (state_C != ST_IDLE && s_nvme_cmd_rsp.valid && s_nvme_cmd_rsp.data[15:0] != 16'h0000)
            last_error <= s_nvme_cmd_rsp.data[15:0];

        case (state_C)
            // --------------------------------------------------------
            ST_IDLE: begin
                if (bench_ctrl[START_RD] || bench_ctrl[START_WR]) begin
                    latch_vaddr           <= bench_vaddr;
                    latch_lba             <= bench_lba;
                    latch_chunk_size      <= bench_chunk_size;
                    latch_n_reps          <= bench_n_reps;
                    latch_max_outstanding <= bench_max_outstanding;
                    latch_is_write        <= bench_ctrl[START_WR];
                    latch_dev_mask        <= bench_dev_mask[BENCH_MAX_DEVS-1:0];
                    latch_nsid            <= bench_nsid[NSID_BITS-1:0];
                    last_error            <= 16'd0;
                    bench_timer           <= '0;
                    fill_dev              <= '0;
                    cpl_send_pending      <= 1'b0;

                    for (int d = 0; d < BENCH_MAX_DEVS; d++) begin
                        dev_vaddr[d]  <= bench_vaddr;
                        dev_offset[d] <= bench_lba;
                        dev_sent[d]   <= '0;
                        dev_done[d]   <= '0;
                        fill_count[d] <= '0;
                    end

                    state_C <= ST_FILL;
                end
            end

            // --------------------------------------------------------
            // ST_FILL: round-robin, send max_outstanding per device
            // --------------------------------------------------------
            ST_FILL: begin
                bench_timer <= bench_timer + 1;

                if (fill_done) begin
                    state_C <= ST_STEADY;
                end
                else if (!nvme_req_valid) begin
                    // Skip inactive devices
                    if (latch_dev_mask[fill_dev] &&
                        fill_count[fill_dev] < latch_max_outstanding &&
                        dev_sent[fill_dev] < latch_n_reps) begin

                        nvme_req.dev_id    <= fill_dev;
                        nvme_req.writeRead <= latch_is_write;
                        nvme_req.nsid      <= latch_nsid;
                        nvme_req.vaddr     <= dev_vaddr[fill_dev];
                        nvme_req.len       <= latch_chunk_size;
                        nvme_req.naddr     <= dev_offset[fill_dev];
                        nvme_req.region_id <= '0;
                        nvme_req_valid     <= 1'b1;

                        dev_vaddr[fill_dev]  <= dev_vaddr[fill_dev] + latch_chunk_size;
                        dev_offset[fill_dev] <= dev_offset[fill_dev] + latch_chunk_size;
                        dev_sent[fill_dev]   <= dev_sent[fill_dev] + 1;
                        fill_count[fill_dev] <= fill_count[fill_dev] + 1;
                    end
                    fill_dev <= fill_dev_next;
                end
            end

            // --------------------------------------------------------
            // ST_STEADY: completion-driven sends
            // --------------------------------------------------------
            ST_STEADY: begin
                bench_timer <= bench_timer + 1;

                // Completion triggers next send
                if (s_nvme_cpl.valid && s_nvme_cpl.ready) begin
                    automatic logic [$clog2(BENCH_MAX_DEVS)-1:0] cid =
                        s_nvme_cpl.data.dev_id[$clog2(BENCH_MAX_DEVS)-1:0];
                    if (dev_sent[cid] < latch_n_reps) begin
                        cpl_send_pending <= 1'b1;
                        cpl_send_dev     <= s_nvme_cpl.data.dev_id;
                    end
                end

                // Issue command from completion-driven queue
                if (cpl_send_pending && !nvme_req_valid) begin
                    automatic logic [$clog2(BENCH_MAX_DEVS)-1:0] sid =
                        cpl_send_dev[$clog2(BENCH_MAX_DEVS)-1:0];

                    nvme_req.dev_id    <= cpl_send_dev;
                    nvme_req.writeRead <= latch_is_write;
                    nvme_req.nsid      <= latch_nsid;
                    nvme_req.vaddr     <= dev_vaddr[sid];
                    nvme_req.len       <= latch_chunk_size;
                    nvme_req.naddr     <= dev_offset[sid];
                    nvme_req.region_id <= '0;
                    nvme_req_valid     <= 1'b1;

                    dev_vaddr[sid]  <= dev_vaddr[sid] + latch_chunk_size;
                    dev_offset[sid] <= dev_offset[sid] + latch_chunk_size;
                    dev_sent[sid]   <= dev_sent[sid] + 1;

                    cpl_send_pending <= 1'b0;
                end

                // All sent → drain
                if (all_devs_sent && !nvme_req_valid && !cpl_send_pending)
                    state_C <= ST_DRAIN;
            end

            // --------------------------------------------------------
            // ST_DRAIN: wait for remaining completions
            // --------------------------------------------------------
            ST_DRAIN: begin
                if (!all_devs_done)
                    bench_timer <= bench_timer + 1;
                if (all_devs_done)
                    state_C <= ST_IDLE;
            end

            default: state_C <= ST_IDLE;
        endcase
    end
end

///////////////////////////////////////
//    COMBINATIONAL OUTPUTS         //
/////////////////////////////////////
always_comb begin
    m_nvme_cmd_req.valid = nvme_req_valid;
    m_nvme_cmd_req.data  = nvme_req;

    s_nvme_cmd_rsp.ready = 1'b1;

    // Backpressure CQ: don't accept if pending send not yet issued
    // (prevents losing completion-driven send requests)
    if (state_C == ST_STEADY)
        s_nvme_cpl.ready = !cpl_send_pending;
    else
        s_nvme_cpl.ready = 1'b1;
end

///////////////////////////////////////
//      TIE-OFF UNUSED SIGNALS      //
/////////////////////////////////////
always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();

always_comb begin
    axis_host_recv[0].tready = 1'b1;
    axis_host_send[0].tvalid = 1'b0;
    axis_host_send[0].tdata  = '0;
    axis_host_send[0].tkeep  = '0;
    axis_host_send[0].tlast  = 1'b0;

    axis_card_recv[0].tready = 1'b1;
    axis_card_send[0].tvalid = 1'b0;
    axis_card_send[0].tdata  = '0;
    axis_card_send[0].tkeep  = '0;
    axis_card_send[0].tlast  = 1'b0;
end

///////////////////////////////////////
//          DEBUG ILA               //
/////////////////////////////////////
`define EN_ILA_PERF_NVME
`ifdef EN_ILA_PERF_NVME
ila_perf_nvme inst_ila_perf_nvme (
    .clk    (aclk),
    .probe0 (state_C),                      // 3
    .probe1 (bench_ctrl),                   // 2
    .probe2 (bench_sent),                   // 32
    .probe3 (bench_done),                   // 32
    .probe4 (cpl_send_pending),             // 1
    .probe5 (cpl_send_dev),                 // 4
    .probe6 (nvme_req_valid),               // 1
    .probe7 (m_nvme_cmd_req.ready),         // 1
    .probe8 (s_nvme_cpl.valid),             // 1
    .probe9 (s_nvme_cpl.data.dev_id),       // 4
    .probe10(bench_timer[31:0]),            // 32
    .probe11(last_error),                   // 16
    .probe12(s_nvme_cmd_rsp.valid),         // 1
    .probe13(s_nvme_cmd_rsp.data),          // 16
    .probe14(nvme_req.dev_id),              // 4
    .probe15(latch_dev_mask[BENCH_MAX_DEVS-1:0])  // 16→4 (padded by tool)
);
`endif
