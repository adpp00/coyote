/**
 * NVMe-TCP Store Client — counterpart for Example 16 Store
 *
 * Protocol:
 *   1. TCP connect to FPGA
 *   2. Send 64B meta: [7:0] = total_data_length (little-endian)
 *   3. Send data with flow control (outstanding window)
 *   4. Receive 64B completion per 1MB block from FPGA:
 *        [31:0]   = status (0=ok)
 *        [63:32]  = nvme_done count
 *        [127:64] = nvme_lba_off (where block was written)
 *        [159:128]= block_recv (bytes in this block)
 *
 * Flow control:
 *   - Outstanding = MB blocks sent but not yet completed
 *   - Initially send up to (outstanding_limit * 1MB)
 *   - For each 1MB completion received, send another 1MB
 *   - Uses poll() to interleave send/recv without deadlock
 *
 * Build:
 *   g++ -O2 -o store_client store_client.cpp
 *
 * Usage:
 *   ./store_client -i 10.0.0.1 -p 5001 -s 128M
 *   ./store_client -i 10.0.0.1 -p 5001 -s 1G -O 4
 */

#include <iostream>
#include <iomanip>
#include <cstring>
#include <cstdint>
#include <chrono>
#include <fcntl.h>
#include <unistd.h>
#include <getopt.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>

static constexpr size_t SEND_CHUNK = 32768;         // 32KB send chunks

static uint64_t parseSize(const char* s) {
    char* end;
    uint64_t val = strtoull(s, &end, 0);
    switch (*end) {
        case 'K': case 'k': val *= 1024ULL; break;
        case 'M': case 'm': val *= 1024ULL * 1024; break;
        case 'G': case 'g': val *= 1024ULL * 1024 * 1024; break;
        default: break;
    }
    return val;
}

static void usage(const char* prog) {
    std::cout << "Usage: " << prog << " [options]\n"
              << "  -i, --ip <addr>          FPGA IP address (default: 10.0.0.1)\n"
              << "  -p, --port <port>        TCP port (default: 5001)\n"
              << "  -a, --addr <offset>      NVMe start byte offset (default: 0)\n"
              << "  -s, --size <bytes>       Total write size (default: 128M)\n"
              << "  -c, --chunk <bytes>      Chunk size, must match FPGA (default: 4K)\n"
              << "  -f, --file <file>        Input file to send (overrides -s)\n"
              << "  -t, --timeout <sec>      Completion timeout in seconds (default: 30)\n"
              << "  -P, --pattern <val>      Fill pattern byte (default: 0xAB)\n"
              << "  -O, --outstanding <num>  Max outstanding blocks (default: 2)\n"
              << std::endl;
}

