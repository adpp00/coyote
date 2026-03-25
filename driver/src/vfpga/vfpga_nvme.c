/*
 * Copyright (c) 2025, Systems Group, ETH Zurich
 * All rights reserved.
 *
 * NVMe initialization and management for Coyote vFPGA.
 * Ported from coyote-nvme with multi-device and permission table support.
 */

#include <linux/pm_runtime.h>

#include "coyote_defs.h"
#include "vfpga/vfpga_ops.h"

/* ============================================================
 * Forward declarations (static helpers)
 * ============================================================ */
static int nvme_open_pci(struct nvme_dev_ctx *ctx, const char *bdf);
static void nvme_close_pci(struct nvme_dev_ctx *ctx);
static int nvme_create_admin_queue(struct nvme_dev_ctx *ctx);
static void nvme_destroy_admin_queue(struct nvme_dev_ctx *ctx);
static int nvme_enable_controller(struct nvme_dev_ctx *ctx);
static int nvme_disable_controller(struct nvme_dev_ctx *ctx);
static int nvme_wait_ready(struct nvme_dev_ctx *ctx, bool enabled, int timeout_ms);
static int nvme_submit_admin_cmd(struct nvme_dev_ctx *ctx, void *sqe, void *cqe_out);
static int nvme_identify(struct nvme_dev_ctx *ctx, uint32_t nsid);
static int nvme_create_io_queues(struct nvme_dev_ctx *ctx, uint16_t io_qid,
                                 uint64_t io_sq_phys, uint64_t io_cq_phys);
static int nvme_delete_io_queues(struct nvme_dev_ctx *ctx, uint16_t io_qid);
static void nvme_write_device_info(volatile struct nvme_fpga_cnfg_regs *cnfg,
                                   struct nvme_device_state *ds,
                                   uint64_t fpga_bar_base);
static void nvme_write_permission(volatile struct nvme_fpga_cnfg_regs *cnfg,
                                  uint32_t region_id, uint32_t dev_id,
                                  uint64_t lba_offset, uint64_t lba_count,
                                  uint32_t lba_size);

/* ============================================================
 * Find or create a device in the global manager
 * ============================================================ */
static struct nvme_device_state *nvme_find_device(struct nvme_manager *mgr,
                                                  const char *bdf, uint32_t nsid)
{
    int i;
    for (i = 0; i < mgr->num_devices; i++) {
        if (mgr->devices[i].active &&
            strncmp(mgr->devices[i].bdf, bdf, 16) == 0 &&
            mgr->devices[i].nsid == nsid)
            return &mgr->devices[i];
    }
    return NULL;
}

static struct nvme_device_state *nvme_alloc_device(struct nvme_manager *mgr)
{
    if (mgr->num_devices >= MAX_NVME_DEVICES)
        return NULL;
    return &mgr->devices[mgr->num_devices]; /* caller increments num_devices */
}

/* ============================================================
 * PCI device discovery and BAR0 mapping
 * ============================================================ */
static int nvme_open_pci(struct nvme_dev_ctx *ctx, const char *bdf)
{
    unsigned int domain = 0, bus = 0, slot = 0, func = 0;
    struct pci_dev *pdev;
    int ret;
    uint64_t cap;

    if (sscanf(bdf, "%x:%x:%x.%x", &domain, &bus, &slot, &func) != 4) {
        domain = 0;
        if (sscanf(bdf, "%x:%x.%x", &bus, &slot, &func) != 3) {
            pr_err("nvme_open_pci: invalid BDF: %s\n", bdf);
            return -EINVAL;
        }
    }

    pdev = pci_get_domain_bus_and_slot(domain, bus, PCI_DEVFN(slot, func));
    if (!pdev) {
        pr_err("nvme_open_pci: device not found: %s\n", bdf);
        return -ENODEV;
    }

    if ((pdev->class >> 8) != 0x0108) { /* NVMe class */
        pr_err("nvme_open_pci: not an NVMe device (class=0x%06x)\n", pdev->class);
        pci_dev_put(pdev);
        return -EINVAL;
    }

    if (pdev->driver) {
        pr_err("nvme_open_pci: device bound to '%s', unbind first\n", pdev->driver->name);
        pci_dev_put(pdev);
        return -EBUSY;
    }

    /* Wake device from D3cold (needed after rmmod nvme / unbind) */
    dbg_info("nvme_open_pci: power state: D%d, calling pm_runtime_get_sync\n",
             pdev->current_state);
    ret = pm_runtime_get_sync(&pdev->dev);
    if (ret < 0 && ret != -EACCES) {
        dbg_info("nvme_open_pci: pm_runtime_get_sync returned %d, continuing\n", ret);
        pm_runtime_put_noidle(&pdev->dev);
    }

    /* Verify PCIe link is up (vendor != 0xFFFF) */
    {
        uint16_t vendor;
        pci_read_config_word(pdev, PCI_VENDOR_ID, &vendor);
        dbg_info("nvme_open_pci: vendor ID after PM resume: 0x%04x\n", vendor);
        if (vendor == 0xFFFF) {
            pr_err("nvme_open_pci: device not reachable (vendor=0xFFFF, PCIe link down)\n");
            pr_err("nvme_open_pci: try: echo 1 > /sys/bus/pci/devices/%s/remove && echo 1 > /sys/bus/pci/rescan\n", bdf);
            pm_runtime_put(&pdev->dev);
            pci_dev_put(pdev);
            return -ENODEV;
        }
    }

    ret = pci_enable_device_mem(pdev);
    if (ret) {
        pr_err("nvme_open_pci: pci_enable_device_mem failed\n");
        pm_runtime_put(&pdev->dev);
        pci_dev_put(pdev);
        return ret;
    }

    pci_set_master(pdev);

    /* Set DMA mask for 64-bit addressing */
    ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
    if (ret) {
        ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
        if (ret) {
            pr_err("nvme_open_pci: dma_set_mask failed\n");
            pci_disable_device(pdev);
            pm_runtime_put(&pdev->dev);
            pci_dev_put(pdev);
            return ret;
        }
    }

    ctx->bar0_phys = pci_resource_start(pdev, 0);
    ctx->bar0_size = pci_resource_len(pdev, 0);
    ctx->bar0 = pci_iomap(pdev, 0, ctx->bar0_size);
    if (!ctx->bar0) {
        pr_err("nvme_open_pci: pci_iomap failed\n");
        pci_disable_device(pdev);
        pci_dev_put(pdev);
        return -ENOMEM;
    }
    ctx->pdev = pdev;

    cap = readq(ctx->bar0 + NVME_REG_CAP);
    ctx->db_stride = 4 << ((cap >> 32) & 0xF);

    dbg_info("nvme_open_pci: BAR0=0x%llx, size=%zu, stride=%u\n",
             ctx->bar0_phys, ctx->bar0_size, ctx->db_stride);
    return 0;
}

