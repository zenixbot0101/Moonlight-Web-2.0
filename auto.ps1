#===============================.txt
#===============================================
# Script Cài Đặt NVIDIA Driver & Các Thành Phần Khác
#===============================================
$ErrorActionPreference = "Stop"

# --- Kiểm tra quyền Quản trị viên ---
Write-Host "Dang kiem tra quyen Quan tri vien..." -ForegroundColor Cyan

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "        LOI: THIEU QUYEN ADMIN" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Script nay YEU CAU quyen Quan tri vien de chay." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Vui long:" -ForegroundColor Cyan
    Write-Host "  1. Nhap chuot phai vao PowerShell" -ForegroundColor White
    Write-Host "  2. Chon 'Chay voi tu cach quan tri vien'" -ForegroundColor White
    Write-Host "  3. Chay lai script nay" -ForegroundColor White
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Exit 1
}

Write-Host "Da xac nhan quyen Quan tri vien. Tiep tuc..." -ForegroundColor Green
Write-Host ""

# --- Chạy Add-AppxPackage và Stop-Process ngay đầu script (cho tất cả OS) ---
Write-Host "Dang chay cac lenh Add-AppxPackage va Stop-Process..." -ForegroundColor Cyan

try {
    Write-Host "  - Dang chay Add-AppxPackage cho MicrosoftWindows.Client.CBS..." -ForegroundColor Gray
    Add-AppxPackage -Register -Path "C:\Windows\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\appxmanifest.xml" -DisableDevelopmentMode -ErrorAction SilentlyContinue
    Write-Host "    Da chay lenh MicrosoftWindows.Client.CBS." -ForegroundColor Green
}
catch {
    Write-Warning "Loi khi chay lenh MicrosoftWindows.Client.CBS: $_"
}

try {
    Write-Host "  - Dang chay Add-AppxPackage cho Microsoft.UI.Xaml.CBS..." -ForegroundColor Gray
    Add-AppxPackage -Register -Path "C:\Windows\SystemApps\Microsoft.UI.Xaml.CBS_8wekyb3d8bbwe\appxmanifest.xml" -DisableDevelopmentMode -ErrorAction SilentlyContinue
    Write-Host "    Da chay lenh Microsoft.UI.Xaml.CBS." -ForegroundColor Green
}
catch {
    Write-Warning "Loi khi chay lenh Microsoft.UI.Xaml.CBS: $_"
}

try {
    Write-Host "  - Dang chay Add-AppxPackage cho MicrosoftWindows.Client.Core..." -ForegroundColor Gray
    Add-AppxPackage -Register -Path "C:\Windows\SystemApps\MicrosoftWindows.Client.Core_cw5n1h2txyewy\appxmanifest.xml" -DisableDevelopmentMode -ErrorAction SilentlyContinue
    Write-Host "    Da chay lenh MicrosoftWindows.Client.Core." -ForegroundColor Green
}
catch {
    Write-Warning "Loi khi chay lenh MicrosoftWindows.Client.Core: $_"
}

try {
    Write-Host "  - Dang dung tien trinh sihost..." -ForegroundColor Gray
    Stop-Process -Name sihost -Force -ErrorAction SilentlyContinue
    Write-Host "    Da dung tien trinh sihost." -ForegroundColor Green
}
catch {
    Write-Warning "Loi khi dung tien trinh sihost: $_"
}

Write-Host "Hoan tat cac lenh dau script." -ForegroundColor Green
Write-Host ""

# --- Cài đặt WinRAR từ file local ---
Write-Host "Buoc 1: Cai dat WinRAR tu file local..." -ForegroundColor Cyan

$WinRarLocalPath = Join-Path -Path $PSScriptRoot -ChildPath "Winrar.exe"

if (Test-Path $WinRarLocalPath) {
    try {
        Write-Host "Tim thay file WinRAR tai: $WinRarLocalPath" -ForegroundColor Gray
        Write-Host "Cai dat WinRAR..." -ForegroundColor Gray
        Start-Process -FilePath $WinRarLocalPath -ArgumentList "/S" -Wait -Verb RunAs
        Write-Host "Cai dat WinRAR hoan tat." -ForegroundColor Green
    } catch {
        Write-Warning "Loi khi cai dat WinRAR: $_"
    }
} else {
    Write-Warning "Khong tim thay file WinRAR.exe trong thu muc script."
}

