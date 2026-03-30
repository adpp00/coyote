/**
 * NVMe-TCP Pipelined Store Client
 *
 * Protocol:
 *   1. TCP connect to FPGA
 *   2. Send 64B meta: [63:0]=naddr, [127:64]=length
 *   3. Recv 64B ACK: [31:0]=status (0=OK)
 *   4. Send data (no flow control needed — FPGA ring buffer handles backpressure via TCP)
 *   5. Recv 64B completion per chunk
 *
 * Build:
 *   g++ -O2 -o store_client store_client.cpp
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

static constexpr size_t SEND_CHUNK = 65536;  // 64KB send chunks

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
              << "  -i, --ip <addr>     FPGA IP address (default: 10.0.0.1)\n"
              << "  -p, --port <port>   TCP port (default: 5001)\n"
              << "  -a, --addr <offset> NVMe start byte offset (default: 0)\n"
              << "  -s, --size <bytes>  Total write size (default: 128M)\n"
              << "  -c, --chunk <bytes> Chunk size for completion tracking (default: 128K)\n"
              << "  -f, --file <file>   Input file to send (overrides -s)\n"
              << "  -t, --timeout <sec> Timeout in seconds (default: 30)\n"
              << "  -P, --pattern <val> Fill pattern byte (default: 0xAB)\n"
              << std::endl;
}

/* Recv exactly n bytes with timeout */
static ssize_t recv_exact(int fd, void* buf, size_t n, int timeout_ms) {
    size_t got = 0;
    struct pollfd pfd = { .fd = fd, .events = POLLIN, .revents = 0 };
    while (got < n) {
        int ret = poll(&pfd, 1, timeout_ms);
        if (ret <= 0) return (ret == 0) ? -(ssize_t)got : -1;
        ssize_t r = recv(fd, (uint8_t*)buf + got, n - got, 0);
        if (r <= 0) return (r == 0) ? -(ssize_t)got : -1;
        got += r;
    }
    return got;
}

