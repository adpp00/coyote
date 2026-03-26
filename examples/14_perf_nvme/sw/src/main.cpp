/**
 * Example 14: NVMe SSD Bandwidth Test (multi-device)
 *
 * Measures read and write bandwidth across one or more NVMe SSDs.
 * Multiple -b flags test multiple devices concurrently.
 *
 * Usage:
 *   bin/test -b 86:00.0                       # single SSD
 *   bin/test -b 86:00.0 -b 87:00.0 -c 128K   # 2 SSDs, 128KB chunks
 */

#include <iostream>
#include <iomanip>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <getopt.h>

#include "cThread.hpp"

using namespace coyote;

/* User logic CSR registers (must match perf_nvme_axi_ctrl_parser HW) */
enum Reg : uint32_t {
    CTRL            = 0,    // W1S: bit0=READ, bit1=WRITE
    SENT            = 1,    // RO: total REQs sent (all devices)
    DONE            = 2,    // RO: total CPLs received (all devices)
    TIMER           = 3,    // RO: clock cycles
    VADDR           = 4,    // WR: card memory base address (shared)
    CHUNK_SIZE      = 5,    // WR: bytes per NVMe command (shared)
    N_REPS          = 6,    // WR: number of commands PER DEVICE
    LBA             = 7,    // WR: starting byte offset (shared)
    DEV_MASK        = 8,    // WR: bitmask of active devices
    NSID            = 9,    // WR: namespace ID (shared)
    MAX_OUTSTANDING = 10,   // WR: max concurrent commands PER DEVICE
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
              << "  -b, --bdf <BDF>           NVMe PCI BDF (repeat for multi-device)\n"
              << "  -t, --total <size>        Total transfer per device (default: 64M)\n"
              << "  -c, --chunk <size>        Chunk size per command (default: 4K)\n"
              << "  -o, --outstanding <n>     Max outstanding per device (default: 16)\n"
              << "  -a, --alloc <size>        NVMe allocation per device (default: total)\n"
              << "  -m, --mem <host|fpga>     Buffer location (default: host)\n"
              << "  -r, --read-only           Read-only test\n"
              << "  -w, --write-only          Write-only test\n"
              << "  -V, --verify              Data integrity check (write→clear→read→compare)\n"
              << "  -v, --vfpga <id>          vFPGA ID (default: 0)\n"
              << "\n  Sizes accept K/M/G suffixes (e.g., 128K, 64M, 1G)\n"
              << std::endl;
}

