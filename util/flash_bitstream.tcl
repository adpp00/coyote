# flash_bitstream.tcl
# Usage:
#   vivado -mode batch -source flash_bitstream.tcl -tclargs <bitstream> [ltx]
#
# Auto-detects JTAG target and device. Single Vivado session.

if { $argc < 1 } {
    puts "Usage: vivado -mode batch -source flash_bitstream.tcl -tclargs <bitstream> \[ltx\]"
    exit 1
}

set bitstream_path [lindex $argv 0]
set ltx_path       ""
if { $argc >= 2 } { set ltx_path [lindex $argv 1] }

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

# Program
puts "Programming: $bitstream_path"
set_property PROGRAM.FILE $bitstream_path $device
if { $ltx_path ne "" } {
    set_property PROBES.FILE $ltx_path $device
}

program_hw_devices $device

# Refresh
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
