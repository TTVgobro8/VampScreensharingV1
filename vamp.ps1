# Define configuration at the very top
$script:Config = @{
    AppName        = "Vamp Cheat Scanner"
    Version        = "3.1.0"
    DefaultModsPath = "$env:APPDATA\.minecraft\mods"
    TempDirName    = "vamp_cheatscanner_tmp"
    TotalPhases    = 7
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

# All your functions go here...

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

# All your variable declarations...

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

# ... (rest of your functions)

# Now, define the Main function with CmdletBinding
function Main {
    [CmdletBinding()]  # Added attribute
    param()

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

    Write-CreditsFooter

    Write-Host "   Scan Completed. Please review the verdict above and take appropriate action." -ForegroundColor Cyan
    Write-Host "   Thank you for using Vamp Cheat Scanner. Stay safe and don't cheat!" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "   Press any key to exit this scan..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# Call Main with CmdletBinding
Main