int main(int argc, char* argv[]) {
    const char* ip = "10.0.0.1";
    uint16_t port = 5001;
    uint64_t naddr = 0;
    uint64_t data_len = 128ULL * 1024 * 1024;
    uint32_t chunk_size = 128 * 1024;
    const char* input_file = nullptr;
    int timeout_sec = 30;
    uint8_t pattern = 0xAB;

    static struct option long_opts[] = {
        {"ip",      required_argument, 0, 'i'},
        {"port",    required_argument, 0, 'p'},
        {"addr",    required_argument, 0, 'a'},
        {"size",    required_argument, 0, 's'},
        {"chunk",   required_argument, 0, 'c'},
        {"file",    required_argument, 0, 'f'},
        {"timeout", required_argument, 0, 't'},
        {"pattern", required_argument, 0, 'P'},
        {"help",    no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "i:p:a:s:c:f:t:P:h", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'i': ip = optarg; break;
            case 'p': port = std::stoi(optarg); break;
            case 'a': naddr = parseSize(optarg); break;
            case 's': data_len = parseSize(optarg); break;
            case 'c': chunk_size = parseSize(optarg); break;
            case 'f': input_file = optarg; break;
            case 't': timeout_sec = std::stoi(optarg); break;
            case 'P': pattern = (uint8_t)strtoul(optarg, NULL, 0); break;
            default: usage(argv[0]); return (opt == 'h') ? 0 : 1;
        }
    }

    int in_fd = -1;
    if (input_file) {
        in_fd = open(input_file, O_RDONLY);
        if (in_fd < 0) { perror("open input"); return 1; }
        data_len = lseek(in_fd, 0, SEEK_END);
        lseek(in_fd, 0, SEEK_SET);
    }

    if (data_len % 64 != 0)
        data_len = (data_len + 63) & ~63ULL;

    uint32_t expected_cpls = (data_len + chunk_size - 1) / chunk_size;

    std::cout << "=== NVMe-TCP Pipelined Store Client ===" << std::endl;
    std::cout << "Target:  " << ip << ":" << port << std::endl;
    std::cout << "Addr:    0x" << std::hex << naddr << std::dec << std::endl;
    std::cout << "Write:   " << (data_len / 1024 / 1024) << " MB" << std::endl;
    std::cout << "Chunk:   " << (chunk_size / 1024) << " KB" << std::endl;
    std::cout << "Expect:  " << expected_cpls << " completions" << std::endl;

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

    // --- 2. Send meta ---
    uint8_t meta[64] = {};
    memcpy(meta + 0, &naddr,    sizeof(naddr));
    memcpy(meta + 8, &data_len, sizeof(data_len));

    ssize_t n = send(fd, meta, 64, 0);
    if (n != 64) { perror("send meta"); close(fd); return 1; }

    // --- 3. Wait for ACK ---
    {
        uint8_t ack[64] = {};
        ssize_t r = recv_exact(fd, ack, 64, timeout_sec * 1000);
        if (r != 64) {
            std::cerr << "ACK timeout/error" << std::endl;
            close(fd);
            return 1;
        }
        uint32_t ack_status;
        memcpy(&ack_status, ack, 4);
        if (ack_status != 0) {
            std::cerr << "FPGA rejected: status=0x" << std::hex << ack_status << std::dec << std::endl;
            close(fd);
            return 1;
        }

        // Auto-adapt chunk_size from FPGA ACK [63:32]
        uint32_t fpga_chunk = 0;
        memcpy(&fpga_chunk, ack + 4, 4);
        if (fpga_chunk != 0 && fpga_chunk != chunk_size) {
            std::cout << "FPGA chunk_size=" << fpga_chunk
                      << ", overriding client chunk=" << chunk_size << std::endl;
            chunk_size = fpga_chunk;
            expected_cpls = (data_len + chunk_size - 1) / chunk_size;
        }
        std::cout << "ACK received (OK)" << std::endl;
    }

    // --- 4. Send data + recv completions (interleaved via poll) ---
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    uint8_t sendbuf[SEND_CHUNK];
    if (!input_file)
        memset(sendbuf, pattern, sizeof(sendbuf));

    auto t0 = std::chrono::high_resolution_clock::now();
    uint64_t total_sent = 0;
    uint32_t cpls_recv = 0;
    uint32_t errors = 0;

    // Completion recv buffer
    uint8_t cpl_buf[64];
    size_t cpl_buf_off = 0;

    bool all_done = false;

    while (!all_done) {
        struct pollfd pfd = { .fd = fd, .events = 0, .revents = 0 };
        if (total_sent < data_len) pfd.events |= POLLOUT;
        if (cpls_recv < expected_cpls) pfd.events |= POLLIN;

        if (pfd.events == 0) { all_done = true; break; }

        int ret = poll(&pfd, 1, timeout_sec * 1000);
        if (ret == 0) {
            std::cerr << "\nTimeout! sent=" << (total_sent/1024/1024) << "MB"
                      << " cpls=" << cpls_recv << "/" << expected_cpls << std::endl;
            break;
        }
        if (ret < 0) { perror("poll"); break; }

        // Recv completions
        if (pfd.revents & POLLIN) {
            ssize_t r = recv(fd, cpl_buf + cpl_buf_off, 64 - cpl_buf_off, 0);
            if (r > 0) {
                cpl_buf_off += r;
                if (cpl_buf_off >= 64) {
                    cpls_recv++;
                    cpl_buf_off = 0;

                    uint32_t status;
                    memcpy(&status, cpl_buf, 4);
                    if (status != 0) {
                        errors++;
                        std::cout << "\n  CPL #" << cpls_recv << ": ERROR 0x"
                                  << std::hex << status << std::dec << std::endl;
                    }

                    if (cpls_recv >= expected_cpls && total_sent >= data_len)
                        all_done = true;
                }
            } else if (r == 0) {
                std::cerr << "\nConnection closed" << std::endl;
                break;
            }
        }

        // Send data (no explicit flow control — FPGA ring handles backpressure via TCP window)
        if ((pfd.revents & POLLOUT) && total_sent < data_len) {
            size_t to_send = data_len - total_sent;
            if (to_send > SEND_CHUNK) to_send = SEND_CHUNK;

            if (input_file) {
                ssize_t r = read(in_fd, sendbuf, to_send);
                if (r <= 0) { perror("read file"); break; }
                to_send = r;
            }

            ssize_t sent = send(fd, sendbuf, to_send, MSG_NOSIGNAL);
            if (sent > 0)
                total_sent += sent;
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

    close(fd);
    if (in_fd >= 0) close(in_fd);
    return (cpls_recv == expected_cpls && errors == 0) ? 0 : 1;
}
