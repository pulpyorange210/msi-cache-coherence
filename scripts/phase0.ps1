# Phase 0 toolchain gate (xsim). Run from the repo root after sourcing the toolchain
# (see "Before resuming" in CLAUDE.md). Exits non-zero if any gate item is missing.
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force results | Out-Null
xvlog -sv -L uvm -f sim/p0.f                                    ; if ($LASTEXITCODE) { exit 1 }
xelab p0_tb -L uvm -s p0_sim -timescale 1ns/1ps -debug typical  ; if ($LASTEXITCODE) { exit 1 }
xsim p0_sim -R -testplusarg "`"UVM_TESTNAME=p0_test`"" -log results/p0.log | Out-Null
$log = Get-Content results/p0.log -Raw

$checks = [ordered]@{
    "UVM test ran"                = $log -match "hello from UVM on xsim"
    "Covergroup reported %"       = $log -match "COV: p0_checker cg_st 100\.00%"
    "Bound assertion fired once"  = $log -match "P0_SVA fired exactly once"
    "Hier ref into generate"      = $log -match "P0_HIER.*\(resolved\)"
    "UVM_ERROR : 0"               = $log -match "UVM_ERROR\s*:\s*0\b"
    "UVM_FATAL : 0"               = $log -match "UVM_FATAL\s*:\s*0\b"
}
$fail = $false
foreach ($k in $checks.Keys) {
    $ok = $checks[$k]; if (-not $ok) { $fail = $true }
    "{0,-28} {1}" -f $k, $(if ($ok) { "PASS" } else { "FAIL" })
}
if ($fail) { exit 1 } else { "Phase 0: PASS" }