static void nvme_close_pci(struct nvme_dev_ctx *ctx)
{
    if (ctx->bar0) {
        pci_iounmap(ctx->pdev, ctx->bar0);
        ctx->bar0 = NULL;
    }
    if (ctx->pdev) {
        pci_clear_master(ctx->pdev);
        pci_disable_device(ctx->pdev);
        pm_runtime_put(&ctx->pdev->dev);
        pci_dev_put(ctx->pdev);
        ctx->pdev = NULL;
    }
}

/* ============================================================
 * Admin queue management
 * ============================================================ */
static int nvme_create_admin_queue(struct nvme_dev_ctx *ctx)
{
    struct pci_dev *pdev = ctx->pdev;

    ctx->asq_virt = dma_alloc_coherent(&pdev->dev,
                                        NVME_ADMIN_QUEUE_SIZE * 64,
                                        &ctx->asq_dma, GFP_KERNEL);
    if (!ctx->asq_virt)
        return -ENOMEM;

    ctx->acq_virt = dma_alloc_coherent(&pdev->dev,
                                        NVME_ADMIN_QUEUE_SIZE * 16,
                                        &ctx->acq_dma, GFP_KERNEL);
    if (!ctx->acq_virt) {
        dma_free_coherent(&pdev->dev, NVME_ADMIN_QUEUE_SIZE * 64,
                          ctx->asq_virt, ctx->asq_dma);
        return -ENOMEM;
    }

    memset(ctx->asq_virt, 0, NVME_ADMIN_QUEUE_SIZE * 64);
    memset(ctx->acq_virt, 0, NVME_ADMIN_QUEUE_SIZE * 16);
    ctx->asq_tail = 0;
    ctx->acq_head = 0;
    ctx->acq_phase = 1;
    ctx->admin_cid = 0;
    return 0;
}

static void nvme_destroy_admin_queue(struct nvme_dev_ctx *ctx)
{
    struct pci_dev *pdev = ctx->pdev;
    if (ctx->asq_virt) {
        dma_free_coherent(&pdev->dev, NVME_ADMIN_QUEUE_SIZE * 64,
                          ctx->asq_virt, ctx->asq_dma);
        ctx->asq_virt = NULL;
    }
    if (ctx->acq_virt) {
        dma_free_coherent(&pdev->dev, NVME_ADMIN_QUEUE_SIZE * 16,
                          ctx->acq_virt, ctx->acq_dma);
        ctx->acq_virt = NULL;
    }
}

/* ============================================================
 * Controller enable / disable / wait
 * ============================================================ */
static int nvme_wait_ready(struct nvme_dev_ctx *ctx, bool enabled, int timeout_ms)
{
    int waited = 0;
    uint32_t csts;

    while (waited < timeout_ms) {
        csts = readl(ctx->bar0 + NVME_REG_CSTS);

        /* Only check CFS when waiting for enable, not during disable.
         * Per NVMe spec: after CFS, host should reset CC.EN=0 to recover.
         * Checking CFS during disable would prevent recovery. */
        if (enabled && (csts & NVME_CSTS_CFS)) {
            pr_err("nvme_wait_ready: controller fatal status (CSTS=0x%x)\n", csts);
            return -EIO;
        }

        if (((csts & NVME_CSTS_RDY) != 0) == enabled)
            return 0;

        msleep(10);
        waited += 10;
    }
    pr_err("nvme_wait_ready: timeout (CSTS=0x%x, wanted %s)\n",
           csts, enabled ? "ready" : "not-ready");
    return -ETIMEDOUT;
}

