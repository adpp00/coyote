/**
 * Example 14: NVMe SSD Bandwidth Test
 *
 * Measures read and write bandwidth for various chunk sizes.
 */

#include <iostream>
#include <iomanip>
#include <cstring>
#include <cstdint>
#include <string>
#include <getopt.h>

#include "cThread.hpp"

using namespace coyote;

/* User logic CSR registers (must match user_logic HW) */
enum Reg : uint32_t {
    CTRL            = 0,
    DONE            = 1,
    TIMER           = 2,
    VADDR           = 3,
    CHUNK_SIZE      = 4,
    N_REPS          = 5,
    LBA             = 6,
    DEV_ID          = 7,
    NSID            = 8,
    MAX_OUTSTANDING = 9,
    ERROR_REG       = 10
};

static constexpr uint64_t START_RD = 1;
static constexpr uint64_t START_WR = 2;

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
              << "  -t, --total <bytes>       Total transfer size (default: 64MB)\n"
              << "  -c, --chunk <bytes>       Chunk size per command (default: 4KB)\n"
              << "  -o, --outstanding <n>     Max outstanding commands (default: 16)\n"
              << "  -a, --alloc <bytes>       NVMe allocation size (default: total)\n"
              << "  -r, --read-only           Read-only test\n"
              << "  -w, --write-only          Write-only test\n"
              << "  -v, --vfpga <id>          vFPGA ID (default: 0)\n"
              << std::endl;
}

int main(int argc, char* argv[]) {
    std::string bdf = "65:00.0";
    uint64_t total_size = 64ULL * 1024 * 1024;  // 64MB
    uint64_t chunk_size = 4096;
    uint32_t max_outstanding = 16;
    uint64_t alloc_size = 0;
    bool do_read = true, do_write = true;
    int vfpga_id = 0;

    static struct option long_opts[] = {
        {"bdf",         required_argument, 0, 'b'},
        {"total",       required_argument, 0, 't'},
        {"chunk",       required_argument, 0, 'c'},
        {"outstanding", required_argument, 0, 'o'},
        {"alloc",       required_argument, 0, 'a'},
        {"read-only",   no_argument,       0, 'r'},
        {"write-only",  no_argument,       0, 'w'},
        {"vfpga",       required_argument, 0, 'v'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "b:t:c:o:a:rwv:", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'b': bdf = optarg; break;
            case 't': total_size = std::stoull(optarg); break;
            case 'c': chunk_size = std::stoull(optarg); break;
            case 'o': max_outstanding = std::stoul(optarg); break;
            case 'a': alloc_size = std::stoull(optarg); break;
            case 'r': do_read = true; do_write = false; break;
            case 'w': do_write = true; do_read = false; break;
            case 'v': vfpga_id = std::stoi(optarg); break;
            default: usage(argv[0]); return 1;
        }
    }

    if (alloc_size == 0)
        alloc_size = total_size;

    /* ======== Init ======== */
    std::cout << "=== NVMe Bandwidth Test ===" << std::endl;
    std::cout << "BDF: " << bdf << std::endl;
    std::cout << "Total: " << formatSize(total_size) << std::endl;
    std::cout << "Chunk: " << formatSize(chunk_size) << std::endl;
    std::cout << "Outstanding: " << max_outstanding << std::endl;

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
    uint32_t n_reps = total_size / chunk_size;

    /* Allocate buffer */
    void* buf = ct.getMem({CoyoteAllocType::HPF, static_cast<uint32_t>(total_size)});
    if (!buf) {
        std::cerr << "Failed to allocate buffer" << std::endl;
        ct.closeNVMe(dev);
        return 1;
    }
    memset(buf, 0xAB, total_size);

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
        double seconds = cycles / 250e6;  // 250 MHz assumed
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

    /* Cleanup */
    ct.freeMem(buf);
    ct.closeNVMe(dev);
    std::cout << "\nDone!" << std::endl;

    return 0;
}
