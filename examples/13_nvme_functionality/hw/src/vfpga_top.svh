/**
 * NVMe Functionality Test (coyote-tcp)
 *
 * Executes a single NVMe request when triggered via AXI control from SW.
 * Adapted for multi-device + region-based permission model:
 *   - naddr is an offset within the permitted region (not raw LBA)
 *   - region_id is tagged by nvme_top arbiter (transparent to user)
 *   - s_nvme_cpl includes dev_id for multi-device tracking
 */

import lynxTypes::*;

// FSM states
typedef enum logic [2:0] {
    ST_IDLE,
    ST_SEND_NVME_REQ,
    ST_WAIT_NVME_RSP,
    ST_WAIT_NVME_CPL,
    ST_DONE
} state_t;

state_t state_C, state_N;

// ----------------------------------------------------------------
// AXI Control Interface
// ----------------------------------------------------------------
logic        nvme_start;
logic [63:0] nvme_dev_id;
logic [63:0] nvme_nsid;
logic [63:0] nvme_lba;
logic [63:0] nvme_len;
logic [63:0] nvme_vaddr;
logic        nvme_write;
logic        nvme_done_C, nvme_done_N;
logic [15:0] nvme_error_C, nvme_error_N;

nvme_axi_ctrl_parser inst_axi_ctrl_parser (
    .aclk(aclk),
    .aresetn(aresetn),
    .axi_ctrl(axi_ctrl),
    .nvme_start(nvme_start),
    .nvme_dev_id(nvme_dev_id),
    .nvme_nsid(nvme_nsid),
    .nvme_lba(nvme_lba),
    .nvme_len(nvme_len),
    .nvme_vaddr(nvme_vaddr),
    .nvme_write(nvme_write),
    .nvme_done(nvme_done_C),
    .nvme_error(nvme_error_C)
);

// ----------------------------------------------------------------
// NVMe request signals
// ----------------------------------------------------------------
logic               nvme_req_valid_C, nvme_req_valid_N;
nvme_user_req_t     nvme_req_C, nvme_req_N;

// CQE tracking
logic [N_NVME_BITS-1:0] cpl_dev_id_C, cpl_dev_id_N;

