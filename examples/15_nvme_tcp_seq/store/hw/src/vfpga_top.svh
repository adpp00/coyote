/**
 * TCP -> NVMe Sequential Store (Example 16 — Store)
 *
 * Architecture (RTL-only, no HLS):
 *   1. Listen on TCP port
 *   2. Client connects and sends: [64B meta: total_data_length] [data...]
 *   3. Per TCP packet: receive -> DMA write to card memory
 *   4. Every 1MB accumulated: issue NVMe writes to SSD dev 0
 *   5. After NVMe done: send 64B TCP completion to client
 *   6. Repeat until total_data_length received
 *
 * NVMe writes are sequential starting from byte offset 0 on device 0.
 * Card memory buffer is reused each 1MB block (blocking pipeline).
 */

import lynxTypes::*;

// ============================================================
// Parameters
// ============================================================
// Block threshold is now dynamic: uses latch_chunk_size (set from SW)
// TCP completion sent after each chunk_size block written to NVMe
localparam integer BEAT_BYTES      = 64;           // 512 bits / 8
localparam integer NVME_DEV_ID     = 0;            // Always write to device 0

// ============================================================
// FSM
// ============================================================
typedef enum logic [4:0] {
    ST_IDLE          = 5'd0,
    ST_LISTEN        = 5'd1,
    ST_WAIT_NOTIFY   = 5'd2,   // Wait for tcp_notify (packet arrival)
    ST_SEND_RD_PKG   = 5'd3,   // Send tcp_rd_pkg
    ST_WAIT_RX_META  = 5'd4,   // Consume tcp_rx_meta
    ST_RECV_FIRST    = 5'd5,   // First packet: consume first beat as app meta
    ST_ACK_META      = 5'd6,   // Send TCP TX meta for status ACK
    ST_ACK_DATA      = 5'd7,   // Send TCP TX data (64B status: OK)
    ST_ACK_WAIT      = 5'd8,   // Wait for TCP TX stat
    ST_SUBMIT_DESC   = 5'd9,   // Submit sq_wr (card memory write)
    ST_RECV_DATA     = 5'd10,  // Forward axis_tcp_recv -> axis_card_send
    ST_WAIT_MEM      = 5'd11,  // Wait for DMA write completion (cq_wr)
    ST_CHECK_BLOCK   = 5'd12,  // chunk_size accumulated? -> NVMe or next packet
    ST_NVME_ISSUE    = 5'd13,  // Issue NVMe write commands
    ST_NVME_DRAIN    = 5'd14,  // Wait for all NVMe completions
    ST_CPL_META      = 5'd15,  // Send TCP completion meta
    ST_CPL_DATA      = 5'd16,  // Send TCP completion data beat
    ST_CPL_WAIT      = 5'd17,  // Wait for TCP TX stat
    ST_DONE          = 5'd18   // All data transferred
} state_t;

state_t state_C;

// ============================================================
// Control registers (from AXI-Lite parser)
// ============================================================
logic [1:0]               bench_ctrl;
logic [15:0]              listen_port;
logic [VADDR_BITS-1:0]    mem_base;
logic [63:0]              reg_nsid;
logic [31:0]              reg_chunk_size;   // NVMe chunk size (bytes)

logic [3:0]               fsm_state_out;
logic                     listen_ok;
logic [63:0]              timer;
logic [31:0]              nvme_sent;
logic [31:0]              nvme_done;
logic [15:0]              last_error;
logic [63:0]              bytes_recv;
logic [63:0]              nvme_lba_off_out;

nvme_tcp_store_ctrl inst_ctrl (
    .aclk(aclk), .aresetn(aresetn), .axi_ctrl(axi_ctrl),
    .bench_ctrl(bench_ctrl), .listen_port(listen_port),
    .mem_base(mem_base), .nsid(reg_nsid), .chunk_size(reg_chunk_size),
    .fsm_state(fsm_state_out), .listen_ok(listen_ok),
    .timer(timer), .nvme_sent(nvme_sent), .nvme_done(nvme_done),
    .last_error(last_error), .bytes_recv(bytes_recv),
    .nvme_lba_off(nvme_lba_off_out)
);

assign fsm_state_out = state_C[3:0];

// ============================================================
// Internal state
// ============================================================
// App meta (from first beat of first packet)
logic [63:0]  naddr_base;       // Client-specified NVMe start byte offset
logic [63:0]  total_data_len;
logic         is_first_pkt;

