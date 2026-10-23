# Claude 账号切换器 - Windows 核心脚本
# 用法: powershell -NoProfile -File claude-switch.ps1 check|status|switch A|B|checkdetail|fix
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ============ 安装时可配置项(安装器自动改写) ============
$PROXY_MODE = "clash-verge"            # 代理客户端: clash-verge|sing-box|clashx|surge|wireguard|other|auto
$COUNTRY_TARGET = "US"                 # 目标出口国家(安装时按出口自动识别)
$TZ_TARGET = "Eastern Standard Time"   # Windows 时区ID
$PROXY_GROUP = "GLOBAL"                # Clash 代理组名
# =======================================================

$BASE = Join-Path $env:USERPROFILE ".claude-switcher"
$DATA = Join-Path $env:APPDATA "Claude"
$LOG  = Join-Path $BASE "claude-switch.log"
$CLASH_DIR = @(
    (Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev"),
    (Join-Path $env:LOCALAPPDATA "io.github.clash-verge-rev.clash-verge-rev")
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $CLASH_DIR) { $CLASH_DIR = Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev" }
New-Item -ItemType Directory -Force -Path "$BASE\accounts" | Out-Null

function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Out-File -Append -Encoding utf8 $LOG }

# 代理客户端显示名(供检查细节输出)
function Get-ProxyName {
    switch ($PROXY_MODE) {
        'clash-verge' { return 'Clash Verge' }
        'sing-box'    { return 'sing-box' }
        'clashx'      { return 'ClashX' }
        'surge'       { return 'Surge' }
        'wireguard'   { return 'WireGuard' }
        'other'       { return '其他代理客户端' }
        'auto'        { return '代理客户端(auto)' }
        default       { return $PROXY_MODE }
    }
}

# 代理客户端在线判定:按安装时识别的客户端分派;auto 任一命中即活,other 只依赖 TUN
function Test-ProxyAlive {
    switch ($PROXY_MODE) {
        'clash-verge' { return [bool](Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue) }
        'sing-box'    { return [bool](Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue) }
        'clashx'      { return [bool](Get-Process -Name 'ClashX' -ErrorAction SilentlyContinue) }
        'surge'       { return [bool](Get-Process -Name 'Surge' -ErrorAction SilentlyContinue) }
        'wireguard'   { return [bool](Get-Service -Name 'WireGuardTunnel*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running') }
        'other'       { return $true }
        'auto' {
            if (Get-Process -Name 'verge-mihomo','sing-box','ClashX','Surge' -ErrorAction SilentlyContinue) { return $true }
            return [bool](Get-Service -Name 'WireGuardTunnel*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running')
        }
        default { return [bool](Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue) }
    }
}

# TUN 在线判定:198.18 假IP段优先,否则回退到任意 Up 状态的虚拟网卡(兼容 Astrill/WireGuard/OpenVPN 等)
function Get-TunStatus {
    if (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '198.18.*' }) {
        return @{ up = $true; detail = '198.18 假IP段' }
    }
    $nic = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and ($_.InterfaceDescription -match 'TAP|TUN|WireGuard|Wintun|VPN|Tailscale') }
    if ($nic) { return @{ up = $true; detail = '通用虚拟网卡' } }
    return @{ up = $false; detail = '不在线' }
}
function Test-TunUp {
    $t = Get-TunStatus
    return [bool]$t.up
}

function Get-Egress {
    $trace = & curl.exe -s --max-time 8 "https://www.cloudflare.com/cdn-cgi/trace" 2>$null
    $ip  = (($trace -split "`n" | Where-Object { $_ -like 'ip=*' })  -replace 'ip=','').Trim()
    $loc = (($trace -split "`n" | Where-Object { $_ -like 'loc=*' }) -replace 'loc=','').Trim()
    return @{ ip = $ip; loc = $loc }
}

