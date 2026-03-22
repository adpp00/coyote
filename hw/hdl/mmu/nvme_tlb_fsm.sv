`timescale 1ns/1ps
import lynxTypes::*;

module nvme_tlb_fsm #(
    parameter int OWNER_ID = 0,
    parameter int PID_CONST = 0,
    parameter logic [STRM_BITS-1:0] STRM_CONST = STRM_NVME  // use STRM_NVME for lookup
) (
    input  logic       aclk,
    input  logic       aresetn,

    // TLBs
    tlbIntf.m          lTlb,
    tlbIntf.m          sTlb,

    // Requests / responses
    metaIntf.s         s_nvme_req,   // STYPE(nvme_req_t) {vaddr,len}
    metaIntf.m         m_nvme_rsp,   // STYPE(nvme_rsp_t) {paddr,len,last,fault,is_host}

    // Mutex
    output logic       lock,
    output logic       unlock,
    input  logic [2:0] mutex         // {owner[1:0], free}
);

    // -- Constants
    localparam int PG_L_SIZE = 1 << PG_L_BITS;
    localparam int PG_S_SIZE = 1 << PG_S_BITS;

    localparam int HASH_L_BITS = TLB_L_ORDER;
    localparam int HASH_S_BITS = TLB_S_ORDER;

    localparam int PHY_L_BITS  = PADDR_BITS - PG_L_BITS;
    localparam int PHY_S_BITS  = PADDR_BITS - PG_S_BITS;

    localparam int TAG_L_BITS  = VADDR_BITS - HASH_L_BITS - PG_L_BITS;
    localparam int TAG_S_BITS  = VADDR_BITS - HASH_S_BITS - PG_S_BITS;

    localparam int STRM_L_OFFS = TAG_L_BITS + PID_BITS;
    localparam int STRM_S_OFFS = TAG_S_BITS + PID_BITS;

    localparam int PHY_L_OFFS  = TAG_L_BITS + PID_BITS + STRM_BITS + 1;
    localparam int PHY_S_OFFS  = TAG_S_BITS + PID_BITS + STRM_BITS + 1;

    localparam int TLB_L_DATA_BITS = TAG_L_BITS + PID_BITS + STRM_BITS + 1 + PHY_L_BITS + HPID_BITS;
    localparam int TLB_S_DATA_BITS = TAG_S_BITS + PID_BITS + STRM_BITS + 1 + PHY_S_BITS + HPID_BITS;

    // -- FSM
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_MUTEX,
        ST_WAIT_1,
        ST_WAIT_2,
        ST_CHECK,
        ST_HIT_LARGE,
        ST_HIT_SMALL,
        ST_CALC_LARGE,
        ST_CALC_SMALL,
        ST_RSP_SEND,
        ST_FAIL_SEND
    } state_t;

    state_t state_C, state_N;

    // -- Request
    logic [VADDR_BITS-1:0] vaddr_C, vaddr_N;
    logic [LEN_BITS-1:0]   len_C,   len_N;

    // -- TLB data
    logic [TLB_L_DATA_BITS-1:0] data_l_C, data_l_N;
    logic [TLB_S_DATA_BITS-1:0] data_s_C, data_s_N;

    // -- Lookup valid
    logic val_C, val_N;

    // -- Segment
    logic [PADDR_BITS-1:0] paddr_C, paddr_N;
    logic [LEN_BITS-1:0]   plen_C,  plen_N;

    // -- Entry location
    logic is_host_C, is_host_N;

    // -- Unlock pulse
    logic unlock_C, unlock_N;

    // -- Hit
    logic hit_l, hit_s, hit_any;

    // -- 4K split (used in large hit path)
    logic [LEN_BITS-1:0] rem4k, remL, take;

    always_comb begin
        // Defaults
        state_N   = state_C;

        vaddr_N   = vaddr_C;
        len_N     = len_C;

        data_l_N  = data_l_C;
        data_s_N  = data_s_C;

        paddr_N   = paddr_C;
        plen_N    = plen_C;

        is_host_N = is_host_C;

        val_N     = val_C;
        unlock_N  = 1'b0;

        lock      = 1'b0;
        unlock    = unlock_C;

        // Handshakes
        s_nvme_req.ready      = 1'b0;

        m_nvme_rsp.valid      = 1'b0;
        m_nvme_rsp.data.paddr = paddr_C;
        m_nvme_rsp.data.len   = plen_C;
        m_nvme_rsp.data.last  = 1'b0;
        m_nvme_rsp.data.fault = 1'b0;
        m_nvme_rsp.data.is_host = is_host_C;

        // TLB drive (translate-only)
        lTlb.addr  = vaddr_C;
        lTlb.wr    = 1'b0;
        lTlb.pid   = PID_CONST[PID_BITS-1:0];
        lTlb.strm  = STRM_CONST;      // STRM_NVME
        lTlb.valid = val_C;

        sTlb.addr  = vaddr_C;
        sTlb.wr    = 1'b0;
        sTlb.pid   = PID_CONST[PID_BITS-1:0];
        sTlb.strm  = STRM_CONST;      // STRM_NVME
        sTlb.valid = val_C;

        hit_l   = lTlb.hit;
        hit_s   = sTlb.hit;
        hit_any = hit_l | hit_s;

        // 4K split defaults
        rem4k = '0;
        remL  = '0;
        take  = '0;

        unique case (state_C)
            ST_IDLE: begin
                val_N = 1'b0;
                s_nvme_req.ready = 1'b1;
                if (s_nvme_req.valid) begin
                    if (s_nvme_req.data.len != 0) begin
                        vaddr_N = s_nvme_req.data.vaddr;
                        len_N   = s_nvme_req.data.len;
                        lock    = 1'b1;
                        state_N = ST_MUTEX;
                    end
                end
            end

            ST_MUTEX: begin
                lock = 1'b1;
                if ((mutex[0] == 1'b0) && (mutex[2:1] == OWNER_ID[1:0])) begin
                    val_N   = 1'b1;
                    state_N = ST_WAIT_1;
                end
            end

            ST_WAIT_1: state_N = ST_WAIT_2;
            ST_WAIT_2: state_N = ST_CHECK;

            ST_CHECK: begin
                unlock_N = 1'b1;
                if (hit_any) begin
                    state_N = hit_l ? ST_HIT_LARGE : ST_HIT_SMALL;
                end else begin
                    state_N = ST_FAIL_SEND;
                end
            end

            ST_HIT_LARGE: begin
                data_l_N  = lTlb.data;
                // entry strm -> is_host
                is_host_N = (lTlb.data[STRM_L_OFFS+:STRM_BITS] == STRM_HOST);
                state_N   = ST_CALC_LARGE;
            end

            ST_HIT_SMALL: begin
                data_s_N  = sTlb.data;
                // entry strm -> is_host
                is_host_N = (sTlb.data[STRM_S_OFFS+:STRM_BITS] == STRM_HOST);
                state_N   = ST_CALC_SMALL;
            end

            // NOTE: even with a large page hit, split responses into 4KB chunks
            //       (but still never cross the large page boundary).
            ST_CALC_LARGE: begin
                // large-page based paddr calculation
                paddr_N = {data_l_C[PHY_L_OFFS+:PHY_L_BITS], vaddr_C[0+:PG_L_BITS]};

                // remaining bytes to next 4KB boundary
                rem4k = PG_S_SIZE - vaddr_C[PG_S_BITS-1:0];

                // remaining bytes to large page boundary
                remL  = PG_L_SIZE - vaddr_C[PG_L_BITS-1:0];

                // take = min(len_C, rem4k, remL)
                take = len_C;
                if (rem4k < take) take = rem4k;
                if (remL  < take) take = remL;

                plen_N  = take;
                len_N   = len_C - take;
                vaddr_N = vaddr_C + take;

                state_N = ST_RSP_SEND;
            end

            ST_CALC_SMALL: begin
                paddr_N = {data_s_C[PHY_S_OFFS+:PHY_S_BITS], vaddr_C[0+:PG_S_BITS]};
                if (len_C + vaddr_C[PG_S_BITS-1:0] > PG_S_SIZE) begin
                    plen_N  = PG_S_SIZE - vaddr_C[PG_S_BITS-1:0];
                    len_N   = len_C - (PG_S_SIZE - vaddr_C[PG_S_BITS-1:0]);
                    vaddr_N = vaddr_C + (PG_S_SIZE - vaddr_C[PG_S_BITS-1:0]);
                end else begin
                    plen_N = len_C;
                    len_N  = '0;
                end
                state_N = ST_RSP_SEND;
            end

            ST_RSP_SEND: begin
                m_nvme_rsp.valid        = 1'b1;
                m_nvme_rsp.data.paddr   = paddr_C;
                m_nvme_rsp.data.len     = plen_C;
                m_nvme_rsp.data.fault   = 1'b0;
                m_nvme_rsp.data.is_host = is_host_C;
                m_nvme_rsp.data.last    = (len_C == '0);

                if (m_nvme_rsp.ready) begin
                    val_N = 1'b0;
                    if (len_C != '0) begin
                        lock    = 1'b1;
                        state_N = ST_MUTEX;
                    end else begin
                        state_N = ST_IDLE;
                    end
                end
            end

            ST_FAIL_SEND: begin
                m_nvme_rsp.valid        = 1'b1;
                m_nvme_rsp.data.paddr   = '0;
                m_nvme_rsp.data.len     = '0;
                m_nvme_rsp.data.fault   = 1'b1;
                m_nvme_rsp.data.is_host = 1'b0;
                m_nvme_rsp.data.last    = 1'b1;

                if (m_nvme_rsp.ready) begin
                    val_N   = 1'b0;
                    state_N = ST_IDLE;
                end
            end

            default: state_N = ST_IDLE;
        endcase
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            state_C   <= ST_IDLE;
            vaddr_C   <= '0;
            len_C     <= '0;
            data_l_C  <= '0;
            data_s_C  <= '0;
            paddr_C   <= '0;
            plen_C    <= '0;
            is_host_C <= 1'b0;
            val_C     <= 1'b0;
            unlock_C  <= 1'b0;
        end else begin
            state_C   <= state_N;
            vaddr_C   <= vaddr_N;
            len_C     <= len_N;
            data_l_C  <= data_l_N;
            data_s_C  <= data_s_N;
            paddr_C   <= paddr_N;
            plen_C    <= plen_N;
            is_host_C <= is_host_N;
            val_C     <= val_N;
            unlock_C  <= unlock_N;
        end
    end

endmodule
