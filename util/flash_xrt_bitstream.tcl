# flash_xrt_bitstream.tcl
# Boots the FPGA from configuration memory (flash), reverting to the golden/XRT shell image.
# This undoes any volatile JTAG programming (e.g., Coyote bitstream).
#
# Usage:
#   vivado -mode batch -source flash_xrt_bitstream.tcl
#
# Auto-detects JTAG target and device. Single Vivado session.

# Connect
open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag

# Auto-detect target
set targets [get_hw_targets *xilinx_tcf/Xilinx/*]
if { [llength $targets] == 0 } {
    puts "ERROR: No JTAG target found"
    exit 1
}
set target [lindex $targets 0]
set serial [lindex [split $target /] end]
puts "JTAG target: $serial"

current_hw_target $target
set_property PARAM.FREQUENCY 15000000 [current_hw_target]
open_hw_target

# Auto-detect device
set devices [get_hw_devices]
if { [llength $devices] == 0 } {
    puts "ERROR: No device found"
    exit 1
}
set device [lindex $devices 0]
puts "Device: $device"

current_hw_device $device
refresh_hw_device -update_hw_probes false $device

# Boot from configuration memory (golden/XRT shell)
boot_hw_device $device
refresh_hw_device $device

puts ""
puts "SUCCESS: Device booted from flash (golden image)!"

close_hw_target
close_hw_manager
exit 0