# STUN 探针(纯 .NET UDP,手工构造 RFC5389 报文)
function Get-StunPublicIP([string]$server, [int]$port, [int]$timeoutMs = 2000) {
    try { $addr = ([System.Net.Dns]::GetHostAddresses($server) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1) } catch { return $null }
    if (-not $addr) { return $null }
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.Client.ReceiveTimeout = $timeoutMs
    try {
        $txn = New-Object byte[] 12; (New-Object Random).NextBytes($txn)
        $req = [byte[]](0x00, 0x01, 0x00, 0x00) + [byte[]](0x21, 0x12, 0xA4, 0x42) + $txn
        $udp.Connect($addr, $port)
        [void]$udp.Send($req, $req.Length)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$remote)
        $pos = 20
        while ($pos + 4 -le $resp.Length) {
            $atype = ([int]$resp[$pos] -shl 8) -bor $resp[$pos + 1]
            $alen  = ([int]$resp[$pos + 2] -shl 8) -bor $resp[$pos + 3]
            if (($atype -eq 0x20 -or $atype -eq 0x01) -and $alen -ge 8 -and $resp[$pos + 5] -eq 0x01) {
                $ipBytes = @($resp[$pos + 8], $resp[$pos + 9], $resp[$pos + 10], $resp[$pos + 11])
                if ($atype -eq 0x20) {
                    $cookie = [byte[]](0x21, 0x12, 0xA4, 0x42)
                    for ($i = 0; $i -lt 4; $i++) { $ipBytes[$i] = $ipBytes[$i] -bxor $cookie[$i] }
                }
                return ($ipBytes -join '.')
            }
            $pos += 4 + $alen + ((4 - ($alen % 4)) % 4)
        }
    } catch { return $null } finally { $udp.Close() }
    return $null
}

function Test-WebRTC($exitIp) {
    $servers = @(@("stun.miwifi.com", 3478), @("stun.chat.bilibili.com", 3478), @("stun.l.google.com", 19302), @("stun.cloudflare.com", 3478))
    $found = @()
    foreach ($s in $servers) {
        $r = Get-StunPublicIP $s[0] $s[1]
        if ($r -and ($found -notcontains $r)) { $found += $r }
    }
    if ($found.Count -eq 0) { return @{ code = 'ok'; detail = 'UDP不出网,零暴露' } }
    $leak = $found | Where-Object { $_ -ne $exitIp }
    if ($leak) { return @{ code = 'fail'; detail = "暴露非代理IP: $($leak -join ',')" } }
    return @{ code = 'ok'; detail = '仅暴露代理IP' }
}

function Test-RulesPinned { Test-Path "$CLASH_DIR\clash-verge.yaml" -and (Select-String -Path "$CLASH_DIR\clash-verge.yaml" -Pattern "DOMAIN-SUFFIX,claude.ai,$PROXY_GROUP" -Quiet) -and (Select-String -Path "$CLASH_DIR\clash-verge.yaml" -Pattern "DST-PORT,3478," -Quiet) }

