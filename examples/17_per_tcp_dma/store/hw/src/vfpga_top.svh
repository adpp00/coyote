/**
 * NVMe TCP Pipelined Store (Example 16) — v2
 *
 * 4 independent processes:
 *   P1: Auto RX FSM   — tcp_notify/rd_pkg/rx_meta auto-consumption
 *   P2: DMA Writer     — axis_tcp_recv → HBM ring (no DMA wait)
 *   P3: NVMe Issuer    — DMA completion tracking → NVMe write
 *   P4: TX FSM         — ACK / completion via TCP TX
 *
 * Ring buffer in HBM:
 *   wp       → next slot to write (P2 produces)
 *   rp_nvme  → next slot for NVMe (P3 consumes wp, produces rp_nvme)
 *   rp_free  → next slot freed after TCP cpl (P4 consumes rp_nvme)
 *
 * Lifecycle:
 *   go_pulse (once) → init params + TCP listen → ready
 *   Per client: meta → data → NVMe → cpl → auto-restart → next meta
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
logic [31:0]              rd_nvme_ptr_out;
logic [10:0]              status_bits;

// ============================================================
// AXI-Lite Control Parser
// ============================================================
nvme_tcp_pipe_store_ctrl inst_ctrl (
    .aclk(aclk), .aresetn(aresetn), .axi_ctrl(axi_ctrl),
    .bench_ctrl(bench_ctrl), .listen_port(listen_port),
    .hbm_base(hbm_base), .chunk_size(reg_chunk_size),
    .n_slots(reg_n_slots), .dma_block_size(reg_dma_block_size),
    .dma_per_slot(reg_dma_per_slot), .nsid(reg_nsid),
    .status_bits(status_bits), .listen_ok(listen_ok),
    .timer(timer), .nvme_sent(nvme_sent), .nvme_done(nvme_done),
    .last_error(last_error), .bytes_total(bytes_total),
    .wr_ptr(wr_ptr_out), .rd_nvme_ptr(rd_nvme_ptr_out)
);

// ============================================================
// Latched parameters (set once on go_pulse)
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
logic [31:0]              wp;
logic [31:0]              rp_nvme;
logic [31:0]              rp_free;

// Accumulated base addresses (NO variable shift)
logic [VADDR_BITS-1:0]    wp_base_addr;
logic [VADDR_BITS-1:0]    rp_nvme_base_addr;

// Head-tail ring full: next write position catches the free pointer
wire [31:0] next_wp = (wp == latch_n_slots - 1) ? '0 : wp + 1;

logic ring_full_r;
always_ff @(posedge aclk) begin
    if (!aresetn)
        ring_full_r <= 1'b0;
    else
        ring_full_r <= (next_wp == rp_free);
end

// Cross-process signals
logic                     ack_req, ack_done;

// App meta
logic [63:0]              naddr_base;
logic [63:0]              total_data_len;
logic [63:0]              nvme_naddr;

// TCP session (shared: set by P1, used by P4)
logic [TCP_SESSION_BITS-1:0] session_id;

assign wr_ptr_out      = wp;
assign rd_nvme_ptr_out = rp_nvme;

// ============================================================
// Go pulse (init only)
// ============================================================
logic go_q;
wire  go_pulse = bench_ctrl[0] & ~go_q;
always_ff @(posedge aclk) begin
    if (!aresetn) go_q <= 1'b0;
    else          go_q <= bench_ctrl[0];
end

// ============================================================
// TCP Listen (started once on go_pulse)
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
// P1: Auto RX FSM — tcp_notify / rd_pkg / rx_meta
// ============================================================
typedef enum logic [1:0] {
    ARX_WAIT_NOTIFY  = 2'd0,
    ARX_SEND_RD_PKG  = 2'd1,
    ARX_WAIT_RX_META = 2'd2
} arx_state_t;

arx_state_t arx_state;

logic [TCP_LEN_BITS-1:0] arx_pkt_len;
logic                    arx_closed;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        arx_state   <= ARX_WAIT_NOTIFY;
        session_id  <= '0;
        arx_pkt_len <= '0;
        arx_closed  <= 1'b0;
    end
    else begin
        case (arx_state)
            ARX_WAIT_NOTIFY: begin
                if (tcp_notify.valid) begin
                    session_id  <= tcp_notify.data.sid;
                    arx_pkt_len <= tcp_notify.data.len;

                    if (tcp_notify.data.closed)
                        arx_closed <= 1'b1;
                    else if (tcp_notify.data.len != 0)
                        arx_state <= ARX_SEND_RD_PKG;
                end
            end

            ARX_SEND_RD_PKG: begin
                if (tcp_rd_pkg.ready)
                    arx_state <= ARX_WAIT_RX_META;
            end

            ARX_WAIT_RX_META: begin
                if (tcp_rx_meta.valid)
                    arx_state <= ARX_WAIT_NOTIFY;
            end

            default: arx_state <= ARX_WAIT_NOTIFY;
        endcase
    end
end

// ============================================================
// P2: DMA Writer — axis_tcp_recv → HBM ring buffer
// ============================================================
typedef enum logic [2:0] {
    RX_IDLE       = 3'd0,
    RX_META       = 3'd1,
    RX_ACK_WAIT   = 3'd2,
    RX_ISSUE_DESC = 3'd3,
    RX_FORWARD    = 3'd4,
    RX_DONE       = 3'd5
} rx_state_t;

rx_state_t rx_state;

logic [31:0]  rx_slot_offset;
logic [31:0]  rx_desc_fwd;

logic         rx_sq_wr_valid;
req_t         rx_sq_wr_desc;

logic [31:0]  dma_wr_total;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        rx_state       <= RX_IDLE;
        naddr_base     <= '0;
        total_data_len <= '0;
        rx_slot_offset <= '0;
        rx_desc_fwd    <= '0;
        rx_sq_wr_valid <= 1'b0;
        rx_sq_wr_desc  <= '0;
        wp             <= '0;

        wp_base_addr   <= '0;
        bytes_total    <= '0;
        ack_req        <= 1'b0;
        dma_wr_total   <= '0;
        timer          <= '0;
    end
    else begin
        if (rx_sq_wr_valid && sq_wr.ready)
            rx_sq_wr_valid <= 1'b0;
        if (ack_done)
            ack_req <= 1'b0;

        case (rx_state)
            // ============================================
            // Init: go_pulse → latch params → RX_META
            // ============================================
            RX_IDLE: begin
                if (go_pulse) begin
                    latch_hbm_base       <= hbm_base;
                    latch_chunk_size     <= reg_chunk_size;
                    latch_n_slots        <= reg_n_slots;
                    latch_dma_block_size <= reg_dma_block_size;
                    latch_dma_per_slot   <= reg_dma_per_slot;
                    latch_nsid           <= reg_nsid[NSID_BITS-1:0];

                    wp             <= '0;
            
                    wp_base_addr   <= hbm_base;
                    bytes_total    <= '0;
                    rx_slot_offset <= '0;
                    dma_wr_total   <= '0;
                    timer          <= '0;

                    rx_state <= RX_META;
                end
            end

            // ============================================
            RX_META: begin
                timer <= timer + 1;
                if (axis_tcp_recv.tvalid) begin
                    naddr_base     <= axis_tcp_recv.tdata[63:0];
                    total_data_len <= axis_tcp_recv.tdata[127:64];
                    ack_req        <= 1'b1;
                    rx_state       <= RX_ACK_WAIT;
                end
            end

            // ============================================
            RX_ACK_WAIT: begin
                timer <= timer + 1;
                if (ack_done)
                    rx_state <= RX_ISSUE_DESC;
            end

            // ============================================
            RX_ISSUE_DESC: begin
                timer <= timer + 1;

                if (bytes_total >= total_data_len) begin
                    rx_state <= RX_DONE;
                end
                else if (rx_slot_offset >= latch_chunk_size) begin
                    if (wp + 1 >= latch_n_slots) begin
                        wp           <= '0;
                        wp_base_addr <= latch_hbm_base;
                    end
                    else begin
                        wp           <= wp + 1;
                        wp_base_addr <= wp_base_addr + latch_chunk_size;
                    end
                    rx_slot_offset <= '0;
                end
                else if (ring_full_r) begin
                    // stall
                end
                else if (!rx_sq_wr_valid) begin
                    rx_sq_wr_desc         <= '0;
                    rx_sq_wr_desc.opcode  <= LOCAL_WRITE;
                    rx_sq_wr_desc.strm    <= STRM_CARD;
                    rx_sq_wr_desc.dest    <= '0;
                    rx_sq_wr_desc.last    <= 1'b1;
                    rx_sq_wr_desc.vaddr   <= wp_base_addr + rx_slot_offset;
                    rx_sq_wr_desc.len     <= latch_dma_block_size;
                    rx_sq_wr_desc.pid     <= '0;
                    rx_sq_wr_desc.vfid    <= '0;
                    rx_sq_wr_valid        <= 1'b1;
                    rx_desc_fwd           <= '0;
                end

                if (rx_sq_wr_valid && sq_wr.ready)
                    rx_state <= RX_FORWARD;
            end

            // ============================================
            RX_FORWARD: begin
                timer <= timer + 1;

                if (axis_tcp_recv.tvalid && axis_card_send[0].tready) begin
                    bytes_total    <= bytes_total + BEAT_BYTES;
                    rx_slot_offset <= rx_slot_offset + BEAT_BYTES;
                    rx_desc_fwd    <= rx_desc_fwd + BEAT_BYTES;

                    if (rx_desc_fwd + BEAT_BYTES >= latch_dma_block_size) begin
                        dma_wr_total <= dma_wr_total + 1;
                        rx_state     <= RX_ISSUE_DESC;
                    end
                end
            end

            // ============================================
            // Auto-restart: reset counters → RX_META
            // ============================================
            RX_DONE: begin
                if (tx_state == TX_DONE) begin
                    naddr_base     <= '0;
                    total_data_len <= '0;
                    wp             <= '0;
            
                    wp_base_addr   <= latch_hbm_base;
                    bytes_total    <= '0;
                    rx_slot_offset <= '0;
                    dma_wr_total   <= '0;
                    timer          <= '0;
                    rx_state       <= RX_META;
                end
            end

            default: rx_state <= RX_IDLE;
        endcase
    end
end

// ============================================================
// P3: DMA Completion Tracker + NVMe Issuer
// ============================================================
typedef enum logic [1:0] {
    NV_IDLE   = 2'd0,
    NV_WAIT   = 2'd1,
    NV_ISSUE  = 2'd2,
    NV_DONE   = 2'd3
} nv_state_t;

nv_state_t nv_state;

logic         nv_req_valid;
nvme_user_req_t nv_req;

logic [31:0]  dma_cpl_total;
logic [31:0]  dma_cpl_threshold;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        nv_state          <= NV_IDLE;
        rp_nvme           <= '0;
        rp_nvme_base_addr <= '0;
        nvme_sent         <= '0;
        nv_req_valid      <= 1'b0;
        nv_req            <= '0;
        nvme_naddr        <= '0;
        dma_cpl_total     <= '0;
        dma_cpl_threshold <= '0;
    end
    else begin
        if (nv_req_valid && m_nvme_cmd_req.ready)
            nv_req_valid <= 1'b0;

        if (cq_wr.valid)
            dma_cpl_total <= dma_cpl_total + 1;

        case (nv_state)
            // ============================================
            // Init: go_pulse → NV_WAIT
            // ============================================
            NV_IDLE: begin
                if (go_pulse) begin
                    rp_nvme           <= '0;
                    rp_nvme_base_addr <= hbm_base;
                    nvme_sent         <= '0;
                    nvme_naddr        <= '0;
                    dma_cpl_total     <= '0;
                    dma_cpl_threshold <= '0;
                    nv_state          <= NV_WAIT;
                end
            end

            // ============================================
            NV_WAIT: begin
                if (dma_cpl_threshold == 0) begin
                    dma_cpl_threshold <= latch_dma_per_slot;
                    nvme_naddr <= naddr_base;
                end
                else if (dma_cpl_total >= dma_cpl_threshold)
                    nv_state <= NV_ISSUE;
                else if (rx_state == RX_DONE && dma_cpl_total == dma_wr_total)
                    nv_state <= NV_DONE;
            end

            // ============================================
            NV_ISSUE: begin
                if (!nv_req_valid) begin
                    nv_req.dev_id    <= NVME_DEV_ID;
                    nv_req.writeRead <= 1'b1;
                    nv_req.nsid      <= latch_nsid;
                    nv_req.vaddr     <= rp_nvme_base_addr;
                    nv_req.naddr     <= nvme_naddr;
                    nv_req.len       <= latch_chunk_size;
                    nv_req.region_id <= '0;
                    nv_req_valid     <= 1'b1;
                end

                if (nv_req_valid && m_nvme_cmd_req.ready) begin
                    nvme_sent         <= nvme_sent + 1;
                    nvme_naddr        <= nvme_naddr + latch_chunk_size;
                    dma_cpl_threshold <= dma_cpl_threshold + latch_dma_per_slot;

                    if (rp_nvme + 1 >= latch_n_slots) begin
                        rp_nvme           <= '0;
                        rp_nvme_base_addr <= latch_hbm_base;
                    end
                    else begin
                        rp_nvme           <= rp_nvme + 1;
                        rp_nvme_base_addr <= rp_nvme_base_addr + latch_chunk_size;
                    end

                    nv_state <= NV_WAIT;
                end
            end

            // ============================================
            // Auto-restart: reset counters → NV_WAIT
            // ============================================
            NV_DONE: begin
                if (tx_state == TX_DONE) begin
                    rp_nvme           <= '0;
                    rp_nvme_base_addr <= latch_hbm_base;
                    nvme_sent         <= '0;
                    nvme_naddr        <= '0;
                    dma_cpl_total     <= '0;
                    dma_cpl_threshold <= '0;
                    nv_state          <= NV_WAIT;
                end
            end

            default: nv_state <= NV_IDLE;
        endcase
    end
end

// ============================================================
// P4: TX FSM — ACK + NVMe rsp/cpl → TCP completion
// ============================================================
typedef enum logic [2:0] {
    TX_IDLE     = 3'd0,
    TX_WAIT_RSP = 3'd1,
    TX_WAIT_CPL = 3'd2,
    TX_META     = 3'd3,
    TX_DATA     = 3'd4,
    TX_STAT     = 3'd5,
    TX_DONE     = 3'd6
} tx_state_t;

tx_state_t tx_state;

logic         tx_meta_valid;
logic         tx_data_valid;
logic         tx_is_ack;
logic [31:0]  tx_cpl_sent;
logic [63:0]  tx_lba_off;
logic [15:0]  tx_error_code;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        tx_state      <= TX_IDLE;
        tx_meta_valid <= 1'b0;
        tx_data_valid <= 1'b0;
        tx_is_ack     <= 1'b0;
        rp_free       <= '0;
        ack_done      <= 1'b0;
        tx_cpl_sent   <= '0;
        tx_lba_off    <= '0;
        tx_error_code <= '0;
        nvme_done     <= '0;
        last_error    <= '0;
    end
    else begin
        ack_done <= 1'b0;

        case (tx_state)
            // ============================================
            TX_IDLE: begin
                if (ack_req) begin
                    tx_is_ack <= 1'b1;
                    tx_state  <= TX_META;
                end
            end

            // ============================================
            TX_META: begin
                tx_meta_valid <= 1'b1;
                if (tx_meta_valid && tcp_tx_meta.ready) begin
                    tx_meta_valid <= 1'b0;
                    tx_state      <= TX_STAT;
                end
            end

            // ============================================
            TX_STAT: begin
                if (tcp_tx_stat.valid)
                    tx_state <= TX_DATA;
            end

            // ============================================
            TX_DATA: begin
                tx_data_valid <= 1'b1;
                if (tx_data_valid && axis_tcp_send.tready) begin
                    tx_data_valid <= 1'b0;
                    if (tx_is_ack) begin
                        ack_done  <= 1'b1;
                        tx_is_ack <= 1'b0;
                    end
                    else begin
                        tx_cpl_sent <= tx_cpl_sent + 1;
                        tx_lba_off  <= tx_lba_off + latch_chunk_size;
                        if (rp_free + 1 >= latch_n_slots)
                            rp_free <= '0;
                        else
                            rp_free <= rp_free + 1;
                    end
                    tx_state <= TX_WAIT_RSP;
                end
            end

            // ============================================
            TX_WAIT_RSP: begin
                if (s_nvme_cmd_rsp.valid) begin
                    if (s_nvme_cmd_rsp.data[15:0] == 16'h0000)
                        tx_state <= TX_WAIT_CPL;
                    else begin
                        tx_error_code <= s_nvme_cmd_rsp.data[15:0];
                        last_error    <= s_nvme_cmd_rsp.data[15:0];
                        tx_state      <= TX_META;
                    end
                end
                else if (nv_state == NV_DONE && nvme_done == nvme_sent)
                    tx_state <= TX_DONE;
            end

            // ============================================
            TX_WAIT_CPL: begin
                if (s_nvme_cpl.valid) begin
                    nvme_done     <= nvme_done + 1;
                    tx_error_code <= '0;
                    tx_is_ack     <= 1'b0;
                    if (tx_cpl_sent == 0)
                        tx_lba_off <= naddr_base;
                    tx_state <= TX_META;
                end
            end

            // ============================================
            // Auto-restart: reset counters → TX_IDLE
            // ============================================
            TX_DONE: begin
                if (rx_state == RX_META && nv_state == NV_WAIT) begin
                    rp_free       <= '0;
                    tx_cpl_sent   <= '0;
                    tx_lba_off    <= '0;
                    tx_error_code <= '0;
                    nvme_done     <= '0;
                    last_error    <= '0;
                    tx_state      <= TX_IDLE;
                end
            end

            default: tx_state <= TX_IDLE;
        endcase
    end
end

// ============================================================
// Status bits for SW polling
// ============================================================
assign status_bits = {tx_state, listen_ok, nv_state, rx_state};

// ============================================================
// Combinational outputs
// ============================================================
always_comb begin
    // --- NVMe ---
    m_nvme_cmd_req.valid = nv_req_valid;
    m_nvme_cmd_req.data  = nv_req;
    s_nvme_cmd_rsp.ready = (tx_state == TX_WAIT_RSP);
    s_nvme_cpl.ready     = (tx_state == TX_WAIT_CPL);

    // --- DMA write descriptor (from P2) ---
    sq_wr.valid = rx_sq_wr_valid;
    sq_wr.data  = rx_sq_wr_desc;
    cq_wr.ready = 1'b1;

    // --- DMA read (unused) ---
    sq_rd.tie_off_m();
    cq_rd.tie_off_s();

    // --- P1: TCP notify/rd_pkg/rx_meta ---
    tcp_notify.ready     = (arx_state == ARX_WAIT_NOTIFY);
    tcp_rd_pkg.valid     = (arx_state == ARX_SEND_RD_PKG);
    tcp_rd_pkg.data.sid  = session_id;
    tcp_rd_pkg.data.len  = arx_pkt_len;
    tcp_rx_meta.ready    = (arx_state == ARX_WAIT_RX_META);

    // --- TCP RX data ---
    axis_tcp_recv.tready = (rx_state == RX_META) ||
                           (rx_state == RX_FORWARD && axis_card_send[0].tready);

    // --- axis_card_send: forward TCP data to HBM ---
    axis_card_send[0].tvalid = (rx_state == RX_FORWARD) && axis_tcp_recv.tvalid;
    axis_card_send[0].tdata  = axis_tcp_recv.tdata;
    axis_card_send[0].tkeep  = axis_tcp_recv.tkeep;
    axis_card_send[0].tlast  = (rx_state == RX_FORWARD) &&
                               (rx_desc_fwd + BEAT_BYTES >= latch_dma_block_size);
    axis_card_send[0].tid    = '0;

    // --- Card memory read (unused) ---
    axis_card_recv[0].tready = 1'b1;

    // --- P4: TCP TX (shared: ACK + CPL) ---
    tcp_tx_meta.valid     = tx_meta_valid;
    tcp_tx_meta.data.sid  = session_id;
    tcp_tx_meta.data.len  = 16'd64;

    axis_tcp_send.tvalid  = tx_data_valid;
    axis_tcp_send.tkeep   = {64{1'b1}};
    axis_tcp_send.tlast   = 1'b1;

    if (tx_is_ack)
        axis_tcp_send.tdata = {448'd0, latch_chunk_size, 32'd0};
    else
        axis_tcp_send.tdata = {352'd0, latch_chunk_size, tx_lba_off, tx_cpl_sent, {16'd0, tx_error_code}};

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
