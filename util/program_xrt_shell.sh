#!/bin/bash
#===============================================================================
# revert_fpga.sh - Revert FPGA to Golden/XRT Shell Image (Boot from Flash)
#===============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCL_SCRIPT="$SCRIPT_DIR/flash_xrt_bitstream.tcl"

# Default values
SERIAL=""
DEVICE=""
HOTPLUG=1

# PCIe info
UPSTREAM_PORT=""
ROOT_PORT=""
LINK_CTL=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

#===============================================================================
# Functions
#===============================================================================

usage() {
    echo ""
    echo -e "${BOLD}Usage:${NC} $0 [options]"
    echo ""
    echo -e "${BOLD}Optional:${NC}"
    echo "  --no-hotplug             Skip PCIe hot plug (not recommended)"
    echo "  -h, --help               Show this help"
    echo ""
    echo -e "${BOLD}Description:${NC}"
    echo "  Reverts a U55C (or similar Alveo) from a JTAG-programmed bitstream"
    echo "  (e.g., Coyote) back to the golden/XRT shell image stored in flash."
    echo "  Auto-detects JTAG serial, device name, and PCIe topology."
    echo "  Removes Coyote driver if loaded."
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  sudo $0"
    echo "  sudo $0 --no-hotplug"
    echo ""
    exit 0
}

error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${GREEN}$1${NC}"
}

find_vivado() {
    if [ -n "$XILINX_VIVADO" ] && [ -x "$XILINX_VIVADO/bin/vivado" ]; then
        echo "$XILINX_VIVADO/bin/vivado"
    elif command -v vivado &>/dev/null; then
        command -v vivado
    elif [ -d "/tools/Xilinx/Vivado" ]; then
        local ver=$(ls /tools/Xilinx/Vivado 2>/dev/null | sort -V | tail -1)
        [ -n "$ver" ] && echo "/tools/Xilinx/Vivado/$ver/bin/vivado"
    fi
}

