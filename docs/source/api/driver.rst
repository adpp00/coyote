
Device driver
===================================

coyote_driver.h
------------------------------------
.. doxygenfile:: coyote_driver.h 
   :project: docs-driver


coyote_setup.h
------------------------------------
.. doxygenfile:: coyote_setup.h 
   :project: docs-driver

coyote_sysfs.h
------------------------------------
.. doxygenfile:: coyote_sysfs.h 
   :project: docs-driver

coyote_nvme.h
------------------------------------
.. doxygenfile:: coyote_nvme.h
   :project: docs-driver

.. _nvme-ioctls:

NVMe IOCTLs
------------------------------------
If the loaded shell includes the NVMe stack (``EN_NVME=1``), the vFPGA device files accept three additional ioctls, defined in ``coyote_defs.h`` and mirrored in ``cDefs.hpp``.
In shells without NVMe they fail with ``EOPNOTSUPP``.
Each ioctl acts on the vFPGA (region) of the device file it is issued on. For the hardware side, see :ref:`nvme-storage`.

============================ ============================== ================== ===========================================================================================
IOCTL                        Argument                       Privilege          Description
============================ ============================== ================== ===========================================================================================
``IOCTL_NVME_INIT``          ``struct nvme_init_ioctl``     ``CAP_SYS_ADMIN``  Claim the SSD (on first use), reserve an LBA range for the region and grant it in hardware.
``IOCTL_NVME_CLOSE``         ``uint64_t dev_id``            ``CAP_SYS_ADMIN``  Revoke the region's permission for ``dev_id`` and free its range. A ``dev_id`` of ``MAX_NVME_DEVICES`` (16) or more releases all ranges of the region.
``IOCTL_NVME_IS_REGISTERED`` ``struct nvme_init_ioctl``     None               Look up (``bdf``, ``nsid``) in the calling region's allocations.
============================ ============================== ================== ===========================================================================================

``struct nvme_init_ioctl`` (``nvmeInitIoctl`` in the software library) is a packed struct with the following fields:

==================== ========== ======== ======================================================================================================
Field                Type       Use      Description
==================== ========== ======== ======================================================================================================
``bdf``              char[16]   In       PCI address of the SSD, ``DDDD:BB:DD.F`` or ``BB:DD.F`` (hexadecimal). Ignored for PL-attached SSDs.
``nsid``             uint32_t   In       Namespace ID. For PL-attached SSDs, it must match the namespace identified by the setup engine (1).
``size``             uint64_t   In       Requested range in bytes (``IOCTL_NVME_INIT`` only), rounded down to whole LBAs; less than one LBA reserves the whole namespace.
``result``           int32_t    Out      0 on success, negative errno otherwise. ``IOCTL_NVME_IS_REGISTERED`` sets ``-ENOENT`` if not registered.
``dev_id``           uint32_t   Out      Device ID, used in the ``dev_id`` field of ``nvme_req_t``.
``lba_size``         uint32_t   Out      LBA size in bytes.
``nsze``             uint64_t   Out      Namespace size in LBAs.
``lba_offset``       uint64_t   Out      First LBA of the region's range.
``lba_count``        uint64_t   Out      Number of LBAs in the region's range.
``sq_doorbell_addr`` uint64_t   Out      Bus address of the I/O SQ doorbell (informational).
``cq_doorbell_addr`` uint64_t   Out      Bus address of the I/O CQ doorbell (informational).
``mdts``             uint32_t   Out      Maximum data transfer size of the SSD in bytes; 0 if the SSD reports no limit.
``queue_depth``      uint32_t   Out      Entries per I/O queue (``NVME_QUEUE_DEPTH``); at most ``queue_depth - 1`` commands are queued per device.
==================== ========== ======== ======================================================================================================

``IOCTL_NVME_INIT`` copies the struct back only on success, so the cause of a failure is the ioctl's ``errno``:

* ``EPERM``: the caller lacks ``CAP_SYS_ADMIN``.
* ``EBUSY``: the SSD is bound to a kernel driver (e.g., ``nvme``), or the region already holds a range on this device; call ``IOCTL_NVME_CLOSE`` first.
* ``ENODEV``: no PCI device at ``bdf``, or the device is not reachable (PCIe link down).
* ``EINVAL``: malformed ``bdf``, the device is not an NVMe controller, the shell's queue depth exceeds the SSD's maximum (``CAP.MQES``), or (PL) the namespace does not match.
* ``ENOSPC``: all ``NVME_NUM_DEVICES`` device slots of the shell are in use, or the namespace has no free range of the requested size.
* ``EIO``, ``ETIMEDOUT``: an admin command failed or timed out, or (PL) the setup engine reported an error or did not finish within 30 seconds.

``IOCTL_NVME_IS_REGISTERED`` succeeds whether or not the device is registered, and only reports this through ``result``; on success, the output fields describe the calling region's range.
``IOCTL_NVME_CLOSE`` on a device without an allocation in the region does nothing and succeeds.
Allocations that are still held when the last handle to the vFPGA device file is closed (for example, when the process exits) are released in the same way as by ``IOCTL_NVME_CLOSE``.
A claimed host-attached SSD stays claimed, with its controller enabled and its I/O queues in place, until the shell is removed (driver unload or shell reconfiguration).
Its device ID is therefore stable across processes until then.

vfpga_gup.h
------------------------------------
.. doxygenfile:: vfpga_gup.h 
   :project: docs-driver

vfpga_hw.h
------------------------------------
.. doxygenfile:: vfpga_hw.h 
   :project: docs-driver

vfpga_isr.h
------------------------------------
.. doxygenfile:: vfpga_isr.h 
   :project: docs-driver

vfpga_ops.h
------------------------------------
.. doxygenfile:: vfpga_ops.h 
   :project: docs-driver


vfpga_uisr.h
------------------------------------
.. doxygenfile:: vfpga_uisr.h 
   :project: docs-driver

reconfig_hw.h
------------------------------------
.. doxygenfile:: reconfig_hw.h 
   :project: docs-driver

reconfig_isr.h
------------------------------------
.. doxygenfile:: reconfig_isr.h 
   :project: docs-driver

reconfig_mem.h
------------------------------------
.. doxygenfile:: reconfig_mem.h 
   :project: docs-driver

reconfig_ops.h
------------------------------------
.. doxygenfile:: reconfig_ops.h 
   :project: docs-driver

pci_util.h
------------------------------------
.. doxygenfile:: pci_util.h 
   :project: docs-driver

pci_xdma.h
------------------------------------
.. doxygenfile:: pci_xdma.h 
   :project: docs-driver
