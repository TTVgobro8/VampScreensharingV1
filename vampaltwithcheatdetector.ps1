#Requires -Version 5.1

<#
.SYNOPSIS
    Vamp Cheat Scanner - Local Minecraft cheat-client detection & mod verification toolkit.

.DESCRIPTION
    A fully transparent, local-first detection tool. Every check runs on your own
    machine using built-in Windows/PowerShell commands. The ONE network call this
    script makes is a read-only lookup against the public Modrinth API to check
    whether a mod's hash matches a known, published project - it returns JSON
    metadata only and never executes anything. Everything else is fully offline.

    Modules:
      Phase 1  - Jar Parser        : hashes mods, verifies against Modrinth, flags unknowns
      Phase 2  - Deep Threat Scan  : scans unverified jars (incl. embedded jars) for
                                     known cheat-client signatures
      Phase 3  - BAM Parser        : reads Background Activity Moderator execution history
      Phase 4  - Services/Process  : flags known cheat-loader process & service names
      Phase 5  - Fileless Bypass   : reflective/in-memory load indicators on java.exe

.PARAMETER ModsPath
    Path to a mods folder. Defaults to %APPDATA%\.minecraft\mods if not supplied.

.PARAMETER ExportReport
    If set, writes a full JSON report to the Desktop after the scan completes.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\VampCheatScanner.ps1
    powershell -ExecutionPolicy Bypass -File .\VampCheatScanner.ps1 -ExportReport

.NOTES
    Name    : Vamp Cheat Scanner
    Version : 2.4.0
    No third-party scripts, no Invoke-Expression, no remote code execution.
    NOTE: This build uses plain ASCII characters only (no Unicode box-drawing
    or emoji) so it renders correctly regardless of file encoding / console
    codepage on the machine it runs on.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ModsPath,

    [Parameter(Mandatory = $false)]
    [switch]$ExportReport
)

# ============================================================================
#  CONFIGURATION
# ============================================================================

$script:Config = @{
    AppName        = "Vamp Cheat Scanner"
    Version        = "2.4.0"
    DefaultModsPath = "$env:APPDATA\.minecraft\mods"
    TempDirName    = "vamp_cheatscanner_tmp"
}

$ErrorActionPreference = "SilentlyContinue"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$script:Findings = New-Object System.Collections.Generic.List[Object]

# Known cheat-client / feature-module name fragments, used for local pattern
# matching only - the same style of signature list an antivirus engine or
# anti-cheat would use to flag known-bad names on a machine you control.
$script:CheatSignatures = @(
    "KillAura", "AimAssist", "TriggerBot", "AutoClicker", "Reach",
    "Velocity", "AntiKnockback", "NoFall", "Fly", "Speed", "Bhop",
    "Scaffold", "FastPlace", "AutoCrystal", "AutoAnchor", "AnchorTweaks",
    "AutoTotem", "InventoryTotem", "LegitTotem", "AutoPot", "AutoArmor",
    "AutoDoubleHand", "Hitboxes", "JumpReset", "PingSpoof", "SelfDestruct",
    "ShieldBreaker", "WebMacro", "AxeSpam", "ChestStealer", "ESP", "Xray",
    "wurst", "impact", "meteor-client", "meteorclient", "future-client",
    "sigma", "aristois", "rusherhack", "salhack", "kamiblue", "novoline",
    "flux", "b0at", "vape", "liquidbounce", "wolfram", "clickcrystals", "doomsday"
)

$script:KnownInjectorProcessNames = @("injector", "loader64", "loader32", "dllinject")

# Known-legitimate native (JNI) libraries that mods extract to a temp folder
# at runtime. These are native codec/audio libs bundled by common, verified
# mods - e.g. Simple Voice Chat's opus/rnnoise/speex/lame codecs, which get
# extracted at launch as "libNAMEj-<hash>\libNAMEj.dll". This is standard JNI
# behavior for any Java mod shipping native code, not a cheat-bypass
# technique, so Phase 5 whitelists these by filename pattern (the temp
# folder's hash suffix changes per install, so we match on filename only).
$script:KnownLegitTempModules = @(
    '^lib[a-z0-9]+4j\.dll$',   # opus4j / rnnoise4j / speex4j / lame4j (Simple Voice Chat JNI codecs)
    '^lwjgl.*\.dll$',           # LWJGL natives (core Minecraft/LWJGL dependency)
    '^glfw.*\.dll$',
    '^jinput-.*\.dll$',
    '^OpenAL.*\.dll$'
)

