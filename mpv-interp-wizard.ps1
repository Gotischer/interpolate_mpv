# =============================================================================
#  mpv-interp-wizard.ps1
#
#  Wizard interactivo para instalar/actualizar/reparar interpolacion de frames
#  en mpv usando VapourSynth + RIFE (TensorRT) o MVTools (fallback CPU).
#
#  Caracteristicas:
#    - Detecta GPU automaticamente y elige el backend optimo:
#        * RTX 30/40/50  -> RIFE con TensorRT (mejor calidad)
#        * GTX 10 / RTX 20 -> RIFE con TensorRT (modo conservador)
#        * AMD / Intel / sin GPU -> MVTools (CPU, calidad estilo SVP basico)
#    - Detecta driver NVIDIA y compute capability
#    - Verifica el estado de la instalacion antes de cada accion
#    - TUI con flechas en PowerShell 7+, fallback a prompts numericos
#    - Menus: Instalar / Actualizar / Reparar / Diagnostico / Desinstalar
#
#  Uso:
#    powershell -ExecutionPolicy Bypass -File mpv-interp-wizard.ps1
# =============================================================================

# ======================== CONFIGURACION (persistida) ========================
# Las rutas se guardan en mpv-interp-wizard.config.json al lado del script.
# La primera vez el wizard te pregunta. Se pueden editar despues en el menu
# "Configuracion".
# =============================================================================

$ErrorActionPreference = "Stop"
$ProgressPreference    = "Continue"

# Versionado del wizard y de los templates generados
$Global:WizardVersion       = "1.0.7"
$Global:VpyTemplateVersion  = 2      # subir cuando cambies el template del .vpy
$Global:LuaTemplateVersion  = 2      # subir cuando cambies el template del auto_mode.lua
$Global:WizardRepo          = "Gotischer/interpolate_mpv"
$Global:VsMlrtRepo          = "AmusementClub/vs-mlrt"
$Global:VapourSynthRepo     = "vapoursynth/vapoursynth"

# Defaults (se usan solo si el JSON no existe y no hay auto-deteccion)
$Global:Config = @{
    BaseDir        = ""
    MpvConfigDir   = ""
    MpvExe         = ""
    LocalBundleDir = ""
    VsRelease           = "R73"
    VsReleasePrevious   = ""
    MlrtVersion         = "v15.16"
    MlrtVersionPrevious = ""
    # Perfil RIFE (escala y modelo). El wizard pone defaults segun backend.
    # Modelos validos: v4.25_heavy, v4.25, v4.22
    # Escala: 1.0 (full) o 0.5 (half - 4x mas rapido, util en GPUs lentas)
    RifeScale           = 1.0
    RifeModel           = "v4.25_heavy"
}

$Global:ConfigFile = if ($env:MPV_INTERP_HOME -and (Test-Path $env:MPV_INTERP_HOME)) {
    Join-Path $env:MPV_INTERP_HOME "mpv-interp-wizard.config.json"
} elseif ($PSScriptRoot) {
    Join-Path $PSScriptRoot "mpv-interp-wizard.config.json"
} else {
    Join-Path (Get-Location) "mpv-interp-wizard.config.json"
}

# Log a archivo (al lado del config) para diagnostico
try {
    $logDir = Split-Path $Global:ConfigFile -Parent
    if (Test-Path $logDir) {
        $logFile = Join-Path $logDir "mpv-interp-wizard.log"
        Start-Transcript -Path $logFile -Append -ErrorAction SilentlyContinue | Out-Null
    }
} catch {}

function Load-Config {
    if (Test-Path $Global:ConfigFile) {
        try {
            $j = Get-Content $Global:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($j.PSObject.Properties.Name)) {
                if ($Global:Config.ContainsKey($k)) { $Global:Config[$k] = $j.$k }
            }
            return $true
        } catch {
            Warn "config corrupto, se recreara"
        }
    }
    return $false
}

function Get-UpdateCacheFile {
    $dir = Split-Path $Global:ConfigFile -Parent
    return (Join-Path $dir "mpv-interp-wizard.update-cache.json")
}

function Get-LatestGithubRelease {
    param([string]$Repo)
    $cacheFile = Get-UpdateCacheFile
    $cache = if (Test-Path $cacheFile) { Get-Content $cacheFile | ConvertFrom-Json -EA SilentlyContinue } else { @{} }
    
    # Validamos que el cache tenga Assets, si no lo forzamos (para migrar de versiones viejas del wizard)
    if ($cache.PSObject.Properties[$Repo] -and 
        $cache.$Repo.Timestamp -gt (Get-Date).AddHours(-24).Ticks -and
        $cache.$Repo.Assets) {
        return $cache.$Repo
    }

    try {
        $apiUrl = "https://api.github.com/repos/$Repo/releases/latest"
        $headers = @{ "Accept" = "application/vnd.github.v3+json"; "User-Agent" = "mpv-interp-wizard" }
        $json = Invoke-RestMethod -Uri $apiUrl -Headers $headers
        if ($json) {
            $res = [PSCustomObject]@{
                Tag       = $json.tag_name
                Url       = $json.html_url
                Timestamp = (Get-Date).Ticks
                Assets    = $json.assets | ForEach-Object { [PSCustomObject]@{ Name = $_.name; Url = $_.browser_download_url } }
            }
            if ($cache -is [System.Collections.Hashtable]) {
                $cache.$Repo = $res
            } else {
                $cache | Add-Member -MemberType NoteProperty -Name $Repo -Value $res -Force
            }
            $cache | ConvertTo-Json -Depth 10 | Set-Content $cacheFile -Encoding UTF8
            return $res
        }
    } catch {
        return $null
    }
}

function Compare-Versions {
    # Devuelve -1 si $A < $B, 0 si iguales, 1 si $A > $B. Tolera prefijos 'v' o 'R'.
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return 0 }
    $na = ($A -replace '^[vVrR]', '')
    $nb = ($B -replace '^[vVrR]', '')
    # Solo numerico (ej. R73 vs R74)
    if ($na -match '^\d+$' -and $nb -match '^\d+$') {
        $diff = [int]$na - [int]$nb
        if ($diff -lt 0) { return -1 }
        if ($diff -gt 0) { return 1 }
        return 0
    }
    try {
        $va = [version]($na -replace '[^0-9.].*$','')
        $vb = [version]($nb -replace '[^0-9.].*$','')
        return $va.CompareTo($vb)
    } catch { return [string]::Compare($na, $nb) }
}

function Set-MlrtVersion {
    param([string]$NewVersion)
    if (-not $NewVersion) { return }
    $Global:Config.MlrtVersionPrevious = $Global:Config.MlrtVersion
    $Global:Config.MlrtVersion         = $NewVersion
    Save-Config | Out-Null
    Info "Pin de vs-mlrt: $($Global:Config.MlrtVersionPrevious) -> $NewVersion (rollback disponible)"
}

function Set-VsRelease {
    param([string]$NewVersion)
    if (-not $NewVersion) { return }
    $Global:Config.VsReleasePrevious = $Global:Config.VsRelease
    $Global:Config.VsRelease         = $NewVersion
    Save-Config | Out-Null
    Info "Pin de VapourSynth: $($Global:Config.VsReleasePrevious) -> $NewVersion"
}

function Save-Config {
    try {
        $Global:Config | ConvertTo-Json -Depth 10 | Set-Content $Global:ConfigFile -Encoding UTF8
        return $true
    } catch {
        Bad "No se pudo guardar la configuracion"
        return $false
    }
}

function Test-MpvVapourSynth {
    param([string]$MpvExe)
    if (-not $MpvExe -or -not (Test-Path $MpvExe)) { return $false }
    
    $exeDir = Split-Path $MpvExe -Parent
    $com = Join-Path $exeDir "mpv.com"
    $target = if (Test-Path $com) { $com } else { $MpvExe }
    
    try {
        # Usamos System.Diagnostics.Process para capturar salida de apps GUI/WinMain
        # ya que el operador '&' en PS a veces falla capturando stdout de WinMain exes.
        $si = New-Object System.Diagnostics.ProcessStartInfo
        $si.FileName = $target
        $si.Arguments = "--version"
        $si.RedirectStandardOutput = $true
        $si.RedirectStandardError  = $true
        $si.UseShellExecute        = $false
        $si.CreateNoWindow         = $true
        
        $p = [System.Diagnostics.Process]::Start($si)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit(3000)
        
        $fullOut = $out + $err
        if ($fullOut -match "vapoursynth") { return $true }
        
        # Fallback: buscar la DLL directamente (comun en builds de shinchiro)
        if (Test-Path (Join-Path $exeDir "vapoursynth.dll")) { return $true }
        
        return $false
    } catch {
        return $false
    }
}

