# campus-sso-login.ps1  (ASCII-ONLY, curl.exe based)
# Headless campus-network login for Hanshan Normal University (hstc)
#   Dr.COM portal + school CAS unified identity (hscas.hstc.edu.cn)
#
# HTTP : curl.exe (built into Windows 10 1803+; no .NET web stack quirks)
# RSA  : .NET RSACryptoServiceProvider, PKCS#1 v1.5 (no openssl needed)
#
# Usage:
#   .\campus-sso-login.ps1 -Check      just report online state
#   .\campus-sso-login.ps1 -DryRun     parse the whole chain, do NOT submit password
#   .\campus-sso-login.ps1             login if not already online
#   .\campus-sso-login.ps1 -Force      ignore online state
#   .\campus-sso-login.ps1 -Redirect "<portal redirect url>"   skip auto-discovery
#
# Credentials: -User/-Pass, env CAMPUS_USER/CAMPUS_PASS, campus.conf.ps1,
#              otherwise prompt in the terminal (password is not echoed)

[CmdletBinding()]
param(
    [string]$User = $env:CAMPUS_USER,
    [string]$Pass = $env:CAMPUS_PASS,
    [string]$Redirect = $env:CAMPUS_REDIRECT,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Check,
    [switch]$Logout
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Any unhandled error: print the line number and the offending source line.
trap {
    Write-Host ''
    Write-Host ("UNHANDLED ERROR at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo.Line) { Write-Host ("  >> " + $_.InvocationInfo.Line.Trim()) -ForegroundColor DarkGray }
    Remove-Item $Jar -ErrorAction SilentlyContinue
    exit 1
}

$Probe    = 'http://connect.rom.miui.com/generate_204'
$Portal   = 'https://rz.hstc.edu.cn'
$CasBase  = 'https://hscas.hstc.edu.cn/cas'
$EpPort   = 801
$EpHttpsPort = 802
$UA       = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
$WorkDir  = Join-Path $env:TEMP 'campus-sso'
$Jar      = Join-Path $WorkDir 'cookies.txt'
$Hdr      = Join-Path $WorkDir 'last.hdr'
$Body     = Join-Path $WorkDir 'last.body'

$ConfFile = Join-Path $PSScriptRoot 'campus.conf.ps1'
if (Test-Path $ConfFile) {
    . $ConfFile
    if (-not $User -and $CAMPUS_USER) { $User = $CAMPUS_USER }
    if (-not $Pass -and $CAMPUS_PASS) { $Pass = $CAMPUS_PASS }
}

function Say([string]$m) { Write-Host ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
function Bye([int]$Code) { Remove-Item $Jar -ErrorAction SilentlyContinue; exit $Code }
function Die([string]$m) { Write-Host ("ERROR: {0}" -f $m) -ForegroundColor Red; Bye 1 }

if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Die 'curl.exe not found (needs Windows 10 1803+)'
}
# Windows' bundled curl uses Schannel, which by default insists on a certificate
# revocation check. On a campus network that is not yet authenticated the CRL/OCSP
# endpoints are unreachable, so the TLS handshake fails with curl exit 35.
# --ssl-no-revoke disables that check. It only exists on Schannel builds.
$script:CurlVer     = ((& curl.exe --version 2>$null) -join ' ')
$script:SslNoRevoke = ($script:CurlVer -match 'Schannel')

# ---------------------------------------------------------------- HTTP helpers
function RunCurl {
    param([string[]]$Extra, [string]$Label = 'curl', [string]$Referer = '')
    Remove-Item $Hdr, $Body -ErrorAction SilentlyContinue
    $errFile = Join-Path $WorkDir 'curl.err'
    Remove-Item $errFile -ErrorAction SilentlyContinue
    $a = @('-sS','-D',$Hdr,'-o',$Body,'--max-time','25','-A',$UA)
    if ($script:SslNoRevoke) { $a += '--ssl-no-revoke' }
    if ($Referer) { $a += @('-H', "Referer: $Referer") }
    $a += $Extra
    & curl.exe @a 2>$errFile | Out-Null
    $script:CurExit = $LASTEXITCODE
    if (Test-Path $errFile) { $script:CurErr = ([IO.File]::ReadAllText($errFile)).Trim() } else { $script:CurErr = '' }
    if (Test-Path $Body)    { $script:CurSize = (Get-Item $Body).Length }              else { $script:CurSize = 0 }
}
function Status {
    $l = Get-Content $Hdr -TotalCount 1 -ErrorAction SilentlyContinue
    if ($l -match 'HTTP/\S+\s+(\d{3})') { return [int]$Matches[1] }
    return 0
}
function HdrVal([string]$Name) {
    $m = Select-String -Path $Hdr -Pattern ("^" + $Name + ":") -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) { return ($m.Line -replace ("^" + $Name + ":\s*"), '').Trim() }
    return $null
}
# read bytes 1:1 (Latin-1) so ASCII patterns survive whatever charset the portal uses
function BodyText {
    if (Test-Path $Body) { return [IO.File]::ReadAllText($Body, [Text.Encoding]::GetEncoding(28591)) }
    return ''
}
function Test-Online {
    RunCurl -Extra @($Probe) -Label 'probe'
    return ((Status) -eq 204)
}

# ---------------------------------------------------------------- logout
# This deployment's portal does not use /drcom/logout: with unBindMac=1 its page
# calls user.unbind_mac(), which posts to mac/unbind with unbind_type=1. Taken
# from the page's own traffic:
#   GET :802/eportal/portal/mac/unbind?user_account=..&wlan_user_mac=000000000000
#       &wlan_user_ip=..&wlan_user_ipv6=::&unbind_type=1&...
#   GET :802/eportal/portal/cas/logout?wlan_user_ip=..  -> follow the switch_uri
function Get-LocalIp {
    try {
        return (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notlike '127.*' } |
                Select-Object -First 1).IPAddress
    } catch { return '' }
}