function Test-IsKnownLegitTempModule {
    param([string]$Path)
    $fileName = Split-Path $Path -Leaf
    foreach ($pattern in $script:KnownLegitTempModules) {
        if ($fileName -match $pattern) { return $true }
    }
    return $false
}

# ============================================================================
#  UI HELPERS  (ASCII-only visual theme)
# ============================================================================

function Get-RunningMinecraftInstances {
    <#
        Finds running java/javaw processes and tries to determine the actual
        game directory each one was launched from, by reading its command
        line (read-only WMI query, no code execution). Most launchers
        (vanilla, MultiMC, Prism, CurseForge, ATLauncher) pass --gameDir
        explicitly. If that's absent, we fall back to walking up from the
        Java classpath looking for a folder that contains "mods" or "saves"
        (the .minecraft/instance root signature).
    #>
    $javaProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^java(w)?$' }
    $instances = @()

    foreach ($jp in $javaProcs) {
        $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$($jp.Id)" -ErrorAction SilentlyContinue
        if (-not $cim -or -not $cim.CommandLine) { continue }
        $cmdLine = $cim.CommandLine
        $gameDir = $null

        if ($cmdLine -match '--gameDir\s+"([^"]+)"') { $gameDir = $matches[1] }
        elseif ($cmdLine -match '--gameDir\s+(\S+)') { $gameDir = $matches[1] }

        if (-not $gameDir) {
            $cpMatch = $null
            if ($cmdLine -match '-cp\s+"([^"]+)"') { $cpMatch = $matches[1] }
            elseif ($cmdLine -match '-classpath\s+"([^"]+)"') { $cpMatch = $matches[1] }
            elseif ($cmdLine -match '-cp\s+(\S+)') { $cpMatch = $matches[1] }

            if ($cpMatch) {
                $firstEntry = ($cpMatch -split ';')[0]
                $dir = Split-Path $firstEntry -Parent -ErrorAction SilentlyContinue
                for ($i = 0; $i -lt 6 -and $dir; $i++) {
                    if ((Test-Path (Join-Path $dir "mods")) -or (Test-Path (Join-Path $dir "saves"))) {
                        $gameDir = $dir
                        break
                    }
                    $dir = Split-Path $dir -Parent -ErrorAction SilentlyContinue
                }
            }
        }

        if ($gameDir -and (Test-Path $gameDir)) {
            $instances += [PSCustomObject]@{
                ProcessId = $jp.Id
                GameDir   = $gameDir
                ModsPath  = Join-Path $gameDir "mods"
            }
        }
    }

    return $instances
}

