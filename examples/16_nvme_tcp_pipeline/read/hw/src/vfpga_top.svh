/**
 * NVMe TCP Pipelined Read (Example 16)
 *
 * Architecture:
 *   Ring buffer in HBM, 3 independent FSMs chained:
 *     NVME FSM: NVMe read from SSD → HBM ring[wp]
 *     TX FSM:   HBM ring[rp] → DMA read → TCP TX data
 *     LISTEN:   TCP listen + meta parse (one-shot setup)
 *
 *   Ring buffer pointers:
 *     wp:       next slot written by NVMe (NVME FSM produces)
 *     rp:       next slot to send via TCP (TX FSM consumes)
 *
 *   Backpressure:
 *     Ring full:  wp - rp >= n_slots → NVME FSM stalls
 *     TX empty:   wp == rp → TX FSM stalls
 *
 *   Meta format (64B from client):
 *     [63:0]   = naddr_base  (NVMe start byte offset)
 *     [127:64] = read_length (total bytes to read)
 *
 *   No per-slot completion — data IS the response.
 *   TX sends chunk_size per TCP TX cycle (split into 32KB packets).
 */

import lynxTypes::*;

// ============================================================
// Parameters
// ============================================================
localparam integer TX_PKT_SIZE = 32'd32768;  // 32KB per TCP TX packet
localparam integer BEAT_BYTES  = 64;
localparam integer NVME_DEV_ID = 0;

// ============================================================
// Control registers
// ============================================================
logic [1:0]               bench_ctrl;
logic [15:0]              listen_port;
logic [VADDR_BITS-1:0]    hbm_base;
logic [4:0]               reg_chunk_bits;
logic [31:0]              reg_slot_mask;
logic [63:0]              reg_nsid;

logic [7:0]               status_bits;
logic                     listen_ok;
logic [63:0]              timer;
logic [31:0]              nvme_sent;
logic [31:0]              nvme_done;
logic [15:0]              last_error;
logic [63:0]              bytes_sent;
logic [31:0]              wr_ptr_out;
logic [31:0]              rd_ptr_out;

nvme_tcp_pipe_read_ctrl inst_ctrl (
    .aclk(aclk), .aresetn(aresetn), .axi_ctrl(axi_ctrl),
    .bench_ctrl(bench_ctrl), .listen_port(listen_port),
    .hbm_base(hbm_base), .chunk_bits(reg_chunk_bits),
    .slot_mask(reg_slot_mask), .nsid(reg_nsid),
    .status_bits(status_bits), .listen_ok(listen_ok),
    .timer(timer), .nvme_sent(nvme_sent), .nvme_done(nvme_done),
    .last_error(last_error), .bytes_sent(bytes_sent),
    .wr_ptr(wr_ptr_out), .rd_ptr(rd_ptr_out)
);

// ============================================================
// Latched parameters
// ============================================================
logic [VADDR_BITS-1:0]    latch_hbm_base;
logic [31:0]              latch_chunk_size;
logic [31:0]              latch_n_slots;
logic [4:0]               latch_chunk_bits;
logic [31:0]              latch_slot_mask;
logic [NSID_BITS-1:0]     latch_nsid;

// ============================================================
// Ring buffer pointers
// ============================================================
logic [31:0]              wp;      // NVMe FSM writes here
logic [31:0]              rp;      // TX FSM reads from here

assign wr_ptr_out = wp;
assign rd_ptr_out = rp;

wire ring_full  = (wp - rp) >= latch_n_slots;
wire tx_pending = (wp != rp);

// ============================================================
// App meta
// ============================================================
logic [63:0]              naddr_base;
logic [63:0]              total_read_len;
logic [63:0]              nvme_lba_off;

