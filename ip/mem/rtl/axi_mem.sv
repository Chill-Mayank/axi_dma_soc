// ============================================================
// File : axi_mem.sv
// What : AXI4 memory (Subordinate): the "warehouse" that the
//        DMA reads from and writes to.
//        Part C2: WRITE side (AW, W, B) + READ side (AR, R).
//        - 256 bytes. Uses only the low MEM_ADDR_W address
//          bits, so the memory repeats every 256 addresses.
//        - Bursts: INCR, FIXED and WRAP. Byte strobes (WSTRB).
//        - One write burst and one read burst at a time; the
//          two sides work at the SAME time, independently.
//        - Outputs come only from flip-flops, never from an
//          input through plain logic (rule 6).
// Spec : ARM IHI0022 Issue L - A2.3 handshake, A3.1 burst
//        address math, A3.2 WSTRB/WLAST/RLAST, A3.3 responses
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
  input  logic              bready,

  // ---------------- AR: read address ----------------
  input  logic [ID_W-1:0]   arid,     // tag; every R beat carries the same tag
  input  logic [ADDR_W-1:0] araddr,
  input  logic [7:0]        arlen,
  input  logic [2:0]        arsize,
  input  logic [1:0]        arburst,
  input  logic              arvalid,
  output logic              arready,

  // ---------------- R: read data ----------------
  output logic [ID_W-1:0]   rid,
  output logic [DATA_W-1:0] rdata,
  output logic [1:0]        rresp,
  output logic              rlast,    // marks the last beat of the burst
  output logic              rvalid,
  input  logic              rready
);

  localparam int LANE_W = $clog2(STRB_W);   // address bits that pick a byte in a word (2)
  localparam int WORD_W = MEM_ADDR_W - LANE_W;   // bits that pick a word (6 -> 64 words)

  // ---------------- Storage: 64 words x 32 bits ----------------
  logic [DATA_W-1:0] mem [MEM_WORDS];

  // ---------------- Address of the next beat ----------------
  // Spec A3.1.6 / A3.1.7. Only shifts and masks: no multiplier.
  // Used by BOTH sides.
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

  // ============================================================
  // WRITE SIDE: AW -> W beats -> B
  // ============================================================
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

  // Storage write. Word number = address bits [7:2]. Bits above 7
  // are ignored, so the memory repeats every 256 addresses.
  logic [WORD_W-1:0] w_word;
  assign w_word = w_addr[MEM_ADDR_W-1:LANE_W];

  always_ff @(posedge clk) begin
    if (w_hs)
      for (int i = 0; i < STRB_W; i++)
        if (wstrb[i]) mem[w_word][8*i +: 8] <= wdata[8*i +: 8];   // only strobed bytes
  end

  // ============================================================
  // READ SIDE: AR -> R beats (each beat carries data; RLAST on the last)
  // ============================================================
  typedef enum logic {
    R_IDLE,    // waiting for an address (AR)
    R_DATA     // sending the data beats (R)
  } rstate_t;
  rstate_t rstate;

  logic [ADDR_W-1:0] r_addr;    // address of the beat now on RDATA
  logic [7:0]        r_len;     // saved ARLEN
  logic [2:0]        r_size;    // saved ARSIZE
  logic [1:0]        r_burst;   // saved ARBURST
  logic [7:0]        r_beat;    // beat number now on RDATA: 0 = first

  logic ar_hs, r_hs;
  assign ar_hs = arvalid && arready;
  assign r_hs  = rvalid  && rready;

  assign arready = (rstate == R_IDLE);
  assign rvalid  = (rstate == R_DATA);
  assign rresp   = RESP_OKAY;          // error answers come in Part D

  // Address of the next beat to put on RDATA
  logic [ADDR_W-1:0] r_next;
  assign r_next = next_addr(r_addr, r_size, r_len, r_burst);

  // ONE read port: the word we load next is either the first beat
  // (from ARADDR) or the next beat of the burst (from r_next).
  logic [WORD_W-1:0] r_word;
  assign r_word = (rstate == R_IDLE) ? araddr[MEM_ADDR_W-1:LANE_W]
                                     : r_next[MEM_ADDR_W-1:LANE_W];

  // RDATA is a register: it changes only when a beat is taken, so it
  // stays steady while RREADY is low (even if a write hits that word).
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate  <= R_IDLE;
      r_addr  <= '0;
      r_len   <= '0;
      r_size  <= '0;
      r_burst <= '0;
      r_beat  <= '0;
      rid     <= '0;
      rdata   <= '0;
      rlast   <= 1'b0;
    end else begin
      case (rstate)
        R_IDLE: if (ar_hs) begin             // address accepted: load the first beat
          r_addr  <= araddr;
          r_len   <= arlen;
          r_size  <= arsize;
          r_burst <= arburst;
          r_beat  <= '0;
          rid     <= arid;                   // every beat carries the same tag
          rdata   <= mem[r_word];
          rlast   <= (arlen == 8'd0);        // a 1-beat burst: first beat is the last
          rstate  <= R_DATA;
        end
        R_DATA: if (r_hs) begin              // a beat was taken
          if (rlast) rstate <= R_IDLE;       // that was the last one
          else begin                         // load the next beat
            r_addr <= r_next;
            r_beat <= r_beat + 1'b1;
            rdata  <= mem[r_word];
            rlast  <= (r_beat + 1'b1 == r_len);
          end
        end
        default: rstate <= R_IDLE;
      endcase
    end
  end

endmodule