function Auto-Detect-Mpv {
    # 1) PATH
    $w = Get-Command mpv.exe -EA SilentlyContinue
    if ($w) { return $w.Source }

    # 2) App Paths (registro) - algunos instaladores la registran ahi
    foreach ($hive in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\mpv.exe",
                        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\mpv.exe")) {
        try {
            $v = (Get-ItemProperty -Path $hive -EA SilentlyContinue).'(default)'
            if ($v -and (Test-Path $v)) { return $v }
        } catch {}
    }

    # 3) Ubicaciones tipicas universales (sin asumir letras de disco arbitrarias)
    $candidates = @(
        "$env:LOCALAPPDATA\mpv\mpv.exe",
        "$env:LOCALAPPDATA\Programs\mpv\mpv.exe",
        "$env:ProgramFiles\mpv\mpv.exe",
        "${env:ProgramFiles(x86)}\mpv\mpv.exe",
        "C:\mpv\mpv.exe",
        # Scoop
        "$env:USERPROFILE\scoop\apps\mpv\current\mpv.exe",
        "$env:USERPROFILE\scoop\shims\mpv.exe",
        # Chocolatey
        "C:\ProgramData\chocolatey\bin\mpv.exe",
        "C:\ProgramData\chocolatey\lib\mpv\tools\mpv.exe"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return $null
}

function Auto-Detect-BaseDir {
    param([string]$MpvExePath)
    # Devuelve la carpeta padre de un vapoursynth-portable\VSPipe.exe existente.
    $roots = New-Object System.Collections.Generic.List[string]
    if ($MpvExePath) {
        $mpvParent  = Split-Path $MpvExePath -Parent       # ej. H:\mpv
        $grand      = Split-Path $mpvParent  -Parent       # ej. H:\
        if ($mpvParent) { $roots.Add($mpvParent) }
        if ($grand)     { $roots.Add($grand) }
    }
    # Raices de discos comunes
    foreach ($d in @("C:\","D:\","E:\","F:\","G:\","H:\")) {
        if (Test-Path $d) { $roots.Add($d) }
    }
    $roots.Add("$env:LOCALAPPDATA")

    # Nombres tipicos de la carpeta base
    $folderNames = @("mpv-interp", "mpv-interpolation", "vapoursynth", "vs")

    foreach ($r in $roots | Select-Object -Unique) {
        foreach ($n in $folderNames) {
            $candidate = Join-Path $r $n
            $vspipe = Join-Path $candidate "vapoursynth-portable\VSPipe.exe"
            if (Test-Path $vspipe) { return $candidate }
        }
    }
    return $null
}

function Auto-Detect-PortableConfig {
    param([string]$MpvExePath)
    if (-not $MpvExePath) { return $null }
    $dir = Split-Path $MpvExePath -Parent
    
    # Prioridad: portable_config al lado del exe
    $portable = Join-Path $dir "portable_config"
    if (Test-Path $portable) { return $portable }
    
    # Si no existe, pero estamos en una ruta que parece de "Software" o "Portables",
    # sugerimos crearla alli en vez de ir a AppData.
    if ($dir -match "Software|Portable|Desktop|Downloads|Games") {
        return $portable # Devolvemos la ruta aunque no exista para que First-Time-Setup la proponga
    }

    $candidates = @(
        (Join-Path $dir "config"),
        "$env:APPDATA\mpv"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return "$env:APPDATA\mpv"
}

function Prompt-Path {
    param([string]$Label, [string]$Default, [bool]$MustExist = $false, [bool]$AllowEmpty = $false)
    while ($true) {
        $shown = if ($Default) { " [$Default]" } else { "" }
        $r = Read-Host "  $Label$shown"
        if ([string]::IsNullOrWhiteSpace($r)) { $r = $Default }
        if ([string]::IsNullOrWhiteSpace($r)) {
            if ($AllowEmpty) { return "" }
            Warn "Ruta requerida"; continue
        }
        if ($MustExist -and -not (Test-Path $r)) {
            $c = Read-Host "  '$r' no existe. Usar de todas formas? (s/n)"
            if ($c -ne "s" -and $c -ne "S") { continue }
        }
        return $r
    }
}

function Show-Welcome {
    Clear-Host
    Title "MPV Interpolation Wizard - Bienvenido"
    Write-Host ""
    Write-Host "  Este asistente instala interpolacion de frames en mpv." -ForegroundColor White
    Write-Host "  Convierte video de 24/30 fps a la frecuencia de tu monitor" -ForegroundColor White
    Write-Host "  (60/120/144 Hz) para movimiento fluido." -ForegroundColor White
    Write-Host ""
    Write-Host "  Que va a pasar:" -ForegroundColor Cyan
    Write-Host "    1. Detecta tu GPU y elige el mejor backend" -ForegroundColor Gray
    Write-Host "       - NVIDIA RTX 20/30/40/50  -> RIFE con TensorRT (calidad alta)" -ForegroundColor DarkGray
    Write-Host "       - AMD / Intel / GTX viejas -> MVTools (CPU, calidad basica)" -ForegroundColor DarkGray
    Write-Host "    2. Te pregunta donde instalar (puedes elegir cualquier carpeta)" -ForegroundColor Gray
    Write-Host "    3. Descarga e instala VapourSynth + vs-mlrt + modelos" -ForegroundColor Gray
    Write-Host "    4. Configura mpv para usarlo automaticamente" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Requisitos:" -ForegroundColor Cyan
    Write-Host "    - Windows 10 o superior" -ForegroundColor Gray
    Write-Host "    - mpv ya instalado (en cualquier carpeta)" -ForegroundColor Gray
    Write-Host "    - ~7 GB libres en disco" -ForegroundColor Gray
    Write-Host "    - Driver NVIDIA reciente (solo si quieres RIFE)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Puedes cancelar con Q o Esc en cualquier menu." -ForegroundColor DarkGray
    Write-Host ""
    $r = Read-Host "  Presiona Enter para continuar, Q para salir"
    if ($r -eq "q" -or $r -eq "Q") { exit 0 }
}

function First-Time-Setup {
    Clear-Host
    Title "CONFIGURACION INICIAL"
    Write-Host "  Es la primera vez que corres este wizard." -ForegroundColor White
    Write-Host "  Configura las rutas (puedes cambiarlas despues)." -ForegroundColor White
    Write-Host ""

    # Auto-detectar mpv
    $detectedMpv = Auto-Detect-Mpv
    if ($detectedMpv) {
        Info "mpv detectado en: $detectedMpv"
    } else {
        Info "mpv no detectado automaticamente"
    }
    $Global:Config.MpvExe = Prompt-Path -Label "Ruta a mpv.exe" -Default $detectedMpv -MustExist $true

    # Auto-detectar portable_config
    $detectedConfig = Auto-Detect-PortableConfig -MpvExePath $Global:Config.MpvExe
    if ($detectedConfig) {
        Info "portable_config detectado: $detectedConfig"
    }
    $Global:Config.MpvConfigDir = Prompt-Path -Label "Carpeta portable_config de mpv" -Default $detectedConfig -MustExist $false

    # BaseDir: primero buscar instalacion real de VapourSynth, sino proponer ruta
    Write-Host ""
    $detectedBase = Auto-Detect-BaseDir -MpvExePath $Global:Config.MpvExe
    if ($detectedBase) {
        Info "VapourSynth detectado en: $detectedBase\vapoursynth-portable"
        $defaultBase = $detectedBase
    } else {
        $mpvParent = Split-Path $Global:Config.MpvExe -Parent
        $defaultBase = Split-Path $mpvParent -Parent
        if ($defaultBase) { $defaultBase = Join-Path $defaultBase "mpv-interp" }
        else { $defaultBase = "C:\mpv-interp" }
        Info "BaseDir es donde se instalara VapourSynth + vs-mlrt (~5-7 GB)"
    }
    $Global:Config.BaseDir = Prompt-Path -Label "Carpeta de instalacion (BaseDir)" -Default $defaultBase -MustExist $false

    # LocalBundleDir: opcional
    Write-Host ""
    Info "Si ya tienes los .7z de vs-mlrt descargados, indica la carpeta"
    Info "(El wizard los reutilizara en vez de descargarlos de nuevo)"
    $Global:Config.LocalBundleDir = Prompt-Path -Label "Carpeta con .7z (opcional, vacio para omitir)" -Default "" -AllowEmpty $true

    if (Save-Config) {
        Ok "Configuracion guardada en $($Global:ConfigFile)"
    }
    Pause-Continue
}

# --- Colores -----------------------------------------------------------------
function Title($t)   { Write-Host "`n  $t`n" -ForegroundColor White -BackgroundColor DarkBlue }
function Section($t) { Write-Host "`n===> $t" -ForegroundColor Cyan }
function Info($t)    { Write-Host "     $t" -ForegroundColor Gray }
function Ok($t)      { Write-Host "[OK] $t" -ForegroundColor Green }
function Warn($t)    { Write-Host "[!!] $t" -ForegroundColor Yellow }
function Bad($t)     { Write-Host "[XX] $t" -ForegroundColor Red }
function Hint($t)    { Write-Host "     $t" -ForegroundColor DarkGray }

# =============================================================================
# DETECCION DEL ENTORNO
# =============================================================================
$Global:Env = @{
    GPU              = $null    # Nombre de la GPU
    GPUVendor        = $null    # NVIDIA / AMD / Intel / Unknown
    GPUGen           = $null    # Blackwell / Ada / Ampere / Turing / Pascal / Older
    ComputeCap       = $null    # 12.0 / 8.9 / etc
    SupportedBackend = $null    # RIFE_TRT_RTX / RIFE_TRT / RIFE_NCNN / MVTOOLS
    DriverVersion    = $null
    HasTUI           = $false
}

function Detect-GPU {
    Section "Detectando GPU"
    try {
        $gpus = Get-CimInstance Win32_VideoController -EA SilentlyContinue |
                Where-Object { $_.Name -notlike "*Basic*" -and $_.Name -notlike "*Microsoft*" }
        if (-not $gpus) {
            $Global:Env.GPU       = "Desconocida"
            $Global:Env.GPUVendor = "Unknown"
            $Global:Env.SupportedBackend = "MVTOOLS"
            return
        }
        $primary = $gpus | Where-Object { $_.Name -like "*NVIDIA*" } | Select-Object -First 1
        if (-not $primary) {
            $primary = $gpus | Where-Object { $_.Name -like "*AMD*" -or $_.Name -like "*Radeon*" } | Select-Object -First 1
        }
        if (-not $primary) { $primary = $gpus | Select-Object -First 1 }

        $Global:Env.GPU = $primary.Name
        $name = $primary.Name.ToLower()

        if ($name -match "nvidia|geforce|rtx|gtx") {
            $Global:Env.GPUVendor = "NVIDIA"
            # Detectar generacion por nombre del modelo
            if ($name -match "rtx\s*50[0-9]{2}|rtx\s*pro\s*6") {
                $Global:Env.GPUGen           = "Blackwell"
                $Global:Env.ComputeCap       = "12.0"
                $Global:Env.SupportedBackend = "RIFE_TRT_RTX"
            } elseif ($name -match "rtx\s*40[0-9]{2}") {
                $Global:Env.GPUGen           = "Ada Lovelace"
                $Global:Env.ComputeCap       = "8.9"
                $Global:Env.SupportedBackend = "RIFE_TRT"
            } elseif ($name -match "rtx\s*30[0-9]{2}") {
                $Global:Env.GPUGen           = "Ampere"
                $Global:Env.ComputeCap       = "8.6"
                $Global:Env.SupportedBackend = "RIFE_TRT"
            } elseif ($name -match "rtx\s*20[0-9]{2}|gtx\s*16[0-9]{2}|titan\s*rtx") {
                $Global:Env.GPUGen           = "Turing"
                $Global:Env.ComputeCap       = "7.5"
                $Global:Env.SupportedBackend = "RIFE_TRT"
            } elseif ($name -match "gtx\s*10[0-9]{2}|titan\s*xp|titan\s*x") {
                $Global:Env.GPUGen           = "Pascal"
                $Global:Env.ComputeCap       = "6.1"
                # Pascal soporta Vulkan -> RIFE via NCNN (TRT necesita compute >= 7.5)
                $Global:Env.SupportedBackend = "RIFE_NCNN"
            } else {
                $Global:Env.GPUGen           = "NVIDIA antigua"
                # Maxwell/Kepler tambien soportan Vulkan en general
                $Global:Env.SupportedBackend = "RIFE_NCNN"
            }
            # Driver NVIDIA
            $Global:Env.DriverVersion = $primary.DriverVersion
        } elseif ($name -match "amd|radeon|rx ") {
            $Global:Env.GPUVendor = "AMD"
            # AMD discreta soporta Vulkan -> RIFE via NCNN
            $Global:Env.SupportedBackend = "RIFE_NCNN"
        } elseif ($name -match "intel.*arc|arc\s+[ab]") {
            $Global:Env.GPUVendor = "Intel"
            $Global:Env.GPUGen    = "Arc"
            # Intel Arc tiene Vulkan robusto
            $Global:Env.SupportedBackend = "RIFE_NCNN"
        } elseif ($name -match "intel|iris|uhd|hd graphics") {
            $Global:Env.GPUVendor = "Intel"
            # iGPU Intel: Vulkan funciona en Iris Xe pero rinde mal en HD Graphics
            # viejas. Lo seguro es MVTools, pero permitir RIFE_NCNN en Xe/Iris.
            if ($name -match "iris\s+xe|iris\s+plus") {
                $Global:Env.SupportedBackend = "RIFE_NCNN"
            } else {
                $Global:Env.SupportedBackend = "MVTOOLS"
            }
        } else {
            $Global:Env.GPUVendor = "Unknown"
            $Global:Env.SupportedBackend = "MVTOOLS"
        }
    } catch {
        Warn "Error detectando GPU: $_"
        $Global:Env.SupportedBackend = "MVTOOLS"
    }

    Info "GPU       : $($Global:Env.GPU)"
    if ($Global:Env.GPUGen)        { Info "Generacion: $($Global:Env.GPUGen)" }
    if ($Global:Env.ComputeCap)    { Info "Compute   : SM $($Global:Env.ComputeCap)" }
    if ($Global:Env.DriverVersion) { Info "Driver    : $($Global:Env.DriverVersion)" }
    Info "Backend recomendado: $($Global:Env.SupportedBackend)"
}

function Detect-TUI {
    # ConsoleKey con flechas funciona en cualquier PowerShell pero la presentacion
    # se ve mejor en PS 7+. Detectamos para mostrar visuales un poco distintos.
    $Global:Env.HasTUI = ($PSVersionTable.PSVersion.Major -ge 7) -and ($Host.UI.RawUI -ne $null)
}

function Detect-Installation {
    $state = [PSCustomObject]@{
        VSInstalled       = $false
        VSPath            = $null
        MlrtInstalled     = $false
        MlrtVersion       = $null
        VsmlrtPyPatched   = $false
        ModelsInstalled   = $false
        VpyInstalled      = $false
        VpyVersion        = $null
        VpyOutdated       = $false
        LuaInstalled      = $false
        LuaVersion        = $null
        LuaOutdated       = $false
        SetHzInstalled    = $false
        MpvSupportsVs     = $false
        OverallStatus     = "No instalado"
    }
    
    $state.MpvSupportsVs = Test-MpvVapourSynth -MpvExe $Global:Config.MpvExe

    $vsDir = Join-Path $Global:Config.BaseDir "vapoursynth-portable"
    if (Test-Path $vsDir) {
        $vspipe = Get-ChildItem $vsDir -Filter "VSPipe.exe" -Recurse -EA SilentlyContinue | Select-Object -First 1
        if ($vspipe) {
            $state.VSInstalled = $true
            $state.VSPath      = Split-Path $vspipe.FullName -Parent
            $pluginDir = Join-Path $state.VSPath "vs-plugins"
            $trtexec = Get-ChildItem $pluginDir -Filter "trtexec.exe" -Recurse -EA SilentlyContinue | Select-Object -First 1
            if ($trtexec) {
                $state.MlrtInstalled = $true
                $d = $trtexec.LastWriteTime
                $state.MlrtVersion = if ($d -gt [datetime]"2025-06-01") { "$($Global:Config.MlrtVersion) (correcto)" }
                                     else { "antigua ($($d.ToShortDateString())) - no soporta SM 12.0" }
            }
            $siteVsmlrt = Join-Path $state.VSPath "Lib\site-packages\vsmlrt.py"
            if (Test-Path $siteVsmlrt) {
                $c = Get-Content $siteVsmlrt -Raw -EA SilentlyContinue
                $state.VsmlrtPyPatched = $c -and $c.Contains('except AttributeError:') -and $c.Contains('**os.environ')
            }
            $modelsDir = Join-Path $pluginDir "models"
            if (Test-Path $modelsDir) {
                # vsmlrt 15+ usa subcarpetas: models/rife/*.onnx, models/cugan/*.onnx, etc.
                # Buscamos recursivo para soportar ambas estructuras (vieja flat y nueva con subcarpetas).
                $onnx = Get-ChildItem $modelsDir -Filter "*.onnx" -Recurse -EA SilentlyContinue
                $state.ModelsInstalled = $onnx.Count -gt 0
            }
        }
    }
    $vpyPath = Join-Path $Global:Config.MpvConfigDir "interpolation.vpy"
    $state.VpyInstalled = Test-Path $vpyPath
    if ($state.VpyInstalled) {
        try {
            $firstLines = Get-Content $vpyPath -TotalCount 3 -EA SilentlyContinue
            $m = $firstLines | Select-String -Pattern 'vpy-template-version:\s*(\d+)' | Select-Object -First 1
            if ($m) {
                $state.VpyVersion = [int]$m.Matches[0].Groups[1].Value
                $state.VpyOutdated = ($state.VpyVersion -lt $Global:VpyTemplateVersion)
            } else {
                $state.VpyVersion = 0
                $state.VpyOutdated = $true   # .vpy viejo sin marca de version
            }
        } catch {}
    }
    $luaPath = Join-Path $Global:Config.MpvConfigDir "scripts\auto_mode.lua"
    $state.LuaInstalled = Test-Path $luaPath
    if ($state.LuaInstalled) {
        try {
            $firstLines = Get-Content $luaPath -TotalCount 3 -EA SilentlyContinue
            $m = $firstLines | Select-String -Pattern 'lua-template-version:\s*(\d+)' | Select-Object -First 1
            if ($m) {
                $state.LuaVersion = [int]$m.Matches[0].Groups[1].Value
                $state.LuaOutdated = ($state.LuaVersion -lt $Global:LuaTemplateVersion)
            } else {
                $state.LuaVersion = 0
                $state.LuaOutdated = $true
            }
        } catch {}
    }
    $state.SetHzInstalled = Test-Path (Join-Path $Global:Config.MpvConfigDir "set_display_hz.ps1")

    $isRife = ($Global:Env.SupportedBackend -match "RIFE_TRT")
    if ($state.VSInstalled) {
        if ($isRife) {
            if ($state.MlrtInstalled -and $state.VsmlrtPyPatched -and $state.ModelsInstalled -and $state.VpyInstalled) {
                $state.OverallStatus = "Instalado y funcional (RIFE)"
            } else {
                $state.OverallStatus = "Instalacion incompleta o corrupta (faltan componentes RIFE)"
            }
        } else {
            # MVTools solo necesita VapourSynth y que el .vpy exista
            if ($state.VpyInstalled) {
                $state.OverallStatus = "Instalado y funcional (MVTools)"
            } else {
                $state.OverallStatus = "VapourSynth OK (Falta configurar interpolation.vpy)"
            }
        }
    }

    if (-not $state.MpvSupportsVs -and $Global:Config.MpvExe) {
        $state.OverallStatus = "ERROR: Tu mpv.exe no soporta VapourSynth"
    }
    
    return $state
}

# =============================================================================
# MENU (TUI con flechas o fallback numerico)
# =============================================================================
function Show-Menu {
    param([string]$Title, [string[]]$Options, [string]$Footer = "")
    # Probar flechas; si no funciona, fallback a numerico
    try {
        return Show-MenuArrows -Title $Title -Options $Options -Footer $Footer
    } catch {
        return Show-MenuNumeric -Title $Title -Options $Options -Footer $Footer
    }
}

function Show-MenuArrows {
    param([string]$Title, [string[]]$Options, [string]$Footer)
    $idx = 0
    $orig = $Host.UI.RawUI.CursorPosition
    while ($true) {
        $Host.UI.RawUI.CursorPosition = $orig
        Write-Host (" " * 80) -NoNewline; Write-Host ""
        Write-Host "  $Title" -ForegroundColor White -BackgroundColor DarkBlue
        Write-Host ""
        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($i -eq $idx) {
                Write-Host ("  > " + $Options[$i]) -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host ("    " + $Options[$i]) -ForegroundColor Gray
            }
        }
        if ($Footer) {
            Write-Host ""
            Write-Host "  $Footer" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "  Flechas para mover, Enter para elegir, Q/Esc para cancelar" -ForegroundColor DarkGray

        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        switch ($key.VirtualKeyCode) {
            38 { if ($idx -gt 0) { $idx-- } }                # Up
            40 { if ($idx -lt $Options.Count - 1) { $idx++ } } # Down
            13 { Clear-Host; return $idx }                    # Enter
            27 { Clear-Host; return -1 }                      # Escape
            81 { Clear-Host; return -1 }                      # Q
        }
    }
}

function Show-MenuNumeric {
    param([string]$Title, [string[]]$Options, [string]$Footer)
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host ""
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $Options[$i]) -ForegroundColor Gray
    }
    if ($Footer) { Write-Host ""; Write-Host "  $Footer" -ForegroundColor DarkGray }
    Write-Host ""
    while ($true) {
        $r = Read-Host "  Elegir (1-$($Options.Count), Q para cancelar)"
        if ($r -eq "q" -or $r -eq "Q") { return -1 }
        $n = 0
        if ([int]::TryParse($r, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) {
            return ($n - 1)
        }
        Warn "Opcion invalida"
    }
}

function Pause-Continue {
    Write-Host ""
    Write-Host "  Presiona Enter para volver al menu..." -ForegroundColor DarkGray
    [void](Read-Host)
}

# =============================================================================
# HELPERS DE INSTALACION
# =============================================================================
function Get-7zr {
    $z = [System.IO.Path]::GetFullPath((Join-Path $Global:Config.BaseDir "7zr.exe"))
    if (-not (Test-Path $z)) {
        if (-not (Test-Path $Global:Config.BaseDir)) { New-Item -ItemType Directory -Path $Global:Config.BaseDir | Out-Null }
        Info "Descargando 7zr.exe..."
        Invoke-WebRequest -Uri "https://www.7-zip.org/a/7zr.exe" -OutFile $z
    }
    Unblock-File $z -ErrorAction SilentlyContinue
    return $z
}

function Get-Aria2 {
    $dir = Join-Path $Global:Config.BaseDir "bin"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $exe = Join-Path $dir "aria2c.exe"
    if (Test-Path $exe) { return $exe }

    Info "Instalando motor de descarga rapida (aria2)..."
    $zip = Join-Path $dir "aria2.zip"
    $url = "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip"
    try {
        $oldPP = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $url -OutFile $zip -TimeoutSec 30
        $ProgressPreference = $oldPP
        Expand-Archive -Path $zip -DestinationPath $dir -Force
        $extracted = Get-ChildItem $dir -Filter "aria2c.exe" -Recurse | Select-Object -First 1
        if ($extracted) {
            Move-Item $extracted.FullName $exe -Force
            Remove-Item $zip -Force -EA SilentlyContinue
            Get-ChildItem $dir -Directory | Remove-Item -Recurse -Force -EA SilentlyContinue
            return $exe
        }
    } catch {
        Warn "No se pudo instalar aria2, se usara descarga normal: $_"
    }
    return $null
}

function Find-Or-Download {
    param([string]$FileName, [string]$Url, [long]$ExpectedSize = 0)
    if ($Global:Config.LocalBundleDir) {
        $loc = Join-Path $Global:Config.LocalBundleDir $FileName
        if (Test-Path $loc) {
            if ($ExpectedSize -eq 0 -or (Get-Item $loc).Length -eq $ExpectedSize) {
                Info "Usando copia local: $loc"
                return $loc
            }
        }
    }
    $dst = [System.IO.Path]::GetFullPath((Join-Path $Global:Config.BaseDir $FileName))
    if (Test-Path $dst) {
        if ($ExpectedSize -eq 0 -or (Get-Item $dst).Length -eq $ExpectedSize) {
            Info "Ya descargado: $FileName"
            return $dst
        }
        Remove-Item $dst -Force
    }

    $aria = Get-Aria2
    if ($aria) {
        Info "Descargando con aria2 (multi-conexion)..."
        $dir = Split-Path $dst -Parent
        $name = Split-Path $dst -Leaf
        & $aria -x 16 -s 16 -k 1M --allow-overwrite=true --auto-file-renaming=false --console-log-level=warn -d $dir -o $name $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path $dst)) { return $dst }
        Warn "Aria2 fallo, reintentando con metodo estandar..."
    }

    Info "Descargando $FileName (metodo estandar)..."
    try {
        Import-Module BitsTransfer -EA SilentlyContinue
        Start-BitsTransfer -Source $Url -Destination $dst -DisplayName "Descargando $FileName"
    } catch {
        Invoke-WebRequest -Uri $Url -OutFile $dst
    }
    return $dst
}

