// ============================================================
// File : axi_mem_tb.sv
// What : Self-checking testbench for axi_mem. Part C2: writes AND reads.
//        - A byte-by-byte model of the memory (the answer key)
//        - Beat addresses from the spec formulas, written in a
//          different way from the RTL on purpose
//        - BLACK-BOX: the memory is checked only through its AXI
//          ports (we read it back), never by looking inside it
//        - Directed write tests, directed read tests, then random
//          writes and reads running at the same time, with coverage
//        Inputs change on the FALLING clock edge; the memory
//        acts on the RISING edge.
// ============================================================
module axi_mem_tb;
  import soc_pkg::*;

  // ---------------- Clock and reset ----------------
  logic clk = 0;
  logic rst_n;
  always #5 clk = ~clk;          // 10 ns period = 100 MHz

  // ---------------- AXI wires ----------------
  logic [ID_W-1:0]   awid;     logic [ADDR_W-1:0] awaddr;
  logic [7:0]        awlen;    logic [2:0]        awsize;
  logic [1:0]        awburst;  logic              awvalid, awready;
  logic [DATA_W-1:0] wdata;    logic [STRB_W-1:0] wstrb;
  logic              wlast,    wvalid, wready;
  logic [ID_W-1:0]   bid;      logic [1:0]        bresp;
  logic              bvalid,   bready;
  logic [ID_W-1:0]   arid;     logic [ADDR_W-1:0] araddr;
  logic [7:0]        arlen;    logic [2:0]        arsize;
  logic [1:0]        arburst;  logic              arvalid, arready;
  logic [ID_W-1:0]   rid;      logic [DATA_W-1:0] rdata;
  logic [1:0]        rresp;    logic              rlast, rvalid, rready;

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

  // ---------------- Write driver ----------------
  logic [DATA_W-1:0] beat_data [$];   // what the next write burst will send
  logic [STRB_W-1:0] beat_strb [$];
  int w_left = 0;                     // write beats not yet accepted

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

  // ---------------- Read driver + checker ----------------
  int r_left = 0;                     // read beats not yet taken
  int rd_bad = 0;                     // mismatches in the current read burst

  // Report only the first mismatch of a read burst (the rest are echoes)
  task automatic rd_fail(input string msg);
    if (rd_bad == 0) fail(msg);
    rd_bad++;
  endtask

  // One whole read burst: AR, then every R beat, each checked
  // against the answer key. Only the byte lanes that belong to
  // the beat are checked (a narrow beat uses fewer lanes).
  //   ar_wait          : clocks before ARVALID rises
  //   r_pmin .. r_pmax : clocks RREADY stays low before each beat
  task automatic read_burst(input logic [ID_W-1:0] id, input longint addr,
                            input int len, input int size, input logic [1:0] burst,
                            input string what,
                            input int ar_wait = 0, input int r_pmin = 0, input int r_pmax = 0);
    logic [DATA_W-1:0] held;
    longint a;
    int nb, lo, hi, base, pause;
    rd_bad = 0;
    // 1) AR
    repeat (ar_wait) @(negedge clk);
    arid = id;  araddr = addr[ADDR_W-1:0];  arlen = len;  arsize = size;  arburst = burst;
    arvalid = 1;
    @(posedge clk); while (!arready) @(posedge clk);       // handshake on this edge
    @(negedge clk);
    arvalid = 0;
    arid = $urandom; araddr = $urandom;                     // junk
    r_left = len + 1;
    // 2) R beats
    for (int n = 0; n <= len; n++) begin
      pause = $urandom_range(r_pmax, r_pmin);
      while (!rvalid) @(negedge clk);
      held = rdata;
      repeat (pause) begin                                  // keep RREADY low a while:
        @(negedge clk);                                     // the beat must stay put
        if (!rvalid)        fail($sformatf("%s: RVALID dropped before RREADY", what));
        if (rdata !== held) fail($sformatf("%s: RDATA changed before RREADY", what));
      end
      rready = 1;
      @(posedge clk);                                       // handshake on this edge
      a    = beat_addr(addr, size, len, burst, n);
      nb   = 1 << size;
      lo   = int'(a % STRB_W);                              // first lane of this beat
      hi   = int'(((a / nb) * nb) % STRB_W) + nb - 1;       // last lane of this beat
      base = int'(a % MEM_BYTES) & ~(STRB_W - 1);
      for (int i = lo; i <= hi; i++)
        if (rdata[8*i +: 8] !== model[base + i])
          rd_fail($sformatf("%s: beat %0d from 0x%0h, lane %0d = %h, expected %h",
                            what, n, a, i, rdata[8*i +: 8], model[base + i]));
      if (rid   !== id)        rd_fail($sformatf("%s: RID = %0d, expected %0d", what, rid, id));
      if (rresp !== RESP_OKAY) rd_fail($sformatf("%s: RRESP = %0d, expected OKAY", what, rresp));
      if (rlast !== (n == len))
        rd_fail($sformatf("%s: RLAST = %0b on beat %0d of %0d", what, rlast, n, len + 1));
      @(negedge clk);
      rready = 0;
      r_left--;
    end
  endtask

  // Read the whole memory through AXI and compare it with the answer key
  task automatic check_mem(input string what, input bit loud = 1);
    int err_start;
    err_start = errors;
    read_burst(4'hF, 'h0, MEM_WORDS-1, SIZE_FULL, BURST_INCR, what);
    if (errors == err_start && loud) $display("  [OK]   %s", what);
  endtask

  // Print [OK] for a directed read test if it added no errors
  task automatic ok_if_clean(input int err_start, input string what);
    if (errors == err_start) $display("  [OK]   %s", what);
  endtask

  // ---------------- Rule checks, every clock ----------------
  // B must not come before the last W beat; R must not come without a read
  always @(posedge clk)
    if (rst_n) begin
      if (bvalid && w_left != 0) fail("BVALID before the last W beat");
      if (rvalid && r_left == 0) fail("RVALID with no read in progress");
    end

  // Safety net: a stuck handshake would otherwise hang the simulation forever
  initial begin
    #2_000_000;
    $display("FAIL: timeout (a handshake never finished)");
    $finish;
  end

  // ---------------- Coverage counters ----------------
  int cov_w_incr, cov_w_fixed, cov_w_wrap, cov_r_incr, cov_r_fixed, cov_r_wrap;
  int cov_single, cov_max, cov_part_strb, cov_w_first, cov_b_wait, cov_r_wait;
  int same_clk = 0;      // clocks with a W beat AND an R beat (both sides working at once)

  always @(posedge clk)
    if (wvalid && wready && rvalid && rready) same_clk++;

  task automatic show_bin(input string what, input int hits);
    if (hits > 0) $display("  [COV]  %-36s hit %0d times", what, hits);
    else begin
      $display("  [HOLE] %-36s NEVER hit", what);
      errors++;
    end
  endtask

  // ---------------- Random bursts for the mixed test ----------------
  // Pick a random burst that stays inside one 128-byte half of the
  // memory (base = 0 or 128), at a random spot in the 32-bit space.
  task automatic pick_burst(input int base, output longint addr, output int len,
                            output logic [1:0] burst);
    case ($urandom_range(2))
      0:       burst = BURST_INCR;
      1:       burst = BURST_FIXED;
      default: burst = BURST_WRAP;
    endcase
    if (burst == BURST_WRAP) len = (2 << $urandom_range(3)) - 1;   // 2, 4, 8 or 16 beats
    else                     len = $urandom_range(MAX_BURST_BEATS-1);
    addr = {$urandom} & 32'hFFFF_FF00;                            // any 256-byte block
    addr = addr + base
         + $urandom_range((burst == BURST_INCR) ? 31 - len : 31) * STRB_W;
    if (len == 0)                 cov_single++;
    if (len == MAX_BURST_BEATS-1) cov_max++;
  endtask

  task automatic random_write(input int base);
    longint addr;
    int len, aw_wait, b_wait;
    logic [1:0] burst;
    pick_burst(base, addr, len, burst);
    for (int n = 0; n <= len; n++) begin
      beat_data.push_back($urandom);
      beat_strb.push_back(STRB_W'($urandom));                  // random strobe pattern
      if (beat_strb[n] != '0 && beat_strb[n] != '1) cov_part_strb++;
    end
    aw_wait = $urandom_range(1) ? 0 : $urandom_range(3, 1);
    b_wait  = $urandom_range(1) ? 0 : $urandom_range(3, 1);
    if (burst == BURST_INCR)  cov_w_incr++;
    if (burst == BURST_FIXED) cov_w_fixed++;
    if (burst == BURST_WRAP)  cov_w_wrap++;
    if (aw_wait > 0) cov_w_first++;
    if (b_wait  > 0) cov_b_wait++;
    write_burst(ID_W'($urandom), addr, len, SIZE_FULL, burst, aw_wait, 2, b_wait);
  endtask

  task automatic random_read(input int base);
    longint addr;
    int len, pmax;
    logic [1:0] burst;
    pick_burst(base, addr, len, burst);
    pmax = $urandom_range(1) ? 0 : 2;
    if (burst == BURST_INCR)  cov_r_incr++;
    if (burst == BURST_FIXED) cov_r_fixed++;
    if (burst == BURST_WRAP)  cov_r_wrap++;
    if (pmax > 0) cov_r_wait++;
    read_burst(ID_W'($urandom), addr, len, SIZE_FULL, burst, "random read",
               $urandom_range(2), 0, pmax);
  endtask

  // ---------------- Tests ----------------
  initial begin
    int err_start, same_start;
    awvalid = 0;  wvalid = 0;  bready = 0;  wlast = 0;
    awid = '0;  awaddr = '0;  awlen = '0;  awsize = '0;  awburst = '0;
    wdata = '0;  wstrb = '0;
    arvalid = 0;  rready = 0;
    arid = '0;  araddr = '0;  arlen = '0;  arsize = '0;  arburst = '0;
    rst_n = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    // ----- Writes (each checked by reading the whole memory back) -----
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
    write_burst(8, 'h70, 3, SIZE_FULL, BURST_INCR, 3);          // aw_wait = 3
    check_mem("data waited for the address, then landed at 0x70..0x7C");

    $display("Test 9: slow BREADY (memory must hold the answer)");
    beat_data.push_back(32'h9999_9999);  beat_strb.push_back('1);
    write_burst(9, 'h80, 0, SIZE_FULL, BURST_INCR, 0, 0, 4);    // b_wait = 4
    check_mem("BVALID stayed high for 4 clocks; data at 0x80");

    $display("Test 10: longest write, 256 beats (wraps the memory 4 times)");
    for (int n = 0; n < 256; n++) begin
      beat_data.push_back(32'hF000_0000 + n);  beat_strb.push_back('1);
    end
    write_burst(10, 'h0, 255, SIZE_FULL, BURST_INCR);
    check_mem("the last 64 beats are what remains");

    // ----- Reads -----
    $display("Test 11: INCR read, 4 beats from 0x10");
    err_start = errors;
    read_burst(11, 'h10, 3, SIZE_FULL, BURST_INCR, "Test 11");
    ok_if_clean(err_start, "beats came from 0x10, 0x14, 0x18, 0x1C; RLAST on beat 4");

    $display("Test 12: FIXED read, 4 beats from 0x30");
    err_start = errors;
    read_burst(12, 'h30, 3, SIZE_FULL, BURST_FIXED, "Test 12");
    ok_if_clean(err_start, "all 4 beats came from 0x30");

    $display("Test 13: WRAP read, 4 beats from 0x48");
    err_start = errors;
    read_burst(13, 'h48, 3, SIZE_FULL, BURST_WRAP, "Test 13");
    ok_if_clean(err_start, "beats came from 0x48, 0x4C, 0x40, 0x44");

    $display("Test 14: narrow read, 4 one-byte beats from 0x50");
    err_start = errors;
    read_burst(14, 'h50, 3, 0, BURST_INCR, "Test 14");
    ok_if_clean(err_start, "each byte came on its own lane");

    $display("Test 15: read from high address 0x0000_1060");
    err_start = errors;
    read_burst(15, 'h1060, 0, SIZE_FULL, BURST_INCR, "Test 15");
    ok_if_clean(err_start, "got the data stored at 0x60");

    $display("Test 16: slow RREADY (3 clocks before every beat)");
    err_start = errors;
    read_burst(0, 'h00, 7, SIZE_FULL, BURST_INCR, "Test 16", 0, 3, 3);
    ok_if_clean(err_start, "RVALID and RDATA held steady while RREADY was low");

    $display("Test 17: longest read, 256 beats (reads the memory 4 times)");
    err_start = errors;
    read_burst(1, 'h0, 255, SIZE_FULL, BURST_INCR, "Test 17");
    ok_if_clean(err_start, "all 256 beats correct; RLAST only on the last");

    // ----- Writes and reads at the same time -----
    $display("Test 18: a 16-beat write and a 16-beat read at the same time");
    err_start = errors;
    same_start = same_clk;
    for (int n = 0; n < 16; n++) begin
      beat_data.push_back(32'h1800_0000 + n);  beat_strb.push_back('1);
    end
    fork
      write_burst(18, 'h00, 15, SIZE_FULL, BURST_INCR);                // lower half
      read_burst (18, 'h80, 15, SIZE_FULL, BURST_INCR, "Test 18");     // upper half
    join
    if (same_clk - same_start < 10)
      fail($sformatf("Test 18: W and R beats shared only %0d clocks", same_clk - same_start));
    ok_if_clean(err_start, $sformatf("W and R beats moved in the same clock %0d times",
                                     same_clk - same_start));
    check_mem("the write landed at 0x00..0x3C");

    // 6 rounds. In each round the writer uses one half of the memory
    // and the reader the other half, so every read has a known answer.
    $display("Test 19: random writes and reads at the same time (300 + 300 bursts)");
    same_start = same_clk;
    for (int round = 0; round < 6; round++) begin
      fork
        for (int k = 0; k < 50; k++) random_write((round % 2) ? 128 : 0);
        for (int k = 0; k < 50; k++) random_read ((round % 2) ? 0 : 128);
      join
    end
    check_mem("memory matches the model after 600 random bursts");

    $display("Coverage of the random test:");
    show_bin("write INCR bursts",                  cov_w_incr);
    show_bin("write FIXED bursts",                 cov_w_fixed);
    show_bin("write WRAP bursts",                  cov_w_wrap);
    show_bin("read INCR bursts",                   cov_r_incr);
    show_bin("read FIXED bursts",                  cov_r_fixed);
    show_bin("read WRAP bursts",                   cov_r_wrap);
    show_bin("single-beat bursts",                 cov_single);
    show_bin("16-beat bursts",                     cov_max);
    show_bin("beats with partial byte strobes",     cov_part_strb);
    show_bin("address sent late (W first)",        cov_w_first);
    show_bin("slow BREADY",                        cov_b_wait);
    show_bin("slow RREADY",                        cov_r_wait);
    show_bin("W and R beats in the same clock",    same_clk - same_start);

    if (errors == 0) $display("PASS");
    else             $display("FAIL: %0d error(s)", errors);
    $finish;
  end

endmodule
