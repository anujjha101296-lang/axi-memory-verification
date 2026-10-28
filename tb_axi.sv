// Layered AXI4 testbench (UVM-style architecture, plain SystemVerilog classes; runs on Verilator).
//   generator -> driver -> DUT ; monitor -> scoreboard (reference model) ; coverage collector
// Plusargs: +MODE=directed|random  +N=<txns>  +SEED=<n>  +BUG=<0..8>  +BP=<0..100 stall %>
`timescale 1ns/1ps

interface axi_if(input logic clk, input logic rstn);
  logic [3:0] awid; logic [31:0] awaddr; logic [7:0] awlen; logic [2:0] awsize; logic [1:0] awburst; logic awvalid, awready;
  logic [31:0] wdata; logic [3:0] wstrb; logic wlast, wvalid, wready;
  logic [3:0] bid; logic [1:0] bresp; logic bvalid, bready;
  logic [3:0] arid; logic [31:0] araddr; logic [7:0] arlen; logic [2:0] arsize; logic [1:0] arburst; logic arvalid, arready;
  logic [3:0] rid; logic [31:0] rdata; logic [1:0] rresp; logic rlast, rvalid, rready;
endinterface

package axi_pkg;
  typedef enum int {FIXED = 0, INCR = 1, WRAP = 2} burst_e;

  // ---------------------------------------------------------------- transaction
  class axi_txn;
    bit is_wr; bit [3:0] id; bit [31:0] addr; int len; burst_e burst;
    bit [31:0] data[$]; bit [3:0] strb[$];
    // observed (filled by monitor)
    bit [1:0] resp; bit [3:0] obs_id; bit [31:0] rdata[$]; bit [1:0] rresp[$]; int rlast_at; int nbeats;
    // stimulus-side stall counters (filled by driver)
    int rstall, bstall, wgap, awdelay;
    function new(); rlast_at = -1; endfunction
    function bit exp_err();
      if (burst == WRAP) return 1;
      if (addr >= 1024) return 1;
      if (burst == INCR && (addr + len * 4) >= 1024) return 1;
      return 0;
    endfunction
    function bit [31:0] beat_addr(int k); return (burst == FIXED) ? addr : addr + 4 * k; endfunction
    function string len_bucket();
      if (len == 0) return "0"; if (len <= 3) return "1-3"; if (len <= 7) return "4-7"; return "8-15";
    endfunction
  endclass

  // ---------------------------------------------------------------- coverage
  class axi_cov;
    bit hit[string]; int total;
    string dirs[2]; string bursts[3]; string lens[4]; string regs[4]; string strbs[5];
    function new();
      dirs = '{"wr", "rd"}; bursts = '{"FIXED", "INCR", "WRAP"}; lens = '{"0", "1-3", "4-7", "8-15"};
      regs = '{"low", "mid", "top", "oor"}; strbs = '{"full", "single", "pair", "zero", "sparse"};
      foreach (dirs[d]) begin
        foreach (bursts[b]) foreach (lens[l]) hit[$sformatf("x_%s_%s_len%s", dirs[d], bursts[b], lens[l])] = 0;
        hit[$sformatf("resp_%s_OKAY", dirs[d])] = 0; hit[$sformatf("resp_%s_SLVERR", dirs[d])] = 0;
        foreach (regs[r]) hit[$sformatf("reg_%s_%s", dirs[d], regs[r])] = 0;
      end
      foreach (strbs[s]) hit[$sformatf("strb_%s", strbs[s])] = 0;
      hit["cross256_yes"] = 0; hit["cross256_no"] = 0;
      hit["bp_rstall"] = 0; hit["bp_bstall"] = 0; hit["bp_wgap"] = 0; hit["bp_awdelay"] = 0;
      hit["read_after_write_same_addr"] = 0;
      total = hit.num();
    endfunction
    function string strb_class(bit [3:0] s);
      int n = $countones(s);
      if (s == 4'hF) return "full"; if (n == 0) return "zero"; if (n == 1) return "single";
      if (s == 4'b0011 || s == 4'b1100) return "pair"; return "sparse";
    endfunction
    function void mark(string k);
      if (!hit.exists(k)) $error("COV: undeclared bin [%s]", k); else hit[k] = 1;
    endfunction
    function void sample(axi_txn t, bit raw);
      string d, reg_s, rs; bit [1:0] rr;
      d = t.is_wr ? "wr" : "rd";
      mark($sformatf("x_%s_%s_len%s", d, t.burst.name(), t.len_bucket()));
      rr = t.is_wr ? t.resp : (t.rresp.size() ? t.rresp[0] : 2'b00);
      if (rr == 2'b00) rs = "OKAY"; else rs = "SLVERR";
      mark($sformatf("resp_%s_%s", d, rs));
      if (t.addr >= 1024) reg_s = "oor"; else if (t.addr < 256) reg_s = "low"; else if (t.addr < 768) reg_s = "mid"; else reg_s = "top";
      mark($sformatf("reg_%s_%s", d, reg_s));
      if (t.is_wr) foreach (t.strb[i]) mark($sformatf("strb_%s", strb_class(t.strb[i])));
      if (t.burst == INCR && t.addr < 1024) begin
        if ((t.addr / 256) != ((t.addr + t.len * 4) / 256)) mark("cross256_yes"); else mark("cross256_no");
      end
      if (t.rstall > 0) mark("bp_rstall"); if (t.bstall > 0) mark("bp_bstall");
      if (t.wgap > 0) mark("bp_wgap");     if (t.awdelay > 0) mark("bp_awdelay");
      if (raw) mark("read_after_write_same_addr");
    endfunction
    function real pct(); int h = 0; foreach (hit[k]) if (hit[k]) h++; return 100.0 * h / total; endfunction
    function int nhit(); int h = 0; foreach (hit[k]) if (hit[k]) h++; return h; endfunction
    function void report_holes(); foreach (hit[k]) if (!hit[k]) $display("  HOLE %s", k); endfunction
  endclass

  // ---------------------------------------------------------------- generator
  class axi_gen;
    mailbox #(axi_txn) out; int unsigned wr_pool[$];
    function new(mailbox #(axi_txn) m); out = m; endfunction
    function int pick_len();
      int r = $urandom_range(0, 99);
      return (r < 40) ? 0 : (r < 70) ? $urandom_range(1, 3) : (r < 90) ? $urandom_range(4, 7) : $urandom_range(8, 15);
    endfunction
    function axi_txn rand_txn();   // constrained-random (weights + legality constraints in procedural form)
      axi_txn t = new(); int r = $urandom_range(0, 99);
      t.is_wr = ($urandom_range(0, 99) < 55);
      t.id = $urandom_range(0, 15);
      t.burst = (r < 55) ? INCR : (r < 85) ? FIXED : WRAP;
      t.len = pick_len();
      r = $urandom_range(0, 99);
      if (r < 40 && wr_pool.size())          t.addr = wr_pool[$urandom_range(0, wr_pool.size() - 1)];     // revisit written area
      else if (r < 70)                       t.addr = 4 * $urandom_range(0, 255);                          // anywhere legal
      else if (r < 85)                       t.addr = 256 * $urandom_range(1, 3) - 4 * $urandom_range(0, 6); // near 256B boundary
      else if (r < 93)                       t.addr = 1024 - 4 * $urandom_range(0, 15);                    // top of memory
      else                                   t.addr = 1024 + 4 * $urandom_range(0, 63);                    // out of range
      if (t.is_wr) begin
        for (int k = 0; k <= t.len; k++) begin
          t.data.push_back($urandom);
          r = $urandom_range(0, 99);
          t.strb.push_back((r < 55) ? 4'hF : (r < 70) ? (4'b1 << $urandom_range(0, 3)) : (r < 80) ? ($urandom_range(0, 1) ? 4'b0011 : 4'b1100) : (r < 85) ? 4'h0 : $urandom_range(1, 14));
        end
        if (t.addr < 1024 && t.burst != WRAP) for (int k = 0; k <= t.len; k++) wr_pool.push_back(t.beat_addr(k) & 32'h3FF);
      end
      return t;
    endfunction
    function axi_txn mk(bit w, bit [31:0] a, int len, burst_e b, bit [3:0] s = 4'hF);
      axi_txn t = new(); t.is_wr = w; t.addr = a; t.len = len; t.burst = b; t.id = $urandom_range(0, 15);
      if (w) for (int k = 0; k <= len; k++) begin t.data.push_back($urandom); t.strb.push_back(s); end
      return t;
    endfunction
    task directed();   // hand-written sanity suite a verification engineer writes first
      out.put(mk(1, 32'h10, 0, INCR));        out.put(mk(0, 32'h10, 0, INCR));
      out.put(mk(1, 32'h40, 3, INCR));        out.put(mk(0, 32'h40, 3, INCR));
      out.put(mk(1, 32'h80, 3, FIXED));       out.put(mk(0, 32'h80, 3, FIXED));
      out.put(mk(1, 32'h100, 15, INCR));      out.put(mk(0, 32'h100, 15, INCR));
      out.put(mk(1, 32'h20, 0, INCR, 4'b0100)); out.put(mk(0, 32'h20, 0, INCR));
      out.put(mk(1, 32'h3F8, 1, INCR));       out.put(mk(0, 32'h3F8, 1, INCR));
      out.put(mk(1, 32'h2000, 0, INCR));      out.put(mk(0, 32'h2000, 0, INCR));
      out.put(mk(1, 32'h60, 3, WRAP));
    endtask
    task random_n(int n); repeat (n) out.put(rand_txn()); endtask
  endclass

  // ---------------------------------------------------------------- driver
  class axi_driver;
    virtual axi_if vif; mailbox #(axi_txn) in; mailbox #(axi_txn) done; int bp;
    function new(virtual axi_if v, mailbox #(axi_txn) i, mailbox #(axi_txn) d, int bp_pct);
      vif = v; in = i; done = d; bp = bp_pct;
    endfunction
    function bit stall(); return ($urandom_range(0, 99) < bp); endfunction
    task do_write(axi_txn t);
      bit br;
      vif.awid <= t.id; vif.awaddr <= t.addr; vif.awlen <= t.len; vif.awsize <= 3'd2; vif.awburst <= t.burst; vif.awvalid <= 1;
      while (1) begin @(posedge vif.clk); if (vif.awready) break; t.awdelay++; end
      vif.awvalid <= 0;
      for (int k = 0; k <= t.len; k++) begin
        while (stall()) begin vif.wvalid <= 0; @(posedge vif.clk); t.wgap++; end
        vif.wdata <= t.data[k]; vif.wstrb <= t.strb[k]; vif.wlast <= (k == t.len); vif.wvalid <= 1;
        while (1) begin @(posedge vif.clk); if (vif.wready) break; end
      end
      vif.wvalid <= 0; vif.wlast <= 0;
      while (1) begin
        br = !stall(); vif.bready <= br; @(posedge vif.clk);
        if (vif.bvalid && br) break; if (vif.bvalid && !br) t.bstall++;
      end
      vif.bready <= 0;
    endtask
    task do_read(axi_txn t);
      bit br; int k = 0;
      vif.arid <= t.id; vif.araddr <= t.addr; vif.arlen <= t.len; vif.arsize <= 3'd2; vif.arburst <= t.burst; vif.arvalid <= 1;
      while (1) begin @(posedge vif.clk); if (vif.arready) break; t.awdelay++; end
      vif.arvalid <= 0;
      while (k < t.len + 3) begin
        br = !stall(); vif.rready <= br; @(posedge vif.clk);
        if (vif.rvalid && br) begin k++; if (vif.rlast) break; end
        else if (vif.rvalid && !br) t.rstall++;
      end
      vif.rready <= 0;
    endtask
    task run();
      axi_txn t;
      forever begin
        in.get(t);
        if (t.is_wr) do_write(t); else do_read(t);
        repeat ($urandom_range(0, 2)) @(posedge vif.clk);
        done.put(t);
      end
    endtask
  endclass

  // ---------------------------------------------------------------- monitor (independent bus observer)
  class axi_mon;
    virtual axi_if vif; mailbox #(axi_txn) obs; int proto_errs; int pk[string];
    function new(virtual axi_if v, mailbox #(axi_txn) o); vif = v; obs = o; endfunction
    function void perr(string k); proto_errs++; if (pk.exists(k)) pk[k]++; else pk[k] = 1; endfunction
    task run();
      axi_txn wt, rt; bit w_active = 0, wlast_seen = 0, r_active = 0;
      bit pb_stall = 0, pr_stall = 0; bit [3:0] pbid, prid; bit [1:0] pbresp, prresp; bit [31:0] prdata; bit prlast;
      forever begin
        @(posedge vif.clk);
        if (!vif.rstn) continue;
        // payload stability while stalled (AXI: valid must hold, payload must not change until ready)
        if (pb_stall && !(vif.bvalid && vif.bid == pbid && vif.bresp == pbresp)) perr("B_UNSTABLE_UNDER_STALL");
        if (pr_stall && !(vif.rvalid && vif.rid == prid && vif.rresp == prresp && vif.rdata == prdata && vif.rlast == prlast))
          perr("R_UNSTABLE_UNDER_STALL");
        pb_stall = vif.bvalid && !vif.bready; pbid = vif.bid; pbresp = vif.bresp;
        pr_stall = vif.rvalid && !vif.rready; prid = vif.rid; prresp = vif.rresp; prdata = vif.rdata; prlast = vif.rlast;
        // ---- write channels
        if (vif.awvalid && vif.awready) begin
          wt = new(); wt.is_wr = 1; wt.id = vif.awid; wt.addr = vif.awaddr; wt.len = vif.awlen; wt.burst = burst_e'(vif.awburst);
          w_active = 1; wlast_seen = 0;
        end
        if (vif.wvalid && vif.wready) begin
          if (!w_active) perr("W_WITHOUT_AW");
          else begin wt.data.push_back(vif.wdata); wt.strb.push_back(vif.wstrb); wt.nbeats++; if (vif.wlast) wlast_seen = 1; end
        end
        if (vif.bvalid && !wlast_seen) perr("B_BEFORE_WLAST");
        if (vif.bvalid && vif.bready && w_active) begin
          wt.resp = vif.bresp; wt.obs_id = vif.bid; obs.put(wt); w_active = 0; wlast_seen = 0;
        end
        // ---- read channels
        if (vif.arvalid && vif.arready) begin
          rt = new(); rt.is_wr = 0; rt.id = vif.arid; rt.addr = vif.araddr; rt.len = vif.arlen; rt.burst = burst_e'(vif.arburst);
          r_active = 1;
        end
        if (vif.rvalid && !r_active) perr("R_SPURIOUS");
        if (vif.rvalid && vif.rready && r_active) begin
          rt.rdata.push_back(vif.rdata); rt.rresp.push_back(vif.rresp); rt.obs_id = vif.rid; rt.nbeats++;
          if (vif.rlast && rt.rlast_at < 0) rt.rlast_at = rt.nbeats - 1;
          if (vif.rlast || rt.nbeats > rt.len + 1) begin obs.put(rt); r_active = 0; end
        end
      end
    endtask
  endclass

  // ---------------------------------------------------------------- scoreboard + reference model
  class axi_sb;
    mailbox #(axi_txn) done, obs; axi_cov cov; bit [31:0] ref_mem[256]; bit written[256];
    int checked, errors; int kinds[string]; int ncheck_curve; string curve[$];
    function new(mailbox #(axi_txn) d, mailbox #(axi_txn) o, axi_cov c);
      done = d; obs = o; cov = c; foreach (ref_mem[i]) begin ref_mem[i] = 0; written[i] = 0; end
    endfunction
    function void bad(string k, string detail);
      errors++; if (kinds.exists(k)) kinds[k]++; else kinds[k] = 1;
      if (kinds[k] <= 2) $display("  SB-ERR %s : %s", k, detail);
    endfunction
    function bit [31:0] merge(bit [31:0] old, bit [31:0] nw, bit [3:0] s);
      return {s[3] ? nw[31:24] : old[31:24], s[2] ? nw[23:16] : old[23:16], s[1] ? nw[15:8] : old[15:8], s[0] ? nw[7:0] : old[7:0]};
    endfunction
    task run();
      axi_txn e, o; bit raw; int w;
      forever begin
        done.get(e); obs.get(o); raw = 0;
        if (o.obs_id !== e.id) bad("ID_MISMATCH", $sformatf("exp %0d got %0d", e.id, o.obs_id));
        if (e.is_wr) begin
          if (o.nbeats != e.len + 1) bad("W_BEATS", $sformatf("exp %0d got %0d", e.len + 1, o.nbeats));
          if (o.resp != (e.exp_err() ? 2'b10 : 2'b00)) bad("WR_RESP", $sformatf("addr=%h len=%0d burst=%s exp %0d got %0d", e.addr, e.len, e.burst.name(), e.exp_err() ? 2 : 0, o.resp));
          if (!e.exp_err()) for (int k = 0; k <= e.len; k++) begin
            w = (e.beat_addr(k) & 32'h3FF) >> 2; ref_mem[w] = merge(ref_mem[w], e.data[k], e.strb[k]); written[w] = 1;
          end
          e.resp = o.resp;
        end else begin
          if (o.nbeats != e.len + 1) bad("RD_BEATS", $sformatf("exp %0d got %0d", e.len + 1, o.nbeats));
          if (o.rlast_at != e.len) bad("RLAST_POS", $sformatf("addr=%h len=%0d rlast at beat %0d", e.addr, e.len, o.rlast_at));
          for (int k = 0; k < o.rdata.size() && k <= e.len; k++) begin
            if (e.exp_err()) begin
              if (o.rresp[k] != 2'b10) bad("RD_RESP", $sformatf("expected SLVERR addr=%h", e.addr));
            end else begin
              w = (e.beat_addr(k) & 32'h3FF) >> 2;
              if (written[w]) raw = 1;
              if (o.rresp[k] != 2'b00) bad("RD_RESP", $sformatf("expected OKAY addr=%h", e.addr));
              if (o.rdata[k] !== ref_mem[w]) bad("RD_DATA", $sformatf("addr=%h beat %0d exp %h got %h", e.beat_addr(k), k, ref_mem[w], o.rdata[k]));
            end
          end
          e.rresp = o.rresp;
        end
        cov.sample(e, raw); checked++;
        if (checked % 25 == 0) curve.push_back($sformatf("%0d:%0.1f", checked, cov.pct()));
      end
    endtask
  endclass
endpackage

// ================================================================== top
module tb_top;
  import axi_pkg::*;
  logic clk = 0, rstn = 0; always #5 clk = ~clk;
  axi_if vif(clk, rstn);
  logic [3:0] bugv = 0;
  axi_mem #(.THROTTLE(1)) dut(.ACLK(clk), .ARESETn(rstn), .bug(bugv),
    .AWID(vif.awid), .AWADDR(vif.awaddr), .AWLEN(vif.awlen), .AWSIZE(vif.awsize), .AWBURST(vif.awburst), .AWVALID(vif.awvalid), .AWREADY(vif.awready),
    .WDATA(vif.wdata), .WSTRB(vif.wstrb), .WLAST(vif.wlast), .WVALID(vif.wvalid), .WREADY(vif.wready),
    .BID(vif.bid), .BRESP(vif.bresp), .BVALID(vif.bvalid), .BREADY(vif.bready),
    .ARID(vif.arid), .ARADDR(vif.araddr), .ARLEN(vif.arlen), .ARSIZE(vif.arsize), .ARBURST(vif.arburst), .ARVALID(vif.arvalid), .ARREADY(vif.arready),
    .RID(vif.rid), .RDATA(vif.rdata), .RRESP(vif.rresp), .RLAST(vif.rlast), .RVALID(vif.rvalid), .RREADY(vif.rready));

  string mode; int n, seed, bp, bugi;
  mailbox #(axi_txn) g2d = new(), d2s = new(), m2s = new();
  axi_gen gen; axi_driver drv; axi_mon mon; axi_sb sb; axi_cov cov;
  int total_txns; bit hang;

  initial begin
    if (!$value$plusargs("MODE=%s", mode)) mode = "random";
    if (!$value$plusargs("N=%d", n)) n = 500;
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    if (!$value$plusargs("BP=%d", bp)) bp = (mode == "directed") ? 0 : 35;
    if (!$value$plusargs("BUG=%d", bugi)) bugi = 0;
    bugv = bugi[3:0];
    void'($urandom(seed));
    vif.awvalid = 0; vif.wvalid = 0; vif.bready = 0; vif.arvalid = 0; vif.rready = 0; vif.wlast = 0;
    vif.awid = 0; vif.awaddr = 0; vif.awlen = 0; vif.awsize = 2; vif.awburst = 1; vif.wdata = 0; vif.wstrb = 0;
    vif.arid = 0; vif.araddr = 0; vif.arlen = 0; vif.arsize = 2; vif.arburst = 1;
    repeat (4) @(posedge clk); rstn <= 1; repeat (2) @(posedge clk);
    cov = new(); gen = new(g2d); drv = new(vif, g2d, d2s, bp); mon = new(vif, m2s); sb = new(d2s, m2s, cov);
    fork drv.run(); mon.run(); sb.run(); join_none
    if (mode == "directed") gen.directed(); else gen.random_n(n);
    total_txns = (mode == "directed") ? 15 : n;
    // wait for completion or watchdog
    begin
      int cycles = 0, limit = 400 * total_txns + 5000;
      while (sb.checked < total_txns && cycles < limit) begin @(posedge clk); cycles++; end
      hang = (sb.checked < total_txns);
    end
    $display("SUMMARY mode=%s bug=%0d bp=%0d seed=%0d txns=%0d checked=%0d sb_errors=%0d proto_errors=%0d hang=%0d cov=%0.1f bins=%0d/%0d",
             mode, bugi, bp, seed, total_txns, sb.checked, sb.errors, mon.proto_errs, hang, cov.pct(), cov.nhit(), cov.total);
    foreach (sb.kinds[k]) $display("KIND %s %0d", k, sb.kinds[k]);
    foreach (mon.pk[k]) $display("PKIND %s %0d", k, mon.pk[k]);
    if (mode == "random") begin string c = ""; foreach (sb.curve[i]) c = {c, sb.curve[i], " "}; $display("CURVE %s", c); end
    if ($test$plusargs("HOLES")) cov.report_holes();
    $finish;
  end
endmodule
