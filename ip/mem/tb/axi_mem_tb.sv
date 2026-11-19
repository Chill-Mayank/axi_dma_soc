// ============================================================
// File : axi_mem_tb.sv
// What : Self-checking testbench for axi_mem. Part C1: writes.
//        - A byte-by-byte model of the memory (the answer key)
//        - Beat addresses from the spec formulas, written in a
//          different way from the RTL on purpose
//        - Directed tests, then random bursts with coverage
//        Inputs change on the FALLING clock edge; the memory
//        acts on the RISING edge.
//        NOTE: until the read side exists (Part C2), we check
//        the memory by looking inside the DUT (dut.mem). That
//        is a temporary "white-box" check.
// ============================================================
module axi_mem_tb;
  import soc_pkg::*;

  // ---------------- Clock and reset ----------------
  logic clk = 0;
  logic rst_n;
  always #5 clk = ~clk;          // 10 ns period = 100 MHz

  // ---------------- AXI write wires ----------------
  logic [ID_W-1:0]   awid;
  logic [ADDR_W-1:0] awaddr;
  logic [7:0]        awlen;
  logic [2:0]        awsize;
  logic [1:0]        awburst;
  logic              awvalid, awready;
  logic [DATA_W-1:0] wdata;
  logic [STRB_W-1:0] wstrb;
  logic              wlast, wvalid, wready;
  logic [ID_W-1:0]   bid;
  logic [1:0]        bresp;
  logic              bvalid, bready;

  axi_mem dut (.*);              // .* = connect each port to the wire with the same name

  // ---------------- Answer key ----------------
  logic [7:0] model [MEM_BYTES]; // what each byte SHOULD hold
  int errors = 0;

  task automatic fail(input string msg);
    errors++;
    if (errors <= 10) $display("  [FAIL] t=%0t ps: %s", $time, msg);
  endtask

  // Address of beat n (0 = first), straight from the spec (A3.1.6)
  function automatic longint beat_addr(input longint start, input int size, input int len,
                                       input logic [1:0] burst, input int n);
    longint nb, total, aligned, wrap_lo, a;
    nb      = longint'(1) << size;           // Number_Bytes
    total   = nb * (len + 1);                // Number_Bytes x Burst_Length
    aligned = (start / nb) * nb;             // Aligned_Address
    if (n == 0 || burst == BURST_FIXED) return start;
    a = aligned + n * nb;
    if (burst == BURST_WRAP) begin
      wrap_lo = (start / total) * total;     // Wrap_Boundary
      if (a >= wrap_lo + total) a = a - total;
    end
    return a;
  endfunction

  // Model: store one beat (only bytes whose strobe bit is 1)
  function automatic void model_write(input longint addr, input logic [DATA_W-1:0] data,
                                      input logic [STRB_W-1:0] strb);
    int base;
    base = int'(addr % MEM_BYTES) & ~(STRB_W - 1);   // first byte of that word
    for (int i = 0; i < STRB_W; i++)
      if (strb[i]) model[base + i] = data[8*i +: 8];
  endfunction

  // Compare the whole memory with the answer key (white-box, until Part C2)
  task automatic check_mem(input string what, input bit loud = 1);
    logic [DATA_W-1:0] exp;
    int bad = 0;
    for (int w = 0; w < MEM_WORDS; w++) begin
      for (int i = 0; i < STRB_W; i++) exp[8*i +: 8] = model[w*STRB_W + i];
      if (dut.mem[w] !== exp) begin
        bad++;
        if (bad == 1) fail($sformatf("%s: address 0x%02h holds %h, expected %h",
                                     what, w*STRB_W, dut.mem[w], exp));
      end
    end
    if (bad == 0 && loud) $display("  [OK]   %s", what);
  endtask

  // ---------------- What the next burst will write ----------------
  logic [DATA_W-1:0] beat_data [$];
  logic [STRB_W-1:0] beat_strb [$];
  int w_left = 0;                // beats not yet accepted (used by the B rule check)

  // One whole write burst: AW and W at the same time, then B.
  //   aw_wait : clocks before AWVALID rises (so W can go first)
  //   w_gap   : up to this many idle clocks between W beats
  //   b_wait  : clocks BREADY stays low after BVALID rises
  task automatic write_burst(input logic [ID_W-1:0] id, input longint addr,
                             input int len, input int size, input logic [1:0] burst,
                             input int aw_wait = 0, input int w_gap = 0, input int b_wait = 0);
    // 1) the answer key: how memory should look afterwards
    for (int n = 0; n <= len; n++)
      model_write(beat_addr(addr, size, len, burst, n), beat_data[n], beat_strb[n]);
    w_left = len + 1;

    // 2) drive AW and W at the same time
    fork
      begin : aw_side
        repeat (aw_wait) @(negedge clk);
        awid = id;  awaddr = addr[ADDR_W-1:0];  awlen = len;  awsize = size;  awburst = burst;
        awvalid = 1;
        @(posedge clk); while (!awready) @(posedge clk);   // handshake on this edge
        @(negedge clk);
        awvalid = 0;
        awid = $urandom; awaddr = $urandom;                 // junk: the DUT must not use it now
      end
      begin : w_side
        for (int n = 0; n <= len; n++) begin
          repeat ($urandom_range(w_gap)) @(negedge clk);    // sometimes pause between beats
          wdata = beat_data[n];  wstrb = beat_strb[n];  wlast = (n == len);
          wvalid = 1;
          @(posedge clk); while (!wready) @(posedge clk);  // handshake on this edge
          w_left--;
          @(negedge clk);
          wvalid = 0;
          wdata = $urandom; wstrb = $urandom; wlast = $urandom; // junk while not valid
        end
      end
    join

    // 3) the answer (B): wait for it, maybe make it wait, then take it
    while (!bvalid) @(negedge clk);
    repeat (b_wait) begin
      @(negedge clk);
      if (!bvalid) fail("BVALID dropped before BREADY");
    end
    bready = 1;
    @(posedge clk);                                         // handshake on this edge
    if (bid   !== id)        fail($sformatf("BID = %0d, expected %0d", bid, id));
    if (bresp !== RESP_OKAY) fail($sformatf("BRESP = %0d, expected OKAY", bresp));
    @(negedge clk);
    bready = 0;
    beat_data.delete();
    beat_strb.delete();
  endtask

  // Rule check, every clock: B must not come before the last W beat
  always @(posedge clk)
    if (rst_n && bvalid && w_left != 0) fail("BVALID before the last W beat");

  // Safety net: a stuck handshake would otherwise hang the simulation forever
  initial begin
    #1_000_000;
    $display("FAIL: timeout (a handshake never finished)");
    $finish;
  end

  // ---------------- Coverage counters ----------------
  int cov_incr, cov_fixed, cov_wrap, cov_single, cov_max;
  int cov_w_first, cov_b_wait, cov_part_strb, cov_alias;

  task automatic show_bin(input string what, input int hits);
    if (hits > 0) $display("  [COV]  %-34s hit %0d times", what, hits);
    else begin
      $display("  [HOLE] %-34s NEVER hit", what);
      errors++;
    end
  endtask

  // ---------------- Tests ----------------
  initial begin
    awvalid = 0;  wvalid = 0;  bready = 0;  wlast = 0;
    awid = '0;  awaddr = '0;  awlen = '0;  awsize = '0;  awburst = '0;
    wdata = '0;  wstrb = '0;
    rst_n = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    $display("Test 1: fill all 256 bytes (one 64-beat INCR burst)");
    for (int n = 0; n < MEM_WORDS; n++) begin
      beat_data.push_back(32'hA000_0000 + n);  beat_strb.push_back('1);
    end
    write_burst(1, 'h0, MEM_WORDS-1, SIZE_FULL, BURST_INCR);
    check_mem("every byte holds the fill pattern");

    $display("Test 2: INCR burst, 4 beats from 0x10");
    for (int n = 0; n < 4; n++) begin
      beat_data.push_back(32'h2000_0000 + n);  beat_strb.push_back('1);
    end
    write_burst(2, 'h10, 3, SIZE_FULL, BURST_INCR);
    check_mem("beats went to 0x10, 0x14, 0x18, 0x1C");

    $display("Test 3: byte strobes (write only bytes 0 and 2 at 0x20)");
    beat_data.push_back(32'hBBBB_BBBB);  beat_strb.push_back(4'b0101);
    write_burst(3, 'h20, 0, SIZE_FULL, BURST_INCR);
    check_mem("only bytes 0 and 2 changed");

    $display("Test 4: FIXED burst, 4 beats to 0x30");
    for (int n = 0; n < 4; n++) begin
      beat_data.push_back(32'h4000_0000 + n);  beat_strb.push_back('1);
    end
    write_burst(4, 'h30, 3, SIZE_FULL, BURST_FIXED);
    check_mem("all beats hit 0x30; the last one stays");

    $display("Test 5: WRAP burst, 4 beats from 0x48");
    for (int n = 0; n < 4; n++) begin
      beat_data.push_back(32'h5000_0000 + n);  beat_strb.push_back('1);
    end
    write_burst(5, 'h48, 3, SIZE_FULL, BURST_WRAP);
    check_mem("beats went to 0x48, 0x4C, 0x40, 0x44");

    $display("Test 6: narrow burst, 4 one-byte beats from 0x50");
    for (int n = 0; n < 4; n++) begin
      beat_data.push_back(32'(8'hC0 + n) << (8*n));        // byte on its own lane
      beat_strb.push_back(4'b0001 << n);
    end
    write_burst(6, 'h50, 3, 0, BURST_INCR);
    check_mem("bytes C0..C3 landed at 0x50..0x53");

    $display("Test 7: high address 0x0000_1060 (memory repeats every 256 bytes)");
    beat_data.push_back(32'h7777_7777);  beat_strb.push_back('1);
    write_burst(7, 'h1060, 0, SIZE_FULL, BURST_INCR);
    check_mem("data landed at 0x60");

    $display("Test 8: W data arrives before the address");
    for (int n = 0; n < 4; n++) begin
      beat_data.push_back(32'h8000_0000 + n);  beat_strb.push_back('1);
    end
    write_burst(8, 'h70, 3, SIZE_FULL, BURST_INCR, 3);         // aw_wait = 3
    check_mem("data waited for the address, then landed at 0x70..0x7C");

    $display("Test 9: slow BREADY (memory must hold the answer)");
    beat_data.push_back(32'h9999_9999);  beat_strb.push_back('1);
    write_burst(9, 'h80, 0, SIZE_FULL, BURST_INCR, 0, 0, 4);   // b_wait = 4
    check_mem("BVALID stayed high for 4 clocks; data at 0x80");

    $display("Test 10: longest burst, 256 beats (wraps the memory 4 times)");
    for (int n = 0; n < 256; n++) begin
      beat_data.push_back(32'hF000_0000 + n);  beat_strb.push_back('1);
    end
    write_burst(10, 'h0, 255, SIZE_FULL, BURST_INCR);
    check_mem("the last 64 beats are what remains");

    $display("Test 11: 300 random bursts (length, type, strobes, delays)");
    for (int k = 0; k < 300; k++) begin
      logic [1:0] burst;
      int len, aw_wait, b_wait;
      longint addr;
      bit part;
      case ($urandom_range(2))
        0:       burst = BURST_INCR;
        1:       burst = BURST_FIXED;
        default: burst = BURST_WRAP;
      endcase
      if (burst == BURST_WRAP) len = (2 << $urandom_range(3)) - 1;   // 2, 4, 8 or 16 beats
      else                     len = $urandom_range(MAX_BURST_BEATS-1);
      addr = {$urandom} & 32'hFFFF_F000;                             // pick a 4KB page...
      addr = addr + ($urandom_range(1023 - len) * STRB_W);           // ...and stay inside it
      aw_wait = $urandom_range(1) ? 0 : $urandom_range(1, 3);
      b_wait  = $urandom_range(1) ? 0 : $urandom_range(1, 3);
      part = 0;
      for (int n = 0; n <= len; n++) begin
        beat_data.push_back($urandom);
        beat_strb.push_back(STRB_W'($urandom));    // random strobe pattern
        if (beat_strb[n] != '0 && beat_strb[n] != '1) part = 1;
      end
      // coverage: which situations did this burst hit?
      if (burst == BURST_INCR)  cov_incr++;
      if (burst == BURST_FIXED) cov_fixed++;
      if (burst == BURST_WRAP)  cov_wrap++;
      if (len == 0)                   cov_single++;
      if (len == MAX_BURST_BEATS-1)   cov_max++;
      if (aw_wait > 0)                cov_w_first++;
      if (b_wait > 0)                 cov_b_wait++;
      if (part)                       cov_part_strb++;
      if (addr >= MEM_BYTES)          cov_alias++;
      write_burst($urandom, addr, len, SIZE_FULL, burst, aw_wait, 2, b_wait);
      check_mem($sformatf("random burst %0d", k), 0);
    end
    check_mem("memory matches the model after 300 random bursts");

    $display("Coverage of the random test:");
    show_bin("INCR bursts",                cov_incr);
    show_bin("FIXED bursts",               cov_fixed);
    show_bin("WRAP bursts",                cov_wrap);
    show_bin("single-beat bursts",         cov_single);
    show_bin("16-beat bursts",             cov_max);
    show_bin("address sent late (W first)", cov_w_first);
    show_bin("slow BREADY",                cov_b_wait);
    show_bin("partial byte strobes",       cov_part_strb);
    show_bin("address above 255 (repeat)", cov_alias);

    if (errors == 0) $display("PASS");
    else             $display("FAIL: %0d error(s)", errors);
    $finish;
  end

endmodule
