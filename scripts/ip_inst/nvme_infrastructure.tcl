##
## NVMe infrastructure IP instantiation
##

# ============================================================================
# AXI BRAM Controllers
# ============================================================================

# PRP BRAM controller — 64-bit data, single port, AXI4, 2-cycle BRAM latency
# MEM_DEPTH=131072: 1MB address space / 8B = 131072 (256KB × 4 devices)
create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name prp_axi_bram_ctrl
set_property -dict [list CONFIG.DATA_WIDTH {64} CONFIG.SINGLE_PORT_BRAM {1} CONFIG.PROTOCOL {AXI4} CONFIG.READ_LATENCY {2} CONFIG.MEM_DEPTH {131072} ] [get_ips prp_axi_bram_ctrl]

# SQ BRAM controller — 512-bit data, single port, AXI4, 2-cycle BRAM latency
# MEM_DEPTH=1024: 64 entries × 16 devices = 1024, covers 64KB address space
create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name sq_axi_bram_ctrl
set_property -dict [list CONFIG.DATA_WIDTH {512} CONFIG.SINGLE_PORT_BRAM {1} CONFIG.PROTOCOL {AXI4} CONFIG.READ_LATENCY {2} CONFIG.MEM_DEPTH {1024} ] [get_ips sq_axi_bram_ctrl]

# CQ BRAM controller — 128-bit data, single port, AXI4
# MEM_DEPTH=4096: 256 slots × 16 devices = 4096, covers 64KB address space
create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -version 4.1 -module_name cq_axi_bram_ctrl
set_property -dict [list CONFIG.DATA_WIDTH {128} CONFIG.SINGLE_PORT_BRAM {1} CONFIG.PROTOCOL {AXI4} CONFIG.MEM_DEPTH {4096} ] [get_ips cq_axi_bram_ctrl]

# AXI4-Stream Data FIFOs (axis_data_fifo_meta_128/96/32)
# Already created in common_infrastructure.tcl — reused here

# ============================================================================
# ILA Debug Cores
# ============================================================================

# --- ila_nvme_top: 34 probes ---
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_nvme_top
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {34} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {4} \
    CONFIG.C_DATA_DEPTH {1024} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {4} \
    CONFIG.C_PROBE3_WIDTH {48} \
    CONFIG.C_PROBE4_WIDTH {28} \
    CONFIG.C_PROBE5_WIDTH {1} \
    CONFIG.C_PROBE6_WIDTH {4} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {1} \
    CONFIG.C_PROBE9_WIDTH {16} \
    CONFIG.C_PROBE10_WIDTH {1} \
    CONFIG.C_PROBE11_WIDTH {1} \
    CONFIG.C_PROBE12_WIDTH {4} \
    CONFIG.C_PROBE13_WIDTH {15} \
    CONFIG.C_PROBE14_WIDTH {1} \
    CONFIG.C_PROBE15_WIDTH {1} \
    CONFIG.C_PROBE16_WIDTH {1} \
    CONFIG.C_PROBE17_WIDTH {1} \
    CONFIG.C_PROBE18_WIDTH {1} \
    CONFIG.C_PROBE19_WIDTH {16} \
    CONFIG.C_PROBE20_WIDTH {1} \
    CONFIG.C_PROBE21_WIDTH {1} \
    CONFIG.C_PROBE22_WIDTH {1} \
    CONFIG.C_PROBE23_WIDTH {1} \
    CONFIG.C_PROBE24_WIDTH {1} \
    CONFIG.C_PROBE25_WIDTH {1} \
    CONFIG.C_PROBE26_WIDTH {1} \
    CONFIG.C_PROBE27_WIDTH {1} \
    CONFIG.C_PROBE28_WIDTH {1} \
    CONFIG.C_PROBE29_WIDTH {1} \
    CONFIG.C_PROBE30_WIDTH {1} \
    CONFIG.C_PROBE31_WIDTH {1} \
    CONFIG.C_PROBE32_WIDTH {1} \
    CONFIG.C_PROBE33_WIDTH {1} \
] [get_ips ila_nvme_top]

# --- ila_nvme_s0: 9 probes ---
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_nvme_s0
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {9} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {4} \
    CONFIG.C_DATA_DEPTH {1024} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {4} \
    CONFIG.C_PROBE5_WIDTH {4} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {2} \
] [get_ips ila_nvme_s0]

