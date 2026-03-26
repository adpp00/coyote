/**
 * Example 16 — Read: NVMe -> TCP Sequential Read (FPGA-side host)
 *
 * This program:
 *   1. Initializes NVMe device 0
 *   2. Allocates card memory buffer (default 2MB)
 *   3. Configures FPGA to listen on TCP port
 *   4. Polls for progress as client requests data
 *
 * TCP client (separate machine) sends:
 *   [64B meta] with meta[63:0] = total_read_length (bytes)
 *
 * FPGA reads NVMe dev 0 sequentially and streams data over TCP.
 * Data is sent in 32KB TCP packets (split from 1MB NVMe read blocks).
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

/* Register map (must match nvme_tcp_read_ctrl HW) */
enum Reg : uint32_t {
    CTRL        = 0,
    STATUS      = 1,
    LISTEN_PORT = 2,
    MEM_BASE    = 3,
    NSID        = 4,
    CHUNK_SIZE  = 5,
    TIMER       = 6,
    NVME_SENT   = 7,
    NVME_DONE   = 8,
    LAST_ERROR  = 9,
    BYTES_SENT  = 10,
    NVME_LBA    = 11
};

static constexpr uint64_t START = 1;
static volatile bool running = true;

static void sighandler(int) { running = false; }

static void usage(const char *prog) {
    std::cout << "Usage: " << prog << " [options]\n"
              << "  -b, --bdf <BDF>       NVMe BDF (e.g., 65:00.0)\n"
              << "  -p, --port <port>     TCP listen port (default: 5002)\n"
              << "  -c, --chunk <bytes>   NVMe chunk size (default: 4096)\n"
              << "  -a, --alloc <bytes>   NVMe allocation size (default: 128M)\n"
              << "  -m, --membuf <bytes>  Card memory buffer (default: 2M)\n"
              << "  -v, --vfpga <id>      vFPGA ID (default: 0)\n"
              << std::endl;
}

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

int main(int argc, char* argv[]) {
    std::string bdf = "65:00.0";
    uint16_t tcp_port = 5002;
    uint32_t chunk_size = 4096;
    uint64_t alloc_size = 128ULL * 1024 * 1024;
    uint64_t mem_size = 2ULL * 1024 * 1024;
    int vfpga_id = 0;

    static struct option long_opts[] = {
        {"bdf",   required_argument, 0, 'b'},
        {"port",  required_argument, 0, 'p'},
        {"chunk", required_argument, 0, 'c'},
        {"alloc", required_argument, 0, 'a'},
        {"membuf",required_argument, 0, 'm'},
        {"vfpga", required_argument, 0, 'v'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "b:p:c:a:m:v:", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'b': bdf = optarg; break;
            case 'p': tcp_port = std::stoi(optarg); break;
            case 'c': chunk_size = parseSize(optarg); break;
            case 'a': alloc_size = parseSize(optarg); break;
            case 'm': mem_size = parseSize(optarg); break;
            case 'v': vfpga_id = std::stoi(optarg); break;
            default: usage(argv[0]); return 1;
        }
    }

    std::cout << "=== NVMe -> TCP Sequential Read ===" << std::endl;
    std::cout << "BDF:         " << bdf << std::endl;
    std::cout << "TCP port:    " << tcp_port << std::endl;
    std::cout << "Chunk size:  " << chunk_size << " bytes" << std::endl;
    std::cout << "NVMe alloc:  " << (alloc_size / 1024 / 1024) << " MB" << std::endl;
    std::cout << "Card buffer: " << (mem_size / 1024 / 1024) << " MB" << std::endl;

    signal(SIGINT, sighandler);

    /* Init */
    cThread ct(vfpga_id, getpid());

    /* Initialize NVMe device 0 */
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
    }

    /* Allocate host buffer and offload to FPGA HBM */
    void* card_buf = ct.getMem({CoyoteAllocType::HPF, static_cast<uint32_t>(mem_size)});
    if (!card_buf) {
        std::cerr << "Failed to allocate buffer" << std::endl;
        ct.closeNVMe(dev);
        return 1;
    }
    memset(card_buf, 0, mem_size);
    ct.invoke(CoyoteOper::LOCAL_OFFLOAD, syncSg{card_buf, mem_size});
    std::cout << "Card buffer: " << card_buf << " (offloaded to HBM)" << std::endl;

    /* Configure FPGA */
    ct.setCSR(reinterpret_cast<uint64_t>(card_buf), Reg::MEM_BASE);
    ct.setCSR(tcp_port,                              Reg::LISTEN_PORT);
    ct.setCSR(dev->nsid,                             Reg::NSID);
    ct.setCSR(chunk_size,                            Reg::CHUNK_SIZE);

    /* Start listening */
    ct.setCSR(START, Reg::CTRL);

    /* Verify listen */
    for (int i = 0; i < 100; i++) {
        usleep(10000);
        uint64_t status = ct.getCSR(Reg::STATUS);
        if (status & (1 << 8)) {
            std::cout << "TCP listen OK on port " << tcp_port << std::endl;
            break;
        }
        if (i == 99) {
            std::cerr << "TCP listen failed (timeout)" << std::endl;
            ct.freeMem(card_buf);
            ct.closeNVMe(dev);
            return 1;
        }
    }

    std::cout << "\nWaiting for client requests (Ctrl+C to stop)..." << std::endl;
    std::cout << std::string(60, '-') << std::endl;

    /* Poll loop */
    uint64_t prev_sent = 0;

    while (running) {
        uint64_t lba_off = ct.getCSR(Reg::NVME_LBA);
        uint64_t sent    = ct.getCSR(Reg::BYTES_SENT);
        uint32_t nsent   = ct.getCSR(Reg::NVME_SENT);
        uint32_t ndone   = ct.getCSR(Reg::NVME_DONE);
        uint64_t status  = ct.getCSR(Reg::STATUS);
        uint16_t error   = ct.getCSR(Reg::LAST_ERROR);
        uint64_t cycles  = ct.getCSR(Reg::TIMER);

        if (sent > prev_sent) {
            double seconds = cycles / 250e6;
            double bw = (sent > 0 && seconds > 0)
                        ? (sent / seconds) / (1024.0 * 1024 * 1024) : 0.0;

            std::cout << "\rSent: " << std::setw(10) << (sent / 1024) << " KB"
                      << " | NVMe LBA: " << std::setw(7) << (lba_off / 1024 / 1024) << " MB"
                      << " | " << std::fixed << std::setprecision(2) << bw << " GB/s"
                      << std::flush;

            if (error)
                std::cout << " | ERR=0x" << std::hex << error << std::dec;

            prev_sent = sent;
        }

        uint32_t fsm = status & 0x1F;
        if (fsm == 15 && prev_sent > 0) {  // ST_DONE
            std::cout << "\n\nTransfer complete!" << std::endl;
            std::cout << "Total sent: " << (prev_sent / 1024 / 1024) << " MB" << std::endl;
            prev_sent = 0;
        }

        usleep(1000);
    }

    /* Cleanup */
    std::cout << "\nShutting down..." << std::endl;
    ct.freeMem(card_buf);
    ct.closeNVMe(dev);
    std::cout << "Done!" << std::endl;

    return 0;
}
