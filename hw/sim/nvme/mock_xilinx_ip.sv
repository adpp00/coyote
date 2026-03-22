/**
 * Mock Xilinx IP modules for nvme_top simulation
 *
 * Provides behavioral models for:
 *   - AXI BRAM controllers (cq/sq/prp)
 *   - AXI-Stream data FIFOs (passthrough)
 *   - ILA cores (empty stubs)
 */

`timescale 1ns/1ps

// ============================================================================
// Generic AXI BRAM Controller (behavioral)
//
// Converts AXI4 transactions to BRAM port signals.
// Supports single-beat writes and reads with 1-cycle latency.
// ============================================================================
module mock_axi_bram_ctrl #(
    parameter int DATA_WIDTH = 128,
    parameter int ADDR_WIDTH = 19
)(
    input  logic                       s_axi_aclk,
    input  logic                       s_axi_aresetn,

    // AXI4 Write Address
    input  logic [ADDR_WIDTH-1:0]      s_axi_awaddr,
    input  logic [7:0]                 s_axi_awlen,
    input  logic [2:0]                 s_axi_awsize,
    input  logic [1:0]                 s_axi_awburst,
    input  logic                       s_axi_awlock,
    input  logic [3:0]                 s_axi_awcache,
    input  logic [2:0]                 s_axi_awprot,
    input  logic                       s_axi_awvalid,
    output logic                       s_axi_awready,

    // AXI4 Write Data
    input  logic [DATA_WIDTH-1:0]      s_axi_wdata,
    input  logic [DATA_WIDTH/8-1:0]    s_axi_wstrb,
    input  logic                       s_axi_wlast,
    input  logic                       s_axi_wvalid,
    output logic                       s_axi_wready,

    // AXI4 Write Response
    output logic [1:0]                 s_axi_bresp,
    output logic                       s_axi_bvalid,
    input  logic                       s_axi_bready,

    // AXI4 Read Address
    input  logic [ADDR_WIDTH-1:0]      s_axi_araddr,
    input  logic [7:0]                 s_axi_arlen,
    input  logic [2:0]                 s_axi_arsize,
    input  logic [1:0]                 s_axi_arburst,
    input  logic                       s_axi_arlock,
    input  logic [3:0]                 s_axi_arcache,
    input  logic [2:0]                 s_axi_arprot,
    input  logic                       s_axi_arvalid,
    output logic                       s_axi_arready,

    // AXI4 Read Data
    output logic [DATA_WIDTH-1:0]      s_axi_rdata,
    output logic [1:0]                 s_axi_rresp,
    output logic                       s_axi_rlast,
    output logic                       s_axi_rvalid,
    input  logic                       s_axi_rready,

    // BRAM Port
    output logic [ADDR_WIDTH-1:0]      bram_addr_a,
    output logic                       bram_clk_a,
    output logic [DATA_WIDTH-1:0]      bram_wrdata_a,
    input  logic [DATA_WIDTH-1:0]      bram_rddata_a,
    output logic                       bram_en_a,
    output logic                       bram_rst_a,
    output logic [DATA_WIDTH/8-1:0]    bram_we_a
);

    assign bram_clk_a = s_axi_aclk;
    assign bram_rst_a = ~s_axi_aresetn;

    // FSM
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_WR_DATA,
        ST_WR_BRAM,
        ST_WR_RESP,
        ST_RD_BRAM,
        ST_RD_DATA
    } state_t;

    state_t state;
    logic [ADDR_WIDTH-1:0]   addr_r;
    logic [DATA_WIDTH-1:0]   wdata_r;
    logic [DATA_WIDTH/8-1:0] wstrb_r;

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            state         <= ST_IDLE;
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
            s_axi_rlast   <= 1'b0;
            s_axi_rdata   <= '0;
            bram_en_a     <= 1'b0;
            bram_we_a     <= '0;
            bram_addr_a   <= '0;
            bram_wrdata_a <= '0;
            addr_r        <= '0;
            wdata_r       <= '0;
            wstrb_r       <= '0;
        end else begin
            // Default: clear single-cycle pulses
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_arready <= 1'b0;
            bram_en_a     <= 1'b0;
            bram_we_a     <= '0;

            case (state)
                ST_IDLE: begin
                    if (s_axi_awvalid && s_axi_wvalid) begin
                        // Accept write address + data simultaneously
                        s_axi_awready <= 1'b1;
                        s_axi_wready  <= 1'b1;
                        addr_r        <= s_axi_awaddr;
                        wdata_r       <= s_axi_wdata;
                        wstrb_r       <= s_axi_wstrb;
                        state         <= ST_WR_BRAM;
                    end else if (s_axi_awvalid) begin
                        s_axi_awready <= 1'b1;
                        addr_r        <= s_axi_awaddr;
                        state         <= ST_WR_DATA;
                    end else if (s_axi_arvalid) begin
                        s_axi_arready <= 1'b1;
                        addr_r        <= s_axi_araddr;
                        state         <= ST_RD_BRAM;
                    end
                end

                ST_WR_DATA: begin
                    if (s_axi_wvalid) begin
                        s_axi_wready <= 1'b1;
                        wdata_r      <= s_axi_wdata;
                        wstrb_r      <= s_axi_wstrb;
                        state        <= ST_WR_BRAM;
                    end
                end

                ST_WR_BRAM: begin
                    // Drive BRAM write for one cycle
                    bram_en_a     <= 1'b1;
                    bram_we_a     <= wstrb_r;
                    bram_addr_a   <= addr_r;
                    bram_wrdata_a <= wdata_r;
                    // Send write response
                    s_axi_bvalid  <= 1'b1;
                    s_axi_bresp   <= 2'b00;
                    state         <= ST_WR_RESP;
                end

                ST_WR_RESP: begin
                    if (s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        state        <= ST_IDLE;
                    end
                end

                ST_RD_BRAM: begin
                    // Drive BRAM read for one cycle
                    bram_en_a   <= 1'b1;
                    bram_addr_a <= addr_r;
                    state       <= ST_RD_DATA;
                end

                ST_RD_DATA: begin
                    // Present read data
                    s_axi_rvalid <= 1'b1;
                    s_axi_rdata  <= bram_rddata_a;
                    s_axi_rlast  <= 1'b1;
                    s_axi_rresp  <= 2'b00;
                    if (s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;
                        s_axi_rlast  <= 1'b0;
                        state        <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

// ============================================================================
// Named wrappers for each AXI BRAM controller IP used in sub-modules
// ============================================================================

module cq_axi_bram_ctrl (
    input  logic         s_axi_aclk,
    input  logic         s_axi_aresetn,
    input  logic [18:0]  s_axi_awaddr,
    input  logic [7:0]   s_axi_awlen,
    input  logic [2:0]   s_axi_awsize,
    input  logic [1:0]   s_axi_awburst,
    input  logic         s_axi_awlock,
    input  logic [3:0]   s_axi_awcache,
    input  logic [2:0]   s_axi_awprot,
    input  logic         s_axi_awvalid,
    output logic         s_axi_awready,
    input  logic [127:0] s_axi_wdata,
    input  logic [15:0]  s_axi_wstrb,
    input  logic         s_axi_wlast,
    input  logic         s_axi_wvalid,
    output logic         s_axi_wready,
    output logic [1:0]   s_axi_bresp,
    output logic         s_axi_bvalid,
    input  logic         s_axi_bready,
    input  logic [18:0]  s_axi_araddr,
    input  logic [7:0]   s_axi_arlen,
    input  logic [2:0]   s_axi_arsize,
    input  logic [1:0]   s_axi_arburst,
    input  logic         s_axi_arlock,
    input  logic [3:0]   s_axi_arcache,
    input  logic [2:0]   s_axi_arprot,
    input  logic         s_axi_arvalid,
    output logic         s_axi_arready,
    output logic [127:0] s_axi_rdata,
    output logic [1:0]   s_axi_rresp,
    output logic         s_axi_rlast,
    output logic         s_axi_rvalid,
    input  logic         s_axi_rready,
    output logic [18:0]  bram_addr_a,
    output logic         bram_clk_a,
    output logic [127:0] bram_wrdata_a,
    input  logic [127:0] bram_rddata_a,
    output logic         bram_en_a,
    output logic         bram_rst_a,
    output logic [15:0]  bram_we_a
);
    mock_axi_bram_ctrl #(.DATA_WIDTH(128), .ADDR_WIDTH(19)) u (.*);
endmodule

module sq_axi_bram_ctrl (
    input  logic         s_axi_aclk,
    input  logic         s_axi_aresetn,
    input  logic [15:0]  s_axi_awaddr,
    input  logic [7:0]   s_axi_awlen,
    input  logic [2:0]   s_axi_awsize,
    input  logic [1:0]   s_axi_awburst,
    input  logic         s_axi_awlock,
    input  logic [3:0]   s_axi_awcache,
    input  logic [2:0]   s_axi_awprot,
    input  logic         s_axi_awvalid,
    output logic         s_axi_awready,
    input  logic [511:0] s_axi_wdata,
    input  logic [63:0]  s_axi_wstrb,
    input  logic         s_axi_wlast,
    input  logic         s_axi_wvalid,
    output logic         s_axi_wready,
    output logic [1:0]   s_axi_bresp,
    output logic         s_axi_bvalid,
    input  logic         s_axi_bready,
    input  logic [15:0]  s_axi_araddr,
    input  logic [7:0]   s_axi_arlen,
    input  logic [2:0]   s_axi_arsize,
    input  logic [1:0]   s_axi_arburst,
    input  logic         s_axi_arlock,
    input  logic [3:0]   s_axi_arcache,
    input  logic [2:0]   s_axi_arprot,
    input  logic         s_axi_arvalid,
    output logic         s_axi_arready,
    output logic [511:0] s_axi_rdata,
    output logic [1:0]   s_axi_rresp,
    output logic         s_axi_rlast,
    output logic         s_axi_rvalid,
    input  logic         s_axi_rready,
    output logic [15:0]  bram_addr_a,
    output logic         bram_clk_a,
    output logic [511:0] bram_wrdata_a,
    input  logic [511:0] bram_rddata_a,
    output logic         bram_en_a,
    output logic         bram_rst_a,
    output logic [63:0]  bram_we_a
);
    mock_axi_bram_ctrl #(.DATA_WIDTH(512), .ADDR_WIDTH(16)) u (.*);
endmodule

module prp_axi_bram_ctrl (
    input  logic         s_axi_aclk,
    input  logic         s_axi_aresetn,
    input  logic [21:0]  s_axi_awaddr,
    input  logic [7:0]   s_axi_awlen,
    input  logic [2:0]   s_axi_awsize,
    input  logic [1:0]   s_axi_awburst,
    input  logic         s_axi_awlock,
    input  logic [3:0]   s_axi_awcache,
    input  logic [2:0]   s_axi_awprot,
    input  logic         s_axi_awvalid,
    output logic         s_axi_awready,
    input  logic [63:0]  s_axi_wdata,
    input  logic [7:0]   s_axi_wstrb,
    input  logic         s_axi_wlast,
    input  logic         s_axi_wvalid,
    output logic         s_axi_wready,
    output logic [1:0]   s_axi_bresp,
    output logic         s_axi_bvalid,
    input  logic         s_axi_bready,
    input  logic [21:0]  s_axi_araddr,
    input  logic [7:0]   s_axi_arlen,
    input  logic [2:0]   s_axi_arsize,
    input  logic [1:0]   s_axi_arburst,
    input  logic         s_axi_arlock,
    input  logic [3:0]   s_axi_arcache,
    input  logic [2:0]   s_axi_arprot,
    input  logic         s_axi_arvalid,
    output logic         s_axi_arready,
    output logic [63:0]  s_axi_rdata,
    output logic [1:0]   s_axi_rresp,
    output logic         s_axi_rlast,
    output logic         s_axi_rvalid,
    input  logic         s_axi_rready,
    output logic [21:0]  bram_addr_a,
    output logic         bram_clk_a,
    output logic [63:0]  bram_wrdata_a,
    input  logic [63:0]  bram_rddata_a,
    output logic         bram_en_a,
    output logic         bram_rst_a,
    output logic [7:0]   bram_we_a
);
    mock_axi_bram_ctrl #(.DATA_WIDTH(64), .ADDR_WIDTH(22)) u (.*);
endmodule

// ============================================================================
// AXI-Stream FIFO mocks (passthrough with 1-cycle delay)
// ============================================================================

module axis_data_fifo_meta_128 (
    input  logic         s_axis_aresetn,
    input  logic         s_axis_aclk,
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,
    input  logic [127:0] s_axis_tdata,
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,
    output logic [127:0] m_axis_tdata
);
    // Simple 1-deep register slice
    logic valid_r;
    logic [127:0] data_r;

    assign s_axis_tready = ~valid_r || m_axis_tready;
    assign m_axis_tvalid = valid_r;
    assign m_axis_tdata  = data_r;

    always_ff @(posedge s_axis_aclk) begin
        if (!s_axis_aresetn) begin
            valid_r <= 1'b0;
            data_r  <= '0;
        end else begin
            if (s_axis_tready && s_axis_tvalid) begin
                valid_r <= 1'b1;
                data_r  <= s_axis_tdata;
            end else if (m_axis_tready) begin
                valid_r <= 1'b0;
            end
        end
    end
endmodule

module axis_data_fifo_meta_96 (
    input  logic        s_axis_aresetn,
    input  logic        s_axis_aclk,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic [95:0] s_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic [95:0] m_axis_tdata
);
    logic valid_r;
    logic [95:0] data_r;

    assign s_axis_tready = ~valid_r || m_axis_tready;
    assign m_axis_tvalid = valid_r;
    assign m_axis_tdata  = data_r;

    always_ff @(posedge s_axis_aclk) begin
        if (!s_axis_aresetn) begin
            valid_r <= 1'b0;
            data_r  <= '0;
        end else begin
            if (s_axis_tready && s_axis_tvalid) begin
                valid_r <= 1'b1;
                data_r  <= s_axis_tdata;
            end else if (m_axis_tready) begin
                valid_r <= 1'b0;
            end
        end
    end
endmodule

module axis_data_fifo_meta_32 (
    input  logic        s_axis_aresetn,
    input  logic        s_axis_aclk,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic [31:0] s_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic [31:0] m_axis_tdata
);
    logic valid_r;
    logic [31:0] data_r;

    assign s_axis_tready = ~valid_r || m_axis_tready;
    assign m_axis_tvalid = valid_r;
    assign m_axis_tdata  = data_r;

    always_ff @(posedge s_axis_aclk) begin
        if (!s_axis_aresetn) begin
            valid_r <= 1'b0;
            data_r  <= '0;
        end else begin
            if (s_axis_tready && s_axis_tvalid) begin
                valid_r <= 1'b1;
                data_r  <= s_axis_tdata;
            end else if (m_axis_tready) begin
                valid_r <= 1'b0;
            end
        end
    end
endmodule

// ============================================================================
// ILA stubs (empty, synthesized away in simulation)
// ============================================================================
// All ILA modules used in nvme_top and sub-modules
// Each accepts .clk + .probeN but does nothing

`define DEFINE_ILA_STUB(name, n_probes) \
module name ( \
    input logic clk \
    `define _P(i) , input logic [$bits(clk)-1:0] probe``i \
); \
endmodule

// Instead of macro (which is tricky), define empty modules explicitly:

module ila_nvme_top (input clk,
    input probe0, input probe1, input [3:0] probe2, input [47:0] probe3,
    input [27:0] probe4, input probe5, input probe6,
    input probe7, input probe8, input [15:0] probe9,
    input probe10, input probe11, input [3:0] probe12, input [14:0] probe13, input probe14,
    input probe15, input probe16, input probe17, input probe18, input [15:0] probe19,
    input probe20, input probe21, input probe22, input probe23,
    input probe24, input probe25,
    input probe26, input probe27, input probe28, input probe29,
    input probe30, input probe31, input probe32, input probe33
);
endmodule

module ila_nvme_s0 (input clk,
    input probe0, input probe1, input probe2, input probe3,
    input [3:0] probe4, input probe5, input probe6, input probe7, input [1:0] probe8
);
endmodule

module ila_nvme_s1 (input clk,
    input probe0, input probe1, input probe2, input probe3,
    input [15:0] probe4, input [63:0] probe5,
    input probe6, input probe7, input [15:0] probe8,
    input probe9, input probe10, input probe11, input probe12,
    input [63:0] probe13, input [2:0] probe14, input probe15, input probe16
);
endmodule

module ila_nvme_s2 (input clk,
    input probe0, input probe1, input probe2, input probe3,
    input probe4, input probe5, input [3:0] probe6,
    input [63:0] probe7, input [15:0] probe8,
    input probe9, input probe10, input [63:0] probe11, input [1:0] probe12
);
endmodule

module ila_nvme_info_table (input clk,
    input probe0, input probe1, input [3:0] probe2, input probe3,
    input [47:0] probe4, input [27:0] probe5,
    input probe6, input probe7, input [15:0] probe8,
    input [63:0] probe9, input [5:0] probe10,
    input probe11, input probe12, input [3:0] probe13, input [5:0] probe14,
    input probe15, input probe16, input [3:0] probe17,
    input probe18, input probe19, input probe20, input [3:0] probe21,
    input probe22, input probe23
);
endmodule

module ila_nvme_manage_prp (input clk,
    input probe0, input probe1, input probe2, input probe3,
    input [63:0] probe4, input [63:0] probe5,
    input probe6, input probe7, input probe8, input probe9,
    input [47:0] probe10, input probe11,
    input probe12, input probe13, input [3:0] probe14, input [63:0] probe15
);
endmodule

module ila_nvme_sq_ctrl (input clk,
    input probe0, input probe1, input [3:0] probe2, input [9:0] probe3,
    input probe4, input [9:0] probe5, input probe6,
    input [9:0] probe7, input [9:0] probe8, input [31:0] probe9
);
endmodule

module ila_nvme_cq_ctrl (input clk,
    input probe0, input [3:0] probe1, input [5:0] probe2,
    input probe3, input probe4, input [3:0] probe5,
    input [14:0] probe6, input probe7, input [2:0] probe8,
    input [3:0] probe9, input [5:0] probe10, input [7:0] probe11,
    input [15:0] probe12, input [15:0] probe13
);
endmodule

module ila_nvme_prp_ctrl (input clk,
    input probe0, input probe1, input [18:0] probe2, input [31:0] probe3,
    input probe4, input [18:0] probe5, input probe6, input [18:0] probe7
);
endmodule

module ila_nvme_cnfg_slave (input clk,
    input probe0, input probe1, input [63:0] probe2,
    input probe3, input probe4, input [31:0] probe5,
    input probe6, input probe7,
    input probe8, input probe9, input [3:0] probe10,
    input probe11, input probe12, input probe13, input [3:0] probe14,
    input probe15, input [63:0] probe16
);
endmodule

module ila_nvme_sq_doorbell_writer (input clk,
    input probe0, input probe1, input [63:0] probe2, input [5:0] probe3,
    input probe4, input probe5, input [43:0] probe6,
    input probe7, input probe8, input [1:0] probe9
);
endmodule

module ila_nvme_cq_head_tracker (input clk,
    input probe0, input [3:0] probe1,
    input probe2, input probe3, input [3:0] probe4, input [5:0] probe5,
    input probe6, input probe7, input [43:0] probe8,
    input [1:0] probe9, input [5:0] probe10, input [5:0] probe11, input [3:0] probe12
);
endmodule

module ila_nvme_dma_arb (input clk,
    input probe0, input probe1, input probe2, input probe3,
    input probe4, input probe5, input probe6, input probe7,
    input [1:0] probe8
);
endmodule