static int nvme_enable_controller(struct nvme_dev_ctx *ctx)
{
    uint32_t cc, csts;
    int ret;

    /* Always disable first — handles CFS, stale state, etc. */
    cc = readl(ctx->bar0 + NVME_REG_CC);
    csts = readl(ctx->bar0 + NVME_REG_CSTS);
    dbg_info("nvme_enable: initial CC=0x%x, CSTS=0x%x\n", cc, csts);

    if (cc & NVME_CC_EN) {
        writel(0, ctx->bar0 + NVME_REG_CC);
        ret = nvme_wait_ready(ctx, false, 5000);
        if (ret) {
            pr_warn("nvme_enable: disable timed out, attempting subsystem reset\n");
            /* Try writing 0 again and wait longer */
            writel(0, ctx->bar0 + NVME_REG_CC);
            msleep(500);
        }
    } else if (csts & NVME_CSTS_CFS) {
        /* Controller not enabled but in fatal state — force CC=0 to reset */
        pr_warn("nvme_enable: CFS set while disabled, resetting\n");
        writel(0, ctx->bar0 + NVME_REG_CC);
        msleep(500);
    }

    /* Ensure CC.EN is 0 and wait for RDY to clear */
    writel(0, ctx->bar0 + NVME_REG_CC);
    ret = nvme_wait_ready(ctx, false, 5000);
    if (ret) {
        pr_err("nvme_enable: controller stuck, cannot disable\n");
        return ret;
    }

    /* Configure admin queues */
    writel(((NVME_ADMIN_QUEUE_SIZE - 1) << 16) | (NVME_ADMIN_QUEUE_SIZE - 1),
           ctx->bar0 + NVME_REG_AQA);
    writeq(ctx->asq_dma, ctx->bar0 + NVME_REG_ASQ);
    writeq(ctx->acq_dma, ctx->bar0 + NVME_REG_ACQ);

    /* Enable */
    cc = NVME_CC_EN | NVME_CC_CSS_NVM | NVME_CC_MPS_4K |
         NVME_CC_AMS_RR | NVME_CC_SHN_NONE |
         NVME_CC_IOSQES | NVME_CC_IOCQES;
    writel(cc, ctx->bar0 + NVME_REG_CC);

    ret = nvme_wait_ready(ctx, true, 5000);
    if (ret) {
        csts = readl(ctx->bar0 + NVME_REG_CSTS);
        pr_err("nvme_enable: failed to become ready, CSTS=0x%x\n", csts);
        return ret;
    }

    dbg_info("nvme_enable_controller: success\n");
    return 0;
}

static int nvme_disable_controller(struct nvme_dev_ctx *ctx)
{
    uint32_t cc = readl(ctx->bar0 + NVME_REG_CC);
    writel(cc & ~NVME_CC_EN, ctx->bar0 + NVME_REG_CC);
    return nvme_wait_ready(ctx, false, 5000);
}

/* ============================================================
 * Admin command submission
 * ============================================================ */
static int nvme_submit_admin_cmd_timeout(struct nvme_dev_ctx *ctx, void *sqe,
                                         void *cqe_out, int timeout_ms)
{
    uint32_t *cqe;
    int timeout = timeout_ms;

    mutex_lock(&ctx->lock);

    memcpy(ctx->asq_virt + ctx->asq_tail * 64, sqe, 64);
    ctx->asq_tail = (ctx->asq_tail + 1) % NVME_ADMIN_QUEUE_SIZE;
    writel(ctx->asq_tail, ctx->bar0 + NVME_REG_DOORBELL);

    while (timeout > 0) {
        cqe = (uint32_t *)(ctx->acq_virt + ctx->acq_head * 16);
        uint8_t phase = (cqe[3] >> 16) & 1;
        if (phase == ctx->acq_phase) {
            if (cqe_out)
                memcpy(cqe_out, cqe, 16);

            ctx->acq_head = (ctx->acq_head + 1) % NVME_ADMIN_QUEUE_SIZE;
            if (ctx->acq_head == 0)
                ctx->acq_phase ^= 1;

            writel(ctx->acq_head, ctx->bar0 + NVME_REG_DOORBELL + ctx->db_stride);
            mutex_unlock(&ctx->lock);

            uint16_t status = (cqe[3] >> 17) & 0x7FF;
            if (status) {
                pr_err("nvme admin cmd status=0x%x\n", status);
                return -EIO;
            }
            return 0;
        }
        msleep(1);
        timeout--;
    }

    mutex_unlock(&ctx->lock);
    pr_warn("nvme admin cmd timeout (%d ms)\n", timeout_ms);
    return -ETIMEDOUT;
}

static int nvme_submit_admin_cmd(struct nvme_dev_ctx *ctx, void *sqe, void *cqe_out)
{
    return nvme_submit_admin_cmd_timeout(ctx, sqe, cqe_out, 2000);
}

/* ============================================================
 * Identify controller & namespace
 * ============================================================ */
