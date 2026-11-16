// =====================================================================
// EvidenceIntakeController (Web tier)  (migration 530)
//
// The ONE public, session-less endpoint of Evidence Automation:
//
//     POST {host}{PathBase}/intake/evidence
//          Authorization: Bearer <token>      (or X-GRAC-Intake-Token)
//          application/json  or  multipart/form-data
//
// A customer's system (a script, Power Automate / Zapier / n8n, a backup
// tool's post-job hook) posts evidence here. The Web tier stays what it is
// everywhere else -- a proxy with no database connection: it forwards the
// body and the token unchanged to Api /api/practice/evidence-automation/
// intake, which hashes the token, finds the ONE source it belongs to and
// stores the evidence as a proposal. No session, no caller headers, no
// cookies: the token is the only credential, and it can do nothing but
// deliver evidence to its own source.
//
// Rate limited per client address ("evidence-intake", Program.cs).
// =====================================================================
using System.Net.Http.Headers;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("intake/evidence")]
[EnableRateLimiting("evidence-intake")]
public sealed class EvidenceIntakeController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<EvidenceIntakeController> logger) : ControllerBase
{
    private const string ApiBaseKey        = "ApiBaseUrl";
    private const string IntakeTokenHeader = "X-GRAC-Intake-Token";
    private const long   IntakeBodyLimit   = 75_000_000;   // matches the Api limit

    [HttpPost]
    [RequestSizeLimit(IntakeBodyLimit)]
    public async Task<IActionResult> Post(CancellationToken ct)
    {
        var auth  = Request.Headers.Authorization.ToString();
        var token = Request.Headers[IntakeTokenHeader].ToString();
        if (string.IsNullOrWhiteSpace(auth) && string.IsNullOrWhiteSpace(token))
            return StatusCode(StatusCodes.Status401Unauthorized, new { success = false, error = "A valid intake token is required." });

        try
        {
            // A plain client: the session-stamping handler has nothing to
            // stamp here and must not run.
            var client = httpClientFactory.CreateClient();
            var url = (configuration[ApiBaseKey] ?? "http://localhost:5045").Trim().TrimEnd('/')
                      + "/api/practice/evidence-automation/intake";
            using var req = new HttpRequestMessage(HttpMethod.Post, url)
            {
                Content = new StreamContent(Request.Body)
            };
            if (!string.IsNullOrWhiteSpace(Request.ContentType))
                req.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(Request.ContentType);
            if (!string.IsNullOrWhiteSpace(auth))
                req.Headers.TryAddWithoutValidation("Authorization", auth);
            if (!string.IsNullOrWhiteSpace(token))
                req.Headers.TryAddWithoutValidation(IntakeTokenHeader, token);

            var resp = await client.SendAsync(req, ct);
            return new ContentResult
            {
                Content     = await resp.Content.ReadAsStringAsync(ct),
                ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json",
                StatusCode  = (int)resp.StatusCode
            };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Evidence intake proxy failed.");
            return StatusCode(StatusCodes.Status502BadGateway, new { success = false, error = "Evidence intake is not available right now. Try again later." });
        }
    }
}
