// =====================================================================
// EvidenceCenterController  (migration 476, Phase 1)
//
// Route: /api/practice/evidence-center/...
//   GET  /                      grid (filters + paging)
//   GET  /lookups               evidence types + employees
//   GET  /{id}                  item, versions, Used in
//   GET  /files/{fileId}        download one version
//   POST /upload                multipart: Upload new / New version
//   POST /{id}/save             metadata
//   POST /{id}/status           Retire / Restore / Delete
//   GET  /notices/me            the caller's expiry notices        (477)
//   POST /notices/me/mark       mark one / all read                (477)
//
// The caller (employee id, admin flag) comes from the headers the Web tier
// stamps from the SESSION (X-PM-Caller-*), never from the browser. The
// procedures decide what the caller may see and change.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/evidence-center")]
public sealed class EvidenceCenterController(
    IEvidenceCenterService evidenceService,
    ILogger<EvidenceCenterController> logger) : ControllerBase
{
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";
    private const string CallerAdminHeader    = "X-PM-Caller-Is-Admin";

    private long? CallerEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private bool CallerIsAdmin =>
        Request.Headers[CallerAdminHeader].ToString() is "1" or "true" or "True";

    private string Actor =>
        CallerEmployeeId is { } id ? $"employee:{id}" : "system";

    [HttpGet]
    public async Task<IActionResult> List(
        [FromQuery] long    organizationId,
        [FromQuery] string? search,
        [FromQuery] int?    evidenceTypeId,
        [FromQuery] long?   ownerEmployeeId,
        [FromQuery] string? validity,
        [FromQuery] string? usage,
        [FromQuery] string? status     = "Active",
        [FromQuery] int     pageNumber = 1,
        [FromQuery] int     pageSize   = 25,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });

        var result = await evidenceService.ListAsync(new EvidenceCenterListQuery(
            organizationId, search, evidenceTypeId, ownerEmployeeId, validity, usage, status,
            pageNumber, pageSize, CallerEmployeeId, CallerIsAdmin), cancellationToken);

        return result.Success
            ? Ok(new { data = result.Rows, totalRows = result.TotalRows, page = pageNumber, pageSize, isAdmin = CallerIsAdmin })
            : BadRequest(new { error = result.Error });
    }

    [HttpGet("lookups")]
    public async Task<IActionResult> Lookups([FromQuery] long organizationId, CancellationToken cancellationToken)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var lookups = await evidenceService.LookupsAsync(organizationId, cancellationToken);
            return Ok(new { evidenceTypes = lookups.EvidenceTypes, employees = lookups.Employees });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "EvidenceCenterController.Lookups failed");
            return StatusCode(StatusCodes.Status500InternalServerError, new { error = "The lists could not be loaded." });
        }
    }

    [HttpGet("{id:long}")]
    public async Task<IActionResult> Get(long id, [FromQuery] long organizationId, CancellationToken cancellationToken)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var detail = await evidenceService.GetAsync(organizationId, id, CallerEmployeeId, CallerIsAdmin, cancellationToken);
            return detail is null
                ? NotFound(new { error = "That evidence item was not found, or you do not have access to it." })
                : Ok(new { item = detail.Item, versions = detail.Versions, usedIn = detail.UsedIn });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "EvidenceCenterController.Get {ItemId} failed", id);
            return StatusCode(StatusCodes.Status500InternalServerError, new { error = "The evidence item could not be loaded." });
        }
    }

    [HttpGet("files/{fileId:long}")]
    public async Task<IActionResult> Download(long fileId, [FromQuery] long organizationId, CancellationToken cancellationToken)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var file = await evidenceService.GetFileAsync(organizationId, fileId, CallerEmployeeId, CallerIsAdmin, cancellationToken);
            return file is null
                ? NotFound(new { error = "That file was not found, or you do not have access to it." })
                : File(file.FileData, file.ContentType ?? "application/octet-stream", file.FileName);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Evidence Center file {FileId} download failed.", fileId);
            return StatusCode(StatusCodes.Status500InternalServerError, new { error = "The file could not be downloaded." });
        }
    }

    /// <summary>Multipart, the Operationalize / Task Centre upload shape.
    /// evidenceItemId given = a new version of that item.</summary>
    [HttpPost("upload")]
    [RequestSizeLimit(52_428_800)] // 50 MB -- matches Task Centre and Document Upload
    public async Task<IActionResult> Upload(
        [FromQuery] long      organizationId,
        [FromForm]  IFormFile? file,
        [FromForm]  long?     evidenceItemId,
        [FromForm]  string?   versionNote,
        [FromForm]  string?   evidenceTitle,
        [FromForm]  int?      evidenceTypeId,
        [FromForm]  string?   evidenceDescription,
        [FromForm]  long?     ownerEmployeeId,
        [FromForm]  DateTime? validFrom,
        [FromForm]  DateTime? validTo,
        [FromForm]  string?   classification,
        [FromForm]  string?   tags,
        [FromForm]  bool      allowDuplicate,
        CancellationToken cancellationToken)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (file is null || file.Length == 0) return BadRequest(new { error = "A non-empty file is required." });

        using var ms = new MemoryStream();
        await file.CopyToAsync(ms, cancellationToken);

        var result = await evidenceService.UploadAsync(new EvidenceCenterUploadRequest(
            organizationId, evidenceItemId, file.FileName, file.ContentType, ms.ToArray(), versionNote,
            evidenceTitle, evidenceTypeId, evidenceDescription, ownerEmployeeId, validFrom, validTo,
            classification, tags, allowDuplicate, CallerEmployeeId, CallerIsAdmin, Actor), cancellationToken);

        if (!result.Success) return BadRequest(new { error = result.Error });
        // 409: nothing stored -- the identical file is already there. The
        // screen offers "Open existing" or "Upload anyway".
        return result.Duplicate
            ? Conflict(new
              {
                  duplicate = true,
                  duplicateItemId = result.DuplicateItemId,
                  duplicateTitle = result.DuplicateTitle,
                  duplicateVersionNo = result.DuplicateVersionNo,
                  error = $"This file already exists in the Evidence Center as \"{result.DuplicateTitle}\" (version {result.DuplicateVersionNo})."
              })
            : StatusCode(StatusCodes.Status201Created, new
              {
                  success = true,
                  evidenceItemId = result.EvidenceItemId,
                  evidenceFileId = result.EvidenceFileId,
                  versionNo = result.VersionNo,
                  message = result.VersionNo is > 1 ? $"Version {result.VersionNo} uploaded." : "Evidence uploaded."
              });
    }

    [HttpPost("{id:long}/save")]
    public async Task<IActionResult> Save(long id, [FromBody] EvidenceCenterSaveRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        var result = await evidenceService.SaveAsync(id, body, CallerEmployeeId, CallerIsAdmin, Actor, cancellationToken);
        return result.Success
            ? Ok(new { success = true, message = result.Message })
            : BadRequest(new { error = result.Error });
    }

    // ---- 477: expiry notices addressed to the caller ------------------
    // The recipient is the caller the Web tier stamped from the session,
    // never a query value, so nobody reads another person's notices.
    [HttpGet("notices/me")]
    public async Task<IActionResult> MyNotices(
        [FromQuery] long?   organizationId,
        [FromQuery] string? status     = "Unread",
        [FromQuery] int     pageNumber = 1,
        [FromQuery] int     pageSize   = 25,
        CancellationToken cancellationToken = default)
    {
        if (CallerEmployeeId is not { } recipient)
            return Ok(new { data = Array.Empty<object>(), totalRows = 0, unreadCount = 0 });
        var result = await evidenceService.ListMyNoticesAsync(recipient, organizationId, status, pageNumber, pageSize, cancellationToken);
        return result.Success
            ? Ok(new { data = result.Rows, totalRows = result.TotalRows, unreadCount = result.UnreadCount })
            : BadRequest(new { error = result.Error });
    }

    [HttpPost("notices/me/mark")]
    public async Task<IActionResult> MarkMyNotices([FromBody] EvidenceNoticeMarkRequest? body, CancellationToken cancellationToken)
    {
        if (CallerEmployeeId is not { } recipient) return Ok(new { markedCount = 0 });
        try
        {
            var marked = await evidenceService.MarkMyNoticesAsync(recipient, body?.OrganizationId, body?.EvidenceNoticeId, cancellationToken);
            return Ok(new { markedCount = marked });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "EvidenceCenterController.MarkMyNotices failed");
            return StatusCode(StatusCodes.Status500InternalServerError, new { error = "The notices could not be marked." });
        }
    }

    [HttpPost("{id:long}/status")]
    public async Task<IActionResult> SetStatus(long id, [FromBody] EvidenceCenterStatusRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        var result = await evidenceService.SetStatusAsync(id, body, CallerEmployeeId, CallerIsAdmin, Actor, cancellationToken);
        return result.Success
            ? Ok(new { success = true, message = result.Message })
            : BadRequest(new { error = result.Error });
    }
}