detect_serial() {
    echo -n "  Detecting JTAG target... "

    local tcl=$(mktemp)
    cat > "$tcl" << 'EOF'
open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
foreach t [get_hw_targets *xilinx_tcf/Xilinx/*] {
    puts "SERIAL:[lindex [split $t /] end]"
}
close_hw_manager
exit
EOF

    local result=$("$VIVADO" -mode tcl -nolog -nojournal -source "$tcl" 2>/dev/null | grep "^SERIAL:" | head -1)
    rm -f "$tcl"

    if [ -n "$result" ]; then
        SERIAL="${result#SERIAL:}"
        echo "$SERIAL"
    else
        echo "FAILED"
        error "No JTAG target found. Check cable connection."
    fi
}

detect_device() {
    echo -n "  Detecting device... "

    local tcl=$(mktemp)
    cat > "$tcl" << EOF
open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
current_hw_target [get_hw_targets *xilinx_tcf/Xilinx/${SERIAL}*]
open_hw_target
foreach d [get_hw_devices] { puts "DEVICE:\$d" }
close_hw_manager
exit
EOF

    local result=$("$VIVADO" -mode tcl -nolog -nojournal -source "$tcl" 2>/dev/null | grep "^DEVICE:" | head -1)
    rm -f "$tcl"

    if [ -n "$result" ]; then
        DEVICE="${result#DEVICE:}"
        echo "$DEVICE"
    else
        echo "FAILED"
        error "No device found on target $SERIAL"
    fi
}

save_pcie_info() {
    echo -n "  Saving PCIe info... "

    local bdf=$(lspci -d 10ee: 2>/dev/null | head -1 | awk '{print $1}')

    if [ -z "$bdf" ]; then
        echo "No Xilinx PCIe device."
        return 1
    fi

    UPSTREAM_PORT="${bdf%.*}"
    ROOT_PORT=$(lspci -s "${UPSTREAM_PORT}.0" -PP 2>/dev/null | head -1 | cut -d'/' -f1)

    if [ -z "$ROOT_PORT" ]; then
        echo "No root port found."
        return 1
    fi

    local pcie_cap=$(sudo lspci -s "$ROOT_PORT" -vv 2>/dev/null | sed -n 's/.*Capabilities: \[\([0-9a-fA-F]*\)\] Express.*/\1/p' | head -1)
    [ -z "$pcie_cap" ] && pcie_cap="58"
    LINK_CTL=$(printf "%X" $((0x$pcie_cap + 0x10)))

    echo "root=$ROOT_PORT upstream=$UPSTREAM_PORT"
    return 0
}

pci_remove() {
    echo -n "  Removing PCIe device... "

    local bdf=$(lspci -d 10ee: 2>/dev/null | head -1 | awk '{print $1}')

    if [ -z "$bdf" ]; then
        echo "not found."
        return
    fi

    sudo sh -c "echo 1 > /sys/bus/pci/devices/0000:$bdf/remove" 2>/dev/null || true
    sleep 1
    echo "done."
}

pci_hotplug() {
    echo ""
    echo -e "${BOLD}PCIe Hot Plug${NC}"

    if [ -z "$ROOT_PORT" ] || [ -z "$UPSTREAM_PORT" ] || [ -z "$LINK_CTL" ]; then
        echo -n "  Simple rescan... "
        sudo sh -c "echo 1 > /sys/bus/pci/rescan" 2>/dev/null || true
        sleep 2
        echo "done."
        return
    fi

    local root_bus=${ROOT_PORT:0:2}
    local root_dev=${ROOT_PORT:3:2}
    local root_func=${ROOT_PORT:6:1}
    local upstream_bus=${UPSTREAM_PORT:0:2}
    local upstream_dev=${UPSTREAM_PORT:3:2}

    echo -n "  Removing root port... "
    sudo sh -c "echo 1 > /sys/bus/pci/devices/0000:${root_bus}:${root_dev}.${root_func}/remove" 2>/dev/null || true
    sleep 1
    sudo sh -c "echo 1 > /sys/bus/pci/rescan"
    sleep 1
    echo "done."

    echo -n "  Removing upstream device... "
    sudo sh -c "echo 1 > /sys/bus/pci/devices/0000:${upstream_bus}:${upstream_dev}.0/remove" 2>/dev/null || true
    sleep 1
    echo "done."

    echo -n "  Toggling PCIe link... "
    sudo setpci -s "$ROOT_PORT" "${LINK_CTL}.b=70" 2>/dev/null || true
    sleep 1
    sudo setpci -s "$ROOT_PORT" "${LINK_CTL}.b=60" 2>/dev/null || true
    sleep 1
    echo "done."

    echo -n "  Rescanning... "
    sudo sh -c "echo 1 > /sys/bus/pci/rescan"
    sleep 1
    echo "done."

    echo -n "  Final rescan... "
    sudo sh -c "echo 1 > /sys/bus/pci/devices/0000:${root_bus}:${root_dev}.${root_func}/remove" 2>/dev/null || true
    sleep 1
    sudo sh -c "echo 1 > /sys/bus/pci/rescan"
    sleep 2
    echo "done."

    echo ""
    if lspci -d 10ee: 2>/dev/null | grep -q .; then
        info "  Device: $(lspci -d 10ee: | head -1)"
    else
        echo -e "${RED}  Warning: Device not detected. Cold reboot may be required.${NC}"
    fi
}

remove_drivers() {
    echo ""
    echo -e "${BOLD}Driver Cleanup${NC}"

    local removed=0

    # Remove coyote driver
    if lsmod | grep -q "^coyote_drv"; then
        echo -n "  Removing coyote_drv... "
        sudo rmmod coyote_drv 2>/dev/null || true
        sleep 1
        echo "done."
        removed=1
    fi

    if lsmod | grep -q "^coyote_driver"; then
        echo -n "  Removing coyote_driver... "
        sudo rmmod coyote_driver 2>/dev/null || true
        sleep 1
        echo "done."
        removed=1
    fi

    if [ $removed -eq 0 ]; then
        echo "  No Coyote drivers loaded."
    fi
}

#===============================================================================
# Parse arguments
#===============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --no-hotplug) HOTPLUG=0; shift ;;
        -h|--help)    usage ;;
        *)            error "Unknown option: $1. Use -h for help." ;;
    esac
done

#===============================================================================
# Validation
#===============================================================================

[ ! -f "$TCL_SCRIPT" ] && error "TCL script not found: $TCL_SCRIPT"

VIVADO=$(find_vivado)
[ -z "$VIVADO" ] && error "Vivado not found. Set XILINX_VIVADO or add to PATH."

#===============================================================================
# Main
#===============================================================================

echo ""
echo -e "${BOLD}======================================${NC}"
echo -e "${BOLD}  Revert FPGA to Golden Image${NC}"
echo -e "${BOLD}======================================${NC}"
echo ""

detect_serial
detect_device

echo ""

remove_drivers
save_pcie_info
pci_remove

echo ""
echo -n "  Booting from flash... "

CMD="$VIVADO -mode batch -nolog -nojournal -source $TCL_SCRIPT -tclargs $SERIAL $DEVICE"

if eval "$CMD" > /dev/null 2>&1; then
    echo "done."
    info "  Golden image loaded!"
else
    echo "FAILED"
    error "Boot from flash failed."
fi

[ $HOTPLUG -eq 1 ] && pci_hotplug

echo ""
info "======================================="
info "  Revert complete!"
info "======================================="
echo ""

