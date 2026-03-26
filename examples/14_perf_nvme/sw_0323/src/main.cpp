/**
 * Example 14: NVMe SSD Bandwidth Test (single-device)
 *
 * For build_0323_3 bitstream (single-device HW, DEV_ID register).
 * CSR offset fix applied (SENT=1 included).
 */

#include <iostream>
#include <iomanip>
#include <cstring>
#include <cstdint>
#include <string>
#include <getopt.h>

#include "cThread.hpp"

using namespace coyote;

/* User logic CSR registers (must match perf_nvme_axi_ctrl_parser HW) */
enum Reg : uint32_t {
    CTRL            = 0,    // W1S: bit0=READ, bit1=WRITE
    SENT            = 1,    // RO: number of REQs sent
    DONE            = 2,    // RO: number of CPLs received
    TIMER           = 3,    // RO: clock cycles
    VADDR           = 4,    // WR: card memory base address
    CHUNK_SIZE      = 5,    // WR: bytes per NVMe command
    N_REPS          = 6,    // WR: number of commands
    LBA             = 7,    // WR: starting byte offset within allocated region
    DEV_ID          = 8,    // WR: NVMe device ID (single device)
    NSID            = 9,    // WR: namespace ID
    MAX_OUTSTANDING = 10,   // WR: max concurrent commands
    ERROR_REG       = 11    // RO: last error code
};

static constexpr uint64_t START_RD = 1;
static constexpr uint64_t START_WR = 2;

static uint64_t parseSize(const char *s) {
    char *end;
    uint64_t val = std::strtoull(s, &end, 0);
    switch (*end) {
        case 'K': case 'k': val *= 1024ULL; break;
        case 'M': case 'm': val *= 1024ULL * 1024; break;
        case 'G': case 'g': val *= 1024ULL * 1024 * 1024; break;
        default: break;
    }
    return val;
}

static std::string formatSize(uint64_t bytes) {
    if (bytes >= 1024ULL * 1024 * 1024)
        return std::to_string(bytes / (1024ULL * 1024 * 1024)) + " GB";
    if (bytes >= 1024ULL * 1024)
        return std::to_string(bytes / (1024ULL * 1024)) + " MB";
    if (bytes >= 1024ULL)
        return std::to_string(bytes / 1024ULL) + " KB";
    return std::to_string(bytes) + " B";
}

static void usage(const char *prog) {
    std::cout << "Usage: " << prog << " [options]\n"
              << "  -b, --bdf <BDF>           NVMe PCI BDF (e.g., 65:00.0)\n"
              << "  -t, --total <size>        Total transfer size (default: 64M)\n"
              << "  -c, --chunk <size>        Chunk size per command (default: 4K)\n"
              << "  -o, --outstanding <n>     Max outstanding commands (default: 16)\n"
              << "  -a, --alloc <size>        NVMe allocation size (default: total)\n"
              << "  -f, --fpga-mem            Use FPGA HBM instead of host memory\n"
              << "  -r, --read-only           Read-only test\n"
              << "  -w, --write-only          Write-only test\n"
              << "  -v, --vfpga <id>          vFPGA ID (default: 0)\n"
              << "\n  Sizes accept K/M/G suffixes (e.g., 128K, 64M, 1G)\n"
              << std::endl;
}