# --- ila_nvme_s1: 17 probes ---
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_nvme_s1
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {17} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {4} \
    CONFIG.C_DATA_DEPTH {1024} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {16} \
    CONFIG.C_PROBE5_WIDTH {64} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {16} \
    CONFIG.C_PROBE9_WIDTH {1} \
    CONFIG.C_PROBE10_WIDTH {1} \
    CONFIG.C_PROBE11_WIDTH {1} \
    CONFIG.C_PROBE12_WIDTH {1} \
    CONFIG.C_PROBE13_WIDTH {64} \
    CONFIG.C_PROBE14_WIDTH {3} \
    CONFIG.C_PROBE15_WIDTH {1} \
    CONFIG.C_PROBE16_WIDTH {1} \
] [get_ips ila_nvme_s1]

# --- ila_nvme_s2: 13 probes ---
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_nvme_s2
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {13} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {4} \
    CONFIG.C_DATA_DEPTH {1024} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {1} \
    CONFIG.C_PROBE5_WIDTH {1} \
    CONFIG.C_PROBE6_WIDTH {4} \
    CONFIG.C_PROBE7_WIDTH {64} \
    CONFIG.C_PROBE8_WIDTH {16} \
    CONFIG.C_PROBE9_WIDTH {1} \
    CONFIG.C_PROBE10_WIDTH {1} \
    CONFIG.C_PROBE11_WIDTH {64} \
    CONFIG.C_PROBE12_WIDTH {2} \
] [get_ips ila_nvme_s2]

# --- ila_nvme_info_table: 24 probes ---
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_nvme_info_table
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {24} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {4} \
    CONFIG.C_DATA_DEPTH {1024} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {4} \
    CONFIG.C_PROBE3_WIDTH {4} \
    CONFIG.C_PROBE4_WIDTH {48} \
    CONFIG.C_PROBE5_WIDTH {28} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {16} \
    CONFIG.C_PROBE9_WIDTH {64} \
    CONFIG.C_PROBE10_WIDTH {6} \
    CONFIG.C_PROBE11_WIDTH {1} \
    CONFIG.C_PROBE12_WIDTH {1} \
    CONFIG.C_PROBE13_WIDTH {4} \
    CONFIG.C_PROBE14_WIDTH {6} \
    CONFIG.C_PROBE15_WIDTH {1} \
    CONFIG.C_PROBE16_WIDTH {1} \
    CONFIG.C_PROBE17_WIDTH {4} \
    CONFIG.C_PROBE18_WIDTH {1} \
    CONFIG.C_PROBE19_WIDTH {1} \
    CONFIG.C_PROBE20_WIDTH {4} \
    CONFIG.C_PROBE21_WIDTH {4} \
    CONFIG.C_PROBE22_WIDTH {1} \
    CONFIG.C_PROBE23_WIDTH {1} \
] [get_ips ila_nvme_info_table]

# --- ila_nvme_manage_prp: 16 probes ---
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_nvme_manage_prp
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {16} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {4} \
    CONFIG.C_DATA_DEPTH {1024} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {1} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {64} \
    CONFIG.C_PROBE5_WIDTH {64} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {1} \
    CONFIG.C_PROBE9_WIDTH {1} \
    CONFIG.C_PROBE10_WIDTH {48} \
    CONFIG.C_PROBE11_WIDTH {1} \
    CONFIG.C_PROBE12_WIDTH {1} \
    CONFIG.C_PROBE13_WIDTH {1} \
    CONFIG.C_PROBE14_WIDTH {4} \
    CONFIG.C_PROBE15_WIDTH {64} \
] [get_ips ila_nvme_manage_prp]

# --- ila_nvme_cnfg_slave: 17 probes ---
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_nvme_cnfg_slave
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {17} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {4} \
    CONFIG.C_DATA_DEPTH {1024} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {64} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {1} \
    CONFIG.C_PROBE5_WIDTH {32} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {1} \
    CONFIG.C_PROBE9_WIDTH {1} \
    CONFIG.C_PROBE10_WIDTH {4} \
    CONFIG.C_PROBE11_WIDTH {1} \
    CONFIG.C_PROBE12_WIDTH {1} \
    CONFIG.C_PROBE13_WIDTH {4} \
    CONFIG.C_PROBE14_WIDTH {4} \
    CONFIG.C_PROBE15_WIDTH {1} \
    CONFIG.C_PROBE16_WIDTH {64} \
] [get_ips ila_nvme_cnfg_slave]

# --- ila_nvme_sq_ctrl: 16 probes ---
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_nvme_sq_ctrl
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {16} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {4} \
    CONFIG.C_DATA_DEPTH {1024} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {4} \
    CONFIG.C_PROBE3_WIDTH {10} \
    CONFIG.C_PROBE4_WIDTH {1} \
    CONFIG.C_PROBE5_WIDTH {10} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {10} \
    CONFIG.C_PROBE8_WIDTH {10} \
    CONFIG.C_PROBE9_WIDTH {32} \
    CONFIG.C_PROBE10_WIDTH {32} \
    CONFIG.C_PROBE11_WIDTH {32} \
    CONFIG.C_PROBE12_WIDTH {32} \
    CONFIG.C_PROBE13_WIDTH {32} \
    CONFIG.C_PROBE14_WIDTH {32} \
    CONFIG.C_PROBE15_WIDTH {32} \
] [get_ips ila_nvme_sq_ctrl]