function Expand-7z {
    param([string]$Archive, [string]$DestDir)
    $ArchiveAbs = (Get-Item $Archive).FullName
    $DestDirAbs = [System.IO.Path]::GetFullPath($DestDir)
    if (-not (Test-Path $DestDirAbs)) { New-Item -ItemType Directory -Path $DestDirAbs | Out-Null }
    
    $z = Get-7zr
    if (-not (Test-Path $ArchiveAbs)) { throw "No se encontro el archivo para extraer: $ArchiveAbs" }
    
    & $z x -y "-o$DestDirAbs" "$ArchiveAbs" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Fallo al extraer $ArchiveAbs (Codigo $LASTEXITCODE)" }
}

function Get-MonitorRefreshRate {
    # Devuelve el refresh rate (Hz) del monitor primario, o 60 si no se puede detectar.
    try {
        $hz = (Get-CimInstance Win32_VideoController -EA SilentlyContinue |
               Where-Object { $_.CurrentRefreshRate -and $_.CurrentRefreshRate -gt 0 } |
               Select-Object -First 1).CurrentRefreshRate
        if ($hz -and $hz -gt 0) { return [int]$hz }
    } catch {}
    return 60
}

function Run-NcnnBenchmark {
    # Genera un .vpy de prueba con el perfil dado y mide cuantos fps puede generar.
    # Devuelve fps efectivos (frames de salida / segundo) o $null si falla.
    param(
        [double]$Scale,
        [string]$Model,
        [int]$FramesIn = 30   # se generan 2x en la salida (multi=2)
    )
    $vsRoot = $null
    $vspipe = $null
    $candidates = @(
        (Join-Path $Global:Config.BaseDir "vapoursynth-portable\VSPipe.exe")
    )
    foreach ($c in $candidates) { if (Test-Path $c) { $vspipe = $c; break } }
    if (-not $vspipe) {
        $vspipeCmd = Get-ChildItem (Join-Path $Global:Config.BaseDir "vapoursynth-portable") -Filter "VSPipe.exe" -Recurse -EA SilentlyContinue | Select-Object -First 1
        if ($vspipeCmd) { $vspipe = $vspipeCmd.FullName }
    }
    if (-not $vspipe) { Warn "No se encontro VSPipe.exe para benchmark"; return $null }

    $modelPy = "RIFEModel." + ($Model -replace '\.', '_')
    $tmpVpy  = Join-Path $env:TEMP "wizard-bench-$([guid]::NewGuid().Guid.Substring(0,8)).vpy"
    $vpy = @"
import math
import vapoursynth as vs
from vsmlrt import RIFE, RIFEModel, Backend
core = vs.core

clip = core.std.BlankClip(width=1920, height=1080, format=vs.YUV420P8,
                          length=$FramesIn, fpsnum=24, fpsden=1)
# Variacion para evitar atajos de optimizacion en frames identicos
clip = core.std.Levels(clip, gamma=0.9)

clip = core.resize.Bicubic(clip, format=vs.RGBH, matrix_in_s="709",
    range_in_s="limited", range_s="full", dither_type="error_diffusion")

pad_w = math.ceil(clip.width / 32) * 32 - clip.width
pad_h = math.ceil(clip.height / 32) * 32 - clip.height
if pad_w or pad_h:
    clip = core.std.AddBorders(clip, left=pad_w//2, right=pad_w-pad_w//2,
        top=pad_h//2, bottom=pad_h-pad_h//2)

backend = Backend.NCNN_VK(fp16=True, num_streams=1, device_id=0)
clip = RIFE(clip, model=$modelPy, backend=backend, multi=2,
            scale=$Scale, video_player=True)

clip = core.resize.Bicubic(clip, format=vs.YUV420P8, matrix_s="709")
clip.set_output()
"@
    Set-Content $tmpVpy $vpy -Encoding UTF8

    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        # NUL en Windows descarta la salida sin tocar disco
        & $vspipe --y4m $tmpVpy NUL 2>&1 | Out-Null
        $sw.Stop()
    } catch {
        Remove-Item $tmpVpy -EA SilentlyContinue
        return $null
    }
    Remove-Item $tmpVpy -EA SilentlyContinue

    if ($LASTEXITCODE -ne 0) { return $null }
    $framesOut = $FramesIn * 2
    if ($sw.Elapsed.TotalSeconds -le 0) { return $null }
    return [math]::Round($framesOut / $sw.Elapsed.TotalSeconds, 1)
}

function Patch-Vsmlrt {
    param([string]$Path)
    $c = Get-Content $Path -Raw -Encoding UTF8
    $orig = $c
    $patches = 0
    $cudaExpr = 'str(__import__("pathlib").Path(__file__).parent / "vsmlrt-cuda")'

    $repl = @(
        @{
            Old = '        trt_version = parse_trt_version(int(core.trt.Version()["tensorrt_version"]))'
            New = '        try:
            trt_version = parse_trt_version(int(core.trt.Version()["tensorrt_version"]))
        except AttributeError:
            trt_version = (10, 16, 0)'
        },
        @{
            Old = '    trt_version = parse_trt_version(int(core.trt_rtx.Version()["tensorrt_version"]))'
            New = '    try:
        trt_version = parse_trt_version(int(core.trt_rtx.Version()["tensorrt_version"]))
    except AttributeError:
        trt_version = (10, 16, 0)'
        },
        @{
            Old = '            env = {env_key: prev_env_value, "CUDA_MODULE_LOADING": "LAZY"}'
            New = "            _cuda_dir = $cudaExpr`n            env = {**os.environ, env_key: prev_env_value, `"CUDA_MODULE_LOADING`": `"LAZY`", `"PATH`": _cuda_dir + `";`" + os.environ.get(`"PATH`", `"`"`)}"
        },
        @{
            Old = '            env = {env_key: log_filename, "CUDA_MODULE_LOADING": "LAZY"}'
            New = "            _cuda_dir = $cudaExpr`n            env = {**os.environ, env_key: log_filename, `"CUDA_MODULE_LOADING`": `"LAZY`", `"PATH`": _cuda_dir + `";`" + os.environ.get(`"PATH`", `"`"`)}"
        },
        @{
            Old = '        env = {"CUDA_MODULE_LOADING": "LAZY"}'
            New = "        _cuda_dir = $cudaExpr`n        env = {**os.environ, `"CUDA_MODULE_LOADING`": `"LAZY`", `"PATH`": _cuda_dir + `";`" + os.environ.get(`"PATH`", `"`"`)}"
        }
    )

    foreach ($r in $repl) {
        if ($c.Contains($r.Old)) {
            $c = $c.Replace($r.Old, $r.New)
            $patches++
        }
    }

    if ($c -ne $orig) {
        Set-Content $Path $c -NoNewline -Encoding UTF8
    }
    return $patches
}

