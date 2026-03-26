/**
 * NVMe BRAM Dump Tool
 *
 * Reads SQ/PRP/CQ BRAM from host via bypass BAR — same path NVMe SSD uses.
 * Use after submitting commands to verify what the SSD would see.
 *
 * Usage:
 *   ./bin/nvme_bram_dump -d <dev_id> [-q <sq_tail>] [-n <num_prp_entries>]
 *
 * Two modes:
 *   1) IOCTL mode (default): calls IOCTL_NVME_DEBUG_DUMP → output in dmesg
 *   2) Direct BAR mode (-D): mmap BAR2 and read SQ/PRP directly from userspace
 */

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <getopt.h>

/* ---- Constants matching driver/include/coyote_defs.h ---- */
#define IOCTL_NVME_DEBUG_DUMP  _IOW('F', 43, unsigned long)

/* BAR offsets (within BAR_SHELL_CONFIG = BAR2, via bypass AXI interconnect) */
#define NVME_SQ_BASE    0x04010000ULL
#define NVME_SQ_SIZE    0x1000ULL        /* 4KB per device */
#define NVME_CQ_BASE    0x04020000ULL
#define NVME_CQ_SIZE    0x1000ULL
#define NVME_PRP_BASE   0x04040000ULL
#define NVME_PRP_SIZE   0x40000ULL       /* 256KB per device */

/* SQE = 64 bytes = 16 DWORDs */
#define SQE_SIZE        64

static void usage(const char *prog) {
    fprintf(stderr,
        "Usage: %s [options]\n"
        "  -d, --dev <id>        NVMe dev_id (0..15, required)\n"
        "  -q, --sq-tail <n>     Dump SQ entry and PRP list for this sq_tail\n"
        "  -n, --num-prp <n>     Number of PRP entries to dump (default: 32)\n"
        "  -D, --direct          Direct BAR read (needs /sys/bus/pci BAR2 resource)\n"
        "  -b, --bar <path>      BAR2 resource path (default: auto-detect from FPGA)\n"
        "  -v, --vfpga <id>      vFPGA ID (default: 0)\n"
        "  -f, --fpga <id>       FPGA device ID (default: 0)\n"
        "\n"
        "Default: IOCTL mode → dumps to dmesg (check with: dmesg | tail -80)\n"
        "\n"
        "Direct mode example:\n"
        "  %s -d 1 -q 0 -n 32 -D -b /sys/bus/pci/devices/0000:d8:00.0/resource2\n"
        "\n", prog, prog);
}

/* ================================================================
 * IOCTL mode: trigger driver's nvme_debug_dump_all → output in dmesg
 * ================================================================ */
static int do_ioctl_dump(int dev_id, int vfpga, int fpga_dev) {
    char path[128];
    snprintf(path, sizeof(path), "/dev/coyote_fpga_%d_v%d", fpga_dev, vfpga);

    int fd = open(path, O_RDWR);
    if (fd < 0) {
        perror(path);
        fprintf(stderr, "Make sure the Coyote driver is loaded and vFPGA %d exists.\n", vfpga);
        return 1;
    }

    printf("Calling IOCTL_NVME_DEBUG_DUMP for dev_id=%d on %s ...\n", dev_id, path);
    int rc = ioctl(fd, IOCTL_NVME_DEBUG_DUMP, (unsigned long)dev_id);
    close(fd);

    if (rc < 0) {
        perror("ioctl NVME_DEBUG_DUMP");
        return 1;
    }

    printf("Done. Check output with:\n  dmesg | tail -80\n");
    return 0;
}

/* ================================================================
 * Direct BAR mode: mmap BAR2 and read SQ/PRP from userspace
 *
 * This reads via the EXACT same path the NVMe SSD uses:
 *   BAR2 → XDMA M_AXI_BYPASS → axi_interconnect → nvme_prp_ctrl
 * ================================================================ */
