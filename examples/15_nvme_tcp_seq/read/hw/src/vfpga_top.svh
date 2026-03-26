/**
 * NVMe -> TCP Sequential Read (Example 16 — Read)
 *
 * Architecture (RTL-only, no HLS):
 *   1. Listen on TCP port
 *   2. Client connects and sends: [64B meta: total_read_length]
 *   3. For each 1MB block:
 *      a. Issue NVMe read commands (dev 0) -> data to card memory
 *      b. Wait for NVMe completions
 *      c. DMA read card memory -> forward to TCP TX
 *   4. Repeat until total_read_length served
 *
 * NVMe reads are sequential starting from byte offset 0 on device 0.
 * TCP TX is split into 32KB packets (fits 16-bit len field).
 */

import lynxTypes::*;

// ============================================================
// Parameters
// ============================================================
// Block size is now dynamic: uses latch_chunk_size (set from SW via CHUNK_SIZE register)
// Each block = one NVMe read command → DMA to card mem → TCP TX
localparam integer TX_PKT_SIZE     = 32'd32768;     // 32KB per TCP TX packet
localparam integer BEAT_BYTES      = 64;
localparam integer NVME_DEV_ID     = 0;

// ============================================================
// FSM
// ============================================================
typedef enum logic [4:0] {
    ST_IDLE          = 5'd0,
    ST_LISTEN        = 5'd1,
    ST_WAIT_NOTIFY   = 5'd2,   // Wait for client connection + request
    ST_SEND_RD_PKG   = 5'd3,   // TCP rd_pkg
    ST_WAIT_RX_META  = 5'd4,   // Consume TCP rx_meta
    ST_RECV_REQ      = 5'd5,   // Receive client request (first beat: total_read_length)
    ST_NVME_ISSUE    = 5'd6,   // Issue NVMe read commands for current block
    ST_NVME_DRAIN    = 5'd7,   // Wait for NVMe completions
    ST_TX_SETUP      = 5'd8,   // Prepare next TCP TX packet
    ST_TX_DESC       = 5'd9,   // Submit sq_rd (card memory read)
    ST_TX_META       = 5'd10,  // Send tcp_tx_meta
    ST_TX_DATA       = 5'd11,  // Forward axis_card_recv -> axis_tcp_send
    ST_TX_WAIT       = 5'd12,  // Wait for tcp_tx_stat
    ST_CHECK_TX      = 5'd13,  // More TX packets in this block?
    ST_CHECK_BLOCK   = 5'd14,  // More blocks to read?
    ST_DONE          = 5'd15
} state_t;

state_t state_C;

// ============================================================
// Control registers
// ============================================================
logic [1:0]               bench_ctrl;
logic [15:0]              listen_port;
logic [VADDR_BITS-1:0]    mem_base;
logic [63:0]              reg_nsid;
logic [31:0]              reg_chunk_size;

logic [3:0]               fsm_state_out;
logic                     listen_ok;
logic [63:0]              timer;
logic [31:0]              nvme_sent;
logic [31:0]              nvme_done;
logic [15:0]              last_error;
logic [63:0]              bytes_sent;
logic [63:0]              nvme_lba_off_out;

nvme_tcp_read_ctrl inst_ctrl (
    .aclk(aclk), .aresetn(aresetn), .axi_ctrl(axi_ctrl),
    .bench_ctrl(bench_ctrl), .listen_port(listen_port),
    .mem_base(mem_base), .nsid(reg_nsid), .chunk_size(reg_chunk_size),
    .fsm_state(fsm_state_out), .listen_ok(listen_ok),
    .timer(timer), .nvme_sent(nvme_sent), .nvme_done(nvme_done),
    .last_error(last_error), .bytes_sent(bytes_sent),
    .nvme_lba_off(nvme_lba_off_out)
);

assign fsm_state_out = state_C[3:0];

// ============================================================
// Internal state
// ============================================================
logic [63:0]  naddr_base;       // Client-specified NVMe start byte offset
logic [63:0]  total_read_len;   // Client-specified read length
logic [TCP_SESSION_BITS-1:0] session_id;
logic [TCP_LEN_BITS-1:0]     pkt_len;

// Block tracking
logic [63:0]  nvme_lba_off;     // Current NVMe LBA byte offset (starts from naddr_base)
logic [31:0]  block_size;       // Actual size of current block
logic [31:0]  nvme_read_off;    // Offset within block for NVMe reads

// TX tracking within a block
logic [31:0]  tx_offset;        // Offset within block for current TX packet
logic [31:0]  tx_pkt_len;       // Length of current TX packet
logic [31:0]  tx_byte_count;    // Bytes forwarded in current TX packet

// NVMe
logic         nvme_req_valid;
nvme_user_req_t nvme_req;