static int nvme_identify(struct nvme_dev_ctx *ctx, uint32_t nsid)
{
    void *buf;
    dma_addr_t buf_dma;
    uint32_t sqe[16] = {0};
    int ret;

    buf = dma_alloc_coherent(&ctx->pdev->dev, 4096, &buf_dma, GFP_KERNEL);
    if (!buf)
        return -ENOMEM;

    /* Identify Controller (CNS=1) */
    sqe[0] = NVME_ADMIN_IDENTIFY | (ctx->admin_cid++ << 16);
    sqe[6] = (uint32_t)buf_dma;
    sqe[7] = (uint32_t)(buf_dma >> 32);
    sqe[10] = 1; /* CNS=1 */

    ret = nvme_submit_admin_cmd(ctx, sqe, NULL);
    if (ret)
        goto out;

    {
        uint8_t *d = (uint8_t *)buf;
        uint8_t mdts_pow = d[77];
        ctx->mdts = mdts_pow ? ((1U << mdts_pow) * 4096) : 0;
        dbg_info("nvme identify: MDTS=%u bytes\n", ctx->mdts);
    }

    /* Identify Namespace (CNS=0) */
    memset(sqe, 0, 64);
    sqe[0] = NVME_ADMIN_IDENTIFY | (ctx->admin_cid++ << 16);
    sqe[1] = nsid;
    sqe[6] = (uint32_t)buf_dma;
    sqe[7] = (uint32_t)(buf_dma >> 32);
    sqe[10] = 0; /* CNS=0 */

    ret = nvme_submit_admin_cmd(ctx, sqe, NULL);
    if (ret)
        goto out;

    {
        uint64_t *ns64 = (uint64_t *)buf;
        uint8_t *ns8 = (uint8_t *)buf;
        ctx->nsze = ns64[0];
        ctx->nsid = nsid;

        uint8_t flbas = ns8[26] & 0xF;
        uint32_t *lbaf_p = (uint32_t *)(ns8 + 128 + flbas * 4);
        uint8_t lbads = (*lbaf_p >> 16) & 0xFF;
        ctx->lba_size = 1U << lbads;

        dbg_info("nvme identify ns: nsze=%llu, lba_size=%u\n",
                 ctx->nsze, ctx->lba_size);
    }

out:
    dma_free_coherent(&ctx->pdev->dev, 4096, buf, buf_dma);
    return ret;
}

/* ============================================================
 * I/O queue creation / deletion (in FPGA BRAM)
 * ============================================================ */
static int nvme_create_io_queues(struct nvme_dev_ctx *ctx, uint16_t io_qid,
                                 uint64_t io_sq_phys, uint64_t io_cq_phys)
{
    uint32_t sqe[16] = {0};
    int ret;

    /* Create I/O CQ */
    sqe[0] = NVME_ADMIN_CREATE_IO_CQ | (ctx->admin_cid++ << 16);
    sqe[6] = (uint32_t)io_cq_phys;
    sqe[7] = (uint32_t)(io_cq_phys >> 32);
    sqe[10] = (io_qid & 0xFFFF) | (((NVME_IO_QUEUE_SIZE - 1) & 0xFFFF) << 16);
    sqe[11] = 1; /* PC=1 */

    ret = nvme_submit_admin_cmd(ctx, sqe, NULL);
    if (ret)
        return ret;

    /* Create I/O SQ */
    memset(sqe, 0, 64);
    sqe[0] = NVME_ADMIN_CREATE_IO_SQ | (ctx->admin_cid++ << 16);
    sqe[6] = (uint32_t)io_sq_phys;
    sqe[7] = (uint32_t)(io_sq_phys >> 32);
    sqe[10] = (io_qid & 0xFFFF) | (((NVME_IO_QUEUE_SIZE - 1) & 0xFFFF) << 16);
    sqe[11] = 1 | (io_qid << 16); /* PC=1, CQID */

    ret = nvme_submit_admin_cmd(ctx, sqe, NULL);
    if (ret) {
        /* Cleanup CQ on failure */
        memset(sqe, 0, 64);
        sqe[0] = NVME_ADMIN_DELETE_IO_CQ | (ctx->admin_cid++ << 16);
        sqe[10] = io_qid;
        nvme_submit_admin_cmd(ctx, sqe, NULL);
    }
    return ret;
}

static int nvme_delete_io_queues_timeout(struct nvme_dev_ctx *ctx,
                                         uint16_t io_qid, int timeout_ms)
{
    uint32_t sqe[16] = {0};

    sqe[0] = NVME_ADMIN_DELETE_IO_SQ | (ctx->admin_cid++ << 16);
    sqe[10] = io_qid;
    nvme_submit_admin_cmd_timeout(ctx, sqe, NULL, timeout_ms);

    memset(sqe, 0, 64);
    sqe[0] = NVME_ADMIN_DELETE_IO_CQ | (ctx->admin_cid++ << 16);
    sqe[10] = io_qid;
    nvme_submit_admin_cmd_timeout(ctx, sqe, NULL, timeout_ms);
    return 0;
}

static int nvme_delete_io_queues(struct nvme_dev_ctx *ctx, uint16_t io_qid)
{
    return nvme_delete_io_queues_timeout(ctx, io_qid, 2000);
}

/* ============================================================
 * FPGA register writes
 * ============================================================ */
