# Requires: isolated OHOS env sourced below. OpenHarmony 本地 debug 签名。
# 每个 keystore 内置自签根 CA -> app/profile 叶证书由该 CA 签发，均以链提供。
# sign-profile 生成 .p7b(注入 app 证书链), sign-app 签 HAP。日志写 app\ohos\signing\sign.log。
param(
    [string]$UnsignedHap = "build\ohos\hap\entry-default-unsigned.hap",
    [string]$SignedHap   = "build\ohos\hap\entry-default-signed.hap"
)
$ErrorActionPreference = "Continue"
$Root    = Split-Path $PSScriptRoot -Parent
$AppDir  = Join-Path $Root "app"
$SignDir = Join-Path $AppDir "ohos\signing"
$LogPath = Join-Path $SignDir "sign.log"
. (Join-Path $PSScriptRoot "use-env.ps1") -Ohos | Out-Null

$tool   = "D:\HuaWei\Sdk\26.0.0\toolchains\lib\hap-sign-tool.jar"
$PWD    = "123456"
$BUNDLE = "com.gamepouch.gamepouch"
$CA_SUBJ  = "C=CN,O=OpenHarmony,OU=OpenHarmony,CN=OpenHarmony CA"
$APP_SUBJ = "C=CN,O=OpenHarmony,OU=OpenHarmony,CN=OpenHarmony Application Release"
$PRF_SUBJ = "C=CN,O=OpenHarmony,OU=OpenHarmony,CN=OpenHarmony Profile"

New-Item -ItemType Directory -Force -Path $SignDir | Out-Null
"" | Set-Content $LogPath
function Step($name, [string[]]$cmdArgs) {
    "=== $name ===" | Write-Host; "=== $name ===" | Add-Content $LogPath
    $out = & java -jar $tool @cmdArgs 2>&1 | Out-String
    $out | Write-Host; $out | Add-Content $LogPath
    "--- exit: $LASTEXITCODE ---" | Write-Host; "--- exit: $LASTEXITCODE ---" | Add-Content $LogPath
}
function MakeChain([string]$outFile, [string[]]$parts) {
    $buf = @()
    foreach ($p in $parts) { if (Test-Path $p) { $buf += ([System.IO.File]::ReadAllText($p)).TrimEnd() } }
    # 仅去除 base64 数据行中的空格（保留 -----BEGIN/END CERTIFICATE----- 头尾的空格）
    $lines = ($buf -join "`n") -split "`n" | ForEach-Object {
        if ($_ -match '-----') { $_ } else { $_ -replace ' ','' }
    }
    [System.IO.File]::WriteAllText($outFile, ($lines -join "`n"))
    "=== chain $outFile ===" | Write-Host
}