function Invoke-CheckDetail {
    $pname = Get-ProxyName
    if (Test-ProxyAlive) {
        if ($PROXY_MODE -eq 'other') { "代理内核=ok:$pname(仅校验TUN)" }
        else { "代理内核=ok:$pname 运行中" }
    } else { "代理内核=fail:$pname 未运行" }

    $tun = Get-TunStatus
    if ($tun.up) {
        if ($tun.detail -eq '198.18 假IP段') { "TUN网卡=ok" }
        else { "TUN网卡=ok:$($tun.detail)" }
    } else { "TUN网卡=fail:不在线" }

    $e = Get-Egress
    if ($e.loc -eq $COUNTRY_TARGET) { "出口IP=ok:$($e.ip)" } else { "出口IP=fail:$($e.ip)/$($e.loc)(期望$COUNTRY_TARGET)" }

    $lastipFile = "$BASE\lastip.txt"
    $lastip = if (Test-Path $lastipFile) { (Get-Content $lastipFile -Raw).Trim() } else { '' }
    if (-not $e.ip) { "IP一致=fail:未获取到出口IP" }
    elseif (-not $lastip) { "IP一致=ok:首次记录" }
    elseif ($e.ip -eq $lastip) { "IP一致=ok" }
    else { "IP一致=warn:$lastip → $($e.ip)" }
    if ($e.ip) { $e.ip | Out-File -Encoding ascii -NoNewline $lastipFile }

    $tz = (Get-TimeZone).Id
    if ($tz -eq $TZ_TARGET) { "时区=ok" } else { "时区=fail:$tz" }

    $cult = (Get-Culture).Name
    if ($cult -eq 'en-US') { "地区=ok" } else { "地区=fail:$cult" }

    $v6off = [bool](Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq $true })
    if (-not $v6off) { "IPv6=ok:已关闭" } else { "IPv6=fail:未关闭" }

    $dns = (Resolve-DnsName claude.ai -Type A -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    if ($dns -like '198.18.*') { "DNS=ok:走隧道" } else { "DNS=fail:未走隧道($dns)" }

    $w = Test-WebRTC $e.ip
    "WebRTC=$($w.code):$($w.detail)"

    $bg = Get-ScheduledTask -TaskName 'ClaudeBodyguard' -ErrorAction SilentlyContinue
    if ($bg) { "保镖=ok" } else { "保镖=fail:未安装" }

    if (Test-RulesPinned) { "规则置顶=ok" } else { "规则置顶=fail:未生效" }

    # 客户端语言: Windows 端 Claude 跟随系统区域格式,地区检查已覆盖
    "客户端语言=ok:跟随系统"

    $org = ''
    try { $org = ((& curl.exe -s --max-time 6 "https://ipinfo.io/json" 2>$null) | ConvertFrom-Json).org } catch {}
    if (-not $org) { "ASN属性=warn:未获取" }
    elseif ($org -match 'Comcast|AT&T|Verizon|Spectrum|Charter|Cox|T-Mobile|Cable|esidential') { "ASN属性=ok:$org" }
    else { "ASN属性=warn:疑似机房($org)" }

    $r1 = & curl.exe -s --max-time 8 -o NUL -w '%{http_code}' "https://claude.ai/" 2>$null
    $r2 = & curl.exe -s --max-time 8 -o NUL -w '%{http_code}' "https://api.anthropic.com/v1/models" 2>$null
    if ($r1 -ne '000' -and $r2 -ne '000') { "生态可达性=ok:claude.ai:$r1 api:$r2" } else { "生态可达性=fail:claude.ai:$r1 api:$r2" }
}