int main(int argc, char* argv[]) {
    std::string bdf = "65:00.0";
    uint64_t total_size = 64ULL * 1024 * 1024;
    uint64_t chunk_size = 4096;
    uint32_t max_outstanding = 16;
    uint64_t alloc_size = 0;
    bool do_read = true, do_write = true;
    bool use_fpga_mem = false;
    int vfpga_id = 0;

    static struct option long_opts[] = {
        {"bdf",         required_argument, 0, 'b'},
        {"total",       required_argument, 0, 't'},
        {"chunk",       required_argument, 0, 'c'},
        {"outstanding", required_argument, 0, 'o'},
        {"alloc",       required_argument, 0, 'a'},
        {"fpga-mem",    no_argument,       0, 'f'},
        {"read-only",   no_argument,       0, 'r'},
        {"write-only",  no_argument,       0, 'w'},
        {"vfpga",       required_argument, 0, 'v'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "b:t:c:o:a:frwv:", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'b': bdf = optarg; break;
            case 't': total_size = parseSize(optarg); break;
            case 'c': chunk_size = parseSize(optarg); break;
            case 'o': max_outstanding = std::stoul(optarg); break;
            case 'a': alloc_size = parseSize(optarg); break;
            case 'f': use_fpga_mem = true; break;
            case 'r': do_read = true; do_write = false; break;
            case 'w': do_write = true; do_read = false; break;
            case 'v': vfpga_id = std::stoi(optarg); break;
            default: usage(argv[0]); return 1;
        }
    }

    if (alloc_size == 0)
        alloc_size = total_size;

    /* ======== Init ======== */
    std::cout << "=== NVMe Bandwidth Test (single-device) ===" << std::endl;
    std::cout << "BDF: " << bdf << std::endl;
    std::cout << "Total: " << formatSize(total_size) << std::endl;
    std::cout << "Chunk: " << formatSize(chunk_size) << std::endl;
    std::cout << "Outstanding: " << max_outstanding << std::endl;
    std::cout << "Memory: " << (use_fpga_mem ? "FPGA HBM" : "Host DRAM") << std::endl;

    cThread ct(vfpga_id, getpid());

    NvmeDevice* dev = ct.initNVMe(bdf.c_str(), 1, alloc_size);
    if (!dev) {
        std::cerr << "Failed to initialize NVMe" << std::endl;
        return 1;
    }

    if (dev->mdts > 0 && chunk_size > dev->mdts) {
        std::cout << "Clamping chunk to MDTS: " << formatSize(dev->mdts) << std::endl;
        chunk_size = dev->mdts;
    }
    if (chunk_size < dev->lba_size) {
        std::cerr << "Error: chunk_size < lba_size (" << dev->lba_size << ")" << std::endl;
        ct.closeNVMe(dev);
        return 1;
    }
    if (chunk_size % dev->lba_size != 0) {
        std::cerr << "Error: chunk_size not aligned to lba_size (" << dev->lba_size << ")" << std::endl;
        ct.closeNVMe(dev);
        return 1;
    }
    if (max_outstanding >= 64) {
        std::cerr << "Error: max_outstanding must be < 64" << std::endl;
        ct.closeNVMe(dev);
        return 1;
    }

    uint32_t n_reps = total_size / chunk_size;

    /* Allocate buffer */
    void* buf = ct.getMem({CoyoteAllocType::HPF, static_cast<uint32_t>(total_size)});
    if (!buf) {
        std::cerr << "Failed to allocate buffer" << std::endl;
        ct.closeNVMe(dev);
        return 1;
    }
    memset(buf, 0xAB, total_size);

    syncSg hmem_sg = { .addr = buf, .len = total_size };

    if (use_fpga_mem) {
        /* Offload buffer to HBM — TLB now points to HBM physical addresses.
         * NVMe PRP entries will reference HBM, so SSD DMAs to/from HBM directly. */
        std::cout << "Offloading buffer to FPGA HBM..." << std::flush;
        ct.invoke(CoyoteOper::LOCAL_OFFLOAD, hmem_sg);
        std::cout << " done." << std::endl;
    }

    auto run_test = [&](const char *name, uint64_t ctrl_val) {
        ct.setCSR(reinterpret_cast<uint64_t>(buf), Reg::VADDR);
        ct.setCSR(chunk_size,       Reg::CHUNK_SIZE);
        ct.setCSR(n_reps,           Reg::N_REPS);
        ct.setCSR(0,                Reg::LBA);
        ct.setCSR(dev->dev_id,      Reg::DEV_ID);
        ct.setCSR(dev->nsid,        Reg::NSID);
        ct.setCSR(max_outstanding,  Reg::MAX_OUTSTANDING);
        ct.setCSR(ctrl_val,         Reg::CTRL);

        while (ct.getCSR(Reg::DONE) < n_reps) {}

        uint64_t cycles = ct.getCSR(Reg::TIMER);
        double seconds = cycles / 250e6;
        double bw_gbps = (total_size / seconds) / (1024.0 * 1024 * 1024);

        std::cout << std::setw(8) << name
                  << " | chunk=" << std::setw(8) << formatSize(chunk_size)
                  << " | total=" << std::setw(8) << formatSize(total_size)
                  << " | " << std::fixed << std::setprecision(2) << bw_gbps << " GB/s"
                  << " | " << cycles << " cycles"
                  << std::endl;
    };

    std::cout << "\n=== Results ===" << std::endl;

    if (do_write) run_test("WRITE", START_WR);
    if (do_read)  run_test("READ",  START_RD);

    /* Sync back from HBM if needed (e.g., to verify read data on host) */
    if (use_fpga_mem) {
        std::cout << "Syncing buffer back from FPGA HBM..." << std::flush;
        ct.invoke(CoyoteOper::LOCAL_SYNC, hmem_sg);
        std::cout << " done." << std::endl;
    }

    /* Cleanup */
    ct.freeMem(buf);
    ct.closeNVMe(dev);
    std::cout << "\nDone!" << std::endl;

    return 0;
}
