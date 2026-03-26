# ILA for NVMe User Logic (ila_nvme_user) — 20 probes
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_nvme_user
set_property -dict [list \
    CONFIG.C_DATA_DEPTH {8192} \
    CONFIG.C_NUM_OF_PROBES {20} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {4} \
    CONFIG.C_PROBE0_WIDTH  {3}   \
    CONFIG.C_PROBE1_WIDTH  {1}   \
    CONFIG.C_PROBE2_WIDTH  {1}   \
    CONFIG.C_PROBE3_WIDTH  {16}  \
    CONFIG.C_PROBE4_WIDTH  {1}   \
    CONFIG.C_PROBE5_WIDTH  {1}   \
    CONFIG.C_PROBE6_WIDTH  {4}   \
    CONFIG.C_PROBE7_WIDTH  {48}  \
    CONFIG.C_PROBE8_WIDTH  {28}  \
    CONFIG.C_PROBE9_WIDTH  {1}   \
    CONFIG.C_PROBE10_WIDTH {1}   \
    CONFIG.C_PROBE11_WIDTH {16}  \
    CONFIG.C_PROBE12_WIDTH {1}   \
    CONFIG.C_PROBE13_WIDTH {4}   \
    CONFIG.C_PROBE14_WIDTH {15}  \
    CONFIG.C_PROBE15_WIDTH {1}   \
    CONFIG.C_PROBE16_WIDTH {4}   \
    CONFIG.C_PROBE17_WIDTH {32}  \
    CONFIG.C_PROBE18_WIDTH {28}  \
    CONFIG.C_PROBE19_WIDTH {1}   \
] [get_ips ila_nvme_user]