function Invoke-Fix {
    "FIX:开始一键修复"

    # A. 拉起代理客户端并等待内核+TUN(仅 Clash Verge 可自动拉起)
    if ($PROXY_MODE -eq 'clash-verge') {
        if (-not (Test-ProxyAlive)) {
            "FIX:正在启动 Clash Verge..."
            $cv = Get-ChildItem "$env:LOCALAPPDATA\Programs","$env:ProgramFiles","${env:ProgramFiles(x86)}" -Recurse -Filter "Clash Verge*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cv) { Start-Process $cv.FullName } else { "FIX:未找到 Clash Verge 可执行文件,请手动启动" }
        }
        $ok = $false
        for ($i = 0; $i -lt 40; $i++) { if ((Test-ProxyAlive) -and (Test-TunUp)) { $ok = $true; break }; Start-Sleep 1 }
        if ($ok) { "FIX:代理内核+TUN ✓" } else { "FIX:代理内核/TUN ✗(请打开 Clash Verge 检查节点/线路及 TUN 开关)" }
    } else {
        $pname = Get-ProxyName
        if ((Test-ProxyAlive) -and (Test-TunUp)) { "FIX:代理客户端($pname)+TUN ✓" }
        elseif (-not (Test-ProxyAlive)) { "FIX:代理客户端($pname)未运行,请手动启动并开启 TUN 模式" }
        else { "FIX:TUN 未在线($pname),请检查客户端 TUN 开关" }
    }

    # B. 时区/IPv6/DNS/保镖(需管理员:通过 UAC 弹一次)
    $adminScript = @()
    if ((Get-TimeZone).Id -ne $TZ_TARGET) { $adminScript += "Set-TimeZone -Id '$TZ_TARGET'" }
    if (Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue | Where-Object { $_.Enabled }) { $adminScript += "Get-NetAdapterBinding -ComponentID ms_tcpip6 | Disable-NetAdapterBinding -Confirm:`$false" }
    $adminScript += "Clear-DnsClientCache"
    if (-not (Get-ScheduledTask -TaskName 'ClaudeBodyguard' -ErrorAction SilentlyContinue)) {
        $adminScript += "`$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$BASE\claude-bodyguard.ps1`"'; `$t = New-ScheduledTaskTrigger -AtLogOn; Register-ScheduledTask -TaskName 'ClaudeBodyguard' -Action `$a -Trigger `$t -Force | Out-Null; Start-ScheduledTask -TaskName 'ClaudeBodyguard'"
    }
    if ($adminScript.Count -gt 0) {
        "FIX:修复时区/IPv6/DNS/保镖(需要管理员授权)..."
        $tmp = "$env:TEMP\claude-fix-$([guid]::NewGuid().Guid).ps1"
        ($adminScript -join "`n") | Out-File -Encoding utf8 $tmp
        try { Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`"" } catch { "FIX:管理员授权被取消" }
        Remove-Item $tmp -ErrorAction SilentlyContinue
        "FIX:时区/IPv6/DNS/保镖 ✓"
    } else {
        "FIX:时区/IPv6/保镖 无需修复 ✓"
    }

    # B2. 置顶规则(仅 Clash Verge 可自动改写)
    if ($PROXY_MODE -ne 'clash-verge') {
        "FIX:请在 $(Get-ProxyName) 中自行添加 Claude 域名置顶规则"
    } elseif (-not (Test-RulesPinned)) {
        "FIX:重写置顶规则..."
        $merge = @"
profile:
  store-selected: true

prepend-rules:
  - DOMAIN-SUFFIX,claude.ai,$PROXY_GROUP
  - DOMAIN-SUFFIX,claude.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,anthropic.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,claudeusercontent.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,challenges.cloudflare.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,datadoghq.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,segment.io,$PROXY_GROUP
  - DOMAIN-SUFFIX,stripe.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,stripe.network,$PROXY_GROUP
  - DOMAIN-SUFFIX,stripecdn.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,intercom.io,$PROXY_GROUP
  - DOMAIN-SUFFIX,intercomcdn.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,intercomassets.com,$PROXY_GROUP
  - DST-PORT,3478,$PROXY_GROUP
  - DST-PORT,5349,$PROXY_GROUP
  - DST-PORT,19302,$PROXY_GROUP
"@
        New-Item -ItemType Directory -Force -Path "$CLASH_DIR\profiles" | Out-Null
        $merge | Out-File -Encoding utf8 "$CLASH_DIR\profiles\Merge.yaml"
        Get-Process -Name 'clash-verge','Clash Verge' -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep 2
        $cv = Get-ChildItem "$env:LOCALAPPDATA\Programs" -Recurse -Filter "Clash Verge*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cv) { Start-Process $cv.FullName }
        for ($i = 0; $i -lt 40; $i++) { if (Test-TunUp) { break }; Start-Sleep 1 }
        if (Test-RulesPinned) { "FIX:置顶规则 ✓" } else { "FIX:置顶规则 ✗(请重启 Clash Verge)" }
    }

    # C. 出口IP最终验证
    Start-Sleep 2
    $e = Get-Egress
    if ($e.loc -eq $COUNTRY_TARGET) { "FIX:出口IP ✓ ($($e.ip))" } else { "FIX:出口IP ✗ ($($e.ip)/$($e.loc),期望$COUNTRY_TARGET) — 请换节点/线路" }
    "FIX:修复流程结束"
}

function Invoke-Status {
    $cur = if (Test-Path "$BASE\current.txt") { (Get-Content "$BASE\current.txt" -Raw).Trim() } else { 'none' }
    $hasA = if (Test-Path "$BASE\accounts\A") { 1 } else { 0 }
    $hasB = if (Test-Path "$BASE\accounts\B") { 1 } else { 0 }
    "current=$cur hasA=$hasA hasB=$hasB"
}

function Stop-ClaudeApp {
    $p = Get-Process -Name 'Claude' -ErrorAction SilentlyContinue
    if (-not $p) { return $true }
    $p | Stop-Process -Force
    for ($i = 0; $i -lt 15; $i++) { if (-not (Get-Process -Name 'Claude' -ErrorAction SilentlyContinue)) { return $true }; Start-Sleep 1 }
    return $false
}

function Save-Account($name) {
    robocopy "$DATA" "$BASE\accounts\$name" /MIR /NFL /NDL /NJH /NJS | Out-Null
    Log "已存档账号$name"
}

function Start-ClaudeApp {
    $exe = @("$env:LOCALAPPDATA\AnthropicClaude\Claude.exe", "$env:LOCALAPPDATA\Programs\Claude\Claude.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($exe) { Start-Process $exe } else { Start-Process "shell:AppsFolder" -ErrorAction SilentlyContinue }
}

function Invoke-Switch($target) {
    $cur = if (Test-Path "$BASE\current.txt") { (Get-Content "$BASE\current.txt" -Raw).Trim() } else { 'none' }

    # 首次运行:收编当前登录为账号A
    if ($cur -eq 'none' -and (Test-Path $DATA) -and (Get-ChildItem $DATA -ErrorAction SilentlyContinue)) {
        if (-not (Stop-ClaudeApp)) { "FAIL:Claude 未能退出，请手动退出后重试"; return }
        Save-Account A
        $cur = 'A'; 'A' | Out-File -Encoding ascii -NoNewline "$BASE\current.txt"
        Log "首次运行:当前登录状态已收编为账号A"
        "NOTE:已将当前登录收编为账号A"
    }

    if ($cur -eq $target) { Start-ClaudeApp; "INFO:当前已是账号$target"; return }

    if (-not (Stop-ClaudeApp)) { "FAIL:Claude 未能退出，请手动退出后重试"; return }

    if ($cur -ne 'none' -and (Test-Path $DATA)) { Save-Account $cur }

    if (Test-Path "$BASE\accounts\$target") {
        Remove-Item $DATA -Recurse -Force -ErrorAction SilentlyContinue
        robocopy "$BASE\accounts\$target" "$DATA" /E /NFL /NDL /NJH /NJS | Out-Null
        Log "已载入账号$target 存档"
    } else {
        Remove-Item $DATA -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $DATA | Out-Null
        Log "账号$target 无存档，将以全新状态初始化"
    }
    $target | Out-File -Encoding ascii -NoNewline "$BASE\current.txt"
    Start-ClaudeApp
    Log "已切换到账号$target 并启动"
    "OK:已切换到账号$target"
}

switch ($args[0]) {
    'checkdetail' {
        $r = Invoke-CheckDetail
        $r | Out-File -Encoding utf8 "$BASE\last-check.txt"
        $r
    }
    'status' { Invoke-Status }
    'fix'    { Invoke-Fix }
    'switch' { Invoke-Switch $args[1] }
    default  { "用法: claude-switch.ps1 checkdetail|status|fix|switch A|B" }
}
