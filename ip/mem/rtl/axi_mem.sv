// ============================================================
// File : axi_mem.sv
// What : AXI4 memory (Subordinate): the "warehouse" that the
//        DMA reads from and writes to.
//        WRITE side (AW, W, B) + READ side (AR, R).
//        - 256 bytes. Uses only the low MEM_ADDR_W address
//          bits, so the memory repeats every 256 addresses.
//        - Bursts: INCR, FIXED and WRAP. Byte strobes (WSTRB).
//        - One write burst and one read burst at a time; the
//          two sides work at the SAME time, independently.
//        - Part D1: error answers (SLVERR). A request we do not
//          support still gets ALL its beats (AXI never cuts a
//          burst short), but:
//            write: nothing is stored, BRESP = SLVERR
//            read : every beat has RRESP = SLVERR and RDATA = 0
//          A WLAST in the wrong place also gives BRESP = SLVERR.
//        - Outputs come only from flip-flops, never from an
//          input through plain logic (rule 6).
// Spec : ARM IHI0022 Issue L - handshake, burst address math,
//        burst rules (length, size, type), WSTRB/WLAST/RLAST,
//        read and write responses
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
                                      // ourselves (AWLEN) and check that
                                      // WLAST agrees with our count.
  input  logic              wvalid,
  output logic              wready,

  // ---------------- B: write response ----------------
  output logic [ID_W-1:0]   bid,
  output logic [1:0]        bresp,    // OKAY, or SLVERR if something was wrong
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
  output logic [1:0]        rresp,    // OKAY, or SLVERR on every beat of a bad read
  output logic              rlast,    // marks the last beat of the burst
  output logic              rvalid,
  input  logic              rready
);

  localparam int LANE_W = $clog2(STRB_W);   // address bits that pick a byte in a word (2)
  localparam int WORD_W = MEM_ADDR_W - LANE_W;   // bits that pick a word (6 -> 64 words)

  // ---------------- Storage: 64 words x 32 bits ----------------
  logic [DATA_W-1:0] mem [MEM_WORDS];

  // ---------------- Address of the next beat ----------------
  // Spec: burst address math. Only shifts and masks: no multiplier.
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

  // ---------------- Is this a request we do not support? ----------------
  // Spec: burst rules. Used by BOTH sides.
  //   - a beat wider than the data bus (AxSIZE > 2 on our 4-byte bus)
  //   - AxBURST = 2'b11 (reserved: it has no meaning)
  //   - WRAP: length not 2, 4, 8 or 16 beats, or the start address
  //     not lined up with the beat size
  //   - FIXED: more than 16 beats
  // (INCR may be 1 to 256 beats; staying inside 4KB is the
  //  master's job, and a checker watches it in Part D2.)
  function automatic logic bad_request(input logic [ADDR_W-1:0] addr,
                                       input logic [7:0]        len,
                                       input logic [2:0]        size,
                                       input logic [1:0]        burst);
    logic [ADDR_W-1:0] bytes;
    bytes = ADDR_W'(1) << size;                          // bytes per beat
    if (size > SIZE_FULL) return 1'b1;                   // wider than the bus
    case (burst)
      BURST_INCR:  return 1'b0;
      BURST_FIXED: return (len > 8'd15);                 // more than 16 beats
      BURST_WRAP:  return !(len == 8'd1 || len == 8'd3 || len == 8'd7 || len == 8'd15)
                          || ((addr & (bytes - 1'b1)) != '0);   // start not lined up
      default:     return 1'b1;                          // 2'b11: reserved
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
  logic              w_bad;     // this burst is a bad request: store nothing
  logic              w_last_err;// WLAST was wrong on an earlier beat of this burst

  // Handshake: something moves only when VALID and READY are both 1
  logic aw_hs, w_hs, b_hs;
  assign aw_hs = awvalid && awready;
  assign w_hs  = wvalid  && wready;
  assign b_hs  = bvalid  && bready;

  // WLAST must be 1 on the last beat and 0 on every other beat
  logic w_is_last, wlast_wrong;
  assign w_is_last   = (w_beat == w_len);
  assign wlast_wrong = (wlast != w_is_last);

  // READY and VALID come only from the state (flip-flops)
  assign awready = (wstate == W_IDLE);
  assign wready  = (wstate == W_DATA);
  assign bvalid  = (wstate == W_RESP);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wstate     <= W_IDLE;
      w_addr     <= '0;
      w_len      <= '0;
      w_size     <= '0;
      w_burst    <= '0;
      w_beat     <= '0;
      w_bad      <= 1'b0;
      w_last_err <= 1'b0;
      bid        <= '0;
      bresp      <= RESP_OKAY;
    end else begin
      case (wstate)
        W_IDLE: if (aw_hs) begin             // address accepted: remember the burst
          w_addr     <= awaddr;
          w_len      <= awlen;
          w_size     <= awsize;
          w_burst    <= awburst;
          w_beat     <= '0;
          w_bad      <= bad_request(awaddr, awlen, awsize, awburst);
          w_last_err <= 1'b0;                // a new burst starts clean
          bid        <= awid;                // the answer carries the same tag
          wstate     <= W_DATA;
        end
        W_DATA: if (w_hs) begin              // one beat taken (see the storage block)
          w_addr <= next_addr(w_addr, w_size, w_len, w_burst);
          w_beat <= w_beat + 1'b1;
          if (wlast_wrong) w_last_err <= 1'b1;
          if (w_is_last) begin               // that was the last beat: prepare the answer
            bresp  <= (w_bad || w_last_err || wlast_wrong) ? RESP_SLVERR : RESP_OKAY;
            wstate <= W_RESP;
          end
        end
        W_RESP: if (b_hs) wstate <= W_IDLE;        // answer taken: free again
        default: wstate <= W_IDLE;
      endcase
    end
  end

  // Storage write. Word number = address bits [7:2]. Bits above 7
  // are ignored, so the memory repeats every 256 addresses.
  // A bad request stores nothing. A WLAST mistake still stores the
  // data (AXI does not say what to do; we keep it and answer SLVERR).
  logic [WORD_W-1:0] w_word;
  assign w_word = w_addr[MEM_ADDR_W-1:LANE_W];

  always_ff @(posedge clk) begin
    if (w_hs && !w_bad)
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
  logic              r_bad;     // this burst is a bad request: send zeros + SLVERR

  logic ar_hs, r_hs;
  assign ar_hs = arvalid && arready;
  assign r_hs  = rvalid  && rready;

  assign arready = (rstate == R_IDLE);
  assign rvalid  = (rstate == R_DATA);

  // Is the read that is arriving now a bad request?
  logic ar_bad;
  assign ar_bad = bad_request(araddr, arlen, arsize, arburst);

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
  // A bad read sends zeros, so nothing from the memory leaks out.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate  <= R_IDLE;
      r_addr  <= '0;
      r_len   <= '0;
      r_size  <= '0;
      r_burst <= '0;
      r_beat  <= '0;
      r_bad   <= 1'b0;
      rid     <= '0;
      rdata   <= '0;
      rresp   <= RESP_OKAY;
      rlast   <= 1'b0;
    end else begin
      case (rstate)
        R_IDLE: if (ar_hs) begin             // address accepted: load the first beat
          r_addr  <= araddr;
          r_len   <= arlen;
          r_size  <= arsize;
          r_burst <= arburst;
          r_beat  <= '0;
          r_bad   <= ar_bad;
          rid     <= arid;                   // every beat carries the same tag
          rdata   <= ar_bad ? '0 : mem[r_word];
          rresp   <= ar_bad ? RESP_SLVERR : RESP_OKAY;   // same answer on every beat
          rlast   <= (arlen == 8'd0);        // a 1-beat burst: first beat is the last
          rstate  <= R_DATA;
        end
        R_DATA: if (r_hs) begin              // a beat was taken
          if (rlast) rstate <= R_IDLE;       // that was the last one
          else begin                         // load the next beat
            r_addr <= r_next;
            r_beat <= r_beat + 1'b1;
            rdata  <= r_bad ? '0 : mem[r_word];
            rlast  <= (r_beat + 1'b1 == r_len);
          end
        end
        default: rstate <= R_IDLE;
      endcase
    end
  end

endmodule