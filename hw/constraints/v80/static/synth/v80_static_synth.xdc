# PCIe
create_clock -period 10.000 [get_ports pcie_clk_clk_p];

# DCMAC clocks
create_clock -period 3.103 -name gt0_refclk_p [get_ports gt0_refclk_p];

# PL-connected NVMe PCIe reference clock (the port only exists with NVME_TYPE=PL)
create_clock -quiet -period 10.000 -name pl_nvme_refclk_p [get_ports -quiet pl_nvme_refclk_p];
