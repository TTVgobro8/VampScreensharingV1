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
      Phase 1 - Jar Parser         : hashes mods, verifies against Modrinth, flags unknowns
      Phase 2 - Deep Threat Scan   : scans unverified jars (incl. embedded jars) for
                                     known cheat-client signatures
      Phase 3 - Cheat Folder Scan  : checks %AppData%/%LocalAppData% for known
                                     cheat-client/injector install folders (Wurst,
                                     Impact, Meteor, Sigma, Ghost Client, Prestige, etc.)
      Phase 4 - BAM Parser         : reads Background Activity Moderator execution history
      Phase 5 - Services/Process   : flags known cheat-loader/injector process & service names
      Phase 6 - Fileless Bypass    : reflective/in-memory load indicators on java.exe
      Phase 7 - Macro/Automation   : flags autoclicker/macro tooling running anywhere on
                                     the system (not just inside Minecraft)

.PARAMETER ModsPath
    Path to a mods folder. Defaults to %APPDATA%\.minecraft\mods if not supplied.

.PARAMETER ExportReport
    If set, writes a full JSON report to the Desktop after the scan completes.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\VampCheatScanner.ps1
    powershell -ExecutionPolicy Bypass -File .\VampCheatScanner.ps1 -ExportReport

.NOTES
    Name    : Vamp Cheat Scanner
    Version : 3.0.0
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
    Version        = "3.0.0"
    DefaultModsPath = "$env:APPDATA\.minecraft\mods"
    TempDirName    = "vamp_cheatscanner_tmp"
    TotalPhases    = 7
}

$ErrorActionPreference = "SilentlyContinue"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$script:Findings = New-Object System.Collections.Generic.List[Object]
$script:StartTime = Get-Date

# ----------------------------------------------------------------------------
#  SIGNATURE DATA
# ----------------------------------------------------------------------------
#
# Signatures are split into two confidence tiers so we don't nuke someone's
# entire mod folder because a legit mod's bytecode happens to contain a word
# like "Speed" or "Fly" somewhere in a string table.
#
#   CheatClientNames  - distinctive, low-collision names of actual cheat
#                        clients / injectors. A single hit on one of these is
#                        treated as high confidence on its own.
#   CheatFeatureWords  - generic "cheat module" style names (KillAura,
#                        AutoClicker, ESP, etc.) that DO show up as class/
#                        feature names inside real cheat clients, but could
#                        theoretically collide with unrelated text. These are
#                        matched with word boundaries and require multiple
#                        distinct hits before being treated as high severity.

$script:CheatClientNames = @(
    "wurst", "impact", "meteor-client", "meteorclient", "future-client",
    "sigma5", "sigma", "aristois", "rusherhack", "salhack", "kamiblue",
    "novoline", "flux-client", "fluxclient", "b0at", "vape", "liquidbounce",
    "wolfram", "clickcrystals", "doomsday",
    # Injector-style / loader clients commonly reported on Minecraft servers
    "prestige", "ghostclient", "ghost-client", "riseclient", "rise-client",
    "onsetclient", "onset-client", "asyncclient", "async-client",
    "exhibitionclient", "exhibition-client", "expressionclient",
    "zephyrclient", "sanguine-client", "kaminari-client", "matrixclient",
    "viperclient", "aionclient", "aresclient", "hyperionclient"
)

$script:CheatFeatureWords = @(
    "KillAura", "AimAssist", "TriggerBot", "AutoClicker", "Reach",
    "AntiKnockback", "NoFall", "Bhop", "Scaffold", "FastPlace",
    "AutoCrystal", "AutoAnchor", "AnchorTweaks", "AutoTotem",
    "InventoryTotem", "LegitTotem", "AutoPot", "AutoArmor",
    "AutoDoubleHand", "JumpReset", "PingSpoof", "SelfDestruct",
    "ShieldBreaker", "WebMacro", "AxeSpam", "ChestStealer", "Xray",
    "Nuker", "Freecam", "Fly", "Speed", "Velocity", "ESP", "Hitboxes"
)
# Words too generic to ever count alone (need 2+ distinct hits to matter)
$script:AmbiguousFeatureWords = @("Fly", "Speed", "Velocity", "ESP", "Reach", "Freecam", "Hitboxes")

