// Saves all testbench + FIFO signals to a waveform file (for GTKWave / Surfer).
// Used only by run_icarus.sh when you ask for waves.
module waves;
  initial begin
    $dumpfile("out/icarus/fifo.vcd");
    $dumpvars(0, dma_fifo_tb);
  end
endmodule
