[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ModsPath,

    [Parameter(Mandatory = $false)]
    [switch]$ExportReport
)

# ===========================================================================
# Vamp Cheat Scanner + Live Memory String Scanner (Combined Edition)
# - All detection phases from the original "Vamp Cheat Scanner"
# - Plus a live javaw/java memory string scan (from the memory scanner tool)
# - Final output is a single dark-dashboard HTML report that auto-opens
# ===========================================================================

$script:Config = @{
    AppName        = "Vamp Cheat Scanner"
    Version        = "4.0.0-combined"
    DefaultModsPath = "$env:APPDATA\.minecraft\mods"
    TempDirName    = "vamp_cheatscanner_tmp"
    TotalPhases    = 11
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
# Layout constants for console box drawing
# ------------------------------------------------------------------------
$script:UI = @{
    Width = 74
    TL = [char]0x2554 ; TR = [char]0x2557 ; BL = [char]0x255A ; BR = [char]0x255D
    H  = [char]0x2550 ; V  = [char]0x2551
    STL = [char]0x250C ; STR = [char]0x2510 ; SBL = [char]0x2514 ; SBR = [char]0x2518
    SH  = [char]0x2500 ; SV  = [char]0x2502
    ML = [char]0x2560 ; MR = [char]0x2563
}

function Get-VisibleLength {
    param([string]$Text)
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

# ------------------------------------------------------------------------
# Signature databases
# ------------------------------------------------------------------------
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

# ------------------------------------------------------------------------
# Memory scanner search terms (from the standalone memory scanner tool)
# ------------------------------------------------------------------------
$script:MemorySearchTerms = @(
    "Autototem", "Auto crystal", "Cw crystal", "Anchor macro", "Anchormacro",
    "Auto anchor", "TriggerBot", "AutoDhand", "SlientAim", "AutoInventoryTotem",
    "aimassist", "AutoCrystal", "prestige", "argon", "stop_cracking", "self de"
)
$script:MemoryMinStringLength = 4

# ------------------------------------------------------------------------
# Native interop for live process memory string scanning
# ------------------------------------------------------------------------
$memScanCsharp = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class MemScanner
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint processAccess, bool bInheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int VirtualQueryEx(IntPtr hProcess, IntPtr lpAddress, out MEMORY_BASIC_INFORMATION lpBuffer, uint dwLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int dwSize, out IntPtr lpNumberOfBytesRead);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out long lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES
    {
        public uint PrivilegeCount;
        public long Luid;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORY_BASIC_INFORMATION
    {
        public IntPtr BaseAddress;
        public IntPtr AllocationBase;
        public uint AllocationProtect;
        public IntPtr RegionSize;
        public uint State;
        public uint Protect;
        public uint Type;
    }

    const uint PROCESS_QUERY_INFORMATION = 0x0400;
    const uint PROCESS_VM_READ = 0x0010;
    const uint MEM_COMMIT = 0x1000;
    const uint PAGE_NOACCESS = 0x01;
    const uint PAGE_GUARD = 0x100;
    const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    const uint TOKEN_QUERY = 0x0008;
    const uint SE_PRIVILEGE_ENABLED = 0x0002;

    public static void EnableDebugPrivilege()
    {
        IntPtr hToken;
        IntPtr hProc = System.Diagnostics.Process.GetCurrentProcess().Handle;
        if (!OpenProcessToken(hProc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out hToken)) return;

        long luid;
        if (!LookupPrivilegeValue(null, "SeDebugPrivilege", out luid)) { CloseHandle(hToken); return; }

        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.PrivilegeCount = 1;
        tp.Luid = luid;
        tp.Attributes = SE_PRIVILEGE_ENABLED;

        AdjustTokenPrivileges(hToken, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        CloseHandle(hToken);
    }

    public static List<string> ScanProcess(int pid, string[] terms, int minLen)
    {
        var results = new List<string>();
        IntPtr hProcess = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
        if (hProcess == IntPtr.Zero) return results;

        IntPtr address = IntPtr.Zero;
        int mbiSize = Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION));

        while (true)
        {
            MEMORY_BASIC_INFORMATION mbi;
            int ret = VirtualQueryEx(hProcess, address, out mbi, (uint)mbiSize);
            if (ret == 0) break;

            long regionSize = mbi.RegionSize.ToInt64();
            if (regionSize <= 0) break;

            bool readable = mbi.State == MEM_COMMIT &&
                             (mbi.Protect & PAGE_NOACCESS) == 0 &&
                             (mbi.Protect & PAGE_GUARD) == 0;

            if (readable)
            {
                long toRead = Math.Min(regionSize, 64L * 1024 * 1024);
                byte[] buffer = new byte[toRead];
                IntPtr bytesRead;
                if (ReadProcessMemory(hProcess, mbi.BaseAddress, buffer, (int)toRead, out bytesRead))
                {
                    ScanBuffer(buffer, (int)bytesRead, terms, minLen, results);
                }
            }

            long next = mbi.BaseAddress.ToInt64() + regionSize;
            if (next <= address.ToInt64()) break;
            address = new IntPtr(next);

            if (results.Count > 3000) break;
        }

        CloseHandle(hProcess);
        return results;
    }

    static void ScanBuffer(byte[] buffer, int length, string[] terms, int minLen, List<string> results)
    {
        int start = -1;
        for (int i = 0; i < length; i++)
        {
            byte b = buffer[i];
            bool printable = b >= 32 && b <= 126;
            if (printable)
            {
                if (start == -1) start = i;
            }
            else
            {
                if (start != -1)
                {
                    int len = i - start;
                    if (len >= minLen)
                    {
                        string s = Encoding.ASCII.GetString(buffer, start, len);
                        CheckMatch(s, terms, results);
                    }
                    start = -1;
                }
            }
        }
        if (start != -1 && (length - start) >= minLen)
        {
            string s = Encoding.ASCII.GetString(buffer, start, length - start);
            CheckMatch(s, terms, results);
        }

        start = -1;
        int i2 = 0;
        while (i2 + 1 < length)
        {
            byte lo = buffer[i2];
            byte hi = buffer[i2 + 1];
            bool printable = hi == 0 && lo >= 32 && lo <= 126;
            if (printable)
            {
                if (start == -1) start = i2;
                i2 += 2;
            }
            else
            {
                if (start != -1)
                {
                    int len = (i2 - start) / 2;
                    if (len >= minLen)
                    {
                        string s = Encoding.Unicode.GetString(buffer, start, i2 - start);
                        CheckMatch(s, terms, results);
                    }
                    start = -1;
                }
                i2 += 1;
            }
        }
    }

    static void CheckMatch(string s, string[] terms, List<string> results)
    {
        foreach (var term in terms)
        {
            if (s.IndexOf(term, StringComparison.OrdinalIgnoreCase) >= 0)
            {
                results.Add(term + " :: " + s);
                break;
            }
        }
    }
}
"@
Add-Type -TypeDefinition $memScanCsharp -Language CSharp

function HtmlEncode {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return $Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}

# ------------------------------------------------------------------------
# Minecraft process / mods folder discovery
# ------------------------------------------------------------------------
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

    # Dedupe: different java-family PIDs (e.g. a bootstrap process and the
    # real game process, or a launcher's own JVM) can resolve to the exact
    # same game directory. That's one real instance, not two - collapse
    # them so the user isn't asked to pick between "duplicates" of the
    # same install.
    $deduped = @($instances | Group-Object {
        $resolved = (Resolve-Path -LiteralPath $_.GameDir -ErrorAction SilentlyContinue).Path
        if ($resolved) { $resolved.ToLower() } else { $_.GameDir.ToLower() }
    } | ForEach-Object { $_.Group | Select-Object -First 1 })

    return @($deduped)
}