function Resolve-ModsPath {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        Write-Host "  -> Mods path      : $ExplicitPath (explicitly specified)" -ForegroundColor Gray
        return $ExplicitPath
    }

    Write-Host "  -> Detecting running Minecraft instance..." -ForegroundColor Gray
    $instances = Get-RunningMinecraftInstances

    if ($instances.Count -eq 0) {
        Write-Host "    No running Minecraft instance detected - using default path." -ForegroundColor DarkGray
        Write-Host "    Mods path      : $($script:Config.DefaultModsPath)" -ForegroundColor Gray
        return $script:Config.DefaultModsPath
    }

    if ($instances.Count -eq 1) {
        $chosen = $instances[0]
        Write-Host ("    [OK] Running instance found (PID {0})" -f $chosen.ProcessId) -ForegroundColor Green
        Write-Host "    Mods path      : $($chosen.ModsPath)" -ForegroundColor Gray
        return $chosen.ModsPath
    }

    # Multiple instances detected - prompt the user to pick which one to scan.
    Write-Host ""
    Write-Host "    [!] Multiple running Minecraft instances detected:" -ForegroundColor Yellow
    Write-Host ""
    for ($idx = 0; $idx -lt $instances.Count; $idx++) {
        $inst = $instances[$idx]
        Write-Host ("      [{0}] PID {1,-7} : {2}" -f ($idx + 1), $inst.ProcessId, $inst.GameDir) -ForegroundColor Gray
    }
    Write-Host ""

    $selection = $null
    while (-not $selection) {
        $raw = Read-Host "    Enter the number of the instance you want to scan (1-$($instances.Count))"
        $num = 0
        if ([int]::TryParse($raw, [ref]$num) -and $num -ge 1 -and $num -le $instances.Count) {
            $selection = $instances[$num - 1]
        } else {
            Write-Host "    Invalid selection. Please enter a number between 1 and $($instances.Count)." -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host ("    [OK] Selected instance (PID {0})" -f $selection.ProcessId) -ForegroundColor Green
    Write-Host "    Mods path      : $($selection.ModsPath)" -ForegroundColor Gray
    return $selection.ModsPath
}

function Write-Banner {
    Clear-Host
    $width = 74
    $line = "=" * $width
    Write-Host ""
    Write-Host " +$line+" -ForegroundColor DarkRed
    Write-Host (" |" + (" " * $width) + "|") -ForegroundColor DarkRed
    Write-Host (" |" + "   __     __ _    __  __ ____".PadRight($width) + "|") -ForegroundColor Red
    Write-Host (" |" + "   \ \   / // \  |  \/  |  _ \".PadRight($width) + "|") -ForegroundColor Red
    Write-Host (" |" + "    \ \ / // _ \ | |\/| | |_) |".PadRight($width) + "|") -ForegroundColor Red
    Write-Host (" |" + "     \ V // ___ \| |  | |  __/".PadRight($width) + "|") -ForegroundColor Red
    Write-Host (" |" + "      \_//_/   \_\_|  |_|_|".PadRight($width) + "|") -ForegroundColor Red
    Write-Host (" |" + "   C H E A T   S C A N N E R".PadRight($width) + "|") -ForegroundColor White
    Write-Host (" |" + (" " * $width) + "|") -ForegroundColor DarkRed
    Write-Host " +$line+" -ForegroundColor DarkRed
    Write-Host ""
    Write-Host "   * Version        " -NoNewline -ForegroundColor DarkGray
    Write-Host ": $($script:Config.Version)" -ForegroundColor White
    Write-Host "   * Scan started   " -NoNewline -ForegroundColor DarkGray
    Write-Host ": $(Get-Date)" -ForegroundColor White
    Write-Host "   * Host / User    " -NoNewline -ForegroundColor DarkGray
    Write-Host ": $env:COMPUTERNAME / $env:USERNAME" -ForegroundColor White
    Write-Host "   * Network usage  " -NoNewline -ForegroundColor DarkGray
    Write-Host ": read-only Modrinth hash lookup ONLY" -ForegroundColor Cyan
    Write-Host "   * Execution mode " -NoNewline -ForegroundColor DarkGray
    Write-Host ": 100% local, no remote code ever run" -ForegroundColor Cyan
    Write-Host ""
}

function Write-PhaseHeader {
    param([string]$Text, [ConsoleColor]$Color = 'Cyan')
    $inner = 68
    $label = " >> $Text"
    $padded = $label.PadRight($inner)
    Write-Host ""
    Write-Host (" +" + ("-" * ($inner + 2)) + "+") -ForegroundColor $Color
    Write-Host (" | $padded |") -ForegroundColor $Color
    Write-Host (" +" + ("-" * ($inner + 2)) + "+") -ForegroundColor $Color
}

function Write-ProgressBar {
    param([string]$Message, [int]$Progress, [int]$Total)
    if ($Total -le 0) { return }
    $pct = [math]::Round(($Progress / $Total) * 100)
    $barLen = 30
    $filled = [math]::Round(($Progress / $Total) * $barLen)
    $bar = ("#" * $filled) + ("." * ($barLen - $filled))
    $barColor = if ($pct -ge 100) { "Green" } else { "Yellow" }
    Write-Host ("`r   [" ) -NoNewline -ForegroundColor DarkGray
    Write-Host ("$bar") -NoNewline -ForegroundColor $barColor
    Write-Host ("] {0,3}% -> {1} ({2}/{3})   " -f $pct, $Message, $Progress, $Total) -NoNewline -ForegroundColor Gray
}

function Add-Finding {
    param($Severity, $Module, $Detail)
    $script:Findings.Add([PSCustomObject]@{ Severity = $Severity; Module = $Module; Detail = $Detail })
    switch ($Severity) {
        "HIGH"   { $color = "Red";    $icon = "[X]" }
        "MEDIUM" { $color = "Yellow"; $icon = "[!]" }
        default  { $color = "Gray";   $icon = "[i]" }
    }
    Write-Host ("     $icon [{0,-6}] {1}" -f $Severity, $Detail) -ForegroundColor $color
}

# ============================================================================
#  PHASE 1: JAR PARSER + MODRINTH VERIFICATION
# ============================================================================

function Get-FileSHA1 {
    param([string]$FilePath)
    try { return (Get-FileHash -Path $FilePath -Algorithm SHA1 -ErrorAction Stop).Hash }
    catch { return $null }
}

function Get-ModrinthProject {
    <#
        Read-only GET request to the public Modrinth API. Returns JSON metadata
        only (project name / slug) if the file's hash matches a known published
        mod. No code is downloaded or executed - this purely tells us whether
        a jar is a recognized, published mod or an unknown file.
    #>
    param([string]$Hash)
    if (-not $Hash) { return $null }
    try {
        $versionUrl = "https://api.modrinth.com/v2/version_file/$Hash"
        $versionData = Invoke-RestMethod -Uri $versionUrl -Method Get -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        if ($versionData.project_id) {
            $projectUrl = "https://api.modrinth.com/v2/project/$($versionData.project_id)"
            $projectData = Invoke-RestMethod -Uri $projectUrl -Method Get -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
            return @{ Name = $projectData.title; Slug = $projectData.slug }
        }
    } catch { }
    return $null
}

function Invoke-JarParserPhase {
    param([string]$Path)
    Write-PhaseHeader -Text "PHASE 1 / 5  -  JAR PARSER & MOD VERIFICATION"

    if (-not (Test-Path $Path)) {
        Write-Host "   Mods folder not found: $Path" -ForegroundColor DarkGray
        return @{ Verified = @(); Unknown = @() }
    }

    $jars = Get-ChildItem -Path $Path -Filter *.jar -File -ErrorAction SilentlyContinue
    if ($jars.Count -eq 0) {
        Write-Host "   No .jar files found in: $Path" -ForegroundColor DarkGray
        return @{ Verified = @(); Unknown = @() }
    }

    Write-Host "   Target folder : $Path" -ForegroundColor Gray
    Write-Host "   Found $($jars.Count) jar file(s). Hashing and checking against Modrinth...`n" -ForegroundColor Gray

    $verified = @()
    $unknown  = @()
    $i = 0
    foreach ($jar in $jars) {
        $i++
        Write-ProgressBar -Message "Verifying" -Progress $i -Total $jars.Count
        $hash = Get-FileSHA1 -FilePath $jar.FullName
        $proj = Get-ModrinthProject -Hash $hash
        if ($proj) {
            $verified += [PSCustomObject]@{
                ModName  = $proj.Name
                FileName = $jar.Name
                SizeMB   = [math]::Round($jar.Length / 1MB, 2)
            }
        } else {
            $unknown += [PSCustomObject]@{
                FileName = $jar.Name
                FilePath = $jar.FullName
                SizeMB   = [math]::Round($jar.Length / 1MB, 2)
                Hash     = $hash
            }
        }
    }
    Write-Host ("`r" + (" " * 90) + "`r") -NoNewline

    Write-Host ""
    Write-Host "   [OK] Verified against Modrinth : " -NoNewline -ForegroundColor Green
    Write-Host "$($verified.Count)" -ForegroundColor White
    Write-Host "   [!] Unverified / unknown      : " -NoNewline -ForegroundColor Yellow
    Write-Host "$($unknown.Count)" -ForegroundColor White

    if ($verified.Count -gt 0) {
        Write-Host ""
        $verified | Sort-Object ModName | ForEach-Object {
            Write-Host ("     [OK] {0,-35} " -f $_.ModName) -NoNewline -ForegroundColor DarkGreen
            Write-Host ("{0,8} MB" -f $_.SizeMB) -ForegroundColor DarkGray
        }
    }

    return @{ Verified = $verified; Unknown = $unknown }
}

# ============================================================================
#  PHASE 2: DEEP THREAT SCAN (unverified jars + embedded jars)
# ============================================================================

function Test-CheatSignaturesInFile {
    param([string]$FilePath)
    $found = [System.Collections.Generic.HashSet[string]]::new()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        $content = [System.Text.Encoding]::ASCII.GetString($bytes)
        foreach ($sig in $script:CheatSignatures) {
            if ($content -match [regex]::Escape($sig)) { $found.Add($sig) | Out-Null }
        }
    } catch { }
    return $found
}

function Test-EmbeddedJars {
    param([string]$JarPath, [string]$TempDir)
    $threats = @()
    try {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($JarPath)
        $extractPath = Join-Path $TempDir $name
        if (Test-Path $extractPath) { Remove-Item -Recurse -Force $extractPath -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($JarPath, $extractPath)

        $embeddedPath = Join-Path $extractPath "META-INF/jars"
        if (Test-Path $embeddedPath) {
            Get-ChildItem -Path $embeddedPath -Filter *.jar -ErrorAction SilentlyContinue | ForEach-Object {
                $sigs = Test-CheatSignaturesInFile -FilePath $_.FullName
                if ($sigs.Count -gt 0) { $threats += @{ EmbeddedJar = $_.Name; Signatures = $sigs } }
            }
        }
        Remove-Item -Recurse -Force $extractPath -ErrorAction SilentlyContinue
    } catch { }
    return $threats
}

function Invoke-DeepThreatScanPhase {
    param($UnknownMods)
    Write-PhaseHeader -Text "PHASE 2 / 5  -  DEEP THREAT SCAN"

    if (-not $UnknownMods -or $UnknownMods.Count -eq 0) {
        Write-Host "   No unverified jars to deep-scan." -ForegroundColor DarkGray
        return @()
    }

    $tempDir = Join-Path $env:TEMP $script:Config.TempDirName
    if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $threats = @()
    $i = 0
    foreach ($mod in $UnknownMods) {
        $i++
        Write-ProgressBar -Message "Scanning" -Progress $i -Total $UnknownMods.Count
        $sigs = Test-CheatSignaturesInFile -FilePath $mod.FilePath
        $embedded = Test-EmbeddedJars -JarPath $mod.FilePath -TempDir $tempDir

        if ($sigs.Count -gt 0 -or $embedded.Count -gt 0) {
            $risk = if ($sigs.Count -ge 4 -or $embedded.Count -gt 0) { "HIGH" } else { "MEDIUM" }
            $threats += [PSCustomObject]@{
                FileName = $mod.FileName
                FilePath = $mod.FilePath
                Signatures = $sigs
                Embedded = $embedded
                Risk = $risk
            }
        }
    }
    Write-Host ("`r" + (" " * 90) + "`r") -NoNewline
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue

    if ($threats.Count -eq 0) {
        Write-Host "   [OK] No cheat signatures found in unverified jars." -ForegroundColor Green
    } else {
        foreach ($t in $threats) {
            Add-Finding $t.Risk "JarThreatScan" ("'{0}' contains signatures: {1}" -f $t.FileName, ($t.Signatures -join ", "))
            foreach ($e in $t.Embedded) {
                Add-Finding "HIGH" "JarThreatScan" ("'{0}' has embedded jar '{1}' with signatures: {2}" -f $t.FileName, $e.EmbeddedJar, ($e.Signatures -join ", "))
            }
        }
    }
    return $threats
}

# ============================================================================
#  PHASE 3: BAM PARSER
# ============================================================================

function Invoke-BamParserPhase {
    Write-PhaseHeader -Text "PHASE 3 / 5  -  BAM PARSER (EXECUTION HISTORY)"

    $bamPath = "HKLM:\SYSTEM\CurrentControlSet\Services\bam\State\UserSettings"
    if (-not (Test-Path $bamPath)) {
        Write-Host "   BAM registry key not present on this system." -ForegroundColor DarkGray
        return
    }
    $userKeys = Get-ChildItem -Path $bamPath -ErrorAction SilentlyContinue
    if (-not $userKeys) {
        Write-Host "   Unable to read BAM entries (try running as Administrator)." -ForegroundColor DarkGray
        return
    }

    $count = 0
    foreach ($userKey in $userKeys) {
        $props = Get-ItemProperty -Path $userKey.PSPath -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        $props.PSObject.Properties | Where-Object { $_.Name -match '^\\Device\\HarddiskVolume' } | ForEach-Object {
            $count++
            $exePath = $_.Name
            $matched = $script:CheatSignatures | Where-Object { $exePath.ToLower() -like "*$($_.ToLower())*" }
            if ($matched) {
                Add-Finding "HIGH" "BamParser" ("Recently executed program matches signature '{0}': {1}" -f $matched[0], $exePath)
            }
        }
    }
    Write-Host "   Parsed $count recent-execution record(s) from BAM." -ForegroundColor Gray
    if ($count -gt 0 -and ($script:Findings | Where-Object { $_.Module -eq "BamParser" }).Count -eq 0) {
        Write-Host "   [OK] No known cheat-client execution history found." -ForegroundColor Green
    }
}

# ============================================================================
#  PHASE 4: SERVICES / PROCESS CHECK
# ============================================================================

function Invoke-ServiceProcessPhase {
    Write-PhaseHeader -Text "PHASE 4 / 5  -  SERVICES & PROCESS CHECK"

    $procs = Get-Process -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        $matched = ($script:CheatSignatures + $script:KnownInjectorProcessNames) | Where-Object { $p.ProcessName.ToLower() -like "*$($_.ToLower())*" }
        if ($matched) {
            Add-Finding "HIGH" "ProcessCheck" ("Running process '{0}' (PID {1}) matches '{2}'" -f $p.ProcessName, $p.Id, $matched[0])
        }
    }
    Write-Host "   Checked $($procs.Count) running process(es)." -ForegroundColor Gray

    $services = Get-Service -ErrorAction SilentlyContinue
    foreach ($svc in $services) {
        $matched = $script:CheatSignatures | Where-Object { ($svc.DisplayName).ToLower() -like "*$($_.ToLower())*" }
        if ($matched) {
            Add-Finding "MEDIUM" "ServiceCheck" ("Service '{0}' matches '{1}'" -f $svc.DisplayName, $matched[0])
        }
    }
    Write-Host "   Checked $($services.Count) installed service(s)." -ForegroundColor Gray

    if (($script:Findings | Where-Object { $_.Module -in @("ProcessCheck","ServiceCheck") }).Count -eq 0) {
        Write-Host "   [OK] No known cheat-related processes or services detected." -ForegroundColor Green
    }
}

# ============================================================================
#  PHASE 5: FILELESS BYPASS DETECTION
# ============================================================================

function Invoke-FilelessBypassPhase {
    Write-PhaseHeader -Text "PHASE 5 / 5  -  FILELESS BYPASS DETECTION"

    $javaProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^java(w)?$' }
    if (-not $javaProcs) {
        Write-Host "   No running Java/Minecraft process found." -ForegroundColor DarkGray
        return
    }

    foreach ($jp in $javaProcs) {
        Write-Host "   -> Inspecting java process PID $($jp.Id)..." -ForegroundColor Gray
        try { $modules = $jp.Modules } catch {
            Write-Host "     Unable to enumerate modules (try running as Administrator)." -ForegroundColor DarkGray
            continue
        }
        foreach ($m in $modules) {
            $path = $m.FileName
            if (-not $path) { continue }
            if ($path -match '\\Temp\\|\\AppData\\Local\\Temp\\|\\Downloads\\') {
                if (Test-IsKnownLegitTempModule -Path $path) {
                    # Known legitimate JNI native library extraction (e.g. Simple
                    # Voice Chat's opus/rnnoise/speex/lame codecs, LWJGL natives).
                    # Skip flagging, but keep it visible so it's not silently hidden.
                    Write-Host ("     [OK] Ignoring known-legit native lib (PID {0}): {1}" -f $jp.Id, (Split-Path $path -Leaf)) -ForegroundColor DarkGray
                } else {
                    Add-Finding "MEDIUM" "FilelessCheck" ("Java process (PID {0}) loaded a module from a temp/download path: {1}" -f $jp.Id, $path)
                }
            }
            $matched = $script:CheatSignatures | Where-Object { $path.ToLower() -like "*$($_.ToLower())*" }
            if ($matched) {
                Add-Finding "HIGH" "FilelessCheck" ("Java process (PID {0}) has module matching '{1}': {2}" -f $jp.Id, $matched[0], $path)
            }
        }
        try {
            $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$($jp.Id)" -ErrorAction SilentlyContinue
            if ($cim) {
                $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($cim.ParentProcessId)" -ErrorAction SilentlyContinue
                if ($parent -and $parent.Name -match 'powershell|cmd|mshta|wscript|cscript') {
                    Add-Finding "MEDIUM" "FilelessCheck" ("Java process (PID {0}) was launched by unusual parent: {1}" -f $jp.Id, $parent.Name)
                }
            }
        } catch { }
    }
    if (($script:Findings | Where-Object { $_.Module -eq "FilelessCheck" }).Count -eq 0) {
        Write-Host "   [OK] No fileless-load or reflective-injection indicators found." -ForegroundColor Green
    }
}

# ============================================================================
#  SUMMARY + EXPORT
# ============================================================================

function Write-StatLine {
    param([string]$Label, [string]$Value, [ConsoleColor]$Color)
    Write-Host ("   {0,-28}" -f $Label) -NoNewline -ForegroundColor Gray
    Write-Host " $Value" -ForegroundColor $Color
}

function Write-SummaryReport {
    param($Verified, $Unknown, $Threats)
    Write-PhaseHeader -Text "SCAN SUMMARY" -Color White

    Write-StatLine "[OK] Verified mods (Modrinth)"  $Verified.Count Green
    Write-StatLine "[!] Unverified mods"           $Unknown.Count Yellow
    Write-StatLine "[X] Jar-level threats"         $Threats.Count Red
    Write-StatLine "[i] System-level findings"     $script:Findings.Count Red
    Write-Host ""

    if ($script:Findings.Count -eq 0 -and $Threats.Count -eq 0) {
        Write-Host "   [OK] RESULT: CLEAN - no cheat-client indicators found." -ForegroundColor Green
    } else {
        $high = ($script:Findings | Where-Object { $_.Severity -eq "HIGH" }).Count + ($Threats | Where-Object { $_.Risk -eq "HIGH" }).Count
        $med  = ($script:Findings | Where-Object { $_.Severity -eq "MEDIUM" }).Count + ($Threats | Where-Object { $_.Risk -eq "MEDIUM" }).Count
        Write-Host "   [!] RESULT: $high HIGH severity, $med MEDIUM severity finding(s)." -ForegroundColor Red
        Write-Host ""
        if ($script:Findings.Count -gt 0) {
            $script:Findings | Sort-Object Severity | Format-Table -AutoSize Severity, Module, Detail | Out-Host
        }
    }

    Write-Host ""
    Write-Host "   Scan completed : $(Get-Date)" -ForegroundColor Gray
    Write-Host "   This scanner performs local pattern-matching + Modrinth" -ForegroundColor DarkGray
    Write-Host "   verification only. It is not an authoritative anti-cheat." -ForegroundColor DarkGray
    Write-Host ""
}

function Write-VerdictBanner {
    param([bool]$Clean)
    $width = 74
    $line = "=" * $width
    $color = if ($Clean) { "Green" } else { "Red" }
    $label = if ($Clean) { "V E R D I C T :   C L E A N" } else { "V E R D I C T :   C H E A T I N G   D E T E C T E D" }

    Write-Host ""
    Write-Host " +$line+" -ForegroundColor $color
    Write-Host (" |" + (" " * $width) + "|") -ForegroundColor $color

    $innerWidth = $width - 4
    $starLine = "*" * $innerWidth
    Write-Host (" |  " + $starLine + "  |") -ForegroundColor $color
    Write-Host (" |  *" + (" " * ($innerWidth - 2)) + "*  |") -ForegroundColor $color

    $labelPadded = $label
    $padTotal = $innerWidth - 2 - $labelPadded.Length
    $padLeft = [math]::Floor($padTotal / 2)
    $padRight = $padTotal - $padLeft
    if ($padLeft -lt 0) { $padLeft = 0 }
    if ($padRight -lt 0) { $padRight = 0 }
    $centeredLabel = (" " * $padLeft) + $labelPadded + (" " * $padRight)
    Write-Host (" |  *" + $centeredLabel + "*  |") -ForegroundColor $color

    Write-Host (" |  *" + (" " * ($innerWidth - 2)) + "*  |") -ForegroundColor $color
    Write-Host (" |  " + $starLine + "  |") -ForegroundColor $color
    Write-Host (" |" + (" " * $width) + "|") -ForegroundColor $color
    Write-Host " +$line+" -ForegroundColor $color
}

function Write-OverallSummary {
    param($Threats)
    Write-PhaseHeader -Text "OVERALL SUMMARY" -Color White

    $jarFlagged   = $Threats.Count -gt 0
    $sysFlagged   = $script:Findings.Count -gt 0
    $anyFlagged   = $jarFlagged -or $sysFlagged

    Write-VerdictBanner -Clean (-not $anyFlagged)

    if (-not $anyFlagged) {
        Write-Host ""
        Write-Host "   [OK] No cheat clients, injectors, or suspicious activity were detected." -ForegroundColor Green
        Write-Host ""
        return
    }

    Write-Host ""

    if ($jarFlagged) {
        Write-Host "   [X] Flagged mod(s):" -ForegroundColor Red
        foreach ($t in $Threats) {
            Write-Host ""
            Write-Host ("     * {0}" -f $t.FileName) -ForegroundColor Red
            Write-Host ("       Risk level : {0}" -f $t.Risk) -ForegroundColor Yellow
            Write-Host ("       Location   : {0}" -f $t.FilePath) -ForegroundColor Gray
            if ($t.Signatures.Count -gt 0) {
                Write-Host ("       Signatures : {0}" -f ($t.Signatures -join ", ")) -ForegroundColor Magenta
            }
            foreach ($e in $t.Embedded) {
                Write-Host ("       Embedded jar '{0}' also flagged for: {1}" -f $e.EmbeddedJar, ($e.Signatures -join ", ")) -ForegroundColor Magenta
            }
        }
        Write-Host ""
    }

    if ($sysFlagged) {
        Write-Host "   [!] System-level indicators (not tied to a specific mod file):" -ForegroundColor Red
        foreach ($f in ($script:Findings | Sort-Object Severity)) {
            $icon = if ($f.Severity -eq "HIGH") { "[X]" } else { "[!]" }
            Write-Host ("     $icon [{0}] {1} - {2}" -f $f.Severity, $f.Module, $f.Detail) -ForegroundColor Yellow
        }
        Write-Host ""
    }

    Write-Host "   [i] Recommendation: remove the flagged mod(s) listed above and" -ForegroundColor DarkGray
    Write-Host "     review any system-level indicators before rejoining a server." -ForegroundColor DarkGray
    Write-Host ""
}

function Export-JsonReport {
    param($Verified, $Unknown, $Threats)
    $path = Join-Path $env:USERPROFILE "Desktop\VampCheatScanner-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    $report = @{
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Version   = $script:Config.Version
        Verified  = $Verified
        Unknown   = $Unknown
        JarThreats = $Threats
        SystemFindings = $script:Findings
    }
    try {
        $report | ConvertTo-Json -Depth 10 | Out-File -FilePath $path -Encoding UTF8
        Write-Host "   [OK] Report exported to: $path" -ForegroundColor Green
    } catch {
        Write-Host "   [X] Failed to export report: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================================
#  MAIN
# ============================================================================

function Main {
    Write-Banner

    $path = Resolve-ModsPath -ExplicitPath $ModsPath
    Write-Host ""

    $p1 = Invoke-JarParserPhase -Path $path
    $threats = Invoke-DeepThreatScanPhase -UnknownMods $p1.Unknown
    Invoke-BamParserPhase
    Invoke-ServiceProcessPhase
    Invoke-FilelessBypassPhase

    Write-SummaryReport -Verified $p1.Verified -Unknown $p1.Unknown -Threats $threats
    Write-OverallSummary -Threats $threats

    if ($ExportReport) {
        Export-JsonReport -Verified $p1.Verified -Unknown $p1.Unknown -Threats $threats
    }

    Write-Host "   Scan Completed. Please review the verdict above and take appropriate action." -ForegroundColor Cyan
    Write-Host "   Thank you for using Vamp Cheat Scanner. Stay safe and don't cheat!" -ForegroundColor Cyan
}

Main
