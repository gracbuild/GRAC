// =====================================================================
// EvidenceAutomationController  (migration 530 -- plan Part A, Phase 1)
//
// Route: /api/practice/evidence-automation/...
//   Configuration and review (caller stamped by the Web tier from the
//   SESSION -- X-PM-Caller-*; the procedures decide what the caller may
//   see and change: admin / source owner / obligation owner):
//     GET  lookups                         evidence types, employees, file drop on/off
//     GET  obligations                     obligations the caller may bind
//     GET  obligations/{id}/evidence       evidence rows of one obligation
//     GET  bindings                        sources grid (health, last received)
//     GET  bindings/{id}                   one source + its latest events
//     POST bindings                        create a source
//     POST bindings/{id}/save              edit a source
//     POST bindings/{id}/status            Pause / Resume / Retire
//     POST bindings/{id}/token             issue (or rotate) the webhook token -- shown ONCE
//     GET  events                          received evidence (Proposed / Accepted / Rejected)
//     GET  events/{id}/targets             where an item may be attached
//     POST events/{id}/accept              attach (existing link procedures) or keep only
//     POST events/{id}/reject              reject with a reason
//     GET  notices/me, POST notices/me/mark   the caller's "not received" notices
//
//   Intake (NO session -- the token is the credential):
//     POST intake    Authorization: Bearer <token>  (or X-GRAC-Intake-Token)
//                    application/json  EvidenceIntakeEvent, file in base64
//                    multipart/form-data  part "file" + the same fields
//                    201 stored / 200 already received / 400 / 401 / 409 / 413
// =====================================================================
using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/evidence-automation")]
public sealed class EvidenceAutomationController(
    IEvidenceAutomationService service,
    ILogger<EvidenceAutomationController> logger) : ControllerBase
{
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";
    private const string CallerAdminHeader    = "X-PM-Caller-Is-Admin";
    private const string IntakeTokenHeader    = "X-GRAC-Intake-Token";
    private const long   IntakeBodyLimit      = 75_000_000;   // a 50 MB file is ~67 MB as base64 JSON

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private long? CallerEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private bool CallerIsAdmin =>
        Request.Headers[CallerAdminHeader].ToString() is "1" or "true" or "True";

    private string Actor =>
        CallerEmployeeId is { } id ? $"employee:{id}" : "system";

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------
    [HttpGet("lookups")]
    public async Task<IActionResult> Lookups([FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        try { return Ok(await service.LookupsAsync(organizationId, ct)); }
        catch (Exception ex)
        {
            logger.LogError(ex, "EvidenceAutomationController.Lookups failed");
            return StatusCode(StatusCodes.Status500InternalServerError, new { error = "The lists could not be loaded." });
        }
    }

    [HttpGet("obligations")]
    public async Task<IActionResult> Obligations([FromQuery] long organizationId, [FromQuery] string? search, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return List(await service.ObligationSearchAsync(organizationId, search, CallerEmployeeId, CallerIsAdmin, ct));
    }

    [HttpGet("obligations/{id:long}/evidence")]
    public async Task<IActionResult> ObligationEvidence(long id, [FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return List(await service.ObligationEvidenceAsync(organizationId, id, ct));
    }

    [HttpGet("bindings")]
    public async Task<IActionResult> Bindings(
        [FromQuery] long organizationId, [FromQuery] string? search, [FromQuery] string? channel,
        [FromQuery] string? status, [FromQuery] string? health,
        [FromQuery] int pageNumber = 1, [FromQuery] int pageSize = 25, CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return List(await service.ListBindingsAsync(organizationId, search, channel, status, health, pageNumber, pageSize,
                                                    CallerEmployeeId, CallerIsAdmin, ct), pageNumber, pageSize);
    }

    [HttpGet("bindings/{id:long}")]
    public async Task<IActionResult> Binding(long id, [FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var detail = await service.GetBindingAsync(organizationId, id, CallerEmployeeId, CallerIsAdmin, ct);
            return detail is null
                ? NotFound(new { error = "That automated evidence source was not found, or you do not manage it." })
                : Ok(new { binding = detail.Binding, recentEvents = detail.RecentEvents });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "EvidenceAutomationController.Binding {BindingId} failed", id);
            return StatusCode(StatusCodes.Status500InternalServerError, new { error = "The source could not be loaded." });
        }
    }

    [HttpPost("bindings")]
    public async Task<IActionResult> CreateBinding([FromBody] EvidenceAutomationBindingSaveRequest body, CancellationToken ct)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        return Command(await service.SaveBindingAsync(null, body, CallerEmployeeId, CallerIsAdmin, Actor, ct));
    }

    [HttpPost("bindings/{id:long}/save")]
    public async Task<IActionResult> SaveBinding(long id, [FromBody] EvidenceAutomationBindingSaveRequest body, CancellationToken ct)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        return Command(await service.SaveBindingAsync(id, body, CallerEmployeeId, CallerIsAdmin, Actor, ct));
    }

    [HttpPost("bindings/{id:long}/status")]
    public async Task<IActionResult> BindingStatus(long id, [FromBody] EvidenceAutomationStatusRequest body, CancellationToken ct)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        return Command(await service.SetBindingStatusAsync(id, body, CallerEmployeeId, CallerIsAdmin, Actor, ct));
    }

    /// <summary>The token is in this response and nowhere else -- it is
    /// stored only as its hash.</summary>
    [HttpPost("bindings/{id:long}/token")]
    public async Task<IActionResult> IssueToken(long id, [FromBody] EvidenceAutomationTokenRequest body, CancellationToken ct)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var result = await service.IssueTokenAsync(id, body.OrganizationId, CallerEmployeeId, CallerIsAdmin, Actor, ct);
        return result.Success
            ? Ok(new { success = true, token = result.Token, message = result.Message })
            : BadRequest(new { error = result.Error });
    }

    // ------------------------------------------------------------------
    // Received evidence -- review
    // ------------------------------------------------------------------
    [HttpGet("events")]
    public async Task<IActionResult> Events(
        [FromQuery] long organizationId, [FromQuery] long? bindingId, [FromQuery] string? status,
        [FromQuery] string? result, [FromQuery] string? search,
        [FromQuery] int pageNumber = 1, [FromQuery] int pageSize = 25, CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return List(await service.ListEventsAsync(organizationId, bindingId, status, result, search, pageNumber, pageSize,
                                                  CallerEmployeeId, CallerIsAdmin, ct), pageNumber, pageSize);
    }

    [HttpGet("events/{id:long}/targets")]
    public async Task<IActionResult> EventTargets(long id, [FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return List(await service.EventTargetsAsync(organizationId, id, CallerEmployeeId, CallerIsAdmin, ct));
    }

    [HttpPost("events/{id:long}/accept")]
    public async Task<IActionResult> Accept(long id, [FromBody] EvidenceAutomationAcceptRequest body, CancellationToken ct)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        return Command(await service.AcceptEventAsync(id, body, CallerEmployeeId, CallerIsAdmin, Actor, ct));
    }

    [HttpPost("events/{id:long}/reject")]
    public async Task<IActionResult> Reject(long id, [FromBody] EvidenceAutomationRejectRequest body, CancellationToken ct)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        return Command(await service.RejectEventAsync(id, body, CallerEmployeeId, CallerIsAdmin, Actor, ct));
    }

    // ------------------------------------------------------------------
    // "Not received" notices addressed to the caller (My Notifications).
    // The recipient is the stamped caller, never a query value.
    // ------------------------------------------------------------------
    [HttpGet("notices/me")]
    public async Task<IActionResult> MyNotices(
        [FromQuery] long? organizationId, [FromQuery] string? status = "Unread",
        [FromQuery] int pageNumber = 1, [FromQuery] int pageSize = 25, CancellationToken ct = default)
    {
        if (CallerEmployeeId is not { } recipient)
            return Ok(new { data = Array.Empty<object>(), totalRows = 0, unreadCount = 0 });
        var result = await service.ListMyNoticesAsync(recipient, organizationId, status, pageNumber, pageSize, ct);
        return result.Success
            ? Ok(new { data = result.Rows, totalRows = result.TotalRows, unreadCount = result.UnreadCount })
            : BadRequest(new { error = result.Error });
    }

    [HttpPost("notices/me/mark")]
    public async Task<IActionResult> MarkMyNotices([FromBody] EvidenceAutomationNoticeMarkRequest? body, CancellationToken ct)
    {
        if (CallerEmployeeId is not { } recipient) return Ok(new { markedCount = 0 });
        try
        {
            return Ok(new { markedCount = await service.MarkMyNoticesAsync(recipient, body?.OrganizationId, body?.NoticeId, ct) });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "EvidenceAutomationController.MarkMyNotices failed");
            return StatusCode(StatusCodes.Status500InternalServerError, new { error = "The notices could not be marked." });
        }
    }

    // ------------------------------------------------------------------
    // Intake -- called by the customer's systems through the Web tier's
    // /intake/evidence route. The token identifies the binding.
    // ------------------------------------------------------------------
    [HttpPost("intake")]
    [RequestSizeLimit(IntakeBodyLimit)]
    [RequestFormLimits(MultipartBodyLengthLimit = IntakeBodyLimit)]
    public async Task<IActionResult> Intake(CancellationToken ct)
    {
        var token = ReadToken();
        EvidenceIntakeEvent evt;
        byte[]? fileData = null;
        string? fileName = null, contentType = null;

        try
        {
            if (Request.HasFormContentType)
            {
                var form = await Request.ReadFormAsync(ct);
                evt = new EvidenceIntakeEvent
                {
                    EventId      = Field(form, "eventId"),
                    OccurredAt   = Date(form, "occurredAt"),
                    PeriodFrom   = Date(form, "periodFrom"),
                    PeriodTo     = Date(form, "periodTo"),
                    Result       = Field(form, "result"),
                    Metric       = Field(form, "metric"),
                    Summary      = Field(form, "summary"),
                    SourceSystem = Field(form, "sourceSystem")
                };
                var file = form.Files.GetFile("file") ?? form.Files.FirstOrDefault();
                if (file is { Length: > 0 })
                {
                    using var ms = new MemoryStream();
                    await file.CopyToAsync(ms, ct);
                    fileData    = ms.ToArray();
                    fileName    = file.FileName;
                    contentType = file.ContentType;
                }
            }
            else
            {
                evt = await JsonSerializer.DeserializeAsync<EvidenceIntakeEvent>(Request.Body, Json, ct)
                      ?? new EvidenceIntakeEvent();
            }
        }
        catch (Exception ex) when (ex is JsonException or InvalidDataException or FormatException)
        {
            // The token is still checked first, so an unauthenticated caller
            // learns nothing about the payload rules.
            if (string.IsNullOrWhiteSpace(token)) return StatusCode(401, new { error = "A valid intake token is required." });
            return BadRequest(new { error = $"The request body could not be read: {ex.Message}" });
        }

        var result = await service.IngestWebhookAsync(token, evt, fileData, fileName, contentType, ct);
        return result.Success
            ? StatusCode(result.StatusCode, new
              {
                  success = true,
                  eventId = result.EventId,
                  evidenceItemId = result.EvidenceItemId,
                  duplicate = result.Duplicate,
                  message = result.Message
              })
            : StatusCode(result.StatusCode, new { success = false, error = result.Error });
    }

    private string? ReadToken()
    {
        var auth = Request.Headers.Authorization.ToString();
        if (auth.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return auth["Bearer ".Length..].Trim();
        var header = Request.Headers[IntakeTokenHeader].ToString();
        return string.IsNullOrWhiteSpace(header) ? null : header.Trim();
    }

    private static string? Field(IFormCollection form, string name)
    {
        var v = form[name].ToString();
        return string.IsNullOrWhiteSpace(v) ? null : v;
    }

    private static DateTime? Date(IFormCollection form, string name)
    {
        var v = Field(form, name);
        if (v is null) return null;
        return DateTime.TryParse(v, System.Globalization.CultureInfo.InvariantCulture,
                                 System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal,
                                 out var d)
            ? d
            : throw new FormatException($"{name} is not a valid date.");
    }

    // ------------------------------------------------------------------
    private IActionResult List(EvidenceAutomationListResult result, int? page = null, int? pageSize = null) =>
        result.Success
            ? Ok(new { data = result.Rows, totalRows = result.TotalRows, page, pageSize, isAdmin = CallerIsAdmin })
            : BadRequest(new { error = result.Error });

    private IActionResult Command(EvidenceAutomationCommandResult result) =>
        result.Success
            ? Ok(new Dictionary<string, object?>(result.Row ?? new Dictionary<string, object?>(), StringComparer.OrdinalIgnoreCase)
              {
                  ["success"] = true
              })
            : BadRequest(new { error = result.Error });
}
