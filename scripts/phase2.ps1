# Phase 2 gate: full UVM env at N=1 (default WAYS, now 2; checkers bound), every
# traffic-mode test x 20 seeds,
# 0 UVM errors. Run from the repo root after sourcing the toolchain.
param([int[]] $Seeds = 1..20, [int] $NOps = 1000)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force results | Out-Null

xvlog -f sim/rtl.f                                                        | Out-Null; if ($LASTEXITCODE) { "xvlog rtl failed"; exit 1 }
xvlog -sv -L uvm -f sim/tb.f                                              | Out-Null; if ($LASTEXITCODE) { "xvlog tb failed"; exit 1 }
xelab tb_top -L uvm -s coh_sim_n1 -generic_top "`"N=1`"" -timescale 1ns/1ps -debug typical | Out-Null
if ($LASTEXITCODE) { "xelab failed"; exit 1 }

$tests = "coh_private_test", "coh_share_test", "coh_conflict_test", "coh_pingpong_test", "coh_falseshare_test"
$ok = & "$PSScriptRoot/run_tests.ps1" -Snapshot coh_sim_n1 -Tests $tests -Seeds $Seeds -NOps $NOps
if ($ok) { "Phase 2: PASS" } else { "Phase 2: FAIL"; exit 1 }