int main(int argc, char* argv[]) {
    const char* ip = "10.0.0.1";
    uint16_t port = 5001;
    uint64_t naddr = 0;
    uint64_t data_len = 128ULL * 1024 * 1024;
    const char* input_file = nullptr;
    int timeout_sec = 30;
    uint8_t pattern = 0xAB;
    uint32_t outstanding_limit = 2;  // max blocks in-flight
    uint32_t chunk_size = 4096;      // must match FPGA chunk_size

    static struct option long_opts[] = {
        {"ip",          required_argument, 0, 'i'},
        {"port",        required_argument, 0, 'p'},
        {"addr",        required_argument, 0, 'a'},
        {"size",        required_argument, 0, 's'},
        {"chunk",       required_argument, 0, 'c'},
        {"file",        required_argument, 0, 'f'},
        {"timeout",     required_argument, 0, 't'},
        {"pattern",     required_argument, 0, 'P'},
        {"outstanding", required_argument, 0, 'O'},
        {"help",        no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "i:p:a:s:c:f:t:P:O:h", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'i': ip = optarg; break;
            case 'p': port = std::stoi(optarg); break;
            case 'a': naddr = parseSize(optarg); break;
            case 's': data_len = parseSize(optarg); break;
            case 'c': chunk_size = parseSize(optarg); break;
            case 'f': input_file = optarg; break;
            case 't': timeout_sec = std::stoi(optarg); break;
            case 'P': pattern = (uint8_t)strtoul(optarg, NULL, 0); break;
            case 'O': outstanding_limit = std::stoi(optarg); break;
            default: usage(argv[0]); return (opt == 'h') ? 0 : 1;
        }
    }

    // Input file overrides data_len
    int in_fd = -1;
    if (input_file) {
        in_fd = open(input_file, O_RDONLY);
        if (in_fd < 0) { perror("open input"); return 1; }
        data_len = lseek(in_fd, 0, SEEK_END);
        lseek(in_fd, 0, SEEK_SET);
    }

    // data_len must be a multiple of 64 (AXI beat size)
    if (data_len % 64 != 0) {
        data_len = (data_len + 63) & ~63ULL;
        std::cout << "Aligned data_len to 64B boundary: " << data_len << std::endl;
    }

    uint32_t expected_cpls = (data_len + chunk_size - 1) / chunk_size;

    std::cout << "=== NVMe-TCP Store Client ===" << std::endl;
    std::cout << "Target:      " << ip << ":" << port << std::endl;
    std::cout << "Addr:        0x" << std::hex << naddr << std::dec << std::endl;
    std::cout << "Write:       " << (data_len / 1024 / 1024) << " MB ("
              << data_len << " bytes)" << std::endl;
    std::cout << "Chunk:       " << (chunk_size / 1024) << " KB" << std::endl;
    std::cout << "Outstanding: " << outstanding_limit << " blocks ("
              << (outstanding_limit * chunk_size / 1024) << " KB)" << std::endl;
    if (input_file)
        std::cout << "Source:      " << input_file << std::endl;
    else
        std::cout << "Pattern:     0x" << std::hex << (int)pattern << std::dec << std::endl;
    std::cout << "Expect:      " << expected_cpls << " completions" << std::endl;

    // --- 1. Connect ---
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }

    int sndbuf = 4 * 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
    int nodelay = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));

    struct sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, ip, &addr.sin_addr) != 1) {
        std::cerr << "Invalid IP: " << ip << std::endl;
        close(fd);
        return 1;
    }

    std::cout << "Connecting..." << std::flush;
    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror(" connect");
        close(fd);
        return 1;
    }
    std::cout << " OK" << std::endl;

    // --- 2. Send 64B meta: [63:0]=naddr, [127:64]=length ---
    uint8_t meta[64] = {};
    memcpy(meta + 0, &naddr,    sizeof(naddr));     // [63:0]
    memcpy(meta + 8, &data_len, sizeof(data_len));  // [127:64]

    ssize_t n = send(fd, meta, 64, 0);
    if (n != 64) { perror("send meta"); close(fd); return 1; }

    // --- 2b. Wait for 64B ACK from FPGA ---
    {
        uint8_t ack[64] = {};
        size_t ack_got = 0;
        struct pollfd pfd_ack = { .fd = fd, .events = POLLIN, .revents = 0 };
        while (ack_got < 64) {
            int ret = poll(&pfd_ack, 1, timeout_sec * 1000);
            if (ret <= 0) {
                std::cerr << "ACK timeout/error" << std::endl;
                close(fd);
                return 1;
            }
            ssize_t r = recv(fd, ack + ack_got, 64 - ack_got, 0);
            if (r <= 0) {
                std::cerr << "ACK recv failed" << std::endl;
                close(fd);
                return 1;
            }
            ack_got += r;
        }
        uint32_t ack_status;
        memcpy(&ack_status, ack, 4);
        if (ack_status != 0) {
            std::cerr << "FPGA rejected: status=0x" << std::hex << ack_status
                      << std::dec << std::endl;
            close(fd);
            return 1;
        }
        std::cout << "ACK received (OK)" << std::endl;
    }

    // --- 3. Interleaved send + recv with flow control ---
    // Set socket non-blocking for poll-based interleaving
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    uint8_t sendbuf[SEND_CHUNK];
    if (!input_file)
        memset(sendbuf, pattern, sizeof(sendbuf));

    auto t0 = std::chrono::high_resolution_clock::now();
    uint64_t total_sent = 0;
    uint32_t cpls_recv = 0;
    uint32_t errors = 0;
    uint64_t last_print = 0;

    // Completion recv buffer (may arrive in fragments)
    uint8_t cpl_buf[64];
    size_t cpl_buf_off = 0;

    bool all_done = false;

    while (!all_done) {
        // --- Flow control: how much are we allowed to send? ---
        // allowed = (cpls_recv + outstanding_limit) * 1MB, capped at data_len
        uint64_t send_ceiling = (uint64_t)(cpls_recv + outstanding_limit) * chunk_size;
        if (send_ceiling > data_len) send_ceiling = data_len;
        bool can_send = (total_sent < send_ceiling);

        // --- Build poll events ---
        struct pollfd pfd = { .fd = fd, .events = 0, .revents = 0 };
        if (can_send)                    pfd.events |= POLLOUT;
        if (cpls_recv < expected_cpls)   pfd.events |= POLLIN;

        if (pfd.events == 0) { all_done = true; break; }

        int ret = poll(&pfd, 1, timeout_sec * 1000);
        if (ret == 0) {
            std::cerr << "\nTimeout! sent=" << (total_sent / 1024 / 1024) << "MB"
                      << " cpls=" << cpls_recv << "/" << expected_cpls << std::endl;
            break;
        }
        if (ret < 0) { perror("poll"); break; }

        // --- Try recv completions first (free up send window) ---
        if (pfd.revents & POLLIN) {
            ssize_t r = recv(fd, cpl_buf + cpl_buf_off, 64 - cpl_buf_off, 0);
            if (r > 0) {
                cpl_buf_off += r;

                // Got a full 64B completion?
                if (cpl_buf_off >= 64) {
                    cpls_recv++;
                    cpl_buf_off = 0;

                    // Parse
                    uint32_t status, nvme_done, block_bytes;
                    uint64_t lba_off;
                    memcpy(&status,      cpl_buf + 0,  4);
                    memcpy(&nvme_done,   cpl_buf + 4,  4);
                    memcpy(&lba_off,     cpl_buf + 8,  8);
                    memcpy(&block_bytes, cpl_buf + 16, 4);

                    if (status != 0) {
                        errors++;
                        std::cout << "\n  CPL #" << cpls_recv << ": ERROR 0x"
                                  << std::hex << status << std::dec << std::endl;
                    } else {
                        auto now = std::chrono::high_resolution_clock::now();
                        double sec = std::chrono::duration<double>(now - t0).count();
                        double gbps = (sec > 0)
                            ? ((uint64_t)cpls_recv * chunk_size / sec) / (1024.0*1024*1024) : 0;

                        std::cout << "\r  CPL #" << std::setw(3) << cpls_recv
                                  << " | lba=" << std::setw(5) << (lba_off/1024/1024) << "MB"
                                  << " | nvme=" << nvme_done
                                  << " | " << std::fixed << std::setprecision(2)
                                  << gbps << " GB/s"
                                  << " | out=" << (total_sent/chunk_size - cpls_recv)
                                  << std::flush;
                    }

                    // Check if all done
                    if (cpls_recv >= expected_cpls && total_sent >= data_len) {
                        all_done = true;
                    }
                }
            } else if (r == 0) {
                std::cerr << "\nConnection closed by FPGA" << std::endl;
                break;
            }
            // EAGAIN is fine — no data yet
        }

        // --- Send data if within window ---
        if ((pfd.revents & POLLOUT) && can_send && total_sent < data_len) {
            size_t to_send = send_ceiling - total_sent;
            if (to_send > SEND_CHUNK) to_send = SEND_CHUNK;
            if (to_send > data_len - total_sent) to_send = data_len - total_sent;

            if (input_file) {
                ssize_t r = read(in_fd, sendbuf, to_send);
                if (r <= 0) { perror("read file"); break; }
                to_send = r;
            }

            ssize_t sent = send(fd, sendbuf, to_send, MSG_NOSIGNAL);
            if (sent > 0) {
                total_sent += sent;

                // Progress every 1MB
                if (total_sent - last_print >= chunk_size) {
                    std::cout << "\rSent: " << std::setw(7) << (total_sent/1024/1024)
                              << " / " << (data_len/1024/1024) << " MB"
                              << " | cpls=" << cpls_recv
                              << " | out=" << (total_sent/chunk_size - cpls_recv)
                              << "     " << std::flush;
                    last_print = total_sent;
                }
            }
            // EAGAIN is fine — send buffer full, poll again
        }
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    double sec = std::chrono::duration<double>(t1 - t0).count();
    double gbps = (sec > 0) ? (total_sent / sec) / (1024.0 * 1024 * 1024) : 0;

    std::cout << "\n\n=== Result ===" << std::endl;
    std::cout << "Sent:        " << (total_sent / 1024 / 1024) << " MB" << std::endl;
    std::cout << "Completions: " << cpls_recv << " / " << expected_cpls << std::endl;
    std::cout << "Errors:      " << errors << std::endl;
    std::cout << "Time:        " << std::fixed << std::setprecision(3) << sec << " s" << std::endl;
    std::cout << "BW:          " << std::setprecision(2) << gbps << " GB/s" << std::endl;

    // Cleanup
    close(fd);
    if (in_fd >= 0) close(in_fd);

    return (cpls_recv == expected_cpls && errors == 0) ? 0 : 1;
}