# =============================================================================
# PASOS DE INSTALACION (compartidos entre Install y Update)
# =============================================================================
function Install-VapourSynth {
    Section "VapourSynth $($Global:Config.VsRelease)"
    $base  = $Global:Config.BaseDir
    $vsDir = Join-Path $base "vapoursynth-portable"
    if (-not (Test-Path $vsDir)) { New-Item -ItemType Directory -Path $vsDir | Out-Null }
    $vspipe = Get-ChildItem $vsDir -Filter "VSPipe.exe" -Recurse -EA SilentlyContinue | Select-Object -First 1
    if ($vspipe) { Info "VapourSynth ya instalado"; return $vspipe.FullName }
    
    $vsTag = $Global:Config.VsRelease
    Info "Buscando instalador de VapourSynth $vsTag..."
    
    $rel = Get-LatestGithubRelease -Repo $Global:VapourSynthRepo
    # Si la version configurada no es la 'latest' del cache, re-consultamos por si acaso
    if (-not $rel -or $rel.Tag -ne $vsTag) {
        # Intentar obtener info de la release especifica si no es la ultima
        try {
            $apiUrl = "https://api.github.com/repos/$($Global:VapourSynthRepo)/releases/tags/$vsTag"
            $rel = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "mpv-interp-wizard" }
            $rel = [PSCustomObject]@{ Tag = $rel.tag_name; Assets = $rel.assets | ForEach-Object { [PSCustomObject]@{ Name = $_.name; Url = $_.browser_download_url } } }
        } catch { $rel = $null }
    }

    $asset = $null
    if ($rel -and $rel.Assets) {
        $asset = $rel.Assets | Where-Object { $_.Name -match "Install-Portable-VapourSynth-.*\.ps1$" } | Select-Object -First 1
    }

    if (-not $asset) {
        Warn "No se encontro el script .ps1 en los assets de VapourSynth $vsTag."
        if ($vsTag -ne "R75") {
            Info "Intentando usar R75 como respaldo..."
            $vsTag = "R75"
            $url = "https://github.com/vapoursynth/vapoursynth/releases/download/R75/Install-Portable-VapourSynth-R75.ps1"
        } else {
            throw "No se pudo encontrar un instalador portable valido para VapourSynth."
        }
    } else {
        $url = $asset.Url
    }
    $instPath = Find-Or-Download -FileName "Install-Portable-VapourSynth-$vsTag.ps1" -Url $url
    $inst = (Get-Item $instPath).FullName
    Unblock-File $inst -ErrorAction SilentlyContinue

    $vsDirAbs = Join-Path $base "vapoursynth-portable"
    Info "Ejecutando instalador de VapourSynth (1-3 min)..."
    Push-Location $base
    try {
        powershell -ExecutionPolicy Bypass -NoProfile -File $inst -Unattended -TargetFolder "$vsDirAbs" -PythonVersionMajor 3 -PythonVersionMinor 13 | Out-Host
    } catch {
        Warn "Reintentando modo interactivo..."
        powershell -ExecutionPolicy Bypass -NoProfile -File $inst | Out-Host
    } finally { Pop-Location }

    $vspipe = Get-ChildItem $vsDir -Filter "VSPipe.exe" -Recurse -EA SilentlyContinue | Select-Object -First 1
    if (-not $vspipe) { throw "VapourSynth no se instalo" }
    Ok "VapourSynth: $($vspipe.FullName)"
    return $vspipe.FullName
}

function Install-VsMlrt {
    param([string]$VsRoot)
    Section "vs-mlrt bundle ($($Global:Config.MlrtVersion))"
    $pluginDir = Join-Path $VsRoot "vs-plugins"
    if (-not (Test-Path $pluginDir)) { New-Item -ItemType Directory -Path $pluginDir | Out-Null }

    $trtexec = Join-Path $pluginDir "vsmlrt-cuda\trtexec.exe"
    if (Test-Path $trtexec) {
        $d = (Get-Item $trtexec).LastWriteTime
        if ($d -gt [datetime]"2025-06-01") {
            Info "Bundle ya correcto ($d)"; return
        }
        Warn "Bundle antiguo, reemplazando..."
    }

    $rel = Get-LatestGithubRelease -Repo $Global:VsMlrtRepo
    if (-not $rel -or $rel.Tag -ne $Global:Config.MlrtVersion -or -not $rel.Assets) {
        try {
            $apiUrl = "https://api.github.com/repos/$($Global:VsMlrtRepo)/releases/tags/$($Global:Config.MlrtVersion)"
            $json = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "mpv-interp-wizard" }
            $rel = [PSCustomObject]@{ Tag = $json.tag_name; Assets = $json.assets | ForEach-Object { [PSCustomObject]@{ Name = $_.name; Url = $_.browser_download_url } } }
        } catch { $rel = $null }
    }

    if (-not $rel) { throw "No se pudo obtener informacion de vs-mlrt $($Global:Config.MlrtVersion)" }

    # Busqueda super flexible para evitar fallos de regex en PS 5.1
    $assets = @($rel.Assets) | Where-Object { 
        if (-not $_ -or -not $_.Name) { return $false }
        $n = $_.Name.ToLower()
        ($n -like "*vsmlrt*cuda*7z*")
    } | Sort-Object Name
    
    if ($assets.Count -eq 0) { 
        # Si falla, intentamos una ultima vez borrando cache
        $cacheFile = Get-UpdateCacheFile
        if (Test-Path $cacheFile) { Remove-Item $cacheFile -Force }
        throw "No se encontraron archivos para vs-mlrt $($rel.Tag). Reintenta ahora que se limpio el cache." 
    }

    $mainArchive = $null
    foreach ($a in $assets) {
        $path = Find-Or-Download -FileName $a.Name -Url $a.Url
        if ($a.Name -match "\.001$") { $mainArchive = $path }
        elseif (-not $mainArchive -and $a.Name.EndsWith(".7z")) { $mainArchive = $path }
    }

    if (-not $mainArchive) { throw "No se encontro el archivo principal de vs-mlrt" }

    Info "Extrayendo bundle (2-4 min)..."
    Expand-7z -Archive $mainArchive -DestDir $pluginDir
    Ok "Bundle extraido"
}

function Setup-VsmlrtPy {
    param([string]$VsRoot)
    Section "vsmlrt.py + parches"
    $pluginDir = Join-Path $VsRoot "vs-plugins"
    $siteDir   = Join-Path $VsRoot "Lib\site-packages"
    if (-not (Test-Path $siteDir)) { New-Item -ItemType Directory -Path $siteDir -Force | Out-Null }

    $srcPy  = Join-Path $pluginDir "vsmlrt.py"
    $destPy = Join-Path $siteDir "vsmlrt.py"

    if (Test-Path $srcPy) {
        # Recien extraido del bundle: mover de vs-plugins/ a site-packages/
        Copy-Item $srcPy $destPy -Force
        Remove-Item $srcPy -Force -EA SilentlyContinue
        Ok "vsmlrt.py movido a $destPy"
    } elseif (Test-Path $destPy) {
        # Ya estaba migrado de una instalacion previa: nada que mover, solo re-parchar
        Info "vsmlrt.py ya estaba en site-packages, se re-aplican parches"
    } else {
        # Ni en vs-plugins ni en site-packages: no hay vs-mlrt instalado
        Warn "vsmlrt.py no encontrado ni en vs-plugins/ ni en Lib/site-packages/"
        Hint "Reinstala vs-mlrt: menu Actualizar -> Actualizar bundle vs-mlrt"
        return
    }

    $n = Patch-Vsmlrt -Path $destPy
    if ($n -gt 0) { Ok "$n parche(s) aplicados" } else { Info "Ya parchado" }
}

function Install-RifeModels {
    param([string]$VsRoot)
    Section "Modelos RIFE"
    # vsmlrt 15+ espera los modelos en models/rife/, no en models/ flat.
    $modelsDir = Join-Path $VsRoot "vs-plugins\models"
    $rifeDir   = Join-Path $modelsDir "rife"
    if (-not (Test-Path $rifeDir)) { New-Item -ItemType Directory -Path $rifeDir -Force | Out-Null }

    # Migrar modelos viejos si estaban flat (instalaciones previas a v1.2.1)
    $flatRife = Get-ChildItem $modelsDir -Filter "rife_*.onnx" -EA SilentlyContinue
    if ($flatRife.Count -gt 0) {
        Info "Migrando $($flatRife.Count) modelo(s) de models/ a models/rife/"
        foreach ($f in $flatRife) { Move-Item $f.FullName (Join-Path $rifeDir $f.Name) -Force -EA SilentlyContinue }
    }

    $wanted = @("v4.25_heavy", "v4.25", "v4.22")
    $missing = $wanted | Where-Object { -not (Test-Path (Join-Path $rifeDir "rife_$_.onnx")) }
    if ($missing.Count -eq 0) { Info "Todos los modelos presentes en models/rife/"; return }

    $rel = Invoke-RestMethod "https://api.github.com/repos/AmusementClub/vs-mlrt/releases/tags/external-models"
    foreach ($v in $missing) {
        $aname = "rife_$v.7z"
        $a = $rel.assets | Where-Object { $_.name -eq $aname } | Select-Object -First 1
        if (-not $a) { Warn "No encontre $aname"; continue }
        $arch = Find-Or-Download -FileName $aname -Url $a.browser_download_url -ExpectedSize $a.size
        $tmp = Join-Path $Global:Config.BaseDir "rife-tmp"
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-7z -Archive $arch -DestDir $tmp
        Get-ChildItem $tmp -Filter "*.onnx" -Recurse | ForEach-Object {
            Copy-Item $_.FullName (Join-Path $rifeDir $_.Name) -Force
            Info "  rife/$($_.Name)"
        }
        Remove-Item $tmp -Recurse -Force
    }
    Ok "Modelos instalados en models/rife/"
}

function Write-InterpolationVpy {
    # BackendType: "TRT_RTX" (Blackwell), "TRT" (Turing/Ampere/Ada), "NCNN_VK" (Pascal/AMD/Intel)
    param([string]$BackendType = "TRT", [switch]$Force)
    Section "interpolation.vpy"
    $dst = Join-Path $Global:Config.MpvConfigDir "interpolation.vpy"
    $parent = Split-Path $dst -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    if ((Test-Path $dst) -and -not $Force) { Info "Ya existe (no se sobreescribe; usa Reparar para regenerar)"; return }
    if (Test-Path $dst) {
        $bak = "$dst.bak"
        Copy-Item $dst $bak -Force
        Info "Backup -> $bak"
    }

    # Modelo y escala vienen de Config (configurables por usuario o benchmark)
    $modelKey  = $Global:Config.RifeModel
    if (-not $modelKey) { $modelKey = if ($BackendType -eq "NCNN_VK") { "v4.22" } else { "v4.25_heavy" } }
    $scaleVal  = if ($Global:Config.RifeScale) { [double]$Global:Config.RifeScale } else { 1.0 }
    $modelLine = "RIFEModel." + ($modelKey -replace '\.', '_')   # "v4.22" -> "v4_22"
    $streamsLine = if ($BackendType -eq "NCNN_VK") { "1" } else { "2" }
    $backendExpr = switch ($BackendType) {
        "TRT_RTX" { "Backend.TRT_RTX(fp16=True, num_streams=NUM_STREAMS, device_id=0)" }
        "NCNN_VK" { "Backend.NCNN_VK(fp16=True, num_streams=NUM_STREAMS, device_id=0)" }
        default   { "Backend.TRT(fp16=True, num_streams=NUM_STREAMS, device_id=0)" }
    }

    $content = @"
# vpy-template-version: $($Global:VpyTemplateVersion)
# =============================================================================
# interpolation.vpy  (RIFE / vs-mlrt) - backend: $BackendType
# mpv inyecta: video_in, container_fps, display_fps
# =============================================================================
import math
import vapoursynth as vs
from vsmlrt import RIFE, RIFEModel, Backend

core = vs.core

RIFE_MODEL  = $modelLine
RIFE_SCALE  = $scaleVal   # 0.5 = procesa a la mitad (4x mas rapido)
NUM_STREAMS = $streamsLine

clip = video_in

target_fps = display_fps if display_fps and display_fps > 0 else 60.0
src_fps    = container_fps if container_fps and container_fps > 0 else 24.0
multi      = max(2, round(target_fps / src_fps))

clip = core.resize.Bicubic(clip, format=vs.RGBH, matrix_in_s="709",
    range_in_s="limited", range_s="full", dither_type="error_diffusion")

pad_w = math.ceil(clip.width / 32) * 32 - clip.width
pad_h = math.ceil(clip.height / 32) * 32 - clip.height
left = right = top = bottom = 0
if pad_w or pad_h:
    left, right = pad_w // 2, pad_w - pad_w // 2
    top, bottom = pad_h // 2, pad_h - pad_h // 2
    clip = core.std.AddBorders(clip, left=left, right=right, top=top, bottom=bottom)

backend = $backendExpr

clip = RIFE(clip, model=RIFE_MODEL, backend=backend, multi=multi,
            scale=RIFE_SCALE, video_player=True)

if pad_w or pad_h:
    clip = core.std.Crop(clip, left=left, right=right, top=top, bottom=bottom)

clip = core.resize.Bicubic(clip, format=vs.YUV420P10, matrix_s="709",
    range_in_s="full", range_s="limited", dither_type="error_diffusion")
clip.set_output()
"@
    Set-Content $dst $content -Encoding UTF8
    Ok "interpolation.vpy creado en $dst"
    Hint "Editalo manualmente para cambiar modelo/scale/streams"
}

