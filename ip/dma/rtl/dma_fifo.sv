// Synchronous FIFO between DMA read channel and write channel.
// First word falls through: rd_data alwas shows the oldest item.

module dma_fifo #(
    parameter int WIDTH = 32,  // bits per item
    parameter int DEPTH = 16 // number of items (power of 2)

)
( 
    input logic clk, // clock: things happen on its rising edge
    input logic rst_n, // reset, active low (0 = reset)

    // write side: the read channel pushes data in
    input logic wr_en, // 1 =  push wr_data at this clock edge
    input logic [WIDTH-1:0] wr_data,
    output logic full, // 1 = no room, do not push

    // read side: the write channel takes data out
    input logic rd_en, // 1 = remove the oldest item
    output logic [WIDTH-1:0] rd_data, // the oldest item (valid when !empty)
    output logic empty, // 1 = nothing inside

    output logic [$clog2(DEPTH):0] count // items inside, 0..DEPTH

);
    // storage and pointers

    localparam int AW = $clog2(DEPTH); // slot number bits: 16 slots -> 4

    logic [WIDTH-1:0] mem[DEPTH]; // 16 slots, each 32 bits
    logic [AW:0] wr_ptr, rd_ptr; // 5 bits = 4 slot bits + 1 lap bit

    // safe push / pop
    logic do_write, do_read;
    assign do_write = wr_en && !full;
    assign do_read = rd_en && !empty;

    // Pointers: Move at each rising clock edge
    always_ff @(poedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;  // reset: both pointers to slot 0, lap 0
            rd_ptr <= '0;
        end else begin
            if (do_write) wr_ptr <=wr_ptr + 1'b1;  // move to the next slot
            if (do_read) rd_ptr <= rd_ptr + 1'b1;
        end
    end

      // ---------------- Storage: write the slot at each rising clock edge ----------------
    always_ff @(posedge clk) begin
      if (do_write) mem[wr_ptr[AW-1:0]] <= wr_data;   // lower 4 bits = slot number
    end
    


endmodule