# 将多个 PEM 证书解码为 DER 字节拼接，再整体 base64url 编码。
# sign-app 把 development-certificate 当作【整段 base64url】，解码后应得到
# cert1_DER||cert2_DER（一条证书链），故必须先拼 DER 再编码，不能各自编码后拼接。
function ChainBody([string[]]$parts) {
    $der = [System.Byte[]]::new(0)
    foreach ($p in $parts) {
        if (Test-Path $p) {
            $txt = [System.IO.File]::ReadAllText($p)
            foreach ($m in [regex]::Matches($txt, '-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----', [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
                $b64 = ($m.Groups[1].Value -replace '\s+', '').Trim()
                if ($b64.Length -gt 0) { $der = $der + [System.Convert]::FromBase64String($b64) }
            }
        }
    }
    return ([System.Convert]::ToBase64String($der)).Replace('+', '-').Replace('/', '_').TrimEnd('=')
}

Get-ChildItem $SignDir -File | Where-Object { $_.Extension -in '.p12','.cer','.p7b','.json' } |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

$udid = (& hdc shell bm get --udid 2>&1 | Select-Object -Last 1).Trim()
"device udid: $udid" | Write-Host; "device udid: $udid" | Add-Content $LogPath

# ===== debug.p12: 根 CA + app 叶证书 =====
Step "app CA keypair" @("generate-keypair","-keyAlias","ohosRootCa","-keyAlg","ECC","-keySize","NIST-P-256",
    "-keystoreFile","$SignDir\debug.p12","-keystorePwd",$PWD,"-keyPwd",$PWD)
Step "app CA cert" @("generate-cert","-keyAlias","ohosRootCa","-keystoreFile","$SignDir\debug.p12",
    "-keystorePwd",$PWD,"-keyPwd",$PWD,"-issuer",$CA_SUBJ,"-issuerKeyAlias","ohosRootCa","-issuerKeyPwd",$PWD,
    "-subject",$CA_SUBJ,"-validity","3650","-keyUsage","certificateSignature,crlSignature",
    "-signAlg","SHA256withECDSA","-basicConstraintsCa","1","-outFile","$SignDir\ca-app.cer")
Step "app keypair" @("generate-keypair","-keyAlias","ohosDebug","-keyAlg","ECC","-keySize","NIST-P-256",
    "-keystoreFile","$SignDir\debug.p12","-keystorePwd",$PWD,"-keyPwd",$PWD)
Step "app cert" @("generate-cert","-keyAlias","ohosDebug","-keystoreFile","$SignDir\debug.p12",
    "-keystorePwd",$PWD,"-keyPwd",$PWD,"-issuer",$CA_SUBJ,"-issuerKeyAlias","ohosRootCa","-issuerKeyPwd",$PWD,
    "-subject",$APP_SUBJ,"-validity","365","-keyUsage","digitalSignature","-extKeyUsage","codeSignature",
    "-signAlg","SHA256withECDSA","-outFile","$SignDir\app.cer")
MakeChain "$SignDir\debug-app-chain.cer" @("$SignDir\app.cer","$SignDir\ca-app.cer")

# ===== debug-profile.p12: 根 CA + profile 叶证书 =====
Step "prf CA keypair" @("generate-keypair","-keyAlias","ohosRootCa","-keyAlg","ECC","-keySize","NIST-P-256",
    "-keystoreFile","$SignDir\debug-profile.p12","-keystorePwd",$PWD,"-keyPwd",$PWD)
Step "prf CA cert" @("generate-cert","-keyAlias","ohosRootCa","-keystoreFile","$SignDir\debug-profile.p12",
    "-keystorePwd",$PWD,"-keyPwd",$PWD,"-issuer",$CA_SUBJ,"-issuerKeyAlias","ohosRootCa","-issuerKeyPwd",$PWD,
    "-subject",$CA_SUBJ,"-validity","3650","-keyUsage","certificateSignature,crlSignature",
    "-signAlg","SHA256withECDSA","-basicConstraintsCa","1","-outFile","$SignDir\ca-profile.cer")
Step "prf keypair" @("generate-keypair","-keyAlias","ohosProfile","-keyAlg","ECC","-keySize","NIST-P-256",
    "-keystoreFile","$SignDir\debug-profile.p12","-keystorePwd",$PWD,"-keyPwd",$PWD)
Step "prf cert" @("generate-cert","-keyAlias","ohosProfile","-keystoreFile","$SignDir\debug-profile.p12",
    "-keystorePwd",$PWD,"-keyPwd",$PWD,"-issuer",$CA_SUBJ,"-issuerKeyAlias","ohosRootCa","-issuerKeyPwd",$PWD,
    "-subject",$PRF_SUBJ,"-validity","365","-keyUsage","digitalSignature","-extKeyUsage","codeSignature",
    "-signAlg","SHA256withECDSA","-outFile","$SignDir\profile.cer")
MakeChain "$SignDir\debug-profile-chain.cer" @("$SignDir\profile.cer","$SignDir\ca-profile.cer")

# ===== debug profile 模板（注入 app 叶证书 + udid + 刷新有效期）=====
# development-certificate 必须是【证书链】，但 sign-app 会对其做 base64 解码，
# 若带 -----BEGIN/END CERTIFICATE----- 头尾（含空格）会报 "Illegal base64 character 20"。
# 故注入去头尾的纯 base64 链（叶证书 + CA，换行分隔）。与 -appCertFile(app.cer 叶证书) 同根 CA。
$appCertPem = ChainBody @("$SignDir\app.cer","$SignDir\ca-app.cer")
$nb = [int][double]::Parse((Get-Date -Date (Get-Date).AddDays(-1) -UFormat %s))
$na = [int][double]::Parse((Get-Date -Date (Get-Date).AddDays(365) -UFormat %s))
$profile = [ordered]@{
    "version-name" = "2.0.0"; "version-code" = 2; "uuid" = [guid]::NewGuid().ToString()
    "validity"     = @{ "not-before" = $nb; "not-after" = $na }
    "type"         = "debug"
    "bundle-info"  = @{ "developer-id" = "OpenHarmony"; "development-certificate" = $appCertPem
                        "bundle-name" = $BUNDLE; "apl" = "normal"; "app-feature" = "hos_normal_app" }
    "acls" = @{ "allowed-acls" = @("") }
    "permissions" = @{ "restricted-permissions" = @("") }
    "debug-info"  = @{ "device-ids" = @($udid); "device-id-type" = "udid" }
    "issuer"      = "pki_internal"
}
$tmpl = Join-Path $SignDir "debug-profile-template.json"
[System.IO.File]::WriteAllText($tmpl, ($profile | ConvertTo-Json -Depth 6))

# ===== 签 profile + 签 HAP =====
Step "sign-profile" @("sign-profile","-mode","localSign","-keyAlias","ohosProfile","-keystoreFile","$SignDir\debug-profile.p12",
    "-keystorePwd",$PWD,"-keyPwd",$PWD,"-profileCertFile","$SignDir\debug-profile-chain.cer",
    "-inFile",$tmpl,"-outFile","$SignDir\debug.p7b","-signAlg","SHA256withECDSA")
Step "sign-app" @("sign-app","-mode","localSign","-keyAlias","ohosDebug","-keystoreFile","$SignDir\debug.p12",
    "-keystorePwd",$PWD,"-keyPwd",$PWD,"-profileFile","$SignDir\debug.p7b","-appCertFile","$SignDir\debug-app-chain.cer",
    "-profileSigned","1","-inFile","$UnsignedHap","-outFile","$SignedHap","-signAlg","SHA256withECDSA")

Write-Host "=== RESULT ==="
Get-ChildItem $SignDir -File | Select-Object Name,Length | Format-Table | Out-Host
if (Test-Path $SignedHap) { "SIGNED HAP OK: $SignedHap ($((Get-Item $SignedHap).Length) bytes)" } else { "SIGNED HAP MISSING" }
