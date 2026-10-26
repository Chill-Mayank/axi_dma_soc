// Shared settings for the whole AXI DMA Subsystem
// SPEC : AMBA AXI Protocol Specification, ARM IHI 0022 Issue L

package soc_pkg;
// Bus Sizes

  localparam int DATA_W = 32;  // bits per data beat (4bytes)
  localparam int STRB_W = DATA_W/8; // one write-strobe bit per byte -4
  localparam int ADDR_W = 8; // address bits > 2^8 = 256 bytes
  localparam int ID_W = 4; // transaction ID bits (AxID)

// Memory
  localparam int MEM_BYTES = 1 << ADDR_W; // 256 bytes
  localparam int MEM_WORDS = MEM_BYTES /STRB_W; // 64 words out of 32 bits

// DMA
  localparam int MAX_BURST_BEATS = 16; // spec allows upto 256
  localparam int FIFO_DEPTH = MAX_BURST_BEATS; // must hold a whole burst
  localparam int BOUNDARY_BYTES = 4096; // a burst must not cross 4KB

// AXI CODE
// AxBurst: How the address moves each beat
  localparam logic [1:0] BURST_FIXED = 2'b00; // same address every beat
  localparam logic [1:0] BURST_INCR = 2'b01; // address goes up every beat
  localparam logic [1:0] BURST_WRAP = 2'b10; // goes up, wraps around at a boundary

// BRESP / RRESP: how the transaction went
  localparam logic [1:0] RESP_OKAY = 2'b00; //all good
  localparam logic [1:0] RESP_EXOKAY = 2'b01; // exclusive OK
  localparam logic [1:0] RESP_SLVERR = 2'b10; // slave error
  localparam logic [1:0] RESP_DECERR = 2'b11; // nobody lives at this address

// AxSIZE for a full-width beat log2(bytes per beat) = 2
  localparam logic [2:0] SIZE_FULL = 3'($clog2(STRB_W)); 

endpackage