// TCP session
logic [TCP_SESSION_BITS-1:0] session_id;
logic [TCP_LEN_BITS-1:0]     pkt_len;       // current packet length from notify
logic [TCP_LEN_BITS-1:0]     pkt_data_len;  // actual data bytes in current packet

// Block tracking (per chunk_size block)
logic [31:0]  block_recv;      // bytes received in current block
logic [31:0]  mem_offset;      // write offset within card buffer for current block

// Packet splitting: track progress within one TCP packet
logic [31:0]  pkt_remaining;   // bytes left in current TCP packet
logic [31:0]  desc_len_reg;    // current DMA descriptor length
logic [31:0]  desc_fwd;        // bytes forwarded for current descriptor

// Cumulative
logic [63:0]  nvme_lba_off;    // current LBA byte offset on SSD

// NVMe issue (offset-based, no division/multiply)
logic [31:0]  nvme_write_off;   // offset within current block
logic         nvme_req_valid;
nvme_user_req_t nvme_req;

// SQ-full retry: track rejected commands
logic         nvme_sq_full;     // last cmd_rsp was SQ full
logic [31:0]  nvme_err_count;   // total error responses

// DMA write descriptor
logic         sq_wr_valid;
req_t         sq_wr_desc;

// DMA write completion flag
logic         mem_wr_done;

// TCP TX control
logic         tx_meta_valid;
logic         tx_data_valid;

// Latched chunk size
logic [31:0]  latch_chunk_size;

assign nvme_lba_off_out = nvme_lba_off;

// ============================================================
// TCP listen (same pattern as perf_tcp)
// ============================================================
logic        lsn_valid_r;
logic [15:0] lsn_port_r;
logic        go_q;
wire         go_pulse = bench_ctrl[0] & ~go_q;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        go_q        <= 1'b0;
        lsn_valid_r <= 1'b0;
        lsn_port_r  <= '0;
        listen_ok   <= 1'b0;
    end
    else begin
        go_q <= bench_ctrl[0];

        if (go_pulse) begin
            lsn_port_r  <= listen_port;
            lsn_valid_r <= 1'b1;
            listen_ok   <= 1'b0;
        end

        if (lsn_valid_r && tcp_listen_req.ready)
            lsn_valid_r <= 1'b0;

        if (tcp_listen_rsp.valid)
            listen_ok <= tcp_listen_rsp.data[0];
    end
end

assign tcp_listen_req.valid = lsn_valid_r;
assign tcp_listen_req.data  = lsn_port_r;
assign tcp_listen_rsp.ready = 1'b1;

// ============================================================
// DMA write completion tracking
// ============================================================
always_ff @(posedge aclk) begin
    if (!aresetn)
        mem_wr_done <= 1'b0;
    else if (state_C == ST_SUBMIT_DESC)
        mem_wr_done <= 1'b0;   // Reset when new descriptor submitted
    else if (cq_wr.valid)
        mem_wr_done <= 1'b1;
end

// ============================================================
// TCP rd_pkg one-shot control
// ============================================================
logic rd_pkg_valid;