# --- ila_nvme_cq_ctrl: 14 probes ---
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_nvme_cq_ctrl
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {14} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {4} \
    CONFIG.C_DATA_DEPTH {1024} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {4} \
    CONFIG.C_PROBE2_WIDTH {6} \
    CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_PROBE4_WIDTH {1} \
    CONFIG.C_PROBE5_WIDTH {4} \
    CONFIG.C_PROBE6_WIDTH {15} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {3} \
    CONFIG.C_PROBE9_WIDTH {4} \
    CONFIG.C_PROBE10_WIDTH {6} \
    CONFIG.C_PROBE11_WIDTH {8} \
    CONFIG.C_PROBE12_WIDTH {16} \
    CONFIG.C_PROBE13_WIDTH {16} \
] [get_ips ila_nvme_cq_ctrl]

# --- ila_nvme_prp_ctrl: 8 probes ---
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_nvme_prp_ctrl
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {8} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {4} \
    CONFIG.C_DATA_DEPTH {1024} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {15} \
    CONFIG.C_PROBE3_WIDTH {32} \
    CONFIG.C_PROBE4_WIDTH {1} \
    CONFIG.C_PROBE5_WIDTH {15} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {15} \
] [get_ips ila_nvme_prp_ctrl]

# --- ila_nvme_cq_head_tracker: 16 probes ---
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_nvme_cq_head_tracker
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {16} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {4} \
    CONFIG.C_DATA_DEPTH {1024} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {4} \
    CONFIG.C_PROBE2_WIDTH {3} \
    CONFIG.C_PROBE3_WIDTH {4} \
    CONFIG.C_PROBE4_WIDTH {1} \
    CONFIG.C_PROBE5_WIDTH {1} \
    CONFIG.C_PROBE6_WIDTH {4} \
    CONFIG.C_PROBE7_WIDTH {6} \
    CONFIG.C_PROBE8_WIDTH {1} \
    CONFIG.C_PROBE9_WIDTH {1} \
    CONFIG.C_PROBE10_WIDTH {48} \
    CONFIG.C_PROBE11_WIDTH {1} \
    CONFIG.C_PROBE12_WIDTH {1} \
    CONFIG.C_PROBE13_WIDTH {7} \
    CONFIG.C_PROBE14_WIDTH {1} \
    CONFIG.C_PROBE15_WIDTH {64} \
] [get_ips ila_nvme_cq_head_tracker]

# --- ila_perf_nvme: 16 probes (user logic bench engine) ---
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_perf_nvme
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {16} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {4} \
    CONFIG.C_DATA_DEPTH {4096} \
    CONFIG.C_PROBE0_WIDTH {3} \
    CONFIG.C_PROBE1_WIDTH {2} \
    CONFIG.C_PROBE2_WIDTH {32} \
    CONFIG.C_PROBE3_WIDTH {32} \
    CONFIG.C_PROBE4_WIDTH {1} \
    CONFIG.C_PROBE5_WIDTH {4} \
    CONFIG.C_PROBE6_WIDTH {1} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {1} \
    CONFIG.C_PROBE9_WIDTH {4} \
    CONFIG.C_PROBE10_WIDTH {32} \
    CONFIG.C_PROBE11_WIDTH {16} \
    CONFIG.C_PROBE12_WIDTH {1} \
    CONFIG.C_PROBE13_WIDTH {16} \
    CONFIG.C_PROBE14_WIDTH {4} \
    CONFIG.C_PROBE15_WIDTH {4} \
] [get_ips ila_perf_nvme]

# --- ila_nvme_sq_doorbell_writer: 10 probes ---
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_nvme_sq_doorbell_writer
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {10} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {4} \
    CONFIG.C_DATA_DEPTH {1024} \
    CONFIG.C_PROBE0_WIDTH {1} \
    CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {64} \
    CONFIG.C_PROBE3_WIDTH {6} \
    CONFIG.C_PROBE4_WIDTH {1} \
    CONFIG.C_PROBE5_WIDTH {1} \
    CONFIG.C_PROBE6_WIDTH {48} \
    CONFIG.C_PROBE7_WIDTH {1} \
    CONFIG.C_PROBE8_WIDTH {1} \
    CONFIG.C_PROBE9_WIDTH {2} \
] [get_ips ila_nvme_sq_doorbell_writer]