static void nvme_write_device_info(volatile struct nvme_fpga_cnfg_regs *cnfg,
                                   struct nvme_device_state *ds,
                                   uint64_t fpga_bar_base)
{
    struct nvme_dev_ctx *ctx = &ds->ctx;
    uint64_t sq_db = ctx->bar0_phys + NVME_REG_DOORBELL
                     + (2 * ds->io_qid * ctx->db_stride);

    cnfg->fpga_bar_base = fpga_bar_base;
    cnfg->dev_id = ds->dev_id;
    cnfg->nsid = ctx->nsid;
    cnfg->lbaf = ffs(ctx->lba_size) - 1; /* log2(lba_size) */
    cnfg->nsze = ctx->nsze;
    cnfg->doorbell_base = sq_db;
    cnfg->valid_nvme_info = 3; /* valid + reset_queue */

    dbg_info("nvme_write_device_info: dev_id=%u, doorbell=0x%llx, lbaf=%u\n",
             ds->dev_id, sq_db, ffs(ctx->lba_size) - 1);
}

static void nvme_write_permission(volatile struct nvme_fpga_cnfg_regs *cnfg,
                                  uint32_t region_id, uint32_t dev_id,
                                  uint64_t lba_offset, uint64_t lba_count,
                                  uint32_t lba_size)
{
    /*
     * HDL pipeline works in bytes: naddr and len are byte values,
     * and nvme_s1 converts to LBAs via >> lbaf_shift.
     * Permission table must also store byte values so the comparison
     *   (naddr + len) <= perm_table.lba_size
     * uses consistent units.
     */
    uint64_t offset_bytes = lba_offset * lba_size;
    uint64_t size_bytes   = lba_count  * lba_size;

    cnfg->perm_region_id = region_id;
    cnfg->perm_dev_id = dev_id;
    cnfg->perm_lba_offset = offset_bytes;
    cnfg->perm_lba_size = size_bytes;
    cnfg->perm_valid = 1; /* commit */

    dbg_info("nvme_write_perm: region=%u, dev=%u, offset=%llu (%llu LBAs), size=%llu (%llu LBAs)\n",
             region_id, dev_id, offset_bytes, lba_offset, size_bytes, lba_count);
}

/* ============================================================
 * Public API: nvme_init_for_region
 * Called from IOCTL_NVME_INIT
 * ============================================================ */
int nvme_init_for_region(struct vfpga_dev *device, struct nvme_init_ioctl *req)
{
    struct bus_driver_data *bd = device->bd_data;
    struct nvme_manager *mgr = bd->nvme_mgr;
    volatile struct nvme_fpga_cnfg_regs *cnfg;
    struct nvme_device_state *ds;
    uint64_t lba_count, lba_offset;
    int region_id = device->id;
    int ret;

    if (!mgr) {
        req->result = -ENODEV;
        return -ENODEV;
    }

    cnfg = (volatile struct nvme_fpga_cnfg_regs *)bd->nvme_cnfg_regs;
    if (!cnfg) {
        req->result = -ENODEV;
        return -ENODEV;
    }

    mutex_lock(&mgr->lock);

    /* 1. Find or create the device */
    ds = nvme_find_device(mgr, req->bdf, req->nsid);
    if (ds) {
        /* Device already initialized — just add permission */
        dbg_info("nvme_init: reusing dev_id=%u for bdf=%s\n",
                 ds->dev_id, req->bdf);
    } else {
        /* New device */
        ds = nvme_alloc_device(mgr);
        if (!ds) {
            mutex_unlock(&mgr->lock);
            req->result = -ENOSPC;
            return -ENOSPC;
        }

        ds->dev_id = mgr->num_devices;
        strncpy(ds->bdf, req->bdf, 16);
        ds->nsid = req->nsid;
        ds->next_free_lba = 0;
        ds->io_qid = 1 + ds->dev_id;
        ds->io_sq_phys = bd->bar_phys_addr[BAR_SHELL_CONFIG]
                         + NVME_SQ_BASE + ds->dev_id * NVME_SQ_SIZE;
        ds->io_cq_phys = bd->bar_phys_addr[BAR_SHELL_CONFIG]
                         + NVME_CQ_BASE + ds->dev_id * NVME_CQ_SIZE;

        mutex_init(&ds->ctx.lock);

        /* PCI init */
        ret = nvme_open_pci(&ds->ctx, req->bdf);
        if (ret) goto err_pci;

        ret = nvme_create_admin_queue(&ds->ctx);
        if (ret) goto err_admin;

        ret = nvme_enable_controller(&ds->ctx);
        if (ret) goto err_enable;

        ret = nvme_identify(&ds->ctx, req->nsid);
        if (ret) goto err_identify;

        ret = nvme_create_io_queues(&ds->ctx, ds->io_qid,
                                    ds->io_sq_phys, ds->io_cq_phys);
        if (ret) goto err_io;

        /* Write device info to FPGA */
        nvme_write_device_info(cnfg, ds, bd->bar_phys_addr[BAR_SHELL_CONFIG]);

        ds->active = true;
        ds->ctx.initialized = true;
        mgr->num_devices++;
    }

    /* 2. Bump-allocate LBA range for this region */
    lba_count = req->size / ds->ctx.lba_size;
    if (lba_count == 0)
        lba_count = ds->ctx.nsze; /* size=0 means whole namespace */

    lba_offset = ds->next_free_lba;
    if (lba_offset + lba_count > ds->ctx.nsze) {
        mutex_unlock(&mgr->lock);
        pr_err("nvme_init: not enough LBAs (need %llu, have %llu)\n",
               lba_count, ds->ctx.nsze - lba_offset);
        req->result = -ENOSPC;
        return -ENOSPC;
    }
    ds->next_free_lba += lba_count;

    /* 3. Write permission to FPGA */
    nvme_write_permission(cnfg, region_id, ds->dev_id, lba_offset, lba_count,
                          ds->ctx.lba_size);

    /* 4. Save allocation */
    mgr->region_allocs[region_id][ds->dev_id].dev_id = ds->dev_id;
    mgr->region_allocs[region_id][ds->dev_id].lba_offset = lba_offset;
    mgr->region_allocs[region_id][ds->dev_id].lba_count = lba_count;
    mgr->region_allocs[region_id][ds->dev_id].active = true;

    /* 5. Fill response */
    req->result = 0;
    req->dev_id = ds->dev_id;
    req->lba_size = ds->ctx.lba_size;
    req->nsze = ds->ctx.nsze;
    req->lba_offset = lba_offset;
    req->lba_count = lba_count;
    req->sq_doorbell_addr = ds->ctx.bar0_phys + NVME_REG_DOORBELL
                            + (2 * ds->io_qid * ds->ctx.db_stride);
    req->cq_doorbell_addr = req->sq_doorbell_addr + ds->ctx.db_stride;
    req->mdts = ds->ctx.mdts;

    mutex_unlock(&mgr->lock);
    return 0;

err_io:
err_identify:
    nvme_disable_controller(&ds->ctx);
err_enable:
    nvme_destroy_admin_queue(&ds->ctx);
err_admin:
    nvme_close_pci(&ds->ctx);
err_pci:
    memset(ds, 0, sizeof(*ds));
    mutex_unlock(&mgr->lock);
    req->result = ret;
    return ret;
}

