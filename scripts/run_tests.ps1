# Run tests x seeds on an already-elaborated xsim snapshot, in parallel, and
# print one row per (test, seed) plus a per-test summary. Pass = log contains
# "UVM_ERROR :    0" and "UVM_FATAL :    0" in the report summary (and the run
# reached the summary at all). Returns $true if every run passed.
#
#   .\scripts\run_tests.ps1 -Snapshot coh_sim_n1 -Tests coh_private_test -Seeds 1..20
#
# Logs: results/<snapshot>/<test>_s<seed>.log. Toolchain must be on PATH.
param(
    [Parameter(Mandatory)] [string]   $Snapshot,
    [Parameter(Mandatory)] [string[]] $Tests,
    [int[]]  $Seeds    = 1..20,
    [int]    $NOps     = 1000,
    [int]    $Parallel = 8,
    [switch] $Quiet,
    [switch] $PassThru     # return the per-run result objects instead of a bool
)
$ErrorActionPreference = "Stop"
$dir = "results/$Snapshot"
New-Item -ItemType Directory -Force $dir | Out-Null

# Parallel runs must NOT share a snapshot directory: xsim rewrites
# xsim.dir/<snap>/xsim_script.tcl on every launch, so concurrent runs pick up each
# other's test name and seed. Each worker gets its own cwd with a private copy.
$jobs = @()
foreach ($t in $Tests) { foreach ($s in $Seeds) { $jobs += [pscustomobject]@{ Test = $t; Seed = $s } } }

$nw = [Math]::Min($Parallel, $jobs.Count)
$workers = @()
for ($k = 0; $k -lt $nw; $k++) {
    $wd = Join-Path (Resolve-Path results).Path "_work/$Snapshot/w$k"
    if (Test-Path $wd) { Remove-Item $wd -Recurse -Force }
    New-Item -ItemType Directory -Force "$wd/xsim.dir" | Out-Null
    Copy-Item -Recurse "xsim.dir/$Snapshot" "$wd/xsim.dir/$Snapshot"
    $workers += [pscustomobject]@{ Dir = $wd; Proc = $null }
}

$results = @()
$xsim = (Get-Command xsim.bat).Source
$absDir = (Resolve-Path $dir).Path
foreach ($j in $jobs) {
    $w = $null
    while (-not $w) {
        $w = $workers | Where-Object { $_.Proc -eq $null -or $_.Proc.HasExited } | Select-Object -First 1
        if (-not $w) { Start-Sleep -Milliseconds 200 }
    }
    $log    = "$absDir/$($j.Test)_s$($j.Seed).log"
    $argStr = "$Snapshot -R -testplusarg `"UVM_TESTNAME=$($j.Test)`" -testplusarg `"N_OPS=$NOps`" -sv_seed $($j.Seed) -log `"$log`""
    $w.Proc = Start-Process -FilePath $xsim -ArgumentList $argStr -WorkingDirectory $w.Dir -NoNewWindow -PassThru `
                            -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err"
}
foreach ($w in $workers) { if ($w.Proc) { $w.Proc.WaitForExit() } }

foreach ($j in $jobs) {
    $log = "$dir/$($j.Test)_s$($j.Seed).log"
    $txt = if (Test-Path $log) { Get-Content $log -Raw } else { "" }
    $errs  = if ($txt -match "UVM_ERROR\s*:\s*(\d+)") { [int]$Matches[1] } else { -1 }
    $fats  = if ($txt -match "UVM_FATAL\s*:\s*(\d+)") { [int]$Matches[1] } else { -1 }
    # First error in the log is the first in time. Paths may contain spaces.
    $first = if ($txt -match "(?m)^UVM_(ERROR|FATAL) .*? @ \d+: \S+ \[([^\]]+)\]") { $Matches[2] }
             elseif ($txt -match "FATAL_ERROR") { "XSIM_CRASH" } else { "" }
    $stat  = if ($txt -match "STAT: (.*)") { $Matches[1].Trim() } else { "" }
    $cov   = ([regex]::Matches($txt, "COV: \S+ .*?total=([\d.]+)%") | ForEach-Object { [double]$_.Groups[1].Value } |
              Measure-Object -Maximum).Maximum
    $lat   = if ($txt -match "LAT: worst=(\d+) K=(\d+)") { [int]$Matches[1] } else { $null }
    $k     = if ($txt -match "LAT: worst=\d+ K=(\d+)") { [int]$Matches[1] } else { $null }
    # Union of coverage bins hit in this run, over every cache.
    $bins = @{}
    foreach ($m in [regex]::Matches($txt, "COV_BINS: \S+ (.*)")) {
        foreach ($kv in $m.Groups[1].Value.Trim() -split '\s+') {
            $n, $v = $kv -split '='
            if (-not $bins.ContainsKey($n)) { $bins[$n] = 0 }
            $bins[$n] += [int]$v
        }
    }
    $results += [pscustomobject]@{
        Test = $j.Test; Seed = $j.Seed; Errors = $errs; Fatals = $fats
        Pass = ($errs -eq 0 -and $fats -eq 0); FirstErr = $first; Stat = $stat
        Cov = $cov; LatWorst = $lat; K = $k; Bins = $bins
    }
}

if (-not $Quiet) {
    $results | Where-Object { -not $_.Pass } |
        Format-Table Test, Seed, Errors, Fatals, FirstErr -AutoSize | Out-String | Write-Host
}
$summary = $results | Group-Object Test | ForEach-Object {
    $g = $_.Group
    # Average the STAT fields over seeds.
    $avg = @{}
    foreach ($f in "ops", "hit_rate", "txn_per_op", "owner", "lat_avg", "lat_max") {
        $vals = $g | ForEach-Object { if ($_.Stat -match "\b$f=([\d.]+)") { [double]$Matches[1] } }
        $avg[$f] = if ($vals) { ($vals | Measure-Object -Average -Maximum) } else { $null }
    }
    $covs = @($g | Where-Object { $_.Cov -ne $null } | ForEach-Object { $_.Cov })
    $lats = @($g | Where-Object { $_.LatWorst -ne $null } | ForEach-Object { $_.LatWorst })
    [pscustomobject]@{
        Test      = $_.Name
        Runs      = $g.Count
        Failed    = @($g | Where-Object { -not $_.Pass }).Count
        FirstErr  = (@($g | Where-Object { $_.FirstErr }) | Select-Object -First 1).FirstErr
        Ops       = if ($avg.ops) { [int]($avg.ops.Average * $g.Count) } else { 0 }
        HitRate   = if ($avg.hit_rate) { "{0:N3}" -f $avg.hit_rate.Average } else { "" }
        TxnPerOp  = if ($avg.txn_per_op) { "{0:N3}" -f $avg.txn_per_op.Average } else { "" }
        OwnerXfer = if ($avg.owner) { "{0:N1}" -f $avg.owner.Average } else { "" }
        LatAvg    = if ($avg.lat_avg) { "{0:N2}" -f $avg.lat_avg.Average } else { "" }
        LatMax    = if ($lats.Count) { ($lats | Measure-Object -Maximum).Maximum } elseif ($avg.lat_max) { [int]$avg.lat_max.Maximum } else { "" }
        CovAvg    = if ($covs.Count) { "{0:N2}" -f ($covs | Measure-Object -Average).Average } else { "" }
    }
}
$summary | Format-Table -AutoSize | Out-String | Write-Host
if ($PassThru) { return $results }
return (@($results | Where-Object { -not $_.Pass }).Count -eq 0)
