<#
.SYNOPSIS
    Generates and verifies GRAC Practice Management password hashes.

.DESCRIPTION
    Reproduces PracticeManagement.Web.Security.PasswordHasher exactly:
    PBKDF2-SHA256, 210,000 iterations, 16-byte salt, 32-byte key, encoded as
    "<iterations>.<base64 salt>.<base64 hash>".

    Two uses:

      VERIFY  — answers "what password is this account actually set to?".
                The login screen returns the same message for a wrong password
                and a missing account, so this is the only way to tell a bad
                password from a bad row once _diag_user_login.sql has shown the
                row is fine.

      GENERATE — produces a hash to paste into a reset UPDATE, for accounts
                created before the default-password provisioning existed
                (migration 208) whose password nobody remembers.

    A hash cannot be produced in T-SQL: the format has to match what
    PasswordHasher.Verify accepts, and SQL Server has no PBKDF2. Hence this
    script.

.PARAMETER Password
    The plaintext to hash, or to test against -Hash.

.PARAMETER Hash
    An existing stored hash. Supplying it switches the script to verify mode.

.PARAMETER EmployeeId
    Optional. When generating, prints a ready-to-run reset UPDATE for this
    employee_id.

.EXAMPLE
    # Is this account really set to Grac@123?
    .\Grac-Password.ps1 -Password 'Grac@123' -Hash '210000.abc...=.def...='

.EXAMPLE
    # Reset employee 42 to the default and force a change at next sign-in
    .\Grac-Password.ps1 -Password 'Grac@123' -EmployeeId 42

.NOTES
    Runs on Windows PowerShell 5.1 and PowerShell 7+.
    Verification takes about a second — 210,000 iterations is the point.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Password,

    [Parameter()]
    [string] $Hash,

    [Parameter()]
    [long] $EmployeeId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Must stay identical to PasswordHasher.Iterations.
$script:Iterations = 210000

function Get-Pbkdf2Bytes {
    param(
        [string] $Plaintext,
        [byte[]] $Salt,
        [int]    $IterationCount,
        [int]    $Length
    )
    # PasswordHasher uses Rfc2898DeriveBytes.Pbkdf2(string, ...), which encodes
    # the password as UTF-8. Matching that matters for non-ASCII passwords.
    $passwordBytes = [System.Text.Encoding]::UTF8.GetBytes($Plaintext)
    $deriver = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
        $passwordBytes, $Salt, $IterationCount,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try   { return $deriver.GetBytes($Length) }
    finally { $deriver.Dispose() }
}

if ($PSBoundParameters.ContainsKey('Hash') -and -not [string]::IsNullOrWhiteSpace($Hash)) {
    # ---------------- verify ----------------
    $parts = $Hash.Trim().Split('.')
    if ($parts.Length -ne 3) {
        Write-Host "INVALID FORMAT - expected '<iterations>.<salt>.<hash>', got $($parts.Length) part(s)." -ForegroundColor Red
        Write-Host "This value can never verify. Reset the account." -ForegroundColor Red
        exit 2
    }

    $iterationCount = 0
    if (-not [int]::TryParse($parts[0], [ref] $iterationCount) -or $iterationCount -lt 100000) {
        # PasswordHasher.Verify rejects anything under 100,000 outright.
        Write-Host "INVALID ITERATIONS - '$($parts[0])'. PasswordHasher.Verify rejects this before hashing." -ForegroundColor Red
        exit 2
    }

    $salt     = [Convert]::FromBase64String($parts[1])
    $expected = [Convert]::FromBase64String($parts[2])
    $actual   = Get-Pbkdf2Bytes -Plaintext $Password -Salt $salt -IterationCount $iterationCount -Length $expected.Length

    # Compare the base64 encodings rather than the byte arrays. PowerShell
    # cannot infer the type argument for the generic Enumerable.SequenceEqual
    # overload, and re-encoding is exact: same length, same bytes, same string.
    # PasswordHasher.Verify uses FixedTimeEquals because it runs on a public
    # endpoint; this is an offline admin tool, so timing is not a concern.
    $match = [Convert]::ToBase64String($actual) -ceq $parts[2].Trim()

    Write-Host ""
    if ($match) {
        Write-Host "MATCH - this account's password IS the value you supplied." -ForegroundColor Green
        Write-Host ""
        Write-Host "So a failing sign-in is not the password. Re-check _diag_user_login.sql" -ForegroundColor Yellow
        Write-Host "section 2, and confirm the site you are signing in to points at THIS database" -ForegroundColor Yellow
        Write-Host "(ConnectionStrings:PracticeManagement in the deployed appsettings.json)." -ForegroundColor Yellow
    }
    else {
        Write-Host "NO MATCH - this account's password is NOT the value you supplied." -ForegroundColor Red
        Write-Host ""
        Write-Host "Most likely causes, in order:" -ForegroundColor Yellow
        Write-Host "  1. The account predates migration 208 and still holds the password that was" -ForegroundColor Yellow
        Write-Host "     typed into the old Users form. Check entered_dt on the row." -ForegroundColor Yellow
        Write-Host "  2. The RUNNING site's UserProvisioning:DefaultPassword is not what you typed." -ForegroundColor Yellow
        Write-Host "     Check the appsettings.json beside the deployed PracticeManagement.Web.dll," -ForegroundColor Yellow
        Write-Host "     any appsettings.Production.json, and UserProvisioning__DefaultPassword." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Re-run with -EmployeeId <id> to generate a reset UPDATE." -ForegroundColor Yellow
    }
    Write-Host ""
    exit ([int](-not $match))
}

# ---------------- generate ----------------
$saltBytes = [byte[]]::new(16)
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try   { $rng.GetBytes($saltBytes) }
finally { $rng.Dispose() }

$hashBytes = Get-Pbkdf2Bytes -Plaintext $Password -Salt $saltBytes -IterationCount $script:Iterations -Length 32
$encoded   = "{0}.{1}.{2}" -f $script:Iterations, [Convert]::ToBase64String($saltBytes), [Convert]::ToBase64String($hashBytes)

Write-Host ""
Write-Host "Hash for the supplied password:" -ForegroundColor Green
Write-Host $encoded
Write-Host ""

if ($PSBoundParameters.ContainsKey('EmployeeId') -and $EmployeeId -gt 0) {
    Write-Host "Reset statement - review the employee_id before running:" -ForegroundColor Green
    Write-Host ""
    Write-Host "UPDATE grac_practice.organization_employee"
    Write-Host "   SET password_hash         = N'$encoded',"
    Write-Host "       force_password_change = 1,"
    Write-Host "       updated_by            = N'admin-reset',"
    Write-Host "       updated_dt            = SYSUTCDATETIME()"
    Write-Host " WHERE employee_id = $EmployeeId;"
    Write-Host ""
    Write-Host "force_password_change = 1 sends the user to the change-password screen at" -ForegroundColor Yellow
    Write-Host "next sign-in, so this shared value cannot become their standing password." -ForegroundColor Yellow
    Write-Host ""
}
else {
    Write-Host "Pass -EmployeeId <id> to also print the reset UPDATE." -ForegroundColor Yellow
    Write-Host ""
}