function Write-AutoModeLua {
    param([switch]$Force, [int]$Buffered = 8, [int]$Concurrent = 4)
    Section "auto_mode.lua"
    $scriptsDir = Join-Path $Global:Config.MpvConfigDir "scripts"
    if (-not (Test-Path $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null }
    $dst = Join-Path $scriptsDir "auto_mode.lua"
    if ((Test-Path $dst) -and -not $Force) { Info "Ya existe (no se sobreescribe; usa Reparar para regenerar)"; return }
    if (Test-Path $dst) {
        # Guardar respaldo FUERA de scripts/ porque mpv intenta cargar todo lo
        # que este alli y falla con "Can't load unknown script: auto_mode.lua.bak"
        $bakDir = Join-Path $Global:Config.MpvConfigDir "wizard-backups"
        if (-not (Test-Path $bakDir)) { New-Item -ItemType Directory -Path $bakDir | Out-Null }
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $bak = Join-Path $bakDir "auto_mode.lua.$stamp.bak"
        Copy-Item $dst $bak -Force
        Info "Backup -> $bak"
    }
    $verLine = "-- lua-template-version: $($Global:LuaTemplateVersion)"
    $content = @"
$verLine
-- auto_mode.lua - HDR/SDR auto + cambio de Hz + toggle manual de interpolacion
local INTERP = "vapoursynth=~~/interpolation.vpy:buffered-frames=${Buffered}:concurrent-frames=${Concurrent}"
local SET_HZ = mp.find_config_file("set_display_hz.ps1")
local original_hz, hz_changed = 120, false

local function is_hdr()
    local t = mp.get_property("video-params/transfer") or ""
    local p = mp.get_property("video-params/primaries") or ""
    return t:find("pq")~=nil or t:find("hlg")~=nil or t:find("smpte2084")~=nil or p:find("bt.2020")~=nil
end

local function fps_to_hz(fps)
    if fps>=23 and fps<24.5 then return 24
    elseif fps>=24.5 and fps<26 then return 25
    elseif fps>=29 and fps<31 then return 30
    elseif fps>=47 and fps<51 then return 50
    elseif fps>=59 and fps<61 then return 60
    elseif fps>=119 and fps<=121 then return 120 end
end

local function set_hz(hz)
    if not SET_HZ then return false end
    return os.execute(string.format('powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%s" -Hz %d', SET_HZ, hz))
end

local function interp_active()
    local vf = mp.get_property("vf") or ""
    return vf:find("vapoursynth",1,true) ~= nil
end

local function set_interp(en)
    local has = interp_active()
    if en and not has then
        mp.commandv("vf","add",INTERP)
        mp.osd_message("Interpolacion: ON", 2)
    elseif (not en) and has then
        mp.commandv("vf","remove",INTERP)
        mp.osd_message("Interpolacion: OFF", 2)
    end
end

local function toggle_interp()
    set_interp(not interp_active())
end

mp.register_event("file-loaded", function()
    local fps = mp.get_property_number("container-fps") or 24
    if is_hdr() then
        set_interp(false)
        local hz = fps_to_hz(fps)
        if hz and hz~=original_hz then
            if set_hz(hz) then hz_changed=true end
            mp.osd_message(string.format("HDR %dfps -> %dHz | Interp OFF", math.floor(fps+0.5), hz), 3)
        else mp.osd_message(string.format("HDR %dfps | Interp OFF", math.floor(fps+0.5)), 2) end
    else
        if hz_changed then set_hz(original_hz); hz_changed=false end
        set_interp(true)
    end
end)

mp.register_event("shutdown", function() if hz_changed then set_hz(original_hz) end end)

-- Atajos de teclado:
--   Ctrl+i    Activar / desactivar interpolacion (toggle manual)
--   H         Mismo toggle (compatibilidad con versiones viejas del script)
mp.add_key_binding("Ctrl+i", "toggle-interpolation", toggle_interp)
mp.add_key_binding("H",      "toggle-interpolation-alt", toggle_interp)
"@
    Set-Content $dst $content -Encoding UTF8
    Ok "auto_mode.lua en $dst"
}

function Write-SetDisplayHz {
    Section "set_display_hz.ps1"
    $dst = Join-Path $Global:Config.MpvConfigDir "set_display_hz.ps1"
    $parent = Split-Path $dst -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path $dst) { Info "Ya existe (no se sobreescribe)"; return }
    $content = @'
param([double]$Hz, [string]$Device = "\\.\DISPLAY2")
Add-Type @"
using System; using System.Runtime.InteropServices;
public class DH {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string dmDeviceName;
        public ushort dmSpecVersion,dmDriverVersion,dmSize,dmDriverExtra;
        public uint dmFields,dmPositionX,dmPositionY,dmDisplayOrientation,dmDisplayFixedOutput;
        public short dmColor,dmDuplex,dmYResolution,dmTTOption,dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string dmFormName;
        public ushort dmLogPixels; public uint dmBitsPerPel,dmPelsWidth,dmPelsHeight,dmDisplayFlags,dmDisplayFrequency;
        public uint dmICMMethod,dmICMIntent,dmMediaType,dmDitherType,dmReserved1,dmReserved2,dmPanningWidth,dmPanningHeight;
    }
    [DllImport("user32.dll",CharSet=CharSet.Ansi)] public static extern bool EnumDisplaySettings(string d,int n,ref DEVMODE m);
    [DllImport("user32.dll",CharSet=CharSet.Ansi)] public static extern int ChangeDisplaySettingsEx(string d,ref DEVMODE m,IntPtr h,uint f,IntPtr l);
    public const int ENUM_CURRENT_SETTINGS=-1; public const uint CDS_UPDATEREGISTRY=1;
}
"@
$cur = New-Object DH+DEVMODE; $cur.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($cur)
[DH]::EnumDisplaySettings($Device,[DH]::ENUM_CURRENT_SETTINGS,[ref]$cur) | Out-Null
$tgt = [int][Math]::Round($Hz); $best=$null; $m = New-Object DH+DEVMODE; $m.dmSize = $cur.dmSize; $i=0
while ([DH]::EnumDisplaySettings($Device,$i,[ref]$m)) {
    if ($m.dmPelsWidth -eq $cur.dmPelsWidth -and $m.dmPelsHeight -eq $cur.dmPelsHeight -and $m.dmBitsPerPel -eq $cur.dmBitsPerPel -and $m.dmDisplayFrequency -eq $tgt) { $best=$m; break }; $i++
}
if ($null -eq $best) { Write-Host "[!!] $($tgt)Hz no soportado en $Device"; exit 1 }
$r = [DH]::ChangeDisplaySettingsEx($Device,[ref]$best,[IntPtr]::Zero,[DH]::CDS_UPDATEREGISTRY,[IntPtr]::Zero)
if ($r -eq 0) { Write-Host "[OK] $Device -> $($best.dmPelsWidth)x$($best.dmPelsHeight)@$($best.dmDisplayFrequency)Hz" }
else { Write-Host "[!!] Error $r"; exit 1 }
'@
    Set-Content $dst $content -Encoding UTF8
    Ok "set_display_hz.ps1 en $dst"
}

