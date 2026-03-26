/**
 * NVMe TCP Pipelined Store (Example 16)
 *
 * Architecture:
 *   Ring buffer in HBM, 4 independent FSMs chained:
 *     RX FSM:   TCP RX → HBM write (ring[wp])
 *     NVME FSM: HBM ring[rp_nvme] → NVMe write to SSD
 *     TX FSM:   TCP TX completions + ACK (priority: ACK > CPL)
 *     LISTEN:   TCP listen (combinational, always active)
 *
 *   Ring buffer pointers:
 *     wp:       next slot to write (RX FSM produces)
 *     rp_nvme:  next slot for NVMe (NVME FSM consumes wp, produces rp_nvme)
 *     rp_free:  next slot freed after TCP cpl sent (TX FSM consumes rp_nvme)
 *
 *   Backpressure:
 *     Ring full:  wp - rp_free >= n_slots → RX FSM stalls
 *     NVMe empty: wp == rp_nvme → NVME FSM stalls
 *     CPL empty:  rp_nvme == rp_free → TX FSM stalls (no cpl to send)
 *
 *   Meta format (first 64B beat from client):
 *     [63:0]   = naddr_base  (NVMe start byte offset)
 *     [127:64] = data_length (total bytes to write)
 *
 *   ACK (64B to client after meta):
 *     [31:0] = status (0 = OK)
 *
 *   Completion (64B per chunk):
 *     [31:0]   = status (0=ok, else last_error)
 *     [63:32]  = slot_idx
 *     [127:64] = nvme_lba_off
 *     [159:128]= chunk_size
 */

import lynxTypes::*;

// ============================================================
// Parameters
// ============================================================
localparam integer BEAT_BYTES  = 64;
localparam integer NVME_DEV_ID = 0;

// ============================================================
// Control registers (from AXI-Lite parser)
// ============================================================
logic [1:0]               bench_ctrl;
logic [15:0]              listen_port;
logic [VADDR_BITS-1:0]    hbm_base;
logic [4:0]               reg_chunk_bits;
logic [31:0]              reg_slot_mask;
logic [63:0]              reg_nsid;

// Status (to parser → SW)
logic [7:0]               status_bits;
logic                     listen_ok;
logic [63:0]              timer;
logic [31:0]              nvme_sent;
logic [31:0]              nvme_done;
logic [15:0]              last_error;
logic [63:0]              bytes_total;
logic [31:0]              wr_ptr_out;
logic [31:0]              rd_nvme_ptr_out;

// ============================================================
// AXI-Lite Control Parser
// ============================================================
nvme_tcp_pipe_store_ctrl inst_ctrl (
    .aclk(aclk), .aresetn(aresetn), .axi_ctrl(axi_ctrl),
    .bench_ctrl(bench_ctrl), .listen_port(listen_port),
    .hbm_base(hbm_base), .chunk_bits(reg_chunk_bits),
    .slot_mask(reg_slot_mask), .nsid(reg_nsid),
    .status_bits(status_bits), .listen_ok(listen_ok),
    .timer(timer), .nvme_sent(nvme_sent), .nvme_done(nvme_done),
    .last_error(last_error), .bytes_total(bytes_total),
    .wr_ptr(wr_ptr_out), .rd_nvme_ptr(rd_nvme_ptr_out)
);

// ============================================================
// Latched parameters (set on START)
// ============================================================
logic [VADDR_BITS-1:0]    latch_hbm_base;
logic [31:0]              latch_chunk_size;
logic [31:0]              latch_n_slots;       // slot_mask + 1
logic [4:0]               latch_chunk_bits;
logic [31:0]              latch_slot_mask;
logic [NSID_BITS-1:0]     latch_nsid;

// ============================================================
// Ring buffer pointers (slot indices)
// ============================================================
logic [31:0]              wp;          // write pointer (RX FSM → NVME FSM)
logic [31:0]              rp_nvme;     // NVMe read pointer (NVME FSM → TX FSM)
logic [31:0]              rp_free;     // free pointer (TX FSM → RX FSM)
logic                     rx_transfer_done; // RX FSM → NV FSM: no more slots coming

assign wr_ptr_out      = wp;
assign rd_nvme_ptr_out = rp_nvme;

// Ring full/empty checks
wire ring_full     = (wp - rp_free) >= latch_n_slots;
wire nvme_pending  = (wp != rp_nvme);
wire cpl_pending   = (rp_nvme != rp_free);
wire pipeline_done = rx_transfer_done && !nvme_pending && !cpl_req;

