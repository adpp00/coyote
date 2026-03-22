/**
 * Example 13: NVMe Functionality Test
 *
 * Basic NVMe read/write verification:
 * 1. Initialize NVMe SSD
 * 2. Write test pattern to SSD
 * 3. Read back and verify
 */

#include <iostream>
#include <cstring>
#include <cstdint>
#include <string>
#include <getopt.h>

#include "cThread.hpp"

using namespace coyote;

/* User logic CSR registers (must match nvme_axi_ctrl_parser HW) */
enum Reg : uint32_t {
    CTRL            = 0,    // W: bit0=start (auto-clears)
    STATUS          = 1,    // R: bit0=done, bits[31:16]=error
    DEV_ID          = 2,    // W: NVMe device ID
    NSID            = 3,    // W: namespace ID
    LBA             = 4,    // W: LBA (offset within allocated range)
    LEN             = 5,    // W: transfer size (bytes)
    VADDR           = 6,    // W: buffer virtual address
    WRITE_FLAG      = 7     // W: 1=write, 0=read
};

static void usage(const char *prog) {
    std::cout << "Usage: " << prog << " [options]\n"
              << "  -b, --bdf <BDF>       NVMe PCI BDF (e.g., 65:00.0)\n"
              << "  -s, --size <bytes>    Buffer size (default: 4096)\n"
              << "  -l, --lba <offset>    Starting LBA offset (default: 0)\n"
              << "  -p, --pattern <val>   32-bit test pattern (default: 0xDEADBEEF)\n"
              << "  -v, --vfpga <id>      vFPGA ID (default: 0)\n"
              << std::endl;
}