function Set-EnvVar {
    Section "Variables de entorno"
    $vsRoot = (Get-Variable -Name vsRoot -Scope Script -EA SilentlyContinue).Value
    if (-not $vsRoot) {
        $vspipe = Get-ChildItem (Join-Path $Global:Config.BaseDir "vapoursynth-portable") -Filter "VSPipe.exe" -Recurse -EA SilentlyContinue | Select-Object -First 1
        if ($vspipe) { $vsRoot = Split-Path $vspipe.FullName -Parent }
    }
    if (-not $vsRoot) { Warn "No se pudo determinar la carpeta de VapourSynth"; return }

    # 1) VSSCRIPT_PATH (lo usan VSPipe y herramientas de VS)
    $cur = [Environment]::GetEnvironmentVariable("VSSCRIPT_PATH","User")
    if ($cur -ne $vsRoot) {
        [Environment]::SetEnvironmentVariable("VSSCRIPT_PATH",$vsRoot,"User")
        Ok "VSSCRIPT_PATH = $vsRoot"
    } else { Info "VSSCRIPT_PATH ya configurado" }

    # 2) PATH del usuario - CRITICO: mpv necesita encontrar VSScript.dll para
    #    que el filtro vapoursynth funcione. Sin esto mpv se cierra al abrir
    #    un video con interpolacion activada.
    $userPath = [Environment]::GetEnvironmentVariable("Path","User")
    if (-not $userPath) { $userPath = "" }
    $parts = $userPath -split ';' | Where-Object { $_ -and $_.Trim() -ne '' }
    $already = $parts | Where-Object { $_.TrimEnd('\') -ieq $vsRoot.TrimEnd('\') }
    if ($already) {
        Info "PATH del usuario ya contiene $vsRoot"
    } else {
        $newPath = (@($vsRoot) + $parts) -join ';'
        [Environment]::SetEnvironmentVariable("Path",$newPath,"User")
        Ok "Agregado al PATH del usuario: $vsRoot"
    }

    Hint "Cierra y vuelve a abrir mpv (y cualquier terminal) para que tome efecto"
}

# =============================================================================
# ACCIONES PRINCIPALES
# =============================================================================
function Execute-Full-Install-Steps {
    param([string]$BackendType = "TRT")
    $script:vsPath = Install-VapourSynth
    $script:vsRoot = Split-Path $script:vsPath -Parent
    Install-VsMlrt -VsRoot $script:vsRoot
    Setup-VsmlrtPy -VsRoot $script:vsRoot
    Install-RifeModels -VsRoot $script:vsRoot
    Write-InterpolationVpy -BackendType $BackendType
    # NCNN soporta menos throughput, bajamos buffered/concurrent
    if ($BackendType -eq "NCNN_VK") { Write-AutoModeLua -Buffered 4 -Concurrent 2 }
    else                            { Write-AutoModeLua }
    Write-SetDisplayHz
    Set-EnvVar
}

function Set-RifeProfile {
    param([string]$Profile)
    # Aplica un preset en $Global:Config y lo persiste.
    switch ($Profile) {
        "maxima"      { $Global:Config.RifeScale = 1.0; $Global:Config.RifeModel = "v4.25_heavy" }
        "calidad"     { $Global:Config.RifeScale = 1.0; $Global:Config.RifeModel = "v4.25" }
        "balanceado"  { $Global:Config.RifeScale = 1.0; $Global:Config.RifeModel = "v4.22" }
        "rendimiento" { $Global:Config.RifeScale = 0.5; $Global:Config.RifeModel = "v4.22" }
    }
    Save-Config | Out-Null
    Info "Perfil: $Profile (modelo=$($Global:Config.RifeModel), scale=$($Global:Config.RifeScale))"
}

function Action-BenchmarkRife {
    # Mide rendimiento de varios perfiles y elige el de mayor calidad que
    # supere el refresh rate del monitor con margen de seguridad (1.2x).
    Section "Test de rendimiento RIFE-NCNN"
    $hz = Get-MonitorRefreshRate
    $target = [math]::Round($hz * 1.2, 1)   # 20% de margen
    Info "Monitor detectado: $hz Hz   |   Objetivo: $target fps efectivos"
    Write-Host ""
    Info "Esto tarda ~1-3 minutos y carga la GPU al maximo. No abras otros videos mientras corre."
    Write-Host ""

    # Perfiles de mas pesado a mas ligero. Salimos en cuanto uno cumple.
    $profiles = @(
        @{ Name = "maxima";      Scale = 1.0; Model = "v4.25_heavy" },
        @{ Name = "calidad";     Scale = 1.0; Model = "v4.25"        },
        @{ Name = "balanceado";  Scale = 1.0; Model = "v4.22"        },
        @{ Name = "rendimiento"; Scale = 0.5; Model = "v4.22"        }
    )

    $best   = $null
    $results = @()
    foreach ($p in $profiles) {
        Info "Probando $($p.Name)  (modelo=$($p.Model), scale=$($p.Scale))..."
        $fps = Run-NcnnBenchmark -Scale $p.Scale -Model $p.Model -FramesIn 30
        if ($null -eq $fps) {
            Warn "  Fallo el test de este perfil"
            continue
        }
        $results += [PSCustomObject]@{ Profile = $p.Name; Fps = $fps }
        $marker = if ($fps -ge $target) { "OK" } else { "lento" }
        Info "  -> $fps fps efectivos  [$marker]"
        if ($fps -ge $target -and -not $best) {
            $best = $p.Name   # primer perfil que cumple (el mas pesado posible)
            # Seguimos midiendo el resto para mostrar tabla completa, pero ya tenemos ganador
        }
    }

    Write-Host ""
    Info "Resumen:"
    foreach ($r in $results) {
        $mark = if ($r.Profile -eq $best) { "  <- ELEGIDO" } else { "" }
        Write-Host ("    {0,-12}  {1,6} fps{2}" -f $r.Profile, $r.Fps, $mark) -ForegroundColor Gray
    }
    Write-Host ""

    if (-not $best) {
        Warn "Ningun perfil alcanza $target fps. Tu GPU es muy lenta para RIFE-Vulkan."
        Hint "Recomendacion: usar el perfil 'rendimiento' y aceptar drops ocasionales,"
        Hint "             o cambiar a MVTools en la opcion Configuracion."
        $r = Read-Host "Aplicar perfil 'rendimiento' de todas formas? (s/n)"
        if ($r -eq "s" -or $r -eq "S") { Set-RifeProfile -Profile "rendimiento" }
        return
    }

    Ok "Perfil elegido: $best"
    Set-RifeProfile -Profile $best

    # Regenerar el .vpy si ya existe, para que tome efecto inmediato
    $vpy = Join-Path $Global:Config.MpvConfigDir "interpolation.vpy"
    if (Test-Path $vpy) {
        $bt = switch ($Global:Env.SupportedBackend) {
            "RIFE_TRT_RTX" { "TRT_RTX" }
            "RIFE_NCNN"    { "NCNN_VK" }
            default        { "TRT" }
        }
        Write-InterpolationVpy -BackendType $bt -Force
    }
}

function Ask-RifeProfile {
    # Para flujos de instalacion: pregunta al usuario el perfil deseado.
    Write-Host ""
    Info "Elige perfil de RIFE:"
    Write-Host "  [1] Maxima calidad  (modelo heavy, scale 1.0)  - solo GPUs potentes"
    Write-Host "  [2] Calidad         (modelo v4.25, scale 1.0)"
    Write-Host "  [3] Balanceado      (modelo v4.22, scale 1.0)  - recomendado para GPUs medias"
    Write-Host "  [4] Rendimiento     (modelo v4.22, scale 0.5)  - GPUs viejas o si hay drops"
    Write-Host "  [5] Test automatico (recomendado)              - prueba todos y elige el mejor"
    Write-Host ""
    while ($true) {
        $r = Read-Host "Opcion (1-5)"
        switch ($r) {
            "1" { Set-RifeProfile -Profile "maxima";       return $true }
            "2" { Set-RifeProfile -Profile "calidad";      return $true }
            "3" { Set-RifeProfile -Profile "balanceado";   return $true }
            "4" { Set-RifeProfile -Profile "rendimiento";  return $true }
            "5" { Action-BenchmarkRife; return $true }
            default { Warn "Opcion invalida" }
        }
    }
}

function Action-Install {
    Clear-Host
    Title "INSTALACION"
    if ($Global:Env.SupportedBackend -eq "MVTOOLS") {
        Warn "Tu GPU ($($Global:Env.GPU)) no soporta RIFE/TensorRT eficientemente."
        Warn "Se instalara MVTools (CPU) en su lugar."
        Hint "MVTools es la base de SVP - calidad similar al modo automatico."
        Write-Host ""
        $ok = Read-Host "Continuar con MVTools? (s/n)"
        if ($ok -ne "s" -and $ok -ne "S") { return }
        Action-Install-MVTools
        return
    }
    $backendType = switch ($Global:Env.SupportedBackend) {
        "RIFE_TRT_RTX" { "TRT_RTX" }
        "RIFE_NCNN"    { "NCNN_VK" }
        default        { "TRT" }
    }
    switch ($backendType) {
        "TRT_RTX" { Info "Backend: RIFE via TensorRT-RTX (Blackwell)" }
        "NCNN_VK" { Info "Backend: RIFE via NCNN-Vulkan ($($Global:Env.GPUGen) - no soporta TensorRT pero si Vulkan)" }
        default   { Info "Backend: RIFE via TensorRT ($($Global:Env.GPUGen))" }
    }
    Write-Host ""

    $st = Detect-Installation
    if (-not $st.MpvSupportsVs) {
        Bad "TU MPV NO ES COMPATIBLE"
        Warn "El archivo: $($Global:Config.MpvExe)"
        Warn "no fue compilado con soporte para VapourSynth."
        Write-Host ""
        Write-Host "  Debes descargar una version compatible (ej. de shinchiro o Gresaca)." -ForegroundColor Gray
        Write-Host "  Link: https://github.com/shinchiro/mpv-winbuild-cmake/releases" -ForegroundColor Cyan
        Write-Host ""
        $c = Read-Host "Continuar de todas formas? (s/n)"
        if ($c -ne "s" -and $c -ne "S") { return }
    }

    if (-not (Test-Path $Global:Config.MpvConfigDir)) { New-Item -ItemType Directory -Path $Global:Config.MpvConfigDir | Out-Null }

    # Para NCNN preguntar perfil; para TRT/TRT_RTX usar defaults de calidad maxima
    if ($backendType -eq "NCNN_VK") {
        Section "Perfil de calidad / rendimiento"
        Info "RIFE-NCNN-Vulkan se puede configurar entre maxima calidad y maximo rendimiento."
        Info "Si no estas seguro, elige '5 - Test automatico' (recomendado)."
        Ask-RifeProfile | Out-Null
    } else {
        Set-RifeProfile -Profile "maxima"
    }

    Execute-Full-Install-Steps -BackendType $backendType

    Section "INSTALACION COMPLETA"
    Write-Host ""
    Write-Host "  Atajos en mpv (al reproducir un video):" -ForegroundColor Cyan
    Write-Host "    Ctrl+i   Activar / desactivar interpolacion"
    Write-Host "    H        Mismo toggle (alias por compatibilidad)"
    Write-Host ""
    Write-Host "  La primera reproduccion por resolucion compila el engine TensorRT" -ForegroundColor Yellow
    Write-Host "  (2-8 min, mpv se vera 'congelado'). Despues queda cacheado." -ForegroundColor Yellow
    Pause-Continue
}

function Action-Install-MVTools {
    Section "Instalando MVTools (CPU)"
    $vsPath = Install-VapourSynth
    $vsRoot = Split-Path $vsPath -Parent
    $pluginDir = Join-Path $vsRoot "vs-plugins"
    if (-not (Test-Path $pluginDir)) { New-Item -ItemType Directory -Path $pluginDir | Out-Null }

    # Bajar mvtools desde el repo de dubhater
    try {
        $rel = Invoke-RestMethod "https://api.github.com/repos/dubhater/vapoursynth-mvtools/releases/latest"
        $asset = $rel.assets | Where-Object { $_.name -like "*win64*" -or $_.name -like "*Windows*" } | Select-Object -First 1
        if (-not $asset) { throw "No se encontro release win64 de mvtools" }
        $arch = Find-Or-Download -FileName $asset.name -Url $asset.browser_download_url -ExpectedSize $asset.size
        if ($asset.name -like "*.7z") { Expand-7z -Archive $arch -DestDir $pluginDir }
        elseif ($asset.name -like "*.zip") { Expand-Archive -Path $arch -DestinationPath $pluginDir -Force }
        Ok "MVTools instalado"
    } catch {
        Warn "Fallo bajar mvtools automaticamente: $_"
        Hint "Descarga manual: https://github.com/dubhater/vapoursynth-mvtools/releases"
        Hint "Extrae libmvtools.dll a $pluginDir"
        Pause-Continue
        return
    }

    # Generar .vpy para MVTools
    $vpyDst = Join-Path $Global:Config.MpvConfigDir "interpolation.vpy"
    if (Test-Path $vpyDst) { Copy-Item $vpyDst "$vpyDst.bak" -Force; Info "Backup -> $vpyDst.bak" }
    $vpyContent = @"
# vpy-template-version: $($Global:VpyTemplateVersion)
# interpolation.vpy - MVTools (CPU)
import vapoursynth as vs
core = vs.core
clip = video_in
target_fps = display_fps if display_fps and display_fps > 0 else 60.0
src_fps    = container_fps if container_fps and container_fps > 0 else 24.0
factor     = max(2, round(target_fps / src_fps))

clip = core.resize.Bicubic(clip, format=vs.YUV420P8, matrix_s="709")
sup  = core.mv.Super(clip, pel=2)
vec_b = core.mv.Analyse(sup, blksize=16, isb=True)
vec_f = core.mv.Analyse(sup, blksize=16, isb=False)
clip = core.mv.BlockFPS(clip, sup, vec_b, vec_f, num=int(src_fps*factor*100), den=100, mode=3)
clip.set_output()
"@
    Set-Content $vpyDst $vpyContent -Encoding UTF8
    Ok "interpolation.vpy (MVTools) creado"
    Write-AutoModeLua
    Set-EnvVar
    Pause-Continue
}

function Action-Update {
    Clear-Host
    Title "ACTUALIZAR"
    $st = Detect-Installation
    if (-not $st.VSInstalled) { Warn "No hay instalacion previa, usa Instalar"; Pause-Continue; return }

    Info "Estado actual:"
    $mlrtStatus = if ($st.MlrtVersion) { " ($($st.MlrtVersion))" } else { " (No detectado)" }
    Info "  vs-mlrt    : $($Global:Config.MlrtVersion)$mlrtStatus"
    Info "  Parchado   : $(if($st.VsmlrtPyPatched){'SI'}else{'NO'})"
    Info "  Modelos    : $(if($st.ModelsInstalled){'SI'}else{'NO'})"
    Write-Host ""

    $prev = $Global:Config.MlrtVersionPrevious
    $rollbackLabel = if ($prev) { "Volver a version anterior de vs-mlrt ($prev)" } else { "Volver a version anterior (sin historial todavia)" }
    $vpySuffix = if ($st.VpyOutdated) { " [!] desactualizado (v$($st.VpyVersion) -> v$($Global:VpyTemplateVersion))" } else { " (v$($st.VpyVersion))" }
    $luaSuffix = if ($st.LuaOutdated) { " [!] desactualizado (v$($st.LuaVersion) -> v$($Global:LuaTemplateVersion))" } else { " (v$($st.LuaVersion))" }
    $vpyLabel = "Regenerar interpolation.vpy" + $vpySuffix
    $luaLabel = "Regenerar auto_mode.lua" + $luaSuffix
    $opts = @(
        "Buscar versiones nuevas online (vs-mlrt / VapourSynth / wizard)",
        "Actualizar bundle vs-mlrt al $($Global:Config.MlrtVersion)",
        $rollbackLabel,
        $vpyLabel,
        $luaLabel,
        "Re-aplicar parches a vsmlrt.py",
        "Re-descargar/actualizar modelos RIFE",
        "Cambiar perfil RIFE (calidad/rendimiento/test automatico)",
        "Reset completo (borra todo lo de mpv-interp y reinstala)",
        "Volver al menu"
    )
    $i = Show-Menu -Title "Que actualizar?" -Options $opts
    switch ($i) {
        0 { Action-CheckOnlineUpdates; Pause-Continue }
        1 {
            $pluginDir = Join-Path $st.VSPath "vs-plugins"
            $trtexec = Join-Path $pluginDir "vsmlrt-cuda\trtexec.exe"
            if (Test-Path $trtexec) { Remove-Item $trtexec -Force }   # forzar re-extraccion
            Install-VsMlrt -VsRoot $st.VSPath
            Setup-VsmlrtPy -VsRoot $st.VSPath
            Pause-Continue
        }
        2 {
            if (-not $prev) {
                Warn "Aun no hay version anterior registrada. Solo se guarda cuando cambias de version."
                Pause-Continue
            } else {
                $cachedHere = Test-Path (Join-Path $Global:Config.BaseDir "vsmlrt-windows-x64-cuda.$prev.7z.001")
                $cachedExt  = $Global:Config.LocalBundleDir -and (Test-Path (Join-Path $Global:Config.LocalBundleDir "vsmlrt-windows-x64-cuda.$prev.7z.001"))
                $cacheNote  = if ($cachedHere -or $cachedExt) { "(bundle cacheado disponible)" } else { "(se descargara de GitHub)" }
                Warn "Vas a hacer rollback de $($Global:Config.MlrtVersion) -> $prev  $cacheNote"
                $c = Read-Host "Confirmas? (s/n)"
                if ($c -eq "s" -or $c -eq "S") {
                    # Intercambiar Previous <-> Current
                    $tmp = $Global:Config.MlrtVersion
                    $Global:Config.MlrtVersion         = $prev
                    $Global:Config.MlrtVersionPrevious = $tmp
                    Save-Config | Out-Null
                    $trt = Join-Path $st.VSPath "vs-plugins\vsmlrt-cuda\trtexec.exe"
                    if (Test-Path $trt) { Remove-Item $trt -Force }
                    Install-VsMlrt -VsRoot $st.VSPath
                    Setup-VsmlrtPy -VsRoot $st.VSPath
                    Ok "Rollback completo. Ahora estas en $prev (anterior queda: $tmp)"
                } else { Info "Cancelado" }
                Pause-Continue
            }
        }
        3 {
            $backendType = switch ($Global:Env.SupportedBackend) {
                "RIFE_TRT_RTX" { "TRT_RTX" }
                "RIFE_NCNN"    { "NCNN_VK" }
                default        { "TRT" }
            }
            if ($Global:Env.SupportedBackend -eq "MVTOOLS") {
                # Regenerar MVTools .vpy
                $vpyDst = Join-Path $Global:Config.MpvConfigDir "interpolation.vpy"
                if (Test-Path $vpyDst) { Copy-Item $vpyDst "$vpyDst.bak" -Force; Info "Backup -> $vpyDst.bak" }
                $vpyContent = @"
# vpy-template-version: $($Global:VpyTemplateVersion)
# interpolation.vpy - MVTools (CPU)
import vapoursynth as vs
core = vs.core
clip = video_in
target_fps = display_fps if display_fps and display_fps > 0 else 60.0
src_fps    = container_fps if container_fps and container_fps > 0 else 24.0
factor     = max(2, round(target_fps / src_fps))

clip = core.resize.Bicubic(clip, format=vs.YUV420P8, matrix_s="709")
sup  = core.mv.Super(clip, pel=2)
vec_b = core.mv.Analyse(sup, blksize=16, isb=True)
vec_f = core.mv.Analyse(sup, blksize=16, isb=False)
clip = core.mv.BlockFPS(clip, sup, vec_b, vec_f, num=int(src_fps*factor*100), den=100, mode=3)
clip.set_output()
"@
                Set-Content $vpyDst $vpyContent -Encoding UTF8
                Ok "interpolation.vpy (MVTools) regenerado"
            } else {
                Write-InterpolationVpy -BackendType $backendType -Force
            }
            Pause-Continue
        }
        4 {
            Write-AutoModeLua -Force
            Pause-Continue
        }
        5 {
            $py = Join-Path $st.VSPath "Lib\site-packages\vsmlrt.py"
            $n = Patch-Vsmlrt -Path $py
            if ($n -gt 0) { Ok "$n parche(s) aplicados" } else { Info "Ya estaba parchado" }
            Pause-Continue
        }
        6 {
            Install-RifeModels -VsRoot $st.VSPath
            Pause-Continue
        }
        7 {
            # Cambiar perfil RIFE
            if ($Global:Env.SupportedBackend -eq "MVTOOLS") {
                Warn "Tu backend es MVTools, no RIFE. Este menu no aplica."
            } else {
                Info "Perfil actual: modelo=$($Global:Config.RifeModel), scale=$($Global:Config.RifeScale)"
                Write-Host ""
                Ask-RifeProfile | Out-Null
                # Regenerar el .vpy con el perfil nuevo
                $vpy = Join-Path $Global:Config.MpvConfigDir "interpolation.vpy"
                if (Test-Path $vpy) {
                    $bt = switch ($Global:Env.SupportedBackend) {
                        "RIFE_TRT_RTX" { "TRT_RTX" }
                        "RIFE_NCNN"    { "NCNN_VK" }
                        default        { "TRT" }
                    }
                    Write-InterpolationVpy -BackendType $bt -Force
                }
            }
            Pause-Continue
        }
        8 {
            $confirm = Read-Host "Esto borrara $($Global:Config.BaseDir). Confirmas? (escribe BORRAR)"
            if ($confirm -eq "BORRAR") {
                Remove-Item $Global:Config.BaseDir -Recurse -Force -EA SilentlyContinue
                Ok "Borrado. Ejecuta 'Instalar' de nuevo."
            } else { Info "Cancelado" }
            Pause-Continue
        }
    }
}

function Update-Wizard {
    param([string]$NewTag)
    Section "Actualizando Wizard a $NewTag"
    
    try {
        $rel = Invoke-RestMethod "https://api.github.com/repos/$Global:WizardRepo/releases/tags/$NewTag" -Headers @{ "User-Agent" = "mpv-interp-wizard" }
        # Buscamos el .bat en los assets
        $asset = $rel.assets | Where-Object { $_.name -eq "MPV-Interp-Wizard.bat" } | Select-Object -First 1
        if (-not $asset) { throw "No se encontro MPV-Interp-Wizard.bat en la release $NewTag" }
        
        # Donde guardar? Si estamos en el .bat, MPV_INTERP_HOME es la carpeta del .bat
        $dest = if ($env:MPV_INTERP_HOME) { Join-Path $env:MPV_INTERP_HOME "MPV-Interp-Wizard.bat" }
                else { Join-Path $PSScriptRoot "MPV-Interp-Wizard.bat" }
        
        Info "Descargando nueva version desde $($asset.browser_download_url)..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile "$dest.new" -TimeoutSec 30
        
        if (Test-Path "$dest.new") {
            if (Test-Path $dest) { Copy-Item $dest "$dest.bak" -Force; Info "Backup creado: $dest.bak" }
            Move-Item "$dest.new" $dest -Force
            Ok "Wizard actualizado con exito en $dest"
            Warn "POR FAVOR, CIERRA ESTA VENTANA Y VUELVE A ABRIR EL WIZARD."
            Pause-Continue
            exit 0
        }
    } catch {
        Bad "Error al actualizar wizard: $_"
    }
}

function Action-CheckOnlineUpdates {
    Section "Buscando actualizaciones online..."
    Info "(cache de 24h en mpv-interp-wizard.update-cache.json)"
    Write-Host ""

    $wiz   = Get-LatestGithubRelease -Repo $Global:WizardRepo
    $mlrt  = Get-LatestGithubRelease -Repo $Global:VsMlrtRepo
    $vs    = Get-LatestGithubRelease -Repo $Global:VapourSynthRepo

    # 1. Mostrar resumen de versiones
    Write-Host "  Wizard       : instalado $($Global:WizardVersion)" -NoNewline
    if ($wiz) {
        $cmp = Compare-Versions $Global:WizardVersion $wiz.Tag
        if ($cmp -lt 0) { Write-Host "  -> NUEVA $($wiz.Tag)" -ForegroundColor Yellow }
        else { Write-Host "  (al dia)" -ForegroundColor Green }
    } else { Write-Host "  (no se pudo consultar)" -ForegroundColor DarkGray }

    Write-Host "  vs-mlrt      : instalado $($Global:Config.MlrtVersion)" -NoNewline
    if ($mlrt) {
        $st = Detect-Installation
        $cmp = Compare-Versions $Global:Config.MlrtVersion $mlrt.Tag
        if ($cmp -lt 0) { Write-Host "  -> NUEVA $($mlrt.Tag)" -ForegroundColor Yellow }
        elseif ($st.MlrtVersion -like "antigua*") { Write-Host " [!] FILES ANTIGUOS" -ForegroundColor Red }
        else { Write-Host "  (al dia)" -ForegroundColor Green }
    } else { Write-Host "  (no se pudo consultar)" -ForegroundColor DarkGray }

    Write-Host "  VapourSynth  : instalado $($Global:Config.VsRelease)" -NoNewline
    if ($vs) {
        $cmp = Compare-Versions $Global:Config.VsRelease $vs.Tag
        if ($cmp -lt 0) { Write-Host "  -> NUEVA $($vs.Tag)" -ForegroundColor Yellow }
        else { Write-Host "  (al dia)" -ForegroundColor Green }
    } else { Write-Host "  (no se pudo consultar)" -ForegroundColor DarkGray }

    # 2. Preguntar por actualizaciones si existen
    Write-Host ""
    if ($wiz -and (Compare-Versions $Global:WizardVersion $wiz.Tag) -lt 0) {
        $r = Read-Host "  ¿Actualizar Wizard ahora a $($wiz.Tag)? (s/n)"
        if ($r -eq "s" -or $r -eq "S") { Update-Wizard -NewTag $wiz.Tag }
    }

    $st = Detect-Installation
    if ($mlrt -and ((Compare-Versions $Global:Config.MlrtVersion $mlrt.Tag) -lt 0 -or $st.MlrtVersion -like "antigua*")) {
        $reason = if ($st.MlrtVersion -like "antigua*") { "tus archivos actuales son antiguos/incompatibles" } else { "hay una nueva version $($mlrt.Tag)" }
        $r = Read-Host "  ¿Actualizar/Reinstalar bundle vs-mlrt? ($reason) (s/n)"
        if ($r -eq "s" -or $r -eq "S") {
            Set-MlrtVersion -NewVersion $mlrt.Tag
            $st = Detect-Installation
            if ($st.VSInstalled) {
                $trt = Get-ChildItem (Join-Path $st.VSPath "vs-plugins") -Filter "trtexec.exe" -Recurse -EA SilentlyContinue | Select-Object -First 1
                if ($trt) { Remove-Item $trt.FullName -Force }
                Install-VsMlrt -VsRoot $st.VSPath
                Setup-VsmlrtPy -VsRoot $st.VSPath
                Ok "vs-mlrt actualizado."
            }
        }
    }

    if ($vs -and (Compare-Versions $Global:Config.VsRelease $vs.Tag) -lt 0) {
        $r = Read-Host "  ¿Actualizar VapourSynth a $($vs.Tag)? (s/n)`n  (Se hara backup temporal de la carpeta actual)"
        if ($r -eq "s" -or $r -eq "S") {
            Set-VsRelease -NewVersion $vs.Tag
            $vsDir = Join-Path $Global:Config.BaseDir "vapoursynth-portable"
            $vsOld = Join-Path $Global:Config.BaseDir "vapoursynth-portable.old"
            
            if (Test-Path $vsDir) {
                Info "Creando backup temporal en .old..."
                if (Test-Path $vsOld) { Remove-Item $vsOld -Recurse -Force }
                Rename-Item $vsDir "vapoursynth-portable.old" -Force
            }
            
            try {
                $bt = switch ($Global:Env.SupportedBackend) {
                    "RIFE_TRT_RTX" { "TRT_RTX" }
                    "RIFE_NCNN"    { "NCNN_VK" }
                    default        { "TRT" }
                }
                Execute-Full-Install-Steps -BackendType $bt
                Ok "Actualizacion de VapourSynth exitosa."
                if (Test-Path $vsOld) { Remove-Item $vsOld -Recurse -Force -EA SilentlyContinue }
            } catch {
                Bad "Fallo la actualizacion: $_"
                if (Test-Path $vsOld) {
                    Warn "Restaurando backup anterior..."
                    if (Test-Path $vsDir) { Remove-Item $vsDir -Recurse -Force -EA SilentlyContinue }
                    Rename-Item $vsOld "vapoursynth-portable" -Force
                    Ok "Sistema restaurado a la version anterior."
                }
            }
        }
    }
}

function Action-Repair {
    Clear-Host
    Title "REPARAR"
    $st = Detect-Installation
    Info "Diagnostico:"
    Info "  VapourSynth      : $(if ($st.VSInstalled){'OK'}else{'FALTA'})"
    Info "  vs-mlrt          : $($st.MlrtVersion)"
    Info "  vsmlrt.py parchado: $(if ($st.VsmlrtPyPatched){'OK'}else{'FALTA'})"
    Info "  Modelos RIFE     : $(if ($st.ModelsInstalled){'OK'}else{'FALTA'})"
    Info "  interpolation.vpy: $(if ($st.VpyInstalled){'OK'}else{'FALTA'})"
    Info "  auto_mode.lua    : $(if ($st.LuaInstalled){'OK'}else{'FALTA'})"
    Info "  set_display_hz   : $(if ($st.SetHzInstalled){'OK'}else{'FALTA'})"
    Info "  mpv + VapourSynth: $(if ($st.MpvSupportsVs){'OK'}else{'INCOMPATIBLE [!]'})"
    Write-Host ""

    if (-not $st.MpvSupportsVs) {
        Warn "Atencion: Tu reproductor mpv no soporta VapourSynth."
        Warn "La interpolacion NO funcionara hasta que cambies el mpv.exe."
        Hint "Descarga uno compatible en: https://github.com/shinchiro/mpv-winbuild-cmake/releases"
        Write-Host ""
    }

    $r = Read-Host "Aplicar reparacion automatica de lo que falte? (s/n)"
    if ($r -ne "s" -and $r -ne "S") { return }
    
    # Asegurar que existe la carpeta de config de mpv
    if (-not (Test-Path $Global:Config.MpvConfigDir)) { 
        New-Item -ItemType Directory -Path $Global:Config.MpvConfigDir -Force | Out-Null
        Ok "Creada carpeta: $($Global:Config.MpvConfigDir)"
    }

    if (-not $st.VSInstalled) { $vsp = Install-VapourSynth; $st.VSPath = Split-Path $vsp -Parent }
    
    if ($Global:Env.SupportedBackend -match "^RIFE_") {
        $backendType = switch ($Global:Env.SupportedBackend) {
            "RIFE_TRT_RTX" { "TRT_RTX" }
            "RIFE_NCNN"    { "NCNN_VK" }
            default        { "TRT" }
        }
        if (-not $st.MlrtInstalled -or $st.MlrtVersion -like "antigua*") { Install-VsMlrt -VsRoot $st.VSPath }
        Setup-VsmlrtPy -VsRoot $st.VSPath
        if (-not $st.ModelsInstalled) { Install-RifeModels -VsRoot $st.VSPath }
        if (-not $st.VpyInstalled -or $st.VpyOutdated) { Write-InterpolationVpy -BackendType $backendType -Force }
        # NCNN rinde menos -> buffers mas conservadores
        $buf = if ($backendType -eq "NCNN_VK") { 4 } else { 8 }
        $cnc = if ($backendType -eq "NCNN_VK") { 2 } else { 4 }
        if (-not $st.LuaInstalled -or $st.LuaOutdated) { Write-AutoModeLua -Force -Buffered $buf -Concurrent $cnc }
        else { Info "auto_mode.lua ya esta al dia (v$($st.LuaVersion))" }
    } else {
        # Reparar MVTools
        if (-not $st.VpyInstalled) {
            $vpyDst = Join-Path $Global:Config.MpvConfigDir "interpolation.vpy"
            $parent = Split-Path $vpyDst -Parent
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            # Generar el vpy de MVTools (copiando la logica de Action-Install-MVTools)
            $vpyContent = @"
# vpy-template-version: $($Global:VpyTemplateVersion)
# interpolation.vpy - MVTools (CPU)
import vapoursynth as vs
core = vs.core
clip = video_in
target_fps = display_fps if display_fps and display_fps > 0 else 60.0
src_fps    = container_fps if container_fps and container_fps > 0 else 24.0
factor     = max(2, round(target_fps / src_fps))

# Asegurar formato compatible y procesar
clip = core.std.SetFieldBased(clip, 0)
clip = core.resize.Bicubic(clip, format=vs.YUV420P8, matrix_s="709")
sup  = core.mv.Super(clip, pel=2)
vec_b = core.mv.Analyse(sup, blksize=16, isb=True)
vec_f = core.mv.Analyse(sup, blksize=16, isb=False)
clip = core.mv.BlockFPS(clip, sup, vec_b, vec_f, num=int(src_fps*factor*1000), den=1000, mode=3)
clip.set_output()
"@
            Set-Content $vpyDst $vpyContent -Encoding UTF8
            Ok "interpolation.vpy (MVTools) regenerado"
        }
        if (-not $st.LuaInstalled -or $st.LuaOutdated) { Write-AutoModeLua -Force -Buffered 4 -Concurrent 1 }
        else { Info "auto_mode.lua ya esta al dia (v$($st.LuaVersion))" }
    }

    if (-not $st.SetHzInstalled) { Write-SetDisplayHz }
    Set-EnvVar
    Pause-Continue
}

function Action-Diagnose {
    Clear-Host
    Title "DIAGNOSTICO"
    Info "GPU:           $($Global:Env.GPU)"
    Info "Generacion:    $($Global:Env.GPUGen)"
    Info "Compute Cap:   $($Global:Env.ComputeCap)"
    Info "Driver:        $($Global:Env.DriverVersion)"
    Info "Backend rec.:  $($Global:Env.SupportedBackend)"
    Write-Host ""
    $st = Detect-Installation
    Info "Instalacion:"
    Info "  Estado           : $($st.OverallStatus)"
    Info "  VapourSynth      : $(if ($st.VSInstalled){$st.VSPath}else{'no instalado'})"
    Info "  mpv compatible   : $(if ($st.MpvSupportsVs){'SI'}else{'NO (Falta soporte VapourSynth en el exe)'})"
    
    if ($Global:Env.SupportedBackend -match "RIFE_TRT") {
        Info "  vs-mlrt version  : $($st.MlrtVersion)"
        Info "  vsmlrt.py parchado: $($st.VsmlrtPyPatched)"
        Info "  Modelos RIFE     : $($st.ModelsInstalled)"
    }

    Info "  interpolation.vpy: $($st.VpyInstalled)"
    Info "  auto_mode.lua    : $($st.LuaInstalled)"
    Info "  set_display_hz   : $($st.SetHzInstalled)"
    Pause-Continue
}

function Action-Uninstall {
    Clear-Host
    Title "DESINSTALAR"
    Warn "Esto borrara:"
    Info "  - $($Global:Config.BaseDir) (VapourSynth + vs-mlrt + modelos)"
    Info "  - interpolation.vpy, auto_mode.lua, set_display_hz.ps1 de portable_config"
    Info "  - Variable de entorno VSSCRIPT_PATH"
    Info "  - Entrada de VapourSynth en el PATH del usuario"
    Hint "No se tocan otros archivos de mpv ni tu update.bat"
    Write-Host ""
    $r = Read-Host "Confirmas? (escribe BORRAR)"
    if ($r -ne "BORRAR") { Info "Cancelado"; Pause-Continue; return }

    Remove-Item $Global:Config.BaseDir -Recurse -Force -EA SilentlyContinue
    Remove-Item (Join-Path $Global:Config.MpvConfigDir "interpolation.vpy") -Force -EA SilentlyContinue
    Remove-Item (Join-Path $Global:Config.MpvConfigDir "scripts\auto_mode.lua") -Force -EA SilentlyContinue
    Remove-Item (Join-Path $Global:Config.MpvConfigDir "set_display_hz.ps1") -Force -EA SilentlyContinue
    # Determinar la carpeta de VapourSynth para quitarla del PATH
    $vsRoot = [Environment]::GetEnvironmentVariable("VSSCRIPT_PATH","User")
    [Environment]::SetEnvironmentVariable("VSSCRIPT_PATH",$null,"User")
    if ($vsRoot) {
        $userPath = [Environment]::GetEnvironmentVariable("Path","User")
        if ($userPath) {
            $parts = $userPath -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $vsRoot.TrimEnd('\') }
            [Environment]::SetEnvironmentVariable("Path",($parts -join ';'),"User")
        }
    }
    Ok "Desinstalado"
    Pause-Continue
}

function Action-Config {
    while ($true) {
        Clear-Host
        Title "CONFIGURACION DE RUTAS"
        Info "Archivo: $Global:ConfigFile"
        Write-Host ""

        $opts = @(
            ("BaseDir         = " + $(if ($Global:Config.BaseDir) { $Global:Config.BaseDir } else { "(vacio)" })),
            ("MpvConfigDir    = " + $(if ($Global:Config.MpvConfigDir) { $Global:Config.MpvConfigDir } else { "(vacio)" })),
            ("MpvExe          = " + $(if ($Global:Config.MpvExe) { $Global:Config.MpvExe } else { "(vacio)" })),
            ("LocalBundleDir  = " + $(if ($Global:Config.LocalBundleDir) { $Global:Config.LocalBundleDir } else { "(no configurado)" })),
            ("VsRelease       = " + $Global:Config.VsRelease),
            ("MlrtVersion     = " + $Global:Config.MlrtVersion),
            "Volver al menu principal"
        )
        $i = Show-Menu -Title "Que quieres editar?" -Options $opts -Footer "Cambios se guardan automaticamente"
        switch ($i) {
            0 {
                $v = Prompt-Path -Label "Nueva BaseDir" -Default $Global:Config.BaseDir -MustExist $false
                $Global:Config.BaseDir = $v; Save-Config
            }
            1 {
                $v = Prompt-Path -Label "Nueva MpvConfigDir" -Default $Global:Config.MpvConfigDir -MustExist $false
                $Global:Config.MpvConfigDir = $v; Save-Config
            }
            2 {
                $v = Prompt-Path -Label "Nueva ruta a mpv.exe" -Default $Global:Config.MpvExe -MustExist $true
                $Global:Config.MpvExe = $v; Save-Config
            }
            3 {
                $v = Prompt-Path -Label "Nueva LocalBundleDir (vacio = ninguna)" -Default $Global:Config.LocalBundleDir -AllowEmpty $true
                $Global:Config.LocalBundleDir = $v; Save-Config
            }
            4 {
                $v = Read-Host "  Nueva VsRelease [$($Global:Config.VsRelease)]"
                if ($v) { $Global:Config.VsRelease = $v; Save-Config }
            }
            5 {
                $v = Read-Host "  Nueva MlrtVersion [$($Global:Config.MlrtVersion)]"
                if ($v) { $Global:Config.MlrtVersion = $v; Save-Config }
            }
            { $_ -eq 6 -or $_ -eq -1 } { return }
        }
    }
}

# =============================================================================
# MAIN
# =============================================================================
function Main {
    Clear-Host
    Detect-TUI

    # Cargar config persistida o disparar setup inicial
    $loaded = Load-Config
    if (-not $loaded -or -not $Global:Config.BaseDir -or -not $Global:Config.MpvConfigDir) {
        Show-Welcome
        First-Time-Setup
    }

    # Forzar refresco de cache de updates si acabamos de actualizar el wizard
    $cacheFile = Get-UpdateCacheFile
    if (Test-Path $cacheFile) {
        $c = Get-Content $cacheFile | ConvertFrom-Json -EA SilentlyContinue
        if ($c -and $c.WizardVersion -ne $Global:WizardVersion) {
            Remove-Item $cacheFile -Force -EA SilentlyContinue
        }
    }

    Detect-GPU

    # Limpieza automatica de respaldos sueltos en scripts/ (versiones < 1.1.2
    # los dejaban como auto_mode.lua.bak alli y mpv intentaba cargarlos como script).
    try {
        $scriptsDir = Join-Path $Global:Config.MpvConfigDir "scripts"
        if (Test-Path $scriptsDir) {
            $orphans = @(Get-ChildItem $scriptsDir -Filter "auto_mode.lua*.bak" -EA SilentlyContinue)
            if ($orphans.Count -gt 0) {
                $bakDir = Join-Path $Global:Config.MpvConfigDir "wizard-backups"
                if (-not (Test-Path $bakDir)) { New-Item -ItemType Directory -Path $bakDir -Force | Out-Null }
                foreach ($f in $orphans) {
                    Move-Item $f.FullName (Join-Path $bakDir $f.Name) -Force -EA SilentlyContinue
                }
                Info "Movidos $($orphans.Count) respaldo(s) sueltos de scripts/ a wizard-backups/"
            }
        }
    } catch {}

    # Chequeo de updates en background (silencioso, con cache 24h)
    $updateHints = @()
    $wizRel = Get-LatestGithubRelease -Repo $Global:WizardRepo
    if ($wizRel -and (Compare-Versions $Global:WizardVersion $wizRel.Tag) -lt 0) {
        $updateHints += "Wizard $($wizRel.Tag) disponible"
    }
    $mlrtRel = Get-LatestGithubRelease -Repo $Global:VsMlrtRepo
    if ($mlrtRel -and (Compare-Versions $Global:Config.MlrtVersion $mlrtRel.Tag) -lt 0) {
        $updateHints += "vs-mlrt $($mlrtRel.Tag) disponible (tienes $($Global:Config.MlrtVersion))"
    }
    $vsRel = Get-LatestGithubRelease -Repo $Global:VapourSynthRepo
    if ($vsRel -and (Compare-Versions $Global:Config.VsRelease $vsRel.Tag) -lt 0) {
        $updateHints += "VapourSynth $($vsRel.Tag) disponible (tienes $($Global:Config.VsRelease))"
    }

    while ($true) {
        Clear-Host
        Title "MPV Interpolation Wizard v$($Global:WizardVersion)"
        Write-Host "  GPU: $($Global:Env.GPU)" -ForegroundColor White
        Write-Host "  Backend: $($Global:Env.SupportedBackend)" -ForegroundColor White
        Write-Host "  BaseDir: $($Global:Config.BaseDir)" -ForegroundColor DarkGray

        $st = Detect-Installation
        $statusColor = if ($st.OverallStatus -eq "Instalado y funcional") { "Green" } elseif ($st.OverallStatus -eq "No instalado") { "Gray" } else { "Yellow" }
        Write-Host "  Estado: $($st.OverallStatus)" -ForegroundColor $statusColor
        if ($st.VpyOutdated -and $st.VpyInstalled) {
            Write-Host "  [!] interpolation.vpy v$($st.VpyVersion) - hay template v$($Global:VpyTemplateVersion) (menu Actualizar)" -ForegroundColor Yellow
        }
        if ($st.LuaOutdated -and $st.LuaInstalled) {
            Write-Host "  [!] auto_mode.lua v$($st.LuaVersion) - hay template v$($Global:LuaTemplateVersion) (menu Actualizar)" -ForegroundColor Yellow
        }
        foreach ($h in $updateHints) {
            Write-Host "  [!] $h" -ForegroundColor Yellow
        }
        Write-Host ""

        $options = @(
            "Instalar (primera vez)",
            "Actualizar (nueva version de vs-mlrt o modelos)",
            "Reparar (re-aplicar parches o reinstalar partes)",
            "Diagnostico (ver estado detallado)",
            "Configuracion (rutas)",
            "Desinstalar",
            "Salir"
        )
        $i = Show-Menu -Title "Que quieres hacer?" -Options $options -Footer "GPU: $($Global:Env.GPU)"
        switch ($i) {
            0 { Action-Install }
            1 { Action-Update }
            2 { Action-Repair }
            3 { Action-Diagnose }
            4 { Action-Config }
            5 { Action-Uninstall }
            6 { return }
            -1 { return }
        }
    }
}

Main