$script:KnownInjectorProcessNames = @(
    "injector", "loader64", "loader32", "dllinject", "xenos", "extreme-injector",
    "extremeinjector", "memhack", "prestigeloader", "ghostloader"
)

# Known cheat-client / injector install folders. Real client mods do not
# typically create their own top-level %AppData% or %LocalAppData% folder,
# so a folder match here is a strong, independent signal.
$script:KnownCheatFolders = @(
    ".wurst", ".impact", ".meteor-client", ".meteorclient", ".future-client",
    ".sigma", ".aristois", ".rusherhack", ".salhack", ".kamiblue",
    ".novoline", ".flux", ".liquidbounce", ".wolfram", ".doomsday",
    ".prestige", ".ghost", ".ghostclient", ".rise", ".onset", ".async",
    ".exhibition", ".expression"
)

# Dedicated macro / autoclicker software - not a game mod at all, but a
# system-wide tool. Flagged with lower severity than an actual cheat client,
# since owning the tool isn't proof it was used in-game, but it's relevant
# context if someone is asking "is this person cheating".
$script:MacroToolProcessNames = @(
    "autohotkeyu64", "autohotkeyu32", "autohotkey", "ahktray",
    "tinytask", "macrorecorder", "macro recorder", "pulovermacrocreator",
    "quickmacros", "ghostmouse", "jitbitmacrorecorder", "macro toolworks",
    "autoclicker", "gsautoclicker", "opautoclicker", "fastclicker"
)

# Peripheral-manufacturer software that CAN do macros/rebinds but is
# overwhelmingly used for entirely legitimate reasons (RGB, DPI, etc).
# We surface these as informational only - never HIGH/MEDIUM on their own.
$script:PeripheralMacroSoftware = @(
    "lghub", "lgshub", "logitech gaming software", "razer synapse",
    "steelseries engine", "corsair icue", "roccat swarm", "wootility"
)

# Common, high-popularity mod name fragments used to avoid flagging a jar
# just because Modrinth's lookup missed it (rate limit, private build,
# CurseForge-only distribution, etc). This does NOT skip signature scanning -
# it only prevents an "unverified" mod from being treated as inherently
# suspicious in the summary if it also comes back clean.
$script:KnownLegitModNamePatterns = @(
    'sodium', 'lithium', 'phosphor', 'starlight', 'lazydfu', 'ferritecore',
    'modmenu', 'fabric-api', 'forge-?\d', 'optifine', '^jei[-_]', '^rei[-_]',
    '^emi[-_]', 'waila', 'jade', 'xaero', 'voxelmap', 'journeymap',
    'simple-?voice-?chat', 'voicechat', 'create-?mod', '^create-', 'jamlib',
    'cloth-config', 'architectury', 'iris', 'indium', 'continuity',
    'sound-?physics', 'dynamic-?fps', 'entityculling', 'immediatelyfast'
)

function Test-IsKnownLegitModName {
    param([string]$FileName)
    foreach ($pattern in $script:KnownLegitModNamePatterns) {
        if ($FileName -match $pattern) { return $true }
    }
    return $false
}

# Known-legitimate native (JNI) libraries that mods extract to a temp folder
# at runtime. These are native codec/audio libs bundled by common, verified
# mods - e.g. Simple Voice Chat's opus/rnnoise/speex/lame codecs, which get
# extracted at launch as "libNAMEj-<hash>\libNAMEj.dll". This is standard JNI
# behavior for any Java mod shipping native code, not a cheat-bypass
# technique, so Phase 6 whitelists these by filename pattern (the temp
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
#  SIGNATURE MATCHING HELPERS
# ============================================================================