// SQ-full retry
logic         nvme_sq_full;
logic [31:0]  nvme_err_count;

// DMA read descriptor
logic         sq_rd_valid;
req_t         sq_rd_desc;
logic         mem_rd_done;

// TCP
logic         rd_pkg_valid;
logic         tx_meta_valid;

// Latched
logic [31:0]  latch_chunk_size;

assign nvme_lba_off_out = nvme_lba_off;

// ============================================================
// TCP listen
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
// DMA read completion tracking
// ============================================================
always_ff @(posedge aclk) begin
    if (!aresetn)
        mem_rd_done <= 1'b0;
    else if (state_C == ST_TX_DESC)
        mem_rd_done <= 1'b0;
    else if (cq_rd.valid)
        mem_rd_done <= 1'b1;
end

// ============================================================
// Main FSM
// ============================================================
always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        state_C         <= ST_IDLE;
        total_read_len  <= '0;
        session_id      <= '0;
        pkt_len         <= '0;
        nvme_lba_off    <= '0;
        block_size      <= '0;
        nvme_read_off   <= '0;
        tx_offset       <= '0;
        tx_pkt_len      <= '0;
        tx_byte_count   <= '0;
        nvme_req_valid  <= 1'b0;
        nvme_req        <= '0;
        nvme_sent       <= '0;
        nvme_done       <= '0;
        nvme_sq_full    <= 1'b0;
        nvme_err_count  <= '0;
        sq_rd_valid     <= 1'b0;
        sq_rd_desc      <= '0;
        rd_pkg_valid    <= 1'b0;
        tx_meta_valid   <= 1'b0;
        last_error      <= '0;
        timer           <= '0;
        bytes_sent      <= '0;
        latch_chunk_size <= 32'd4096;
    end
    else begin
        // --- Clear one-shot signals ---
        if (nvme_req_valid && m_nvme_cmd_req.ready)
            nvme_req_valid <= 1'b0;
        if (sq_rd_valid && sq_rd.ready)
            sq_rd_valid <= 1'b0;
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
                // SQ full: roll back nvme_sent & nvme_read_off so we retry
                nvme_sq_full  <= 1'b1;
                nvme_sent     <= nvme_sent - 1;
                nvme_read_off <= nvme_read_off - latch_chunk_size;
            end
        end

        case (state_C)
            // ============================================
            ST_IDLE: begin
                if (go_pulse) begin
                    naddr_base       <= '0;
                    total_read_len   <= '0;
                    nvme_lba_off     <= '0;
                    bytes_sent       <= '0;
                    nvme_sent        <= '0;
                    nvme_done        <= '0;
                    last_error       <= '0;
                    timer            <= '0;
                    latch_chunk_size <= (reg_chunk_size != 0) ? reg_chunk_size : 32'd4096;
                    state_C          <= ST_WAIT_NOTIFY;
                end
            end

            // ============================================
            ST_WAIT_NOTIFY: begin
                timer <= timer + 1;
                if (tcp_notify.valid) begin
                    session_id <= tcp_notify.data.sid;
                    pkt_len    <= tcp_notify.data.len;
                    if (tcp_notify.data.closed)
                        state_C <= ST_DONE;
                    else if (tcp_notify.data.len != 0)
                        state_C <= ST_SEND_RD_PKG;
                end
            end

            // ============================================
            ST_SEND_RD_PKG: begin
                timer <= timer + 1;
                if (!rd_pkg_valid)
                    rd_pkg_valid <= 1'b1;
                if (rd_pkg_valid && tcp_rd_pkg.ready)
                    state_C <= ST_WAIT_RX_META;
            end

            // ============================================
            ST_WAIT_RX_META: begin
                timer <= timer + 1;
                if (tcp_rx_meta.valid)
                    state_C <= ST_RECV_REQ;
            end

            // ============================================
            // Receive client request:
            //   [63:0]   = naddr_base  (NVMe start byte offset)
            //   [127:64] = read_length (total bytes to read)
            // ============================================
            ST_RECV_REQ: begin
                timer <= timer + 1;
                if (axis_tcp_recv.tvalid) begin
                    naddr_base     <= axis_tcp_recv.tdata[63:0];
                    total_read_len <= axis_tcp_recv.tdata[127:64];
                    nvme_lba_off   <= axis_tcp_recv.tdata[63:0];  // start from naddr_base
                    timer          <= '0;
                    state_C        <= ST_NVME_ISSUE;

                    // Setup first block
                    block_size    <= (axis_tcp_recv.tdata[127:64] >= latch_chunk_size)
                                     ? latch_chunk_size
                                     : axis_tcp_recv.tdata[95:64];
                    nvme_read_off <= '0;
                    nvme_sent     <= '0;
                    nvme_done     <= '0;
                end
            end

            // ============================================
            // Issue NVMe read commands for current block
            // On SQ-full: pause issuing, drain completions, then resume
            // ============================================
            ST_NVME_ISSUE: begin
                timer <= timer + 1;

                if (nvme_read_off >= block_size) begin
                    state_C <= ST_NVME_DRAIN;
                end
                else if (nvme_sq_full) begin
                    // SQ full: wait for some completions before retrying
                    // (nvme_sent/nvme_read_off already rolled back)
                end
                else if (!nvme_req_valid) begin
                    automatic logic [31:0] remaining = block_size - nvme_read_off;
                    automatic logic [31:0] this_len = (remaining >= latch_chunk_size)
                                                      ? latch_chunk_size : remaining;

                    nvme_req.dev_id    <= NVME_DEV_ID;
                    nvme_req.writeRead <= 1'b0;  // read
                    nvme_req.nsid      <= reg_nsid[NSID_BITS-1:0];
                    nvme_req.vaddr     <= mem_base + nvme_read_off;
                    nvme_req.naddr     <= nvme_lba_off + nvme_read_off;
                    nvme_req.len       <= this_len;
                    nvme_req.region_id <= '0;
                    nvme_req_valid     <= 1'b1;
                end

                if (nvme_req_valid && m_nvme_cmd_req.ready) begin
                    nvme_sent     <= nvme_sent + 1;
                    nvme_read_off <= nvme_read_off + latch_chunk_size;
                end
            end

            // ============================================
            ST_NVME_DRAIN: begin
                timer <= timer + 1;
                if (nvme_done >= nvme_sent) begin
                    // Data is now in card memory. Start TCP TX.
                    tx_offset <= '0;
                    state_C   <= ST_TX_SETUP;
                end
            end

            // ============================================
            // Prepare next TCP TX packet
            // ============================================
            ST_TX_SETUP: begin
                timer <= timer + 1;
                if (tx_offset >= block_size) begin
                    state_C <= ST_CHECK_BLOCK;
                end
                else begin
                    // Compute this TX packet size
                    if ((block_size - tx_offset) >= TX_PKT_SIZE)
                        tx_pkt_len <= TX_PKT_SIZE;
                    else
                        tx_pkt_len <= block_size - tx_offset;

                    tx_byte_count <= '0;
                    state_C       <= ST_TX_DESC;
                end
            end

            // ============================================
            // Submit card memory read descriptor
            // ============================================
            ST_TX_DESC: begin
                timer <= timer + 1;
                if (!sq_rd_valid) begin
                    sq_rd_desc         <= '0;
                    sq_rd_desc.opcode  <= LOCAL_READ;
                    sq_rd_desc.strm    <= STRM_CARD;
                    sq_rd_desc.dest    <= '0;
                    sq_rd_desc.last    <= 1'b1;
                    sq_rd_desc.vaddr   <= mem_base + tx_offset;
                    sq_rd_desc.len     <= tx_pkt_len;
                    sq_rd_desc.pid     <= '0;
                    sq_rd_desc.vfid    <= '0;
                    sq_rd_valid        <= 1'b1;
                end
                if (sq_rd_valid && sq_rd.ready)
                    state_C <= ST_TX_META;
            end

            // ============================================
            // Send tcp_tx_meta for this packet
            // ============================================
            ST_TX_META: begin
                timer <= timer + 1;
                tx_meta_valid <= 1'b1;
                if (tx_meta_valid && tcp_tx_meta.ready) begin
                    tx_meta_valid <= 1'b0;
                    state_C       <= ST_TX_DATA;
                end
            end

            // ============================================
            // Forward axis_card_recv -> axis_tcp_send
            // ============================================
            ST_TX_DATA: begin
                timer <= timer + 1;
                if (axis_card_recv[0].tvalid && axis_tcp_send.tready) begin
                    tx_byte_count <= tx_byte_count + BEAT_BYTES;
                    bytes_sent    <= bytes_sent + BEAT_BYTES;
                end

                if (axis_card_recv[0].tvalid && axis_card_recv[0].tlast && axis_tcp_send.tready) begin
                    state_C <= ST_TX_WAIT;
                end
            end

            // ============================================
            ST_TX_WAIT: begin
                timer <= timer + 1;
                if (tcp_tx_stat.valid) begin
                    tx_offset <= tx_offset + tx_pkt_len;
                    state_C   <= ST_CHECK_TX;
                end
            end

            // ============================================
            // More TX packets in this block?
            // ============================================
            ST_CHECK_TX: begin
                timer <= timer + 1;
                if (tx_offset >= block_size)
                    state_C <= ST_CHECK_BLOCK;
                else
                    state_C <= ST_TX_SETUP;
            end

            // ============================================
            // More blocks to read?
            // ============================================
            ST_CHECK_BLOCK: begin
                timer <= timer + 1;
                nvme_lba_off <= nvme_lba_off + block_size;

                if (nvme_lba_off + block_size >= naddr_base + total_read_len) begin
                    state_C <= ST_DONE;
                end
                else begin
                    // Setup next block
                    automatic logic [63:0] remaining = (naddr_base + total_read_len) - (nvme_lba_off + block_size);
                    block_size    <= (remaining >= latch_chunk_size) ? latch_chunk_size : remaining[31:0];
                    nvme_read_off <= '0;
                    nvme_sent     <= '0;
                    nvme_done     <= '0;
                    tx_offset     <= '0;
                    state_C       <= ST_NVME_ISSUE;
                end
            end

            // ============================================
            ST_DONE: begin
                naddr_base     <= '0;
                total_read_len <= '0;
                nvme_lba_off   <= '0;
                bytes_sent     <= '0;
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

    // --- DMA read descriptor ---
    sq_rd.valid = sq_rd_valid;
    sq_rd.data  = sq_rd_desc;
    cq_rd.ready = 1'b1;

    // --- DMA write (unused in read mode) ---
    sq_wr.tie_off_m();
    cq_wr.tie_off_s();

    // --- TCP notify ---
    tcp_notify.ready = (state_C == ST_WAIT_NOTIFY);

    // --- TCP rd_pkg ---
    tcp_rd_pkg.valid     = rd_pkg_valid;
    tcp_rd_pkg.data.sid  = session_id;
    tcp_rd_pkg.data.len  = pkt_len;

    // --- TCP rx_meta ---
    tcp_rx_meta.ready = (state_C == ST_WAIT_RX_META);

    // --- TCP RX data (consume request packet) ---
    axis_tcp_recv.tready = (state_C == ST_RECV_REQ);

    // --- Card memory read -> TCP TX ---
    axis_card_recv[0].tready = (state_C == ST_TX_DATA) && axis_tcp_send.tready;

    axis_tcp_send.tvalid = (state_C == ST_TX_DATA) && axis_card_recv[0].tvalid;
    axis_tcp_send.tdata  = axis_card_recv[0].tdata;
    axis_tcp_send.tkeep  = axis_card_recv[0].tkeep;
    axis_tcp_send.tlast  = axis_card_recv[0].tlast;

    // --- TCP TX meta ---
    tcp_tx_meta.valid     = tx_meta_valid;
    tcp_tx_meta.data.sid  = session_id;
    tcp_tx_meta.data.len  = tx_pkt_len[15:0];

    tcp_tx_stat.ready     = 1'b1;

    // --- Card memory write (unused) ---
    axis_card_send[0].tvalid = 1'b0;
    axis_card_send[0].tdata  = '0;
    axis_card_send[0].tkeep  = '0;
    axis_card_send[0].tlast  = 1'b0;
    axis_card_send[0].tid    = '0;
