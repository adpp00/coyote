# boot_from_flash.tcl
# Boots the FPGA from configuration memory (flash), reverting to the golden/XRT shell image.
# This undoes any volatile JTAG programming (e.g., Coyote bitstream).
#
# Usage:
#   vivado -mode batch -source boot_from_flash.tcl -tclargs <serial> <device>
#
# Example:
#   vivado -mode batch -source boot_from_flash.tcl -tclargs XFL1U51TW40FA xcu280_u55c_0

if { $argc < 2 } {
    puts "Usage: vivado -mode batch -source boot_from_flash.tcl -tclargs <serial> <device>"
    exit 1
}

set serial_number [lindex $argv 0]
set device_name   [lindex $argv 1]
set server_addr   "localhost"

puts "============================================"
puts "Serial    : $serial_number"
puts "Device    : $device_name"
puts "Action    : Boot from flash (golden image)"
puts "============================================"

# Connect
open_hw_manager
connect_hw_server -url ${server_addr}:3121 -allow_non_jtag

# Open target
set targets [get_hw_targets */xilinx_tcf/Xilinx/${serial_number}*]
if { [llength $targets] == 0 } {
    puts "ERROR: Target not found: $serial_number"
    puts "Available: [get_hw_targets]"
    close_hw_manager
    exit 1
}
current_hw_target [lindex $targets 0]
set_property PARAM.FREQUENCY 15000000 [current_hw_target]
open_hw_target

# Get device
set devices [get_hw_devices ${device_name}*]
if { [llength $devices] == 0 } {
    puts "ERROR: Device not found: $device_name"
    puts "Available: [get_hw_devices]"
    close_hw_target
    close_hw_manager
    exit 1
}
set device [lindex $devices 0]
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
