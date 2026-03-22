/**
 * This file is part of the Coyote <https://github.com/fpgasystems/Coyote>
 *
 * MIT Licence
 * Copyright (c) 2025, Systems Group, ETH Zurich
 * All rights reserved.
 */

import lynxTypes::*;

/**
 * nvme_axi_ctrl_parser
 * @brief Reads from/writes to the AXI Lite stream for NVMe control
 *
 * Register Map:
 * 0x00 (W1S) : Control (bit 0 = start)
 * 0x08 (RO)  : Status (bit 0 = done, bits[31:16] = error)
 * 0x10 (WR)  : NVMe Device ID
 * 0x18 (WR)  : NVMe Namespace ID (NSID)
 * 0x20 (WR)  : NVMe LBA (Logical Block Address)
 * 0x28 (WR)  : Transfer Size (bytes)
 * 0x30 (WR)  : Virtual Address
 * 0x38 (WR)  : Write/Read (1 = write, 0 = read)
 */
module nvme_axi_ctrl_parser (
  input  logic                        aclk,
  input  logic                        aresetn,

  AXI4L.s                             axi_ctrl,

  // Control outputs
  output logic                        nvme_start,
  output logic [63:0]                 nvme_dev_id,
  output logic [63:0]                 nvme_nsid,
  output logic [63:0]                 nvme_lba,
  output logic [63:0]                 nvme_len,
  output logic [63:0]                 nvme_vaddr,
  output logic                        nvme_write,

  // Status inputs
  input  logic                        nvme_done,
  input  logic [15:0]                 nvme_error
);

/////////////////////////////////////
//          CONSTANTS             //
///////////////////////////////////
localparam integer N_REGS = 8;
localparam integer ADDR_MSB = $clog2(N_REGS);
localparam integer ADDR_LSB = $clog2(AXIL_DATA_BITS/8);
localparam integer AXI_ADDR_BITS = ADDR_LSB + ADDR_MSB;

/////////////////////////////////////
//          REGISTERS             //
///////////////////////////////////
logic [AXI_ADDR_BITS-1:0] axi_awaddr;
logic axi_awready;
logic [AXI_ADDR_BITS-1:0] axi_araddr;
logic axi_arready;
logic [1:0] axi_bresp;
logic axi_bvalid;
logic axi_wready;
logic [AXIL_DATA_BITS-1:0] axi_rdata;
logic [1:0] axi_rresp;
logic axi_rvalid;
logic aw_en;

logic [N_REGS-1:0][AXIL_DATA_BITS-1:0] ctrl_reg;
logic ctrl_reg_rden;
logic ctrl_reg_wren;

/////////////////////////////////////
//         REGISTER MAP           //
///////////////////////////////////
localparam integer CTRL_REG       = 0;  // Control (bit 0 = start)
localparam integer STATUS_REG     = 1;  // Status (bit 0 = done, bits[31:16] = error)
localparam integer DEV_ID_REG     = 2;  // NVMe Device ID
localparam integer NSID_REG       = 3;  // Namespace ID
localparam integer LBA_REG        = 4;  // LBA
localparam integer LEN_REG        = 5;  // Transfer size
localparam integer VADDR_REG      = 6;  // Virtual address
localparam integer WRITE_REG      = 7;  // Write/Read flag

/////////////////////////////////////
//         WRITE PROCESS          //
///////////////////////////////////
assign ctrl_reg_wren = axi_wready && axi_ctrl.wvalid && axi_awready && axi_ctrl.awvalid;