/* ============================================================
 * nvme_close_for_region — release region's allocations
 * ============================================================ */
void nvme_close_for_region(struct vfpga_dev *device, unsigned long arg)
{
    struct bus_driver_data *bd = device->bd_data;
    struct nvme_manager *mgr = bd->nvme_mgr;
    int region_id = device->id;
    int i;

    if (!mgr) return;

    mutex_lock(&mgr->lock);
    for (i = 0; i < MAX_NVME_DEVICES; i++) {
        mgr->region_allocs[region_id][i].active = false;
    }
    mutex_unlock(&mgr->lock);

    dbg_info("nvme_close: cleared allocations for region %d\n", region_id);
}

/* ============================================================
 * nvme_is_registered — check if BDF+nsid already has a dev_id
 * ============================================================ */
int nvme_is_registered(struct bus_driver_data *bd, const char *bdf,
                       uint32_t nsid, uint32_t *out_dev_id)
{
    struct nvme_manager *mgr = bd->nvme_mgr;
    struct nvme_device_state *ds;

    if (!mgr) return -ENODEV;

    mutex_lock(&mgr->lock);
    ds = nvme_find_device(mgr, bdf, nsid);
    mutex_unlock(&mgr->lock);

    if (ds) {
        *out_dev_id = ds->dev_id;
        return 0;
    }
    return -ENOENT;
}

/* ============================================================
 * Cleanup functions (called from driver remove)
 * ============================================================ */

/* Quick check: is the SSD still reachable via PCIe? */
static bool nvme_device_reachable(struct nvme_dev_ctx *ctx)
{
    uint16_t vendor;

    if (!ctx->pdev || !ctx->bar0)
        return false;

    pci_read_config_word(ctx->pdev, PCI_VENDOR_ID, &vendor);
    if (vendor == 0xFFFF)
        return false;

    /* Also check CSTS isn't all-ones (link down returns 0xFFFFFFFF) */
    if (readl(ctx->bar0 + NVME_REG_CSTS) == 0xFFFFFFFF)
        return false;

    return true;
}

void nvme_cleanup_device(struct nvme_device_state *ds, struct bus_driver_data *bd)
{
    if (!ds || !ds->active)
        return;

    if (ds->ctx.initialized) {
        /* Skip admin cmds on rmmod — SSD may already be reset by Linux NVMe driver.
         * Just release host-side resources and move on. */
        nvme_destroy_admin_queue(&ds->ctx);
        nvme_close_pci(&ds->ctx);
        ds->ctx.initialized = false;
    }
    ds->active = false;
}

void nvme_manager_cleanup(struct bus_driver_data *bd)
{
    struct nvme_manager *mgr = bd->nvme_mgr;
    int i;

    if (!mgr) return;

    for (i = 0; i < mgr->num_devices; i++) {
        nvme_cleanup_device(&mgr->devices[i], bd);
    }

    kfree(mgr);
    bd->nvme_mgr = NULL;
}

/* ============================================================
 * Debug: dump FPGA NVMe BRAM contents (SQ, CQ, PRP)
 *
 * These functions ioremap the BRAM regions, read entries,
 * and print to dmesg. Safe to call at any time.
 * ============================================================ */