// ============================================================
// App meta
// ============================================================
logic [63:0]              naddr_base;
logic [63:0]              total_data_len;
logic [63:0]              nvme_lba_off;     // current NVMe byte offset

// ============================================================
// TCP session
// ============================================================
logic [TCP_SESSION_BITS-1:0] session_id;

// ============================================================
// TCP listen (always active after START)
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
logic mem_wr_done;
always_ff @(posedge aclk) begin
    if (!aresetn)
        mem_wr_done <= 1'b0;
    else if (rx_state == RX_SUBMIT_DESC)
        mem_wr_done <= 1'b0;
    else if (cq_wr.valid)
        mem_wr_done <= 1'b1;
end

// ============================================================
// RX FSM: TCP RX → HBM ring buffer
// ============================================================
typedef enum logic [3:0] {
    RX_IDLE         = 4'd0,
    RX_WAIT_NOTIFY  = 4'd1,
    RX_SEND_RD_PKG  = 4'd2,
    RX_WAIT_RX_META = 4'd3,
    RX_RECV_FIRST   = 4'd4,
    RX_SUBMIT_DESC  = 4'd5,
    RX_RECV_DATA    = 4'd6,
    RX_WAIT_MEM     = 4'd7,
    RX_CHECK        = 4'd8,
    RX_DONE         = 4'd9
} rx_state_t;

rx_state_t rx_state;

logic         is_first_pkt;
logic [TCP_LEN_BITS-1:0] rx_pkt_len;
logic [31:0]  rx_pkt_remaining;
logic [31:0]  rx_block_recv;     // bytes received in current slot
logic [31:0]  rx_desc_len;       // current DMA descriptor length
logic [31:0]  rx_desc_fwd;       // bytes forwarded for current descriptor
logic         rx_rd_pkg_valid;

// DMA write descriptor
logic         rx_sq_wr_valid;
req_t         rx_sq_wr_desc;

