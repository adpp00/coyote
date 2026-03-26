# ILA for NVMe->TCP Read (ila_nvme_tcp_read) - 24 probes
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_nvme_tcp_read
set_property -dict [list \
    CONFIG.C_DATA_DEPTH {8192} \
    CONFIG.C_NUM_OF_PROBES {24} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {4} \
    CONFIG.C_PROBE0_WIDTH  {5}   \
    CONFIG.C_PROBE1_WIDTH  {2}   \
    CONFIG.C_PROBE2_WIDTH  {1}   \
    CONFIG.C_PROBE3_WIDTH  {32}  \
    CONFIG.C_PROBE4_WIDTH  {32}  \
    CONFIG.C_PROBE5_WIDTH  {32}  \
    CONFIG.C_PROBE6_WIDTH  {16}  \
    CONFIG.C_PROBE7_WIDTH  {32}  \
    CONFIG.C_PROBE8_WIDTH  {1}   \
    CONFIG.C_PROBE9_WIDTH  {1}   \
    CONFIG.C_PROBE10_WIDTH {1}   \
    CONFIG.C_PROBE11_WIDTH {1}   \
    CONFIG.C_PROBE12_WIDTH {1}   \
    CONFIG.C_PROBE13_WIDTH {1}   \
    CONFIG.C_PROBE14_WIDTH {1}   \
    CONFIG.C_PROBE15_WIDTH {1}   \
    CONFIG.C_PROBE16_WIDTH {1}   \
    CONFIG.C_PROBE17_WIDTH {1}   \
    CONFIG.C_PROBE18_WIDTH {1}   \
    CONFIG.C_PROBE19_WIDTH {1}   \
    CONFIG.C_PROBE20_WIDTH {32}  \
    CONFIG.C_PROBE21_WIDTH {32}  \
    CONFIG.C_PROBE22_WIDTH {32}  \
    CONFIG.C_PROBE23_WIDTH {16}  \
] [get_ips ila_nvme_tcp_read]