int main(int argc, char* argv[]) {
    std::string bdf = "65:00.0";
    uint64_t buf_size = 4096;
    uint64_t start_lba = 0;
    uint32_t pattern = 0xDEADBEEF;
    int vfpga_id = 0;

    static struct option long_opts[] = {
        {"bdf",     required_argument, 0, 'b'},
        {"size",    required_argument, 0, 's'},
        {"lba",     required_argument, 0, 'l'},
        {"pattern", required_argument, 0, 'p'},
        {"vfpga",   required_argument, 0, 'v'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "b:s:l:p:v:", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'b': bdf = optarg; break;
            case 's': buf_size = std::stoull(optarg); break;
            case 'l': start_lba = std::stoull(optarg); break;
            case 'p': pattern = std::stoul(optarg, nullptr, 16); break;
            case 'v': vfpga_id = std::stoi(optarg); break;
            default: usage(argv[0]); return 1;
        }
    }

    /* ======== Step 1: Init ======== */
    std::cout << "=== Step 1: Initialization ===" << std::endl;

    cThread ct(vfpga_id, getpid());
    std::cout << "cThread created (vfpga=" << vfpga_id << ")" << std::endl;

    NvmeDevice* dev = ct.initNVMe(bdf.c_str(), 1, buf_size);
    if (!dev) {
        std::cerr << "Failed to initialize NVMe" << std::endl;
        return 1;
    }

    uint32_t xfer_size = buf_size;
    if (dev->mdts > 0 && xfer_size > dev->mdts)
        xfer_size = dev->mdts;

    /* ======== Step 2: Allocate buffers ======== */
    std::cout << "\n=== Step 2: Allocate Buffers ===" << std::endl;

    void* write_buf = ct.getMem({CoyoteAllocType::HPF, static_cast<uint32_t>(buf_size)});
    void* read_buf  = ct.getMem({CoyoteAllocType::HPF, static_cast<uint32_t>(buf_size)});
    if (!write_buf || !read_buf) {
        std::cerr << "Failed to allocate buffers" << std::endl;
        ct.closeNVMe(dev);
        return 1;
    }

    /* Fill write buffer with pattern */
    uint64_t* wp = reinterpret_cast<uint64_t*>(write_buf);
    uint64_t num_qwords = buf_size / sizeof(uint64_t);
    uint64_t pat64 = ((uint64_t)pattern << 32);
    for (uint64_t i = 0; i < num_qwords; i++)
        wp[i] = pat64 | i;

    memset(read_buf, 0, buf_size);
    std::cout << "Buffers allocated: " << buf_size << " bytes" << std::endl;

    /* ======== Step 3: NVMe Write ======== */
    std::cout << "\n=== Step 3: NVMe Write ===" << std::endl;

    ct.setCSR(dev->dev_id,      Reg::DEV_ID);
    ct.setCSR(dev->nsid,        Reg::NSID);
    ct.setCSR(start_lba,        Reg::LBA);
    ct.setCSR(xfer_size,        Reg::LEN);
    ct.setCSR(reinterpret_cast<uint64_t>(write_buf), Reg::VADDR);
    ct.setCSR(1,                Reg::WRITE_FLAG);   // 1 = write
    ct.setCSR(1,                Reg::CTRL);          // bit0 = start

    while (ct.getCSR(Reg::STATUS) & 1) {}           // wait for done to clear
    while (!(ct.getCSR(Reg::STATUS) & 1)) {}        // poll bit0 = done
    uint16_t wr_err = (ct.getCSR(Reg::STATUS) >> 16) & 0xFFFF;
    std::cout << "Write complete" << (wr_err ? " (ERROR 0x" + std::to_string(wr_err) + ")" : "") << std::endl;

    /* ======== Step 4: NVMe Read ======== */
    std::cout << "\n=== Step 4: NVMe Read ===" << std::endl;

    ct.setCSR(dev->dev_id,      Reg::DEV_ID);
    ct.setCSR(dev->nsid,        Reg::NSID);
    ct.setCSR(start_lba,        Reg::LBA);
    ct.setCSR(xfer_size,        Reg::LEN);
    ct.setCSR(reinterpret_cast<uint64_t>(read_buf), Reg::VADDR);
    ct.setCSR(0,                Reg::WRITE_FLAG);   // 0 = read
    ct.setCSR(1,                Reg::CTRL);          // bit0 = start

    while (ct.getCSR(Reg::STATUS) & 1) {}           // wait for done to clear
    while (!(ct.getCSR(Reg::STATUS) & 1)) {}        // poll bit0 = done
    uint16_t rd_err = (ct.getCSR(Reg::STATUS) >> 16) & 0xFFFF;
    std::cout << "Read complete" << (rd_err ? " (ERROR 0x" + std::to_string(rd_err) + ")" : "") << std::endl;

    /* ======== Step 5: Verify ======== */
    std::cout << "\n=== Step 5: Verification ===" << std::endl;

    uint64_t* rp = reinterpret_cast<uint64_t*>(read_buf);
    uint64_t errors = 0;
    uint64_t first_err_idx = 0;
    uint64_t first_err_exp = 0, first_err_got = 0;

    for (uint64_t i = 0; i < num_qwords; i++) {
        uint64_t expected = pat64 | i;
        if (rp[i] != expected) {
            if (errors == 0) {
                first_err_idx = i;
                first_err_exp = expected;
                first_err_got = rp[i];
            }
            errors++;
        }
    }

    if (errors == 0) {
        std::cout << "PASSED: All " << num_qwords << " qwords match" << std::endl;
    } else {
        std::cout << "FAILED: " << errors << "/" << num_qwords << " qwords mismatch" << std::endl;
        std::cout << "  First error at [" << first_err_idx << "]: "
                  << "expected 0x" << std::hex << first_err_exp
                  << ", got 0x" << first_err_got << std::dec << std::endl;
    }

    /* ======== Cleanup ======== */
    std::cout << "\n=== Cleanup ===" << std::endl;
    ct.freeMem(write_buf);
    ct.freeMem(read_buf);
    ct.closeNVMe(dev);
    std::cout << "Done!" << std::endl;

    return (errors == 0) ? 0 : 1;
}