// ----------------------------------------------------------------
// FSM combinational logic
// ----------------------------------------------------------------
always_comb begin
    // Defaults
    state_N          = state_C;
    nvme_req_valid_N = nvme_req_valid_C;
    nvme_req_N       = nvme_req_C;
    nvme_error_N     = nvme_error_C;
    nvme_done_N      = nvme_done_C;
    cpl_dev_id_N     = cpl_dev_id_C;

    // NVMe request interface
    m_nvme_cmd_req.valid = nvme_req_valid_C;
    m_nvme_cmd_req.data  = nvme_req_C;

    // Always ready to receive response/completion
    s_nvme_cmd_rsp.ready = 1'b1;
    s_nvme_cpl.ready     = 1'b1;

    case (state_C)
        // --------------------------------------------------------
        // ST_IDLE: Wait for start signal from SW
        // --------------------------------------------------------
        ST_IDLE: begin
            if (nvme_start) begin
                nvme_done_N  = 1'b0;
                nvme_error_N = 16'd0;
                state_N      = ST_SEND_NVME_REQ;
            end
        end

        // --------------------------------------------------------
        // ST_SEND_NVME_REQ: Send NVMe request
        // --------------------------------------------------------
        ST_SEND_NVME_REQ: begin
            nvme_req_N.dev_id    = nvme_dev_id[DEV_ID_BITS-1:0];
            nvme_req_N.writeRead = nvme_write;
            nvme_req_N.nsid      = nvme_nsid[NSID_BITS-1:0];
            nvme_req_N.vaddr     = nvme_vaddr;
            nvme_req_N.len       = nvme_len[LEN_BITS-1:0];
            // naddr = offset within permitted region (byte offset)
            // Host permission table maps this to actual LBA via lba_offset
            nvme_req_N.naddr     = nvme_lba;
            // region_id is tagged by nvme_top arbiter — leave as 0 here
            nvme_req_N.region_id = '0;

            nvme_req_valid_N = 1'b1;

            if (nvme_req_valid_C && m_nvme_cmd_req.ready) begin
                nvme_req_valid_N = 1'b0;
                state_N = ST_WAIT_NVME_RSP;
            end
        end

        // --------------------------------------------------------
        // ST_WAIT_NVME_RSP: Wait for command response (error code)
        // --------------------------------------------------------
        ST_WAIT_NVME_RSP: begin
            if (s_nvme_cmd_rsp.valid) begin
                nvme_error_N = s_nvme_cmd_rsp.data[15:0];

                if (s_nvme_cmd_rsp.data[15:0] != 16'h0000) begin
                    nvme_done_N = 1'b1;
                    state_N     = ST_DONE;
                end
                else begin
                    state_N = ST_WAIT_NVME_CPL;
                end
            end
        end

        // --------------------------------------------------------
        // ST_WAIT_NVME_CPL: Wait for NVMe completion (CQE)
        // --------------------------------------------------------
        ST_WAIT_NVME_CPL: begin
            if (s_nvme_cpl.valid) begin
                cpl_dev_id_N = s_nvme_cpl.data.dev_id;
                nvme_done_N  = 1'b1;
                state_N      = ST_DONE;
            end
        end

        // --------------------------------------------------------
        // ST_DONE: Transfer complete
        // --------------------------------------------------------
        ST_DONE: begin
            state_N = ST_IDLE;
        end

        default: begin
            state_N = ST_IDLE;
        end
    endcase
end

// ----------------------------------------------------------------
// Sequential logic
// ----------------------------------------------------------------
always_ff @(posedge aclk) begin
    if (!aresetn) begin
        state_C          <= ST_IDLE;
        nvme_req_valid_C <= 1'b0;
        nvme_req_C       <= '0;
        nvme_error_C     <= 16'd0;
        nvme_done_C      <= 1'b0;
        cpl_dev_id_C     <= '0;
    end
    else begin
        state_C          <= state_N;
        nvme_req_valid_C <= nvme_req_valid_N;
        nvme_req_C       <= nvme_req_N;
        nvme_error_C     <= nvme_error_N;
        nvme_done_C      <= nvme_done_N;
        cpl_dev_id_C     <= cpl_dev_id_N;
    end
end

// ----------------------------------------------------------------
// Tie-off unused interfaces
// ----------------------------------------------------------------
always_comb begin
    notify.tie_off_m();
    sq_rd.tie_off_m();
    sq_wr.tie_off_m();
    cq_rd.tie_off_s();
    cq_wr.tie_off_s();

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

// ----------------------------------------------------------------
// Debug ILA
// ----------------------------------------------------------------
`ifdef EN_ILA_NVME
ila_nvme_user inst_ila_nvme_user (
    .clk    (aclk),
    // FSM
    .probe0 (state_C),                      // 3
    .probe1 (nvme_start),                   // 1
    .probe2 (nvme_done_C),                  // 1
    .probe3 (nvme_error_C),                 // 16
    // NVMe request
    .probe4 (nvme_req_valid_C),             // 1
    .probe5 (m_nvme_cmd_req.ready),         // 1
    .probe6 (nvme_req_C.dev_id),            // DEV_ID_BITS (4)
    .probe7 (nvme_req_C.naddr),             // ADDR_BITS (48)
    .probe8 (nvme_req_C.len),               // LEN_BITS (28)
    .probe9 (nvme_req_C.writeRead),         // 1
    // NVMe response
    .probe10(s_nvme_cmd_rsp.valid),         // 1
    .probe11(s_nvme_cmd_rsp.data),          // 16
    // NVMe completion
    .probe12(s_nvme_cpl.valid),             // 1
    .probe13(s_nvme_cpl.data.dev_id),       // N_NVME_BITS (4)
    .probe14(s_nvme_cpl.data.status),       // 15
    .probe15(s_nvme_cpl.data.phase),        // 1
    // Config from SW
    .probe16(nvme_dev_id[3:0]),             // 4
    .probe17(nvme_lba[31:0]),               // 32
    .probe18(nvme_len[27:0]),               // 28
    .probe19(nvme_write)                    // 1
);
`endif