static int do_direct_dump(const char *bar_path, int dev_id, int sq_tail, int num_prp) {
    int fd = open(bar_path, O_RDWR | O_SYNC);
    if (fd < 0) {
        perror(bar_path);
        fprintf(stderr, "Need root. Try: sudo %s ...\n", "nvme_bram_dump");
        return 1;
    }

    /* --- Dump SQ entry --- */
    {
        uint64_t sq_offset = NVME_SQ_BASE + (uint64_t)dev_id * NVME_SQ_SIZE;
        size_t sq_map_size = NVME_SQ_SIZE;

        /* mmap must be page-aligned; sq_offset might not be */
        uint64_t sq_page = sq_offset & ~0xFFFULL;
        size_t sq_page_off = sq_offset - sq_page;

        void *sq_map = mmap(NULL, sq_page_off + sq_map_size,
                            PROT_READ, MAP_SHARED, fd, sq_page);
        if (sq_map == MAP_FAILED) {
            perror("mmap SQ");
            close(fd);
            return 1;
        }

        volatile uint32_t *sq_base = (volatile uint32_t *)((char *)sq_map + sq_page_off);

        printf("\n===== SQ BRAM dev_id=%d (BAR offset=0x%llx) =====\n",
               dev_id, (unsigned long long)sq_offset);

        if (sq_tail >= 0) {
            /* Dump specific SQ entry */
            volatile uint32_t *sqe = sq_base + (sq_tail * 16); /* 16 DWs per SQE */
            printf("  SQE[%d]:\n", sq_tail);
            printf("    Opcode=0x%02x  CID=%u  NSID=%u\n",
                   sqe[0] & 0xFF, sqe[0] >> 16, sqe[1]);
            printf("    PRP1=0x%08x_%08x\n", sqe[7], sqe[6]);
            printf("    PRP2=0x%08x_%08x\n", sqe[9], sqe[8]);
            printf("    SLBA=0x%08x_%08x  NLB=%u\n",
                   sqe[11], sqe[10], sqe[12] & 0xFFFF);
            for (int r = 0; r < 4; r++) {
                printf("    DW%d-%d: %08x %08x %08x %08x\n",
                       r*4, r*4+3, sqe[r*4], sqe[r*4+1], sqe[r*4+2], sqe[r*4+3]);
            }
        } else {
            /* Dump all non-zero SQ entries */
            for (int i = 0; i < 64; i++) {
                volatile uint32_t *sqe = sq_base + (i * 16);
                bool all_zero = true;
                for (int j = 0; j < 16; j++)
                    if (sqe[j] != 0) { all_zero = false; break; }
                if (all_zero) continue;

                printf("  SQE[%02d]: opcode=0x%02x CID=%u NSID=%u "
                       "PRP1=%08x_%08x PRP2=%08x_%08x SLBA=%08x_%08x NLB=%u\n",
                       i, sqe[0] & 0xFF, sqe[0] >> 16, sqe[1],
                       sqe[7], sqe[6], sqe[9], sqe[8],
                       sqe[11], sqe[10], sqe[12] & 0xFFFF);
            }
        }
        munmap(sq_map, sq_page_off + sq_map_size);
    }

    /* --- Dump PRP list --- */
    {
        /*
         * PRP address as seen by NVMe SSD (and by host via BAR):
         *   NVME_PRP_BASE + dev_id * NVME_PRP_SIZE + sq_tail * 4096
         *
         * NVME_PRP_SIZE = 256KB = (1 << 18), so dev_id * 256KB = dev_id << 18
         * Each queue's PRP page = 4KB (NVMe spec page alignment)
         */
        int tail = (sq_tail >= 0) ? sq_tail : 0;
        uint64_t prp_offset = NVME_PRP_BASE
                             + (uint64_t)dev_id * NVME_PRP_SIZE
                             + (uint64_t)tail * 4096ULL;

        size_t prp_map_size = (size_t)num_prp * 8;
        if (prp_map_size < 4096) prp_map_size = 4096;

        uint64_t prp_page = prp_offset & ~0xFFFULL;
        size_t prp_page_off = prp_offset - prp_page;

        void *prp_map = mmap(NULL, prp_page_off + prp_map_size,
                             PROT_READ, MAP_SHARED, fd, prp_page);
        if (prp_map == MAP_FAILED) {
            perror("mmap PRP");
            close(fd);
            return 1;
        }

        volatile uint32_t *prp_base = (volatile uint32_t *)((char *)prp_map + prp_page_off);

        printf("\n===== PRP BRAM dev_id=%d sq_tail=%d (BAR offset=0x%llx) =====\n",
               dev_id, tail, (unsigned long long)prp_offset);
        printf("  (This is the address the SSD would DMA-read for the PRP list)\n\n");

        int found = 0;
        for (int i = 0; i < num_prp; i++) {
            uint32_t lo = prp_base[i * 2];
            uint32_t hi = prp_base[i * 2 + 1];
            uint64_t addr = ((uint64_t)hi << 32) | lo;
            if (addr != 0) {
                printf("  PRP[%03d]: 0x%016lx\n", i, addr);
                found++;
            }
        }
        if (found == 0) {
            printf("  (all entries are zero)\n");
        }

        /* Also read from offset 0 (what truncated address would map to) */
        munmap(prp_map, prp_page_off + prp_map_size);

        if (dev_id > 0) {
            printf("\n===== PRP BRAM at offset 0 (aliased addr if truncated) =====\n");
            uint64_t alias_offset = NVME_PRP_BASE + (uint64_t)tail * 4096ULL;
            uint64_t alias_page = alias_offset & ~0xFFFULL;
            size_t alias_page_off = alias_offset - alias_page;

            void *alias_map = mmap(NULL, alias_page_off + 4096,
                                   PROT_READ, MAP_SHARED, fd, alias_page);
            if (alias_map != MAP_FAILED) {
                volatile uint32_t *alias_base =
                    (volatile uint32_t *)((char *)alias_map + alias_page_off);
                printf("  BAR offset=0x%llx (dev_id=0 region)\n\n",
                       (unsigned long long)alias_offset);
                for (int i = 0; i < num_prp; i++) {
                    uint32_t lo = alias_base[i * 2];
                    uint32_t hi = alias_base[i * 2 + 1];
                    uint64_t addr = ((uint64_t)hi << 32) | lo;
                    if (addr != 0)
                        printf("  PRP[%03d]: 0x%016lx\n", i, addr);
                }
                munmap(alias_map, alias_page_off + 4096);
            }
        }
    }

    close(fd);
    return 0;
}

