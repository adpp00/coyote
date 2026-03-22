# Util

Copy this directory to Coyote's `util` directory before use.

These scripts replace Coyote's default `util/program_alveo.tcl` and `util/hot_reset.sh` with an automated, all-in-one workflow. For full context on Coyote's build and deployment flow, see the [Coyote examples README](https://github.com/fpgasystems/coyote/blob/master/examples/README.md).

## Scripts

### `program_coyote.sh` — Program FPGA with a Coyote bitstream

Programs the FPGA via JTAG, performs PCIe hot plug, and optionally inserts the Coyote driver — all in one step. Auto-detects JTAG serial, device name, and PCIe topology.

```bash
# Basic usage (bitstream only)
sudo bash util/program_coyote.sh -b <path-to-bitstream>

# With driver insertion
sudo bash util/program_coyote.sh -b <path-to-bitstream> -d <path-to-driver.ko>

# With driver parameters (e.g., for networking examples)
sudo bash util/program_coyote.sh -b <path-to-bitstream> -d <path-to-driver.ko> \
    -p "ip_addr=0x0A000001,mac_addr=0x000000000001"

# With ILA probes file
sudo bash util/program_coyote.sh -b <path-to-bitstream> -l <path-to-probes.ltx>
```

**Example** — deploying Example 1 (Hello World):
```bash
# 1. Build the hardware and software (see Coyote examples README)
# 2. Build the driver
cd Coyote/driver && make TARGET_PLATFORM=ultrascale_plus

# 3. Program and deploy
sudo bash Coyote/util/program_coyote.sh \
    -b Coyote/examples/01_hello_world/hw/build_hw/bitstreams/cyt_top.bit \
    -d Coyote/driver/build/coyote_driver.ko

# 4. Verify with dmesg (last line should be "probe returning 0")
sudo dmesg | tail

# 5. Run the application
cd Coyote/examples/01_hello_world/sw/build_sw && ./test
```

### `program_xrt_shell.sh` — Revert FPGA to golden/XRT shell image

Reverts the FPGA from a JTAG-programmed bitstream (e.g., Coyote) back to the golden/XRT shell image stored in flash. Automatically removes any loaded Coyote drivers.

```bash
sudo bash util/program_xrt_shell.sh
```