function Get-ClientNameMatches {
    <# Distinctive cheat-client names - substring match is fine, low collision risk. #>
    param([string]$Text)
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $script:CheatClientNames) {
        if ($Text -match [regex]::Escape($name)) { $found.Add($name) }
    }
    return $found
}

function Get-FeatureWordMatches {
    <#
        Generic cheat-module names - matched with word boundaries (using
        lookaround instead of \b so it still works on CamelCase-glued
        identifiers like "KillAuraModule") to cut down on accidental
        substring hits inside unrelated text.
    #>
    param([string]$Text)
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($word in $script:CheatFeatureWords) {
        $pattern = "(?<![A-Za-z])" + [regex]::Escape($word) + "(?![a-z])"
        if ([regex]::IsMatch($Text, $pattern)) { $found.Add($word) }
    }
    return $found
}

function Get-SignatureRisk {
    <#
        Turns a set of client-name hits + feature-word hits into a severity.
        - Any distinctive client-name hit -> HIGH, full stop.
        - Feature words: ambiguous single-word ones are discounted; you need
          either 1 non-ambiguous word, or 3+ ambiguous words, for MEDIUM, and
          4+ total (or 2+ non-ambiguous) for HIGH.
    #>
    param([string[]]$ClientHits, [string[]]$FeatureHits)

    if ($ClientHits -and $ClientHits.Count -gt 0) { return "HIGH" }
    if (-not $FeatureHits -or $FeatureHits.Count -eq 0) { return $null }

    $nonAmbiguous = @($FeatureHits | Where-Object { $script:AmbiguousFeatureWords -notcontains $_ })
    $ambiguousOnly = @($FeatureHits | Where-Object { $script:AmbiguousFeatureWords -contains $_ })

    if ($nonAmbiguous.Count -ge 2) { return "HIGH" }
    if ($nonAmbiguous.Count -ge 1) { return "MEDIUM" }
    if ($ambiguousOnly.Count -ge 3) { return "MEDIUM" }
    return $null
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
    Write-Host "   Severity legend  : " -NoNewline -ForegroundColor DarkGray
    Write-Host "[X] HIGH  " -NoNewline -ForegroundColor Red
    Write-Host "[!] MEDIUM  " -NoNewline -ForegroundColor Yellow
    Write-Host "[i] INFO" -ForegroundColor Gray
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
    Write-PhaseHeader -Text ("PHASE 1 / {0}  -  JAR PARSER & MOD VERIFICATION" -f $script:Config.TotalPhases)

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
                FileName     = $jar.Name
                FilePath     = $jar.FullName
                SizeMB       = [math]::Round($jar.Length / 1MB, 2)
                Hash         = $hash
                LikelyLegit  = (Test-IsKnownLegitModName -FileName $jar.Name)
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

    $likelyLegitUnknown = @($unknown | Where-Object { $_.LikelyLegit })
    if ($likelyLegitUnknown.Count -gt 0) {
        Write-Host ""
        Write-Host "   [i] Not found on Modrinth, but filename matches a well-known mod:" -ForegroundColor Gray
        foreach ($u in $likelyLegitUnknown) {
            Write-Host ("     [i] {0} (still deep-scanned below, just not auto-flagged as unknown)" -f $u.FileName) -ForegroundColor DarkGray
        }
    }

    return @{ Verified = $verified; Unknown = $unknown }
}

# ============================================================================
#  PHASE 2: DEEP THREAT SCAN (unverified jars + embedded jars)
# ============================================================================

