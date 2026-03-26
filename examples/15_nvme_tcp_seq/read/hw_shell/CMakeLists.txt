cmake_minimum_required(VERSION 3.5)
set(CYT_DIR ${CMAKE_SOURCE_DIR}/../../../../)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CYT_DIR}/cmake)
find_package(CoyoteHW REQUIRED)

project(example_16_nvme_tcp_read_shell)
message("*** Coyote Example 16: NVMe -> TCP Sequential Read [Shell] ***")

set(BUILD_STATIC 1)
set(BUILD_SHELL 0)
set(BUILD_OPT 1)

set(EN_MEM 1)
set(EN_STRM 1)
set(N_CARD_AXI 1)
set(EN_TCP 1)
set(EN_NVME 1)

set(N_REGIONS 1)

validation_checks_hw()

load_apps (
    VFPGA_C0_0 "../hw/src"
)

create_hw()
