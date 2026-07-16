[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ModsPath,

    [Parameter(Mandatory = $false)]
    [switch]$ExportReport
)

$script:Config = @{
    AppName        = "Vamp Cheat Scanner"
    Version        = "3.1.0"
    DefaultModsPath = "$env:APPDATA\.minecraft\mods"
    TempDirName    = "vamp_cheatscanner_tmp"
    TotalPhases    = 10
    Credits        = @(
        @{ Name = "Laffer";        Role = "Ideas" },
        @{ Name = "ArchiveThomas"; Role = "Made by" }
    )
}

$ErrorActionPreference = "SilentlyContinue"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$script:Findings = New-Object System.Collections.Generic.List[Object]
$script:StartTime = Get-Date

# ------------------------------------------------------------------------
# Layout constants - single source of truth so every box lines up
# ------------------------------------------------------------------------
$script:UI = @{
    Width = 74   # inner content width used by all boxes
    TL = [char]0x2554 ; TR = [char]0x2557 ; BL = [char]0x255A ; BR = [char]0x255D  # double corners  ╔ ╗ ╚ ╝
    H  = [char]0x2550 ; V  = [char]0x2551  # double line/pipe  ═ ║
    STL = [char]0x250C ; STR = [char]0x2510 ; SBL = [char]0x2514 ; SBR = [char]0x2518  # single corners  ┌ ┐ └ ┘
    SH  = [char]0x2500 ; SV  = [char]0x2502  # single line/pipe  ─ │
    ML = [char]0x2560 ; MR = [char]0x2563  # double line T-joints  ╠ ╣
}

function Get-VisibleLength {
    param([string]$Text)
    # Strips nothing special today, but centralizes length calc in case
    # of future color-tag style markup, keeping padding math correct.
    return $Text.Length
}

function Write-DoubleBoxLine {
    param([string]$Text = "", [ConsoleColor]$Color = 'White', [string]$Align = 'Left')
    $w = $script:UI.Width
    $len = Get-VisibleLength -Text $Text
    if ($len -gt $w) { $Text = $Text.Substring(0, $w); $len = $w }
    switch ($Align) {
        'Center' {
            $padTotal = $w - $len
            $padL = [math]::Floor($padTotal / 2)
            $padR = $padTotal - $padL
            $line = (" " * $padL) + $Text + (" " * $padR)
        }
        default {
            $line = $Text.PadRight($w)
        }
    }
    Write-Host ("  $($script:UI.V)") -NoNewline -ForegroundColor DarkRed
    Write-Host " $line " -NoNewline -ForegroundColor $Color
    Write-Host "$($script:UI.V)" -ForegroundColor DarkRed
}

function Write-DoubleBoxTop    { Write-Host ("  $($script:UI.TL)" + ($script:UI.H.ToString() * ($script:UI.Width + 2)) + "$($script:UI.TR)") -ForegroundColor DarkRed }
function Write-DoubleBoxBottom { Write-Host ("  $($script:UI.BL)" + ($script:UI.H.ToString() * ($script:UI.Width + 2)) + "$($script:UI.BR)") -ForegroundColor DarkRed }
function Write-DoubleBoxDivider { Write-Host ("  $($script:UI.ML)" + ($script:UI.H.ToString() * ($script:UI.Width + 2)) + "$($script:UI.MR)") -ForegroundColor DarkRed }


