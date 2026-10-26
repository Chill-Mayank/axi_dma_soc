# make xrun TEST = pkg_smoke
# make gui TEST = pkg_smoke
# make clean

export PROJ_ROOT ?= $(abspath ..)
TEST ?= pkg_smoke
XRUN_FLAGS := -sv -timescale 1ns/1ps -licqueue

# Test table: files and top module of each test
pkg_smoke_FILES := -f $(PROJ_ROOT)/ip/common/common.f \
				   $(PROJ_ROOT)/ip/common/tb/pkg_smoke_tb.sv
pkg_smoke_TOP := pkg_smoke_tb

FILES := $($(TEST)_FILES)
TOP := $($(TEST)_TOP)
OUT := out/$(TEST)

.PHONY: xrun gui clean
xrun:
	mkdir -p $(OUT)
	cd $(OUT) && xrun $(XRUN_FLAGS) $(FILES) -top $(TOP) -l xrun.log

gui:
	mkdir -p $(OUT)
	cd $(OUT) && xrun $(XRUN_FLAGS) -access +rwc -gui $(FILES) -top $(TOP) -l xrun_gui.log

clean:
	rm -rf out