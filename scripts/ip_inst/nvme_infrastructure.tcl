######################################################################################
# This file is part of the Coyote <https://github.com/fpgasystems/Coyote>
#
# MIT Licence
# Copyright (c) 2021-2026, Systems Group, ETH Zurich
# All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
######################################################################################

##
## NVMe infrastructure IP instantiation
##

# Buffer NVMe-to-HBM write data independently of the stripe mapper's AW
# expansion latency. The stripe still regenerates physical WLAST at each
# 1 KiB fragment boundary.
create_ip -name axis_data_fifo -vendor xilinx.com -library ip -version 2.0 -module_name axis_data_fifo_nvme_w
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES {64} \
    CONFIG.FIFO_DEPTH {32} \
    CONFIG.HAS_TSTRB {1} \
    CONFIG.HAS_TLAST {1} \
] [get_ips axis_data_fifo_nvme_w]

# ============================================================================
# AXI BRAM Controllers
# ============================================================================

# 16 devices. The SSD-visible windows are fixed for every depth (SQ 16 KiB and
# PRP 1 MiB per device); nvme_sq_ctrl and nvme_prp_ctrl compact addresses ahead
# of the controllers to physical storage: one 64-byte SQE per configured entry,
# and 32 64-bit PRP entries per 4-KiB SSD-visible page.
set nvme_prp_mem_depth [expr {16 * $cfg(nvme_queue_depth) * 32}]
set nvme_sq_mem_depth [expr {16 * $cfg(nvme_queue_depth)}]
set nvme_queue_bits [expr {int(log($cfg(nvme_queue_depth))/log(2))}]

# PRP BRAM controller — 64-bit data, single port, AXI4, 1-cycle BRAM latency
create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name nvme_prp_axi_bram_ctrl
set_property -dict [list CONFIG.DATA_WIDTH {64} CONFIG.SINGLE_PORT_BRAM {1} CONFIG.PROTOCOL {AXI4} CONFIG.READ_LATENCY {1} CONFIG.MEM_DEPTH $nvme_prp_mem_depth ] [get_ips nvme_prp_axi_bram_ctrl]

# SQ BRAM controller — 512-bit data, single port, AXI4, 2-cycle BRAM latency
create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name nvme_sq_axi_bram_ctrl
set_property -dict [list CONFIG.DATA_WIDTH {512} CONFIG.SINGLE_PORT_BRAM {1} CONFIG.PROTOCOL {AXI4} CONFIG.READ_LATENCY {2} CONFIG.MEM_DEPTH $nvme_sq_mem_depth ] [get_ips nvme_sq_axi_bram_ctrl]

# CQ BRAM controller — 128-bit data, single port, AXI4
create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name nvme_cq_axi_bram_ctrl
set_property -dict [list CONFIG.DATA_WIDTH {128} CONFIG.SINGLE_PORT_BRAM {1} CONFIG.PROTOCOL {AXI4} CONFIG.MEM_DEPTH {4096} ] [get_ips nvme_cq_axi_bram_ctrl]

# ============================================================================
# Card window clock crossing (xclk to aclk, UltraScale+)
# ============================================================================

if {$cfg(en_nvme_host) eq 1 && $cfg(en_nvme_card) eq 1 && $cfg(fpga_arch) eq "ultrascale_plus"} {
    create_ip -name axi_clock_converter -vendor xilinx.com -library ip -version 2.1 -module_name axi_clock_converter_nvme_card
    set_property -dict [list CONFIG.ADDR_WIDTH {64} CONFIG.DATA_WIDTH {512} CONFIG.ID_WIDTH {6}] [get_ips axi_clock_converter_nvme_card]
}