# --- Cài đặt DirectX từ file local ---
Write-Host "Buoc 2: Cai dat DirectX tu file local..." -ForegroundColor Cyan

$DirectXLocalPath = Join-Path -Path $PSScriptRoot -ChildPath "DX11.exe"

if (Test-Path $DirectXLocalPath) {
    try {
        Write-Host "Tim thay file DirectX tai: $DirectXLocalPath" -ForegroundColor Gray
        Write-Host "Cai dat DirectX..." -ForegroundColor Gray
        
        $DX11Dir = Join-Path -Path $env:TEMP -ChildPath "DX11"
        New-Item -ItemType Directory -Path $DX11Dir -Force
        
        Copy-Item -Path $DirectXLocalPath -Destination $DX11Dir -Force
        
        Set-Location -Path $DX11Dir
        Start-Process -FilePath "DXsetup.exe" -ArgumentList "/silent" -Wait -Verb RunAs
        Write-Host "Cai dat DirectX hoan tat." -ForegroundColor Green
        
        Set-Location -Path $env:TEMP
    } catch {
        Write-Warning "Loi khi cai dat DirectX: $_"
    }
} else {
    Write-Warning "Khong tim thay file DX11.exe trong thu muc script."
}

# --- Cài đặt Visual C++ Redistributable ---
Write-Host "Buoc 3: Cai dat Visual C++ Redistributable..." -ForegroundColor Cyan

$VCRedistLocalPath = Join-Path -Path $PSScriptRoot -ChildPath "vc_redist.x64.exe"
$VCRedistPath = $VCRedistLocalPath

if (-not (Test-Path $VCRedistLocalPath)) {
    Write-Host "Khong tim thay file local, tai tu internet..." -ForegroundColor Gray
    $VCRedistUrl = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
    $VCRedistPath = Join-Path -Path $env:TEMP -ChildPath "vc_redist.x64.exe"
    
    try {
        Write-Host "Tai xuong Visual C++ Redistributable tu: $VCRedistUrl" -ForegroundColor Gray
        $OriginalProgressPreference = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $VCRedistUrl -OutFile $VCRedistPath -UseBasicParsing
        $ProgressPreference = $OriginalProgressPreference
        Write-Host "Tai xuong Visual C++ Redistributable hoan tat." -ForegroundColor Green
    } catch {
        Write-Warning "Loi khi tai Visual C++ Redistributable: $_"
        $VCRedistPath = $null
    }
}

if ($VCRedistPath -and (Test-Path $VCRedistPath)) {
    try {
        Write-Host "Cai dat Visual C++ Redistributable..." -ForegroundColor Gray
        Start-Process -FilePath $VCRedistPath -ArgumentList "/install", "/quiet", "/norestart" -Wait -Verb RunAs
        Write-Host "Cai dat Visual C++ Redistributable hoan tat." -ForegroundColor Green
        
        if ($VCRedistPath -ne $VCRedistLocalPath -and (Test-Path $VCRedistPath)) {
            Remove-Item -Path $VCRedistPath -Force
        }
    } catch {
        Write-Warning "Loi khi cai dat Visual C++ Redistributable: $_"
    }
}

# --- Cài đặt StarDesk từ file local ---
Write-Host "Buoc 4: Cai dat StarDesk tu file local..." -ForegroundColor Cyan

$StarDeskLocalPath = Join-Path -Path $PSScriptRoot -ChildPath "Stardesk.exe"

if (Test-Path $StarDeskLocalPath) {
    try {
        Write-Host "Tim thay file StarDesk tai: $StarDeskLocalPath" -ForegroundColor Gray
        Write-Host "Cai dat StarDesk..." -ForegroundColor Gray
        Start-Process -FilePath $StarDeskLocalPath -ArgumentList "/S" -Wait -Verb RunAs
        Write-Host "Cai dat StarDesk hoan tat." -ForegroundColor Green
    } catch {
        Write-Warning "Loi khi cai dat StarDesk: $_"
    }
} else {
    Write-Warning "Khong tim thay file Stardesk.exe trong thu muc script."
}

# --- Cài đặt IDM từ file local ---
Write-Host "Buoc 5: Cai dat IDM tu file local..." -ForegroundColor Cyan

$IDMLocalPath = Join-Path -Path $PSScriptRoot -ChildPath "IDM.exe"