function Test-CheatSignaturesInFile {
    param([string]$FilePath)
    $result = @{ ClientHits = @(); FeatureHits = @() }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        $content = [System.Text.Encoding]::ASCII.GetString($bytes)
        $result.ClientHits  = @(Get-ClientNameMatches -Text $content)
        $result.FeatureHits = @(Get-FeatureWordMatches -Text $content)
    } catch { }
    return $result
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
                $sig = Test-CheatSignaturesInFile -FilePath $_.FullName
                $risk = Get-SignatureRisk -ClientHits $sig.ClientHits -FeatureHits $sig.FeatureHits
                if ($risk) { $threats += @{ EmbeddedJar = $_.Name; ClientHits = $sig.ClientHits; FeatureHits = $sig.FeatureHits; Risk = $risk } }
            }
        }
        Remove-Item -Recurse -Force $extractPath -ErrorAction SilentlyContinue
    } catch { }
    return $threats
}

function Invoke-DeepThreatScanPhase {
    param($UnknownMods)
    Write-PhaseHeader -Text ("PHASE 2 / {0}  -  DEEP THREAT SCAN" -f $script:Config.TotalPhases)

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
        $sig = Test-CheatSignaturesInFile -FilePath $mod.FilePath
        $embedded = Test-EmbeddedJars -JarPath $mod.FilePath -TempDir $tempDir
        $risk = Get-SignatureRisk -ClientHits $sig.ClientHits -FeatureHits $sig.FeatureHits

        if ($risk -or $embedded.Count -gt 0) {
            $finalRisk = if ($embedded.Count -gt 0 -and (-not $risk -or $risk -eq "MEDIUM")) { "HIGH" } else { $risk }
            $threats += [PSCustomObject]@{
                FileName    = $mod.FileName
                FilePath    = $mod.FilePath
                ClientHits  = $sig.ClientHits
                FeatureHits = $sig.FeatureHits
                Embedded    = $embedded
                Risk        = $finalRisk
            }
        }
    }
    Write-Host ("`r" + (" " * 90) + "`r") -NoNewline
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue

    if ($threats.Count -eq 0) {
        Write-Host "   [OK] No cheat signatures found in unverified jars." -ForegroundColor Green
    } else {
        foreach ($t in $threats) {
            $parts = @()
            if ($t.ClientHits.Count -gt 0)  { $parts += ("known client name(s): {0}" -f ($t.ClientHits -join ", ")) }
            if ($t.FeatureHits.Count -gt 0) { $parts += ("cheat-module strings: {0}" -f ($t.FeatureHits -join ", ")) }
            Add-Finding $t.Risk "JarThreatScan" ("'{0}' matched {1}" -f $t.FileName, ($parts -join "; "))
            foreach ($e in $t.Embedded) {
                $eparts = @()
                if ($e.ClientHits.Count -gt 0)  { $eparts += ("known client name(s): {0}" -f ($e.ClientHits -join ", ")) }
                if ($e.FeatureHits.Count -gt 0) { $eparts += ("cheat-module strings: {0}" -f ($e.FeatureHits -join ", ")) }
                Add-Finding "HIGH" "JarThreatScan" ("'{0}' has embedded jar '{1}' matching {2}" -f $t.FileName, $e.EmbeddedJar, ($eparts -join "; "))
            }
        }
    }
    return $threats
}

# ============================================================================
#  PHASE 3: KNOWN CHEAT-CLIENT FOLDER SCAN
# ============================================================================

function Invoke-CheatFolderScanPhase {
    Write-PhaseHeader -Text ("PHASE 3 / {0}  -  CHEAT-CLIENT FOLDER SCAN" -f $script:Config.TotalPhases)

    $rootsToCheck = @($env:APPDATA, $env:LOCALAPPDATA) | Where-Object { $_ -and (Test-Path $_) }
    $hits = 0

    foreach ($root in $rootsToCheck) {
        foreach ($folder in $script:KnownCheatFolders) {
            $candidate = Join-Path $root $folder
            if (Test-Path $candidate) {
                $hits++
                Add-Finding "HIGH" "CheatFolderScan" ("Found known cheat-client data folder: {0}" -f $candidate)
            }
        }
    }

    Write-Host ("   Checked {0} known cheat-client folder name(s) under AppData/LocalAppData." -f $script:KnownCheatFolders.Count) -ForegroundColor Gray
    if ($hits -eq 0) {
        Write-Host "   [OK] No known cheat-client install folders found." -ForegroundColor Green
    }
}

