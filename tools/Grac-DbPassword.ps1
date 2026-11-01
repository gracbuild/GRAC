<#
.SYNOPSIS
    Encrypts (and verifies) the SQL Server password for the Practice
    Management API's ConnectionStrings:Password setting.

.DESCRIPTION
    Reproduces PracticeManagement.Api.Infrastructure.SqlConnectionStringResolver
    (and PracticeRepositoryService.DecryptPassword) exactly:

        ConnectionStrings:Password = "<key>~<base64 ciphertext>"
        AES-256-CBC, PKCS7
        AES key = UTF-8 bytes of <key>.Substring(4, 32)
        AES IV  = UTF-8 bytes of <key>.ToLowerInvariant().Substring(4, 16)

    At start-up the API decrypts the value and APPENDS the plaintext to
    ConnectionStrings:DbConnection, so DbConnection must end with
    "Password=" and carry no password of its own:

        "DbConnection": "Data Source=<server>;Initial Catalog=<db>;User ID=<login>;Password=",
        "Password":     "<output of this script>"

    Two uses:

      ENCRYPT - (default) produces the "<key>~<ciphertext>" value. A new
                random key is generated unless -Key is given, so every
                environment (UAT, Production) gets its own key.

      VERIFY  - -Encrypted '<key>~<ciphertext>' checks that a configured
                value decrypts to the password you supply. The plaintext is
                never printed.

.PARAMETER Password
    The SQL login's password (plaintext).

.PARAMETER Key
    Optional. An existing key to reuse (36+ ASCII characters). Omit it to
    generate a new one.

.PARAMETER Encrypted
    An existing ConnectionStrings:Password value. Supplying it switches the
    script to verify mode.

.EXAMPLE
    # Production: new key, encrypt the password
    .\Grac-DbPassword.ps1 -Password 'Pr0d#Secret'

.EXAMPLE
    # Is the deployed value really this password?
    .\Grac-DbPassword.ps1 -Password 'Pr0d#Secret' -Encrypted '9202B4...~K0iy7+...=='

.NOTES
    Runs on Windows PowerShell 5.1 and PowerShell 7+.
    The key travels in the same setting as the ciphertext: this keeps the
    password out of plain sight in appsettings.json and source control, it
    does not protect it from someone who can read the deployed file. Restrict
    the file's NTFS permissions to the IIS app pool identity and administrators.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Password,

    [Parameter()]
    [string] $Key,

    [Parameter()]
    [string] $Encrypted
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-GracAes {
    param([string] $KeyText)
    if ($KeyText.Length -lt 36) {
        throw "The key must be at least 36 characters (the API reads characters 5-36). Got $($KeyText.Length)."
    }
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($KeyText.Substring(4, 32))
    $ivBytes  = [System.Text.Encoding]::UTF8.GetBytes($KeyText.ToLowerInvariant().Substring(4, 16))
    if ($keyBytes.Length -ne 32 -or $ivBytes.Length -ne 16) {
        throw "The key must be plain ASCII so that it gives a 32-byte AES key and a 16-byte IV."
    }
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key     = $keyBytes
    $aes.IV      = $ivBytes
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    return $aes
}

function Protect-GracPassword {
    param([string] $KeyText, [string] $Plaintext)
    $aes = New-GracAes -KeyText $KeyText
    try {
        $enc   = $aes.CreateEncryptor()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Plaintext)
        return [Convert]::ToBase64String($enc.TransformFinalBlock($bytes, 0, $bytes.Length))
    }
    finally { $aes.Dispose() }
}

function Unprotect-GracPassword {
    param([string] $KeyText, [string] $CipherText)
    $aes = New-GracAes -KeyText $KeyText
    try {
        $dec   = $aes.CreateDecryptor()
        $bytes = [Convert]::FromBase64String($CipherText)
        return [System.Text.Encoding]::UTF8.GetString($dec.TransformFinalBlock($bytes, 0, $bytes.Length))
    }
    finally { $aes.Dispose() }
}

# The plaintext is appended to "...;Password=" unquoted, so SqlClient would
# split a password at ';' and trim surrounding spaces / quotes.
if ($Password -match ';' -or $Password -ne $Password.Trim() -or $Password -match '^[''"]') {
    Write-Host "WARNING - the password contains ';', leading/trailing spaces or a leading quote." -ForegroundColor Red
    Write-Host "The API appends it to 'Password=' unquoted, so SQL Server would receive a different value." -ForegroundColor Red
    Write-Host "Choose a password without these characters." -ForegroundColor Red
    exit 2
}

if ($PSBoundParameters.ContainsKey('Encrypted') -and -not [string]::IsNullOrWhiteSpace($Encrypted)) {
    # ---------------- verify ----------------
    $parts = $Encrypted.Trim().Split([char[]]@('~'), 2)
    if ($parts.Length -ne 2) {
        Write-Host "INVALID FORMAT - expected '<key>~<ciphertext>'. The API refuses this value at start-up." -ForegroundColor Red
        exit 2
    }
    try   { $plain = Unprotect-GracPassword -KeyText $parts[0] -CipherText $parts[1] }
    catch {
        Write-Host "CANNOT DECRYPT - $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "The API would fail the same way on its first database call." -ForegroundColor Red
        exit 2
    }
    Write-Host ""
    if ($plain -ceq $Password) {
        Write-Host "MATCH - the value decrypts to the password you supplied." -ForegroundColor Green
        exit 0
    }
    Write-Host "NO MATCH - the value decrypts, but to a different password." -ForegroundColor Red
    exit 1
}

# ---------------- encrypt ----------------
if ([string]::IsNullOrWhiteSpace($Key)) {
    # 32 random bytes as 64 hex characters, the same shape as the existing keys.
    $random = [byte[]]::new(32)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try   { $rng.GetBytes($random) }
    finally { $rng.Dispose() }
    $Key = -join ($random | ForEach-Object { $_.ToString('X2') })
}

$cipher = Protect-GracPassword -KeyText $Key -Plaintext $Password
# Prove the round trip before handing the value over.
if ((Unprotect-GracPassword -KeyText $Key -CipherText $cipher) -cne $Password) {
    throw "Round-trip check failed; do not use this output."
}
$value = "$Key~$cipher"

Write-Host ""
Write-Host "ConnectionStrings:Password value:" -ForegroundColor Green
Write-Host $value
Write-Host ""
Write-Host "Put this in the deployed PracticeManagement.Api appsettings.json:" -ForegroundColor Green
Write-Host ""
Write-Host '  "ConnectionStrings": {'
Write-Host '    "DbConnection": "Data Source=<server>;Initial Catalog=<database>;User ID=<login>;Password=",'
Write-Host "    `"Password`": `"$value`""
Write-Host '  }'
Write-Host ""
Write-Host "DbConnection must END with 'Password=' - the API appends the decrypted password." -ForegroundColor Yellow
Write-Host "Do not also set ConnectionStrings:PracticeManagement: when present it wins and these two are ignored." -ForegroundColor Yellow
Write-Host ""