int main(int argc, char *argv[]) {
    int dev_id = -1;
    int sq_tail = -1;
    int num_prp = 32;
    int vfpga = 0;
    int fpga_dev = 0;
    bool direct = false;
    const char *bar_path = NULL;

    static struct option long_opts[] = {
        {"dev",      required_argument, 0, 'd'},
        {"sq-tail",  required_argument, 0, 'q'},
        {"num-prp",  required_argument, 0, 'n'},
        {"direct",   no_argument,       0, 'D'},
        {"bar",      required_argument, 0, 'b'},
        {"vfpga",    required_argument, 0, 'v'},
        {"fpga",     required_argument, 0, 'f'},
        {"help",     no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "d:q:n:Db:v:f:h", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'd': dev_id = atoi(optarg); break;
            case 'q': sq_tail = atoi(optarg); break;
            case 'n': num_prp = atoi(optarg); break;
            case 'D': direct = true; break;
            case 'b': bar_path = optarg; break;
            case 'v': vfpga = atoi(optarg); break;
            case 'f': fpga_dev = atoi(optarg); break;
            case 'h':
            default:
                usage(argv[0]);
                return 1;
        }
    }

    if (dev_id < 0) {
        fprintf(stderr, "Error: -d <dev_id> is required\n\n");
        usage(argv[0]);
        return 1;
    }

    if (!direct) {
        return do_ioctl_dump(dev_id, vfpga, fpga_dev);
    }

    if (!bar_path) {
        fprintf(stderr, "Error: -D mode requires -b <bar2_resource_path>\n");
        fprintf(stderr, "Find it with: lspci -v | grep -A10 'Coyote\\|FPGA'\n");
        fprintf(stderr, "Then use the resource2 path, e.g.:\n");
        fprintf(stderr, "  -b /sys/bus/pci/devices/0000:d8:00.0/resource2\n");
        return 1;
    }

    return do_direct_dump(bar_path, dev_id, sq_tail, num_prp);
}
