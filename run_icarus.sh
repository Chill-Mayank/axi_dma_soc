#!/bin/sh
# Run the FIFO test on a laptop with Icarus Verilog (no Cadence server needed).
# Install once (Intel Mac):  sudo port install iverilog
# Use:   cd sim && sh run_icarus.sh          (text only)
#        cd sim && sh run_icarus.sh waves    (also saves out/icarus/fifo.vcd)
set -e
cd "$(dirname "$0")"
mkdir -p out/icarus
printf '`timescale 1ns/1ps\n' > out/icarus/timescale.sv
EXTRA=""
TOPS="-s dma_fifo_tb"
if [ "$1" = "waves" ]; then
  EXTRA="waves.sv"
  TOPS="-s dma_fifo_tb -s waves"
fi
iverilog -g2012 $TOPS -o out/icarus/fifo.vvp \
  out/icarus/timescale.sv ../ip/dma/rtl/dma_fifo.sv ../ip/dma/tb/dma_fifo_tb.sv $EXTRA
vvp -n out/icarus/fifo.vvp
if [ "$1" = "waves" ]; then
  echo "Waveform saved: sim/out/icarus/fifo.vcd"
fi
