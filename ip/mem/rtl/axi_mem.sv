// ============================================================
// File : axi_mem.sv
// What : AXI4 memory (Subordinate): the "warehouse" that the
//        DMA reads from and writes to.
//        Part C1: WRITE side only (channels AW, W, B).
//        - 256 bytes. Uses only the low MEM_ADDR_W address
//          bits, so the memory repeats every 256 addresses.
//        - Bursts: INCR, FIXED and WRAP. Byte strobes (WSTRB).
//        - One write burst at a time.
//        - READY/VALID outputs come only from flip-flops,
//          never from an input through plain logic (rule 6).
// Spec : ARM IHI0022 Issue L - A2.3 handshake, A3.1 burst
//        address math, A3.2 WSTRB and WLAST, A3.3 responses
// ============================================================
module axi_mem
  import soc_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,

  // ---------------- AW: write address ----------------
  input  logic [ID_W-1:0]   awid,     // tag; the answer (B) carries the same tag
  input  logic [ADDR_W-1:0] awaddr,   // address of the first beat
  input  logic [7:0]        awlen,    // number of beats - 1
  input  logic [2:0]        awsize,   // bytes per beat = 2**awsize
  input  logic [1:0]        awburst,  // FIXED, INCR or WRAP
  input  logic              awvalid,
  output logic              awready,

  // ---------------- W: write data ----------------
  input  logic [DATA_W-1:0] wdata,
  input  logic [STRB_W-1:0] wstrb,    // 1 bit per byte: write this byte?
  input  logic              wlast,    // marks the last beat. We count beats
                                      // ourselves; Part D checks wlast.
  input  logic              wvalid,
  output logic              wready,

  // ---------------- B: write response ----------------
  output logic [ID_W-1:0]   bid,
  output logic [1:0]        bresp,
  output logic              bvalid,
  input  logic              bready
);

  localparam int LANE_W = $clog2(STRB_W);   // address bits that pick a byte in a word (2)

  // ---------------- Storage: 64 words x 32 bits ----------------
  logic [DATA_W-1:0] mem [MEM_WORDS];

  // ---------------- Write-side state machine ----------------
  typedef enum logic [1:0] {
    W_IDLE,    // waiting for an address (AW)
    W_DATA,    // taking the data beats (W)
    W_RESP     // giving the answer (B)
  } wstate_t;
  wstate_t wstate;

  logic [ADDR_W-1:0] w_addr;    // address of the current beat
  logic [7:0]        w_len;     // saved AWLEN
  logic [2:0]        w_size;    // saved AWSIZE
  logic [1:0]        w_burst;   // saved AWBURST
  logic [7:0]        w_beat;    // beat number: 0 = first

  // Handshake: something moves only when VALID and READY are both 1
  logic aw_hs, w_hs, b_hs;
  assign aw_hs = awvalid && awready;
  assign w_hs  = wvalid  && wready;
  assign b_hs  = bvalid  && bready;

  // READY and VALID come only from the state (flip-flops)
  assign awready = (wstate == W_IDLE);
  assign wready  = (wstate == W_DATA);
  assign bvalid  = (wstate == W_RESP);
  assign bresp   = RESP_OKAY;          // error answers come in Part D

  // ---------------- Address of the next beat ----------------
  // Spec A3.1.6 / A3.1.7. Only shifts and masks: no multiplier.
  function automatic logic [ADDR_W-1:0] next_addr(input logic [ADDR_W-1:0] addr,
                                                  input logic [2:0]        size,
                                                  input logic [7:0]        len,
                                                  input logic [1:0]        burst);
    logic [ADDR_W-1:0] bytes, aligned, total;
    bytes   = ADDR_W'(1) << size;              // bytes per beat
    aligned = addr & ~(bytes - 1'b1);          // round down to a beat boundary
    total   = (ADDR_W'(len) + 1'b1) << size;   // bytes in the whole burst (for WRAP)
    case (burst)
      BURST_FIXED: return addr;                                  // same address every beat
      BURST_WRAP:  return (addr & ~(total - 1'b1))               // start of the wrap window
                        | ((aligned + bytes) & (total - 1'b1));  // + next offset, wrapped
      default:     return aligned + bytes;                       // INCR: up by one beat
    endcase
  endfunction

  // ---------------- State machine ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wstate  <= W_IDLE;
      w_addr  <= '0;
      w_len   <= '0;
      w_size  <= '0;
      w_burst <= '0;
      w_beat  <= '0;
      bid     <= '0;
    end else begin
      case (wstate)
        W_IDLE: if (aw_hs) begin             // address accepted: remember the burst
          w_addr  <= awaddr;
          w_len   <= awlen;
          w_size  <= awsize;
          w_burst <= awburst;
          w_beat  <= '0;
          bid     <= awid;                   // the answer carries the same tag
          wstate  <= W_DATA;
        end
        W_DATA: if (w_hs) begin              // one beat stored (see the storage block)
          w_addr <= next_addr(w_addr, w_size, w_len, w_burst);
          w_beat <= w_beat + 1'b1;
          if (w_beat == w_len) wstate <= W_RESP;   // that was the last beat
        end
        W_RESP: if (b_hs) wstate <= W_IDLE;        // answer taken: free again
        default: wstate <= W_IDLE;
      endcase
    end
  end

  // ---------------- Storage write ----------------
  // Word number = address bits [7:2]. Bits above 7 are ignored,
  // so the memory repeats every 256 addresses.
  logic [MEM_ADDR_W-LANE_W-1:0] w_word;
  assign w_word = w_addr[MEM_ADDR_W-1:LANE_W];

  always_ff @(posedge clk) begin
    if (w_hs)
      for (int i = 0; i < STRB_W; i++)
        if (wstrb[i]) mem[w_word][8*i +: 8] <= wdata[8*i +: 8];   // only strobed bytes
  end

endmodule
