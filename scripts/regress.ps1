# Mutation regression: for each of {none, MUT_1..MUT_6}: compile the RTL with the
# define, elaborate its own snapshot (coh_sim / coh_sim_m<k>), run every test x
# every seed, and emit one table: mutant, runs failed, tests failed, first error
# ID, coverage. The unmutated row must be all-pass; every mutant must be caught.
# Writes results/regress.md. Run from the repo root with the toolchain on PATH.
param([int[]] $Seeds = 1..20, [int] $NOps = 1000, [int] $Parallel = 8)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force results | Out-Null

$tests   = "coh_private_test", "coh_share_test", "coh_conflict_test", "coh_pingpong_test", "coh_falseshare_test"
$mutants = @("none") + (1..6 | ForEach-Object { "MUT_$_" })

xvlog -sv -L uvm -f sim/tb.f | Out-Null; if ($LASTEXITCODE) { "xvlog tb failed"; exit 1 }

$rows = @()
foreach ($m in $mutants) {
    $snap = if ($m -eq "none") { "coh_sim" } else { "coh_sim_m" + $m.Substring(4) }
    if ($m -eq "none") { xvlog -f sim/rtl.f | Out-Null } else { xvlog -d $m -f sim/rtl.f | Out-Null }
    if ($LASTEXITCODE) { "xvlog rtl ($m) failed"; exit 1 }
    xelab tb_top -L uvm -s $snap -timescale 1ns/1ps -debug typical | Out-Null
    if ($LASTEXITCODE) { "xelab ($m) failed"; exit 1 }

    Write-Host "=== $m ($snap)"
    $r = & "$PSScriptRoot/run_tests.ps1" -Snapshot $snap -Tests $tests -Seeds $Seeds -NOps $NOps -Parallel $Parallel -Quiet -PassThru

    $failed   = @($r | Where-Object { -not $_.Pass })
    $tfailed  = @($failed | Select-Object -ExpandProperty Test -Unique)
    # First error per failing run; report the most common, then the others.
    $firsts   = $failed | Group-Object FirstErr | Sort-Object Count -Descending
    $firstStr = ($firsts | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join ", "
    # Coverage: union of bins over every run of this mutant, and mean covergroup %.
    $u = @{}
    foreach ($x in $r) { foreach ($k in $x.Bins.Keys) { if (-not $u.ContainsKey($k)) { $u[$k] = 0 }; $u[$k] += $x.Bins[$k] } }
    $binsHit = @($u.Keys | Where-Object { $u[$_] -gt 0 }).Count
    $covs    = @($r | Where-Object { $_.Cov -ne $null } | ForEach-Object { $_.Cov })
    $lats    = @($r | Where-Object { $_.LatWorst -ne $null } | ForEach-Object { $_.LatWorst })
    $rows += [pscustomobject]@{
        Mutant      = $m
        RunsFailed  = "$($failed.Count)/$($r.Count)"
        TestsFailed = "$($tfailed.Count)/$($tests.Count)"
        FirstError  = if ($firstStr) { $firstStr } else { "-" }
        BinsHit     = "$binsHit/$($u.Count)"
        CovRunAvg   = if ($covs.Count) { "{0:N1}%" -f ($covs | Measure-Object -Average).Average } else { "-" }
        LatWorst    = if ($lats.Count) { ($lats | Measure-Object -Maximum).Maximum } else { "-" }
        RaceDemote  = $u["ev_race_demote"]
        RaceInval   = $u["ev_race_inval"]
        Caught      = if ($m -eq "none") { if ($failed.Count -eq 0) { "all pass" } else { "FAIL" } }
                      else { if ($failed.Count -gt 0) { "caught" } else { "MISSED" } }
    }
}

# Leave the work library and coh_sim on the unmutated RTL.
xvlog -f sim/rtl.f | Out-Null

$rows | Format-Table -AutoSize | Out-String -Width 250 | Write-Host

$md  = "| Mutant | Runs failed | Tests failed | First error (count) | Bins hit | Covergroup % (run avg) | Worst latency | Result |`n"
$md += "|---|---|---|---|---|---|---|---|`n"
foreach ($x in $rows) {
    $md += "| $($x.Mutant) | $($x.RunsFailed) | $($x.TestsFailed) | $($x.FirstError) | $($x.BinsHit) | $($x.CovRunAvg) | $($x.LatWorst) | $($x.Caught) |`n"
}
$md | Out-File -Encoding utf8 results/regress.md
"Table written to results/regress.md"

$ok = ($rows[0].Caught -eq "all pass") -and (@($rows | Select-Object -Skip 1 | Where-Object { $_.Caught -ne "caught" }).Count -eq 0)
if ($ok) { "Regression: PASS (unmutated all-pass, every mutant caught)" } else { "Regression: FAIL"; exit 1 }
