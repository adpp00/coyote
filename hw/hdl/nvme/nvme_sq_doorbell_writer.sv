`timescale 1ns/1ps

import lynxTypes::*;

// ------------------------------------------------------------
// NVMe SQ Doorbell Writer
// ------------------------------------------------------------
module nvme_sq_doorbell_writer (
    input  logic        aclk,
    input  logic        aresetn,

    // Input: Doorbell request from nvme_s2
    metaIntf.s          s_sq_db_req,    // sq_db_req_t

    // Output: DMA write request (address + length)
    dmaIntf.m           m_dma_wr_req,
    
    // Output: DMA write data (doorbell value)
    AXI4S.m             m_dma_wr_data
);

    // ----------------------------------------------------------------
    // FSM States
    // ----------------------------------------------------------------
    typedef enum logic [1:0] {
        ST_IDLE,
        ST_SEND_DMA_REQ,
        ST_SEND_DATA
    } state_t;

    state_t        state_C, state_N;
    sq_db_req_t    db_req_C, db_req_N;

    // ----------------------------------------------------------------
    // Combinational logic
    // ----------------------------------------------------------------
    always_comb begin
        // Defaults
        state_N  = state_C;
        db_req_N = db_req_C;

        // Input ready
        s_sq_db_req.ready = 1'b0;

        // DMA request defaults
        m_dma_wr_req.valid = 1'b0;
        m_dma_wr_req.req   = '0;

        // AXI4S data defaults
        m_dma_wr_data.tvalid = 1'b0;
        m_dma_wr_data.tdata  = '0;
        m_dma_wr_data.tkeep  = '0;
        m_dma_wr_data.tlast  = 1'b0;

        case (state_C)
            // --------------------------------------------------------
            // ST_IDLE: Wait for doorbell request
            // --------------------------------------------------------
            ST_IDLE: begin
                s_sq_db_req.ready = 1'b1;
                
                if (s_sq_db_req.valid) begin
                    db_req_N = s_sq_db_req.data;
                    state_N  = ST_SEND_DMA_REQ;
                end
            end

            // --------------------------------------------------------
            // ST_SEND_DMA_REQ: Send DMA write request (address + length)
            // Doorbell write = 4 bytes (32-bit register)
            // --------------------------------------------------------
            ST_SEND_DMA_REQ: begin
                m_dma_wr_req.valid     = 1'b1;
                m_dma_wr_req.req.paddr = db_req_C.db_addr;
                m_dma_wr_req.req.len   = 4;  // 32-bit doorbell
                m_dma_wr_req.req.last  = 1'b1;
                m_dma_wr_req.req.rsrvd = '0;

                if (m_dma_wr_req.ready) begin
                    state_N = ST_SEND_DATA;
                end
            end

            // --------------------------------------------------------
            // ST_SEND_DATA: Send doorbell value via AXI4S
            // Data is 32-bit (sq_tail), padded to AXI_DATA_BITS
            // --------------------------------------------------------
            ST_SEND_DATA: begin
                m_dma_wr_data.tvalid = 1'b1;
                // doorbell value is 32-bit, placed in lower bits
                m_dma_wr_data.tdata  = {'0, db_req_C.sq_tail};
                // Only first 4 bytes valid (32-bit)
                m_dma_wr_data.tkeep  = {{(AXI_DATA_BITS/8 - 4){1'b0}}, 4'hF};
                m_dma_wr_data.tlast  = 1'b1;

                if (m_dma_wr_data.tready) begin
                    state_N = ST_IDLE;
                end
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
            state_C  <= ST_IDLE;
            db_req_C <= '0;
        end
        else begin
            state_C  <= state_N;
            db_req_C <= db_req_N;
        end
    end

    // ================================================================
    // ILA Debug
    // ================================================================
// `define EN_ILA_NVME_SQ_DB_WRITER
`ifdef EN_ILA_NVME_SQ_DB_WRITER
    ila_nvme_sq_doorbell_writer inst_ila_nvme_sq_doorbell_writer (
        .clk    (aclk),
        .probe0 (s_sq_db_req.valid),                    // 1
        .probe1 (s_sq_db_req.ready),                    // 1
        .probe2 (s_sq_db_req.data.db_addr),             // 64
        .probe3 (s_sq_db_req.data.sq_tail),             // NVME_QUEUE_BITS (6)
        .probe4 (m_dma_wr_req.valid),                   // 1
        .probe5 (m_dma_wr_req.ready),                   // 1
        .probe6 (m_dma_wr_req.req.paddr),               // ADDR_BITS (48)
        .probe7 (m_dma_wr_data.tvalid),                 // 1
        .probe8 (m_dma_wr_data.tready),                 // 1
        .probe9 (state_C)                               // 2
    );
`endif

endmodule