$script:PageProgram = ''
$script:PageIndex   = ''
# Every portal jsonp call carries program_index / page_index / v / lang on top of
# callback+jsVersion (see util._jsonp). wlan_ac_ip and wlan_user_ipv6 have to be
# present even when empty, otherwise loadConfig answers with an error.
function Get-PageIndices([string]$ClientIp) {
    if ($script:PageProgram -and $script:PageIndex) { return }
    if (-not $ClientIp) { return }
    $h   = ([regex]::Match($Portal, '^https?://([^/]+)')).Groups[1].Value -replace ':\d+$', ''
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ClientIp))
    RunCurl -Extra @("http://${h}:$EpPort/eportal/portal/page/loadConfig?callback=cb&program_index=&wlan_user_ip=$b64&wlan_ac_ip=&wlan_user_ipv6=&jsVersion=4.1") -Label 'loadConfig'
    $r  = BodyText
    $m1 = [regex]::Match($r, '"program_index":"([^"]*)"')
    $m2 = [regex]::Match($r, '"page_index":"([^"]*)"')
    if ($m1.Success) { $script:PageProgram = $m1.Groups[1].Value }
    if ($m2.Success) { $script:PageIndex   = $m2.Groups[1].Value }
}

function Do-Logout {
    $h    = ([regex]::Match($Portal, '^https?://([^/]+)')).Groups[1].Value -replace ':\d+$', ''
    $base = "https://${h}:$EpHttpsPort/eportal/portal"
    $ref  = "https://${h}/"
    $rnd  = Get-Random -Minimum 1000 -Maximum 9999

    # Ask the portal who we are: uid is the account, ss5 is the client IP as the
    # portal itself sees it. Both are needed by the unbind call below.
    RunCurl -Extra @("$Portal/drcom/chkstatus?callback=cb&jsVersion=4.2.2") -Label 'chkstatus'
    $st  = BodyText
    $uid = ([regex]::Match($st, '"uid":"([^"]*)"')).Groups[1].Value
    $cip = ([regex]::Match($st, '"ss5":"([^"]*)"')).Groups[1].Value
    if (-not $cip) { $cip = Get-LocalIp }
    Get-PageIndices $cip
    Say "portal sees us as uid=$(if ($uid) { $uid } else { '?' }) ip=$(if ($cip) { $cip } else { '?' })"

    # 1) Unbind the terminal MAC - this is the call that actually drops the session.
    RunCurl -Extra @('-G', "$base/mac/unbind",
        '--data-urlencode', "callback=dr$rnd",
        '--data-urlencode', "user_account=$uid",
        '--data-urlencode', 'wlan_user_mac=000000000000',
        '--data-urlencode', "wlan_user_ip=$cip",
        '--data-urlencode', 'wlan_user_ipv6=::',
        '--data-urlencode', 'unbind_type=1',
        '--data-urlencode', 'jsVersion=4.2.2',
        '--data-urlencode', "program_index=$($script:PageProgram)",
        '--data-urlencode', "page_index=$($script:PageIndex)",
        '--data-urlencode', "v=$((Get-Random -Minimum 500 -Maximum 10500))",
        '--data-urlencode', 'lang=zh-cn') -Label 'mac/unbind' -Referer $ref
    Say "mac/unbind   -> $(BodyText)"

    Start-Sleep -Seconds 2
    if (-not (Test-Online)) { Say 'logged out'; Bye 0 }

    # 2) CAS single sign-on sign-off, then follow the returned switch_uri.
    RunCurl -Extra @('-G', "$base/cas/logout",
        '--data-urlencode', "callback=dr$($rnd + 1)",
        '--data-urlencode', "wlan_user_ip=$cip",
        '--data-urlencode', 'jsVersion=4.2.2',
        '--data-urlencode', "program_index=$($script:PageProgram)",
        '--data-urlencode', "page_index=$($script:PageIndex)",
        '--data-urlencode', "v=$((Get-Random -Minimum 500 -Maximum 10500))",
        '--data-urlencode', 'lang=zh-cn') -Label 'cas/logout' -Referer $ref
    $r2 = BodyText
    Say "cas/logout   -> $r2"
    $sw = ([regex]::Match($r2, '"switch_uri":"([^"]*)"')).Groups[1].Value -replace '\\/', '/'
    if ($sw) {
        Say "cas logout redirect -> $sw"
        RunCurl -Extra @($sw) -Label 'cas logout'
    }

    Start-Sleep -Seconds 3
    if (Test-Online) { Say 'still online after logout'; Bye 2 }
    Say 'logged out'
    Bye 0
}

