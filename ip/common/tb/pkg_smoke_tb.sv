// Print soc_pkg settings and checks them against AXI specs

module pkg_smoke_tb;
  
  import soc_pkg::*; // import the package

  int errors = 0; // error counter

  task automatic check(input bit ok, input string what);
    if (ok) $display(" [OK] %s", what);
    else begin
      $display(" [FAIL] %s", what);
      errors++;
    end
  endtask

   initial begin
     $display(" soc_pkg setttings ");
     $display(" DATA_W = %0d, ADDR_W = %0d, memory = %0d bytes", DATA_W, ADDR_W, MEM_BYTES);
     $display(" MAX_BURST_BEATS = %0d, FIFO_DEPTH = %0d", MAX_BURST_BEATS, FIFO_DEPTH);

     $display(" rule check ");
     check(STRB_W * 8 == DATA_W, "one write strobe per byte");
     check(MAX_BURST_BEATS inside {[1:256]}, "burst length legal for INCR");
     check(FIFO_DEPTH >= MAX_BURST_BEATS, "FIFO can hold a whole burst");
     check(MAX_BURST_BEATS * STRB_W <= BOUNDARY_BYTES, " one burst fits in 4KB");
     check((1 << SIZE_FULL) == STRB_W, "AxSIZE code matches bus width");

     if (errors == 0) $display("PASS");
     else $display("FAIL: %0d check(s) failed", errors);
     $finish;
   end
endmodule