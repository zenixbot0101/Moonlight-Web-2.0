<#
.SYNOPSIS
    GCP Windows Startup Script - tu dong doi DNS suffix/domain noi bo (Primary DNS Suffix,
    Connection-specific suffix, DNS Search List, TCP/IP registry, hosts file).

.DESCRIPTION
    Dùng làm nội dung cho metadata key "windows-startup-script-ps1" của một Compute Engine
    Windows VM. Script chạy dưới quyền SYSTEM ở mỗi lần boot, nên được thiết kế IDEMPOTENT:
      - Lần đầu boot: phát hiện domain chưa đúng -> áp dụng thay đổi -> ghi marker vào registry
        -> lên lịch restart 1 lần (delay 15s) để mọi thứ (Primary DNS Suffix, Task Manager...)
        hiển thị đúng ngay từ lần logon kế tiếp.
      - Các lần boot sau: phát hiện marker đã khớp domain hiện tại -> BỎ QUA, không làm gì,
        không restart. Nhờ vậy VM không bị reboot loop mỗi lần khởi động.

    Toàn bộ log được ghi vào C:\ProgramData\AztuCloud-DNS.log VÀ in ra stdout, vì GCP chuyển
    tiếp stdout của startup script vào Serial Port Output (COM1) - xem được từ xa bằng:

        gcloud compute instances get-serial-port-output INSTANCE_NAME --zone=ZONE

.NOTES
    - Không dùng param() vì GCP không truyền argument cho startup script. Chỉnh biến $NewDomain
      / $NewComputerName ở phần CONFIG bên dưới trước khi đưa vào metadata.
    - Nếu muốn đổi cả Computer Name, lưu ý Rename-Computer cũng cần restart - script đã gộp
      chung vào 1 lần restart duy nhất với phần đổi DNS.
#>

# ================== CONFIG - CHỈNH TRƯỚC KHI DÙNG ==================
$NewDomain        = "aztucloudnetwork.com"   # domain suffix muốn áp dụng
$NewComputerName  = ""                        # để trống nếu không muốn đổi tên máy
$RestartDelaySec  = 15                        # delay trước khi restart (giây)
$AdapterWaitMax   = 60                        # số giây tối đa chờ NIC lên "Up" lúc boot
# =====================================================================

$LogPath    = "C:\ProgramData\AztuCloud-DNS.log"
$MarkerPath = "HKLM:\SOFTWARE\AztuCloud\DnsStartup"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Output $line              # -> đi vào GCP Serial Port Output
    Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force -ErrorAction SilentlyContinue | Out-Null
Write-Log "===== GCP Startup Script: kiem tra DNS domain ====="

# --- 0. Idempotency check: da ap dung dung domain nay chua? ---
try {
    $marker = Get-ItemProperty -Path $MarkerPath -ErrorAction Stop
    if ($marker.AppliedDomain -eq $NewDomain -and $marker.AppliedComputerName -eq $env:COMPUTERNAME) {
        Write-Log "Domain '$NewDomain' da duoc ap dung truoc do cho may '$env:COMPUTERNAME'. Bo qua, khong lam gi them."
        exit 0
    }
}
catch {
    Write-Log "Chua co marker -> day la lan chay dau tien, se tien hanh ap dung."
}

# --- 1. Cho network adapter san sang (luc boot NIC co the chua Up ngay) ---
$adapter = $null
$waited = 0
while (-not $adapter -and $waited -lt $AdapterWaitMax) {
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
    if (-not $adapter) {
        Start-Sleep -Seconds 3
        $waited += 3
    }
}
if (-not $adapter) {
    Write-Log "LOI: Khong tim thay adapter nao 'Up' sau $AdapterWaitMax giay. Dung, se thu lai o lan boot ke tiep."
    exit 1
}
$InterfaceAlias = $adapter.Name
Write-Log "Adapter san sang: $InterfaceAlias"

# --- 2. Lay cau hinh IP hien tai ---
$ipConfig = Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -in @("Dhcp","Manual") } | Select-Object -First 1
if (-not $ipConfig) {
    Write-Log "LOI: Khong lay duoc IPv4 tren $InterfaceAlias. Dung."
    exit 1
}
$currentIP    = $ipConfig.IPAddress
$prefixLength = $ipConfig.PrefixLength
$gatewayObj   = Get-NetRoute -InterfaceAlias $InterfaceAlias -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -First 1
$currentGW    = if ($gatewayObj) { $gatewayObj.NextHop } else { $null }
$dnsServers   = (Get-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4).ServerAddresses

Write-Log "IP hien tai: $currentIP/$prefixLength | Gateway: $currentGW | DNS: $($dnsServers -join ', ')"

# --- 3. Chuyen sang static IP (giu nguyen thong so) de DHCP cua GCP khong ghi de DNS suffix ---
try {
    Set-NetIPInterface -InterfaceAlias $InterfaceAlias -Dhcp Disabled -ErrorAction SilentlyContinue

    $existing = Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($existing) { $existing | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue }

    $existingRoutes = Get-NetRoute -InterfaceAlias $InterfaceAlias -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
    if ($existingRoutes) { $existingRoutes | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue }

    if ($currentGW) {
        New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $currentIP -PrefixLength $prefixLength -DefaultGateway $currentGW | Out-Null
    } else {
        New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $currentIP -PrefixLength $prefixLength | Out-Null
    }
    if ($dnsServers -and $dnsServers.Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $dnsServers
    }
    Write-Log "Da chuyen '$InterfaceAlias' sang static IP (DHCP disabled)."
}
catch {
    Write-Log "LOI khi set static IP: $($_.Exception.Message)"
}