# ============================================================================
#  PHASE 4: BAM PARSER
# ============================================================================

function Invoke-BamParserPhase {
    Write-PhaseHeader -Text ("PHASE 4 / {0}  -  BAM PARSER (EXECUTION HISTORY)" -f $script:Config.TotalPhases)

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

    $allNames = $script:CheatClientNames + $script:MacroToolProcessNames
    $count = 0
    foreach ($userKey in $userKeys) {
        $props = Get-ItemProperty -Path $userKey.PSPath -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        $props.PSObject.Properties | Where-Object { $_.Name -match '^\\Device\\HarddiskVolume' } | ForEach-Object {
            $count++
            $exePath = $_.Name
            $matchedClient = $script:CheatClientNames | Where-Object { $exePath.ToLower() -like "*$($_.ToLower())*" }
            if ($matchedClient) {
                Add-Finding "HIGH" "BamParser" ("Recently executed program matches known cheat-client name '{0}': {1}" -f $matchedClient[0], $exePath)
                return
            }
            $matchedMacro = $script:MacroToolProcessNames | Where-Object { $exePath.ToLower() -like "*$($_.ToLower())*" }
            if ($matchedMacro) {
                Add-Finding "MEDIUM" "BamParser" ("Recently executed program matches macro/automation tool '{0}': {1}" -f $matchedMacro[0], $exePath)
            }
        }
    }
    Write-Host "   Parsed $count recent-execution record(s) from BAM." -ForegroundColor Gray
    if ($count -gt 0 -and ($script:Findings | Where-Object { $_.Module -eq "BamParser" }).Count -eq 0) {
        Write-Host "   [OK] No known cheat-client or macro-tool execution history found." -ForegroundColor Green
    }
}

# ============================================================================
#  PHASE 5: SERVICES / PROCESS CHECK
# ============================================================================

function Invoke-ServiceProcessPhase {
    Write-PhaseHeader -Text ("PHASE 5 / {0}  -  SERVICES & PROCESS CHECK" -f $script:Config.TotalPhases)

    $procs = Get-Process -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        $matchedClient   = $script:CheatClientNames | Where-Object { $p.ProcessName.ToLower() -like "*$($_.ToLower())*" }
        $matchedInjector = $script:KnownInjectorProcessNames | Where-Object { $p.ProcessName.ToLower() -like "*$($_.ToLower())*" }
        if ($matchedClient) {
            Add-Finding "HIGH" "ProcessCheck" ("Running process '{0}' (PID {1}) matches known cheat client '{2}'" -f $p.ProcessName, $p.Id, $matchedClient[0])
        } elseif ($matchedInjector) {
            Add-Finding "HIGH" "ProcessCheck" ("Running process '{0}' (PID {1}) matches known injector/loader pattern '{2}'" -f $p.ProcessName, $p.Id, $matchedInjector[0])
        }
    }
    Write-Host "   Checked $($procs.Count) running process(es)." -ForegroundColor Gray

    $services = Get-Service -ErrorAction SilentlyContinue
    foreach ($svc in $services) {
        $matched = $script:CheatClientNames | Where-Object { ($svc.DisplayName).ToLower() -like "*$($_.ToLower())*" }
        if ($matched) {
            Add-Finding "MEDIUM" "ServiceCheck" ("Service '{0}' matches known cheat client '{1}'" -f $svc.DisplayName, $matched[0])
        }
    }
    Write-Host "   Checked $($services.Count) installed service(s)." -ForegroundColor Gray

    if (($script:Findings | Where-Object { $_.Module -in @("ProcessCheck","ServiceCheck") }).Count -eq 0) {
        Write-Host "   [OK] No known cheat-related processes or services detected." -ForegroundColor Green
    }
}