function Resolve-ModsPath {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        Write-Host "  -> Mods path      : $ExplicitPath (explicitly specified)" -ForegroundColor Gray
        return $ExplicitPath
    }

    Write-Host "  -> Detecting running Minecraft instance..." -ForegroundColor Gray
    $instances = @(Get-RunningMinecraftInstances)

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
    Write-DoubleBoxLine -Text "Final report will be written as an HTML dashboard" -Color DarkYellow -Align Center
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

# ------------------------------------------------------------------------
# Phase 1: System Checker
# ------------------------------------------------------------------------
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

function Get-FileSHA1 {
    param([string]$FilePath)
    try { return (Get-FileHash -Path $FilePath -Algorithm SHA1 -ErrorAction Stop).Hash }
    catch { return $null }
}

function Get-ModrinthProject {
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

# ------------------------------------------------------------------------
# Phase 2: Jar Parser & Mod Verification
# ------------------------------------------------------------------------
function Invoke-JarParserPhase {
    param([string]$Path)
    Write-PhaseHeader -Text ("PHASE 2 / {0}  -  JAR PARSER & MOD VERIFICATION" -f $script:Config.TotalPhases)

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
    return @($threats)
}

# ------------------------------------------------------------------------
# Phase 3: Deep Threat Scan
# ------------------------------------------------------------------------
function Invoke-DeepThreatScanPhase {
    param($UnknownMods)
    Write-PhaseHeader -Text ("PHASE 3 / {0}  -  DEEP THREAT SCAN" -f $script:Config.TotalPhases)

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
        $embedded = @(Test-EmbeddedJars -JarPath $mod.FilePath -TempDir $tempDir)
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
    return @($threats)
}

# ------------------------------------------------------------------------
# Phase 4: Hidden Files in Mods Folder
# ------------------------------------------------------------------------
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

# ------------------------------------------------------------------------
# Phase 5: Cheat-Client Folder Scan
# ------------------------------------------------------------------------
function Invoke-CheatFolderScanPhase {
    Write-PhaseHeader -Text ("PHASE 5 / {0}  -  CHEAT-CLIENT FOLDER SCAN" -f $script:Config.TotalPhases)

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

# ------------------------------------------------------------------------
# Phase 6: BAM Parser (execution history)
# ------------------------------------------------------------------------
function Invoke-BamParserPhase {
    Write-PhaseHeader -Text ("PHASE 6 / {0}  -  BAM PARSER (EXECUTION HISTORY)" -f $script:Config.TotalPhases)

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

# ------------------------------------------------------------------------
# Phase 7: Services & Process Check
# ------------------------------------------------------------------------
function Invoke-ServiceProcessPhase {
    Write-PhaseHeader -Text ("PHASE 7 / {0}  -  SERVICES & PROCESS CHECK" -f $script:Config.TotalPhases)

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

# ------------------------------------------------------------------------
# Phase 8: Fileless Bypass Detection
# ------------------------------------------------------------------------
function Invoke-FilelessBypassPhase {
    Write-PhaseHeader -Text ("PHASE 8 / {0}  -  FILELESS BYPASS DETECTION" -f $script:Config.TotalPhases)

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

# ------------------------------------------------------------------------
# Phase 9: Macro / Automation Tool Scan
# ------------------------------------------------------------------------
function Invoke-MacroToolScanPhase {
    Write-PhaseHeader -Text ("PHASE 9 / {0}  -  MACRO / AUTOMATION TOOL SCAN" -f $script:Config.TotalPhases)

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

# ------------------------------------------------------------------------
# Phase 10: Live Memory String Scan (from the standalone memory scanner)
# ------------------------------------------------------------------------
function Invoke-MemoryStringScanPhase {
    Write-PhaseHeader -Text ("PHASE 10 / {0}  -  LIVE MEMORY STRING SCAN" -f $script:Config.TotalPhases)

    [MemScanner]::EnableDebugPrivilege()

    $processes = Get-Process -Name "javaw" -ErrorAction SilentlyContinue
    if (-not $processes) { $processes = Get-Process -Name "java" -ErrorAction SilentlyContinue }

    if (-not $processes) {
        Write-Host "   No running javaw.exe/java.exe process found - skipping memory scan." -ForegroundColor DarkGray
        return @{}
    }

    $resultsByPid = @{}

    foreach ($proc in $processes) {
        Write-Host "   -> Scanning memory of PID $($proc.Id)..." -NoNewline -ForegroundColor Gray

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $runspace = [PowerShell]::Create()
        $runspace.AddScript({
            param($pid_, $terms, $minLen)
            [MemScanner]::ScanProcess($pid_, $terms, $minLen)
        }) | Out-Null
        $runspace.AddArgument($proc.Id) | Out-Null
        $runspace.AddArgument($script:MemorySearchTerms) | Out-Null
        $runspace.AddArgument($script:MemoryMinStringLength) | Out-Null
        $handle = $runspace.BeginInvoke()

        while (-not $handle.IsCompleted) {
            Start-Sleep -Milliseconds 400
            Write-Host "." -NoNewline -ForegroundColor Gray
        }
        $sw.Stop()

        $results = $runspace.EndInvoke($handle)
        $runspace.Dispose()

        Write-Host (" done ({0:0.0}s, {1} hit(s))" -f ($sw.ElapsedMilliseconds / 1000), $results.Count) -ForegroundColor $(if ($results.Count -gt 0) { "Red" } else { "Green" })

        if ($results.Count -gt 0) {
            Add-Finding "HIGH" "MemoryScan" ("Process PID $($proc.Id): $($results.Count) suspicious in-memory string hit(s)")
        }

        $resultsByPid[$proc.Id] = @{
            StartTime      = $proc.StartTime
            Results        = $results
            ElapsedSeconds = [math]::Round($sw.ElapsedMilliseconds / 1000, 1)
        }
    }

    return $resultsByPid
}

# ------------------------------------------------------------------------
# Phase 11: Command History Analysis
# ------------------------------------------------------------------------
function Invoke-CommandHistoryPhase {
    Write-PhaseHeader -Text ("PHASE 11 / {0}  -  COMMAND HISTORY ANALYSIS" -f $script:Config.TotalPhases)

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

function Export-JsonReport {
    param($Verified, $Unknown, $Threats, $MemoryResults)
    $path = Join-Path $env:USERPROFILE "Desktop\VampCheatScanner-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    $report = @{
        Timestamp      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Version        = $script:Config.Version
        Verified       = $Verified
        Unknown        = $Unknown
        JarThreats     = $Threats
        SystemFindings = $script:Findings
        MemoryScan     = $MemoryResults
        Credits        = $script:Config.Credits
    }
    try {
        $report | ConvertTo-Json -Depth 10 | Out-File -FilePath $path -Encoding UTF8
        Write-Host "   [OK] JSON report exported to: $path" -ForegroundColor Green
    } catch {
        Write-Host "   [X] Failed to export JSON report: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ===========================================================================
# HTML dashboard report builder
# ===========================================================================
function Build-HtmlReport {
    param($Verified, $Unknown, $Threats, $MemoryResultsByPid)

    $actionableFindings = @($script:Findings | Where-Object { $_.Severity -ne "INFO" })
    $infoFindings       = @($script:Findings | Where-Object { $_.Severity -eq "INFO" })

    $totalMemoryHits = 0
    foreach ($k in $MemoryResultsByPid.Keys) { $totalMemoryHits += $MemoryResultsByPid[$k].Results.Count }

    $jarFlagged = $Threats.Count -gt 0
    $sysFlagged = $actionableFindings.Count -gt 0
    $memFlagged = $totalMemoryHits -gt 0
    $anyFlagged = $jarFlagged -or $sysFlagged -or $memFlagged

    $verdictClass = if ($anyFlagged) { "flagged" } else { "clean" }
    $verdictText  = if ($anyFlagged) { "CHEATING DETECTED" } else { "CLEAN" }

    $totalHigh   = ($actionableFindings | Where-Object { $_.Severity -eq "HIGH" }).Count + ($Threats | Where-Object { $_.Risk -eq "HIGH" }).Count
    $totalMedium = ($actionableFindings | Where-Object { $_.Severity -eq "MEDIUM" }).Count + ($Threats | Where-Object { $_.Risk -eq "MEDIUM" }).Count

    $verdictSub = if (-not $anyFlagged) {
        "No cheat clients, injectors, flagged mods, or suspicious in-memory strings were found."
    } else {
        "$($Threats.Count) flagged mod(s), $($actionableFindings.Count) system-level finding(s), $totalMemoryHits in-memory string hit(s)."
    }

    # --- Verified mods panel -------------------------------------------------
    $verifiedHtml = ""
    if ($Verified.Count -gt 0) {
        $rows = ""
        foreach ($v in ($Verified | Sort-Object ModName)) {
            $rows += "<div class='mod-row'><span class='mod-name'>$(HtmlEncode $v.ModName)</span><span class='mod-file'>$(HtmlEncode $v.FileName)</span><span class='mod-size'>$($v.SizeMB) MB</span></div>"
        }
        $verifiedHtml = @"
    <div class="panel">
      <div class="panel-header">
        <div><div class="panel-title">Verified Mods (Modrinth)</div><div class="panel-sub">Matched against public mod registry</div></div>
        <div class="badge badge-clean">$($Verified.Count) VERIFIED</div>
      </div>
      <div class="panel-body">$rows</div>
    </div>
"@
    }

    # --- Jar threats panel ---------------------------------------------------
    $jarHtml = ""
    if ($Threats.Count -gt 0) {
        $rows = ""
        foreach ($t in $Threats) {
            $badgeClass = if ($t.Risk -eq "HIGH") { "badge-flagged" } else { "badge-medium" }
            $clientHits = if ($t.ClientHits.Count -gt 0) { "<div class='detail-line'><b>Known client match:</b> $(HtmlEncode ($t.ClientHits -join ', '))</div>" } else { "" }
            $featureHits = if ($t.FeatureHits.Count -gt 0) { "<div class='detail-line'><b>Cheat-module strings:</b> $(HtmlEncode ($t.FeatureHits -join ', '))</div>" } else { "" }
            $embeddedHtml = ""
            foreach ($e in $t.Embedded) {
                $eparts = @()
                if ($e.ClientHits.Count -gt 0) { $eparts += ($e.ClientHits -join ", ") }
                if ($e.FeatureHits.Count -gt 0) { $eparts += ($e.FeatureHits -join ", ") }
                $embeddedHtml += "<div class='detail-line'><b>Embedded jar '$(HtmlEncode $e.EmbeddedJar)':</b> $(HtmlEncode ($eparts -join '; '))</div>"
            }
            $rows += @"
        <div class="term-row">
          <div class="term-head">
            <span class="term-name">$(HtmlEncode $t.FileName)</span>
            <span class="badge $badgeClass">$($t.Risk)</span>
          </div>
          <div class="detail-line mono">$(HtmlEncode $t.FilePath)</div>
          $clientHits
          $featureHits
          $embeddedHtml
        </div>
"@
        }
        $jarHtml = @"
    <div class="panel">
      <div class="panel-header">
        <div><div class="panel-title">Jar-Level Threats</div><div class="panel-sub">Mods with cheat-client signatures</div></div>
        <div class="badge badge-flagged">$($Threats.Count) FLAGGED</div>
      </div>
      <div class="panel-body">$rows</div>
    </div>
"@
    }

    # --- System-level findings panel ----------------------------------------
    $sysHtml = ""
    if ($actionableFindings.Count -gt 0) {
        $rows = ""
        foreach ($f in ($actionableFindings | Sort-Object Severity)) {
            $badgeClass = if ($f.Severity -eq "HIGH") { "badge-flagged" } else { "badge-medium" }
            $rows += @"
        <div class="term-row">
          <div class="term-head">
            <span class="term-name">$(HtmlEncode $f.Module)</span>
            <span class="badge $badgeClass">$($f.Severity)</span>
          </div>
          <div class="detail-line">$(HtmlEncode $f.Detail)</div>
        </div>
"@
        }
        $sysHtml = @"
    <div class="panel">
      <div class="panel-header">
        <div><div class="panel-title">System-Level Findings</div><div class="panel-sub">Not tied to a specific mod file</div></div>
        <div class="badge badge-flagged">$($actionableFindings.Count) FINDING(S)</div>
      </div>
      <div class="panel-body">$rows</div>
    </div>
"@
    }

    # --- Informational panel -------------------------------------------------
    $infoHtml = ""
    if ($infoFindings.Count -gt 0) {
        $rows = ""
        foreach ($f in $infoFindings) {
            $rows += "<div class='term-row'><div class='detail-line'><b>$(HtmlEncode $f.Module):</b> $(HtmlEncode $f.Detail)</div></div>"
        }
        $infoHtml = @"
    <div class="panel">
      <div class="panel-header">
        <div><div class="panel-title">Informational Notes</div><div class="panel-sub">Do not affect the verdict</div></div>
        <div class="badge badge-info">$($infoFindings.Count) NOTE(S)</div>
      </div>
      <div class="panel-body">$rows</div>
    </div>
"@
    }

    # --- Live memory scan panel(s) ------------------------------------------
    $memoryHtml = ""
    if ($MemoryResultsByPid.Keys.Count -gt 0) {
        foreach ($pidKey in $MemoryResultsByPid.Keys) {
            $data = $MemoryResultsByPid[$pidKey]
            $results = $data.Results

            if ($results.Count -eq 0) {
                $memoryHtml += @"
    <div class="panel">
      <div class="panel-header">
        <div><div class="panel-title">Memory Scan &middot; PID $pidKey</div><div class="panel-sub">Started $($data.StartTime) &middot; scanned in $($data.ElapsedSeconds)s</div></div>
        <div class="badge badge-clean">CLEAN</div>
      </div>
    </div>
"@
                continue
            }

            $grouped = $results | Group-Object { ($_ -split " :: ")[0] } | Sort-Object Count -Descending
            $rowsHtml = ""
            foreach ($group in $grouped) {
                $termEsc = HtmlEncode $group.Name
                $examplesHtml = ""
                $group.Group | Select-Object -First 5 | ForEach-Object {
                    $line = ($_ -split " :: ", 2)[1]
                    if ($line.Length -gt 160) { $line = $line.Substring(0, 160) + "..." }
                    $examplesHtml += "<div class='example'>$(HtmlEncode $line)</div>"
                }
                $rowsHtml += @"
        <div class="term-row">
          <div class="term-head">
            <span class="term-name">$termEsc</span>
            <span class="term-count">$($group.Count) hit(s)</span>
          </div>
          <div class="examples">$examplesHtml</div>
        </div>
"@
            }

            $memoryHtml += @"
    <div class="panel">
      <div class="panel-header">
        <div><div class="panel-title">Memory Scan &middot; PID $pidKey</div><div class="panel-sub">Started $($data.StartTime) &middot; scanned in $($data.ElapsedSeconds)s</div></div>
        <div class="badge badge-flagged">FLAGGED &middot; $($results.Count)</div>
      </div>
      <div class="panel-body">$rowsHtml</div>
    </div>
"@
        }
    }

    $creditsLine = ($script:Config.Credits | ForEach-Object { "$($_.Role): $(HtmlEncode $_.Name)" }) -join " &middot; "

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Vamp Cheat Scanner Report</title>
<style>
  :root {
    --bg: #0b0e14;
    --panel: #131722;
    --panel-border: #232838;
    --text: #e6e9f0;
    --text-dim: #8b93a7;
    --accent: #5b8cff;
    --red: #ff5470;
    --red-dim: #3a1520;
    --green: #3ddc97;
    --green-dim: #10291f;
    --yellow: #ffcc66;
    --yellow-dim: #332a10;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    padding: 40px 24px;
    background: radial-gradient(circle at top, #10141f 0%, #0b0e14 60%);
    color: var(--text);
    font-family: 'Segoe UI', Roboto, -apple-system, sans-serif;
  }
  .container { max-width: 900px; margin: 0 auto; }
  .header { display: flex; justify-content: space-between; align-items: flex-end; margin-bottom: 28px; }
  .header h1 { font-size: 22px; font-weight: 600; margin: 0 0 4px 0; letter-spacing: -0.02em; }
  .header .meta { color: var(--text-dim); font-size: 13px; }

  .verdict { border-radius: 14px; padding: 26px 28px; margin-bottom: 28px; display: flex; align-items: center; gap: 20px; border: 1px solid var(--panel-border); }
  .verdict.clean { background: linear-gradient(135deg, var(--green-dim), #0b0e14); }
  .verdict.flagged { background: linear-gradient(135deg, var(--red-dim), #0b0e14); }
  .verdict-icon { width: 52px; height: 52px; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-size: 20px; font-weight: 700; flex-shrink: 0; }
  .clean .verdict-icon { background: var(--green); color: #06251a; }
  .flagged .verdict-icon { background: var(--red); color: #2c0812; }
  .verdict-title { font-size: 20px; font-weight: 700; letter-spacing: 0.03em; }
  .clean .verdict-title { color: var(--green); }
  .flagged .verdict-title { color: var(--red); }
  .verdict-sub { color: var(--text-dim); font-size: 14px; margin-top: 4px; }

  .stats { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-bottom: 28px; }
  .stat { background: var(--panel); border: 1px solid var(--panel-border); border-radius: 10px; padding: 16px 18px; }
  .stat .value { font-size: 22px; font-weight: 700; }
  .stat .label { color: var(--text-dim); font-size: 11px; margin-top: 2px; text-transform: uppercase; letter-spacing: 0.05em; }

  .panel { background: var(--panel); border: 1px solid var(--panel-border); border-radius: 12px; margin-bottom: 16px; overflow: hidden; }
  .panel-header { display: flex; justify-content: space-between; align-items: center; padding: 16px 20px; }
  .panel-title { font-weight: 600; font-size: 15px; }
  .panel-sub { color: var(--text-dim); font-size: 12px; margin-top: 2px; }
  .badge { padding: 5px 12px; border-radius: 20px; font-size: 11px; font-weight: 700; letter-spacing: 0.03em; white-space: nowrap; }
  .badge-clean { background: var(--green-dim); color: var(--green); border: 1px solid var(--green); }
  .badge-flagged { background: var(--red-dim); color: var(--red); border: 1px solid var(--red); }
  .badge-medium { background: var(--yellow-dim); color: var(--yellow); border: 1px solid var(--yellow); }
  .badge-info { background: #1a2233; color: var(--text-dim); border: 1px solid var(--panel-border); }

  .panel-body { border-top: 1px solid var(--panel-border); padding: 8px 20px 16px; }
  .term-row { padding: 12px 0; border-bottom: 1px solid var(--panel-border); }
  .term-row:last-child { border-bottom: none; }
  .term-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; gap: 12px; }
  .term-name { font-weight: 700; color: var(--red); font-size: 14px; }
  .term-count { color: var(--text-dim); font-size: 12px; white-space: nowrap; }
  .detail-line { color: var(--text-dim); font-size: 13px; margin-top: 4px; line-height: 1.5; }
  .detail-line b { color: var(--text); }
  .detail-line.mono { font-family: 'Cascadia Code', Consolas, monospace; font-size: 12px; }
  .examples { display: flex; flex-direction: column; gap: 4px; }
  .example {
    font-family: 'Cascadia Code', Consolas, monospace; font-size: 12px; color: var(--text-dim);
    background: #0b0e14; border: 1px solid var(--panel-border); border-radius: 6px;
    padding: 6px 10px; overflow-x: auto; white-space: pre;
  }

  .mod-row { display: flex; justify-content: space-between; gap: 12px; padding: 8px 0; border-bottom: 1px solid var(--panel-border); font-size: 13px; }
  .mod-row:last-child { border-bottom: none; }
  .mod-name { font-weight: 600; color: var(--green); flex: 1; }
  .mod-file { color: var(--text-dim); flex: 1; text-align: left; }
  .mod-size { color: var(--text-dim); white-space: nowrap; }

  .footer { text-align: center; color: var(--text-dim); font-size: 12px; margin-top: 32px; }
  .footer .credits { margin-top: 6px; color: #6f7690; }
</style>
</head>
<body>
  <div class="container">
    <div class="header">
      <div>
        <h1>Vamp Cheat Scanner Report</h1>
        <div class="meta">Version $($script:Config.Version) &middot; jar verification + system checks + live memory scan</div>
      </div>
      <div class="meta">$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</div>
    </div>

    <div class="verdict $verdictClass">
      <div class="verdict-icon">$(if ($anyFlagged) { "!" } else { "OK" })</div>
      <div>
        <div class="verdict-title">$verdictText</div>
        <div class="verdict-sub">$verdictSub</div>
      </div>
    </div>

    <div class="stats">
      <div class="stat"><div class="value">$($Verified.Count)</div><div class="label">Verified Mods</div></div>
      <div class="stat"><div class="value">$($Threats.Count)</div><div class="label">Flagged Mods</div></div>
      <div class="stat"><div class="value">$totalHigh / $totalMedium</div><div class="label">High / Medium Findings</div></div>
      <div class="stat"><div class="value">$totalMemoryHits</div><div class="label">Memory String Hits</div></div>
    </div>

    $jarHtml
    $sysHtml
    $memoryHtml
    $verifiedHtml
    $infoHtml

    <div class="footer">
      Generated locally &middot; no data leaves this machine (aside from optional Modrinth hash lookups)
      <div class="credits">$creditsLine</div>
    </div>
  </div>
</body>
</html>
"@

    return $html
}

function Main {
    Write-Banner

    $path = Resolve-ModsPath -ExplicitPath $ModsPath
    Write-Host ""

    Ensure-Administrator

    Invoke-SystemCheckerPhase
    $p1 = Invoke-JarParserPhase -Path $path
    $verifiedMods = @($p1.Verified)
    $unknownMods  = @($p1.Unknown)
    $threats = @(Invoke-DeepThreatScanPhase -UnknownMods $unknownMods)
    Invoke-HiddenModFilesPhase -ModsPath $path
    Invoke-CheatFolderScanPhase
    Invoke-BamParserPhase
    Invoke-ServiceProcessPhase
    Invoke-FilelessBypassPhase
    Invoke-MacroToolScanPhase
    $memoryResults = Invoke-MemoryStringScanPhase
    Invoke-CommandHistoryPhase

    if ($ExportReport) {
        Export-JsonReport -Verified $verifiedMods -Unknown $unknownMods -Threats $threats -MemoryResults $memoryResults
    }

    Write-Host ""
    Write-PhaseHeader -Text "GENERATING HTML REPORT" -Color White

    $html = Build-HtmlReport -Verified $verifiedMods -Unknown $unknownMods -Threats $threats -MemoryResultsByPid $memoryResults
    $reportPath = Join-Path $env:USERPROFILE "Desktop\VampCheatScanner-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
    $html | Out-File -FilePath $reportPath -Encoding UTF8

    Write-Host "   [OK] HTML report saved to: $reportPath" -ForegroundColor Green
    Write-Host ("   Elapsed time: {0:N1}s" -f ((Get-Date) - $script:StartTime).TotalSeconds) -ForegroundColor Gray
    Write-Host ""
    Write-Host "   Opening report in your default browser..." -ForegroundColor Cyan
    Start-Process $reportPath

    Write-Host ""
    Write-Host "   Scan completed. Please review the HTML report and take appropriate action." -ForegroundColor Cyan
    Write-Host "   Thank you for using Vamp Cheat Scanner. Stay safe and don't cheat!" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   Press any key to exit this scan..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

Main