// =====================================================================
// PracticePickerController (Web tier)
//
// Route: /practice/api/practice-picker/*  -> forwards to
//        /api/practice/practice-picker/*  on the API tier.
//
// Mirrors OrgAssuranceController exactly:
//   * session-guarded,
//   * same-origin browser calls only,
//   * cross-organization access blocked via HttpContext.IsOrganizationAllowed
//     for the organizationId every picker endpoint carries,
//   * the Web tier never opens its own SQL connection.
//
// GET-only: the picker reads, it never writes. A caller that needs to
// SAVE a chosen practice keeps using its own screen's endpoint (the Risk
// Centre still posts to /register/{riskId}/practices), which is what
// makes the component drop-in for existing pages.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/practice-picker")]
public sealed class PracticePickerController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<PracticePickerController> logger) : ControllerBase
{
    private const string ApiBaseKey = "ApiBaseUrl";

    private HttpClient BuildClient()
    {
        var client = httpClientFactory.CreateClient("PracticeManagementApi");
        if (client.BaseAddress is null)
        {
            var url = (configuration[ApiBaseKey] ?? "http://localhost:5045").Trim().TrimEnd('/') + "/";
            client.BaseAddress = new Uri(url);
        }
        return client;
    }

    [HttpGet("{**path}")]
    public async Task<IActionResult> ProxyGet(string path, CancellationToken cancellationToken)
    {
        var token = HttpContext.Session.GetString(PracticeSessionIdentity.TokenKey);
        if (string.IsNullOrWhiteSpace(token))
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        // Every picker endpoint is organisation-scoped; refuse a caller
        // asking about an organisation they are not assigned to.
        if (long.TryParse(Request.Query["organizationId"], out var orgId) && orgId > 0
            && !HttpContext.IsOrganizationAllowed(orgId))
        {
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Caller is not authorised for the requested organization." });
        }

        var client = BuildClient();
        var qs     = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        try
        {
            var resp    = await client.GetAsync("api/practice/practice-picker/" + path + qs, cancellationToken);
            var payload = await resp.Content.ReadAsStringAsync(cancellationToken);
            return new ContentResult
            {
                Content     = payload,
                ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json",
                StatusCode  = (int)resp.StatusCode
            };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "PracticePickerController.ProxyGet failed for {Path}", path);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }
}
