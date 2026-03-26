/**
 * Example 16 — Pipelined Read: NVMe → TCP (FPGA-side host)
 */

#include <iostream>
#include <iomanip>
#include <cstring>
#include <cstdint>
#include <string>
#include <getopt.h>
#include <csignal>

#include "cThread.hpp"

using namespace coyote;

enum Reg : uint32_t {
    CTRL        = 0,
    STATUS      = 1,
    LISTEN_PORT = 2,
    HBM_BASE    = 3,
    CHUNK_BITS  = 4,
    SLOT_MASK   = 5,
    NSID        = 6,
    TIMER       = 7,
    NVME_SENT   = 8,
    NVME_DONE   = 9,
    LAST_ERROR  = 10,
    BYTES_SENT  = 11,
    WR_PTR      = 12,
    RD_PTR      = 13
};

static constexpr uint64_t START = 1;
static volatile bool running = true;
static void sighandler(int) { running = false; }

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

static void usage(const char *prog) {
    std::cout << "Usage: " << prog << " [options]\n"
              << "  -b, --bdf <BDF>       NVMe BDF (e.g., 65:00.0)\n"
              << "  -p, --port <port>     TCP listen port (default: 5002)\n"
              << "  -c, --chunk <bytes>   Chunk/slot size (default: 128K)\n"
              << "  -r, --ring <bytes>    Ring buffer size (default: 128M)\n"
              << "  -a, --alloc <bytes>   NVMe allocation size (default: 128M)\n"
              << "  -v, --vfpga <id>      vFPGA ID (default: 0)\n"
              << std::endl;
}

int main(int argc, char* argv[]) {
    std::string bdf = "65:00.0";
    uint16_t tcp_port = 5002;
    uint32_t chunk_size = 128 * 1024;
    uint64_t ring_size = 128ULL * 1024 * 1024;
    uint64_t alloc_size = 128ULL * 1024 * 1024;
    int vfpga_id = 0;

    static struct option long_opts[] = {
        {"bdf",   required_argument, 0, 'b'},
        {"port",  required_argument, 0, 'p'},
        {"chunk", required_argument, 0, 'c'},
        {"ring",  required_argument, 0, 'r'},
        {"alloc", required_argument, 0, 'a'},
        {"vfpga", required_argument, 0, 'v'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "b:p:c:r:a:v:", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'b': bdf = optarg; break;
            case 'p': tcp_port = std::stoi(optarg); break;
            case 'c': chunk_size = parseSize(optarg); break;
            case 'r': ring_size = parseSize(optarg); break;
            case 'a': alloc_size = parseSize(optarg); break;
            case 'v': vfpga_id = std::stoi(optarg); break;
            default: usage(argv[0]); return 1;
        }
    }

    uint32_t n_slots = ring_size / chunk_size;

    std::cout << "=== NVMe TCP Pipelined Read ===" << std::endl;
    std::cout << "BDF:         " << bdf << std::endl;
    std::cout << "TCP port:    " << tcp_port << std::endl;
    std::cout << "Chunk size:  " << (chunk_size / 1024) << " KB" << std::endl;
    std::cout << "Ring buffer: " << (ring_size / 1024 / 1024) << " MB (" << n_slots << " slots)" << std::endl;

    signal(SIGINT, sighandler);

    cThread ct(vfpga_id, getpid());

    NvmeDevice* dev = ct.initNVMe(bdf.c_str(), 1, alloc_size);
    if (!dev) {
        std::cerr << "Failed to init NVMe: " << bdf << std::endl;
        return 1;
    }
    std::cout << "NVMe dev_id=" << dev->dev_id
              << "  NSID=" << dev->nsid
              << "  MDTS=" << dev->mdts << std::endl;

    if (dev->mdts > 0 && chunk_size > dev->mdts) {
        std::cout << "Clamping chunk to MDTS: " << dev->mdts << std::endl;
        chunk_size = dev->mdts;
        n_slots = ring_size / chunk_size;
    }

    void* ring_buf = ct.getMem({CoyoteAllocType::HPF, static_cast<uint32_t>(ring_size)});
    if (!ring_buf) {
        std::cerr << "Failed to allocate ring buffer" << std::endl;
        ct.closeNVMe(dev);
        return 1;
    }
    memset(ring_buf, 0, ring_size);
    ct.invoke(CoyoteOper::LOCAL_OFFLOAD, syncSg{ring_buf, ring_size});
    std::cout << "Ring buffer: " << ring_buf << " (offloaded to HBM)" << std::endl;

    if (chunk_size == 0 || (chunk_size & (chunk_size - 1)) != 0) {
        std::cerr << "chunk_size must be a power of 2" << std::endl;
        ct.freeMem(ring_buf); ct.closeNVMe(dev); return 1;
    }

    ct.setCSR(reinterpret_cast<uint64_t>(ring_buf), Reg::HBM_BASE);
    ct.setCSR(__builtin_ctz(chunk_size),             Reg::CHUNK_BITS);
    ct.setCSR(n_slots - 1,                           Reg::SLOT_MASK);
    ct.setCSR(tcp_port,                              Reg::LISTEN_PORT);
    ct.setCSR(dev->nsid,                             Reg::NSID);

    ct.setCSR(START, Reg::CTRL);

    for (int i = 0; i < 100; i++) {
        usleep(10000);
        uint64_t status = ct.getCSR(Reg::STATUS);
        if (status & (1 << 8)) {
            std::cout << "TCP listen OK on port " << tcp_port << std::endl;
            break;
        }
        if (i == 99) {
            std::cerr << "TCP listen failed (timeout)" << std::endl;
            ct.freeMem(ring_buf);
            ct.closeNVMe(dev);
            return 1;
        }
    }

    std::cout << "\nWaiting for client requests (Ctrl+C to stop)..." << std::endl;
    std::cout << std::string(70, '-') << std::endl;

    uint64_t prev_sent = 0;

    while (running) {
        uint32_t wp    = ct.getCSR(Reg::WR_PTR);
        uint32_t rp_rd = ct.getCSR(Reg::RD_PTR);
        uint32_t sent  = ct.getCSR(Reg::NVME_SENT);
        uint32_t done  = ct.getCSR(Reg::NVME_DONE);
        uint64_t bytes = ct.getCSR(Reg::BYTES_SENT);
        uint16_t error = ct.getCSR(Reg::LAST_ERROR);
        uint64_t cycles = ct.getCSR(Reg::TIMER);

        if (bytes > prev_sent) {
            double seconds = cycles / 250e6;
            double bw = (bytes > 0 && seconds > 0)
                        ? (bytes / seconds) / (1024.0 * 1024 * 1024) : 0.0;

            std::cout << "\rwp=" << std::setw(5) << wp
                      << " rp=" << std::setw(5) << rp_rd
                      << " | nvme " << sent << "/" << done
                      << " | " << std::setw(7) << (bytes / 1024 / 1024) << " MB"
                      << " | " << std::fixed << std::setprecision(2) << bw << " GB/s";
            if (error)
                std::cout << " | ERR=0x" << std::hex << error << std::dec;
            std::cout << std::flush;

            prev_sent = bytes;
        }

        usleep(1000);
    }

    std::cout << "\nShutting down..." << std::endl;
    ct.freeMem(ring_buf);
    ct.closeNVMe(dev);
    std::cout << "Done!" << std::endl;

    return 0;
}
