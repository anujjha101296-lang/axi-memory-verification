# AXI4 layered verification
`axi_mem.v`: AXI4 slave (1 KB, INCR/FIXED bursts <=16 beats, byte strobes, SLVERR for WRAP and out-of-range, LFSR backpressure) with 8 injectable bugs (`+BUG=1..8`).
`tb_axi.sv`: generator, driver, independent monitor (stability/B-before-WLAST/spurious-R checks), scoreboard with reference memory, 48-bin functional coverage. Verilator 5 (plain SV classes, UVM-style architecture; not the UVM library).
Build: `verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_top -Mdir obj axi_mem.v tb_axi.sv`
Run: `./obj/Vtb_top +MODE=directed|random +N=500 +SEED=1 +BUG=0..8 +HOLES`; sweep: `python3 sweep.py`.
Results: directed (15 txns) 26/48 bins = 54.2%; constrained-random (500 txns) 48/48 = 100%. Bug detection: directed 6/8 (misses BUG6 read data advancing during stall, BUG7 INCR wrap at 256 B); random 8/8 on 5/5 seeds, first detection within 10-200 txns. Clean DUT: 0 scoreboard/protocol errors.
Limits: the directed suite is mine and deliberately basic; the 54% vs 100% gap depends on it.
