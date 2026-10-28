// AXI4 memory slave: 1 KB (256 x 32b), INCR + FIXED bursts up to 16 beats, byte strobes,
// SLVERR for WRAP bursts and out-of-range accesses. One outstanding write + one read.
// Backpressure: pseudo-random ready/valid throttling (LFSR) when THROTTLE=1.
// `bug` (static input) injects one of 8 defects for testbench effectiveness measurement (0 = clean).
module axi_mem #(parameter THROTTLE = 1) (
  input             ACLK, ARESETn,
  input      [3:0]  bug,
  input      [3:0]  AWID,  input [31:0] AWADDR, input [7:0] AWLEN, input [2:0] AWSIZE, input [1:0] AWBURST,
  input             AWVALID, output AWREADY,
  input      [31:0] WDATA, input [3:0] WSTRB, input WLAST, input WVALID, output WREADY,
  output     [3:0]  BID,   output [1:0] BRESP, output BVALID, input BREADY,
  input      [3:0]  ARID,  input [31:0] ARADDR, input [7:0] ARLEN, input [2:0] ARSIZE, input [1:0] ARBURST,
  input             ARVALID, output ARREADY,
  output     [3:0]  RID,   output [31:0] RDATA, output [1:0] RRESP, output RLAST, output RVALID, input RREADY);

  reg [31:0] mem [0:255];
  integer ii; initial for (ii = 0; ii < 256; ii = ii + 1) mem[ii] = 32'd0;

  // ---- LFSR for throttling
  reg [15:0] lf;
  always @(posedge ACLK) if (!ARESETn) lf <= 16'hACE1; else lf <= {lf[14:0], lf[15] ^ lf[13] ^ lf[12] ^ lf[10]};

  function oor(input [31:0] a, input [7:0] len, input [1:0] burst);
    reg [31:0] last;
    begin
      last = a + {len, 2'b00};
      if (a >= 32'd1024) oor = 1'b1;
      else if (burst == 2'd1 && last >= 32'd1024) oor = 1'b1;
      else oor = 1'b0;
    end
  endfunction

  function [31:0] merge(input [31:0] old, input [31:0] nw, input [3:0] s);
    merge = {s[3] ? nw[31:24] : old[31:24], s[2] ? nw[23:16] : old[23:16],
             s[1] ? nw[15:8]  : old[15:8],  s[0] ? nw[7:0]   : old[7:0]};
  endfunction

  // ================= write path
  localparam WI = 2'd0, WD = 2'd1, WR = 2'd2;
  reg [1:0] wst; reg [3:0] wid; reg [31:0] waddr; reg [1:0] wburst; reg werr;
  wire w_ok = THROTTLE ? (lf[0] | lf[5]) : 1'b1;
  assign AWREADY = (wst == WI);
  assign WREADY  = (wst == WD) && w_ok;
  assign BVALID  = (wst == WR);
  assign BID     = wid;
  assign BRESP   = werr ? 2'b10 : 2'b00;
  wire aw_hs = AWVALID && AWREADY;
  wire w_hs  = WVALID && WREADY;
  wire [1:0] wburst_eff = (bug == 4'd2 && wburst == 2'd0) ? 2'd1 : wburst;   // BUG2: FIXED treated as INCR

  always @(posedge ACLK) begin
    if (!ARESETn) begin wst <= WI; werr <= 1'b0; wid <= 4'd0; waddr <= 32'd0; wburst <= 2'd0; end
    else case (wst)
      WI: if (aw_hs) begin
            wid <= AWID; waddr <= AWADDR; wburst <= AWBURST;
            if (bug == 4'd8)      werr <= oor(AWADDR, AWLEN, AWBURST);               // BUG8: WRAP not flagged
            else if (bug == 4'd5) werr <= (AWBURST == 2'd2);                          // BUG5: write OOR not flagged
            else                  werr <= (AWBURST == 2'd2) || oor(AWADDR, AWLEN, AWBURST);
            wst <= WD;
          end
      WD: if (w_hs) begin
            if (!werr && !(bug == 4'd4 && WLAST))                                     // BUG4: last beat dropped
              mem[waddr[9:2]] <= merge(mem[waddr[9:2]], WDATA, (bug == 4'd1) ? 4'hF : WSTRB); // BUG1: strobes ignored
            if (WLAST) wst <= WR;
            else if (wburst_eff == 2'd0) waddr <= waddr;
            else if (bug == 4'd7) waddr <= {waddr[31:8], waddr[7:0] + 8'd4};         // BUG7: increment wraps at 256 B
            else waddr <= waddr + 32'd4;
          end
      WR: if (BREADY) wst <= WI;
      default: wst <= WI;
    endcase
  end

  // ================= read path
  localparam RI = 1'b0, RD = 1'b1;
  reg rst_; reg [3:0] rid_r; reg [31:0] raddr; reg [7:0] rcnt, rlen_r; reg [1:0] rburst; reg rerr; reg rgate;
  assign ARREADY = (rst_ == RI) && (THROTTLE ? (lf[3] | lf[9]) : 1'b1);
  assign RVALID  = (rst_ == RD) && rgate;
  assign RID     = rid_r;
  assign RDATA   = rerr ? 32'd0 : mem[raddr[9:2]];
  assign RRESP   = rerr ? 2'b10 : 2'b00;
  assign RLAST   = (bug == 4'd3 && rlen_r != 8'd0) ? (rcnt == rlen_r - 8'd1) : (rcnt == rlen_r); // BUG3: RLAST one beat early
  wire ar_hs = ARVALID && ARREADY;
  wire r_hs  = RVALID && RREADY;
  wire [1:0] rburst_eff = rburst;
  wire [31:0] rnext = (rburst_eff == 2'd0) ? raddr : raddr + 32'd4;

  always @(posedge ACLK) begin
    if (!ARESETn) begin rst_ <= RI; rgate <= 1'b0; rid_r <= 4'd0; raddr <= 32'd0; rcnt <= 8'd0; rlen_r <= 8'd0;
                        rburst <= 2'd0; rerr <= 1'b0; end
    else case (rst_)
      RI: if (ar_hs) begin
            rid_r <= ARID; raddr <= ARADDR; rlen_r <= ARLEN; rburst <= ARBURST; rcnt <= 8'd0;
            rerr <= (ARBURST == 2'd2) || oor(ARADDR, ARLEN, ARBURST);
            rgate <= THROTTLE ? (lf[7] | lf[2]) : 1'b1; rst_ <= RD;
          end
      RD: begin
            if (!rgate) rgate <= THROTTLE ? (lf[7] | lf[2] | lf[11]) : 1'b1;
            if (r_hs) begin
              if (rcnt == rlen_r) rst_ <= RI;
              else begin rcnt <= rcnt + 8'd1; raddr <= rnext; end
              rgate <= THROTTLE ? (lf[7] | lf[2]) : 1'b1;
            end else if (RVALID && !RREADY && bug == 4'd6) raddr <= rnext;           // BUG6: data advances during stall
          end
    endcase
  end
endmodule