if (Test-Path $IDMLocalPath) {
    try {
        Write-Host "Tim thay file IDM tai: $IDMLocalPath" -ForegroundColor Gray
        Write-Host "Cai dat IDM..." -ForegroundColor Gray
        Start-Process -FilePath $IDMLocalPath -ArgumentList "/S" -Wait -Verb RunAs
        Write-Host "Cai dat IDM hoan tat." -ForegroundColor Green
    } catch {
        Write-Warning "Loi khi cai dat IDM: $_"
    }
} else {
    Write-Warning "Khong tim thay file IDM.exe trong thu muc script."
}

# --- Cài đặt Steam từ file local ---
Write-Host "Buoc 6: Cai dat Steam tu file local..." -ForegroundColor Cyan

$SteamLocalPath = Join-Path -Path $PSScriptRoot -ChildPath "Steam.exe"

if (Test-Path $SteamLocalPath) {
    try {
        Write-Host "Tim thay file Steam tai: $SteamLocalPath" -ForegroundColor Gray
        Write-Host "Cai dat Steam..." -ForegroundColor Gray
        Start-Process -FilePath $SteamLocalPath -ArgumentList "/S" -Wait -Verb RunAs
        Write-Host "Cai dat Steam hoan tat." -ForegroundColor Green
    } catch {
        Write-Warning "Loi khi cai dat Steam: $_"
    }
} else {
    Write-Warning "Khong tim thay file Steam.exe trong thu muc script."
}

# --- Copy console.bat ra Desktop ---
Write-Host "Buoc 7: Copy console.bat ra Desktop..." -ForegroundColor Cyan

$ConsoleBatLocalPath = Join-Path -Path $PSScriptRoot -ChildPath "console.bat"

if (Test-Path $ConsoleBatLocalPath) {
    try {
        $DesktopPath = [Environment]::GetFolderPath("Desktop")
        $DestPath = Join-Path -Path $DesktopPath -ChildPath "console.bat"
        
        Write-Host "Copy console.bat tu: $ConsoleBatLocalPath" -ForegroundColor Gray
        Write-Host "Den: $DestPath" -ForegroundColor Gray
        
        Copy-Item -Path $ConsoleBatLocalPath -Destination $DestPath -Force
        Write-Host "Da copy console.bat ra Desktop." -ForegroundColor Green
    } catch {
        Write-Warning "Loi khi copy console.bat: $_"
    }
} else {
    Write-Warning "Khong tim thay file console.bat trong thu muc script."
}

# --- Tải và đặt wallpaper ngẫu nhiên ---
Write-Host "Buoc 8: Tai va dat wallpaper ngau nhien..." -ForegroundColor Cyan

$WallpaperUrls = @(
    "https://raw.githubusercontent.com/zenixbot0101/Moonlight-Web-2.0/main/roblox-wallpaper.jpg",
    "https://raw.githubusercontent.com/zenixbot0101/Moonlight-Web-2.0/main/roblox-wallpaper.jpg",
    "https://raw.githubusercontent.com/zenixbot0101/Moonlight-Web-2.0/main/wallpaper11.jpg",
    "https://raw.githubusercontent.com/zenixbot0101/Moonlight-Web-2.0/main/wall1.png",
    "https://raw.githubusercontent.com/zenixbot0101/Moonlight-Web-2.0/main/wall2.png"
)

try {
    $randomIndex = Get-Random -Minimum 0 -Maximum $WallpaperUrls.Count
    $selectedUrl = $WallpaperUrls[$randomIndex]
    
    Write-Host "Dang chon wallpaper ngau nhien: $selectedUrl" -ForegroundColor Gray
    
    $wallpaperPath = Join-Path -Path $env:TEMP -ChildPath "wallpaper.jpg"
    $OriginalProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $selectedUrl -OutFile $wallpaperPath -UseBasicParsing
    $ProgressPreference = $OriginalProgressPreference
    Write-Host "Tai xuong wallpaper hoan tat." -ForegroundColor Green
    
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.SystemInformation]::VirtualScreen
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\wallpaper.lnk")
    $shortcut.TargetPath = "rundll32.exe"
    $shortcut.Arguments = "user32.dll,UpdatePerUserSystemParameters"
    $shortcut.Save()
    
    $regPath = "HKCU:\Control Panel\Desktop"
    Set-ItemProperty -Path $regPath -Name Wallpaper -Value $wallpaperPath
    Set-ItemProperty -Path $regPath -Name WallpaperStyle -Value 2
    Set-ItemProperty -Path $regPath -Name TileWallpaper -Value 0
    
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.SystemInformation]::VirtualScreen
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
    
    $sig = @"