// ACK request to TX FSM
logic         ack_req;
logic         ack_done;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        rx_state        <= RX_IDLE;
        is_first_pkt    <= 1'b1;
        naddr_base      <= '0;
        total_data_len  <= '0;
        session_id      <= '0;
        rx_pkt_len      <= '0;
        rx_pkt_remaining <= '0;
        rx_block_recv   <= '0;
        rx_desc_len     <= '0;
        rx_desc_fwd     <= '0;
        rx_rd_pkg_valid <= 1'b0;
        rx_sq_wr_valid  <= 1'b0;
        rx_sq_wr_desc   <= '0;
        wp               <= '0;
        bytes_total      <= '0;
        ack_req          <= 1'b0;
        rx_transfer_done <= 1'b0;
    end
    else begin
        // --- Clear one-shot signals ---
        if (rx_sq_wr_valid && sq_wr.ready)
            rx_sq_wr_valid <= 1'b0;
        if (rx_rd_pkg_valid && tcp_rd_pkg.ready)
            rx_rd_pkg_valid <= 1'b0;
        if (ack_done)
            ack_req <= 1'b0;

        case (rx_state)
            RX_IDLE: begin
                if (go_pulse) begin
                    is_first_pkt     <= 1'b1;
                    naddr_base       <= '0;
                    total_data_len   <= '0;
                    wp               <= '0;
                    bytes_total      <= '0;
                    latch_hbm_base   <= hbm_base;
                    latch_chunk_bits <= reg_chunk_bits;
                    latch_slot_mask  <= reg_slot_mask;
                    latch_chunk_size <= 32'd1 << reg_chunk_bits;
                    latch_n_slots    <= reg_slot_mask + 1;
                    latch_nsid       <= reg_nsid[NSID_BITS-1:0];
                    timer            <= '0;
                    rx_state         <= RX_WAIT_NOTIFY;
                end
            end

            RX_WAIT_NOTIFY: begin
                timer <= timer + 1;
                if (tcp_notify.valid) begin
                    session_id <= tcp_notify.data.sid;
                    rx_pkt_len <= tcp_notify.data.len;
                    if (tcp_notify.data.closed)
                        rx_state <= RX_DONE;
                    else if (tcp_notify.data.len != 0)
                        rx_state <= RX_SEND_RD_PKG;
                end
            end

            RX_SEND_RD_PKG: begin
                timer <= timer + 1;
                if (!rx_rd_pkg_valid)
                    rx_rd_pkg_valid <= 1'b1;
                if (rx_rd_pkg_valid && tcp_rd_pkg.ready)
                    rx_state <= RX_WAIT_RX_META;
            end

            RX_WAIT_RX_META: begin
                timer <= timer + 1;
                if (tcp_rx_meta.valid) begin
                    if (is_first_pkt)
                        rx_state <= RX_RECV_FIRST;
                    else begin
                        rx_pkt_remaining <= rx_pkt_len;
                        rx_state         <= RX_SUBMIT_DESC;
                    end
                end
            end

            // Parse meta: [63:0]=naddr, [127:64]=length
            RX_RECV_FIRST: begin
                timer <= timer + 1;
                if (axis_tcp_recv.tvalid) begin
                    naddr_base     <= axis_tcp_recv.tdata[63:0];
                    total_data_len <= axis_tcp_recv.tdata[127:64];
                    is_first_pkt   <= 1'b0;

                    if (axis_tcp_recv.tlast)
                        rx_pkt_remaining <= '0;
                    else
                        rx_pkt_remaining <= rx_pkt_len - BEAT_BYTES;

                    // Request ACK → TX FSM will send it
                    ack_req  <= 1'b1;
                    rx_state <= RX_SUBMIT_DESC;
                end
            end

            // Submit DMA write, capped at chunk_size
            RX_SUBMIT_DESC: begin
                timer <= timer + 1;

                // Stall if ring is full
                if (ring_full) begin
                    // wait
                end
                else if (!rx_sq_wr_valid && rx_pkt_remaining > 0) begin
                    automatic logic [31:0] slot_remain = latch_chunk_size - rx_block_recv;
                    automatic logic [31:0] this_desc = (rx_pkt_remaining >= slot_remain)
                                                       ? slot_remain : rx_pkt_remaining;

                    rx_sq_wr_desc         <= '0;
                    rx_sq_wr_desc.opcode  <= LOCAL_WRITE;
                    rx_sq_wr_desc.strm    <= STRM_CARD;
                    rx_sq_wr_desc.dest    <= '0;
                    rx_sq_wr_desc.last    <= 1'b1;
                    rx_sq_wr_desc.vaddr   <= latch_hbm_base
                                           + ((wp & latch_slot_mask) << latch_chunk_bits)
                                           + rx_block_recv;
                    rx_sq_wr_desc.len     <= this_desc;
                    rx_sq_wr_desc.pid     <= '0;
                    rx_sq_wr_desc.vfid    <= '0;
                    rx_sq_wr_valid        <= 1'b1;

                    rx_desc_len <= this_desc;
                    rx_desc_fwd <= '0;
                end
                else if (rx_pkt_remaining == 0) begin
                    // No more data in packet, wait for next
                    rx_state <= RX_WAIT_NOTIFY;
                end

                if (rx_sq_wr_valid && sq_wr.ready)
                    rx_state <= RX_RECV_DATA;
            end

            // Forward TCP data → HBM, stop at desc_len or tlast
            RX_RECV_DATA: begin
                timer <= timer + 1;

                if (axis_tcp_recv.tvalid && axis_card_send[0].tready) begin
                    bytes_total      <= bytes_total + BEAT_BYTES;
                    rx_block_recv    <= rx_block_recv + BEAT_BYTES;
                    rx_desc_fwd      <= rx_desc_fwd + BEAT_BYTES;
                    rx_pkt_remaining <= rx_pkt_remaining - BEAT_BYTES;

                    if (axis_tcp_recv.tlast) begin
                        rx_pkt_remaining <= '0;
                        rx_state         <= RX_WAIT_MEM;
                    end
                    else if (rx_desc_fwd + BEAT_BYTES >= rx_desc_len) begin
                        rx_state <= RX_WAIT_MEM;
                    end
                end
            end

            RX_WAIT_MEM: begin
                timer <= timer + 1;
                if (mem_wr_done)
                    rx_state <= RX_CHECK;
            end

            // Slot filled?
            RX_CHECK: begin
                timer <= timer + 1;
                if (rx_block_recv >= latch_chunk_size || bytes_total >= total_data_len) begin
                    // Slot complete — advance write pointer
                    wp            <= wp + 1;
                    rx_block_recv <= '0;

                    if (bytes_total >= total_data_len)
                        rx_state <= RX_DONE;
                    else if (rx_pkt_remaining > 0)
                        rx_state <= RX_SUBMIT_DESC;
                    else
                        rx_state <= RX_WAIT_NOTIFY;
                end
                else begin
                    // Slot not full — continue with same packet or next
                    if (rx_pkt_remaining > 0)
                        rx_state <= RX_SUBMIT_DESC;
                    else
                        rx_state <= RX_WAIT_NOTIFY;
                end
            end

            RX_DONE: begin
                rx_transfer_done <= 1'b1;
                is_first_pkt     <= 1'b1;
                if (pipeline_done) begin
                    wp               <= '0;
                    bytes_total      <= '0;
                    rx_transfer_done <= 1'b0;
                    timer            <= '0;
                    rx_state         <= RX_WAIT_NOTIFY;
                end
            end

            default: rx_state <= RX_IDLE;
        endcase
    end