// ============================================================
// TCP session
// ============================================================
logic [TCP_SESSION_BITS-1:0] session_id;

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
// META FSM: TCP RX → parse meta → kick NVME FSM
// ============================================================
typedef enum logic [2:0] {
    META_IDLE         = 3'd0,
    META_WAIT_NOTIFY  = 3'd1,
    META_SEND_RD_PKG  = 3'd2,
    META_WAIT_RX_META = 3'd3,
    META_RECV_REQ     = 3'd4,
    META_RUNNING      = 3'd5
} meta_state_t;

meta_state_t meta_state;

logic        meta_rd_pkg_valid;
logic [TCP_LEN_BITS-1:0] meta_pkt_len;
logic        transfer_active;  // set after meta parsed, cleared on done
logic        tx_transfer_done; // TX FSM → META FSM handshake

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        meta_state       <= META_IDLE;
        naddr_base       <= '0;
        total_read_len   <= '0;
        session_id       <= '0;
        meta_pkt_len     <= '0;
        meta_rd_pkg_valid <= 1'b0;
        transfer_active  <= 1'b0;
    end
    else begin
        if (meta_rd_pkg_valid && tcp_rd_pkg.ready)
            meta_rd_pkg_valid <= 1'b0;

        case (meta_state)
            META_IDLE: begin
                if (go_pulse) begin
                    naddr_base      <= '0;
                    total_read_len  <= '0;
                    transfer_active <= 1'b0;
                    latch_hbm_base   <= hbm_base;
                    latch_chunk_bits <= reg_chunk_bits;
                    latch_slot_mask  <= reg_slot_mask;
                    latch_chunk_size <= 32'd1 << reg_chunk_bits;
                    latch_n_slots    <= reg_slot_mask + 1;
                    latch_nsid       <= reg_nsid[NSID_BITS-1:0];
                    timer           <= '0;
                    meta_state      <= META_WAIT_NOTIFY;
                end
            end

            META_WAIT_NOTIFY: begin
                timer <= timer + 1;
                if (tcp_notify.valid) begin
                    session_id   <= tcp_notify.data.sid;
                    meta_pkt_len <= tcp_notify.data.len;
                    if (tcp_notify.data.closed)
                        meta_state <= META_IDLE;
                    else if (tcp_notify.data.len != 0)
                        meta_state <= META_SEND_RD_PKG;
                end
            end

            META_SEND_RD_PKG: begin
                timer <= timer + 1;
                if (!meta_rd_pkg_valid)
                    meta_rd_pkg_valid <= 1'b1;
                if (meta_rd_pkg_valid && tcp_rd_pkg.ready)
                    meta_state <= META_WAIT_RX_META;
            end

            META_WAIT_RX_META: begin
                timer <= timer + 1;
                if (tcp_rx_meta.valid)
                    meta_state <= META_RECV_REQ;
            end

            // Parse: [63:0]=naddr, [127:64]=length
            META_RECV_REQ: begin
                timer <= timer + 1;
                if (axis_tcp_recv.tvalid) begin
                    naddr_base     <= axis_tcp_recv.tdata[63:0];
                    total_read_len <= axis_tcp_recv.tdata[127:64];
                    transfer_active <= 1'b1;
                    timer          <= '0;
                    meta_state     <= META_RUNNING;
                end
            end

            // Stay here until transfer completes
            META_RUNNING: begin
                timer <= timer + 1;
                if (tx_transfer_done) begin
                    transfer_active <= 1'b0;
                    timer           <= '0;
                    meta_state      <= META_WAIT_NOTIFY;
                end
            end

            default: meta_state <= META_IDLE;
        endcase
    end
end

// ============================================================
// NVME FSM: NVMe read → HBM ring[wp]
// ============================================================
typedef enum logic [2:0] {
    NV_IDLE       = 3'd0,
    NV_WAIT_META  = 3'd1,
    NV_ISSUE      = 3'd2,
    NV_DRAIN      = 3'd3,
    NV_DONE       = 3'd4
} nv_state_t;

nv_state_t nv_state;