[DllImport("user32.dll", SetLastError = true)]
public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
"@
    
    $SPI_SETDESKWALLPAPER = 20
    $SPIF_UPDATEINIFILE = 0x01
    $SPIF_SENDCHANGE = 0x02
    
    $setWallpaper = Add-Type -MemberDefinition $sig -Name "Win32" -Namespace "Win32" -PassThru
    $setWallpaper::SystemParametersInfo($SPI_SETDESKWALLPAPER, 0, $wallpaperPath, ($SPIF_UPDATEINIFILE -bor $SPIF_SENDCHANGE))
    
    Write-Host "Da dat wallpaper thanh cong." -ForegroundColor Green
    
    Remove-Item -Path $wallpaperPath -Force
} catch {
    Write-Warning "Loi khi tai hoac dat wallpaper: $_"
}

# --- Tắt tất cả các cổng Windows ---
Write-Host "Buoc 9: Tat tat ca cac cong Windows..." -ForegroundColor Cyan

try {
    Write-Host "Tat tat ca cac cong Windows (firewall)..." -ForegroundColor Gray
    netsh advfirewall set allprofiles state off
    Write-Host "Da tat tat ca cac cong Windows." -ForegroundColor Green
} catch {
    Write-Warning "Loi khi tat cong Windows: $_"
}

# --- Tắt Windows Defender ---
Write-Host "Buoc 10: Tat Windows Defender..." -ForegroundColor Cyan

try {
    Write-Host "Tat Windows Defender..." -ForegroundColor Gray
    Stop-Service -Name "Windows Defender Service" -Force -ErrorAction SilentlyContinue
    Set-Service -Name "Windows Defender Service" -StartupType Disabled
    
    Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False
    
    Set-MpPreference -DisableRealtimeMonitoring $true
    
    Write-Host "Da tat Windows Defender." -ForegroundColor Green
} catch {
    Write-Warning "Loi khi tat Windows Defender: $_"
}

# --- Cài đặt NVIDIA Driver ---
Write-Host "Buoc 11: Cai dat NVIDIA Driver..." -ForegroundColor Cyan

$Drivers = @{
    "Normal" = @{
        "Filename" = "582.53_grid_win10_win11_server2022_server_2025_dch_64bit_international.exe"
        "Hash"     = "6f1210b459efc7f29db930103533c3de9b93c2afdfa8d7b4871640c6b8638c0b"
    }
    "vGPU"   = @{
        "Filename" = "582.53_grid_win10_win11_server2022_server2025_dch_64bit_international_gcp_swl.exe"
        "Hash"     = "8e8689db080a0807cd9efae2368dc1971a60e66fd7defdb5f1c5025fdb0e0ced"
    }
}

$TempDir = [System.IO.Path]::GetTempPath()
$InstallerName = "nvidia_driver_installer.exe"
$InstallerPath = Join-Path -Path $TempDir -ChildPath $InstallerName

$ApolloUrl = "https://github.com/ClassicOldSong/Apollo/releases/download/v0.4.6/Apollo-0.4.6.exe"
$ApolloInstallerName = "Apollo-0.4.6.exe"
$ApolloInstallerPath = Join-Path -Path $TempDir -ChildPath $ApolloInstallerName

function Get-GcpMultiRegion {
    $RegionMap = @{
        "africa"       = "eu"
        "asia"         = "asia"
        "australia"    = "asia"
        "europe"       = "eu"
        "me"           = "eu"
        "northamerica" = "us"
        "southamerica" = "us"
        "us"           = "us"
    }

    Write-Host "Dang phat hien vung GCP..." -ForegroundColor Cyan

    try {
        $ZoneUrl = "http://metadata.google.internal/computeMetadata/v1/instance/zone"
        $Response = Invoke-RestMethod -Uri $ZoneUrl -Headers @{"Metadata-Flavor" = "Google"} -TimeoutSec 5 -ErrorAction Stop

        $ZoneName = $Response.Split('/')[-1]
        $RegionPrefix = $ZoneName.Split('-')[0]

        if ($RegionMap.ContainsKey($RegionPrefix)) {
            $MultiRegion = $RegionMap[$RegionPrefix]
            Write-Host "Da phat hien vung: $RegionPrefix -> Da vung: $MultiRegion" -ForegroundColor Green
            return $MultiRegion
        }
    }
    catch {
        Write-Warning "Khong the phat hien vung GCP qua may chu metadata. Mac dinh la 'us'."
    }

    return "us"
}