$script:CheatClientNames = @(
    "wurst", "impact", "meteor-client", "meteorclient", "future-client",
    "sigma5", "sigma", "aristois", "rusherhack", "salhack", "kamiblue",
    "novoline", "flux-client", "fluxclient", "b0at", "vape", "liquidbounce",
    "wolfram", "clickcrystals", "doomsday",

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
$script:AmbiguousFeatureWords = @("Fly", "Speed", "Velocity", "ESP", "Reach", "Freecam", "Hitboxes")

$script:KnownInjectorProcessNames = @(
    "injector", "loader64", "loader32", "dllinject", "xenos", "extreme-injector",
    "extremeinjector", "memhack", "prestigeloader", "ghostloader"
)

$script:KnownCheatFolders = @(
    ".wurst", ".impact", ".meteor-client", ".meteorclient", ".future-client",
    ".sigma", ".aristois", ".rusherhack", ".salhack", ".kamiblue",
    ".novoline", ".flux", ".liquidbounce", ".wolfram", ".doomsday",
    ".prestige", ".ghost", ".ghostclient", ".rise", ".onset", ".async",
    ".exhibition", ".expression"
)
$script:MacroToolProcessNames = @(
    "autohotkeyu64", "autohotkeyu32", "autohotkey", "ahktray",
    "tinytask", "macrorecorder", "macro recorder", "pulovermacrocreator",
    "quickmacros", "ghostmouse", "jitbitmacrorecorder", "macro toolworks",
    "autoclicker", "gsautoclicker", "opautoclicker", "fastclicker"
)

$script:PeripheralMacroSoftware = @(
    "lghub", "lgshub", "logitech gaming software", "razer synapse",
    "steelseries engine", "corsair icue", "roccat swarm", "wootility"
)

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

$script:KnownLegitTempModules = @(
    '^lib[a-z0-9]+4j\.dll$',
    '^lwjgl.*\.dll$',
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

function Get-ClientNameMatches {
    param([string]$Text)
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $script:CheatClientNames) {
        if ($Text -match [regex]::Escape($name)) { $found.Add($name) }
    }
    return $found
}

function Get-FeatureWordMatches {
    param([string]$Text)
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($word in $script:CheatFeatureWords) {
        $pattern = "(?<![A-Za-z])" + [regex]::Escape($word) + "(?![a-z])"
        if ([regex]::IsMatch($Text, $pattern)) { $found.Add($word) }
    }
    return $found
}

function Get-SignatureRisk {
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


function Get-RunningMinecraftInstances {
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
    Write-Host ""
    Write-DoubleBoxTop
    Write-DoubleBoxLine
    Write-DoubleBoxLine -Text " __     __ _    __  __ ____  "    -Color Red    -Align Center
    Write-DoubleBoxLine -Text " \ \   / // \  |  \/  |  _ \  "    -Color Red    -Align Center
    Write-DoubleBoxLine -Text "  \ \ / // _ \ | |\/| | |_) | "    -Color Red    -Align Center
    Write-DoubleBoxLine -Text "   \ V // ___ \| |  | |  __/  "    -Color Red    -Align Center
    Write-DoubleBoxLine -Text "    \_//_/   \_\_|  |_|_|     "    -Color Red    -Align Center
    Write-DoubleBoxLine
    Write-DoubleBoxLine -Text "C H E A T   S C A N N E R    "    -Color White -Align Center
    Write-DoubleBoxLine
    Write-DoubleBoxDivider
    Write-DoubleBoxLine -Text ("Version         : {0}" -f $script:Config.Version) -Color Gray
    Write-DoubleBoxLine -Text ("Scan started     : {0}" -f (Get-Date)) -Color Gray
    Write-DoubleBoxLine -Text ("Execution mode   : 100% local, no remote code ever run") -Color Cyan
    Write-DoubleBoxDivider
    Write-DoubleBoxLine -Text ("Severity legend  :  [X] HIGH    [!] MEDIUM    [i] INFO") -Color Gray
    Write-DoubleBoxDivider
    $creditLine = ($script:Config.Credits | ForEach-Object { "$($_.Role): $($_.Name)" }) -join "   |   "
    Write-DoubleBoxLine -Text $creditLine -Color DarkYellow -Align Center
    Write-DoubleBoxBottom
    Write-Host ""
}

function Write-PhaseHeader {
    param([string]$Text, [ConsoleColor]$Color = 'Cyan')
    $w = $script:UI.Width
    $label = ">> $Text"
    if ($label.Length -gt $w) { $label = $label.Substring(0, $w) }
    $padded = $label.PadRight($w)
    Write-Host ""
    Write-Host ("  $($script:UI.STL)" + ($script:UI.SH.ToString() * ($w + 2)) + "$($script:UI.STR)") -ForegroundColor $Color
    Write-Host ("  $($script:UI.SV) $padded $($script:UI.SV)") -ForegroundColor $Color
    Write-Host ("  $($script:UI.SBL)" + ($script:UI.SH.ToString() * ($w + 2)) + "$($script:UI.SBR)") -ForegroundColor $Color
}

function Ensure-Administrator {
    $principal = [System.Security.Principal.WindowsPrincipal]::new([System.Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "`n" -ForegroundColor Red
        Write-Host "============================================================" -ForegroundColor DarkGray
        Write-Host " Administrator privileges are required to run this scanner." -ForegroundColor Red
        Write-Host " Please restart PowerShell as Administrator and retry." -ForegroundColor Red
        Write-Host "============================================================" -ForegroundColor DarkGray
        Write-Host "`n" -ForegroundColor Red
        exit 1
    }
}

function Get-CurrentMinecraftProcess {
    return Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^java(w)?$' } | Select-Object -First 1
}

function Get-MinecraftStartTime {
    $mcProc = Get-CurrentMinecraftProcess
    if ($mcProc) { return $mcProc.StartTime }
    return $null
}

function Invoke-SystemCheckerPhase {
    Write-PhaseHeader -Text ("PHASE 1 / {0}  -  SYSTEM CHECKER" -f $script:Config.TotalPhases)

    $bootData = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($bootData) {
        $bootTime = $bootData.LastBootUpTime
        $uptime = (Get-Date) - $bootTime
        Write-Host ("   Boot time: {0}" -f $bootTime.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Gray
        Write-Host ("   Uptime   : {0} days {1:D2}:{2:D2}:{3:D2}" -f $uptime.Days, $uptime.Hours, $uptime.Minutes, $uptime.Seconds) -ForegroundColor Gray
    }

    $mcProc = Get-CurrentMinecraftProcess
    if ($mcProc) {
        try {
            $mcUptime = (Get-Date) - $mcProc.StartTime
            Write-Host ("   Minecraft process: {0} (PID {1})" -f $mcProc.ProcessName, $mcProc.Id) -ForegroundColor Gray
            Write-Host ("   Started         : {0}" -f $mcProc.StartTime.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Gray
            Write-Host ("   Running for     : {0}h {1}m {2}s" -f $mcUptime.Hours, $mcUptime.Minutes, $mcUptime.Seconds) -ForegroundColor Gray
        } catch { }
    } else {
        Write-Host "   Minecraft process not found." -ForegroundColor DarkGray
    }

    $drives = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -ne 5 }
    if ($drives) {
        Write-Host "   Connected drives:" -ForegroundColor Gray
        foreach ($drive in $drives) {
            Write-Host ("     {0}: {1} {2}" -f $drive.DeviceID, $drive.FileSystem, $drive.VolumeName) -ForegroundColor DarkGray
        }
    }

    try {
        $defenderKey  = "HKLM:\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection"
        $rtpValue     = (Get-ItemProperty -Path $defenderKey -Name "DisableRealtimeMonitoring" -ErrorAction SilentlyContinue).DisableRealtimeMonitoring
        $tamper       = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows Defender\Features" -Name "TamperProtection" -ErrorAction SilentlyContinue).TamperProtection

        Write-Host "   Defender RTP: " -NoNewline -ForegroundColor Gray
        if ($rtpValue -eq 1) {
            Write-Host "DISABLED" -ForegroundColor Red
            Add-Finding "HIGH" "SystemChecker" "Windows Defender real-time protection is disabled"
        } else {
            Write-Host "Enabled" -ForegroundColor Green
        }

        Write-Host "   Tamper Protection: " -NoNewline -ForegroundColor Gray
        if ($tamper -eq 5) { Write-Host "Enabled" -ForegroundColor Green }
        elseif ($null -eq $tamper) { Write-Host "Unknown" -ForegroundColor Yellow }
        else { Write-Host "DISABLED" -ForegroundColor Red; Add-Finding "MEDIUM" "SystemChecker" "Windows Defender tamper protection is disabled" }
    } catch {
        Write-Host "   Unable to read Defender status." -ForegroundColor DarkGray
    }

    try {
        $event = Get-WinEvent -LogName "System" -FilterXPath "*[System[EventID=104 or EventID=1102]]" -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($event) {
            Write-Host "   Event logs cleared recently: ID $($event.Id) at $($event.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Yellow
            Add-Finding "MEDIUM" "SystemChecker" "Event log clear recorded (ID $($event.Id))"
        }
    } catch { }

    Write-Host "   System check complete." -ForegroundColor Gray
}

function Invoke-HiddenModFilesPhase {
    param([string]$ModsPath)
    Write-PhaseHeader -Text ("PHASE 4 / {0}  -  HIDDEN FILES IN MODS FOLDER" -f $script:Config.TotalPhases)

    if (-not (Test-Path $ModsPath)) {
        Write-Host "   Mods folder not found: $ModsPath" -ForegroundColor DarkGray
        return
    }

    $files = Get-ChildItem -Path $ModsPath -Recurse -Force -ErrorAction SilentlyContinue
    $suspicious = @()
    foreach ($item in $files) {
        $hidden = $item.Attributes -band [System.IO.FileAttributes]::Hidden
        $system = $item.Attributes -band [System.IO.FileAttributes]::System
        if ($hidden -or $system) {
            $suspicious += [PSCustomObject]@{
                Path = $item.FullName
                Hidden = $hidden
                System = $system
                Extension = $item.Extension
            }
        }
    }

    if ($suspicious.Count -gt 0) {
        Write-Host "   Hidden/system files detected inside mods folder:" -ForegroundColor Yellow
        foreach ($entry in $suspicious | Sort-Object Hidden, System -Descending) {
            $flags = @()
            if ($entry.Hidden) { $flags += "Hidden" }
            if ($entry.System) { $flags += "System" }
            Write-Host ("     - {0} [{1}]" -f $entry.Path, ($flags -join ', ')) -ForegroundColor DarkGray
        }
        Add-Finding "MEDIUM" "HiddenFiles" ("Found $($suspicious.Count) hidden/system file(s) in mods folder")
    } else {
        Write-Host "   No hidden or system files detected in mods folder." -ForegroundColor Green
    }
}

function Invoke-CommandHistoryPhase {
    Write-PhaseHeader -Text ("PHASE 10 / {0}  -  COMMAND HISTORY ANALYSIS" -f $script:Config.TotalPhases)

    $mcStart = Get-MinecraftStartTime
    $since = if ($mcStart) { $mcStart } else { (Get-Date).AddHours(-24) }
    Write-Host ("   Searching commands since: {0}" -f $since.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Gray

    $suspiciousCommands = @(
        "powershell -enc", "cmd /c", "certutil -decode", "certutil -urlcache",
        "bitsadmin /transfer", "Start-BitsTransfer", "Invoke-WebRequest", "curl -o", "wget -O",
        "rundll32.exe", "regsvr32.exe", "mshta.exe", "wscript.exe", "cscript.exe",
        "taskkill /f", "Stop-Process -Force", "Get-Process", "Inject", "LoadLibrary", "VirtualAlloc",
        "WriteProcessMemory", "netsh", "net use", "net user", "net localgroup", "net share",
        "reg add", "reg delete", "reg query", "Set-ItemProperty", "Remove-ItemProperty", "New-ItemProperty",
        "bcdedit", "wmic", "wevtutil", "cipher", "sfc", "chkdsk",
        "cheat", "hack", "inject", "bypass", "crack", "patch", "mod menu",
        "trainer", "esp", "aimbot", "wallhack", "attrib +h", "attrib +s",
        "cipher /e", "hidden", "stealth", "IEX", "Invoke-Expression", "DownloadString",
        "DownloadFile", "FromBase64String", "proxy", "tunnel", "socks"
    )

    $historyPath = Join-Path $env:USERPROFILE "AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
    $suspiciousPS = @()
    if (Test-Path $historyPath) {
        $historyFile = Get-Item -LiteralPath $historyPath -ErrorAction SilentlyContinue
        $lines = Get-Content -Path $historyPath -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            $lineTime = $null
            $command = $line
            if ($line -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}') {
                try {
                    $lineTime = [datetime]::Parse($line.Substring(0, 19))
                    $command = $line.Substring(20).Trim()
                } catch { }
            }

            if ($lineTime) {
                if ($lineTime -lt $since) { continue }
            } else {
                continue
            }

            foreach ($pattern in $suspiciousCommands) {
                if ($command -like "*$pattern*" -or $command -match [regex]::Escape($pattern)) {
                    $suspiciousPS += [PSCustomObject]@{ Source = 'PowerShell'; Command = $command; Pattern = $pattern; Time = $lineTime }
                    break
                }
            }
        }
    }

    if ($suspiciousPS.Count -gt 0) {
        Write-Host "   Suspicious PowerShell history commands found: $($suspiciousPS.Count)" -ForegroundColor Yellow
        foreach ($entry in $suspiciousPS | Select-Object -First 10) {
            Write-Host ("     * [{0}] {1}" -f $entry.Pattern, $entry.Command) -ForegroundColor DarkGray
        }
        Add-Finding "MEDIUM" "CommandHistory" ("Suspicious PowerShell history entries detected ($($suspiciousPS.Count))")
    } elseif (Test-Path $historyPath) {
        Write-Host "   No suspicious PowerShell history entries found." -ForegroundColor Green
    } else {
        Write-Host "   PowerShell history file not found." -ForegroundColor DarkGray
    }

    try {
        $events = Get-WinEvent -LogName "Microsoft-Windows-ProcessCreation/Operational" -MaxEvents 200 -ErrorAction SilentlyContinue | Where-Object { $_.Id -eq 4688 }
        $cmdHits = @()
        foreach ($event in $events) {
            if ($event.TimeCreated -lt $since) { continue }
            $message = $event.Message
            $commandLine = ""
            if ($message -match 'Command Line:\s*(.+?)\r?\n') {
                $commandLine = $matches[1].Trim()
            } elseif ($message -match 'Command Line:\s*(.+)$') {
                $commandLine = $matches[1].Trim()
            }

            if (-not $commandLine) { $commandLine = $message }
            if ($commandLine -and ($commandLine -like "*cmd.exe*" -or $commandLine -like "*command.com*" -or $commandLine -like "*powershell.exe*" -or $commandLine -like "*powershell -enc*")) {
                foreach ($pattern in $suspiciousCommands) {
                    if ($commandLine -like "*$pattern*" -or $commandLine -match [regex]::Escape($pattern)) {
                        $cmdHits += [PSCustomObject]@{ Source = 'CMD'; Time = $event.TimeCreated; Pattern = $pattern; Command = $commandLine }
                        break
                    }
                }
            }
        }
        if ($cmdHits.Count -gt 0) {
            Write-Host "   Suspicious process creation events found: $($cmdHits.Count)" -ForegroundColor Yellow
            foreach ($hit in $cmdHits | Select-Object -First 10) {
                Write-Host ("     * [{0}] {1}" -f $hit.Pattern, $hit.Command) -ForegroundColor DarkGray
            }
            Add-Finding "MEDIUM" "CommandHistory" ("Suspicious process creation activity detected ($($cmdHits.Count))")
        } else {
            Write-Host "   No suspicious process creation events found." -ForegroundColor Green
        }
    } catch {
        Write-Host "   Unable to analyze process creation event logs." -ForegroundColor DarkGray
    }
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
    # Record the finding for aggregation. Do not print immediately so we can
    # present a single consolidated summary at the end of the scan.
    $script:Findings.Add([PSCustomObject]@{ Time = (Get-Date); Severity = $Severity; Module = $Module; Detail = $Detail })
}

function Get-FileSHA1 {
    param([string]$FilePath)
    try { return (Get-FileHash -Path $FilePath -Algorithm SHA1 -ErrorAction Stop).Hash }
    catch { return $null }
}

    Write-PhaseHeader -Text "FINAL SUMMARY"

    $all = if ($script:Findings) { $script:Findings } else { @() }

    # Compute verdict
    $high = ($all | Where-Object { $_.Severity -eq 'HIGH' }).Count
    $med  = ($all | Where-Object { $_.Severity -eq 'MEDIUM' }).Count
    $total = $all.Count

    if ($high -gt 0) {
        $verdict = 'CHEAT DETECTED'
        $vColor = 'Red'
        $recommend = 'Quarantine the detected files, stop play, and investigate processes immediately.'
    } elseif ($med -gt 0) {
        $verdict = 'SUSPICIOUS ACTIVITY'
        $vColor = 'Yellow'
        $recommend = 'Review the listed items and verify whether they are legitimate tools or false positives.'
    } else {
        $verdict = 'CLEAN'
        $vColor = 'Green'
        $recommend = 'No actionable threats found. Maintain usual security hygiene.'
    }

    Write-Host ""
    Write-Host (("=" * 60)) -ForegroundColor $vColor
    Write-Host ("  OVERALL VERDICT: {0}" -f $verdict) -ForegroundColor $vColor
    Write-Host (("=" * 60)) -ForegroundColor $vColor
    Write-Host ("   Summary: {0} finding(s) total — {1} HIGH, {2} MEDIUM" -f $total, $high, $med) -ForegroundColor Gray
    Write-Host ("   Recommendation: {0}" -f $recommend) -ForegroundColor Cyan

    Write-Host "" -ForegroundColor Gray

    if ($all.Count -eq 0) {
        Write-Host "   No findings were recorded during the scan." -ForegroundColor Green
    } else {
        $bySeverity = $all | Group-Object -Property Severity | Sort-Object {[array]::IndexOf(@('HIGH','MEDIUM','LOW','INFO'), $_.Name)}
        foreach ($g in $bySeverity) {
            $sev = $g.Name
            $count = $g.Count
            $color = switch ($sev) { 'HIGH' { 'Red' } 'MEDIUM' { 'Yellow' } default { 'Gray' } }
            Write-Host ("   {0,7}: {1}" -f $sev, $count) -ForegroundColor $color
        }

        Write-Host "" -ForegroundColor Gray
        Write-Host "   Findings by module:" -ForegroundColor Gray
        $byModule = $all | Group-Object -Property Module | Sort-Object Count -Descending
        foreach ($m in $byModule) {
            Write-Host ("     - {0}: {1}" -f $m.Name, $m.Count) -ForegroundColor DarkGray
        }

        Write-Host "" -ForegroundColor Gray
        Write-Host "   Detailed findings (most recent first):" -ForegroundColor Gray
        foreach ($f in ($all | Sort-Object -Property Time -Descending)) {
            $t = if ($f.Time) { $f.Time.ToString('yyyy-MM-dd HH:mm:ss') } else { 'n/a' }
            $sevColor = switch ($f.Severity) { 'HIGH' { 'Red' } 'MEDIUM' { 'Yellow' } default { 'Gray' } }
            Write-Host ("     [{0}] {1} - {2} ({3})" -f $t, $f.Severity, $f.Detail, $f.Module) -ForegroundColor $sevColor
        }
    }

    Write-Host "" -ForegroundColor Gray
    Write-Host ("   Verified mods: {0}    Unknown mods: {1}    Threats: {2}" -f ($Verified.Count -as [int]), ($Unknown.Count -as [int]), ($Threats.Count -as [int])) -ForegroundColor Cyan
    Write-Host "" -ForegroundColor Gray
    Write-Host ("   Verified mods: {0}    Unknown mods: {1}    Threats: {2}" -f ($Verified.Count -as [int]), ($Unknown.Count -as [int]), ($Threats.Count -as [int])) -ForegroundColor Cyan
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

    $count = 0
    foreach ($userKey in $userKeys) {
        $props = Get-ItemProperty -Path $userKey.PSPath -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($prop in $props.PSObject.Properties) {
            if ($prop.Name -notmatch '^\\Device\\HarddiskVolume') { continue }
            $count++
            $exePath = $prop.Name
            $exeName = [System.IO.Path]::GetFileName($exePath)
            if ($exeName -ieq 'MeowDoomsdayFucker.exe') { continue }
            $matchedClient = $script:CheatClientNames | Where-Object { $exePath.ToLower() -like "*$($_.ToLower())*" }
            if ($matchedClient) {
                Add-Finding "HIGH" "BamParser" ("Recently executed program matches known cheat-client name '{0}': {1}" -f $matchedClient[0], $exePath)
                continue
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

function Invoke-MacroToolScanPhase {
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

    Write-Host "   Summary of scan results:" -ForegroundColor White
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
            $actionableFindings | Sort-Object Severity | Format-Table -Property Severity, Module, Detail -AutoSize | Out-Host
        }
    }

    if ($infoFindings.Count -gt 0) {
        Write-Host "   Informational notes (not counted in verdict):" -ForegroundColor DarkGray
        $infoFindings | Format-Table -Property Severity, Module, Detail -AutoSize | Out-Host
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
    $color = if ($Clean) { "Green" } else { "Red" }
    $label = if ($Clean) { "V E R D I C T   :   C L E A N" } else { "V E R D I C T   :   C H E A T I N G   D E T E C T E D" }

    $w = $script:UI.Width
    Write-Host ""
    Write-Host ("  $($script:UI.TL)" + ($script:UI.H.ToString() * ($w + 2)) + "$($script:UI.TR)") -ForegroundColor $color
    Write-Host ("  $($script:UI.V)" + (" " * ($w + 2)) + "$($script:UI.V)") -ForegroundColor $color

    $starLine = "*" * $w
    Write-Host ("  $($script:UI.V) $starLine $($script:UI.V)") -ForegroundColor $color

    $padTotal = $w - $label.Length
    $padLeft = [math]::Max(0, [math]::Floor($padTotal / 2))
    $padRight = [math]::Max(0, $padTotal - $padLeft)
    $centeredLabel = (" " * $padLeft) + $label + (" " * $padRight)
    Write-Host ("  $($script:UI.V) $centeredLabel $($script:UI.V)") -ForegroundColor $color

    Write-Host ("  $($script:UI.V) $starLine $($script:UI.V)") -ForegroundColor $color
    Write-Host ("  $($script:UI.V)" + (" " * ($w + 2)) + "$($script:UI.V)") -ForegroundColor $color
    Write-Host ("  $($script:UI.BL)" + ($script:UI.H.ToString() * ($w + 2)) + "$($script:UI.BR)") -ForegroundColor $color
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

    Write-Host ""
    $totalHigh   = ($actionableFindings | Where-Object { $_.Severity -eq "HIGH" }).Count + ($Threats | Where-Object { $_.Risk -eq "HIGH" }).Count
    $totalMedium = ($actionableFindings | Where-Object { $_.Severity -eq "MEDIUM" }).Count + ($Threats | Where-Object { $_.Risk -eq "MEDIUM" }).Count
    $totalInfo   = $infoFindings.Count
    $totalMods   = $Threats.Count
    $totalSys    = $actionableFindings.Count

    Write-Host "   VERDICT SUMMARY" -ForegroundColor White
    Write-StatLine "Verdict status"           (if (-not $anyFlagged) { 'CLEAN' } else { 'CHEATING DETECTED' }) (if (-not $anyFlagged) { [ConsoleColor]::Green } else { [ConsoleColor]::Red })
    Write-StatLine "Flagged mods"             $totalMods (if ($totalMods -eq 0) { [ConsoleColor]::Green } else { [ConsoleColor]::Red })
    Write-StatLine "System-level indicators"   $totalSys (if ($totalSys -eq 0) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow })
    Write-StatLine "High severity hits"       $totalHigh (if ($totalHigh -eq 0) { [ConsoleColor]::Green } else { [ConsoleColor]::Red })
    Write-StatLine "Medium severity hits"     $totalMedium (if ($totalMedium -eq 0) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow })
    Write-StatLine "Informational notes"      $totalInfo Gray
    Write-Host ""

    if (-not $anyFlagged) {
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

function Write-CreditsFooter {
    $w = $script:UI.Width
    Write-Host ""
    Write-Host ("  $($script:UI.STL)" + ($script:UI.SH.ToString() * ($w + 2)) + "$($script:UI.STR)") -ForegroundColor DarkYellow
    $title = "CREDITS"
    $padTotal = $w - $title.Length
    $padL = [math]::Floor($padTotal / 2); $padR = $padTotal - $padL
    Write-Host ("  $($script:UI.SV) " + (" " * $padL) + $title + (" " * $padR) + " $($script:UI.SV)") -ForegroundColor DarkYellow
    Write-Host ("  $($script:UI.STL)" + ($script:UI.SH.ToString() * ($w + 2)) + "$($script:UI.STR)".Replace($script:UI.STL,$script:UI.ML).Replace($script:UI.STR,$script:UI.MR)) -ForegroundColor DarkYellow
    foreach ($c in $script:Config.Credits) {
        $line = ("{0,-14} : {1}" -f $c.Role, $c.Name)
        $pad = $w - $line.Length
        if ($pad -lt 0) { $pad = 0 }
        Write-Host ("  $($script:UI.SV) $line" + (" " * $pad) + " $($script:UI.SV)") -ForegroundColor Yellow
    }
    Write-Host ("  $($script:UI.SBL)" + ($script:UI.SH.ToString() * ($w + 2)) + "$($script:UI.SBR)") -ForegroundColor DarkYellow
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
        Credits   = $script:Config.Credits
    }
    try {
        $report | ConvertTo-Json -Depth 10 | Out-File -FilePath $path -Encoding UTF8
        Write-Host "   [OK] Report exported to: $path" -ForegroundColor Green
    } catch {
        Write-Host "   [X] Failed to export report: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Main {
    Write-Banner

    $path = Resolve-ModsPath -ExplicitPath $ModsPath
    Write-Host ""

    Ensure-Administrator
    $p1 = Invoke-JarParserPhase -Path $path
    $threats = Invoke-DeepThreatScanPhase -UnknownMods $p1.Unknown
    Invoke-HiddenModFilesPhase -ModsPath $path
    Invoke-CheatFolderScanPhase
    Invoke-BamParserPhase
    Invoke-ServiceProcessPhase
    Invoke-FilelessBypassPhase
    Invoke-MacroToolScanPhase
    Invoke-CommandHistoryPhase

    Write-FinalSummary -Verified $p1.Verified -Unknown $p1.Unknown -Threats $threats

    if ($ExportReport) {
        Export-JsonReport -Verified $p1.Verified -Unknown $p1.Unknown -Threats $threats
    }

    Write-CreditsFooter

    Write-Host "   Scan Completed. Please review the verdict above and take appropriate action." -ForegroundColor Cyan
    Write-Host "   Thank you for using Vamp Cheat Scanner. Stay safe and don't cheat!" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "   Press any key to exit this scan..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

Main