end

// ============================================================
// NVME FSM: HBM ring → NVMe SSD
// ============================================================
typedef enum logic [2:0] {
    NV_IDLE       = 3'd0,
    NV_WAIT_SLOT  = 3'd1,
    NV_ISSUE      = 3'd2,
    NV_DRAIN      = 3'd3
} nv_state_t;

nv_state_t nv_state;

logic         nv_req_valid;
nvme_user_req_t nv_req;

// CPL request to TX FSM
logic         cpl_req;
logic         cpl_done;
logic [63:0]  cpl_lba_off;       // LBA offset for this slot's completion

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        nv_state     <= NV_IDLE;
        rp_nvme      <= '0;
        nvme_sent    <= '0;
        nvme_done    <= '0;
        nv_req_valid <= 1'b0;
        nv_req       <= '0;
        last_error   <= '0;
        cpl_req      <= 1'b0;
        cpl_lba_off  <= '0;
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

        // Clear cpl_req when TX FSM acknowledges
        if (cpl_done)
            cpl_req <= 1'b0;

        case (nv_state)
            NV_IDLE: begin
                if (go_pulse) begin
                    rp_nvme      <= '0;
                    nvme_sent    <= '0;
                    nvme_done    <= '0;
                    last_error   <= '0;
                    nvme_lba_off <= '0;
                    nv_state     <= NV_WAIT_SLOT;
                end
            end

            // Wait for RX FSM to fill a slot
            NV_WAIT_SLOT: begin
                if (nvme_pending && !cpl_req) begin
                    if (rp_nvme == 0)
                        nvme_lba_off <= naddr_base;
                    nv_state <= NV_ISSUE;
                end
                else if (pipeline_done) begin
                    rp_nvme      <= '0;
                    nvme_sent    <= '0;
                    nvme_done    <= '0;
                    last_error   <= '0;
                    nvme_lba_off <= '0;
                    // stay in NV_WAIT_SLOT, ready for next transfer
                end
            end

            // Issue NVMe write for current slot
            NV_ISSUE: begin
                if (!nv_req_valid) begin
                    nv_req.dev_id    <= NVME_DEV_ID;
                    nv_req.writeRead <= 1'b1;
                    nv_req.nsid      <= latch_nsid;
                    nv_req.vaddr     <= latch_hbm_base
                                      + ((rp_nvme & latch_slot_mask) << latch_chunk_bits);
                    nv_req.naddr     <= nvme_lba_off;
                    nv_req.len       <= latch_chunk_size;
                    nv_req.region_id <= '0;
                    nv_req_valid     <= 1'b1;
                end

                if (nv_req_valid && m_nvme_cmd_req.ready) begin
                    nvme_sent <= nvme_sent + 1;
                    nv_state  <= NV_DRAIN;
                end
            end

            // Wait for NVMe completion
            NV_DRAIN: begin
                if (nvme_done >= nvme_sent) begin
                    // Signal TX FSM to send completion
                    cpl_lba_off  <= nvme_lba_off;
                    cpl_req      <= 1'b1;

                    // Advance
                    nvme_lba_off <= nvme_lba_off + latch_chunk_size;
                    rp_nvme      <= rp_nvme + 1;
                    nv_state     <= NV_WAIT_SLOT;
                end
            end

            default: nv_state <= NV_IDLE;
        endcase
    end
end

// ============================================================
// TX FSM: TCP TX (ACK priority > CPL)
// ============================================================
typedef enum logic [2:0] {
    TX_IDLE      = 3'd0,
    TX_META      = 3'd1,
    TX_DATA      = 3'd2,
    TX_WAIT      = 3'd3
} tx_state_t;

tx_state_t tx_state;

