# Makefile for nvme_top simulation with Vivado xsim

PROJ_ROOT := $(abspath ../../..)
HDL_DIR   := $(PROJ_ROOT)/hw/hdl
PKG_DIR   := $(HDL_DIR)/pkg
NVME_DIR  := $(HDL_DIR)/nvme
RAM_DIR   := $(HDL_DIR)/common/ram
SIM_DIR   := $(abspath .)

# Use generated lynx_pkg from build (has all parameters set)
BUILD_DIR := $(PROJ_ROOT)/examples/13_nvme_functionality/hw/build
LYNX_PKG  := $(BUILD_DIR)/example_13_nvme_functionality_config_0/user_c0_0/hdl/lynx_pkg.sv

# Source files (order matters for xvlog)
PKG_SRCS := \
	$(LYNX_PKG)

INTF_SRCS := \
	$(PKG_DIR)/axi_intf.sv \
	$(PKG_DIR)/lynx_intf.sv

MOCK_SRCS := \
	$(SIM_DIR)/mock_xilinx_ip.sv

RAM_SRCS := \
	$(RAM_DIR)/sdp_ram_c.sv \
	$(RAM_DIR)/tdp_ram_c.sv

RTL_SRCS := \
	$(NVME_DIR)/slave/nvme_cnfg_slave.sv \
	$(NVME_DIR)/slave/nvme_sq_ctrl.sv \
	$(NVME_DIR)/slave/nvme_cq_ctrl.sv \
	$(NVME_DIR)/slave/nvme_prp_ctrl.sv \
	$(NVME_DIR)/nvme_s0.sv \
	$(NVME_DIR)/nvme_s1.sv \
	$(NVME_DIR)/nvme_s2.sv \
	$(NVME_DIR)/nvme_info_table.sv \
	$(NVME_DIR)/nvme_manage_prp.sv \
	$(NVME_DIR)/nvme_sq_doorbell_writer.sv \
	$(NVME_DIR)/nvme_cq_head_tracker.sv \
	$(NVME_DIR)/dma_axis_arbiter_2to1.sv \
	$(NVME_DIR)/nvme_top.sv

TB_SRCS := \
	$(SIM_DIR)/tb_nvme_top.sv

ALL_SRCS := $(PKG_SRCS) $(INTF_SRCS) $(MOCK_SRCS) $(RAM_SRCS) $(RTL_SRCS) $(TB_SRCS)

# xvlog/xelab/xsim settings
XVLOG_FLAGS := --sv -L uvm --include $(PKG_DIR) -d SIM_NVME
XELAB_FLAGS := --debug typical -L uvm
TOP         := tb_nvme_top

.PHONY: all compile elaborate sim clean

all: sim

compile:
	xvlog $(XVLOG_FLAGS) $(ALL_SRCS)

elaborate: compile
	xelab $(XELAB_FLAGS) $(TOP) -s sim_snapshot

sim: elaborate
	xsim sim_snapshot -runall -log sim.log

gui: elaborate
	xsim sim_snapshot -gui

clean:
	rm -rf xsim.dir .Xil *.jou *.log *.pb *.wdb *.vcd webtalk* xvlog* xelab*