function Get-MachineType {
    try {
        Write-Host "Dang phat hien loai may..." -ForegroundColor Cyan
        
        $MachineTypeUrl = "http://metadata.google.internal/computeMetadata/v1/instance/machine-type"
        $Response = Invoke-RestMethod -Uri $MachineTypeUrl -Headers @{"Metadata-Flavor" = "Google"} -TimeoutSec 5 -ErrorAction Stop
        
        $MachineType = $Response.Split('/')[-1]
        Write-Host "Da phat hien loai may: $MachineType" -ForegroundColor Green
        
        if ($MachineType -in ('g4-standard-6', 'g4-standard-12', 'g4-standard-24')) {
            return "vGPU"
        }
        
        $InstanceUrl = "http://metadata.google.internal/computeMetadata/v1/instance/"
        $Response = Invoke-RestMethod -Uri $InstanceUrl -Headers @{"Metadata-Flavor" = "Google"} -TimeoutSec 5 -ErrorAction Stop
        
        if ($Response -like "*nvidia-grid-license*") {
            return "Normal" 
        }
    }
    catch {
        Write-Warning "Khong the phat hien loai may qua may chu metadata. Mac dinh la 'Normal'."
    }
    return "Normal"
}

function Get-Mgmt-Command {
    $Command = 'Get-CimInstance'
    if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
        $Command = 'Get-WmiObject'
    }
    return $Command
}

function Find-GPU {
    $MgmtCommand = Get-Mgmt-Command
    try {
        $Command = "(${MgmtCommand} -query ""select DeviceID from Win32_PNPEntity Where (deviceid Like '%PCI\\VEN_10DE%') and (PNPClass = 'Display' or Name = '3D Video Controller')"" | Select-Object DeviceID -ExpandProperty DeviceID).substring(13,8)"
        $dev_id = Invoke-Expression -Command $Command
        return $dev_id
    }
    catch {
        Write-Warning "Duong nhu khong co GPU nao duoc ket noi voi he thong cua ban."
        return ""
    }
}

$MultiRegion = Get-GcpMultiRegion
$MachineType = Get-MachineType

$DriverInfo = $Drivers[$MachineType]
$DriverVersionFilename = $DriverInfo["Filename"]
$ExpectedSha256 = $DriverInfo["Hash"]

$DriverUrl = "https://storage.googleapis.com/compute-gpu-installation-$MultiRegion/windows/$DriverVersionFilename"

Write-Host "Buoc 1: Dang kiem tra GPU NVIDIA (Kiem tra PCI ID)..." -ForegroundColor Cyan

$gpuId = Find-GPU

if ([string]::IsNullOrWhiteSpace($gpuId)) {
    Write-Warning "Khong phat hien GPU NVIDIA (VEN_10DE) qua kiem tra PnP Entity. Dang thoat."
    Exit
} else {
    Write-Host "Da phat hien GPU voi chuoi Device ID: $gpuId" -ForegroundColor Green
}

Write-Host "Buoc 2: Dang kiem tra cai dat hien co (nvidia-smi)..." -ForegroundColor Cyan

$smiCommand = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
$smiPathDefault = "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
$smiPathSystem = "C:\Windows\System32\nvidia-smi.exe"

if ($smiCommand -or (Test-Path $smiPathDefault) -or (Test-Path $smiPathSystem)) {
    Write-Warning "nvidia-smi da ton tai. Driver duong nhu da duoc cai dat. Dang thoat."
    Exit
} else {
    Write-Host "Khong tim thay nvidia-smi. Tien hanh cai dat." -ForegroundColor Green
}

