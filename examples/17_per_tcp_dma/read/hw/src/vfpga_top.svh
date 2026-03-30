/**
 * NVMe TCP Pipelined Read (Example 16) — v2
 *
 * 3 independent processes + meta parse:
 *   META:  TCP listen + meta parse (one-shot setup)
 *   P1:    NVMe Issuer — issue reads to HBM ring (pipelined, no drain wait)
 *   P2:    NVMe Completion Tracker — advance wp on s_nvme_cpl
 *   P3:    TX FSM — HBM ring[rp] → DMA read → TCP TX
 *
 * Ring buffer in HBM:
 *   nv_ip  → next slot for NVMe read issue (P1 produces)
 *   wp     → next completed slot (P2 advances on NVMe completion)
 *   rp     → next slot to send via TCP (P3 consumes)
 *
 * WNS fix: all addresses accumulated incrementally, NO variable shifts.
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
logic [31:0]              reg_chunk_size;
logic [31:0]              reg_n_slots;
logic [31:0]              reg_dma_block_size;
logic [31:0]              reg_dma_per_slot;
logic [63:0]              reg_nsid;

// Status (to parser → SW)
logic                     listen_ok;
logic [63:0]              timer;
logic [31:0]              nvme_sent;
logic [31:0]              nvme_done;
logic [15:0]              last_error;
logic [63:0]              bytes_total;
logic [31:0]              wr_ptr_out;
logic [31:0]              rd_ptr_out;
logic [10:0]              status_bits;

// ============================================================
// AXI-Lite Control Parser
// ============================================================
nvme_tcp_pipe_read_ctrl inst_ctrl (
    .aclk(aclk), .aresetn(aresetn), .axi_ctrl(axi_ctrl),
    .bench_ctrl(bench_ctrl), .listen_port(listen_port),
    .hbm_base(hbm_base), .chunk_size(reg_chunk_size),
    .n_slots(reg_n_slots), .dma_block_size(reg_dma_block_size),
    .dma_per_slot(reg_dma_per_slot), .nsid(reg_nsid),
    .status_bits(status_bits), .listen_ok(listen_ok),
    .timer(timer), .nvme_sent(nvme_sent), .nvme_done(nvme_done),
    .last_error(last_error), .bytes_total(bytes_total),
    .wr_ptr(wr_ptr_out), .rd_ptr(rd_ptr_out)
);

// ============================================================
// Latched parameters (set on START)
// ============================================================
logic [VADDR_BITS-1:0]    latch_hbm_base;
logic [31:0]              latch_chunk_size;
logic [31:0]              latch_n_slots;
logic [31:0]              latch_dma_block_size;
logic [31:0]              latch_dma_per_slot;
logic [NSID_BITS-1:0]     latch_nsid;

// ============================================================
// Ring buffer pointers
// ============================================================
logic [31:0]              nv_ip;   // NVMe issue pointer (P1 advances)
logic [31:0]              wp;      // NVMe completion pointer (P2 advances)
logic [31:0]              rp;      // TX send pointer (P3 advances)

// Accumulated base addresses (NO variable shift)
logic [VADDR_BITS-1:0]    nv_ip_base_addr;
logic [VADDR_BITS-1:0]    rp_base_addr;

assign wr_ptr_out = wp;
assign rd_ptr_out = rp;

// Registered ring full (eliminates subtract+compare timing path)
logic ring_full_r;
always_ff @(posedge aclk) begin
    if (!aresetn)
        ring_full_r <= 1'b0;
    else
        ring_full_r <= (nv_ip - rp) >= latch_n_slots;
end

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
// Go pulse
// ============================================================
logic go_q;
wire  go_pulse = bench_ctrl[0] & ~go_q;
always_ff @(posedge aclk) begin
    if (!aresetn) go_q <= 1'b0;
    else          go_q <= bench_ctrl[0];
end

// ============================================================
// TCP Listen (always active after START)
// ============================================================
logic        lsn_valid_r;
logic [15:0] lsn_port_r;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        lsn_valid_r <= 1'b0;
        lsn_port_r  <= '0;
        listen_ok   <= 1'b0;
    end
    else begin
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
// META FSM: TCP RX → parse meta → kick pipeline
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
        meta_state        <= META_IDLE;
        naddr_base        <= '0;
        total_read_len    <= '0;
        session_id        <= '0;
        meta_pkt_len      <= '0;
        meta_rd_pkg_valid <= 1'b0;
        transfer_active   <= 1'b0;
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

                    // Latch parameters (no division — SW pre-computes dma_per_slot)
                    latch_hbm_base       <= hbm_base;
                    latch_chunk_size     <= reg_chunk_size;
                    latch_n_slots        <= reg_n_slots;
                    latch_dma_block_size <= reg_dma_block_size;
                    latch_dma_per_slot   <= reg_dma_per_slot;
                    latch_nsid           <= reg_nsid[NSID_BITS-1:0];

                    timer      <= '0;
                    meta_state <= META_WAIT_NOTIFY;
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
                    naddr_base      <= axis_tcp_recv.tdata[63:0];
                    total_read_len  <= axis_tcp_recv.tdata[127:64];
                    transfer_active <= 1'b1;
                    timer           <= '0;
                    meta_state      <= META_RUNNING;
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
// P1: NVMe Issuer — issue reads pipelined (no drain wait)
// ============================================================
typedef enum logic [1:0] {
    NV_IDLE  = 2'd0,
    NV_WAIT  = 2'd1,
    NV_ISSUE = 2'd2,
    NV_DONE  = 2'd3
} nv_state_t;

nv_state_t nv_state;

logic           nv_req_valid;
nvme_user_req_t nv_req;
logic [63:0]    nv_bytes_issued;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        nv_state        <= NV_IDLE;
        nv_ip           <= '0;
        nv_ip_base_addr <= '0;
        nvme_sent       <= '0;
        nv_req_valid    <= 1'b0;
        nv_req          <= '0;
        nvme_lba_off    <= '0;
        nv_bytes_issued <= '0;
    end
    else begin
        // Clear one-shot
        if (nv_req_valid && m_nvme_cmd_req.ready)
            nv_req_valid <= 1'b0;

        case (nv_state)
            NV_IDLE: begin
                if (go_pulse) begin
                    nv_ip           <= '0;
                    nv_ip_base_addr <= hbm_base;
                    nvme_sent       <= '0;
                    nvme_lba_off    <= '0;
                    nv_bytes_issued <= '0;
                    nv_state        <= NV_WAIT;
                end
            end

            // Wait for meta FSM to parse the request
            NV_WAIT: begin
                if (transfer_active) begin
                    nvme_lba_off <= naddr_base;
                    nv_state     <= NV_ISSUE;
                end
            end

            // Issue NVMe reads — stay here, loop, no drain wait
            NV_ISSUE: begin
                if (nv_bytes_issued >= total_read_len) begin
                    nv_state <= NV_DONE;
                end
                else if (ring_full_r) begin
                    // Ring full — wait for TX to free slots
                end
                else if (!nv_req_valid) begin
                    automatic logic [63:0] remaining = total_read_len - nv_bytes_issued;
                    automatic logic [31:0] this_len = (remaining >= latch_chunk_size)
                                                      ? latch_chunk_size : remaining[31:0];

                    nv_req.dev_id    <= NVME_DEV_ID;
                    nv_req.writeRead <= 1'b0;  // read
                    nv_req.nsid      <= latch_nsid;
                    nv_req.vaddr     <= nv_ip_base_addr;
                    nv_req.naddr     <= nvme_lba_off;
                    nv_req.len       <= this_len;
                    nv_req.region_id <= '0;
                    nv_req_valid     <= 1'b1;
                end

                // On handshake: advance issue pointer, stay in NV_ISSUE
                if (nv_req_valid && m_nvme_cmd_req.ready) begin
                    nvme_sent       <= nvme_sent + 1;
                    nvme_lba_off    <= nvme_lba_off + latch_chunk_size;
                    nv_bytes_issued <= nv_bytes_issued + latch_chunk_size;

                    if (nv_ip + 1 >= latch_n_slots) begin
                        nv_ip           <= '0;
                        nv_ip_base_addr <= latch_hbm_base;
                    end
                    else begin
                        nv_ip           <= nv_ip + 1;
                        nv_ip_base_addr <= nv_ip_base_addr + latch_chunk_size;
                    end
                end
            end

            NV_DONE: begin
                if (!transfer_active) begin
                    nv_ip           <= '0;
                    nv_ip_base_addr <= latch_hbm_base;
                    nvme_sent       <= '0;
                    nvme_lba_off    <= '0;
                    nv_bytes_issued <= '0;
                    nv_state        <= NV_WAIT;
                end
            end

            default: nv_state <= NV_IDLE;
        endcase
    end
end

// ============================================================
// P2: NVMe Completion Tracker — advance wp on completion
// ============================================================
always_ff @(posedge aclk) begin
    if (!aresetn) begin
        nvme_done  <= '0;
        wp         <= '0;
        last_error <= '0;
    end
    else begin
        if (go_pulse) begin
            nvme_done  <= '0;
            wp         <= '0;
            last_error <= '0;
        end

        // NVMe command response (error check)
        if (s_nvme_cmd_rsp.valid && s_nvme_cmd_rsp.data[15:0] != 16'h0000)
            last_error <= s_nvme_cmd_rsp.data[15:0];

        // NVMe completion — data is in HBM, advance wp
        if (s_nvme_cpl.valid) begin
            nvme_done <= nvme_done + 1;

            if (wp + 1 >= latch_n_slots)
                wp <= '0;
            else
                wp <= wp + 1;
        end
    end
end

// ============================================================
// P3: TX FSM — HBM ring[rp] → DMA read → TCP TX
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

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        tx_state         <= TX_IDLE;
        rp               <= '0;
        rp_base_addr     <= '0;
        tx_sq_rd_valid   <= 1'b0;
        tx_sq_rd_desc    <= '0;
        tx_meta_valid    <= 1'b0;
        tx_slot_size     <= '0;
        tx_pkt_offset    <= '0;
        tx_pkt_len       <= '0;
        tx_bytes_sent    <= '0;
        bytes_total      <= '0;
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
                    rp_base_addr     <= hbm_base;
                    tx_bytes_sent    <= '0;
                    bytes_total      <= '0;
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

            // Wait for a completed slot (wp > rp)
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

            // Prepare next TCP TX packet within this slot
            TX_SETUP: begin
                if (tx_pkt_offset >= tx_slot_size) begin
                    tx_state <= TX_NEXT_SLOT;
                end
                else begin
                    automatic logic [31:0] remain_in_slot = tx_slot_size - tx_pkt_offset;
                    tx_pkt_len <= (remain_in_slot >= latch_dma_block_size)
                                 ? latch_dma_block_size : remain_in_slot;
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
                    tx_sq_rd_desc.vaddr   <= rp_base_addr + tx_pkt_offset;
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
                if (axis_card_recv[0].tvalid && axis_tcp_send.tready)
                    bytes_total <= bytes_total + BEAT_BYTES;

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
                tx_bytes_sent <= tx_bytes_sent + tx_slot_size;

                if (rp + 1 >= latch_n_slots) begin
                    rp           <= '0;
                    rp_base_addr <= latch_hbm_base;
                end
                else begin
                    rp           <= rp + 1;
                    rp_base_addr <= rp_base_addr + latch_chunk_size;
                end

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
                    rp_base_addr     <= latch_hbm_base;
                    tx_bytes_sent    <= '0;
                    bytes_total      <= '0;
                    tx_transfer_done <= 1'b0;
                    tx_state         <= TX_WAIT_META;
                end
            end

            default: tx_state <= TX_IDLE;
        endcase
    end
end

// ============================================================
// Status bits for SW polling
// ============================================================
// [2:0]=meta_state, [4:3]=nv_state, [5]=listen_ok, [9:6]=tx_state, [10]=0
assign status_bits = {1'b0, tx_state, listen_ok, nv_state, meta_state};

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
