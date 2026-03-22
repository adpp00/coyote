# flash_bitstream.tcl
# Usage:
#   vivado -mode batch -source flash_bitstream.tcl -tclargs <serial> <device> <bitstream> [ltx]
#
# Example:
#   vivado -mode batch -source flash_bitstream.tcl -tclargs XFL1U51TW40FA xcu280_u55c_0 ./cyt_top.bit
#   vivado -mode batch -source flash_bitstream.tcl -tclargs XFL1U51TW40FA xcu280_u55c_0 ./cyt_top.bit ./cyt_top.ltx

if { $argc < 3 } {
    puts "Usage: vivado -mode batch -source flash_bitstream.tcl -tclargs <serial> <device> <bitstream> \[ltx\]"
    exit 1
}

set serial_number  [lindex $argv 0]
set device_name    [lindex $argv 1]
set bitstream_path [lindex $argv 2]
set ltx_path       ""
if { $argc >= 4 } { set ltx_path [lindex $argv 3] }

set server_addr "localhost"

puts "============================================"
puts "Serial    : $serial_number"
puts "Device    : $device_name"
puts "Bitstream : $bitstream_path"
if { $ltx_path ne "" } { puts "LTX       : $ltx_path" }
puts "============================================"

# Validate files
if { ![file exists $bitstream_path] } {
    puts "ERROR: Bitstream not found: $bitstream_path"
    exit 1
}
if { $ltx_path ne "" && ![file exists $ltx_path] } {
    puts "ERROR: LTX not found: $ltx_path"
    exit 1
}

# Connect
open_hw_manager
connect_hw_server -url ${server_addr}:3121 -allow_non_jtag

# Open target
set targets [get_hw_targets */xilinx_tcf/Xilinx/${serial_number}*]
if { [llength $targets] == 0 } {
    puts "ERROR: Target not found: $serial_number"
    puts "Available: [get_hw_targets]"
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
    exit 1
}
set device [lindex $devices 0]
current_hw_device $device

# Program
set_property PROGRAM.FILE $bitstream_path $device
if { $ltx_path ne "" } {
    set_property PROBES.FILE $ltx_path $device
}

program_hw_devices $device

# Refresh with probes
if { $ltx_path ne "" } {
    refresh_hw_device -update_hw_probes true $device
} else {
    refresh_hw_device $device
}

puts ""
puts "SUCCESS: Programming complete!"

close_hw_target
close_hw_manager
exit 0