Write-Host "Buoc 3: Dang tai xuong driver..." -ForegroundColor Cyan
Write-Host "Nguon: $DriverUrl" -ForegroundColor Gray

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    $OriginalProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    Invoke-WebRequest -Uri $DriverUrl -OutFile $InstallerPath -UseBasicParsing

    $ProgressPreference = $OriginalProgressPreference

    Write-Host "Tai xuong hoan tat. Da luu tai: $InstallerPath" -ForegroundColor Green

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        Write-Host "Dang xac minh checksum SHA256..." -ForegroundColor Cyan
        $ComputedHash = (Get-FileHash -Path $InstallerPath -Algorithm SHA256).Hash

        if ($ComputedHash -eq $ExpectedSha256) {
            Write-Host "Checksum da duoc xac minh." -ForegroundColor Green
        } else {
            Remove-Item -Path $InstallerPath -Force
            Write-Error "Checksum khong khop! Du kien: $ExpectedSha256, Tinh toan: $ComputedHash"
            Exit
        }
    }
}
catch {
    Write-Error "Khong the tai xuong hoac xac minh trinh cai dat. Loi: $_"
    Exit
}

Write-Host "Buoc 4: Dang thuc thi trinh cai dat..." -ForegroundColor Cyan
Write-Host "Co su dung: /s /n (Am tham, Khong khoi dong lai)" -ForegroundColor Gray

try {
    $process = Start-Process -FilePath $InstallerPath -ArgumentList "/s", "/n" -PassThru -Wait -Verb RunAs

    if ($process.ExitCode -eq 0) {
        Write-Host "Cai dat hoan tat thanh cong." -ForegroundColor Green
    } else {
        Write-Warning "Cai dat hoan tat voi ma thoat: $($process.ExitCode). Dieu nay co the cho thay can khoi dong lai hoac canh bao khong nghiem trong."
    }
}
catch {
    Write-Error "Khong the thuc thi trinh cai dat. Loi: $_"
    Exit
}

Write-Host "Dang don dep cac tep tam thoi..." -ForegroundColor Cyan
if (Test-Path $InstallerPath) {
    Remove-Item -Path $InstallerPath -Force
}

Write-Host ""
Write-Host "Buoc 5: Dang cau hinh va khoi dong dich vu am thanh..." -ForegroundColor Cyan

try {
    Write-Host "  - Cau hinh Audiosrv (Windows Audio)..." -ForegroundColor Gray
    $audiosrv = sc.exe config Audiosrv start= auto
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    Da cau hinh Audiosrv thanh cong." -ForegroundColor Green
    } else {
        Write-Warning "    Khong the cau hinh Audiosrv. Ma loi: $LASTEXITCODE"
    }

    Write-Host "  - Khoi dong Audiosrv (Windows Audio)..." -ForegroundColor Gray
    $startAudiosrv = net start Audiosrv
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    Da khoi dong Audiosrv thanh cong." -ForegroundColor Green
    } else {
        Write-Warning "    Khong the khoi dong Audiosrv. Ma loi: $LASTEXITCODE"
    }

    Write-Host "  - Cau hinh AudioEndpointBuilder..." -ForegroundColor Gray
    $audioEndpoint = sc.exe config AudioEndpointBuilder start= auto
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    Da cau hinh AudioEndpointBuilder thanh cong." -ForegroundColor Green
    } else {
        Write-Warning "    Khong the cau hinh AudioEndpointBuilder. Ma loi: $LASTEXITCODE"
    }

    Write-Host "  - Khoi dong AudioEndpointBuilder..." -ForegroundColor Gray
    $startAudioEndpoint = net start AudioEndpointBuilder
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    Da khoi dong AudioEndpointBuilder thanh cong." -ForegroundColor Green
    } else {
        Write-Warning "    Khong the khoi dong AudioEndpointBuilder. Ma loi: $LASTEXITCODE"
    }

    Write-Host "Hoan tat cau hinh dich vu am thanh." -ForegroundColor Green
}
catch {
    Write-Warning "Da xay ra loi khi cau hinh dich vu am thanh: $_"
}

Write-Host ""
Write-Host "Buoc 6: Cai dat Apollo tu file local..." -ForegroundColor Cyan

$ApolloLocalPath = Join-Path -Path $PSScriptRoot -ChildPath "Apollo-0.4.6.exe"