# ---------------------------------------------------------------- entry
if ($Logout) { Do-Logout }
if (-not $Force -and (Test-Online)) { Say 'Already online, nothing to do'; Bye 0 }
if ($Check) { Say 'Not online'; Bye 1 }
if ($DryRun) { $Force = $true }

$Interactive = -not [Console]::IsInputRedirected
if (-not $User -and $Interactive) {
    $u = Read-Host 'Student/Staff ID'
    if ($u) { $User = $u.Trim() }
}
if (-not $Pass -and $Interactive) {
    $sec  = Read-Host 'Unified-auth password' -AsSecureString
    $Pass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
if (-not $User) { Die 'No account (-User / CAMPUS_USER / campus.conf.ps1 / prompt)' }
if (-not $Pass) { Die 'No password (-Pass / CAMPUS_PASS / campus.conf.ps1 / prompt)' }

# ---------------------------------------------------------------- 1. portal redirect
if ($Redirect) {
    $redir = $Redirect
}
else {
    RunCurl -Extra @($Probe) -Label 'probe'
    $pc = Status
    if ($pc -eq 204) { Say 'Already online, nothing to do'; Bye 0 }
    $redir = HdrVal 'Location'
    if (-not $redir) { $redir = ([regex]::Match((BodyText), "https?://[^'`"]+")).Value }
    if (-not $redir) {
        $b = BodyText
        if ($b.Length -gt 200) { $b = $b.Substring(0, 200) }
        Say ("probe HTTP status = {0}" -f $pc)
        Say ("probe body = [{0}]" -f $b)
        Say ("curl exit = {0}" -f $script:CurExit)
        Say ("curl stderr = " + $(if ($script:CurErr) { $script:CurErr } else { '(empty)' }))
        Die 'No portal redirect. Pass -Redirect "<url>" or check the portal.'
    }
}
Say "Portal redirect: $redir"

function Get-Q([string]$u, [string]$n) {
    $m = [regex]::Match($u, "[?&]$([regex]::Escape($n))=([^&]*)")
    if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}

$scheme = ([regex]::Match($redir, '^(https?)://')).Groups[1].Value
$phost  = ([regex]::Match($redir, '^https?://([^/]+)')).Groups[1].Value -replace ':\d+$', ''
$wip    = Get-Q $redir 'wlanuserip'
$umac   = (Get-Q $redir 'usermac') -replace '[:-]', ''
$acip   = Get-Q $redir 'wlanacip'
$acname = Get-Q $redir 'wlanacname'
if (-not $wip -or -not $umac) { Die "Redirect missing wlanuserip/usermac: $redir" }
Say "ip=$wip mac=$umac ac=$acip/$acname portal=${scheme}://${phost}"

# eportal API: plain HTTP on 801 works for both the domain and the raw IP,
# and avoids any TLS/certificate issue. Verified against this campus.
$ep = "http://${phost}:$EpPort/eportal/portal"

# ---------------------------------------------------------------- 2. cas/create
Get-PageIndices $wip
RunCurl -Extra @('-G', "$ep/cas/create",
    '--data-urlencode', 'callback=cb',
    '--data-urlencode', "program_index=$($script:PageProgram)",
    '--data-urlencode', "page_index=$($script:PageIndex)",
    '--data-urlencode', "v=$((Get-Random -Minimum 500 -Maximum 10500))",
    '--data-urlencode', 'lang=zh-cn',
    '--data-urlencode', 'login_method=1',
    '--data-urlencode', "wlan_user_ip=$wip",
    '--data-urlencode', "wlan_user_mac=$umac",
    '--data-urlencode', "wlan_ac_ip=$acip",
    '--data-urlencode', "wlan_ac_name=$acname",
    '--data-urlencode', 'mac_type=0',
    '--data-urlencode', 'jsVersion=4.1') -Label 'cas/create'

$create = BodyText
if ($create.Length -gt 160) { Say ("cas/create -> " + $create.Substring(0, 160)) }

$m = [regex]::Match($create, '"authorize_uri":"([^"]*)"')
if (-not $m.Success) { Die "cas/create returned no authorize_uri: $create" }
$authz = $m.Groups[1].Value -replace '\\/', '/'
Say "authorize_uri: $authz"

# ---------------------------------------------------------------- 3. execution token
# CAS often answers 302 first (dropping a session cookie) before serving the login
# page, so follow a few hops manually and keep the cookie jar.
$casUrl  = $authz
$casPage = ''
$ticketSeen = $false
for ($hop = 0; $hop -lt 6; $hop++) {
    RunCurl -Extra @('-c', $Jar, '-b', $Jar, $casUrl) -Label 'cas page' | Out-Null
    $st      = Status
    $casPage = BodyText
    Say ("cas page: HTTP {0}, {1} bytes, curl exit={2}" -f $st, $casPage.Length, $script:CurExit)
    if ($st -ge 300 -and $st -lt 400) {
        $loc = HdrVal 'Location'
        if ($loc -match 'ticket=ST-') { $ticketSeen = $true }
        if (-not $loc) { break }
        if ($loc -notmatch '^https?://') {
            $origin = ([regex]::Match($casUrl, '^https?://[^/]+')).Value
            if ($loc.StartsWith('/')) { $loc = $origin + $loc } else { $loc = $origin + '/' + $loc }
        }
        Say ("  -> following Location: {0}" -f $loc)
        $casUrl = $loc
        continue
    }
    break
}
[IO.File]::WriteAllText((Join-Path $WorkDir 'cas-login.html'), $casPage, [Text.Encoding]::UTF8)

if (-not $casPage) {
    Say ("curl exit    : {0}" -f $script:CurExit)
    Say ("curl stderr  : " + $(if ($script:CurErr) { $script:CurErr } else { '(empty)' }))
    Say ("curl version : " + $script:CurlVer)
    Say ("ssl-no-revoke: " + $script:SslNoRevoke)
    Say ("authorize_uri = [" + $authz + "]")
    Die 'CAS page is empty - the CAS server was not reached'
}

# If CAS already trusted this client (IP-level SSO, or the authorization link that
# cas/create just registered) it hands out a ticket immediately and there is no
# login form at all. In that case go straight to the connectivity check.
if ($ticketSeen) {
    Say 'CAS issued a ticket without prompting for credentials'
    Start-Sleep -Seconds 2
    if (Test-Online) { Say 'Login OK, network is up'; Bye 0 }
    Say 'Ticket was seen but the probe is still not 204; falling back to the login form'
}

$m = [regex]::Match($casPage, 'name="execution"\s+value="([^"]+)"')
if (-not $m.Success) {
    Say ("CAS response head: " + $casPage.Substring(0, [Math]::Min(300, $casPage.Length)))
    Die "No execution token (see $WorkDir\cas-login.html)"
}
$exec = $m.Groups[1].Value
Say ("execution: " + $exec.Substring(0, [Math]::Min(32, $exec.Length)) + '...')

# ---------------------------------------------------------------- 4. RSA encrypt
RunCurl -Extra @("$CasBase/jwt/publicKey") -Label 'public key'
$pem = BodyText
if ($pem -notmatch 'BEGIN PUBLIC KEY') { Die 'Failed to fetch CAS public key' }

$b64 = ($pem -replace '-----[^-]+-----', '') -replace '\s', ''
$der = [Convert]::FromBase64String($b64)

function Get-DerLen { param([byte[]]$d, [ref]$i)
    $l = $d[$i.Value]; $i.Value++
    if ($l -band 0x80) {
        $n = $l -band 0x7F; $l = 0
        for ($k = 0; $k -lt $n; $k++) { $l = ($l -shl 8) -bor $d[$i.Value]; $i.Value++ }
    }
    return $l
}

$i = 0
if ($der[$i] -ne 0x30) { Die 'Public key is not SPKI' }; $i++
$null = Get-DerLen $der ([ref]$i)
if ($der[$i] -ne 0x30) { Die 'Missing AlgorithmIdentifier' }; $i++
$algLen = Get-DerLen $der ([ref]$i); $i += $algLen
if ($der[$i] -ne 0x03) { Die 'Missing BIT STRING' }; $i++
$null = Get-DerLen $der ([ref]$i); $i++          # skip the unused-bits byte
if ($der[$i] -ne 0x30) { Die 'Missing RSAPublicKey' }; $i++
$null = Get-DerLen $der ([ref]$i)
if ($der[$i] -ne 0x02) { Die 'Missing modulus' }; $i++
$mLen = Get-DerLen $der ([ref]$i)
$modulus = New-Object byte[] $mLen
[Array]::Copy($der, $i, $modulus, 0, $mLen); $i += $mLen
if ($der[$i] -ne 0x02) { Die 'Missing exponent' }; $i++
$eLen = Get-DerLen $der ([ref]$i)
$exponent = New-Object byte[] $eLen
[Array]::Copy($der, $i, $exponent, 0, $eLen)
if ($modulus[0] -eq 0) { $modulus = $modulus[1..($modulus.Length - 1)] }

$rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
$rsa.PersistKeyInCsp = $false
$rp = New-Object System.Security.Cryptography.RSAParameters
$rp.Modulus  = $modulus
$rp.Exponent = $exponent
$rsa.ImportParameters($rp)
$encB64 = [Convert]::ToBase64String($rsa.Encrypt([Text.Encoding]::UTF8.GetBytes($Pass), $false))
Say ("Password RSA-encrypted ({0} chars base64)" -f $encB64.Length)

if ($DryRun) {
    Say 'dry-run done: whole chain parsed OK, password NOT submitted'
    Say "Would submit: username=$User password=__RSA__<hidden> execution=$($exec.Substring(0,20))... _eventId=submit"
    Bye 0
}

# ---------------------------------------------------------------- 5. submit to CAS
$uri    = $authz
$method = 'POST'
$final  = $null
$sawTicket = $false

for ($hop = 0; $hop -lt 10; $hop++) {
    if ($method -eq 'POST') {
        RunCurl -Extra @('-c', $Jar, '-b', $Jar,
            '--data-urlencode', "username=$User",
            '--data-urlencode', "password=__RSA__$encB64",
            '--data-urlencode', "execution=$exec",
            '--data-urlencode', '_eventId=submit',
            '--data-urlencode', 'geolocation=',
            '--data-urlencode', 'mfaState=',
            '--data-urlencode', 'currentMenu=1',
            '--data-urlencode', 'failN=-1',
            $uri) -Label 'cas post'
    } else {
        RunCurl -Extra @('-c', $Jar, '-b', $Jar, $uri) -Label 'redirect'
    }

    $code = Status
    if ($code -ge 300 -and $code -lt 400) {
        $loc = HdrVal 'Location'
        if ($loc -match 'ticket=ST-') { $sawTicket = $true }
        Say ("  [{0}] -> {1}" -f $code, $loc)
        $uri = $loc; $method = 'GET'; continue
    }
    $final = @{ Code = $code; Body = (BodyText) }
    break
}

if ($sawTicket) { Say 'CAS issued a ticket' }
else            { Say 'No ticket seen; CAS may have rejected this login' }

if ($final) {
    Say ("final HTTP status = {0}" -f $final.Code)
    if ($final.Body) {
        [IO.File]::WriteAllText((Join-Path $WorkDir 'post.html'), $final.Body, [Text.Encoding]::UTF8)
        $err = [regex]::Match($final.Body, 'id="loginError1"[^>]*>\s*([^<]{2,80})')
        if ($err.Success) { Say ("CAS says: " + $err.Groups[1].Value.Trim()) }
    }
}

# ---------------------------------------------------------------- 6. verify
Start-Sleep -Seconds 2
if (Test-Online) { Say 'Login OK, network is up'; Bye 0 }
Say "Still offline. Dump dir: $WorkDir"
Bye 2
