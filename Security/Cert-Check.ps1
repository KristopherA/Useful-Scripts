<#
.SYNOPSIS
    Validate local certificate files and remote TLS services using OpenSSL.

.DESCRIPTION
    Local files (PEM, DER, PKCS#12/PFX, PKCS#7/P7B): parse, print a summary
    (subject, issuer, serial, validity, SHA-256 fingerprint, SAN, key usage),
    check expiry, verify the trust chain against a CA bundle, check the
    expected hostname against the SAN, and confirm a private key matches.

    Remote services: connect with openssl s_client (optionally STARTTLS for
    SMTP/LDAP/IMAP/POP3), verify chain + hostname, and print leaf details.

    PowerShell port of cert_check.sh. Works on Windows PowerShell 5.1 and
    PowerShell 7+ (Windows, macOS, Linux).

.PARAMETER File
    Local certificate or bundle to validate.
.PARAMETER Type
    auto, pem, der, p12, pfx, p7b, p7c. Default auto (by file extension).
.PARAMETER CAFile
    CA bundle or root CA PEM used for trust validation.
.PARAMETER Intermediate
    Intermediate PEM bundle.
.PARAMETER Hostname
    Expected hostname to look for in the SAN.
.PARAMETER Key
    Private key file for key/certificate match validation.
.PARAMETER Password
    PKCS#12 password. Defaults to $env:CERT_CHECK_PASSWORD. It is passed to
    OpenSSL via an environment variable, not on the command line.
.PARAMETER Remote
    Remote service hostname.
.PARAMETER Port
    Remote port. Default 443.
.PARAMETER Service
    https, smtp, ldap, imap, pop3, generic. Default https.

.EXAMPLE
    .\Cert-Check.ps1 -File server.pem -CAFile ca-bundle.pem -Hostname app.example.com
.EXAMPLE
    $env:CERT_CHECK_PASSWORD = 'secret'; .\Cert-Check.ps1 -File bundle.p12 -CAFile root.pem
.EXAMPLE
    .\Cert-Check.ps1 -File chain.p7b
.EXAMPLE
    .\Cert-Check.ps1 -Remote www.example.com -Port 443 -Service https
.EXAMPLE
    .\Cert-Check.ps1 -Remote mail.example.com -Port 25 -Service smtp
.EXAMPLE
    .\Cert-Check.ps1 -File cert.pem -Key key.pem

.NOTES
    Requires: openssl in PATH (OpenSSL 1.1.1+ recommended).
    Exit codes: 0 = no FAIL, 1 = one or more FAIL, 2 = usage/setup error.
#>
[CmdletBinding()]
param(
    [string]$File,
    [ValidateSet("auto","pem","der","p12","pfx","p7b","p7c")]
    [string]$Type = "auto",
    [string]$CAFile,
    [string]$Intermediate,
    [string]$Hostname,
    [string]$Key,
    [string]$Password = $env:CERT_CHECK_PASSWORD,
    [string]$Remote,
    [ValidateRange(1,65535)]
    [int]$Port = 443,
    [ValidateSet("https","smtp","ldap","imap","pop3","generic")]
    [string]$Service = "https"
)

$script:Failures = 0
function Write-Pass([string]$Message) { Write-Host "[PASS] $Message" -ForegroundColor Green }
function Write-Fail([string]$Message) { Write-Host "[FAIL] $Message" -ForegroundColor Red; $script:Failures++ }
function Write-Info([string]$Message) { Write-Host "[INFO] $Message" }
function Write-Warn([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }

function Get-DetectedType([string]$Path) {
    $lower = $Path.ToLowerInvariant()
    if ($lower.EndsWith(".pem") -or $lower.EndsWith(".crt")) { return "pem" }
    if ($lower.EndsWith(".cer") -or $lower.EndsWith(".der")) { return "der" }
    if ($lower.EndsWith(".p12") -or $lower.EndsWith(".pfx") -or $lower.EndsWith(".pkcs12")) { return "p12" }
    if ($lower.EndsWith(".p7b") -or $lower.EndsWith(".p7c") -or $lower.EndsWith(".pkcs7")) { return "p7b" }
    return "pem"
}

# Run openssl with an argument array (no cmd.exe, no string quoting issues).
# Deliberately a simple (non-advanced) function so tokens like -in/-noout
# land in $args and are passed straight through to openssl.
function Invoke-OpenSSL {
    & openssl @args 2>&1 | ForEach-Object { "$_" }
}

function Show-X509Summary([string]$CertPath) {
    Invoke-OpenSSL x509 -in $CertPath -noout -subject -issuer -serial -dates -fingerprint -sha256
    $text = Invoke-OpenSSL x509 -in $CertPath -text -noout
    Write-Host ""
    Write-Info "Subject Alternative Name"
    $text | Select-String -Context 0,1 "Subject Alternative Name" | ForEach-Object { $_.ToString() }
    Write-Host ""
    Write-Info "Key Usage / Extended Key Usage / Basic Constraints"
    $text | Select-String -Context 0,1 "X509v3 (Key Usage|Extended Key Usage|Basic Constraints)" | ForEach-Object { $_.ToString() }
    Write-Host ""
    Write-Info "Public Key / Signature"
    $text | Select-String "Signature Algorithm|Public-Key:" | ForEach-Object { $_.Line.Trim() } | Select-Object -Unique
}

function Test-Expiry([string]$CertPath) {
    $null = Invoke-OpenSSL x509 -in $CertPath -noout -checkend 0
    if ($LASTEXITCODE -ne 0) { Write-Fail "Certificate is expired"; return }
    $null = Invoke-OpenSSL x509 -in $CertPath -noout -checkend 2592000
    if ($LASTEXITCODE -ne 0) { Write-Warn "Certificate expires within 30 days" }
    else { Write-Pass "Certificate is within its validity period" }
}

function Test-Trust([string]$CertPath, [string]$IntermediatePath) {
    if ($CAFile -and $IntermediatePath) {
        Invoke-OpenSSL verify -CAfile $CAFile -untrusted $IntermediatePath $CertPath
        if ($LASTEXITCODE -eq 0) { Write-Pass "Trust chain validation succeeded" } else { Write-Fail "Trust chain validation failed" }
    }
    elseif ($CAFile) {
        Invoke-OpenSSL verify -CAfile $CAFile $CertPath
        if ($LASTEXITCODE -eq 0) { Write-Pass "Trust validation succeeded" } else { Write-Fail "Trust validation failed" }
    }
    else {
        Write-Warn "No -CAFile supplied, skipping trust validation"
    }
}

function Test-HostnameLocal([string]$CertPath, [string]$ExpectedName) {
    if (-not $ExpectedName) { return }
    $text = (Invoke-OpenSSL x509 -in $CertPath -text -noout) -join "`n"
    $sanNames = [regex]::Matches($text, 'DNS:([^,\s]+)') | ForEach-Object { $_.Groups[1].Value }
    if ($sanNames -contains $ExpectedName) {   # -contains is case-insensitive
        Write-Pass "Hostname found in SAN: $ExpectedName"
    } else {
        Write-Warn "Hostname not found with exact DNS match in SAN (wildcards not evaluated): $ExpectedName"
    }
}

function Test-KeyMatch([string]$CertPath, [string]$KeyPath, [string]$WorkingDir) {
    if (-not $KeyPath) { return }
    $certPub = Join-Path $WorkingDir "cert.pub.pem"
    $null = Invoke-OpenSSL x509 -in $CertPath -pubkey -noout -out $certPub
    $certKey = (Invoke-OpenSSL pkey -pubin -in $certPub -outform pem) -join "`n"
    $certOk = ($LASTEXITCODE -eq 0)
    $keyKey  = (Invoke-OpenSSL pkey -in $KeyPath -pubout -outform pem) -join "`n"
    $keyOk = ($LASTEXITCODE -eq 0)
    if ($certOk -and $keyOk -and $certKey -and ($certKey -ceq $keyKey)) {
        Write-Pass "Certificate and private key match"
    } else {
        Write-Fail "Certificate and private key do not match, or key could not be read"
    }
}

function Test-PemOrDer([string]$InputPath, [string]$Mode, [string]$WorkingDir) {
    $certPath = Join-Path $WorkingDir "leaf.pem"
    if ($Mode -eq "der") {
        $null = Invoke-OpenSSL x509 -inform DER -in $InputPath -out $certPath
        if ($LASTEXITCODE -ne 0) { Write-Fail "DER certificate could not be parsed"; exit 1 }
    } else {
        Copy-Item -LiteralPath $InputPath -Destination $certPath -Force
        $null = Invoke-OpenSSL x509 -in $certPath -noout
        if ($LASTEXITCODE -ne 0) { Write-Fail "PEM certificate could not be parsed"; exit 1 }
    }
    Write-Pass "Certificate parsed successfully"
    Show-X509Summary $certPath
    Test-Expiry $certPath
    Test-Trust $certPath $Intermediate
    Test-HostnameLocal $certPath $Hostname
    Test-KeyMatch $certPath $Key $WorkingDir
}

function Test-P12([string]$InputPath, [string]$WorkingDir) {
    $certPath = Join-Path $WorkingDir "p12-cert.pem"
    $caPath   = Join-Path $WorkingDir "p12-ca.pem"
    $keyPath  = Join-Path $WorkingDir "p12-key.pem"

    # Pass the password through the environment rather than argv.
    $env:CERT_CHECK_P12_PASS = $Password
    $passArgs = @("-passin", "env:CERT_CHECK_P12_PASS")
    try {
        $null = Invoke-OpenSSL pkcs12 -in $InputPath @passArgs -info -nodes -nokeys
        if ($LASTEXITCODE -ne 0) { Write-Fail "PKCS#12 bundle could not be parsed (wrong password, or legacy encryption - try OpenSSL 3 with -legacy)"; exit 1 }
        Write-Pass "PKCS#12 bundle parsed successfully"

        $null = Invoke-OpenSSL pkcs12 -in $InputPath @passArgs -clcerts -nokeys -out $certPath
        $null = Invoke-OpenSSL pkcs12 -in $InputPath @passArgs -cacerts -nokeys -out $caPath
        $null = Invoke-OpenSSL pkcs12 -in $InputPath @passArgs -nocerts -nodes -out $keyPath
    }
    finally {
        Remove-Item Env:\CERT_CHECK_P12_PASS -ErrorAction SilentlyContinue
    }

    if (-not ((Test-Path $certPath) -and (Get-Item $certPath).Length -gt 0)) {
        Write-Fail "No leaf certificate found in PKCS#12 bundle"; exit 1
    }
    Write-Pass "Leaf certificate extracted from PKCS#12"
    Show-X509Summary $certPath
    Test-Expiry $certPath

    if ($CAFile) {
        $chain = $Intermediate
        if (-not $chain -and (Test-Path $caPath) -and (Get-Item $caPath).Length -gt 0) { $chain = $caPath }
        Test-Trust $certPath $chain
    } else {
        Write-Warn "No -CAFile supplied, trust validation skipped"
    }

    Test-HostnameLocal $certPath $Hostname
    if ((Test-Path $keyPath) -and (Get-Item $keyPath).Length -gt 0) {
        Test-KeyMatch $certPath $keyPath $WorkingDir
    } else {
        Write-Warn "No private key extracted from PKCS#12"
    }
}

function Test-P7B([string]$InputPath) {
    $inform = "PEM"
    $null = Invoke-OpenSSL pkcs7 -in $InputPath -print_certs -noout
    if ($LASTEXITCODE -ne 0) {
        $null = Invoke-OpenSSL pkcs7 -inform DER -in $InputPath -print_certs -noout
        if ($LASTEXITCODE -ne 0) { Write-Fail "PKCS#7 bundle could not be parsed"; exit 1 }
        $inform = "DER"
    }
    Write-Pass "PKCS#7 bundle parsed successfully ($inform)"
    Write-Info "Certificates found in PKCS#7 bundle"
    Invoke-OpenSSL pkcs7 -inform $inform -in $InputPath -print_certs -text -noout
    Write-Warn "PKCS#7 usually contains certificates only and not a private key"
}

function Test-Remote([string]$RemoteHost, [int]$RemotePort, [string]$Mode, [string]$WorkingDir) {
    $sclientArgs = @("s_client")
    if ($Mode -in @("smtp","ldap","imap","pop3")) { $sclientArgs += @("-starttls", $Mode) }
    $sclientArgs += @("-connect", "$($RemoteHost):$RemotePort", "-servername", $RemoteHost,
                      "-verify_hostname", $RemoteHost, "-showcerts")

    Write-Info "Connecting to $($RemoteHost):$RemotePort with service=$Mode"
    $out = '' | & openssl @sclientArgs 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { Write-Warn "s_client returned non-zero status, review output below" }

    $out | Select-Object -First 220
    Write-Host ""
    $raw = $out -join "`n"
    if ($raw -match [regex]::Escape("Verify return code: 0 (ok)")) {
        Write-Pass "Remote verification returned code 0"
    } else {
        Write-Fail "Remote verification did not return code 0"
    }

    $m = [regex]::Match($raw, '-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----')
    if ($m.Success) {
        $leaf = Join-Path $WorkingDir "remote-leaf.pem"
        Set-Content -LiteralPath $leaf -Value $m.Value -Encoding Ascii
        Invoke-OpenSSL x509 -in $leaf -noout -subject -issuer -dates -fingerprint -sha256
        Write-Pass "Remote leaf certificate extracted"
        Test-Expiry $leaf
    } else {
        Write-Fail "Could not extract remote leaf certificate"
    }
}

# ── Main ───────────────────────────────────────────────────────────────
if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    Write-Error "OpenSSL was not found in PATH."
    exit 2
}

if (-not $File -and -not $Remote) {
    Get-Help $PSCommandPath -Detailed
    exit 2
}

if ($File -and $Remote) {
    Write-Error "Use either -File or -Remote, not both."
    exit 2
}

$workingDir = Join-Path ([System.IO.Path]::GetTempPath()) ("certcheck_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $workingDir | Out-Null

try {
    if ($File) {
        if (-not (Test-Path -LiteralPath $File)) {
            Write-Error "File not found: $File"
            exit 2
        }
        $File = (Resolve-Path -LiteralPath $File).ProviderPath

        if ($Type -eq "auto") { $Type = Get-DetectedType $File }

        Write-Info "File validation started"
        Write-Info "Detected type: $Type"

        switch ($Type) {
            "pem" { Test-PemOrDer $File "pem" $workingDir }
            "der" { Test-PemOrDer $File "der" $workingDir }
            "p12" { Test-P12 $File $workingDir }
            "pfx" { Test-P12 $File $workingDir }
            "p7b" { Test-P7B $File }
            "p7c" { Test-P7B $File }
        }
    }

    if ($Remote) {
        Test-Remote $Remote $Port $Service $workingDir
    }

    if ($script:Failures -gt 0) {
        Write-Info "Validation completed with $($script:Failures) failure(s)"
        exit 1
    }
    Write-Pass "Validation completed"
    exit 0
}
finally {
    Remove-Item -LiteralPath $workingDir -Recurse -Force -ErrorAction SilentlyContinue
}
