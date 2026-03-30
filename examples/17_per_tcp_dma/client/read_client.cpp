/**
 * NVMe-TCP Pipelined Read Client
 *
 * Protocol:
 *   1. TCP connect to FPGA
 *   2. Send 64B meta: [63:0]=naddr, [127:64]=length
 *   3. Receive data stream (FPGA sends in 32KB TCP packets)
 *
 * Build:
 *   g++ -O2 -o read_client read_client.cpp
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
              << "  -p, --port <port>   TCP port (default: 5002)\n"
              << "  -a, --addr <offset> NVMe start byte offset (default: 0)\n"
              << "  -s, --size <bytes>  Total read size (default: 128M)\n"
              << "  -o, --output <file> Save received data to file (optional)\n"
              << "  -t, --timeout <sec> Recv timeout in seconds (default: 30)\n"
              << "  -v, --verify        Print first 64 bytes of received data\n"
              << std::endl;
}

int main(int argc, char* argv[]) {
    const char* ip = "10.0.0.1";
    uint16_t port = 5002;
    uint64_t naddr = 0;
    uint64_t read_len = 128ULL * 1024 * 1024;
    const char* output_file = nullptr;
    int timeout_sec = 30;
    bool verify = false;

    static struct option long_opts[] = {
        {"ip",      required_argument, 0, 'i'},
        {"port",    required_argument, 0, 'p'},
        {"addr",    required_argument, 0, 'a'},
        {"size",    required_argument, 0, 's'},
        {"output",  required_argument, 0, 'o'},
        {"timeout", required_argument, 0, 't'},
        {"verify",  no_argument,       0, 'v'},
        {"help",    no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "i:p:a:s:o:t:vh", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'i': ip = optarg; break;
            case 'p': port = std::stoi(optarg); break;
            case 'a': naddr = parseSize(optarg); break;
            case 's': read_len = parseSize(optarg); break;
            case 'o': output_file = optarg; break;
            case 't': timeout_sec = std::stoi(optarg); break;
            case 'v': verify = true; break;
            default: usage(argv[0]); return (opt == 'h') ? 0 : 1;
        }
    }

    std::cout << "=== NVMe-TCP Pipelined Read Client ===" << std::endl;
    std::cout << "Target:  " << ip << ":" << port << std::endl;
    std::cout << "Addr:    0x" << std::hex << naddr << std::dec << std::endl;
    std::cout << "Read:    " << (read_len / 1024 / 1024) << " MB ("
              << read_len << " bytes)" << std::endl;

    // --- 1. Connect ---
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }

    int rcvbuf = 4 * 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
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
    memcpy(meta + 0, &naddr,    sizeof(naddr));
    memcpy(meta + 8, &read_len, sizeof(read_len));

    ssize_t sent = 0;
    while (sent < 64) {
        ssize_t n = send(fd, meta + sent, 64 - sent, 0);
        if (n <= 0) { perror("send meta"); close(fd); return 1; }
        sent += n;
    }
    std::cout << "Sent request: addr=0x" << std::hex << naddr << std::dec
              << " len=" << (read_len / 1024 / 1024) << " MB" << std::endl;

    // --- 3. Receive data ---
    int out_fd = -1;
    if (output_file) {
        out_fd = open(output_file, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (out_fd < 0) { perror("open output"); close(fd); return 1; }
    }

    uint8_t first_bytes[64] = {};
    bool got_first = false;

    auto t0 = std::chrono::high_resolution_clock::now();
    uint64_t total_recv = 0;
    uint64_t last_print = 0;
    uint8_t buf[65536];

    struct pollfd pfd = { .fd = fd, .events = POLLIN, .revents = 0 };

    while (total_recv < read_len) {
        int ret = poll(&pfd, 1, timeout_sec * 1000);
        if (ret == 0) {
            std::cerr << "\nTimeout after " << timeout_sec << "s (received "
                      << total_recv << " / " << read_len << " bytes)" << std::endl;
            break;
        }
        if (ret < 0) { perror("\npoll"); break; }

        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0) {
            if (n == 0)
                std::cerr << "\nConnection closed by FPGA" << std::endl;
            else
                perror("\nrecv");
            break;
        }

        if (verify && !got_first) {
            size_t copy = (n > 64) ? 64 : n;
            memcpy(first_bytes, buf, copy);
            got_first = true;
        }

        if (out_fd >= 0) {
            ssize_t written = 0;
            while (written < n) {
                ssize_t w = write(out_fd, buf + written, n - written);
                if (w <= 0) { perror("write output"); break; }
                written += w;
            }
        }

        total_recv += n;

        if (total_recv - last_print >= 1024 * 1024) {
            auto now = std::chrono::high_resolution_clock::now();
            double sec = std::chrono::duration<double>(now - t0).count();
            double gbps = (sec > 0) ? (total_recv / sec) / (1024.0 * 1024 * 1024) : 0;

            std::cout << "\rRecv: " << std::setw(7) << (total_recv / 1024 / 1024) << " / "
                      << (read_len / 1024 / 1024) << " MB  "
                      << std::fixed << std::setprecision(2) << gbps << " GB/s"
                      << std::flush;
            last_print = total_recv;
        }
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    double sec = std::chrono::duration<double>(t1 - t0).count();
    double gbps = (sec > 0) ? (total_recv / sec) / (1024.0 * 1024 * 1024) : 0;

    std::cout << "\n\n=== Result ===" << std::endl;
    std::cout << "Received: " << (total_recv / 1024 / 1024) << " MB ("
              << total_recv << " bytes)" << std::endl;
    std::cout << "Time:     " << std::fixed << std::setprecision(3) << sec << " s" << std::endl;
    std::cout << "BW:       " << std::setprecision(2) << gbps << " GB/s" << std::endl;

    if (total_recv == read_len)
        std::cout << "Status:   OK" << std::endl;
    else
        std::cout << "Status:   INCOMPLETE" << std::endl;

    if (verify && got_first) {
        std::cout << "\nFirst 64 bytes:" << std::endl;
        for (int i = 0; i < 64; i++) {
            std::cout << std::hex << std::setw(2) << std::setfill('0') << (int)first_bytes[i];
            if ((i & 15) == 15) std::cout << std::endl;
            else std::cout << " ";
        }
        std::cout << std::dec << std::setfill(' ');
    }

    if (out_fd >= 0) close(out_fd);
    close(fd);
    return (total_recv == read_len) ? 0 : 1;
}
