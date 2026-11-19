# ============================================================
# File : sim/Makefile
# Use  : make xrun TEST=pkg_smoke   (text result)
#        make gui  TEST=fifo        (SimVision)
#        make clean                 (delete outputs)
# ============================================================

export PROJ_ROOT ?= $(abspath ..)
TEST ?= pkg_smoke
SEED ?= 1
XRUN_FLAGS := -sv -timescale 1ns/1ps -licqueue -nowarn DLCVAR -nowarn DLCPTH -svseed $(SEED)

# ---- Test table: files and top module of each test ----
pkg_smoke_FILES := -f $(PROJ_ROOT)/ip/common/common.f \
                   $(PROJ_ROOT)/ip/common/tb/pkg_smoke_tb.sv
pkg_smoke_TOP   := pkg_smoke_tb

fifo_FILES := -f $(PROJ_ROOT)/ip/dma/dma.f \
              $(PROJ_ROOT)/ip/dma/tb/dma_fifo_tb.sv                         # NEW: FIFO test
fifo_TOP   := dma_fifo_tb                                                    # NEW

FILES := $($(TEST)_FILES)
TOP   := $($(TEST)_TOP)
OUT   := out/$(TEST)

.PHONY: xrun gui clean

xrun:
	mkdir -p $(OUT)
	cd $(OUT) && xrun $(XRUN_FLAGS) $(FILES) -top $(TOP) -l xrun.log

gui:
	mkdir -p $(OUT)
	cd $(OUT) && xrun $(XRUN_FLAGS) -access +rwc -gui $(FILES) -top $(TOP) -l xrun_gui.log

clean:
	rm -rf out
	