/**
 * nvme_debug_dump_sq - dump IO SQ BRAM entries for a device
 * @bd: bus driver data (for BAR address)
 * @dev_id: NVMe device ID (0..15)
 * @num_entries: number of SQ entries to dump (0 = all non-zero up to queue size)
 *
 * SQE format (64 bytes = 16 DWORDs):
 *   DW0:  Opcode[7:0], FUSE[9:8], PSDT[15:14], CID[31:16]
 *   DW1:  NSID
 *   DW2-3: reserved
 *   DW4-5: MPTR
 *   DW6-7: PRP1 (64-bit)
 *   DW8-9: PRP2 (64-bit)
 *   DW10:  SLBA low (for read/write)
 *   DW11:  SLBA high (for read/write)
 *   DW12:  NLB[15:0] (for read/write)
 *   DW13-15: reserved
 */
void nvme_debug_dump_sq(struct bus_driver_data *bd, uint32_t dev_id, int num_entries)
{
    uint64_t phys = bd->bar_phys_addr[BAR_SHELL_CONFIG]
                    + NVME_SQ_BASE + dev_id * NVME_SQ_SIZE;
    void __iomem *base;
    int i, j;
    uint32_t dw[16];
    bool all_zero;

    if (dev_id >= MAX_NVME_DEVICES) {
        pr_err("nvme_debug: invalid dev_id %u\n", dev_id);
        return;
    }

    base = ioremap(phys, NVME_SQ_SIZE);
    if (!base) {
        pr_err("nvme_debug: cannot map SQ BRAM dev %u at 0x%llx\n", dev_id, phys);
        return;
    }

    if (num_entries <= 0 || num_entries > NVME_IO_QUEUE_SIZE)
        num_entries = NVME_IO_QUEUE_SIZE;

    pr_info("===== SQ BRAM dev_id=%u (phys=0x%llx, %d entries) =====\n",
            dev_id, phys, num_entries);

    for (i = 0; i < num_entries; i++) {
        all_zero = true;
        for (j = 0; j < 16; j++) {
            dw[j] = readl(base + i * 64 + j * 4);
            if (dw[j] != 0) all_zero = false;
        }
        if (all_zero) continue;

        pr_info("  SQE[%02d]: opcode=0x%02x CID=%u NSID=%u\n",
                i, dw[0] & 0xFF, dw[0] >> 16, dw[1]);
        pr_info("           PRP1=0x%08x_%08x  PRP2=0x%08x_%08x\n",
                dw[7], dw[6], dw[9], dw[8]);
        pr_info("           SLBA=0x%08x_%08x  NLB=%u\n",
                dw[11], dw[10], dw[12] & 0xFFFF);
        pr_info("           DW0-3:  %08x %08x %08x %08x\n",
                dw[0], dw[1], dw[2], dw[3]);
        pr_info("           DW4-7:  %08x %08x %08x %08x\n",
                dw[4], dw[5], dw[6], dw[7]);
        pr_info("           DW8-11: %08x %08x %08x %08x\n",
                dw[8], dw[9], dw[10], dw[11]);
        pr_info("           DW12-15:%08x %08x %08x %08x\n",
                dw[12], dw[13], dw[14], dw[15]);
    }

    iounmap(base);
}

/**
 * nvme_debug_dump_cq - dump IO CQ BRAM entries for a device
 * @bd: bus driver data
 * @dev_id: NVMe device ID (0..15)
 * @num_entries: number of CQ entries to dump (0 = all non-zero)
 *
 * CQE format (16 bytes = 4 DWORDs):
 *   DW0:  Command specific
 *   DW1:  Reserved
 *   DW2:  SQ Head[15:0], SQ ID[31:16]
 *   DW3:  CID[15:0], Phase[16], Status[30:17]
 */
void nvme_debug_dump_cq(struct bus_driver_data *bd, uint32_t dev_id, int num_entries)
{
    uint64_t phys = bd->bar_phys_addr[BAR_SHELL_CONFIG]
                    + NVME_CQ_BASE + dev_id * NVME_CQ_SIZE;
    void __iomem *base;
    int i;
    uint32_t dw[4];
    bool all_zero;

    if (dev_id >= MAX_NVME_DEVICES) {
        pr_err("nvme_debug: invalid dev_id %u\n", dev_id);
        return;
    }

    base = ioremap(phys, NVME_CQ_SIZE);
    if (!base) {
        pr_err("nvme_debug: cannot map CQ BRAM dev %u at 0x%llx\n", dev_id, phys);
        return;
    }

    /* Find the last non-zero CQE */
    {
        int last = -1;
        for (i = NVME_IO_QUEUE_SIZE - 1; i >= 0; i--) {
            uint32_t t = readl(base + i * 16) | readl(base + i * 16 + 4)
                       | readl(base + i * 16 + 8) | readl(base + i * 16 + 12);
            if (t) { last = i; break; }
        }

        pr_info("===== CQ BRAM dev_id=%u (last entry) =====\n", dev_id);
        if (last < 0) {
            pr_info("  (empty)\n");
        } else {
            dw[0] = readl(base + last * 16 + 0);
            dw[1] = readl(base + last * 16 + 4);
            dw[2] = readl(base + last * 16 + 8);
            dw[3] = readl(base + last * 16 + 12);
            pr_info("  CQE[%02d]: CID=%u  Phase=%u  Status=0x%03x  SQHead=%u  SQID=%u\n",
                    last,
                    dw[3] & 0xFFFF,
                    (dw[3] >> 16) & 1,
                    (dw[3] >> 17) & 0x7FF,
                    dw[2] & 0xFFFF,
                    (dw[2] >> 16) & 0xFFFF);
            pr_info("           DW0-3: %08x %08x %08x %08x\n",
                    dw[0], dw[1], dw[2], dw[3]);
        }
    }

    iounmap(base);
}