# ============================================================================
#  PHASE 6: FILELESS BYPASS DETECTION
# ============================================================================

function Invoke-FilelessBypassPhase {
    Write-PhaseHeader -Text ("PHASE 6 / {0}  -  FILELESS BYPASS DETECTION" -f $script:Config.TotalPhases)

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
            $matchedClient = $script:CheatClientNames | Where-Object { $path.ToLower() -like "*$($_.ToLower())*" }
            if ($matchedClient) {
                Add-Finding "HIGH" "FilelessCheck" ("Java process (PID {0}) has module matching known cheat client '{1}': {2}" -f $jp.Id, $matchedClient[0], $path)
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
#  PHASE 7: MACRO / AUTOMATION TOOL SCAN
# ============================================================================

function Invoke-MacroToolScanPhase {
    <#
        System-wide scan (not limited to Minecraft) for autoclicker/macro
        software that could be used to automate clicking, key presses, or
        combat timing. Dedicated macro tools are flagged MEDIUM. Peripheral-
        manufacturer suites (Logitech/Razer/Corsair/etc) are flagged INFO
        only, since the overwhelming majority of installs are unrelated to
        gaming and having the software present isn't evidence of cheating -
        it's just useful context.
    #>
    Write-PhaseHeader -Text ("PHASE 7 / {0}  -  MACRO / AUTOMATION TOOL SCAN" -f $script:Config.TotalPhases)

    $procs = Get-Process -ErrorAction SilentlyContinue
    $macroHits = 0
    $infoHits = 0

    foreach ($p in $procs) {
        $name = $p.ProcessName.ToLower()

        $matchedMacro = $script:MacroToolProcessNames | Where-Object { $name -like "*$($_.ToLower())*" }
        if ($matchedMacro) {
            $macroHits++
            Add-Finding "MEDIUM" "MacroToolScan" ("Detected macro/automation software running: '{0}' (PID {1}), matches '{2}'" -f $p.ProcessName, $p.Id, $matchedMacro[0])
            continue
        }

        $matchedPeripheral = $script:PeripheralMacroSoftware | Where-Object { $name -like "*$($_.ToLower())*" }
        if ($matchedPeripheral) {
            $infoHits++
            Add-Finding "INFO" "MacroToolScan" ("Peripheral software with macro/rebind capability is running: '{0}' (PID {1}) - common and usually unrelated to cheating" -f $p.ProcessName, $p.Id)
        }
    }

    Write-Host "   Checked $($procs.Count) running process(es) for macro/automation tooling." -ForegroundColor Gray
    if ($macroHits -eq 0) {
        Write-Host "   [OK] No dedicated macro/autoclicker software detected." -ForegroundColor Green
    }
    if ($infoHits -gt 0) {
        Write-Host "   [i] Informational peripheral-software hits are listed above and in the summary, but do not count toward the verdict on their own." -ForegroundColor DarkGray
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

    $actionableFindings = @($script:Findings | Where-Object { $_.Severity -ne "INFO" })
    $infoFindings       = @($script:Findings | Where-Object { $_.Severity -eq "INFO" })

    Write-StatLine "[OK] Verified mods (Modrinth)"  $Verified.Count Green
    Write-StatLine "[!] Unverified mods"           $Unknown.Count Yellow
    Write-StatLine "[X] Jar-level threats"         $Threats.Count Red
    Write-StatLine "[i] System-level findings"     $actionableFindings.Count Red
    Write-StatLine "[i] Informational-only notes"  $infoFindings.Count Gray
    Write-Host ""

    if ($actionableFindings.Count -eq 0 -and $Threats.Count -eq 0) {
        Write-Host "   [OK] RESULT: CLEAN - no cheat-client indicators found." -ForegroundColor Green
    } else {
        $high = ($actionableFindings | Where-Object { $_.Severity -eq "HIGH" }).Count + ($Threats | Where-Object { $_.Risk -eq "HIGH" }).Count
        $med  = ($actionableFindings | Where-Object { $_.Severity -eq "MEDIUM" }).Count + ($Threats | Where-Object { $_.Risk -eq "MEDIUM" }).Count
        Write-Host "   [!] RESULT: $high HIGH severity, $med MEDIUM severity finding(s)." -ForegroundColor Red
        Write-Host ""
        if ($actionableFindings.Count -gt 0) {
            $actionableFindings | Sort-Object Severity | Format-Table -AutoSize Severity, Module, Detail | Out-Host
        }
    }

    if ($infoFindings.Count -gt 0) {
        Write-Host "   Informational notes (not counted in verdict):" -ForegroundColor DarkGray
        $infoFindings | Format-Table -AutoSize Severity, Module, Detail | Out-Host
    }

    Write-Host ""
    Write-Host "   Scan completed : $(Get-Date)" -ForegroundColor Gray
    Write-Host ("   Elapsed time   : {0:N1}s" -f ((Get-Date) - $script:StartTime).TotalSeconds) -ForegroundColor Gray
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

    $actionableFindings = @($script:Findings | Where-Object { $_.Severity -ne "INFO" })
    $infoFindings       = @($script:Findings | Where-Object { $_.Severity -eq "INFO" })

    $jarFlagged   = $Threats.Count -gt 0
    $sysFlagged   = $actionableFindings.Count -gt 0
    $anyFlagged   = $jarFlagged -or $sysFlagged

    Write-VerdictBanner -Clean (-not $anyFlagged)

    if (-not $anyFlagged) {
        Write-Host ""
        Write-Host "   [OK] No cheat clients, injectors, or suspicious activity were detected." -ForegroundColor Green
        if ($infoFindings.Count -gt 0) {
            Write-Host "   [i] A few informational-only notes were logged above (e.g. peripheral" -ForegroundColor DarkGray
            Write-Host "       macro software) - these are common and don't affect the verdict." -ForegroundColor DarkGray
        }
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
            if ($t.ClientHits.Count -gt 0) {
                Write-Host ("       Known client name match(es) : {0}" -f ($t.ClientHits -join ", ")) -ForegroundColor Magenta
            }
            if ($t.FeatureHits.Count -gt 0) {
                Write-Host ("       Cheat-module string match(es): {0}" -f ($t.FeatureHits -join ", ")) -ForegroundColor Magenta
            }
            foreach ($e in $t.Embedded) {
                $eparts = @()
                if ($e.ClientHits.Count -gt 0)  { $eparts += ($e.ClientHits -join ", ") }
                if ($e.FeatureHits.Count -gt 0) { $eparts += ($e.FeatureHits -join ", ") }
                Write-Host ("       Embedded jar '{0}' also flagged for: {1}" -f $e.EmbeddedJar, ($eparts -join "; ")) -ForegroundColor Magenta
            }
        }
        Write-Host ""
    }

    if ($sysFlagged) {
        Write-Host "   [!] System-level indicators (not tied to a specific mod file):" -ForegroundColor Red
        foreach ($f in ($actionableFindings | Sort-Object Severity)) {
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
    Invoke-CheatFolderScanPhase
    Invoke-BamParserPhase
    Invoke-ServiceProcessPhase
    Invoke-FilelessBypassPhase
    Invoke-MacroToolScanPhase

    Write-SummaryReport -Verified $p1.Verified -Unknown $p1.Unknown -Threats $threats
    Write-OverallSummary -Threats $threats

    if ($ExportReport) {
        Export-JsonReport -Verified $p1.Verified -Unknown $p1.Unknown -Threats $threats
    }

    Write-Host "   Scan Completed. Please review the verdict above and take appropriate action." -ForegroundColor Cyan
    Write-Host "   Thank you for using Vamp Cheat Scanner. Stay safe and don't cheat!" -ForegroundColor Cyan
}

Main
