$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

$mimeMap = @{
  ".html"  = "text/html; charset=utf-8"
  ".js"    = "text/javascript; charset=utf-8"
  ".css"   = "text/css; charset=utf-8"
  ".svg"   = "image/svg+xml"
  ".png"   = "image/png"
  ".jpg"   = "image/jpeg"
  ".ico"   = "image/x-icon"
  ".json"  = "application/json"
  ".woff"  = "font/woff"
  ".woff2" = "font/woff2"
}

function Test-KnownVpnAddress([string]$ip) {
  # Hamachi (25.x) and Radmin VPN (26.x) hand out addresses in these ranges -
  # they are never a real home Wi-Fi/LAN address, so we hide them from the list.
  return ($ip -like "25.*" -or $ip -like "26.*")
}

function Get-LanAddresses {
  $ips = @()
  try {
    # Prefer adapters that actually have a default gateway - this reliably
    # picks the real Wi-Fi/Ethernet connection and skips most virtual adapters.
    $ips = Get-NetIPConfiguration -ErrorAction Stop |
      Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" } |
      ForEach-Object { $_.IPv4Address.IPAddress } |
      Where-Object { $_ -and $_ -ne "127.0.0.1" -and $_ -notlike "169.254.*" } |
      Select-Object -Unique
  } catch {}

  if (-not $ips -or $ips.Count -eq 0) {
    try {
      $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object {
          $_.IPAddress -ne "127.0.0.1" -and
          $_.IPAddress -notlike "169.254.*" -and
          $_.PrefixOrigin -ne "WellKnown"
        } |
        Select-Object -ExpandProperty IPAddress -Unique
    } catch {
      try {
        $hostName = [System.Net.Dns]::GetHostName()
        $ips = [System.Net.Dns]::GetHostAddresses($hostName) |
          Where-Object { $_.AddressFamily -eq "InterNetwork" -and $_.ToString() -ne "127.0.0.1" } |
          ForEach-Object { $_.ToString() }
      } catch {}
    }
  }

  $ips = $ips | Where-Object { -not (Test-KnownVpnAddress $_) }

  # Typical home routers hand out 192.168.x.x - show those first.
  # Addresses ending in ".1" are almost always a gateway/virtual adapter, not
  # this computer's own address, so they are shown last.
  $ips = $ips | Sort-Object -Property @(
    @{ Expression = { if ($_ -like "192.168.*") { 0 } elseif ($_ -like "10.*") { 1 } else { 2 } } },
    @{ Expression = { if ($_ -like "*.1") { 1 } else { 0 } } }
  )

  return $ips
}

function Send-HttpResponse {
  param($Stream, [byte[]]$Bytes, [string]$ContentType, [int]$StatusCode = 200, [string]$StatusText = "OK")
  $header = "HTTP/1.1 $StatusCode $StatusText`r`nContent-Type: $ContentType`r`nContent-Length: $($Bytes.Length)`r`nConnection: close`r`nCache-Control: no-cache`r`nAccess-Control-Allow-Origin: *`r`n`r`n"
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
  $Stream.Write($headerBytes, 0, $headerBytes.Length)
  if ($Bytes.Length -gt 0) { $Stream.Write($Bytes, 0, $Bytes.Length) }
  $Stream.Flush()
}

try {
  $port = 5391
  $listener = $null
  for ($attempt = 0; $attempt -lt 25; $attempt++) {
    try {
      $candidate = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $port)
      $candidate.Start()
      $listener = $candidate
      break
    } catch {
      $port++
    }
  }

  if (-not $listener) {
    throw "Не удалось найти свободный порт для запуска сервера."
  }

  $localUrl = "http://localhost:$port/"
  $lanIps = Get-LanAddresses

  Clear-Host
  Write-Host ""
  Write-Host "  ================================================" -ForegroundColor DarkYellow
  Write-Host "   Capitalis - Финансовый симулятор запущен" -ForegroundColor Yellow
  Write-Host "  ================================================" -ForegroundColor DarkYellow
  Write-Host ""
  Write-Host "  На этом компьютере:" -ForegroundColor White
  Write-Host "    $localUrl" -ForegroundColor Cyan
  Write-Host ""
  if ($lanIps -and $lanIps.Count -gt 0) {
    Write-Host "  На телефоне/планшете (тот же Wi-Fi, напр. iPhone):" -ForegroundColor White
    $first = $true
    foreach ($ip in $lanIps) {
      $suffix = if ($first) { "  <- попробуйте этот" } else { "" }
      Write-Host "    http://${ip}:$port/$suffix" -ForegroundColor Green
      $first = $false
    }
    Write-Host ""
    Write-Host "  Откройте этот адрес в Safari на iPhone. Компьютер" -ForegroundColor DarkGray
    Write-Host "  и телефон должны быть подключены к одной сети Wi-Fi." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Если телефон не может подключиться - разрешите" -ForegroundColor DarkGray
    Write-Host "  доступ в окне 'Брандмауэр Windows', которое может" -ForegroundColor DarkGray
    Write-Host "  появиться при первом запуске." -ForegroundColor DarkGray
  } else {
    Write-Host "  Не удалось определить адрес в локальной сети Wi-Fi." -ForegroundColor DarkGray
    Write-Host "  Приложение доступно только на этом компьютере." -ForegroundColor DarkGray
  }
  Write-Host ""
  Write-Host "  Закройте это окно, чтобы остановить сервер." -ForegroundColor DarkGray
  Write-Host ""

  try { Start-Process $localUrl } catch {}

  try {
    while ($true) {
      $client = $listener.AcceptTcpClient()
      try {
        $stream = $client.GetStream()
        $buffer = New-Object byte[] 16384
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { continue }

        $requestText = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
        $requestLine = ($requestText -split "`r`n")[0]
        $parts = $requestLine -split " "
        $rawPath = if ($parts.Length -ge 2) { $parts[1] } else { "/" }
        $path = $rawPath -replace "\?.*$", ""
        $relPath = [System.Uri]::UnescapeDataString($path.TrimStart("/"))
        if ([string]::IsNullOrWhiteSpace($relPath)) { $relPath = "index.html" }

        $filePath = Join-Path $root $relPath
        $fullRoot = (Resolve-Path $root).Path
        $isInsideRoot = $false
        if (Test-Path $filePath -PathType Leaf) {
          $fullFile = (Resolve-Path $filePath).Path
          $isInsideRoot = $fullFile.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)
        }

        if (-not $isInsideRoot) {
          $filePath = Join-Path $root "index.html"
        }

        $ext = [System.IO.Path]::GetExtension($filePath)
        $contentType = $mimeMap[$ext]
        if (-not $contentType) { $contentType = "application/octet-stream" }

        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        Send-HttpResponse -Stream $stream -Bytes $bytes -ContentType $contentType
      } catch {
      } finally {
        $client.Close()
      }
    }
  } finally {
    $listener.Stop()
  }
} catch {
  Write-Host ""
  Write-Host "  Не удалось запустить сервер Capitalis." -ForegroundColor Red
  Write-Host "  Причина: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host ""
  Read-Host "  Нажмите Enter, чтобы закрыть окно"
  exit 1
}
