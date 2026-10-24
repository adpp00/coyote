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
 * @file coyote_nvme.h
 * @brief NVMe device management for the Coyote driver
 *
 * Host-connected devices use per-device PCI discovery, controller
 * initialization, admin/I/O queue setup, and per-region LBA permission
 * management. PL-connected devices use the same ioctls and permission model;
 * their controller is managed by design_plnvme, and the driver reads the
 * namespace parameters discovered by the BD through the FPGA config window.
 *
 * All entry points are only meaningful when EN_NVME is set in the loaded bitstream;
 * callers must check bd_data->en_nvme before invoking.
 */

#ifndef _COYOTE_NVME_H_
#define _COYOTE_NVME_H_

#include "coyote_defs.h"

/// Allocate and initialize bd_data->nvme_mgr; called from coyote_setup when en_nvme is true
int  nvme_mgr_init(struct bus_driver_data *bd_data);

/// Free bd_data->nvme_mgr; called during driver teardown
void nvme_mgr_free(struct bus_driver_data *bd_data);

/// Initialize NVMe access for a region; HOST uses BDF discovery, while PL consumes the block-design discovery registers
long vfpga_nvme_init(struct vfpga_dev *device, struct nvme_init_ioctl *req);

/// Revoke this region's FPGA permission for dev_id (all devices if dev_id >= MAX_NVME_DEVICES) and free its LBA range;
/// the controller stays claimed until driver teardown
long vfpga_nvme_close(struct vfpga_dev *device, uint32_t dev_id);

/// Test whether an NVMe device matching *req is registered to this region; populates the output fields when found,
/// otherwise returns 0 with req->result = -ENOENT
long vfpga_nvme_is_registered(struct vfpga_dev *device, struct nvme_init_ioctl *req);

/// Same cleanup as vfpga_nvme_close for every device; called when the last handle to the vFPGA device is released
void vfpga_nvme_release_region(struct vfpga_dev *device);

#endif // _COYOTE_NVME_H_
