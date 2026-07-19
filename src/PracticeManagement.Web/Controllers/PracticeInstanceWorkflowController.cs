// =====================================================================
// PracticeInstanceWorkflowController (Web tier proxy)  (Q13/Q14/Q15)
//
// Route: /practice/api/instances/...
// Thin HTTP proxy to the Api tier — same pattern as Web TaskController.
// =====================================================================
using System.Net.Http;
using System.Text;
using Microsoft.AspNetCore.Mvc;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/instances")]
public sealed class PracticeInstanceWorkflowController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<PracticeInstanceWorkflowController> logger) : ControllerBase
{
    // Uses the same ApiBaseUrl config key SecurePracticeClient already reads
    // (default localhost:5045). Zero appsettings changes needed.
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

    [HttpGet("implementation-status-options")]
    public async Task<IActionResult> GetImplementationStatusOptions(CancellationToken cancellationToken)
    {
        var client = BuildClient();
        if (client.BaseAddress is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable, new { error = "PracticeManagementApi:BaseUrl is not configured." });
        try
        {
            var resp    = await client.GetAsync("api/practice/instances/implementation-status-options", cancellationToken);
            var payload = await resp.Content.ReadAsStringAsync(cancellationToken);
            return new ContentResult { Content = payload, ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json", StatusCode = (int)resp.StatusCode };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "GetImplementationStatusOptions proxy failed");
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    [HttpPost("{id:long}/update-implementation-status")]
    public async Task<IActionResult> UpdateImplementationStatus(long id, CancellationToken cancellationToken)
    {
        var client = BuildClient();
        if (client.BaseAddress is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable, new { error = "PracticeManagementApi:BaseUrl is not configured." });

        string bodyJson;
        using (var reader = new StreamReader(Request.Body, System.Text.Encoding.UTF8))
            bodyJson = await reader.ReadToEndAsync(cancellationToken);
        if (string.IsNullOrWhiteSpace(bodyJson)) bodyJson = "{}";

        using var req = new HttpRequestMessage(HttpMethod.Post, $"api/practice/instances/{id}/update-implementation-status")
        {
            Content = new StringContent(bodyJson, System.Text.Encoding.UTF8, "application/json")
        };
        try
        {
            var resp    = await client.SendAsync(req, cancellationToken);
            var payload = await resp.Content.ReadAsStringAsync(cancellationToken);
            return new ContentResult { Content = payload, ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json", StatusCode = (int)resp.StatusCode };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "UpdateImplementationStatus proxy failed for instance {Id}", id);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    [HttpGet("gaps")]
    public async Task<IActionResult> Gaps(
        [FromQuery] long? organizationId,
        [FromQuery] string? search,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        var client = BuildClient();
        try
        {
            var qs = "?page=" + page + "&pageSize=" + pageSize;
            if (organizationId.HasValue)               qs += "&organizationId=" + organizationId.Value;
            if (!string.IsNullOrWhiteSpace(search))    qs += "&search=" + Uri.EscapeDataString(search);
            var resp    = await client.GetAsync("api/practice/instances/gaps" + qs, cancellationToken);
            var payload = await resp.Content.ReadAsStringAsync(cancellationToken);
            return new ContentResult { Content = payload, ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json", StatusCode = (int)resp.StatusCode };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "PracticeInstanceWorkflowController.Gaps proxy failed");
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    [HttpGet("{id:long}/employees")]
    public async Task<IActionResult> GetEmployees(long id, CancellationToken cancellationToken)
    {
        var client = BuildClient();
        if (client.BaseAddress is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable, new { error = "PracticeManagementApi:BaseUrl is not configured." });
        try
        {
            var resp    = await client.GetAsync($"api/practice/instances/{id}/employees", cancellationToken);
            var payload = await resp.Content.ReadAsStringAsync(cancellationToken);
            return new ContentResult { Content = payload, ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json", StatusCode = (int)resp.StatusCode };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "GetEmployees proxy failed for instance {Id}", id);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    [HttpGet("{id:long}/context")]
    public async Task<IActionResult> GetContext(long id, CancellationToken cancellationToken)
    {
        var client = BuildClient();
        if (client.BaseAddress is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable,
                new { error = "PracticeManagementApi:BaseUrl is not configured." });
        try
        {
            var resp    = await client.GetAsync($"api/practice/instances/{id}/context", cancellationToken);
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
            logger.LogError(ex, "GetContext proxy failed for instance {Id}", id);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    [HttpPost("{id:long}/open-implementation-task")]
    public async Task<IActionResult> OpenImplementationTask(long id, CancellationToken cancellationToken)
    {
        var client = BuildClient();
        if (client.BaseAddress is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable,
                new { error = "PracticeManagementApi:BaseUrl is not configured." });

        string bodyJson;
        using (var reader = new StreamReader(Request.Body, Encoding.UTF8))
            bodyJson = await reader.ReadToEndAsync(cancellationToken);
        if (string.IsNullOrWhiteSpace(bodyJson)) bodyJson = "{}";

        using var req = new HttpRequestMessage(
            HttpMethod.Post, $"api/practice/instances/{id}/open-implementation-task")
        {
            Content = new StringContent(bodyJson, Encoding.UTF8, "application/json")
        };
        try
        {
            var resp = await client.SendAsync(req, cancellationToken);
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
            logger.LogError(ex, "OpenImplementationTask proxy failed for instance {Id}", id);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }
}
