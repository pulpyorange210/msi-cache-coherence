# Phase 1 gate: directed smoke test on xsim + Yosys latch/loop check.
# Run from the repo root after sourcing the toolchain (see "Before resuming").
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force results | Out-Null

xvlog -f sim/rtl.f                                                  ; if ($LASTEXITCODE) { exit 1 }
xvlog -sv -f sim/smoke.f                                            ; if ($LASTEXITCODE) { exit 1 }
xelab tb_smoke -s smoke_sim -timescale 1ns/1ps -debug typical       ; if ($LASTEXITCODE) { exit 1 }
xsim smoke_sim -R -sv_seed 1 -log results/smoke.log | Out-Null
$sim = Get-Content results/smoke.log -Raw
$simOk = $sim -match "SMOKE: PASS"
Select-String -Path results/smoke.log -Pattern "SMOKE:|Error" | ForEach-Object { $_.Line }

# Relative paths: the repo path contains spaces, which split read_verilog's file list.
$rtlFiles = (Get-ChildItem rtl\*.v | ForEach-Object { "rtl/" + $_.Name }) -join ' '
yosys -l results/yosys.log -p "read_verilog -I rtl $rtlFiles; hierarchy -top coh_top; proc; opt; fsm; opt; memory; opt; techmap; opt; check -assert; stat" | Out-Null
$ysOk = ($LASTEXITCODE -eq 0)
$ys = Get-Content results/yosys.log -Raw
$latches = ([regex]::Matches($ys, '\$_?DLATCH')).Count
Select-String -Path results/yosys.log -Pattern "Warning|loop|latch" | ForEach-Object { $_.Line }

"smoke (xsim)        {0}" -f $(if ($simOk) { "PASS" } else { "FAIL" })
"yosys check -assert {0}" -f $(if ($ysOk) { "PASS" } else { "FAIL" })
"yosys latch cells   {0}" -f $latches
if ($simOk -and $ysOk -and $latches -eq 0) { "Phase 1: PASS" } else { "Phase 1: FAIL"; exit 1 }