end

// ============================================================
// Tie-off unused
// ============================================================
always_comb begin
    notify.tie_off_m();

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
`define EN_ILA_NVME_TCP_READ
`ifdef EN_ILA_NVME_TCP_READ
ila_nvme_tcp_read inst_ila (
    .clk    (aclk),
    .probe0 (state_C),                      // 5
    .probe1 (bench_ctrl),                   // 2
    .probe2 (listen_ok),                    // 1
    .probe3 (timer[31:0]),                  // 32
    .probe4 (nvme_sent),                    // 32
    .probe5 (nvme_done),                    // 32
    .probe6 (last_error),                   // 16
    .probe7 (bytes_sent[31:0]),             // 32
    // NVMe
    .probe8 (nvme_req_valid),               // 1
    .probe9 (m_nvme_cmd_req.ready),         // 1
    .probe10(s_nvme_cpl.valid),             // 1
    // DMA read
    .probe11(sq_rd_valid),                  // 1
    .probe12(sq_rd.ready),                  // 1
    .probe13(cq_rd.valid),                  // 1
    // TCP TX
    .probe14(tx_meta_valid),                // 1
    .probe15(axis_tcp_send.tvalid),         // 1
    .probe16(axis_tcp_send.tready),         // 1
    .probe17(axis_tcp_send.tlast),          // 1
    // Card recv
    .probe18(axis_card_recv[0].tvalid),     // 1
    .probe19(axis_card_recv[0].tready),     // 1
    // Block tracking
    .probe20(block_size),                   // 32
    .probe21(tx_offset),                    // 32
    .probe22(tx_pkt_len),                   // 32
    .probe23(session_id)                    // 16
);
`endif
