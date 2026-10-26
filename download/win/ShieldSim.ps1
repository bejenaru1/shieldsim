# ShieldSim for Windows: launcher, updater and installer of the local AI (Nova).
#
#   ShieldSim.ps1              start: offer the update if there is one, start Ollama, serve the site
#                              on http://127.0.0.1:5190 and open the browser
#   ShieldSim.ps1 -Install     first install (run by "Instaleaza ShieldSim.cmd")
#   ShieldSim.ps1 -Uninstall   remove ShieldSim (Ollama itself is kept)
#
# Everything goes to %LOCALAPPDATA%\ShieldSim; no administrator rights are needed.
# The files come from the ShieldSim site (download/manifest.json lists them, with SHA-256).
# Windows PowerShell 5.1 compatible. Source: artifacts/space-shield-sim/installer/windows/.
param([switch]$Install, [switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'          # Invoke-WebRequest is much faster without the progress bar
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
Add-Type -AssemblyName System.Windows.Forms

$SiteUrl   = 'https://bejenaru1.github.io/shieldsim/'
$Dir       = Join-Path $env:LOCALAPPDATA 'ShieldSim'
$SiteDir   = Join-Path $Dir 'site'
$StateFile = Join-Path $Dir 'installed.json'
$ConfFile  = Join-Path $Dir 'config.json'
$Port      = 5190
$AppUrl    = "http://127.0.0.1:$Port/"
$OllamaApi = 'http://127.0.0.1:11434'
$Host.UI.RawUI.WindowTitle = 'ShieldSim'

function Say([string]$m) { Write-Host "[ShieldSim] $m" }
function Warn([string]$m) { Write-Host "[ShieldSim] $m" -ForegroundColor Yellow }
function New-Owner { $f = New-Object System.Windows.Forms.Form; $f.TopMost = $true; return $f }   # keeps dialogs above the console
function Ask([string]$text) {
  $o = New-Owner
  $r = [System.Windows.Forms.MessageBox]::Show($o, $text, 'ShieldSim', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
  $o.Dispose()
  return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}
function Tell([string]$text, [string]$icon) {
  $o = New-Owner
  [System.Windows.Forms.MessageBox]::Show($o, $text, 'ShieldSim', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::$icon) | Out-Null
  $o.Dispose()
}
function Read-JsonFile([string]$p) { if (Test-Path $p) { return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json) } return $null }
function Write-JsonFile([string]$p, $o) { $o | ConvertTo-Json -Depth 6 | Set-Content -Path $p -Encoding UTF8 }
function Get-Manifest {
  try { return (Invoke-WebRequest -UseBasicParsing -Uri ($SiteUrl + 'download/manifest.json') -TimeoutSec 6).Content | ConvertFrom-Json }
  catch { return $null }
}
function Get-Sha([string]$p) { if (Test-Path $p) { return (Get-FileHash -Algorithm SHA256 -Path $p).Hash.ToLower() } return '' }

# ── files ─────────────────────────────────────────────────────────────────────────────────
function Sync-Files($manifest) {
  $n = 0
  foreach ($f in $manifest.files) {
    $dest = Join-Path $Dir ($f.dest -replace '/', '\')
    if ((Get-Sha $dest) -eq $f.sha256) { continue }
    $folder = Split-Path $dest -Parent
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $tmp = "$dest.download"
    Invoke-WebRequest -UseBasicParsing -Uri ($SiteUrl + $f.url) -OutFile $tmp -TimeoutSec 300
    if ((Get-Sha $tmp) -ne $f.sha256) { Remove-Item $tmp -Force; throw "Fisier corupt la descarcare: $($f.url)" }
    Move-Item $tmp $dest -Force
    $n++
  }
  Say "Fisiere actualizate: $n din $($manifest.files.Count)."
}

# ── Ollama and the AI model ───────────────────────────────────────────────────────────────
function Find-Ollama {
  $p = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
  if (Test-Path $p) { return $p }
  $c = Get-Command ollama -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  return $null
}
function Get-Models {
  try { return @((Invoke-RestMethod -Uri "$OllamaApi/api/tags" -TimeoutSec 3).models | ForEach-Object { $_.name }) }
  catch { return $null }
}
function Has-Model($models, [string]$name) {
  if ($null -eq $models) { return $false }
  return ($models -contains $name) -or ($models -contains "${name}:latest")
}
function Start-Ollama {
  if ($null -ne (Get-Models)) { return $true }
  $exe = Find-Ollama
  if (-not $exe) { return $false }
  $app = Join-Path (Split-Path $exe -Parent) 'ollama app.exe'
  if (Test-Path $app) { Start-Process $app } else { Start-Process $exe -ArgumentList 'serve' -WindowStyle Hidden }
  for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Seconds 1; if ($null -ne (Get-Models)) { return $true } }
  return $false
}
function Get-OllamaVersion {
  try { $v = (Invoke-RestMethod -Uri "$OllamaApi/api/version" -TimeoutSec 3).version; return [version]($v -replace '[^0-9.].*$', '') }
  catch { return $null }
}
function Install-Ollama {
  $tmp = Join-Path $env:TEMP 'OllamaSetup.exe'
  Say 'Descarc Ollama de pe ollama.com (aproximativ 1 GB, cateva minute)...'
  Invoke-WebRequest -UseBasicParsing -Uri 'https://ollama.com/download/OllamaSetup.exe' -OutFile $tmp -TimeoutSec 3600
  Say 'Instalez Ollama...'
  Start-Process $tmp -ArgumentList '/VERYSILENT', '/NORESTART', '/SUPPRESSMSGBOXES' -Wait
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}
function Get-BaseModel($manifest) {
  $conf = Read-JsonFile $ConfFile
  if ($conf -and $conf.base) { return $conf.base }
  return $manifest.model.base
}
function Choose-BaseModel($manifest) {
  $base = $manifest.model.base
  $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
  if ($ram -lt $manifest.model.minRamGB -and $manifest.model.fallback) {
    $msg = "Acest calculator are $ram GB RAM. Modelul recomandat ($base) are nevoie de aproximativ $($manifest.model.minRamGB) GB.`n`n" +
           "Instalez modelul mai mic ($($manifest.model.fallback))? Raspunde mai slab in romana, dar merge si cu 8 GB.`n`n" +
           "Da = modelul mic   Nu = modelul recomandat"
    if (Ask $msg) { $base = $manifest.model.fallback }
  }
  Write-JsonFile $ConfFile @{ base = $base }
  return $base
}
function Install-Model($manifest, [string]$base) {
  $exe = Find-Ollama
  $models = Get-Models
  if (-not (Has-Model $models $base)) {
    Say "Descarc modelul AI $base (o singura data; poate dura 10-30 de minute)..."
    & $exe pull $base
    if ($LASTEXITCODE -ne 0) { throw "Descarcarea modelului $base a esuat." }
  }
  # the Modelfile is published for the recommended base; use the chosen one
  $mf = Join-Path $Dir 'Modelfile'
  $tmp = Join-Path $Dir 'Modelfile.local'
  $text = [IO.File]::ReadAllText($mf) -replace '(?m)^FROM .*$', "FROM $base"
  [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))   # no BOM: Ollama reads the file as is
  Say "Pregatesc modelul ""$($manifest.model.name)""..."
  & $exe create $manifest.model.name -f $tmp
  if ($LASTEXITCODE -ne 0) { throw 'Crearea modelului ShieldSim a esuat.' }
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

# ── shortcuts ─────────────────────────────────────────────────────────────────────────────
function New-Shortcut([string]$path, [string]$arguments) {
  $ws = New-Object -ComObject WScript.Shell
  $l = $ws.CreateShortcut($path)
  $l.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $l.Arguments = "-NoProfile -ExecutionPolicy Bypass -File ""$Dir\ShieldSim.ps1"" $arguments"
  $l.WorkingDirectory = $Dir
  $l.IconLocation = "$Dir\shieldsim.ico"
  $l.Save()
}
function Install-Shortcuts {
  $programs = Join-Path ([Environment]::GetFolderPath('Programs')) 'ShieldSim'
  New-Item -ItemType Directory -Path $programs -Force | Out-Null
  New-Shortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'ShieldSim.lnk') ''
  New-Shortcut (Join-Path $programs 'ShieldSim.lnk') ''
  New-Shortcut (Join-Path $programs 'Dezinstaleaza ShieldSim.lnk') '-Uninstall'
}

function Main {
  # ── uninstall ─────────────────────────────────────────────────────────────────────────────
  if ($Uninstall) {
    if (-not (Ask "Sterg ShieldSim de pe acest calculator?`n`nOllama ramane instalat; il poti sterge din Settings > Apps.")) { exit 0 }
    $exe = Find-Ollama
    if ($exe -and (Start-Ollama)) { try { & $exe rm shieldsim | Out-Null } catch { } }
    Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'ShieldSim.lnk') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'ShieldSim') -Recurse -Force -ErrorAction SilentlyContinue
    Set-Location $env:TEMP
    Remove-Item $Dir -Recurse -Force -ErrorAction SilentlyContinue
    Tell 'ShieldSim a fost sters.' 'Information'
    exit 0
  }

  # ── install / update ──────────────────────────────────────────────────────────────────────
  New-Item -ItemType Directory -Path $Dir -Force | Out-Null
  $state = Read-JsonFile $StateFile

  if ($Install) {
    Say 'Instalez ShieldSim cu asistentul AI. Nu inchide aceasta fereastra.'
    $manifest = Get-Manifest
    if (-not $manifest) { throw "Nu pot ajunge la $SiteUrl. Verifica internetul si porneste din nou instalarea." }
    $free = [math]::Round((Get-PSDrive -Name ($env:LOCALAPPDATA.Substring(0, 1))).Free / 1GB)
    if ($free -lt $manifest.model.diskGB) {
      if (-not (Ask "Pe disc sunt liberi doar $free GB, iar instalarea are nevoie de aproximativ $($manifest.model.diskGB) GB. Continui?")) { exit 1 }
    }
    Sync-Files $manifest
    if (-not (Find-Ollama)) { Install-Ollama }
    if (-not (Start-Ollama)) { throw 'Ollama nu a pornit. Reporneste calculatorul si ruleaza din nou instalarea.' }
    $v = Get-OllamaVersion
    if ($v -and $v -lt [version]'0.9') {
      Say "Ollama $v este prea vechi pentru modelul AI; il actualizez."
      Get-Process -Name 'ollama*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
      Install-Ollama
      if (-not (Start-Ollama)) { throw 'Ollama nu a pornit dupa actualizare. Reporneste calculatorul si ruleaza din nou instalarea.' }
    }
    $base = Choose-BaseModel $manifest
    Install-Model $manifest $base
    Install-Shortcuts
    Write-JsonFile $StateFile $manifest
    $state = $manifest
    Say 'Gata! ShieldSim este instalat. De acum il pornesti din scurtatura ShieldSim de pe Desktop.'
  } else {
    $manifest = Get-Manifest
    if ($manifest -and $state -and $manifest.build -ne $state.build) {
      $msg = "Exista o versiune noua a ShieldSim ($($manifest.version), $($manifest.date)).`n" +
             "Versiunea ta: $($state.version), $($state.date).`n`nActualizez acum?"
      if (Ask $msg) {
        Say 'Actualizez ShieldSim...'
        try {
          Sync-Files $manifest
          $modelChanged = ($manifest.model.modelfileSha -ne $state.model.modelfileSha) -or ($manifest.model.base -ne $state.model.base)
          if ($modelChanged -and (Start-Ollama)) {
            $conf = Read-JsonFile $ConfFile
            if (-not $conf -or $conf.base -eq $state.model.base) { Write-JsonFile $ConfFile @{ base = $manifest.model.base } }
            Install-Model $manifest (Get-BaseModel $manifest)
          }
          Write-JsonFile $StateFile $manifest
          $state = $manifest
          Say 'Actualizare terminata.'
        } catch { Warn "Actualizarea nu a reusit ($($_.Exception.Message)). Pornesc versiunea instalata." }
      }
    }
  }

  if (-not (Test-Path (Join-Path $SiteDir 'index.html'))) { throw 'ShieldSim nu este instalat complet. Ruleaza din nou "Instaleaza ShieldSim.cmd".' }

  # ── start ─────────────────────────────────────────────────────────────────────────────────
  $ai = Start-Ollama
  $models = Get-Models
  if (-not $ai) { Warn 'Ollama nu ruleaza: Nova va raspunde doar la intrebarile frecvente.' }
  elseif (-not (Has-Model $models 'shieldsim')) {
    if ($state -and (Get-Manifest)) { try { Install-Model $state (Get-BaseModel $state) } catch { Warn $_.Exception.Message } }
    else { Warn 'Modelul AI "shieldsim" lipseste si nu e internet ca sa-l instalez. Nova va raspunde doar la intrebarile frecvente.' }
  }

  $listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
  try { $listener.Start() } catch {
    Say 'ShieldSim ruleaza deja; deschid browserul.'
    Start-Process $AppUrl
    exit 0
  }
  Start-Process ($AppUrl + '#/calculator')
  Say "ShieldSim ruleaza la $AppUrl . Inchide aceasta fereastra ca sa-l opresti."

  # warm the model up, so the first answer is not slowed down by loading it
  if ($ai) {
    try {
      $wc = New-Object System.Net.WebClient
      $wc.Headers['Content-Type'] = 'application/json'
      $wc.UploadStringAsync([Uri]"$OllamaApi/api/generate", '{"model":"shieldsim","prompt":"","keep_alive":"30m"}')
    } catch { }
  }

  $types = @{
    '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript'; '.json' = 'application/json'; '.webmanifest' = 'application/manifest+json'
    '.png' = 'image/png'; '.svg' = 'image/svg+xml'; '.webp' = 'image/webp'; '.jpg' = 'image/jpeg'; '.pdf' = 'application/pdf'; '.ico' = 'image/x-icon'; '.txt' = 'text/plain; charset=utf-8'
  }
  $root = [IO.Path]::GetFullPath($SiteDir)
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $stream.ReadTimeout = 3000
      $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 8192, $true)
      $line = $reader.ReadLine()
      while ($true) { $h = $reader.ReadLine(); if ($null -eq $h -or $h -eq '') { break } }
      $parts = "$line".Split(' ')
      $status = '404 Not Found'; $body = [Text.Encoding]::UTF8.GetBytes('Not found'); $type = 'text/plain'
      if ($parts.Count -ge 2 -and ($parts[0] -eq 'GET' -or $parts[0] -eq 'HEAD')) {
        $p = [Uri]::UnescapeDataString(($parts[1] -split '\?')[0])
        if ($p -eq '/') { $p = '/index.html' }
        $file = [IO.Path]::GetFullPath((Join-Path $root ($p.TrimStart('/') -replace '/', '\')))
        if ($file.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $file -PathType Leaf)) {
          $status = '200 OK'
          $body = [IO.File]::ReadAllBytes($file)
          $ext = [IO.Path]::GetExtension($file).ToLower()
          if ($types.ContainsKey($ext)) { $type = $types[$ext] } else { $type = 'application/octet-stream' }
        }
        if ($parts[0] -eq 'HEAD') { $len = $body.Length; $body = New-Object byte[] 0 } else { $len = $body.Length }
      } else { $len = $body.Length }
      $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Type: $type`r`nContent-Length: $len`r`nCache-Control: no-cache`r`nConnection: close`r`n`r`n")
      $stream.Write($head, 0, $head.Length)
      if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
      $stream.Flush()
    } catch { } finally { $client.Close() }
  }
}

try { Main }
catch {
  Warn "Eroare: $($_.Exception.Message)"
  Tell ("ShieldSim nu a putut porni:`n`n" + $_.Exception.Message) 'Error'
  Read-Host 'Apasa Enter ca sa inchizi'
  exit 1
}
