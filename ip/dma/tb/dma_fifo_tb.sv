// ============================================================
// File : dma_fifo_tb.sv
// What : Self-checking testbench for dma_fifo.
//        Inputs change on the FALLING clock edge; the FIFO
//        acts on the RISING edge, so there are no races.
//        Part C: corner-case tests, and a model that never
//        looks at the FIFO's own full/empty flags.
//        Part D: random stress test + coverage counters.
// ============================================================
module dma_fifo_tb;

  localparam int WIDTH = 32;
  localparam int DEPTH = 16;

  // ---------------- Wires to the FIFO ----------------
  logic                   clk = 0;
  logic                   rst_n;
  logic                   wr_en, rd_en;
  logic [WIDTH-1:0]       wr_data, rd_data;
  logic                   full, empty;
  logic [$clog2(DEPTH):0] count;

  // ---------------- The FIFO under test (DUT) ----------------
  dma_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .wr_en   (wr_en),
    .wr_data (wr_data),
    .full    (full),
    .rd_en   (rd_en),
    .rd_data (rd_data),
    .empty   (empty),
    .count   (count)
  );

  // ---------------- Clock: 10 ns period = 100 MHz ----------------
  always #5 clk = ~clk;

  // ---------------- Reference model (scoreboard) ----------------
  logic [WIDTH-1:0] model [$];   // queue: what SHOULD come out, oldest first
  int errors = 0;                // how many checks failed

  // ---------------- Coverage counters (Part D) ----------------
  // How often did the random test hit each tricky situation?
  bit cov_on = 0;                // count only during the random test
  int cov_push_full;             // push tried while full     (must be refused)
  int cov_pop_empty;             // pop tried while empty     (must be ignored)
  int cov_both;                  // push and pop both happened in one clock
  int cov_hit_full;              // clocks that ended full
  int cov_hit_empty;             // clocks that ended empty

  // fail: count every error, print only the first 10
  // (after a real bug, later errors are usually echoes of the first)
  task automatic fail(input string msg);
    errors++;
    if (errors <= 10) $display("  [FAIL] t=%0t ps: %s", $time, msg);
  endtask

  // check_flags: count, empty and full must match the expected occupancy.
  //   loud = 1: also print [OK]   (named checkpoints in the test)
  //   loud = 0: silent unless wrong (the automatic check after every clock)
  task automatic check_flags(input int exp_count, input string what, input bit loud = 1);
    logic exp_empty, exp_full;
    exp_empty = (exp_count == 0);
    exp_full  = (exp_count == DEPTH);
    if (count !== exp_count || empty !== exp_empty || full !== exp_full)
      fail($sformatf("%s: count=%0d empty=%0b full=%0b, expected count=%0d empty=%0b full=%0b",
                     what, count, empty, full, exp_count, exp_empty, exp_full));
    else if (loud)
      $display("  [OK]   %s (count=%0d empty=%0b full=%0b)", what, count, empty, full);
  endtask

  // cycle: one clock of write and/or read, then check everything.
  // The model decides BY ITSELF what the FIFO must accept.
  // It never looks at the DUT's full/empty, so a DUT bug can't fool it.
  task automatic cycle(input bit wr, input bit rd, input logic [WIDTH-1:0] d = '0);
    bit will_wr, will_rd;
    will_wr = wr && (model.size() < DEPTH);   // room?  A full FIFO ignores a push
    will_rd = rd && (model.size() > 0);       // data?  An empty FIFO ignores a pop

    if (cov_on) begin                         // coverage: what situation is this clock?
      if (wr && model.size() == DEPTH) cov_push_full++;
      if (rd && model.size() == 0)     cov_pop_empty++;
      if (will_wr && will_rd)          cov_both++;
    end

    if (will_rd && rd_data !== model[0])      // fall-through: oldest item already showing
      fail($sformatf("read %h, expected %h", rd_data, model[0]));

    wr_en = wr;  rd_en = rd;  wr_data = d;    // drive the pins
    @(negedge clk);                           // FIFO acts at the rising edge in between
    wr_en = 0;   rd_en = 0;

    if (will_rd) void'(model.pop_front());    // model does the same move
    if (will_wr) model.push_back(d);
    check_flags(model.size(), "auto-check", 0);  // flags checked after EVERY clock

    if (cov_on && model.size() == DEPTH) cov_hit_full++;
    if (cov_on && model.size() == 0)     cov_hit_empty++;
  endtask

  // show_bin: print one coverage bin; a bin never hit is a hole (counts as an error)
  task automatic show_bin(input string what, input int hits);
    if (hits > 0) $display("  [COV]  %-32s hit %0d times", what, hits);
    else begin
      $display("  [HOLE] %-32s NEVER hit", what);
      errors++;
    end
  endtask

  // Short names for the three moves
  task automatic push(input logic [WIDTH-1:0] d);     cycle(1, 0, d); endtask
  task automatic pop();                               cycle(0, 1);    endtask
  task automatic push_pop(input logic [WIDTH-1:0] d); cycle(1, 1, d); endtask

  // ---------------- Test sequence ----------------
  // Data tag: first hex digit = test number (5000_0003 = Test 5, item 3)
  initial begin
    rst_n = 0; wr_en = 0; rd_en = 0; wr_data = '0;   // start in reset, inputs quiet
    repeat (3) @(negedge clk);                       // hold reset for 3 clocks
    rst_n = 1;                                       // release reset
    @(negedge clk);
    check_flags(0, "after reset");

    $display("Test 1: push 3 items, pop 3 items");
    push(32'h1111_1111);
    push(32'h2222_2222);
    push(32'h3333_3333);
    check_flags(3, "3 items inside");
    repeat (3) pop();
    check_flags(0, "empty again");

    $display("Test 2: fill to full (16 pushes)");
    for (int i = 1; i <= DEPTH; i++) push(32'h2000_0000 + i);
    check_flags(DEPTH, "full after 16 pushes");

    $display("Test 3: overflow (push while full must be ignored)");
    push(32'hDEAD_BEEF);
    check_flags(DEPTH, "still 16 after push-when-full");
    repeat (DEPTH) pop();                  // must give 2000_0001..2000_0010, in order
    check_flags(0, "empty after 16 pops");

    $display("Test 4: underflow (pop while empty must be ignored)");
    pop(); pop();
    check_flags(0, "still empty after 2 pops-when-empty");
    push(32'h4000_0001);                   // pointers must be unharmed
    pop();
    check_flags(0, "push + pop still work afterwards");

    $display("Test 5: push and pop in the same clock");
    push_pop(32'h5000_0001);               // EMPTY: nothing to pop, so only the push
    check_flags(1, "empty + push_pop -> 1 item");
    for (int i = 2; i <= 4; i++) push(32'h5000_0000 + i);
    for (int i = 5; i <= 8; i++) push_pop(32'h5000_0000 + i);
    check_flags(4, "middle: 4 push_pops, count stays 4");
    for (int i = 9; i <= 20; i++) push(32'h5000_0000 + i);
    check_flags(DEPTH, "full again");
    push_pop(32'h5000_00FF);               // FULL: push refused, pop happens
    check_flags(DEPTH-1, "full + push_pop -> 15 (push refused)");
    repeat (DEPTH-1) pop();                // 5000_00FF must never come out
    check_flags(0, "empty after 15 pops");

    $display("Test 6: wrap-around (stream 44 items, 4 always inside)");
    for (int i = 1;  i <= 4;  i++) push(32'h6000_0000 + i);
    for (int i = 5;  i <= 44; i++) push_pop(32'h6000_0000 + i);
    repeat (4) pop();
    check_flags(0, "empty after 44 items streamed");

    $display("Test 7: random stress (2000 clocks, no hand-typed answers)");
    cov_on = 1;
    for (int k = 0; k < 2000; k++) begin
      int push_pct;                          // chance of a push, in percent
      push_pct = ((k / 200) % 2 == 0) ? 80 : 20;   // 200 clocks filling, 200 draining, ...
      cycle($urandom_range(99) < push_pct,          // push?
            $urandom_range(99) < 100 - push_pct,    // pop?
            $urandom);                              // random data
    end
    cov_on = 0;
    while (model.size() > 0) pop();          // drain whatever is left
    check_flags(0, "empty after random stress");

    $display("Coverage of the random test:");
    show_bin("push while full",           cov_push_full);
    show_bin("pop while empty",           cov_pop_empty);
    show_bin("push + pop in one clock",   cov_both);
    show_bin("clock ended full",          cov_hit_full);
    show_bin("clock ended empty",         cov_hit_empty);

    if (errors == 0) $display("PASS");
    else             $display("FAIL: %0d error(s)", errors);
    $finish;
  end

endmodule
