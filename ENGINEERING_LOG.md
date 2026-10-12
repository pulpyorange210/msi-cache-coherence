# Engineering Log — N-core MSI Snooping Cache Coherence

Every entry is a complete fact: what was built or fixed, the mechanism, the
measurable outcome, and the tool (xsim, Yosys, Vivado).

## Decisions

| # | Decision | Reason |
|---|---|---|
| D1 | Atomic shared bus: one transaction in flight from grant to `bus_done`; no transient states | Removes every interleaving race at the protocol level, so MSI needs only 3 stable states and verification targets real bugs, not transient-state explosion. |
| D2 | S→M upgrade always uses `BusRdX` with data; no `BusUpgr` | A data-free upgrade loses if another cache invalidates the S copy while the upgrader waits for the bus (lost-upgrade race). |
| D3 | M owner supplies data on any snoop hit; memory is written only on snooped `BusRd` | Keeps invariant "every S line equals memory"; on `BusRdX` the requester takes M, so a memory write would be wasted. |
| D4 | Decide the transaction at grant, not at request | Other caches can demote or invalidate a waiting cache's lines; re-reading state at grant guarantees every grant yields exactly one correct transaction. |
| D5 | Snoops beat local accesses: no non-requester services a local access to the set under transaction | Prevents a store hitting an M line in the same window a snoop hands it away (lost store). |
| D6 | 2-way set-associative, victim = lowest invalid way else LRU; LRU updates only on local hit or completed fill | Invalid-first avoids needless evictions; restricting LRU updates keeps replacement correct, checked by a shadow-MRU LRU checker. |
| D7 | 4 sets × 16 B lines (4 × 32-bit words), whole line in one bus beat | Small enough that random traffic forces conflicts and evictions constantly; one-beat lines keep the bus FSM simple. |
| D8 | Testbench memory with random 2–8 cycle latency, seeded by `-sv_seed` | Exposes ordering and timing-dependent bugs that fixed latency hides, while staying reproducible per seed. |
| D9 | `N` (and `WAYS`, `SETS`, widths) fully parameterized; tested at N=2 | Scaling cores or ways is an instantiation change, not a rewrite. |
| D10 | Minimal UVM: per-core agents, one flat-memory scoreboard, no virtual sequencer, no RAL; `config_db` carries only virtual interfaces | Minimal structure that still gives randomized multi-core traffic and a single pass/fail authority within the build window. |
| D11 | Snoop-beats-local is `req_ready` low when another cache's transaction (SNOOP through DONE) is on the request's set; `req_ready` therefore depends on `req_addr`, and drivers must hold the address stable while `req_valid` is high | Blocks the lost-store window at the core boundary with one comparator per cache; no extra controller state. |
| D12 | Bus FSM is `ARB → SNOOP → (MEM) → DONE`, grant registered in ARB; the requester decides its command combinationally in SNOOP from current state and latches it, and the bus latches cmd/addr at the end of SNOOP | Decide-at-grant with no wasted cycle. The snoop lookup is combinational in SNOOP, and every register stage breaks the bus_addr → owner_hit → FSM path, so there are no combinational loops. Minimum transaction: 3 cycles (owner + BusRdX). |
| D13 | Store hit = read of S/M or write of M; a write to S goes to the bus as BusRdX (no hit-path LRU update) | Keeps invariant 8: LRU only advances on true hits and completed fills. |
| D14 | `rr_arbiter` written from scratch (not reused from the NoC repo); pointer advances only when a grant is taken | Fairness guarantee needed for the latency bound K. |