logic         nv_req_valid;
nvme_user_req_t nv_req;
logic [63:0]  nv_bytes_issued;  // total NVMe bytes issued

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        nv_state       <= NV_IDLE;
        wp             <= '0;
        nvme_sent      <= '0;
        nvme_done      <= '0;
        nv_req_valid   <= 1'b0;
        nv_req         <= '0;
        last_error     <= '0;
        nvme_lba_off   <= '0;
        nv_bytes_issued <= '0;
    end
    else begin
        // Clear one-shot
        if (nv_req_valid && m_nvme_cmd_req.ready)
            nv_req_valid <= 1'b0;

        // NVMe completions (always)
        if (s_nvme_cpl.valid)
            nvme_done <= nvme_done + 1;
        if (s_nvme_cmd_rsp.valid && s_nvme_cmd_rsp.data[15:0] != 16'h0000)
            last_error <= s_nvme_cmd_rsp.data[15:0];

        case (nv_state)
            NV_IDLE: begin
                if (go_pulse) begin
                    wp              <= '0;
                    nvme_sent       <= '0;
                    nvme_done       <= '0;
                    last_error      <= '0;
                    nvme_lba_off    <= '0;
                    nv_bytes_issued <= '0;
                    nv_state        <= NV_WAIT_META;
                end
            end

            // Wait for meta FSM to parse the request
            NV_WAIT_META: begin
                if (transfer_active) begin
                    nvme_lba_off <= naddr_base;
                    nv_state     <= NV_ISSUE;
                end
            end

            // Issue NVMe read for next slot
            NV_ISSUE: begin
                if (nv_bytes_issued >= total_read_len) begin
                    nv_state <= NV_DONE;
                end
                else if (ring_full) begin
                    // Ring full — wait for TX to free slots
                end
                else if (!nv_req_valid) begin
                    automatic logic [63:0] remaining = total_read_len - nv_bytes_issued;
                    automatic logic [31:0] this_len = (remaining >= latch_chunk_size)
                                                      ? latch_chunk_size : remaining[31:0];

                    nv_req.dev_id    <= NVME_DEV_ID;
                    nv_req.writeRead <= 1'b0;  // read
                    nv_req.nsid      <= latch_nsid;
                    nv_req.vaddr     <= latch_hbm_base
                                      + ((wp & latch_slot_mask) << latch_chunk_bits);
                    nv_req.naddr     <= nvme_lba_off;
                    nv_req.len       <= this_len;
                    nv_req.region_id <= '0;
                    nv_req_valid     <= 1'b1;
                end

                if (nv_req_valid && m_nvme_cmd_req.ready) begin
                    nvme_sent <= nvme_sent + 1;
                    nv_state  <= NV_DRAIN;
                end
            end

            // Wait for NVMe completion → advance wp
            NV_DRAIN: begin
                if (nvme_done >= nvme_sent) begin
                    wp              <= wp + 1;
                    nvme_lba_off    <= nvme_lba_off + latch_chunk_size;
                    nv_bytes_issued <= nv_bytes_issued + latch_chunk_size;
                    nv_state        <= NV_ISSUE;
                end
            end

            NV_DONE: begin
                if (!transfer_active) begin
                    wp              <= '0;
                    nvme_sent       <= '0;
                    nvme_done       <= '0;
                    last_error      <= '0;
                    nvme_lba_off    <= '0;
                    nv_bytes_issued <= '0;
                    nv_state        <= NV_WAIT_META;
                end
            end

            default: nv_state <= NV_IDLE;
        endcase
    end
end

// ============================================================
// TX FSM: HBM ring[rp] → DMA read → TCP TX
// ============================================================
typedef enum logic [3:0] {
    TX_IDLE      = 4'd0,
    TX_WAIT_META = 4'd1,
    TX_WAIT_SLOT = 4'd2,
    TX_SETUP     = 4'd3,
    TX_DESC      = 4'd4,
    TX_META      = 4'd5,
    TX_DATA      = 4'd6,
    TX_WAIT      = 4'd7,
    TX_CHECK_PKT = 4'd8,
    TX_NEXT_SLOT = 4'd9,
    TX_DONE      = 4'd10
} tx_state_t;

tx_state_t tx_state;

logic         tx_sq_rd_valid;
req_t         tx_sq_rd_desc;
logic         tx_meta_valid;

logic [31:0]  tx_slot_size;     // actual size of current slot (may be < chunk for last)
logic [31:0]  tx_pkt_offset;    // offset within slot for current TX packet
logic [31:0]  tx_pkt_len;       // current TX packet length
logic [63:0]  tx_bytes_sent;    // total bytes sent via TCP

// DMA read completion tracking
logic mem_rd_done;
always_ff @(posedge aclk) begin
    if (!aresetn)
        mem_rd_done <= 1'b0;
    else if (tx_state == TX_DESC)
        mem_rd_done <= 1'b0;
    else if (cq_rd.valid)
        mem_rd_done <= 1'b1;
end

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        tx_state         <= TX_IDLE;
        rp               <= '0;
        tx_sq_rd_valid   <= 1'b0;
        tx_sq_rd_desc    <= '0;
        tx_meta_valid    <= 1'b0;
        tx_slot_size     <= '0;
        tx_pkt_offset    <= '0;
        tx_pkt_len       <= '0;
        tx_bytes_sent    <= '0;
        bytes_sent       <= '0;
        tx_transfer_done <= 1'b0;
    end
    else begin
        // Clear one-shot
        if (tx_sq_rd_valid && sq_rd.ready)
            tx_sq_rd_valid <= 1'b0;

        case (tx_state)
            TX_IDLE: begin
                if (go_pulse) begin
                    rp               <= '0;
                    tx_bytes_sent    <= '0;
                    bytes_sent       <= '0;
                    tx_transfer_done <= 1'b0;
                    tx_state         <= TX_WAIT_META;
                end
            end

            TX_WAIT_META: begin
                if (transfer_active) begin
                    tx_transfer_done <= 1'b0;
                    tx_state         <= TX_WAIT_SLOT;
                end
            end

            // Wait for NVMe FSM to fill a slot
            TX_WAIT_SLOT: begin
                if (tx_bytes_sent >= total_read_len) begin
                    tx_state <= TX_DONE;
                end
                else if (tx_pending) begin
                    // Compute slot size (last slot may be smaller)
                    automatic logic [63:0] remaining = total_read_len - tx_bytes_sent;
                    tx_slot_size  <= (remaining >= latch_chunk_size)
                                    ? latch_chunk_size : remaining[31:0];
                    tx_pkt_offset <= '0;
                    tx_state      <= TX_SETUP;
                end
            end

            // Prepare next 32KB TCP TX packet within this slot
            TX_SETUP: begin
                if (tx_pkt_offset >= tx_slot_size) begin
                    tx_state <= TX_NEXT_SLOT;
                end
                else begin
                    automatic logic [31:0] remain_in_slot = tx_slot_size - tx_pkt_offset;
                    tx_pkt_len <= (remain_in_slot >= TX_PKT_SIZE)
                                 ? TX_PKT_SIZE : remain_in_slot;
                    tx_state   <= TX_DESC;
                end
            end

            // Submit card memory read descriptor
            TX_DESC: begin
                if (!tx_sq_rd_valid) begin
                    tx_sq_rd_desc         <= '0;
                    tx_sq_rd_desc.opcode  <= LOCAL_READ;
                    tx_sq_rd_desc.strm    <= STRM_CARD;
                    tx_sq_rd_desc.dest    <= '0;
                    tx_sq_rd_desc.last    <= 1'b1;
                    tx_sq_rd_desc.vaddr   <= latch_hbm_base
                                           + ((rp & latch_slot_mask) << latch_chunk_bits)
                                           + tx_pkt_offset;
                    tx_sq_rd_desc.len     <= tx_pkt_len;
                    tx_sq_rd_desc.pid     <= '0;
                    tx_sq_rd_desc.vfid    <= '0;
                    tx_sq_rd_valid        <= 1'b1;
                end
                if (tx_sq_rd_valid && sq_rd.ready)
                    tx_state <= TX_META;
            end

            // Send tcp_tx_meta
            TX_META: begin
                tx_meta_valid <= 1'b1;
                if (tx_meta_valid && tcp_tx_meta.ready) begin
                    tx_meta_valid <= 1'b0;
                    tx_state      <= TX_DATA;
                end
            end

            // Forward axis_card_recv → axis_tcp_send
            TX_DATA: begin
                if (axis_card_recv[0].tvalid && axis_tcp_send.tready) begin
                    bytes_sent <= bytes_sent + BEAT_BYTES;
                end

                if (axis_card_recv[0].tvalid && axis_card_recv[0].tlast && axis_tcp_send.tready)
                    tx_state <= TX_WAIT;
            end

            // Wait for tcp_tx_stat
            TX_WAIT: begin
                if (tcp_tx_stat.valid) begin
                    tx_pkt_offset <= tx_pkt_offset + tx_pkt_len;
                    tx_state      <= TX_CHECK_PKT;
                end
            end

            // More packets in this slot?
            TX_CHECK_PKT: begin
                if (tx_pkt_offset >= tx_slot_size)
                    tx_state <= TX_NEXT_SLOT;
                else
                    tx_state <= TX_SETUP;
            end

            // Slot fully sent → advance rp
            TX_NEXT_SLOT: begin
                rp            <= rp + 1;
                tx_bytes_sent <= tx_bytes_sent + tx_slot_size;

                if (tx_bytes_sent + tx_slot_size >= total_read_len) begin
                    tx_transfer_done <= 1'b1;
                    tx_state         <= TX_DONE;
                end
                else
                    tx_state <= TX_WAIT_SLOT;
            end

            TX_DONE: begin
                tx_transfer_done <= 1'b1;
                if (!transfer_active) begin
                    rp               <= '0;
                    tx_bytes_sent    <= '0;
                    bytes_sent       <= '0;
                    tx_transfer_done <= 1'b0;
                    tx_state         <= TX_WAIT_META;
                end
            end

            default: tx_state <= TX_IDLE;
        endcase
    end
end

// ============================================================
// Status bits
// ============================================================
assign status_bits = {2'd0, listen_ok, transfer_active, tx_state[1:0], nv_state[1:0]};

// ============================================================
// Combinational outputs
// ============================================================
always_comb begin
    // --- NVMe ---
    m_nvme_cmd_req.valid = nv_req_valid;
    m_nvme_cmd_req.data  = nv_req;
    s_nvme_cmd_rsp.ready = 1'b1;
    s_nvme_cpl.ready     = 1'b1;

    // --- DMA write (unused in read) ---
    sq_wr.tie_off_m();
    cq_wr.tie_off_s();

    // --- DMA read descriptor (from TX FSM) ---
    sq_rd.valid = tx_sq_rd_valid;
    sq_rd.data  = tx_sq_rd_desc;
    cq_rd.ready = 1'b1;

    // --- TCP notify ---
    tcp_notify.ready = (meta_state == META_WAIT_NOTIFY);

    // --- TCP rd_pkg ---
    tcp_rd_pkg.valid     = meta_rd_pkg_valid;
    tcp_rd_pkg.data.sid  = session_id;
    tcp_rd_pkg.data.len  = meta_pkt_len;

    // --- TCP rx_meta ---
    tcp_rx_meta.ready = (meta_state == META_WAIT_RX_META);

    // --- TCP RX data (consume meta packet only) ---
    axis_tcp_recv.tready = (meta_state == META_RECV_REQ);

    // --- Card memory read → TCP TX ---
    axis_card_recv[0].tready = (tx_state == TX_DATA) && axis_tcp_send.tready;

    axis_tcp_send.tvalid = (tx_state == TX_DATA) && axis_card_recv[0].tvalid;
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
