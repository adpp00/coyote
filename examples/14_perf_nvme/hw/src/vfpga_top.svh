/**
 * NVMe SSD Bandwidth Test (coyote-tcp, multi-device)
 *
 * Pipelined benchmark: sends N NVMe requests with configurable
 * max outstanding, measures total time.
 *
 * Adapted for multi-device + region-based permission:
 *   - naddr = byte offset within permitted region
 *   - region_id tagged by nvme_top arbiter
 *   - s_nvme_cpl includes dev_id
 */

import lynxTypes::*;

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
logic [31:0]           bench_n_reps;
logic [63:0]           bench_lba;
logic [63:0]           bench_dev_id;
logic [63:0]           bench_nsid;
logic [31:0]           bench_max_outstanding;

///////////////////////////////////////
//     BENCHMARK STATUS (to SW)     //
/////////////////////////////////////
logic [31:0] bench_sent;
logic [31:0] bench_done;
logic [63:0] bench_timer;
logic [15:0] last_error;

///////////////////////////////////////
//      LATCHED PARAMETERS          //
/////////////////////////////////////
logic [VADDR_BITS-1:0]  curr_vaddr;
logic [63:0]            curr_offset;    // byte offset within permitted region
logic [31:0]            latch_chunk_size;
logic [31:0]            latch_n_reps;
logic [31:0]            latch_max_outstanding;
logic                   latch_is_write;
logic [DEV_ID_BITS-1:0] latch_dev_id;
logic [NSID_BITS-1:0]   latch_nsid;

///////////////////////////////////////
//           FSM                    //
/////////////////////////////////////
typedef enum logic [2:0] {
    ST_IDLE,
    ST_RUNNING,
    ST_DRAIN
} state_t;

state_t state_C;

// NVMe request
logic           nvme_req_valid;
nvme_user_req_t nvme_req;

// Outstanding count
wire [31:0] outstanding = bench_sent - bench_done;

// Can send condition
wire can_send = (outstanding < latch_max_outstanding) && (bench_sent < latch_n_reps);

// All done condition
wire all_done = (bench_done >= latch_n_reps);

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
    .bench_dev_id(bench_dev_id),
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
        state_C              <= ST_IDLE;
        nvme_req_valid       <= 1'b0;
        nvme_req             <= '0;
        last_error           <= 16'd0;

        curr_vaddr           <= '0;
        curr_offset          <= '0;
        latch_chunk_size     <= '0;
        latch_n_reps         <= '0;
        latch_max_outstanding<= '0;
        latch_is_write       <= 1'b0;
        latch_dev_id         <= '0;
        latch_nsid           <= '0;

        bench_sent           <= '0;
        bench_done           <= '0;
        bench_timer          <= '0;
    end
    else begin
        // Clear request valid after accepted
        if (nvme_req_valid && m_nvme_cmd_req.ready) begin
            nvme_req_valid <= 1'b0;
        end

        case (state_C)
            // --------------------------------------------------------
            // ST_IDLE: Wait for start signal
            // --------------------------------------------------------
            ST_IDLE: begin
                if (bench_ctrl[START_RD] || bench_ctrl[START_WR]) begin
                    curr_vaddr           <= bench_vaddr;
                    // bench_lba from SW = byte offset within permitted region
                    curr_offset          <= bench_lba;
                    latch_chunk_size     <= bench_chunk_size;
                    latch_n_reps         <= bench_n_reps;
                    latch_max_outstanding<= bench_max_outstanding;
                    latch_is_write       <= bench_ctrl[START_WR];
                    latch_dev_id         <= bench_dev_id[DEV_ID_BITS-1:0];
                    latch_nsid           <= bench_nsid[NSID_BITS-1:0];
                    last_error           <= 16'd0;

                    bench_sent  <= '0;
                    bench_done  <= '0;
                    bench_timer <= '0;

                    state_C <= ST_RUNNING;
                end
            end

            // --------------------------------------------------------
            // ST_RUNNING: Send REQs while receiving CPLs
            // --------------------------------------------------------
            ST_RUNNING: begin
                bench_timer <= bench_timer + 1;

                // === Send path ===
                if (can_send && !nvme_req_valid) begin
                    nvme_req.dev_id    <= latch_dev_id;
                    nvme_req.writeRead <= latch_is_write;
                    nvme_req.nsid      <= latch_nsid;
                    nvme_req.vaddr     <= curr_vaddr;
                    nvme_req.len       <= latch_chunk_size;
                    // naddr = byte offset within permitted region
                    nvme_req.naddr     <= curr_offset;
                    // region_id tagged by nvme_top arbiter
                    nvme_req.region_id <= '0;

                    nvme_req_valid <= 1'b1;
                end

                // Update addresses after REQ accepted
                if (nvme_req_valid && m_nvme_cmd_req.ready) begin
                    curr_vaddr  <= curr_vaddr + latch_chunk_size;
                    curr_offset <= curr_offset + latch_chunk_size;
                    bench_sent  <= bench_sent + 1;
                end

                // === Receive path ===
                if (s_nvme_cpl.valid) begin
                    bench_done <= bench_done + 1;
                end

                if (s_nvme_cmd_rsp.valid && s_nvme_cmd_rsp.data[15:0] != 16'h0000) begin
                    last_error <= s_nvme_cmd_rsp.data[15:0];
                end

                // Transition to DRAIN when all REQs sent
                if (bench_sent >= latch_n_reps && !nvme_req_valid) begin
                    state_C <= ST_DRAIN;
                end
            end

            // --------------------------------------------------------
            // ST_DRAIN: Wait for remaining CPLs
            // --------------------------------------------------------
            ST_DRAIN: begin
                if (!all_done)
                    bench_timer <= bench_timer + 1;

                if (s_nvme_cpl.valid)
                    bench_done <= bench_done + 1;

                if (s_nvme_cmd_rsp.valid && s_nvme_cmd_rsp.data[15:0] != 16'h0000)
                    last_error <= s_nvme_cmd_rsp.data[15:0];

                if (all_done)
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
    s_nvme_cpl.ready     = 1'b1;
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
`ifdef EN_ILA_NVME
ila_perf_nvme inst_ila_perf_nvme (
    .clk    (aclk),
    .probe0 (state_C),                      // 3
    .probe1 (bench_ctrl),                   // 2
    .probe2 (bench_sent),                   // 32
    .probe3 (bench_done),                   // 32
    .probe4 (outstanding),                  // 32
    .probe5 (can_send),                     // 1
    .probe6 (nvme_req_valid),               // 1
    .probe7 (m_nvme_cmd_req.ready),         // 1
    .probe8 (s_nvme_cpl.valid),             // 1
    .probe9 (s_nvme_cpl.data.dev_id),       // N_NVME_BITS (4)
    .probe10(bench_timer[31:0]),            // 32
    .probe11(last_error),                   // 16
    .probe12(s_nvme_cmd_rsp.valid),         // 1
    .probe13(s_nvme_cmd_rsp.data),          // 16
    .probe14(nvme_req.dev_id),              // DEV_ID_BITS (4)
    .probe15(curr_offset[31:0])             // 32
);
`endif
