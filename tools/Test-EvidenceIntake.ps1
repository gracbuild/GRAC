<#
.SYNOPSIS
  End-to-end test of the Evidence Automation webhook (migration 530) against a
  running GRAC Web site. UAT / demo only.

.DESCRIPTION
  1. On Policies & Documents -> Evidence Automation, create a Webhook source
     and click "Issue token". Copy the token.
  2. Run:  .\Test-EvidenceIntake.ps1 -BaseUrl https://uat-host/practice -Token grac_ei_...
  It sends six requests to <BaseUrl>/intake/evidence and prints PASS / FAIL:
     JSON with a file           -> 201
     same eventId again         -> 200, duplicate
     no file (event = evidence) -> 201
     multipart/form-data        -> 201
     invalid result             -> 400
     wrong token                -> 401
  Afterwards the Received tab shows four items waiting for review (reject them,
  or run them through Accept to test the attach step).
  Works on Windows PowerShell 5.1 and PowerShell 7.
#>
param(
    [Parameter(Mandatory)] [string] $BaseUrl,   # site root incl. PathBase, e.g. https://uat-host/practice
    [Parameter(Mandatory)] [string] $Token,
    [switch] $SkipCertificateCheck
)

Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
if ($SkipCertificateCheck) { $handler.ServerCertificateCustomValidationCallback = { $true } }
$client = New-Object System.Net.Http.HttpClient($handler)
$url = $BaseUrl.TrimEnd('/') + '/intake/evidence'
$run = (Get-Date).ToString('yyyyMMddHHmmss')
$today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
$results = @()

function Send([string] $name, [System.Net.Http.HttpContent] $content, [string] $token, [int] $expect, [scriptblock] $extra) {
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $url)
    $req.Headers.TryAddWithoutValidation('Authorization', "Bearer $token") | Out-Null
    $req.Content = $content
    try {
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $code = [int]$resp.StatusCode
        $ok = ($code -eq $expect)
        if ($ok -and $extra) { $ok = & $extra $body }
        $script:results += [pscustomobject]@{ Test = $name; Expected = $expect; Got = $code; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Body = $body }
    } catch {
        $script:results += [pscustomobject]@{ Test = $name; Expected = $expect; Got = 'error'; Result = 'FAIL'; Body = $_.Exception.Message }
    }
}
function Json([hashtable] $o) {
    $c = New-Object System.Net.Http.StringContent(($o | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8, 'application/json')
    return $c
}

$fileB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("530 intake test $run"))
$evt = @{ eventId = "test-$run"; periodTo = $today; result = 'Pass'; metric = '0 failed jobs'; summary = 'Intake test'
          sourceSystem = 'Test-EvidenceIntake'; file = @{ name = "intake-test-$run.txt"; contentType = 'text/plain'; contentBase64 = $fileB64 } }

Send 'JSON with a file'           (Json $evt) $Token 201 $null
Send 'same eventId again'         (Json $evt) $Token 200 { param($b) $b -match '"duplicate"\s*:\s*true' }
Send 'no file (event is evidence)' (Json @{ eventId = "test-$run-nofile"; result = 'Fail'; metric = '3 failed jobs' }) $Token 201 $null

$mp = New-Object System.Net.Http.MultipartFormDataContent
$mp.Add((New-Object System.Net.Http.StringContent("test-$run-multipart")), 'eventId')
$mp.Add((New-Object System.Net.Http.StringContent('Pass')), 'result')
$mp.Add((New-Object System.Net.Http.StringContent($today)), 'periodTo')
$bytes = New-Object System.Net.Http.ByteArrayContent(,[System.Text.Encoding]::UTF8.GetBytes("multipart test $run"))
$bytes.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('text/plain')
$mp.Add($bytes, 'file', "intake-multipart-$run.txt")
Send 'multipart/form-data'        $mp $Token 201 $null

Send 'invalid result'             (Json @{ eventId = "test-$run-bad"; result = 'maybe' }) $Token 400 $null
Send 'wrong token'                (Json @{ result = 'Pass' }) 'grac_ei_not-a-real-token' 401 $null

$results | Format-Table Test, Expected, Got, Result -AutoSize
$results | Where-Object Result -eq 'FAIL' | ForEach-Object { Write-Host "$($_.Test): $($_.Body)" -ForegroundColor Yellow }
$p = ($results | Where-Object Result -eq 'PASS').Count
Write-Host "$p of $($results.Count) passed." -ForegroundColor $(if ($p -eq $results.Count) { 'Green' } else { 'Red' })
