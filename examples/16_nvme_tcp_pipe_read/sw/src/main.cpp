/**
 * This file is part of the Coyote <https://github.com/fpgasystems/Coyote>
 *
 * MIT Licence
 * Copyright (c) 2021-2026, Systems Group, ETH Zurich
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:

 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.

 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

// Example 16: NVMe -> TCP pipelined read (FPGA-side host).
//
// The program claims an NVMe SSD, allocates an HBM ring buffer, programs the
// pipeline CSRs, kicks off the TCP listener and polls the progress counters.

#include <cstdint>
#include <cstring>
#include <csignal>
#include <iomanip>
#include <iostream>
#include <string>
#include <unistd.h>
#include <boost/program_options.hpp>

#include <coyote/cThread.hpp>

// CSR register map; must match nvme_tcp_pipe_read_ctrl.sv
enum class PipeRegister : uint32_t {
    CTRL            = 0,
    STATUS          = 1,
    LISTEN_PORT     = 2,
    HBM_BASE        = 3,
    CHUNK_SIZE      = 4,
    N_SLOTS         = 5,
    DMA_BLOCK_SIZE  = 6,
    DMA_PER_SLOT    = 7,
    NSID            = 8,
    TIMER           = 9,
    NVME_SENT       = 10,
    NVME_DONE       = 11,
    LAST_ERROR      = 12,
    BYTES_TOTAL     = 13,
    WR_PTR          = 14,
    RD_PTR          = 15,
    MAX_OUTSTANDING = 16
};

static inline uint32_t reg(PipeRegister r) { return static_cast<uint32_t>(r); }

static constexpr uint64_t START = 1;
static volatile bool running = true;
static void sighandler(int) { running = false; }

// Parse a size string like "64M", "128K" or "1G"
static uint64_t parseSize(const std::string& s) {
    if (s.empty()) {
        throw std::runtime_error("empty size string");
    }
    char* end = nullptr;
    uint64_t val = std::strtoull(s.c_str(), &end, 0);
    switch (end ? *end : '\0') {
        case 'K': case 'k': val *= 1024ULL; break;
        case 'M': case 'm': val *= 1024ULL * 1024; break;
        case 'G': case 'g': val *= 1024ULL * 1024 * 1024; break;
        case '\0':                                       break;
        default:
            throw std::runtime_error("unknown size suffix in '" + s + "'");
    }
    return val;
}

int main(int argc, char* argv[]) {
    // CLI arguments
    std::string bdf;
    std::string chunk_str;
    std::string dma_str;
    std::string ring_str;
    std::string alloc_str;
    uint16_t tcp_port;
    uint32_t max_outstanding;
    int vfpga_id;

    namespace po = boost::program_options;
    po::options_description runtime_options("Coyote NVMe -> TCP Pipelined Read Options");
    runtime_options.add_options()
        ("bdf,b",         po::value<std::string>(&bdf)->required(),                       "NVMe PCI BDF (e.g. 0000:65:00.0)")
        ("port,p",        po::value<uint16_t>(&tcp_port)->default_value(5002),            "TCP listen port")
        ("chunk,c",       po::value<std::string>(&chunk_str)->default_value("128K"),      "Bytes per ring slot")
        ("dma,d",         po::value<std::string>(&dma_str)->default_value("4K"),          "DMA read granularity for TCP TX")
        ("ring,r",        po::value<std::string>(&ring_str)->default_value("128M"),       "HBM ring buffer size")
        ("alloc,a",       po::value<std::string>(&alloc_str)->default_value("128M"),      "NVMe allocation size")
        ("outstanding,o", po::value<uint32_t>(&max_outstanding)->default_value(56),       "Max in-flight NVMe commands")
        ("vfpga,v",       po::value<int>(&vfpga_id)->default_value(0),                    "vFPGA ID");

    po::variables_map command_line_arguments;
    po::store(po::parse_command_line(argc, argv, runtime_options), command_line_arguments);
    po::notify(command_line_arguments);

    uint32_t chunk_size     = static_cast<uint32_t>(parseSize(chunk_str));
    uint32_t dma_block_size = static_cast<uint32_t>(parseSize(dma_str));
    uint64_t ring_size      = parseSize(ring_str);
    uint64_t alloc_size     = parseSize(alloc_str);

    if (chunk_size == 0 || dma_block_size == 0) {
        throw std::runtime_error("chunk and dma block sizes must be non-zero");
    }
    if (chunk_size % dma_block_size != 0) {
        throw std::runtime_error("chunk size must be a multiple of the dma block size");
    }
    if (ring_size < chunk_size) {
        throw std::runtime_error("ring size must be >= chunk size");
    }

    uint32_t n_slots = static_cast<uint32_t>(ring_size / chunk_size);

    HEADER("CLI PARAMETERS:");
    std::cout << "vFPGA ID:    " << vfpga_id << std::endl;
    std::cout << "BDF:         " << bdf << std::endl;
    std::cout << "TCP port:    " << tcp_port << std::endl;
    std::cout << "Chunk size:  " << (chunk_size / 1024) << " KB" << std::endl;
    std::cout << "DMA block:   " << (dma_block_size / 1024) << " KB" << std::endl;
    std::cout << "Ring buffer: " << (ring_size / 1024 / 1024) << " MB (" << n_slots << " slots)" << std::endl;
    std::cout << "DMA/slot:    " << (chunk_size / dma_block_size) << " descriptors" << std::endl;
    std::cout << "Max QD:      " << max_outstanding << std::endl;

    signal(SIGINT, sighandler);

    coyote::cThread coyote_thread(vfpga_id, getpid());

    // Claim the NVMe device for this region
    coyote::nvmeInitIoctl dev = coyote_thread.initNVMe(bdf, 1, alloc_size);
    std::cout << "NVMe dev_id=" << dev.dev_id
              << "  lba_size=" << dev.lba_size
              << "  nsze=" << dev.nsze
              << "  mdts=" << dev.mdts << std::endl;

    if (dev.mdts > 0 && chunk_size > dev.mdts) {
        std::cout << "Clamping chunk to MDTS: " << dev.mdts << std::endl;
        chunk_size = dev.mdts;
        n_slots = static_cast<uint32_t>(ring_size / chunk_size);
    }

    if (chunk_size % dma_block_size != 0) {
        throw std::runtime_error("chunk size (after MDTS clamping) is not a multiple of the dma block size");
    }

    // Allocate the HBM ring buffer (huge pages backing, offloaded to card memory)
    void* ring_buf = coyote_thread.getMem({coyote::CoyoteAllocType::HPF, static_cast<uint32_t>(ring_size)});
    if (!ring_buf) {
        coyote_thread.closeNVMe(dev.dev_id);
        throw std::runtime_error("could not allocate HBM ring buffer");
    }
    std::memset(ring_buf, 0, ring_size);
    coyote_thread.invoke(coyote::CoyoteOper::LOCAL_OFFLOAD, coyote::syncSg{ring_buf, ring_size});
    std::cout << "Ring buffer: " << ring_buf << " (offloaded to HBM)" << std::endl;

    // Configure the pipeline CSRs
    const uint32_t dma_per_slot = chunk_size / dma_block_size;
    coyote_thread.setCSR(reinterpret_cast<uint64_t>(ring_buf), reg(PipeRegister::HBM_BASE));
    coyote_thread.setCSR(chunk_size,                            reg(PipeRegister::CHUNK_SIZE));
    coyote_thread.setCSR(n_slots,                               reg(PipeRegister::N_SLOTS));
    coyote_thread.setCSR(dma_block_size,                        reg(PipeRegister::DMA_BLOCK_SIZE));
    coyote_thread.setCSR(dma_per_slot,                          reg(PipeRegister::DMA_PER_SLOT));
    coyote_thread.setCSR(tcp_port,                              reg(PipeRegister::LISTEN_PORT));
    coyote_thread.setCSR(static_cast<uint64_t>(dev.nsid),       reg(PipeRegister::NSID));
    coyote_thread.setCSR(max_outstanding,                       reg(PipeRegister::MAX_OUTSTANDING));

    // Kick off
    coyote_thread.setCSR(START, reg(PipeRegister::CTRL));

    // Wait for the listen handshake to complete
    bool listen_ok = false;
    for (int i = 0; i < 100; i++) {
        usleep(10000);
        const uint64_t status = coyote_thread.getCSR(reg(PipeRegister::STATUS));
        if (status & (1ULL << 5)) {
            listen_ok = true;
            std::cout << "TCP listen OK on port " << tcp_port << std::endl;
            break;
        }
    }
    if (!listen_ok) {
        std::cerr << "TCP listen failed (timeout)" << std::endl;
        coyote_thread.freeMem(ring_buf);
        coyote_thread.closeNVMe(dev.dev_id);
        return EXIT_FAILURE;
    }

    HEADER("WAITING FOR CLIENT REQUESTS (Ctrl+C to stop)...");

    // Poll loop
    uint32_t prev_done = 0;
    while (running) {
        const uint32_t wp     = coyote_thread.getCSR(reg(PipeRegister::WR_PTR));
        const uint32_t rp     = coyote_thread.getCSR(reg(PipeRegister::RD_PTR));
        const uint32_t sent   = coyote_thread.getCSR(reg(PipeRegister::NVME_SENT));
        const uint32_t done   = coyote_thread.getCSR(reg(PipeRegister::NVME_DONE));
        const uint64_t bytes  = coyote_thread.getCSR(reg(PipeRegister::BYTES_TOTAL));
        const uint16_t error  = coyote_thread.getCSR(reg(PipeRegister::LAST_ERROR)) & 0xFFFF;
        const uint64_t cycles = coyote_thread.getCSR(reg(PipeRegister::TIMER));

        if (done > prev_done) {
            const double seconds = (double) cycles / 250.0e6;
            const double bw      = (bytes > 0 && seconds > 0.0)
                                 ? (double) bytes / seconds / (1024.0 * 1024.0 * 1024.0)
                                 : 0.0;

            std::cout << "\rwp=" << std::setw(5) << wp
                      << " rp=" << std::setw(5) << rp
                      << " | nvme " << sent << "/" << done
                      << " | " << std::setw(7) << (bytes / 1024 / 1024) << " MB"
                      << " | " << std::fixed << std::setprecision(2) << bw << " GB/s";
            if (error) {
                std::cout << " | ERR=0x" << std::hex << error << std::dec;
            }
            std::cout << std::flush;

            prev_done = done;
        }

        usleep(1000);
    }

    std::cout << std::endl << "Shutting down..." << std::endl;
    coyote_thread.freeMem(ring_buf);
    coyote_thread.closeNVMe(dev.dev_id);
    std::cout << "Done." << std::endl;
    return EXIT_SUCCESS;
}
