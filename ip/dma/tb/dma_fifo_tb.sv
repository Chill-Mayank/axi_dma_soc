// ============================================================
// File : dma_fifo_tb.sv
// What : Self-checking testbench for dma_fifo.
//        Inputs change on the FALLING clock edge; the FIFO
//        acts on the RISING edge, so there are no races.
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

  // ---------------- Test sequence ----------------
  initial begin
    rst_n = 0; wr_en = 0; rd_en = 0; wr_data = '0;   // start in reset, inputs quiet
    repeat (3) @(negedge clk);                       // hold reset for 3 clocks
    rst_n = 1;                                       // release reset
    @(negedge clk);
    $display("After reset: empty=%0b full=%0b count=%0d", empty, full, count);
    // (tests will go here in parts B and C)
    repeat (3) @(negedge clk);
    $finish;
  end

endmodule