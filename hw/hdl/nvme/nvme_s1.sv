`timescale 1ns/1ps

import lynxTypes::*;

// ------------------------------------------------------------
// Stage 1: cmd + info_rsp -> user_rsp + prp_req + cmd_s1
//
// FIX: ST_SEND_PRP_CMD now properly handshakes both outputs.
//      Old code had unconditional state_N = ST_IDLE which dropped
//      cmd_s1 when s2 was busy (not in ST_IDLE).
// ------------------------------------------------------------
module nvme_s1 (
    input  logic        aclk,
    input  logic        aresetn,

    metaIntf.s          s_nvme_cmd_s0,     // nvme_user_req_t
    metaIntf.s          s_nvme_info_rsp,   // nvme_info_rsp_t

    metaIntf.m          m_nvme_user_rsp,   // logic[15:0] (error code)
    metaIntf.m          m_nvme_prp_req,    // nvme_prp_req_t
    metaIntf.m          m_nvme_cmd_s1      // nvme_cmd_s1_t
);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_WAIT_INFO_RSP,
        ST_SEND_USER_RSP,
        ST_SEND_PRP_CMD
    } state_t;

    state_t          state_C, state_N;
    nvme_user_req_t  cmd_C, cmd_N;
    nvme_info_rsp_t  info_rsp_C, info_rsp_N;

    // Fired registers: track which outputs have been accepted
    // in ST_SEND_PRP_CMD (dual handshake)
    logic prp_fired_C, prp_fired_N;
    logic cmd_fired_C, cmd_fired_N;

    // Temporaries (declared at module scope)
    nvme_prp_req_t   prp_req;
    nvme_cmd_s1_t    cmd_s1;

    // Constrained shift amount to prevent synthesis issues with wide shift operands
    // Max value of 15 covers sector sizes up to 32KB (2^15), which is well beyond
    // typical NVMe LBA formats (512B = 9, 4KB = 12)
    logic [3:0]      lbaf_shift;

    always_comb begin
        // Defaults
        state_N     = state_C;
        cmd_N       = cmd_C;
        info_rsp_N  = info_rsp_C;
        prp_fired_N = prp_fired_C;
        cmd_fired_N = cmd_fired_C;

        s_nvme_cmd_s0.ready   = 1'b0;
        s_nvme_info_rsp.ready = 1'b0;

        m_nvme_user_rsp.valid = 1'b0;
        m_nvme_user_rsp.data  = '0;

        m_nvme_prp_req.valid  = 1'b0;
        m_nvme_prp_req.data   = '0;

        m_nvme_cmd_s1.valid   = 1'b0;
        m_nvme_cmd_s1.data    = '0;

        prp_req    = '0;
        cmd_s1     = '0;
        lbaf_shift = '0;

        case (state_C)
            // State 1: Accept user command
            ST_IDLE: begin
                s_nvme_cmd_s0.ready = 1'b1;
                if (s_nvme_cmd_s0.valid) begin
                    cmd_N   = s_nvme_cmd_s0.data;
                    state_N = ST_WAIT_INFO_RSP;
                end
            end

            // State 2: Wait for and receive info table response
            ST_WAIT_INFO_RSP: begin
                s_nvme_info_rsp.ready = 1'b1;
                if (s_nvme_info_rsp.valid) begin
                    info_rsp_N = s_nvme_info_rsp.data;
                    state_N    = ST_SEND_USER_RSP;
                end
            end

            // State 3: Send user error response
            ST_SEND_USER_RSP: begin
                m_nvme_user_rsp.valid = 1'b1;
                m_nvme_user_rsp.data  = info_rsp_C.error;

                if (m_nvme_user_rsp.ready) begin
                    if (info_rsp_C.error != NVME_NO_ERROR) begin
                        // Error: go back to idle
                        state_N = ST_IDLE;
                    end
                    else begin
                        // Success: send PRP req and cmd_s1
                        state_N     = ST_SEND_PRP_CMD;
                        prp_fired_N = 1'b0;
                        cmd_fired_N = 1'b0;
                    end
                end
            end

            // State 4: Send PRP request and cmd_s1 (success path only)
            //
            // FIX: Proper dual handshake using fired registers.
            // Each output is presented until accepted. Only transitions
            // to ST_IDLE when BOTH have been accepted.
            ST_SEND_PRP_CMD: begin
                // Constrain shift amount to 4 bits
                lbaf_shift = info_rsp_C.lbaf[3:0];

                // Build PRP req
                prp_req           = '0;
                prp_req.vaddr     = cmd_C.vaddr;
                prp_req.len       = cmd_C.len;
                prp_req.dev_id    = cmd_C.dev_id;
                prp_req.sq_tail   = info_rsp_C.sq_tail;
                prp_req.writeRead = cmd_C.writeRead;

                // Build cmd_s1
                cmd_s1            = '0;
                cmd_s1.writeRead  = cmd_C.writeRead;
                cmd_s1.dev_id     = cmd_C.dev_id;
                cmd_s1.nsid       = cmd_C.nsid;
                cmd_s1.sq_tail    = info_rsp_C.sq_tail;
                cmd_s1.sq_db_addr = info_rsp_C.sq_db_addr;
                cmd_s1.slba       = (info_rsp_C.lba_offset + cmd_C.naddr) >> lbaf_shift;
                cmd_s1.nlba       = (cmd_C.len >> lbaf_shift) - 1'b1;

                // Present prp_req until accepted
                m_nvme_prp_req.valid = ~prp_fired_C;
                m_nvme_prp_req.data  = prp_req;

                // Present cmd_s1 until accepted
                m_nvme_cmd_s1.valid  = ~cmd_fired_C;
                m_nvme_cmd_s1.data   = cmd_s1;

                // Track acceptance
                if (~prp_fired_C && m_nvme_prp_req.ready)
                    prp_fired_N = 1'b1;
                if (~cmd_fired_C && m_nvme_cmd_s1.ready)
                    cmd_fired_N = 1'b1;

                // Both accepted (either this cycle or previously)?
                if ((prp_fired_C || (~prp_fired_C && m_nvme_prp_req.ready)) &&
                    (cmd_fired_C || (~cmd_fired_C && m_nvme_cmd_s1.ready))) begin
                    state_N     = ST_IDLE;
                    prp_fired_N = 1'b0;
                    cmd_fired_N = 1'b0;
                end
            end

            default: begin
                state_N = ST_IDLE;
            end
        endcase
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            state_C     <= ST_IDLE;
            cmd_C       <= '0;
            info_rsp_C  <= '0;
            prp_fired_C <= 1'b0;
            cmd_fired_C <= 1'b0;
        end
        else begin
            state_C     <= state_N;
            cmd_C       <= cmd_N;
            info_rsp_C  <= info_rsp_N;
            prp_fired_C <= prp_fired_N;
            cmd_fired_C <= cmd_fired_N;
        end
    end

    // ================================================================
    // ILA Debug
    // ================================================================
// `define EN_ILA_NVME_S1
`ifdef EN_ILA_NVME_S1
    ila_nvme_s1 inst_ila_nvme_s1 (
        .clk    (aclk),
        .probe0 (s_nvme_cmd_s0.valid),                  // 1
        .probe1 (s_nvme_cmd_s0.ready),                  // 1
        .probe2 (s_nvme_info_rsp.valid),                // 1
        .probe3 (s_nvme_info_rsp.ready),                // 1
        .probe4 (s_nvme_info_rsp.data.error),           // 16
        .probe5 (s_nvme_info_rsp.data.lba_offset),      // 64
        .probe6 (m_nvme_user_rsp.valid),                // 1
        .probe7 (m_nvme_user_rsp.ready),                // 1
        .probe8 (m_nvme_user_rsp.data),                 // 16
        .probe9 (m_nvme_prp_req.valid),                 // 1
        .probe10(m_nvme_prp_req.ready),                 // 1
        .probe11(m_nvme_cmd_s1.valid),                  // 1
        .probe12(m_nvme_cmd_s1.ready),                  // 1
        .probe13(m_nvme_cmd_s1.data.slba),              // 64
        .probe14(state_C),                              // 3
        .probe15(prp_fired_C),                          // 1
        .probe16(cmd_fired_C)                           // 1
    );
`endif

endmodule