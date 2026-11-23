#!/bin/sh
# Run a test on a laptop with Icarus Verilog (no Cadence server needed).
# Install once (Intel Mac):  sudo port install iverilog
# Use:   cd sim && sh run_icarus.sh fifo          (or: mem)
#        cd sim && sh run_icarus.sh mem waves     (also saves out/icarus/waves.vcd)
# Note:  pkg_smoke does not run on Icarus (it uses 'inside'); use the server.
set -e
cd "$(dirname "$0")"
TEST=${1:-fifo}
WAVES=${2:-}
if [ "$TEST" = "waves" ]; then TEST=fifo; WAVES=waves; fi   # old way: sh run_icarus.sh waves
case "$TEST" in
  fifo) TOP=dma_fifo_tb
        FILES="../ip/dma/rtl/dma_fifo.sv ../ip/dma/tb/dma_fifo_tb.sv" ;;
  mem)  TOP=axi_mem_tb
        FILES="../ip/common/rtl/soc_pkg.sv ../ip/mem/rtl/axi_mem.sv ../ip/mem/tb/axi_mem_tb.sv" ;;
  *)    echo "Unknown test '$TEST'. Tests on Icarus: fifo mem"; exit 1 ;;
esac
mkdir -p out/icarus
printf '`timescale 1ns/1ps\n' > out/icarus/timescale.sv
TOPS="-s $TOP"
EXTRA=""
if [ "$WAVES" = "waves" ]; then
  TOPS="$TOPS -s waves"
  EXTRA="waves.sv"
fi
iverilog -g2012 $TOPS -o out/icarus/$TEST.vvp out/icarus/timescale.sv $FILES $EXTRA
vvp -n out/icarus/$TEST.vvp
if [ "$WAVES" = "waves" ]; then
  echo "Waveform saved: sim/out/icarus/waves.vcd"
fi
