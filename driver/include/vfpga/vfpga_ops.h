/*
 * Copyright (c) 2025,  Systems Group, ETH Zurich
 * All rights reserved.
 *
 * This file is part of the Coyote device driver for Linux.
 * Coyote can be found at: https://github.com/fpgasystems/Coyote
 *
 * This source code is free software; you can redistribute it and/or modify it
 * under the terms and conditions of the GNU General Public License,
 * version 2, as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
 * more details.
 *
 * The full GNU General Public License is included in this distribution in
 * the file called "COPYING". If not found, a copy of the GNU General Public  
 * License can be found <https://www.gnu.org/licenses/>.
 */

/**
 * @file vfpga_ops.h
 * @brief Standard device operations for the vfpga_dev char device: open, release, ioctl and memory map (mmap)
 */

#ifndef _VFPGA_OPS_H_
#define _VFPGA_OPS_H_

#include "coyote_setup.h"
#include "coyote_defs.h"
#include "vfpga_isr.h"
#include "vfpga_uisr.h"

/// vfpga_dev open char device
int vfpga_dev_open(struct inode *inode, struct file *file);

/// vfpga_dev release (close) char device
int vfpga_dev_release(struct inode *inode, struct file *file);

/// vfpga_dev IOCTL calls
long vfpga_dev_ioctl(struct file *file, unsigned int cmd, unsigned long arg);

/// vfpga_dev memory map; maps user control region, vFPGA config and writeback regions
int vfpga_dev_mmap(struct file *file, struct vm_area_struct *vma);

/* NVMe BAR0 Register Offsets */
#define NVME_REG_CAP        0x00
#define NVME_REG_VS         0x08
#define NVME_REG_CC         0x14
#define NVME_REG_CSTS       0x1C
#define NVME_REG_AQA        0x24
#define NVME_REG_ASQ        0x28
#define NVME_REG_ACQ        0x30
#define NVME_REG_DOORBELL   0x1000

/* NVMe CC bits */
#define NVME_CC_EN          (1 << 0)
#define NVME_CC_CSS_NVM     (0 << 4)
#define NVME_CC_MPS_4K      (0 << 7)
#define NVME_CC_AMS_RR      (0 << 11)
#define NVME_CC_SHN_NONE    (0 << 14)
#define NVME_CC_IOSQES      (6 << 16)
#define NVME_CC_IOCQES      (4 << 20)

/* NVMe CSTS bits */
#define NVME_CSTS_RDY       (1 << 0)
#define NVME_CSTS_CFS       (1 << 1)

/* NVMe Admin Opcodes */
#define NVME_ADMIN_IDENTIFY         0x06
#define NVME_ADMIN_CREATE_IO_CQ     0x05
#define NVME_ADMIN_CREATE_IO_SQ     0x01
#define NVME_ADMIN_DELETE_IO_SQ     0x00
#define NVME_ADMIN_DELETE_IO_CQ     0x04

/* Queue sizes */
#define NVME_ADMIN_QUEUE_SIZE   64
#define NVME_IO_QUEUE_SIZE      64

/// NVMe: init a device for a region (IOCTL handler)
int nvme_init_for_region(struct vfpga_dev *device, struct nvme_init_ioctl *req);

/// NVMe: close all allocations for a region
void nvme_close_for_region(struct vfpga_dev *device, unsigned long arg);

/// NVMe: check if BDF+nsid is already registered
int nvme_is_registered(struct bus_driver_data *bd, const char *bdf,
                       uint32_t nsid, uint32_t *out_dev_id);

/// NVMe device cleanup (called from driver remove)
void nvme_cleanup_device(struct nvme_device_state *dev_state,
                         struct bus_driver_data *bd);

/// NVMe manager cleanup
void nvme_manager_cleanup(struct bus_driver_data *bd);

#endif // _VFPGA_OPS_H_