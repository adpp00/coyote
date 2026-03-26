/**
 * Example 16 — Store: TCP -> NVMe Sequential Write (FPGA-side host)
 *
 * This program:
 *   1. Initializes NVMe device 0
 *   2. Allocates card memory buffer (default 2MB — one working block + margin)
 *   3. Configures FPGA to listen on TCP port
 *   4. Polls for progress as TCP client sends data -> NVMe
 *
 * TCP client (separate machine) sends:
 *   [64B meta header] [data...]
 *   meta[63:0] = total_data_length (bytes)
 *
 * FPGA stores data sequentially to SSD dev 0, starting at byte offset 0.
 * Sends 64B TCP completion after every 1MB written to NVMe.
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

/* Register map (must match nvme_tcp_store_ctrl HW) */
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
    BYTES_RECV  = 10,
    NVME_LBA    = 11
};

static constexpr uint64_t START = 1;
static volatile bool running = true;

static void sighandler(int) { running = false; }

static void usage(const char *prog) {
    std::cout << "Usage: " << prog << " [options]\n"
              << "  -b, --bdf <BDF>       NVMe BDF (e.g., 65:00.0)\n"
              << "  -p, --port <port>     TCP listen port (default: 5001)\n"
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
    uint16_t tcp_port = 5001;
    uint32_t chunk_size = 4096;
    uint64_t alloc_size = 128ULL * 1024 * 1024;  // 128MB NVMe allocation
    uint64_t mem_size = 2ULL * 1024 * 1024;       // 2MB card memory buffer
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

    std::cout << "=== TCP -> NVMe Sequential Store ===" << std::endl;
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

    /* Clamp chunk to MDTS if needed */
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

    /* Verify listen succeeded */
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

    std::cout << "\nWaiting for TCP transfers (Ctrl+C to stop)..." << std::endl;
    std::cout << std::string(60, '-') << std::endl;

    /* Poll loop */
    uint64_t prev_lba = 0;
    uint32_t block_count = 0;
    uint32_t prev_fsm = 99;
    uint64_t prev_bytes = 0;
    int stall_count = 0;

    static const char* fsm_names[] = {
        "IDLE", "LISTEN", "WAIT_NOTIFY", "SEND_RD_PKG",
        "WAIT_RX_META", "RECV_FIRST", "SUBMIT_DESC", "RECV_DATA",
        "WAIT_MEM", "CHECK_BLOCK", "NVME_ISSUE", "NVME_DRAIN",
        "CPL_META", "CPL_DATA", "CPL_WAIT", "DONE"
    };

    while (running) {
        uint64_t lba_off    = ct.getCSR(Reg::NVME_LBA);
        uint64_t bytes      = ct.getCSR(Reg::BYTES_RECV);
        uint32_t sent       = ct.getCSR(Reg::NVME_SENT);
        uint32_t done       = ct.getCSR(Reg::NVME_DONE);
        uint64_t status     = ct.getCSR(Reg::STATUS);
        uint16_t error      = ct.getCSR(Reg::LAST_ERROR);
        uint64_t cycles     = ct.getCSR(Reg::TIMER);
        uint32_t fsm        = status & 0x1F;
        bool     listen     = (status >> 8) & 1;

        // Always print when FSM state changes
        if (fsm != prev_fsm) {
            std::cout << "[FSM] " << (fsm < 16 ? fsm_names[fsm] : "???")
                      << " (" << fsm << ")"
                      << " | recv=" << bytes << " B"
                      << " | nvme_sent=" << sent
                      << " | nvme_done=" << done
                      << " | lba=" << (lba_off / 1024) << " KB"
                      << " | listen=" << listen;
            if (error)
                std::cout << " | ERR=0x" << std::hex << error << std::dec;
            std::cout << std::endl;
            prev_fsm = fsm;
            stall_count = 0;
        }

        // Print periodic status if stuck in same state
        if (bytes == prev_bytes && fsm == prev_fsm) {
            stall_count++;
            if (stall_count == 1000) {  // ~1 second stuck
                std::cout << "[STALL] state=" << (fsm < 16 ? fsm_names[fsm] : "???")
                          << " recv=" << bytes << " B"
                          << " nvme_sent=" << sent << " nvme_done=" << done
                          << " lba=" << (lba_off / 1024) << " KB"
                          << " err=0x" << std::hex << error << std::dec
                          << std::endl;
                stall_count = 0;
            }
        } else {
            stall_count = 0;
        }
        prev_bytes = bytes;

        // Detect new block completion (LBA offset advances)
        if (lba_off > prev_lba) {
            block_count++;
            uint64_t block_bytes = lba_off - prev_lba;
            double seconds = cycles / 250e6;
            double bw = (bytes > 0 && seconds > 0)
                        ? (bytes / seconds) / (1024.0 * 1024 * 1024) : 0.0;

            std::cout << "Block #" << std::setw(4) << block_count
                      << " | +" << std::setw(7) << (block_bytes / 1024) << " KB"
                      << " | total=" << std::setw(7) << (lba_off / 1024 / 1024) << " MB"
                      << " | recv=" << std::setw(10) << bytes << " B"
                      << " | " << std::fixed << std::setprecision(2) << bw << " GB/s";
            if (error)
                std::cout << " | ERR=0x" << std::hex << error << std::dec;
            std::cout << std::endl;

            prev_lba = lba_off;
        }

        // Check if transfer is done
        if (fsm == 15 && block_count > 0) {  // ST_DONE
            std::cout << "\nTransfer complete!" << std::endl;
            std::cout << "Total stored: " << (lba_off / 1024 / 1024) << " MB" << std::endl;
            prev_lba = 0;
            block_count = 0;
        }

        usleep(1000);  // 1ms poll
    }

    /* Cleanup */
    std::cout << "\nShutting down..." << std::endl;
    ct.freeMem(card_buf);
    ct.closeNVMe(dev);
    std::cout << "Done!" << std::endl;

    return 0;
}