// ============================================================
// Main FSM
// ============================================================
always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        state_C         <= ST_IDLE;
        total_data_len  <= '0;
        is_first_pkt    <= 1'b1;
        session_id      <= '0;
        pkt_len         <= '0;
        pkt_data_len    <= '0;
        block_recv      <= '0;
        mem_offset      <= '0;
        pkt_remaining   <= '0;
        desc_len_reg    <= '0;
        desc_fwd        <= '0;
        bytes_recv      <= '0;
        nvme_lba_off    <= '0;
        nvme_write_off  <= '0;
        nvme_req_valid  <= 1'b0;
        nvme_req        <= '0;
        nvme_sent       <= '0;
        nvme_done       <= '0;
        nvme_sq_full    <= 1'b0;
        nvme_err_count  <= '0;
        sq_wr_valid     <= 1'b0;
        sq_wr_desc      <= '0;
        last_error      <= '0;
        timer           <= '0;
        rd_pkg_valid    <= 1'b0;
        tx_meta_valid   <= 1'b0;
        tx_data_valid   <= 1'b0;
        latch_chunk_size <= 32'd4096;
    end
    else begin
        // --- Clear one-shot signals after handshake ---
        if (nvme_req_valid && m_nvme_cmd_req.ready)
            nvme_req_valid <= 1'b0;
        if (sq_wr_valid && sq_wr.ready)
            sq_wr_valid <= 1'b0;
        if (rd_pkg_valid && tcp_rd_pkg.ready)
            rd_pkg_valid <= 1'b0;

        // --- NVMe completions (always) ---
        if (s_nvme_cpl.valid)
            nvme_done <= nvme_done + 1;

        // --- NVMe error handling ---
        nvme_sq_full <= 1'b0;  // default: clear each cycle
        if (s_nvme_cmd_rsp.valid && s_nvme_cmd_rsp.data[15:0] != 16'h0000) begin
            last_error     <= s_nvme_cmd_rsp.data[15:0];
            nvme_err_count <= nvme_err_count + 1;

            if (s_nvme_cmd_rsp.data[15:0] == 16'h0002) begin
                // SQ full: roll back nvme_sent & nvme_write_off so we retry
                nvme_sq_full   <= 1'b1;
                nvme_sent      <= nvme_sent - 1;
                nvme_write_off <= nvme_write_off - latch_chunk_size;
            end
        end

        case (state_C)
            // ============================================
            ST_IDLE: begin
                if (go_pulse) begin
                    is_first_pkt    <= 1'b1;
                    naddr_base      <= '0;
                    total_data_len  <= '0;
                    block_recv      <= '0;
                    mem_offset      <= '0;
                    bytes_recv      <= '0;
                    nvme_lba_off    <= '0;
                    nvme_sent       <= '0;
                    nvme_done       <= '0;
                    last_error      <= '0;
                    timer           <= '0;
                    latch_chunk_size <= (reg_chunk_size != 0) ? reg_chunk_size : 32'd4096;
                    state_C         <= ST_WAIT_NOTIFY;
                end
            end

            // ============================================
            // Wait for tcp_notify (packet available)
            // ============================================
            ST_WAIT_NOTIFY: begin
                timer <= timer + 1;
                if (tcp_notify.valid) begin
                    session_id <= tcp_notify.data.sid;
                    pkt_len    <= tcp_notify.data.len;

                    if (tcp_notify.data.closed) begin
                        // Connection closed by peer
                        state_C <= ST_DONE;
                    end
                    else if (tcp_notify.data.len != 0) begin
                        state_C <= ST_SEND_RD_PKG;
                    end
                    // len==0 (connection event, no data): stay and wait for next notify
                end
            end

            // ============================================
            // Send tcp_rd_pkg
            // ============================================
            ST_SEND_RD_PKG: begin
                timer <= timer + 1;
                if (!rd_pkg_valid) begin
                    rd_pkg_valid <= 1'b1;
                end
                if (rd_pkg_valid && tcp_rd_pkg.ready) begin
                    state_C <= ST_WAIT_RX_META;
                end
            end

            // ============================================
            // Consume tcp_rx_meta
            // ============================================
            ST_WAIT_RX_META: begin
                timer <= timer + 1;
                if (tcp_rx_meta.valid) begin
                    if (is_first_pkt)
                        state_C <= ST_RECV_FIRST;
                    else begin
                        pkt_remaining <= pkt_len;
                        state_C       <= ST_SUBMIT_DESC;
                    end
                end
            end

            // ============================================
            // First packet: consume first beat as app meta
            //   [63:0]   = naddr_base
            //   [127:64] = data_length
            // ============================================
            ST_RECV_FIRST: begin
                timer <= timer + 1;
                if (axis_tcp_recv.tvalid) begin
                    naddr_base     <= axis_tcp_recv.tdata[63:0];
                    total_data_len <= axis_tcp_recv.tdata[127:64];
                    nvme_lba_off   <= axis_tcp_recv.tdata[63:0];
                    is_first_pkt   <= 1'b0;

                    // Remaining data in this packet after consuming 64B meta
                    if (axis_tcp_recv.tlast)
                        pkt_remaining <= '0;
                    else
                        pkt_remaining <= pkt_len - BEAT_BYTES;

                    // Always send ACK before receiving data
                    state_C <= ST_ACK_META;
                end
            end

            // ============================================
            // Send status ACK to client (64B)
            //   [31:0] = status (0 = OK)
            // ============================================
            ST_ACK_META: begin
                tx_meta_valid <= 1'b1;
                if (tx_meta_valid && tcp_tx_meta.ready) begin
                    tx_meta_valid <= 1'b0;
                    state_C       <= ST_ACK_DATA;
                end
            end

            ST_ACK_DATA: begin
                tx_data_valid <= 1'b1;
                if (tx_data_valid && axis_tcp_send.tready) begin
                    tx_data_valid <= 1'b0;
                    state_C       <= ST_ACK_WAIT;
                end
            end

            ST_ACK_WAIT: begin
                if (tcp_tx_stat.valid) begin
                    if (pkt_remaining > 0)
                        state_C <= ST_SUBMIT_DESC;  // same packet has data after meta
                    else
                        state_C <= ST_WAIT_NOTIFY;  // meta-only packet, wait for data
                end
            end

            // ============================================
            // Submit DMA write descriptor
            // Capped at chunk_size to split large packets
            // ============================================
            ST_SUBMIT_DESC: begin
                timer <= timer + 1;
                if (!sq_wr_valid) begin
                    // Cap descriptor length at chunk_size
                    automatic logic [31:0] max_this = latch_chunk_size - block_recv;
                    automatic logic [31:0] this_desc = (pkt_remaining >= max_this)
                                                       ? max_this : pkt_remaining;

                    sq_wr_desc         <= '0;
                    sq_wr_desc.opcode  <= LOCAL_WRITE;
                    sq_wr_desc.strm    <= STRM_CARD;
                    sq_wr_desc.dest    <= '0;
                    sq_wr_desc.last    <= 1'b1;
                    sq_wr_desc.vaddr   <= mem_base + mem_offset;
                    sq_wr_desc.len     <= this_desc;
                    sq_wr_desc.pid     <= '0;
                    sq_wr_desc.vfid    <= '0;
                    sq_wr_valid        <= 1'b1;

                    desc_len_reg       <= this_desc;
                    desc_fwd           <= '0;
                end

                if (sq_wr_valid && sq_wr.ready) begin
                    state_C <= ST_RECV_DATA;
                end
            end

            // ============================================
            // Forward axis_tcp_recv -> axis_card_send
            // Exits on: tlast (packet end) OR desc_fwd >= desc_len_reg (chunk full)
            // ============================================
            ST_RECV_DATA: begin
                timer <= timer + 1;

                if (axis_tcp_recv.tvalid && axis_card_send[0].tready) begin
                    bytes_recv    <= bytes_recv + BEAT_BYTES;
                    block_recv    <= block_recv + BEAT_BYTES;
                    mem_offset    <= mem_offset + BEAT_BYTES;
                    desc_fwd      <= desc_fwd + BEAT_BYTES;
                    pkt_remaining <= pkt_remaining - BEAT_BYTES;

                    if (axis_tcp_recv.tlast) begin
                        // Packet exhausted
                        pkt_remaining <= '0;
                        state_C       <= ST_WAIT_MEM;
                    end
                    else if (desc_fwd + BEAT_BYTES >= desc_len_reg) begin
                        // Descriptor complete (chunk boundary) — pause, process NVMe
                        state_C <= ST_WAIT_MEM;
                    end
                end
            end

            // ============================================
            // Wait for DMA write completion
            // ============================================
            ST_WAIT_MEM: begin
                timer <= timer + 1;
                if (mem_wr_done)
                    state_C <= ST_CHECK_BLOCK;
            end

            // ============================================
            // Check: chunk_size accumulated OR all data received?
            // Issue exactly 1 NVMe command per chunk, then completion
            // ============================================
            ST_CHECK_BLOCK: begin
                timer <= timer + 1;
                if (block_recv >= latch_chunk_size || bytes_recv >= total_data_len) begin
                    nvme_write_off <= '0;
                    nvme_sent      <= '0;
                    nvme_done      <= '0;
                    state_C        <= ST_NVME_ISSUE;
                end
                else if (pkt_remaining > 0) begin
                    // Same packet has more data -> continue filling this block
                    state_C <= ST_SUBMIT_DESC;
                end
                else begin
                    // Need next TCP packet
                    state_C <= ST_WAIT_NOTIFY;
                end
            end

            // ============================================
            // Issue NVMe write commands (sequential, dev 0)
            // Offset-based: no division or multiplication
            // On SQ-full: pause issuing, drain completions, then resume
            // ============================================
            ST_NVME_ISSUE: begin
                timer <= timer + 1;

                if (nvme_write_off >= block_recv) begin
                    // All commands issued → wait for completions
                    state_C <= ST_NVME_DRAIN;
                end
                else if (nvme_sq_full) begin
                    // SQ full: wait for some completions before retrying
                    // (nvme_sent/nvme_write_off already rolled back)
                end
                else if (!nvme_req_valid) begin
                    automatic logic [31:0] remaining = block_recv - nvme_write_off;
                    automatic logic [31:0] this_len = (remaining >= latch_chunk_size)
                                                      ? latch_chunk_size : remaining;

                    nvme_req.dev_id    <= NVME_DEV_ID;
                    nvme_req.writeRead <= 1'b1;  // write
                    nvme_req.nsid      <= reg_nsid[NSID_BITS-1:0];
                    nvme_req.vaddr     <= mem_base + nvme_write_off;
                    nvme_req.naddr     <= nvme_lba_off + nvme_write_off;
                    nvme_req.len       <= this_len;
                    nvme_req.region_id <= '0;
                    nvme_req_valid     <= 1'b1;
                end

                if (nvme_req_valid && m_nvme_cmd_req.ready) begin
                    nvme_sent      <= nvme_sent + 1;
                    nvme_write_off <= nvme_write_off + latch_chunk_size;
                end
            end

            // ============================================
            // Wait for all NVMe completions
            // ============================================
            ST_NVME_DRAIN: begin
                timer <= timer + 1;
                if (nvme_done >= nvme_sent)
                    state_C <= ST_CPL_META;
            end

            // ============================================
            // Send TCP completion meta
            // ============================================
            ST_CPL_META: begin
                tx_meta_valid <= 1'b1;
                if (tx_meta_valid && tcp_tx_meta.ready) begin
                    tx_meta_valid <= 1'b0;
                    state_C       <= ST_CPL_DATA;
                end
            end

            // ============================================
            // Send TCP completion data (64B beat)
            //   [31:0]   = status (0=ok, else last_error)
            //   [63:32]  = nvme_done count
            //   [127:64] = nvme_lba_off (where this block was written)
            //   [159:128]= block_recv (bytes in this block)
            // ============================================
            ST_CPL_DATA: begin
                tx_data_valid <= 1'b1;
                if (tx_data_valid && axis_tcp_send.tready) begin
                    tx_data_valid <= 1'b0;
                    state_C       <= ST_CPL_WAIT;
                end
            end

            // ============================================
            // Wait for TCP TX stat
            // ============================================
            ST_CPL_WAIT: begin
                if (tcp_tx_stat.valid) begin
                    // Advance LBA offset for next block
                    nvme_lba_off <= nvme_lba_off + block_recv;

                    // Reset block state
                    block_recv <= '0;
                    mem_offset <= '0;

                    if (bytes_recv >= total_data_len)
                        state_C <= ST_DONE;
                    else if (pkt_remaining > 0)
                        state_C <= ST_SUBMIT_DESC;  // same packet, next chunk
                    else
                        state_C <= ST_WAIT_NOTIFY;  // need next TCP packet
                end
            end

            // ============================================
            ST_DONE: begin
                // All data stored. Go back to wait for next transfer.
                is_first_pkt   <= 1'b1;
                naddr_base     <= '0;
                total_data_len <= '0;
                block_recv     <= '0;
                mem_offset     <= '0;
                bytes_recv     <= '0;
                nvme_lba_off   <= '0;
                nvme_sent      <= '0;
                nvme_done      <= '0;
                last_error     <= '0;
                timer          <= '0;
                state_C        <= ST_WAIT_NOTIFY;
            end

            default: state_C <= ST_IDLE;
        endcase
    end
end

// ============================================================
// Combinational outputs
// ============================================================
always_comb begin
    // --- NVMe ---
    m_nvme_cmd_req.valid = nvme_req_valid;
    m_nvme_cmd_req.data  = nvme_req;
    s_nvme_cmd_rsp.ready = 1'b1;
    s_nvme_cpl.ready     = 1'b1;

    // --- DMA write descriptor ---
    sq_wr.valid = sq_wr_valid;
    sq_wr.data  = sq_wr_desc;
    cq_wr.ready = 1'b1;

    // --- TCP notify -> accept ---
    tcp_notify.ready = (state_C == ST_WAIT_NOTIFY);

    // --- TCP rd_pkg ---
    tcp_rd_pkg.valid     = rd_pkg_valid;
    tcp_rd_pkg.data.sid  = session_id;
    tcp_rd_pkg.data.len  = pkt_len;

    // --- TCP rx_meta -> consume ---
    tcp_rx_meta.ready = (state_C == ST_WAIT_RX_META);

    // --- TCP RX data -> card memory ---
    // In ST_RECV_FIRST: consume first beat (meta), don't forward to card
    // In ST_RECV_DATA: forward to axis_card_send
    axis_tcp_recv.tready = (state_C == ST_RECV_FIRST) ||
                           (state_C == ST_RECV_DATA && axis_card_send[0].tready);

    axis_card_send[0].tvalid = (state_C == ST_RECV_DATA) && axis_tcp_recv.tvalid;
    axis_card_send[0].tdata  = axis_tcp_recv.tdata;
    axis_card_send[0].tkeep  = axis_tcp_recv.tkeep;
    axis_card_send[0].tlast  = axis_tcp_recv.tlast;
    axis_card_send[0].tid    = '0;

    // --- Card memory read (unused in store mode) ---
    axis_card_recv[0].tready = 1'b1;

    // --- TCP TX (shared: ACK + completion) ---
    tcp_tx_meta.valid     = tx_meta_valid;
    tcp_tx_meta.data.sid  = session_id;
    tcp_tx_meta.data.len  = 16'd64;   // always 64 bytes

    axis_tcp_send.tvalid  = tx_data_valid;
    axis_tcp_send.tkeep   = {64{1'b1}};
    axis_tcp_send.tlast   = 1'b1;

    // Mux TX data based on state: ACK (status only) vs CPL (full stats)
    if (state_C == ST_ACK_DATA)
        axis_tcp_send.tdata = {480'd0, 32'd0};  // [31:0] = status 0 (OK)
    else
        axis_tcp_send.tdata = {352'd0, block_recv, nvme_lba_off[63:0], nvme_done, {16'd0, last_error}};

    tcp_tx_stat.ready     = 1'b1;
end

// ============================================================
// Tie-off unused
// ============================================================
always_comb begin
    notify.tie_off_m();
    sq_rd.tie_off_m();
    cq_rd.tie_off_s();

    axis_host_recv[0].tready = 1'b1;
    axis_host_send[0].tvalid = 1'b0;
    axis_host_send[0].tdata  = '0;
    axis_host_send[0].tkeep  = '0;
    axis_host_send[0].tlast  = 1'b0;
    axis_host_send[0].tid    = '0;

    tcp_open_req.tie_off_m();
    tcp_open_rsp.tie_off_s();
    tcp_close_req.tie_off_m();
end

// ============================================================
// Debug ILA
// ============================================================
`define EN_ILA_NVME_TCP_STORE
`ifdef EN_ILA_NVME_TCP_STORE
ila_nvme_tcp_store inst_ila (
    .clk    (aclk),
    .probe0 (state_C),                      // 5
    .probe1 (bench_ctrl),                   // 2
    .probe2 (listen_ok),                    // 1
    .probe3 (timer[31:0]),                  // 32
    .probe4 (nvme_sent),                    // 32
    .probe5 (nvme_done),                    // 32
    .probe6 (last_error),                   // 16
    .probe7 (bytes_recv[31:0]),             // 32
    // NVMe
    .probe8 (nvme_req_valid),               // 1
    .probe9 (m_nvme_cmd_req.ready),         // 1
    .probe10(s_nvme_cpl.valid),             // 1
    .probe11(s_nvme_cmd_rsp.valid),         // 1
    // DMA
    .probe12(sq_wr_valid),                  // 1
    .probe13(sq_wr.ready),                  // 1
    .probe14(mem_wr_done),                  // 1
    // TCP RX
    .probe15(tcp_notify.valid),             // 1
    .probe16(axis_tcp_recv.tvalid),         // 1
    .probe17(axis_tcp_recv.tready),         // 1
    .probe18(axis_tcp_recv.tlast),          // 1
    // TCP TX
    .probe19(tx_meta_valid),                // 1
    .probe20(axis_tcp_send.tvalid),         // 1
    // Block tracking
    .probe21(block_recv),                   // 32
    .probe22(mem_offset),                   // 32
    .probe23(session_id),                   // 16
    .probe24(total_data_len[31:0]),         // 32
    .probe25(nvme_write_off)                // 32
);
`endif