# --- 4. Connection-specific DNS suffix ---
try {
    Set-DnsClient -InterfaceAlias $InterfaceAlias -ConnectionSpecificSuffix $NewDomain -RegisterThisConnectionsAddress $true -UseSuffixWhenRegistering $true
    Write-Log "Da set Connection-specific DNS suffix = $NewDomain"
}
catch { Write-Log "LOI connection-specific suffix: $($_.Exception.Message)" }

# --- 5. DNS Suffix Search List toan cuc ---
try {
    Set-DnsClientGlobalSetting -SuffixSearchList @($NewDomain)
    Write-Log "Da set DNS Suffix Search List = $NewDomain"
}
catch { Write-Log "LOI suffix search list: $($_.Exception.Message)" }

# --- 6. Primary DNS Suffix (registry global) ---
try {
    $tcpipParamsPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
    Set-ItemProperty -Path $tcpipParamsPath -Name "Domain" -Value $NewDomain -Force
    Set-ItemProperty -Path $tcpipParamsPath -Name "NV Domain" -Value $NewDomain -Force
    Set-ItemProperty -Path $tcpipParamsPath -Name "SearchList" -Value $NewDomain -Force
    New-ItemProperty -Path $tcpipParamsPath -Name "DhcpDomain" -Value $NewDomain -PropertyType String -Force | Out-Null
    Write-Log "Da set Primary DNS suffix (registry global) = $NewDomain"
}
catch { Write-Log "LOI registry global TCP/IP Domain: $($_.Exception.Message)" }

# --- 7. Registry per-interface ---
try {
    $guid = $adapter.InterfaceGuid
    $ifPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
    if (Test-Path $ifPath) {
        Set-ItemProperty -Path $ifPath -Name "Domain" -Value $NewDomain -Force
        Set-ItemProperty -Path $ifPath -Name "SearchList" -Value $NewDomain -Force -ErrorAction SilentlyContinue
        New-ItemProperty -Path $ifPath -Name "DhcpDomain" -Value $NewDomain -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Log "Da set registry per-interface ($guid) = $NewDomain"
    }
}
catch { Write-Log "LOI registry per-interface: $($_.Exception.Message)" }

# --- 8. hosts file ---
try {
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $hostName  = if ([string]::IsNullOrWhiteSpace($NewComputerName)) { $env:COMPUTERNAME } else { $NewComputerName }
    $fqdn      = "$hostName.$NewDomain"
    $hostsContent = Get-Content $hostsPath -ErrorAction SilentlyContinue
    $filtered = $hostsContent | Where-Object { $_ -notmatch [regex]::Escape($fqdn) -and $_ -notmatch "^\s*$([regex]::Escape($currentIP))\s" }
    $newLine = "$currentIP`t$fqdn`t$hostName"
    $filtered + $newLine | Set-Content -Path $hostsPath -Encoding ASCII
    Write-Log "Da cap nhat hosts: $currentIP -> $fqdn"
}
catch { Write-Log "LOI hosts file: $($_.Exception.Message)" }

# --- 9. (Tuy chon) doi Computer Name ---
$needComputerRename = $false
if (-not [string]::IsNullOrWhiteSpace($NewComputerName) -and $NewComputerName -ne $env:COMPUTERNAME) {
    try {
        Rename-Computer -NewName $NewComputerName -Force -ErrorAction Stop
        Write-Log "Da doi Computer Name thanh: $NewComputerName (ap dung sau restart)"
        $needComputerRename = $true
    }
    catch { Write-Log "LOI doi Computer Name: $($_.Exception.Message)" }
}

# --- 10. Flush DNS ---
try {
    Clear-DnsClientCache
    ipconfig /flushdns | Out-Null
    Write-Log "Da flush DNS cache."
}
catch { Write-Log "LOI flush DNS: $($_.Exception.Message)" }

# --- 11. Ghi marker de lan boot sau khong lam lai (chi ghi SAU khi da thu ap dung xong) ---
try {
    New-Item -Path $MarkerPath -Force | Out-Null
    Set-ItemProperty -Path $MarkerPath -Name "AppliedDomain" -Value $NewDomain -Force
    $finalComputerName = if ($needComputerRename) { $NewComputerName } else { $env:COMPUTERNAME }
    Set-ItemProperty -Path $MarkerPath -Name "AppliedComputerName" -Value $finalComputerName -Force
    Set-ItemProperty -Path $MarkerPath -Name "AppliedAt" -Value (Get-Date -Format "s") -Force
    Write-Log "Da ghi marker registry ($MarkerPath) de tranh chay lai o lan boot ke tiep."
}
catch { Write-Log "LOI ghi marker: $($_.Exception.Message)" }

# --- 12. Restart 1 lan duy nhat de ap dung day du (Primary DNS Suffix / Task Manager) ---
Write-Log "===== Hoan tat ap dung. Se restart sau $RestartDelaySec giay de ap dung day du. ====="
shutdown.exe /r /t $RestartDelaySec /c "AztuCloud DNS startup script: applying DNS suffix, restarting once" /f
exit 0
