/**
 * Example 13: NVMe Functionality Test
 *
 * Basic NVMe read/write verification:
 * 1. Initialize NVMe SSD(s)
 * 2. Write test pattern to SSD
 * 3. Read back and verify
 *
 * Supports -m host (default) or -m fpga to use FPGA HBM as data buffer.
 */

#include <iostream>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <getopt.h>

#include "cThread.hpp"

using namespace coyote;

/* User logic CSR registers (must match nvme_axi_ctrl_parser HW) */
enum Reg : uint32_t {
    CTRL            = 0,    // W: bit0=start (auto-clears)
    STATUS          = 1,    // R: bit0=done, bits[31:16]=error
    DEV_ID          = 2,    // W: NVMe device ID
    NSID            = 3,    // W: namespace ID
    LBA             = 4,    // W: byte offset within allocated range (maps to naddr)
    LEN             = 5,    // W: transfer size (bytes)
    VADDR           = 6,    // W: buffer virtual address
    WRITE_FLAG      = 7     // W: 1=write, 0=read
};

static void usage(const char *prog) {
    std::cout << "Usage: " << prog << " [options]\n"
              << "  -b, --bdf <BDF>       NVMe PCI BDF (repeat for multi-device)\n"
              << "  -s, --size <bytes>    Buffer size (default: 4096)\n"
              << "  -l, --lba <offset>    Byte offset within allocated region (default: 0)\n"
              << "  -p, --pattern <val>   32-bit test pattern (default: 0xDEADBEEF)\n"
              << "  -m, --mem <host|fpga> Memory type (default: host)\n"
              << "  -v, --vfpga <id>      vFPGA ID (default: 0)\n"
              << std::endl;
}