int main(int argc, char* argv[]) {
    std::vector<std::string> bdfs;
    uint64_t total_size = 64ULL * 1024 * 1024;  // 64MB per device
    uint64_t chunk_size = 4096;
    uint32_t max_outstanding = 16;
    uint64_t alloc_size = 0;
    bool do_read = true, do_write = true;
    bool do_verify = false;
    int vfpga_id = 0;
    bool use_fpga_mem = false;

    static struct option long_opts[] = {
        {"bdf",         required_argument, 0, 'b'},
        {"total",       required_argument, 0, 't'},
        {"chunk",       required_argument, 0, 'c'},
        {"outstanding", required_argument, 0, 'o'},
        {"alloc",       required_argument, 0, 'a'},
        {"read-only",   no_argument,       0, 'r'},
        {"write-only",  no_argument,       0, 'w'},
        {"verify",      no_argument,       0, 'V'},
        {"mem",         required_argument, 0, 'm'},
        {"vfpga",       required_argument, 0, 'v'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "b:t:c:o:a:rwVm:v:", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'b': bdfs.push_back(optarg); break;
            case 't': total_size = parseSize(optarg); break;
            case 'c': chunk_size = parseSize(optarg); break;
            case 'o': max_outstanding = std::stoul(optarg); break;
            case 'a': alloc_size = parseSize(optarg); break;
            case 'r': do_read = true; do_write = false; break;
            case 'w': do_write = true; do_read = false; break;
            case 'V': do_verify = true; break;
            case 'm': {
                std::string arg(optarg);
                if (arg == "fpga" || arg == "card" || arg == "hbm")
                    use_fpga_mem = true;
                else if (arg == "host")
                    use_fpga_mem = false;
                else {
                    std::cerr << "Error: -m must be 'host' or 'fpga'" << std::endl;
                    return 1;
                }
                break;
            }
            case 'v': vfpga_id = std::stoi(optarg); break;
            default: usage(argv[0]); return 1;
        }
    }

    if (bdfs.empty()) {
        std::cerr << "Error: at least one -b <BDF> required" << std::endl;
        usage(argv[0]);
        return 1;
    }

    if (alloc_size == 0)
        alloc_size = total_size;

    /* ======== Init ======== */
    std::cout << "=== NVMe Bandwidth Test ===" << std::endl;
    std::cout << "Devices:     " << bdfs.size() << std::endl;
    std::cout << "Total/dev:   " << formatSize(total_size) << std::endl;
    std::cout << "Chunk:       " << formatSize(chunk_size) << std::endl;
    std::cout << "Outstanding: " << max_outstanding << " per device" << std::endl;
    std::cout << "Memory:      " << (use_fpga_mem ? "FPGA (HBM)" : "HOST") << std::endl;

    cThread ct(vfpga_id, getpid());

    /* Initialize all NVMe devices */
    std::vector<NvmeDevice*> devs;
    uint16_t dev_mask = 0;

    for (auto& bdf : bdfs) {
        NvmeDevice* dev = ct.initNVMe(bdf.c_str(), 1, alloc_size);
        if (!dev) {
            std::cerr << "Failed to initialize NVMe: " << bdf << std::endl;
            for (auto* d : devs) ct.closeNVMe(d);
            return 1;
        }
        devs.push_back(dev);
        dev_mask |= (1 << dev->dev_id);
        std::cout << "  dev_id=" << dev->dev_id << "  BDF=" << bdf << std::endl;
    }

    std::cout << "DEV_MASK:    0x" << std::hex << dev_mask << std::dec << std::endl;

    /* Validate max_outstanding against HW SQ depth */
    if (max_outstanding >= 64) {
        std::cerr << "Error: max_outstanding (" << max_outstanding
                  << ") must be < 64 (HW SQ depth)" << std::endl;
        for (auto* d : devs) ct.closeNVMe(d);
        return 1;
    }

    /* Clamp chunk to smallest MDTS, validate against LBA size */
    for (auto* dev : devs) {
        if (dev->mdts > 0 && chunk_size > dev->mdts) {
            std::cout << "Clamping chunk to MDTS(" << dev->dev_id << "): "
                      << formatSize(dev->mdts) << std::endl;
            chunk_size = dev->mdts;
        }
        if (chunk_size < dev->lba_size) {
            std::cerr << "Error: chunk_size (" << chunk_size
                      << ") < lba_size (" << dev->lba_size << ") for dev "
                      << dev->dev_id << std::endl;
            for (auto* d : devs) ct.closeNVMe(d);
            return 1;
        }
        if (chunk_size % dev->lba_size != 0) {
            std::cerr << "Error: chunk_size (" << chunk_size
                      << ") not aligned to lba_size (" << dev->lba_size
                      << ") for dev " << dev->dev_id << std::endl;
            for (auto* d : devs) ct.closeNVMe(d);
            return 1;
        }
    }

    uint32_t n_reps = total_size / chunk_size;   // per device
    uint32_t total_n_reps = n_reps * devs.size();

    /* Allocate buffer */
    void* buf = ct.getMem({CoyoteAllocType::HPF, static_cast<uint32_t>(total_size)});
    if (!buf) {
        std::cerr << "Failed to allocate buffer" << std::endl;
        for (auto* d : devs) ct.closeNVMe(d);
        return 1;
    }
    memset(buf, 0xAB, total_size);

    /* FPGA memory: offload buffer to HBM */
    if (use_fpga_mem) {
        std::cout << "Offloading buffer to FPGA HBM..." << std::endl;
        ct.invoke(CoyoteOper::LOCAL_OFFLOAD, syncSg{buf, total_size});
        std::cout << "Offload complete" << std::endl;
    }

    auto run_test = [&](const char *name, uint64_t ctrl_val,
                        uint16_t mask, uint32_t n_devs, uint32_t expected) {
        ct.setCSR(reinterpret_cast<uint64_t>(buf), Reg::VADDR);
        ct.setCSR(chunk_size,       Reg::CHUNK_SIZE);
        ct.setCSR(n_reps,           Reg::N_REPS);
        ct.setCSR(0,                Reg::LBA);
        ct.setCSR(mask,             Reg::DEV_MASK);
        ct.setCSR(1,                Reg::NSID);
        ct.setCSR(max_outstanding,  Reg::MAX_OUTSTANDING);
        ct.setCSR(ctrl_val,         Reg::CTRL);

        uint32_t poll_count = 0;
        while (ct.getCSR(Reg::DONE) < expected) {
            if (++poll_count % 10000000 == 0) {
                uint32_t sent = ct.getCSR(Reg::SENT);
                uint32_t done = ct.getCSR(Reg::DONE);
                uint16_t err  = ct.getCSR(Reg::ERROR_REG) & 0xFFFF;
                std::cout << "  [poll] SENT=" << sent
                          << " DONE=" << done
                          << " ERR=0x" << std::hex << err << std::dec
                          << " (need " << expected << ")" << std::endl;
                if (poll_count > 100000000) {
                    std::cout << "  TIMEOUT — aborting this test" << std::endl;
                    return;
                }
            }
        }

        uint64_t cycles = ct.getCSR(Reg::TIMER);
        double seconds = cycles / 250e6;
        uint64_t total_bytes = (uint64_t)total_size * n_devs;
        double agg_bw = (total_bytes / seconds) / (1024.0 * 1024 * 1024);

        std::cout << std::setw(8) << name
                  << " | chunk=" << std::setw(8) << formatSize(chunk_size)
                  << " | mask=0x" << std::hex << mask << std::dec
                  << " | " << std::fixed << std::setprecision(2) << agg_bw << " GB/s"
                  << " | " << cycles << " cycles"
                  << std::endl;
    };

    std::cout << "\n=== Per-device tests (one at a time) ===" << std::endl;
    for (auto* dev : devs) {
        uint16_t single_mask = 1 << dev->dev_id;
        std::cout << "\n--- dev_id=" << dev->dev_id << " (mask=0x"
                  << std::hex << single_mask << std::dec << ") ---" << std::endl;
        if (do_write) run_test("WRITE", START_WR, single_mask, 1, n_reps);
        if (do_read)  run_test("READ",  START_RD, single_mask, 1, n_reps);
    }

    std::cout << "\n=== All devices together ===" << std::endl;
    if (do_write) run_test("WRITE", START_WR, dev_mask, devs.size(), total_n_reps);
    if (do_read)  run_test("READ",  START_RD, dev_mask, devs.size(), total_n_reps);

    /* ======== Data Integrity Verification ======== */
    if (do_verify) {
        std::cout << "\n=== Data Integrity Verification ===" << std::endl;
        uint8_t* host_buf = reinterpret_cast<uint8_t*>(buf);

        // Step 1: Fill with known pattern and offload
        std::cout << "1. Fill buffer with pattern..." << std::flush;
        for (uint64_t i = 0; i < total_size; i++)
            host_buf[i] = (uint8_t)(i & 0xFF);
        if (use_fpga_mem)
            ct.invoke(CoyoteOper::LOCAL_OFFLOAD, syncSg{buf, total_size});
        std::cout << " OK" << std::endl;

        // Step 2: NVMe WRITE (buffer → SSD)
        std::cout << "2. NVMe WRITE to SSD..." << std::flush;
        run_test("VERIFY-WR", START_WR, dev_mask, devs.size(), total_n_reps);

        // Step 3: Clear buffer and offload zeros
        std::cout << "3. Clear buffer..." << std::flush;
        memset(host_buf, 0x00, total_size);
        if (use_fpga_mem)
            ct.invoke(CoyoteOper::LOCAL_OFFLOAD, syncSg{buf, total_size});
        std::cout << " OK" << std::endl;

        // Step 4: NVMe READ (SSD → buffer)
        std::cout << "4. NVMe READ from SSD..." << std::flush;
        run_test("VERIFY-RD", START_RD, dev_mask, devs.size(), total_n_reps);

        // Step 5: Sync back from HBM to host
        if (use_fpga_mem) {
            std::cout << "5. Sync HBM → host..." << std::flush;
            ct.invoke(CoyoteOper::LOCAL_SYNC, syncSg{buf, total_size});
            std::cout << " OK" << std::endl;
        }

        // Step 6: Compare
        std::cout << "6. Comparing data..." << std::endl;
        uint64_t errors = 0;
        uint64_t first_err_off = UINT64_MAX;
        for (uint64_t i = 0; i < total_size; i++) {
            uint8_t expected = (uint8_t)(i & 0xFF);
            if (host_buf[i] != expected) {
                if (errors < 16) {
                    std::cout << "   MISMATCH @ 0x" << std::hex << i
                              << ": got=0x" << (int)host_buf[i]
                              << " expected=0x" << (int)expected
                              << std::dec << std::endl;
                }
                if (first_err_off == UINT64_MAX) first_err_off = i;
                errors++;
            }
        }

        if (errors == 0) {
            std::cout << "   PASS — " << (total_size / 1024 / 1024) << " MB verified OK"
                      << std::endl;
        } else {
            std::cout << "   FAIL — " << errors << " byte mismatches / "
                      << total_size << " bytes"
                      << " (first @ offset 0x" << std::hex << first_err_off << std::dec
                      << ")" << std::endl;

            // Show chunk boundary analysis
            if (first_err_off != UINT64_MAX) {
                uint64_t err_chunk = first_err_off / chunk_size;
                uint64_t err_page  = first_err_off / 4096;
                std::cout << "   First error: chunk #" << err_chunk
                          << " (offset " << (first_err_off % chunk_size)
                          << " within chunk)"
                          << ", page #" << err_page << std::endl;

                // Check if errors start at PRP list boundary (>8KB = page 2+)
                if (first_err_off % chunk_size >= 8192)
                    std::cout << "   ** Error starts at PRP list region (>8KB into chunk) — likely PRP issue **"
                              << std::endl;
                else if (first_err_off % chunk_size >= 4096)
                    std::cout << "   ** Error starts at PRP2 region (4-8KB into chunk) **"
                              << std::endl;
            }
        }
    }

    /* Cleanup */
    ct.freeMem(buf);
    for (auto* d : devs) ct.closeNVMe(d);
    std::cout << "\nDone!" << std::endl;

    return 0;
}