logic         tx_meta_valid;
logic         tx_data_valid;
logic         tx_is_ack;       // true if current TX is ACK, false if CPL

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        tx_state      <= TX_IDLE;
        tx_meta_valid <= 1'b0;
        tx_data_valid <= 1'b0;
        tx_is_ack     <= 1'b0;
        rp_free       <= '0;
        ack_done      <= 1'b0;
        cpl_done      <= 1'b0;
    end
    else begin
        ack_done <= 1'b0;
        cpl_done <= 1'b0;

        case (tx_state)
            TX_IDLE: begin
                if (pipeline_done)
                    rp_free <= '0;
                if (ack_req) begin
                    // ACK has priority
                    tx_is_ack <= 1'b1;
                    tx_state  <= TX_META;
                end
                else if (cpl_req) begin
                    tx_is_ack <= 1'b0;
                    tx_state  <= TX_META;
                end
            end

            TX_META: begin
                tx_meta_valid <= 1'b1;
                if (tx_meta_valid && tcp_tx_meta.ready) begin
                    tx_meta_valid <= 1'b0;
                    tx_state      <= TX_DATA;
                end
            end

            TX_DATA: begin
                tx_data_valid <= 1'b1;
                if (tx_data_valid && axis_tcp_send.tready) begin
                    tx_data_valid <= 1'b0;
                    tx_state      <= TX_WAIT;
                end
            end

            TX_WAIT: begin
                if (tcp_tx_stat.valid) begin
                    if (tx_is_ack) begin
                        ack_done <= 1'b1;
                    end
                    else begin
                        cpl_done <= 1'b1;
                        rp_free  <= rp_free + 1;
                    end
                    tx_state <= TX_IDLE;
                end
            end

            default: tx_state <= TX_IDLE;
        endcase
    end
end

// ============================================================
// Status bits for SW polling
// ============================================================
assign status_bits = {3'd0, listen_ok, tx_state[1:0], nv_state[1:0]};  // placeholder

// ============================================================
// Combinational outputs
// ============================================================
always_comb begin
    // --- NVMe ---
    m_nvme_cmd_req.valid = nv_req_valid;
    m_nvme_cmd_req.data  = nv_req;
    s_nvme_cmd_rsp.ready = 1'b1;
    s_nvme_cpl.ready     = 1'b1;

    // --- DMA write descriptor (from RX FSM) ---
    sq_wr.valid = rx_sq_wr_valid;
    sq_wr.data  = rx_sq_wr_desc;
    cq_wr.ready = 1'b1;

    // --- DMA read (unused in store) ---
    sq_rd.tie_off_m();
    cq_rd.tie_off_s();

    // --- TCP notify ---
    tcp_notify.ready = (rx_state == RX_WAIT_NOTIFY);

    // --- TCP rd_pkg ---
    tcp_rd_pkg.valid     = rx_rd_pkg_valid;
    tcp_rd_pkg.data.sid  = session_id;
    tcp_rd_pkg.data.len  = rx_pkt_len;

    // --- TCP rx_meta ---
    tcp_rx_meta.ready = (rx_state == RX_WAIT_RX_META);

    // --- TCP RX data ---
    axis_tcp_recv.tready = (rx_state == RX_RECV_FIRST) ||
                           (rx_state == RX_RECV_DATA && axis_card_send[0].tready);

    axis_card_send[0].tvalid = (rx_state == RX_RECV_DATA) && axis_tcp_recv.tvalid;
    axis_card_send[0].tdata  = axis_tcp_recv.tdata;
    axis_card_send[0].tkeep  = axis_tcp_recv.tkeep;
    axis_card_send[0].tlast  = axis_tcp_recv.tlast;
    axis_card_send[0].tid    = '0;

    // --- Card memory read (unused) ---
    axis_card_recv[0].tready = 1'b1;

    // --- TCP TX (shared: ACK + CPL) ---
    tcp_tx_meta.valid     = tx_meta_valid;
    tcp_tx_meta.data.sid  = session_id;
    tcp_tx_meta.data.len  = 16'd64;

    axis_tcp_send.tvalid  = tx_data_valid;
    axis_tcp_send.tkeep   = {64{1'b1}};
    axis_tcp_send.tlast   = 1'b1;

    if (tx_is_ack)
        axis_tcp_send.tdata = {480'd0, 32'd0};  // ACK: status=0 (OK)
    else
        axis_tcp_send.tdata = {352'd0, latch_chunk_size, cpl_lba_off, rp_free, {16'd0, last_error}};

    tcp_tx_stat.ready = 1'b1;
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