int main(int argc, char* argv[]) {
    std::string bdf_default = "65:00.0";
    uint64_t buf_size = 4096;
    uint64_t byte_offset = 0;
    uint32_t pattern = 0xDEADBEEF;
    int vfpga_id = 0;
    bool use_fpga_mem = false;

    static struct option long_opts[] = {
        {"bdf",     required_argument, 0, 'b'},
        {"size",    required_argument, 0, 's'},
        {"lba",     required_argument, 0, 'l'},
        {"pattern", required_argument, 0, 'p'},
        {"mem",     required_argument, 0, 'm'},
        {"vfpga",   required_argument, 0, 'v'},
        {0, 0, 0, 0}
    };

    std::vector<std::string> bdfs;

    int opt;
    while ((opt = getopt_long(argc, argv, "b:s:l:p:m:v:", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'b': bdfs.push_back(optarg); break;
            case 's': buf_size = std::stoull(optarg); break;
            case 'l': byte_offset = std::stoull(optarg); break;
            case 'p': pattern = std::stoul(optarg, nullptr, 16); break;
            case 'm': use_fpga_mem = (std::string(optarg) == "fpga"); break;
            case 'v': vfpga_id = std::stoi(optarg); break;
            default: usage(argv[0]); return 1;
        }
    }
    if (bdfs.empty()) bdfs.push_back(bdf_default);

    /* ======== Step 1: Init ALL devices ======== */
    std::cout << "=== Step 1: Initialize all " << bdfs.size() << " devices ===" << std::endl;
    std::cout << "Memory mode: " << (use_fpga_mem ? "FPGA (HBM)" : "HOST") << std::endl;

    cThread ct(vfpga_id, getpid());

    std::vector<NvmeDevice*> devs;
    for (auto& b : bdfs) {
        NvmeDevice* d = ct.initNVMe(b.c_str(), 1, buf_size);
        if (!d) {
            std::cerr << "Failed to initialize NVMe: " << b << std::endl;
            for (auto* dd : devs) ct.closeNVMe(dd);
            return 1;
        }
        devs.push_back(d);
    }

    /* ======== Allocate buffers ======== */
    void* write_buf = ct.getMem({CoyoteAllocType::HPF, static_cast<uint32_t>(buf_size)});
    void* read_buf  = ct.getMem({CoyoteAllocType::HPF, static_cast<uint32_t>(buf_size)});
    if (!write_buf || !read_buf) {
        std::cerr << "Failed to allocate buffers" << std::endl;
        for (auto* d : devs) ct.closeNVMe(d);
        return 1;
    }

    /* FPGA memory: offload buffers to HBM */
    if (use_fpga_mem) {
        std::cout << "Offloading buffers to FPGA HBM..." << std::endl;
        ct.invoke(CoyoteOper::LOCAL_OFFLOAD, syncSg{write_buf, buf_size});
        ct.invoke(CoyoteOper::LOCAL_OFFLOAD, syncSg{read_buf, buf_size});
        std::cout << "Offload complete" << std::endl;
    }

    uint64_t num_qwords = buf_size / sizeof(uint64_t);
    uint64_t pat64 = ((uint64_t)pattern << 32);
    int total_errors = 0;

    /* ======== Test each device one at a time ======== */
    for (size_t di = 0; di < devs.size(); di++) {
        NvmeDevice* dev = devs[di];
        uint32_t xfer_size = buf_size;
        if (dev->mdts > 0 && xfer_size > dev->mdts)
            xfer_size = dev->mdts;

        std::cout << "\n========== Testing dev_id=" << dev->dev_id
                  << " BDF=" << bdfs[di] << " ==========" << std::endl;

        /* Fill write buffer (in host memory) */
        if (use_fpga_mem)
            ct.invoke(CoyoteOper::LOCAL_SYNC, syncSg{write_buf, buf_size});

        uint64_t* wp = reinterpret_cast<uint64_t*>(write_buf);
        for (uint64_t i = 0; i < num_qwords; i++)
            wp[i] = pat64 | (((uint64_t)dev->dev_id << 48) | i);
        memset(read_buf, 0, buf_size);

        if (use_fpga_mem) {
            ct.invoke(CoyoteOper::LOCAL_OFFLOAD, syncSg{write_buf, buf_size});
            ct.invoke(CoyoteOper::LOCAL_OFFLOAD, syncSg{read_buf, buf_size});
        }

        /* Write to SSD */
        ct.setCSR(dev->dev_id,      Reg::DEV_ID);
        ct.setCSR(dev->nsid,        Reg::NSID);
        ct.setCSR(byte_offset,      Reg::LBA);
        ct.setCSR(xfer_size,        Reg::LEN);
        ct.setCSR(reinterpret_cast<uint64_t>(write_buf), Reg::VADDR);
        ct.setCSR(1,                Reg::WRITE_FLAG);
        ct.setCSR(1,                Reg::CTRL);

        while (ct.getCSR(Reg::STATUS) & 1) {}
        while (!(ct.getCSR(Reg::STATUS) & 1)) {}
        uint16_t wr_err = (ct.getCSR(Reg::STATUS) >> 16) & 0xFFFF;

        /* Read from SSD */
        ct.setCSR(dev->dev_id,      Reg::DEV_ID);
        ct.setCSR(dev->nsid,        Reg::NSID);
        ct.setCSR(byte_offset,      Reg::LBA);
        ct.setCSR(xfer_size,        Reg::LEN);
        ct.setCSR(reinterpret_cast<uint64_t>(read_buf), Reg::VADDR);
        ct.setCSR(0,                Reg::WRITE_FLAG);
        ct.setCSR(1,                Reg::CTRL);

        while (ct.getCSR(Reg::STATUS) & 1) {}
        while (!(ct.getCSR(Reg::STATUS) & 1)) {}
        uint16_t rd_err = (ct.getCSR(Reg::STATUS) >> 16) & 0xFFFF;

        /* Sync read buffer back to host for verification */
        if (use_fpga_mem)
            ct.invoke(CoyoteOper::LOCAL_SYNC, syncSg{read_buf, buf_size});

        /* Verify */
        uint64_t* rp = reinterpret_cast<uint64_t*>(read_buf);
        uint64_t errors = 0;
        for (uint64_t i = 0; i < num_qwords; i++) {
            uint64_t expected = pat64 | (((uint64_t)dev->dev_id << 48) | i);
            if (rp[i] != expected) errors++;
        }

        std::cout << "  Write: " << (wr_err ? "ERR" : "OK")
                  << "  Read: " << (rd_err ? "ERR" : "OK")
                  << "  Verify: " << (errors == 0 ? "PASSED" : "FAILED")
                  << " (" << errors << "/" << num_qwords << " errors)" << std::endl;
        total_errors += errors;
    }

    /* ======== Cleanup ======== */
    std::cout << "\n=== Cleanup ===" << std::endl;
    ct.freeMem(write_buf);
    ct.freeMem(read_buf);
    for (auto* d : devs) ct.closeNVMe(d);
    std::cout << (total_errors == 0 ? "ALL PASSED" : "SOME FAILED") << std::endl;

    return (total_errors == 0) ? 0 : 1;
}