| D15 | `mem_model` commits writes with a blocking assignment into its associative array | xsim 2025.1 rejects non-blocking assignment to associative arrays ([XSIM 43-3980]); the array has one writer in one clocked block, so blocking is race-free for the model itself. |
| D16 | Plusargs and generics containing `=` are passed to `xsim.bat`/`xelab.bat` wrapped in embedded quotes (`"`"UVM_TESTNAME=x`""`) | Windows batch wrappers split arguments at `=`; unquoted, xsim reports "Expected a switch but found p". |
| D17 | Yosys reads RTL by relative path (`rtl/<file>.v`), not `FullName` | The repo path contains spaces; Yosys splits an absolute path at the space and fails to find the file. |
| D18 | `bus_if` is sized to the project limits (4 cores × 2 ways), not to the DUT's `N`/`WAYS`; `tb_top` drives existing entries hierarchically from `cache_store` and ties the rest to I | The UVM package is compiled once but `N` is set per snapshot (`xelab -generic_top`); a parameterized virtual interface would need a different type per `N`. Fixed sizing gives one `virtual bus_if` for every snapshot. |
| D19 | The env learns `N` by counting `core_vif_<i>` entries in `config_db`; agents get `vif`/`core_id` by handle from the env | Keeps `config_db` to virtual interfaces only (D10) with no separate `N` knob to keep in sync. |
| D20 | End-of-test check reads the coherent value through `bus_if.coherent_word()` (M copy from the cache snapshot, else `u_mem.peek()`), not by issuing extra loads | Checks the stored state directly, independently of the DUT read path, and does not perturb the cache state it is checking. |
| D21 | `MUT_5` (dirty-victim writeback skipped) implemented in Phase 2, ahead of Phase 6 | Proves the scoreboard can fail before trusting its passes: 472 `SB_LOAD` errors on `coh_private_test` seed 1 (xsim). |
| D22 | Parallel regression: each worker runs in its own directory holding a private copy of the snapshot (`scripts/run_tests.ps1`) | See B3; 100 runs at N=1 complete in 69 s on 8 workers versus ~6 s per run sequentially. |
| D23 | Latency bound **K = 2N·T + 1, T = LAT_MAX + 5** (= 53 at N=2, LAT_MAX=8), measured from the accept edge to the edge sampling `resp_valid` | T: 1 ARB + 1 SNOOP + (LAT_MAX + 2) MEM (mem_model samples `mem_req` on the first MEM edge, acks LAT edges later, the bus sees the ack one edge after) + 1 DONE. A request needs ≤ 2 own transactions (BusWB then fill; after the WB the victim way is invalid so no second WB). Round-robin lets each of the other N−1 caches win ≤ 1 grant before each own grant ⇒ ≤ 2N transactions; +1 for `bus_done`→`resp_valid`. Checks: N=1 gives K=27, exactly the N=1 measured worst case; the N=2 regression reaches exactly 53. The pre-accept stall from snoop-beats-local is excluded (bounded separately by one transaction, since the ARB cycle between transactions reopens `req_ready`). |
| D24 | Coverage is reported two ways: the covergroup % per run (xsim `get_coverage()`, type coverage over both caches), and a merged figure = union of the 27 covergroup bins across all runs, from per-bin counters the checker prints as `COV_BINS:` | xsim covergroups do not merge across separate simulation runs without extra tooling (`xcrg`); each traffic mode deliberately covers only part of the space (e.g. `coh_share_test` never evicts), so per-run % understates what the regression covers. |
| D25 | `MUT_3` ("transaction chosen at request") commits at accept to the command, victim way, address, writeback data, **and** — for a write to an S line — an upgrade that keeps the local copy, then replays all of it at grant | With BusRdX-with-data (D2) and blocking caches, merely latching the command at request is benign: every path refetches data. The bug decide-at-grant prevents is acting on request-time state, and the concrete consequence is the lost upgrade: the S copy was invalidated (and the line rewritten elsewhere) while waiting, yet the stale local line is promoted to M. |
| D26 | Invariants 2 and 3 are checked at negedge in `system_checker` with immediate assertions, reporting a violation once when it appears | At negedge every register and the memory model (blocking write at posedge, D15) are settled, so there is no same-edge race; one report per violation onset keeps a persistent stale line from flooding the log. |
| D27 | LRU checker treats a completed fill whose way already holds the requested tag (non-I) as an upgrade (no victim check); every other fill, and every BusWB, gets a victim check | An S→M upgrade reuses its own way and is not a replacement decision; a BusWB is the replacement decision for a dirty victim and must also avoid the MRU way. |

## Bugs

### B1 — Phase 0 probe: generate-block counter wrapped to zero (xsim)
- **Symptom:** `phase0.ps1` item "Hier ref into generate" FAIL; `P0_HIER` reported `dut.g_way[1].cnt = 0`.
- **Caught by:** the probe's own `P0_HIER` `uvm_error` check on xsim.
- **Root cause:** the 4-bit counter stepping by 2 per cycle reached exactly 32 mod 16 = 0 at the probe cycle; the hierarchical reference itself resolved fine.
- **Fix:** widened `cnt` to 8 bits in `tb/phase0/p0_dut.v` and the compare in `p0_tb.sv`.
- **Before/after:** 5/6 → 6/6 Phase 0 items PASS.

### B2 — Phase 0/1 scripts: tool invocation on Windows
- **Symptom:** `xsim` "Expected a switch but found p"; Yosys "File `C:\Users\rishi\Downloads\coherence' not found"; xelab [XSIM 43-3980] on `mem_model.sv:55`.
- **Caught by:** first runs of `phase0.ps1` / `smoke.ps1` on the Windows machine.
- **Root cause:** batch-wrapper `=` splitting, spaces in the repo path, and an xsim limitation on NBA to associative arrays (D15–D17).
- **Fix:** quoted plusarg, relative Yosys paths, blocking memory write.
- **Before/after:** both gates failed to run → both gates PASS.

### B3 — Parallel xsim runs silently ran the wrong test and seed
- **Symptom:** 8 parallel seeds of `coh_private_test` printed byte-identical `STAT:` lines; then `coh_private_test_s1.log` turned out to contain a `coh_conflict_test` run with `-sv_seed 4`.
- **Caught by:** cross-checking `STAT:` lines across seeds and the `# xsim {...}` command echo in each xsim log, before any gate result was recorded.
- **Root cause:** `xsim <snap> -R` (and `-runall`) writes its arguments to the shared `xsim.dir/<snap>/xsim_script.tcl` and then sources it, so concurrent launches on one snapshot overwrite each other's test name and seed.
- **Fix:** `run_tests.ps1` copies the snapshot into one working directory per worker (`results/_work/<snap>/w<k>`) and launches xsim there.
- **Before/after:** 8 runs = 1 distinct run → 8 distinct runs; seed 1 reproduces the sequential run exactly (115 hits, 1352 bus transactions).

### B4 — system_checker: loop-local flags were static (xsim)
- **Symptom:** xvlog warning [VRFC 10-3824] "variable 'swmr' must explicitly be declared as automatic or static" (also `lat`).
- **Caught by:** xvlog compile of `tb/system_checker.sv`, before the first run.
- **Root cause:** a variable declared with an initializer inside a procedural loop is static by default in a module, so `bit swmr = 0` is initialized once at time 0 and never cleared — after the first violation the single-writer check would stay latched (and `lat` would be shared state).
- **Fix:** declared both `automatic`.
- **Before/after:** warning gone; unmutated regression 0 errors, MUT_1 reports SYS_SWMR on onset only.

### B5 — cache_checker: xsim kernel crash on string-keyed coverage counters
- **Symptom:** `FATAL_ERROR: Vivado Simulator kernel has discovered an exceptional condition` at 195 ns in `cache_checker.sv` (process `Always293`), on every run.
- **Caught by:** first `coh_conflict_test` run after adding per-bin counters (xsim 2025.1).
- **Root cause:** per-bin hit counters kept in an `int unsigned [string]` associative array updated with concatenated/`$sformatf` keys inside a bound module crash the xsim kernel (the first attempt also used `bins` as an identifier, a SystemVerilog keyword).
- **Fix:** fixed-size integer arrays (`h_local[3][2]`, `h_snoop[3][2]`, `h_hitw`, `h_evict`, `h_vic`) with names generated only in the `final` block.
- **Before/after:** crash on every run → 100/100 runs complete, `COV_BINS` printed per cache.

## Gate results

| Gate | Result | Evidence | Tool | Date |
|---|---|---|---|---|
| Phase 0 | PASS | UVM hello, covergroup `cg_st` 100.00%, bound SVA fired exactly once (caught + demoted), hier ref `dut.g_way[1].cnt` resolved; UVM_ERROR 0, UVM_FATAL 0 | xsim 2025.1 | 12 Oct 00:00 |
| Phase 1 | PASS | `tb_smoke` (N=1, WAYS=1): 11 accesses, all loads match reference; read/write hits 1 cycle; bus BusRd=3 BusRdX=2 BusWB=1; memory B/B2 hold written values after WB; silent S eviction issues no BusWB | xsim 2025.1 | 12 Oct 00:01 |
| Phase 1 | PASS | `coh_top` (N=2, WAYS=1): `check -assert` clean, 0 `$dlatch`, 0 warnings, 12019 generic cells (1926 FFs) | Yosys 0.68 | 12 Oct 00:01 |
| Phase 2 | PASS | `scripts/phase2.ps1`: N=1, WAYS=1, 5 tests × 20 seeds = 100 runs, 100,000 accesses, 0 UVM_ERROR, 0 UVM_FATAL; every load checked against the flat reference, every touched word checked at end of test | xsim 2025.1 | 12 Oct 00:10 |
| Phase 2 (negative) | FAIL as expected | `MUT_5` snapshot: 9/9 runs (3 tests × 3 seeds) fail, first error `SB_LOAD` | xsim 2025.1 | 12 Oct 00:10 |
| Phase 3 | PASS | `coh_sim` (N=2, WAYS=1): 5 tests × 20 seeds = 100 runs, 200,000 accesses, 0 UVM_ERROR, 0 UVM_FATAL, first run with no RTL change; snoop path exercised (owner transfers per run: share 555, conflict 183, pingpong 1302, falseshare 1034). RTL unchanged since the 00:11 Yosys check (clean). | xsim 2025.1 | 12 Oct 05:19 |
| Phase 4 | PASS | `coh_sim_w2` (N=2, WAYS=2): 5 tests × 20 seeds = 100 runs, 200,000 accesses, 0 errors, no RTL change (the way-generic code worked first time at WAYS=2). `WAYS=2` is now the default in `coh_top` and `tb_top`. | xsim 2025.1 | 12 Oct 05:22 |
| Phase 4 | PASS | `coh_top` (N=2, WAYS=2): `check -assert` clean, 0 latches, 0 warnings, 16195 generic cells (3182 FFs); smoke (WAYS=1) re-run PASS | Yosys 0.68 + xsim | 12 Oct 05:23 |
| Phase 5 | PASS | `coh_sim` (N=2, WAYS=2) with `cache_checker` bound into both caches and `system_checker` in `tb_top`: 5 tests × 20 seeds = 100 runs, 200,000 accesses, 0 UVM_ERROR, 0 UVM_FATAL. Merged coverage 27/27 bins hit (100%); race bins: victim demoted M→S while waiting = 464 hits, S line invalidated while waiting to upgrade = 3241 hits. Worst-case request latency 53 cycles = derived bound K = 53 (bound met with zero slack, in `coh_conflict_test`). | xsim 2025.1 | 12 Oct 05:33 |
| Phase 6 | PASS | `scripts/regress.ps1`: 7 snapshots (none, MUT_1..MUT_6) × 5 tests × 20 seeds = 700 runs in 9.9 min. Unmutated: 0/100 runs failed. Every mutant caught (table below). | xsim 2025.1 | 12 Oct 05:42 |
| Phase 6 | PASS | Final RTL (all mutation `ifdef`s present, none defined): `check -assert` clean, 0 latches, 0 warnings; smoke PASS | Yosys 0.68 + xsim | 12 Oct 05:43 |
| Phase 7 (optional) | DONE | `impl/synth.tcl`: Vivado out-of-context synth + place + route on xc7a100tcsg324-1, 0 errors, 0 critical warnings, 0 latches; 3240 LUT / 724 FF / 70.8 MHz | Vivado 2025.1 | 12 Oct 05:47 |
| Phase 7 | DONE | README: Mermaid block diagram, traffic-mode table, mutation table, coverage, synthesis, one-command run (`scripts/regress.ps1`) | — | 12 Oct 05:50 |
| Phase 2 re-run | PASS | `phase2.ps1` with checkers bound, N=1, WAYS=2: 100 runs, 0 errors; N=1 worst latency 27 = K(N=1) = 27 | xsim 2025.1 | 12 Oct 05:50 |
| Phase 2 re-check | PASS | `smoke.ps1` re-run after adding `MUT_5` ifdef: smoke PASS, Yosys 0 latches, 0 warnings | xsim + Yosys | 12 Oct 00:11 |

## Mutation results (xsim 2025.1, 12 Oct 05:42, N=2, WAYS=2, 5 tests × 20 seeds each)

| # | Injected bug | Runs failed | First check to fire (runs) | Every error ID seen (count over all runs) | Expected catcher | Match |
|---|---|---|---|---|---|---|
| — | none | 0/100 | — | — | all pass | yes |
| 1 | No invalidation on snooped BusRdX | 80/100 (all but private) | SYS_SWMR (80) | SYS_SWMR 9083, SB_LOAD 15376, SB_SAMECYC 1777, SYS_S_NEQ_MEM 385, SB_FINAL 218 | single-writer SVA, then scoreboard stale load | yes |
| 2 | Owner silent on snooped BusRd (no data, no memory write) | 80/100 | SYS_S_NEQ_MEM (80) | SYS_S_NEQ_MEM 23530, SB_LOAD 37207, SB_FINAL 173 | S == memory SVA | yes |
| 3 | Transaction chosen at request (D25) | 80/100 | SB_LOAD (48), CC_VICTIM_INV (32, all `coh_conflict_test`) | SB_LOAD 1547, CC_VICTIM_INV 861, SB_FINAL 8 | race bins + scoreboard | yes — race bins hit in the same runs (529 demote, 3208 inval); in conflict traffic the stale upgrade writes into a way that was invalidated while a lower way is free, which the victim checker sees first |
| 4 | Fixed-priority arbiter | 20/100 (`coh_private_test` only) | SYS_LATENCY (20) | **SYS_LATENCY 800 only** | only the latency-bound SVA | yes — worst latency 73 vs K = 53; zero data errors |
| 5 | Dirty victim writeback skipped | 40/100 (private, conflict: the evicting modes) | SB_LOAD (40) | SB_LOAD 26354, SB_FINAL 3884 | scoreboard on the next miss | yes |
| 6 | LRU not updated on hit | 40/100 (private, conflict) | CC_LRU (40) | **CC_LRU 5976 only** | only the LRU checker | yes — zero data errors |

Mutants caught: **6/6**. Mutants 4 and 6 never produce a wrong value; only the latency SVA and the shadow-MRU LRU checker see them.

## Numbers

| Metric | Value | Tool | Date |
|---|---|---|---|
| Smoke latencies (N=1) | hit 1 cycle; read miss 8; write miss 11; upgrade 9; miss + dirty WB 16 (memory latency 2–8 random) | xsim | 12 Oct |
| Generic cell count, `coh_top` N=2 WAYS=1 | 12019 cells, 1926 flip-flops, 0 latches | Yosys | 12 Oct |
| Phase 2 operations | 100 runs × 1000 accesses = 100,000 accesses, 0 errors | xsim | 12 Oct |
| N=1 hit rate / bus txn per op / avg latency (20 seeds each) | private 0.127 / 1.326 / 14.27; share 0.688 / 0.487 / 5.86; conflict 0.156 / 1.287 / 13.89; pingpong 0.999 / 0.001 / 1.01; falseshare 0.999 / 0.001 / 1.01 (single line at N=1, so near-all hits) | xsim | 12 Oct |
| Final regression operations (N=2, WAYS=2, unmutated) | 100 runs (5 tests × 20 seeds) × 2 cores × 1000 = 200,000 accesses, 0 errors; 700 runs / 1.4 M accesses including mutants | xsim | 12 Oct |
| Coverage (N=2, WAYS=2) | 27/27 bins (100%) merged over the regression; covergroup % per run averages 76.3% (traffic modes are deliberately narrow); `coh_conflict_test` alone reaches 100% per run | xsim | 12 Oct |
| Race bins | hit: victim demoted M→S while waiting = 464, S invalidated while waiting to upgrade = 3241 (over 100 runs) | xsim | 12 Oct |
| Worst-case request latency vs bound | 53 measured vs K = 53 derived (N=2, LAT_MAX=8); MUT_4 (fixed priority) reaches 73 | xsim | 12 Oct |
| Per mode, N=2 WAYS=2 (hit rate / bus txn per op / owner transfers per run / avg latency) | private 0.267 / 1.128 / 0 / 18.99; share 0.467 / 0.533 / 711 / 5.97; conflict 0.281 / 0.925 / 396 / 11.79; pingpong 0.224 / 0.776 / 1299 / 5.37; falseshare 0.294 / 0.706 / 1027 / 6.19 | xsim | 12 Oct |
| Event totals over the unmutated regression (both caches) | dirty evictions 24,024; silent S evictions 20,444; S→M upgrades 25,672; owner transfers 68,660 | xsim | 12 Oct |
| Generic cell count, `coh_top` N=2 WAYS=2 | 16195 cells, 3182 flip-flops, 0 latches | Yosys | 12 Oct |
| FPGA implementation, `coh_top` N=2 WAYS=2, xc7a100tcsg324-1, out-of-context, routed | 3240 LUTs (2408 logic + 832 LUTRAM holding the tag/data arrays), 724 FFs, 0 latches, 0 BRAM/DSP | Vivado 2025.1 | 12 Oct 05:47 |
| Fmax | 70.8 MHz (10 ns target, WNS −4.129 ns, reg-to-reg; ports unconstrained OOC). Critical path: `g_cache[0].u_cache` FSM state → port-A address mux → LUTRAM tag read → tag compare (CARRY4) → victim select → `dec_wdata` → `coh_bus` requester mux → `u_bus/data_r` (19 logic levels, 67% routing). Not optimized: registering the grant-time decision would cut it, at one cycle per transaction. | Vivado 2025.1 | 12 Oct 05:47 |
| N=1 worst-case request latency | 27 cycles (max over 100 runs; the worst case is a miss behind a dirty writeback, i.e. two back-to-back memory operations) | xsim | 12 Oct |