always_ff @(posedge aclk) begin
  if (aresetn == 1'b0) begin
    ctrl_reg <= 0;
  end
  else begin
    // Control register auto-clears
    ctrl_reg[CTRL_REG] <= 0;

    if(ctrl_reg_wren) begin
      case (axi_awaddr[ADDR_LSB+:ADDR_MSB])
        CTRL_REG:
          for (int i = 0; i < (AXIL_DATA_BITS/8); i++) begin
            if(axi_ctrl.wstrb[i]) begin
              ctrl_reg[CTRL_REG][(i*8)+:8] <= axi_ctrl.wdata[(i*8)+:8];
            end
          end
        DEV_ID_REG:
          for (int i = 0; i < (AXIL_DATA_BITS/8); i++) begin
            if(axi_ctrl.wstrb[i]) begin
              ctrl_reg[DEV_ID_REG][(i*8)+:8] <= axi_ctrl.wdata[(i*8)+:8];
            end
          end
        NSID_REG:
          for (int i = 0; i < (AXIL_DATA_BITS/8); i++) begin
            if(axi_ctrl.wstrb[i]) begin
              ctrl_reg[NSID_REG][(i*8)+:8] <= axi_ctrl.wdata[(i*8)+:8];
            end
          end
        LBA_REG:
          for (int i = 0; i < (AXIL_DATA_BITS/8); i++) begin
            if(axi_ctrl.wstrb[i]) begin
              ctrl_reg[LBA_REG][(i*8)+:8] <= axi_ctrl.wdata[(i*8)+:8];
            end
          end
        LEN_REG:
          for (int i = 0; i < (AXIL_DATA_BITS/8); i++) begin
            if(axi_ctrl.wstrb[i]) begin
              ctrl_reg[LEN_REG][(i*8)+:8] <= axi_ctrl.wdata[(i*8)+:8];
            end
          end
        VADDR_REG:
          for (int i = 0; i < (AXIL_DATA_BITS/8); i++) begin
            if(axi_ctrl.wstrb[i]) begin
              ctrl_reg[VADDR_REG][(i*8)+:8] <= axi_ctrl.wdata[(i*8)+:8];
            end
          end
        WRITE_REG:
          for (int i = 0; i < (AXIL_DATA_BITS/8); i++) begin
            if(axi_ctrl.wstrb[i]) begin
              ctrl_reg[WRITE_REG][(i*8)+:8] <= axi_ctrl.wdata[(i*8)+:8];
            end
          end
        default: ;
      endcase
    end
  end
end

/////////////////////////////////////
//         READ PROCESS           //
///////////////////////////////////
assign ctrl_reg_rden = axi_arready & axi_ctrl.arvalid & ~axi_rvalid;

always_ff @(posedge aclk) begin
  if(aresetn == 1'b0) begin
    axi_rdata <= 0;
  end
  else begin
    if(ctrl_reg_rden) begin
      axi_rdata <= 0;

      case (axi_araddr[ADDR_LSB+:ADDR_MSB])
        STATUS_REG:
          axi_rdata <= {32'b0, nvme_error, 15'b0, nvme_done};
        default: ;
      endcase
    end
  end
end

/////////////////////////////////////
//       OUTPUT ASSIGNMENT        //
///////////////////////////////////
always_comb begin
  nvme_start   = ctrl_reg[CTRL_REG][0];
  nvme_dev_id  = ctrl_reg[DEV_ID_REG];
  nvme_nsid    = ctrl_reg[NSID_REG];
  nvme_lba     = ctrl_reg[LBA_REG];
  nvme_len     = ctrl_reg[LEN_REG];
  nvme_vaddr   = ctrl_reg[VADDR_REG];
  nvme_write   = ctrl_reg[WRITE_REG][0];
end

/////////////////////////////////////
//     STANDARD AXI CONTROL       //
///////////////////////////////////
assign axi_ctrl.awready = axi_awready;
assign axi_ctrl.arready = axi_arready;
assign axi_ctrl.bresp = axi_bresp;
assign axi_ctrl.bvalid = axi_bvalid;
assign axi_ctrl.wready = axi_wready;
assign axi_ctrl.rdata = axi_rdata;
assign axi_ctrl.rresp = axi_rresp;
assign axi_ctrl.rvalid = axi_rvalid;

// awready and awaddr
always_ff @(posedge aclk) begin
  if ( aresetn == 1'b0 ) begin
    axi_awready <= 1'b0;
    axi_awaddr <= 0;
    aw_en <= 1'b1;
  end
  else begin
    if (~axi_awready && axi_ctrl.awvalid && axi_ctrl.wvalid && aw_en) begin
      axi_awready <= 1'b1;
      aw_en <= 1'b0;
      axi_awaddr <= axi_ctrl.awaddr;
    end
    else if (axi_ctrl.bready && axi_bvalid) begin
      aw_en <= 1'b1;
      axi_awready <= 1'b0;
    end
    else begin
      axi_awready <= 1'b0;
    end
  end
end

// arready and araddr
always_ff @(posedge aclk) begin
  if ( aresetn == 1'b0 ) begin
    axi_arready <= 1'b0;
    axi_araddr  <= 0;
  end
  else begin
    if (~axi_arready && axi_ctrl.arvalid) begin
      axi_arready <= 1'b1;
      axi_araddr  <= axi_ctrl.araddr;
    end
    else begin
      axi_arready <= 1'b0;
    end
  end
end

// bvalid and bresp
always_ff @(posedge aclk) begin
  if ( aresetn == 1'b0 ) begin
    axi_bvalid  <= 0;
    axi_bresp   <= 2'b0;
  end
  else begin
    if (axi_awready && axi_ctrl.awvalid && ~axi_bvalid && axi_wready && axi_ctrl.wvalid) begin
      axi_bvalid <= 1'b1;
      axi_bresp  <= 2'b0;
    end
    else begin
      if (axi_ctrl.bready && axi_bvalid) begin
        axi_bvalid <= 1'b0;
      end
    end
  end
end

// wready
always_ff @(posedge aclk) begin
  if ( aresetn == 1'b0 ) begin
    axi_wready <= 1'b0;
  end
  else begin
    if (~axi_wready && axi_ctrl.wvalid && axi_ctrl.awvalid && aw_en ) begin
      axi_wready <= 1'b1;
    end
    else begin
      axi_wready <= 1'b0;
    end
  end
end

// rvalid and rresp
always_ff @(posedge aclk) begin
  if ( aresetn == 1'b0 ) begin
    axi_rvalid <= 0;
    axi_rresp  <= 0;
  end
  else begin
    if (axi_arready && axi_ctrl.arvalid && ~axi_rvalid) begin
      axi_rvalid <= 1'b1;
      axi_rresp  <= 2'b0;
    end
    else if (axi_rvalid && axi_ctrl.rready) begin
      axi_rvalid <= 1'b0;
    end
  end
end

endmodule