if (Test-Path $ApolloLocalPath) {
    try {
        Write-Host "Tim thay file Apollo tai: $ApolloLocalPath" -ForegroundColor Gray
        Write-Host "Dang cai dat Apollo (che do am tham)..." -ForegroundColor Gray
        $apolloProcess = Start-Process -FilePath $ApolloLocalPath -ArgumentList "/S" -PassThru -Wait -Verb RunAs

        if ($apolloProcess.ExitCode -eq 0) {
            Write-Host "Cai dat Apollo thanh cong." -ForegroundColor Green
        } else {
            Write-Warning "Cai dat Apollo hoan tat voi ma thoat: $($apolloProcess.ExitCode)."
        }
    } catch {
        Write-Warning "Loi khi cai dat Apollo: $_"
    }
} else {
    Write-Warning "Khong tim thay file Apollo-0.4.6.exe trong thu muc script. Dang tai tu internet..."
    
    try {
        Write-Host "  - Dang tai Apollo tu: $ApolloUrl" -ForegroundColor Gray
        
        $OriginalProgressPreference = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        
        Invoke-WebRequest -Uri $ApolloUrl -OutFile $ApolloInstallerPath -UseBasicParsing
        
        $ProgressPreference = $OriginalProgressPreference
        
        Write-Host "    Da tai xuong: $ApolloInstallerPath" -ForegroundColor Green

        Write-Host "  - Dang cai dat Apollo (che do am tham)..." -ForegroundColor Gray
        $apolloProcess = Start-Process -FilePath $ApolloInstallerPath -ArgumentList "/S" -PassThru -Wait -Verb RunAs

        if ($apolloProcess.ExitCode -eq 0) {
            Write-Host "    Cai dat Apollo thanh cong." -ForegroundColor Green
        } else {
            Write-Warning "    Cai dat Apollo hoan tat voi ma thoat: $($apolloProcess.ExitCode)."
        }

        if (Test-Path $ApolloInstallerPath) {
            Remove-Item -Path $ApolloInstallerPath -Force
            Write-Host "  - Da don dep file cai dat Apollo." -ForegroundColor Gray
        }
    } catch {
        Write-Warning "Khong the tai hoac cai dat Apollo. Loi: $_"
    }
}

Write-Host ""
Write-Host "Buoc 7: Tu dong chay Apollo..." -ForegroundColor Cyan

try {
    $apolloPath = "C:\Program Files\Apollo\Apollo.exe"
    if (Test-Path $apolloPath) {
        Write-Host "Dang chay Apollo..." -ForegroundColor Gray
        Start-Process -FilePath $apolloPath -Verb RunAs
        Write-Host "Da chay Apollo thanh cong." -ForegroundColor Green
    } else {
        Write-Warning "Khong tim thay Apollo de chay. Co the Apollo chua duoc cai dat hoac duong dan khong dung."
    }
}
catch {
    Write-Warning "Khong the chay Apollo. Loi: $_"
}

Write-Host ""
Write-Host "Buoc 8: Khoi dong lai he thong..." -ForegroundColor Cyan

try {
    Write-Host "Dang khoi dong lai he thong sau 0 giay..." -ForegroundColor Gray
    shutdown /r /t 0
    Write-Host "Da bat dau qua trinh khoi dong lai." -ForegroundColor Green
}
catch {
    Write-Warning "Khong the khoi dong lai he thong: $_"
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "        CAI DAT HOAN TAT" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "✓ Add-AppxPackage da duoc chay" -ForegroundColor White
Write-Host "✓ Tien trinh sihost da duoc dung" -ForegroundColor White
Write-Host "✓ WinRAR da duoc cai dat" -ForegroundColor White
Write-Host "✓ DirectX Jun2010 da duoc cai dat" -ForegroundColor White
Write-Host "✓ Visual C++ Redistributable da duoc cai dat" -ForegroundColor White
Write-Host "✓ StarDesk da duoc cai dat" -ForegroundColor White
Write-Host "✓ IDM da duoc cai dat" -ForegroundColor White
Write-Host "✓ Steam da duoc cai dat" -ForegroundColor White
Write-Host "✓ console.bat da duoc copy ra Desktop" -ForegroundColor White
Write-Host "✓ Wallpaper da duoc dat" -ForegroundColor White
Write-Host "✓ Tat ca cong Windows da bi tat" -ForegroundColor White
Write-Host "✓ Windows Defender da bi tat" -ForegroundColor White
Write-Host "✓ Driver NVIDIA da duoc cai dat" -ForegroundColor White
Write-Host "✓ Dich vu am thanh da duoc cau hinh va khoi dong" -ForegroundColor White
Write-Host "✓ Apollo da duoc cai dat" -ForegroundColor White
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
