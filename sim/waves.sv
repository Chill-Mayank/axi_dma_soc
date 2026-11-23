// Saves every signal of the test to a waveform file (for VaporView, GTKWave, Surfer).
// Used only by run_icarus.sh when you ask for waves.
module waves;
  initial begin
    $dumpfile("out/icarus/waves.vcd");
    $dumpvars;                      // no arguments = save everything
  end
endmodule
