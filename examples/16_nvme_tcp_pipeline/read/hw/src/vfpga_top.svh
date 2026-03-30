/**
 * NVMe TCP Pipelined Read (Example 16) — v3
 *
 * 4 independent processes (consistent with STORE):
 *   P1: Auto RX FSM   — tcp_notify/rd_pkg/rx_meta auto-consumption
 *   P2: NVMe Issuer   — parse meta, ACK, issue NVMe reads → HBM ring
 *   P3: NVMe CPL      — advance wp on completion
 *   P4: TX FSM        — ACK + HBM ring → DMA read → TCP TX
 *
 * Ring buffer in HBM:
 *   nv_ip  → next slot for NVMe issue (P2 produces)
 *   wp     → next completed slot (P3 advances on cpl)
 *   rp     → next slot to send via TCP (P4 consumes)
 *
 * Lifecycle:
 *   go_pulse (once) → init params + TCP listen → ready
 *   Per client: notify → meta → ACK → NVMe reads → TCP data → auto-restart
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
logic [31:0]              reg_max_outstanding;

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
    .dma_per_slot(reg_dma_per_slot), .nsid(reg_nsid), .max_outstanding(reg_max_outstanding),
    .status_bits(status_bits), .listen_ok(listen_ok),
    .timer(timer), .nvme_sent(nvme_sent), .nvme_done(nvme_done),
    .last_error(last_error), .bytes_total(bytes_total),
    .wr_ptr(wr_ptr_out), .rd_ptr(rd_ptr_out)
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
logic [31:0]              latch_max_outstanding;

// ============================================================
// Ring buffer pointers
// ============================================================
logic [31:0]              nv_ip;   // NVMe issue pointer (P2)
logic [31:0]              wp;      // NVMe completion pointer (P3)
logic [31:0]              rp;      // TX send pointer (P4)

// Accumulated base addresses (NO variable shift)
logic [VADDR_BITS-1:0]    nv_ip_base_addr;
logic [VADDR_BITS-1:0]    wp_base_addr;

// Head-tail ring full: next issue position catches the send pointer
wire [31:0] next_nv_ip = (nv_ip == latch_n_slots - 1) ? '0 : nv_ip + 1;

logic ring_full_r;
always_ff @(posedge aclk) begin
    if (!aresetn)
        ring_full_r <= 1'b0;
    else
        ring_full_r <= (next_nv_ip == rp);
end

// NVMe SQ inflight limit (SW-configurable via MAX_OUTSTANDING register)
wire [31:0] nv_inflight = nvme_sent - nvme_done;
wire        nv_sq_full  = (nv_inflight >= latch_max_outstanding);

wire tx_pending = (wp != rp);

// Cross-process signals
logic                     ack_req, ack_done;

// App meta
logic [63:0]              naddr_base;
logic [63:0]              total_read_len;
logic [63:0]              nvme_lba_off;

// TCP session (shared: set by P1, used by P4)
logic [TCP_SESSION_BITS-1:0] session_id;

assign wr_ptr_out = wp;
assign rd_ptr_out = rp;

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
//     (identical to STORE P1)
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
// P2: Meta Parse + NVMe Issuer
//     (mirrors STORE P2: IDLE → META → ACK_WAIT → ISSUE → DONE)
// ============================================================
typedef enum logic [2:0] {
    NV_IDLE     = 3'd0,
    NV_META     = 3'd1,
    NV_ACK_WAIT = 3'd2,
    NV_ISSUE    = 3'd3,
    NV_DONE     = 3'd4
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
        naddr_base      <= '0;
        total_read_len  <= '0;
        ack_req         <= 1'b0;
        timer           <= '0;
    end
    else begin
        if (nv_req_valid && m_nvme_cmd_req.ready)
            nv_req_valid <= 1'b0;
        if (ack_done)
            ack_req <= 1'b0;

        case (nv_state)
            // ============================================
            // Init: go_pulse → latch params → NV_META
            // ============================================
            NV_IDLE: begin
                if (go_pulse) begin
                    latch_hbm_base       <= hbm_base;
                    latch_chunk_size     <= reg_chunk_size;
                    latch_n_slots        <= reg_n_slots;
                    latch_dma_block_size <= reg_dma_block_size;
                    latch_dma_per_slot   <= reg_dma_per_slot;
                    latch_nsid           <= reg_nsid[NSID_BITS-1:0];
                    latch_max_outstanding <= (reg_max_outstanding == 0) ? 32'd56 : reg_max_outstanding;

                    nv_ip           <= '0;
                    nv_ip_base_addr <= hbm_base;
                    nvme_sent       <= '0;
                    nvme_lba_off    <= '0;
                    nv_bytes_issued <= '0;
                    naddr_base      <= '0;
                    total_read_len  <= '0;
                    timer           <= '0;

                    nv_state <= NV_META;
                end
            end

            // ============================================
            // Wait for TCP request meta (mirrors STORE RX_META)
            // ============================================
            NV_META: begin
                timer <= timer + 1;
                if (axis_tcp_recv.tvalid) begin
                    naddr_base     <= axis_tcp_recv.tdata[63:0];
                    total_read_len <= axis_tcp_recv.tdata[127:64];
                    ack_req        <= 1'b1;
                    nv_state       <= NV_ACK_WAIT;
                end
            end

            // ============================================
            // Wait for ACK to be sent (mirrors STORE RX_ACK_WAIT)
            // ============================================
            NV_ACK_WAIT: begin
                timer <= timer + 1;
                if (ack_done) begin
                    nvme_lba_off <= naddr_base;
                    timer        <= '0;
                    nv_state     <= NV_ISSUE;
                end
            end

            // ============================================
            // Issue NVMe reads — pipelined, stay here
            // ============================================
            NV_ISSUE: begin
                timer <= timer + 1;

                if (nv_bytes_issued >= total_read_len) begin
                    nv_state <= NV_DONE;
                end
                else if (ring_full_r || nv_sq_full) begin
                    // Ring full or SQ depth limit — wait
                end
                else if (!nv_req_valid) begin
                    nv_req.dev_id    <= NVME_DEV_ID;
                    nv_req.writeRead <= 1'b0;  // read
                    nv_req.nsid      <= latch_nsid;
                    nv_req.vaddr     <= nv_ip_base_addr;
                    nv_req.naddr     <= nvme_lba_off;
                    nv_req.len       <= latch_chunk_size;
                    nv_req.region_id <= '0;
                    nv_req_valid     <= 1'b1;
                end

                // On handshake: advance issue pointer
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

            // ============================================
            // Auto-restart: reset counters → NV_META
            // ============================================
            NV_DONE: begin
                if (tx_state == TX_DONE) begin
                    nv_ip           <= '0;
                    nv_ip_base_addr <= latch_hbm_base;
                    nvme_sent       <= '0;
                    nvme_lba_off    <= '0;
                    nv_bytes_issued <= '0;
                    naddr_base      <= '0;
                    total_read_len  <= '0;
                    timer           <= '0;
                    nv_state        <= NV_META;
                end
            end

            default: nv_state <= NV_IDLE;
        endcase
    end
end

// ============================================================
// P3: NVMe Completion → DMA Read from HBM
// ============================================================
logic         p3_sq_rd_valid;
req_t         p3_sq_rd_desc;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        nvme_done      <= '0;
        wp             <= '0;
        wp_base_addr   <= '0;
        last_error     <= '0;
        p3_sq_rd_valid <= 1'b0;
        p3_sq_rd_desc  <= '0;
    end
    else begin
        // sq_rd handshake clear
        if (p3_sq_rd_valid && sq_rd.ready)
            p3_sq_rd_valid <= 1'b0;

        // Reset on go_pulse
        if (go_pulse) begin
            nvme_done      <= '0;
            wp             <= '0;
            wp_base_addr   <= hbm_base;
            last_error     <= '0;
            p3_sq_rd_valid <= 1'b0;
        end
        // Auto-restart
        else if (nv_state == NV_DONE && tx_state == TX_DONE) begin
            nvme_done      <= '0;
            wp             <= '0;
            wp_base_addr   <= latch_hbm_base;
            last_error     <= '0;
            p3_sq_rd_valid <= 1'b0;
        end
        else begin
            // NVMe command response (error check)
            if (s_nvme_cmd_rsp.valid && s_nvme_cmd_rsp.data[15:0] != 16'h0000)
                last_error <= s_nvme_cmd_rsp.data[15:0];

            // NVMe completion → issue DMA read from HBM
            if (s_nvme_cpl.valid && !p3_sq_rd_valid) begin
                nvme_done <= nvme_done + 1;

                p3_sq_rd_desc         <= '0;
                p3_sq_rd_desc.opcode  <= LOCAL_READ;
                p3_sq_rd_desc.strm    <= STRM_CARD;
                p3_sq_rd_desc.dest    <= '0;
                p3_sq_rd_desc.last    <= 1'b1;
                p3_sq_rd_desc.vaddr   <= wp_base_addr;
                p3_sq_rd_desc.len     <= latch_chunk_size;
                p3_sq_rd_desc.pid     <= '0;
                p3_sq_rd_desc.vfid    <= '0;
                p3_sq_rd_valid        <= 1'b1;

                // Advance wp
                if (wp + 1 >= latch_n_slots) begin
                    wp           <= '0;
                    wp_base_addr <= latch_hbm_base;
                end
                else begin
                    wp           <= wp + 1;
                    wp_base_addr <= wp_base_addr + latch_chunk_size;
                end
            end
        end
    end
end

// ============================================================
// P4: TX FSM — ACK + forward DMA data → TCP TX
// ============================================================
typedef enum logic [3:0] {
    TX_IDLE      = 4'd0,
    TX_META      = 4'd1,    // shared: ACK + data packets
    TX_STAT      = 4'd2,    // shared: wait tcp_tx_stat
    TX_ACK_DATA  = 4'd3,    // send 1-beat ACK
    TX_WAIT_SLOT = 4'd4,    // wait wp > rp
    TX_FWD       = 4'd5,    // forward card_recv → tcp_send (beat counting)
    TX_NEXT_PKT  = 4'd6,    // more packets in slot?
    TX_NEXT_SLOT = 4'd7,    // advance rp
    TX_DONE      = 4'd8     // auto-restart
} tx_state_t;

tx_state_t tx_state;

logic         tx_meta_valid;
logic         tx_data_valid;   // for ACK beat only
logic         tx_is_ack;

logic [31:0]  tx_pkt_cnt;     // packets sent in current slot
logic [31:0]  tx_pkt_bytes;   // bytes forwarded in current packet
logic [63:0]  tx_bytes_sent;

always_ff @(posedge aclk) begin
    if (!aresetn) begin
        tx_state       <= TX_IDLE;
        rp             <= '0;
        tx_meta_valid  <= 1'b0;
        tx_data_valid  <= 1'b0;
        tx_is_ack      <= 1'b0;
        tx_pkt_cnt     <= '0;
        tx_pkt_bytes   <= '0;
        tx_bytes_sent  <= '0;
        bytes_total    <= '0;
        ack_done       <= 1'b0;
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
            // Shared: send tcp_tx_meta
            // ============================================
            TX_META: begin
                tx_meta_valid <= 1'b1;
                if (tx_meta_valid && tcp_tx_meta.ready) begin
                    tx_meta_valid <= 1'b0;
                    tx_state      <= TX_STAT;
                end
            end

            // ============================================
            // Shared: wait for tcp_tx_stat
            // ============================================
            TX_STAT: begin
                if (tcp_tx_stat.valid) begin
                    if (tx_is_ack)
                        tx_state <= TX_ACK_DATA;
                    else begin
                        tx_pkt_bytes <= '0;
                        tx_state     <= TX_FWD;
                    end
                end
            end

            // ============================================
            // Send 1-beat ACK
            // ============================================
            TX_ACK_DATA: begin
                tx_data_valid <= 1'b1;
                if (tx_data_valid && axis_tcp_send.tready) begin
                    tx_data_valid <= 1'b0;
                    tx_is_ack     <= 1'b0;
                    ack_done      <= 1'b1;
                    tx_state      <= TX_WAIT_SLOT;
                end
            end

            // ============================================
            // Wait for a completed slot (wp > rp)
            // ============================================
            TX_WAIT_SLOT: begin
                if (tx_bytes_sent >= total_read_len)
                    tx_state <= TX_DONE;
                else if (tx_pending) begin
                    tx_pkt_cnt <= '0;
                    tx_state   <= TX_META;
                end
            end

            // ============================================
            // Forward card_recv → tcp_send (beat counting)
            // ============================================
            TX_FWD: begin
                if (axis_card_recv[0].tvalid && axis_tcp_send.tready) begin
                    tx_pkt_bytes <= tx_pkt_bytes + BEAT_BYTES;
                    bytes_total  <= bytes_total + BEAT_BYTES;

                    if (tx_pkt_bytes + BEAT_BYTES >= latch_dma_block_size)
                        tx_state <= TX_NEXT_PKT;
                end
            end

            // ============================================
            // More packets in this slot?
            // ============================================
            TX_NEXT_PKT: begin
                tx_pkt_cnt <= tx_pkt_cnt + 1;
                if (tx_pkt_cnt + 1 >= latch_dma_per_slot)
                    tx_state <= TX_NEXT_SLOT;
                else
                    tx_state <= TX_META;
            end

            // ============================================
            // Slot fully sent → advance rp
            // ============================================
            TX_NEXT_SLOT: begin
                tx_bytes_sent <= tx_bytes_sent + latch_chunk_size;

                if (rp + 1 >= latch_n_slots)
                    rp <= '0;
                else
                    rp <= rp + 1;

                if (tx_bytes_sent + latch_chunk_size >= total_read_len)
                    tx_state <= TX_DONE;
                else
                    tx_state <= TX_WAIT_SLOT;
            end

            // ============================================
            // Auto-restart: reset counters → TX_IDLE
            // ============================================
            TX_DONE: begin
                if (nv_state == NV_META) begin
                    rp            <= '0;
                    tx_bytes_sent <= '0;
                    bytes_total   <= '0;
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
// [1:0]=arx_state, [4:2]=nv_state, [5]=listen_ok, [9:6]=tx_state
assign status_bits = {1'b0, tx_state, listen_ok, nv_state, arx_state};

// ============================================================
// Combinational outputs
// ============================================================
always_comb begin
    // --- NVMe ---
    m_nvme_cmd_req.valid = nv_req_valid;
    m_nvme_cmd_req.data  = nv_req;
    s_nvme_cmd_rsp.ready = 1'b1;
    s_nvme_cpl.ready     = !p3_sq_rd_valid;

    // --- DMA write (unused in read) ---
    sq_wr.tie_off_m();
    cq_wr.tie_off_s();

    // --- DMA read descriptor (from P3) ---
    sq_rd.valid = p3_sq_rd_valid;
    sq_rd.data  = p3_sq_rd_desc;
    cq_rd.ready = 1'b1;

    // --- P1: TCP notify/rd_pkg/rx_meta ---
    tcp_notify.ready     = (arx_state == ARX_WAIT_NOTIFY);
    tcp_rd_pkg.valid     = (arx_state == ARX_SEND_RD_PKG);
    tcp_rd_pkg.data.sid  = session_id;
    tcp_rd_pkg.data.len  = arx_pkt_len;
    tcp_rx_meta.ready    = (arx_state == ARX_WAIT_RX_META);

    // --- TCP RX data (consume meta packet in P2) ---
    axis_tcp_recv.tready = (nv_state == NV_META);

    // --- P4: TCP TX meta ---
    tcp_tx_meta.valid     = tx_meta_valid;
    tcp_tx_meta.data.sid  = session_id;
    tcp_tx_meta.data.len  = tx_is_ack ? 16'd64 : latch_dma_block_size[15:0];

    tcp_tx_stat.ready     = 1'b1;

    // --- axis_tcp_send: ACK or data ---
    if (tx_state == TX_ACK_DATA) begin
        axis_tcp_send.tvalid = tx_data_valid;
        axis_tcp_send.tdata  = {448'd0, latch_chunk_size, 32'd0};
        axis_tcp_send.tkeep  = {64{1'b1}};
        axis_tcp_send.tlast  = 1'b1;
    end
    else begin
        axis_tcp_send.tvalid = (tx_state == TX_FWD) && axis_card_recv[0].tvalid;
        axis_tcp_send.tdata  = axis_card_recv[0].tdata;
        axis_tcp_send.tkeep  = axis_card_recv[0].tkeep;
        axis_tcp_send.tlast  = (tx_pkt_bytes + BEAT_BYTES >= latch_dma_block_size);
    end

    // --- Card memory read → TCP TX ---
    axis_card_recv[0].tready = (tx_state == TX_FWD) && axis_tcp_send.tready;

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