/**
 * nvme_debug_dump_prp - dump PRP BRAM entries for a device
 * @bd: bus driver data
 * @dev_id: NVMe device ID (0..15)
 * @num_entries: number of 64-bit PRP entries to dump (0 = first 64 non-zero)
 *
 * PRP BRAM layout: 256KB per device, each entry is 8 bytes (64-bit phys addr).
 * Organized as [queue_idx][prp_entry] by the HDL.
 */
void nvme_debug_dump_prp(struct bus_driver_data *bd, uint32_t dev_id, int num_entries)
{
    uint64_t phys = bd->bar_phys_addr[BAR_SHELL_CONFIG]
                    + NVME_PRP_BASE + dev_id * NVME_PRP_SIZE;
    void __iomem *base;
    int i;
    uint32_t lo, hi;
    uint64_t addr;

    if (dev_id >= MAX_NVME_DEVICES) {
        pr_err("nvme_debug: invalid dev_id %u\n", dev_id);
        return;
    }

    /* Map only what we need (up to 4KB for first entries) */
    size_t map_size = (num_entries <= 0) ? 4096 : (num_entries * 8);
    if (map_size > NVME_PRP_SIZE) map_size = NVME_PRP_SIZE;

    base = ioremap(phys, map_size);
    if (!base) {
        pr_err("nvme_debug: cannot map PRP BRAM dev %u at 0x%llx\n", dev_id, phys);
        return;
    }

    if (num_entries <= 0)
        num_entries = 64;

    pr_info("===== PRP BRAM dev_id=%u (phys=0x%llx, %d entries) =====\n",
            dev_id, phys, num_entries);

    for (i = 0; i < num_entries; i++) {
        lo = readl(base + i * 8);
        hi = readl(base + i * 8 + 4);
        addr = ((uint64_t)hi << 32) | lo;
        if (addr == 0) continue;
        pr_info("  PRP[%03d]: 0x%016llx\n", i, addr);
    }

    iounmap(base);
}

/**
 * nvme_debug_dump_cnfg - dump NVMe config registers
 * @bd: bus driver data
 */
void nvme_debug_dump_cnfg(struct bus_driver_data *bd)
{
    volatile uint64_t *regs = bd->nvme_cnfg_regs;
    int i;

    if (!regs) {
        pr_err("nvme_debug: nvme_cnfg_regs not mapped\n");
        return;
    }

    pr_info("===== NVMe CNFG registers =====\n");
    for (i = 0; i < 32; i++) {
        uint64_t val = regs[i];
        if (val != 0)
            pr_info("  cnfg[%02d] = 0x%016llx\n", i, val);
    }
}

/**
 * nvme_debug_dump_all - dump everything for a device
 * @bd: bus driver data
 * @dev_id: NVMe device ID
 */
void nvme_debug_dump_all(struct bus_driver_data *bd, uint32_t dev_id)
{
    struct nvme_manager *mgr = bd->nvme_mgr;

    pr_info("============ NVMe DEBUG DUMP dev_id=%u ============\n", dev_id);

    /* Device state */
    if (mgr && dev_id < mgr->num_devices && mgr->devices[dev_id].active) {
        struct nvme_device_state *ds = &mgr->devices[dev_id];
        struct nvme_dev_ctx *ctx = &ds->ctx;
        pr_info("  BDF=%s  nsid=%u  io_qid=%u  lba_size=%u  nsze=%llu\n",
                ds->bdf, ds->nsid, ds->io_qid, ctx->lba_size, ctx->nsze);
        pr_info("  io_sq_phys=0x%llx  io_cq_phys=0x%llx\n",
                ds->io_sq_phys, ds->io_cq_phys);
        pr_info("  bar0_phys=0x%llx  db_stride=%u\n",
                ctx->bar0_phys, ctx->db_stride);

        /* SSD-side registers (if bar0 still mapped) */
        if (ctx->bar0) {
            uint64_t cap = readq(ctx->bar0 + 0x00);
            uint32_t cc  = readl(ctx->bar0 + 0x14);
            uint32_t csts = readl(ctx->bar0 + 0x1C);
            pr_info("  SSD regs: CAP=0x%016llx  CC=0x%08x  CSTS=0x%08x\n",
                    cap, cc, csts);
        }
    }

    nvme_debug_dump_cnfg(bd);
    nvme_debug_dump_sq(bd, dev_id, 0);
    nvme_debug_dump_cq(bd, dev_id, 0);
    nvme_debug_dump_prp(bd, dev_id, 64);

    pr_info("============ END DEBUG DUMP ============\n");
}
