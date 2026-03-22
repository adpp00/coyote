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
                                  uint64_t lba_offset, uint64_t lba_count);

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
static int nvme_submit_admin_cmd(struct nvme_dev_ctx *ctx, void *sqe, void *cqe_out)
{
    uint32_t *cqe;
    int timeout = 5000;

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
    pr_err("nvme admin cmd timeout\n");
    return -ETIMEDOUT;
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

static int nvme_delete_io_queues(struct nvme_dev_ctx *ctx, uint16_t io_qid)
{
    uint32_t sqe[16] = {0};

    sqe[0] = NVME_ADMIN_DELETE_IO_SQ | (ctx->admin_cid++ << 16);
    sqe[10] = io_qid;
    nvme_submit_admin_cmd(ctx, sqe, NULL);

    memset(sqe, 0, 64);
    sqe[0] = NVME_ADMIN_DELETE_IO_CQ | (ctx->admin_cid++ << 16);
    sqe[10] = io_qid;
    nvme_submit_admin_cmd(ctx, sqe, NULL);
    return 0;
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
                                  uint64_t lba_offset, uint64_t lba_count)
{
    cnfg->perm_region_id = region_id;
    cnfg->perm_dev_id = dev_id;
    cnfg->perm_lba_offset = lba_offset;
    cnfg->perm_lba_size = lba_count;
    cnfg->perm_valid = 1; /* commit */

    dbg_info("nvme_write_perm: region=%u, dev=%u, offset=%llu, count=%llu\n",
             region_id, dev_id, lba_offset, lba_count);
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
    nvme_write_permission(cnfg, region_id, ds->dev_id, lba_offset, lba_count);

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
void nvme_cleanup_device(struct nvme_device_state *ds, struct bus_driver_data *bd)
{
    if (!ds || !ds->active)
        return;

    if (ds->ctx.initialized) {
        nvme_delete_io_queues(&ds->ctx, ds->io_qid);
        nvme_disable_controller(&ds->ctx);
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
