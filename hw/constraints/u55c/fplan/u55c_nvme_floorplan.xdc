# =====================================================================
# u55c_nvme_floorplan.xdc
# ---------------------------------------------------------------------
# EN_NVME-only floorplan helper for the shell->static wback path.
#
# This file is added unconditionally with the rest of hw/constraints/u55c/fplan,
# but every constraint inside is wrapped in a Tcl `if` that checks whether the
# NVMe-only `inst_shell/inst_shell2static_wback_slice` cell exists in the
# elaborated design. When EN_NVME=0 (and en_wb=0 path on the shell template),
# that cell is not instantiated, so all the commands below are no-ops and the
# baseline build is untouched.
#
# Why this exists:
#   - WNS violator (-0.292ns) on xclk goes from
#     inst_shell/inst_shell2static_wback_slice/.../n_entries_reg[1]/C
#     to inst_static/inst_cnvrt_static/inst_wback_adj/inst_que_wb/.../count_value_i_reg[1]/CE
#   - Path is 96% route delay across an SLR boundary (slice placed at
#     SLICE_X163Y242 in SLR1; wback_adj sits at ~SLICE_X176Y72 in SLR0).
#   - Pulling the slice into SLR0 close to the static wback_adj shortens the
#     route and removes the SLR-crossing penalty.
#
# Strategy: create a small pblock (4x4 CLB-ish region) inside the existing
# shell pblock's SLR0 carve-out (SLICE_X117Y180:SLICE_X175Y239 -- see
# u55c_static_floorplan.xdc) and pull the wback slice cells into it. The
# region is placed near the high-Y / high-X corner of the SLR0 slice
# territory so it sits as close as physically possible to the static
# inst_wback_adj which lives at X~176 Y~72 (the static partition itself is
# locked and unmovable). This is a best-effort pull; if the slice's logic
# can't all fit, SNAPPING_MODE and IS_SOFT=TRUE allow Vivado to spill.
# =====================================================================

if {[llength [get_cells -quiet inst_shell/inst_shell2static_wback_slice]] > 0} {
    # Small floorplan region inside the shell pblock's SLR0 strip.
    # Shell pblock allows SLICE_X117Y180:SLICE_X175Y239 in SLR0; we take the
    # top-right corner of that strip (closest in routing terms to the static
    # wback_adj fanout which exits the static partition near X~176).
    create_pblock pblock_nvme_wback
    resize_pblock [get_pblocks pblock_nvme_wback] -add {SLICE_X168Y232:SLICE_X175Y239}
    # IS_SOFT lets the placer spill if the slice grows; the pull is advisory.
    set_property IS_SOFT TRUE   [get_pblocks pblock_nvme_wback]
    set_property SNAPPING_MODE ON [get_pblocks pblock_nvme_wback]
    # Pull every cell beneath the wback slice instance (meta_reg -> inst_reg_slice -> inst_fifo).
    add_cells_to_pblock [get_pblocks pblock_nvme_wback] \
        [get_cells -hierarchical -filter {NAME =~ "inst_shell/inst_shell2static_wback_slice/*"}] \
        -clear_locs
}
