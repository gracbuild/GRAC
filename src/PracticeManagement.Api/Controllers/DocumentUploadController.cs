// =====================================================================
// DocumentUploadController  (charter §5)
//
// Route: /api/practice/document-uploads/...
// Independent of every other controller per charter §5 non-negotiable.
//
// Endpoints (Phase 1 -- upload + list; acknowledgement in Phase 2):
//
//   Lookups (GET):
//     GET  lookups/types            ?includeAll=
//     GET  lookups/stages           ?includeAll=
//     GET  lookups/statuses         ?includeAll=
//     GET  lookups/source-types     ?includeAll=
//     GET  lookups/distribution-types
//     GET  lookups/departments      ?organizationId=&includeAll=
//     GET  lookups/employees        ?organizationId=&departmentIds=1,2&includeAll=
//
//   Register (GET):
//     GET  /                        ?organizationId=&typeId=&stageId=&statusId=&search=&page=&pageSize=
//     GET  {id}
//     GET  {id}/distribution/departments
//     GET  {id}/distribution/employees
//     GET  {id}/file                (streams the current file)
//
//   Register (writes):
//     POST /                        [FromForm] multipart -- New
//     PUT  {id}                     [FromForm] multipart -- Edit (file optional)
//     POST {id}/toggle-status
//     POST {id}/workflow            { transition, decision, remark }
//
// Multipart is the only new pattern this module introduces; the rest of
// the API stays JSON. See DocumentUploadSaveForm for the field list.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/document-uploads")]
public sealed class DocumentUploadController(
    IDocumentUploadService documentUploads,
    ILogger<DocumentUploadController> logger) : ControllerBase
{
    // ============================== Lookups ==========================

    [HttpGet("lookups/types")]
    public async Task<IActionResult> Types([FromQuery] bool includeAll = false, CancellationToken ct = default)
        => Ok(await documentUploads.ListTypesAsync(includeAll, ct));

    [HttpGet("lookups/stages")]
    public async Task<IActionResult> Stages([FromQuery] bool includeAll = false, CancellationToken ct = default)
        => Ok(await documentUploads.ListStagesAsync(includeAll, ct));

    [HttpGet("lookups/statuses")]
    public async Task<IActionResult> Statuses([FromQuery] bool includeAll = false, CancellationToken ct = default)
        => Ok(await documentUploads.ListStatusesAsync(includeAll, ct));

    [HttpGet("lookups/source-types")]
    public async Task<IActionResult> SourceTypes([FromQuery] bool includeAll = false, CancellationToken ct = default)
        => Ok(await documentUploads.ListSourceTypesAsync(includeAll, ct));

    [HttpGet("lookups/distribution-types")]
    public async Task<IActionResult> DistributionTypes(CancellationToken ct = default)
        => Ok(await documentUploads.ListDistributionTypesAsync(ct));

    [HttpGet("lookups/departments")]
    public async Task<IActionResult> Departments(
        [FromQuery] long organizationId,
        [FromQuery] bool includeAll = false,
        CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await documentUploads.ListDepartmentsAsync(organizationId, includeAll, ct));
    }

    [HttpGet("lookups/employees")]
    public async Task<IActionResult> Employees(
        [FromQuery] long organizationId,
        [FromQuery] string? departmentIds,
        [FromQuery] bool includeAll = false,
        CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await documentUploads.ListEmployeesAsync(organizationId, departmentIds, includeAll, ct));
    }

    // ============================== Register (read) ==================

    [HttpGet]
    public async Task<IActionResult> List(
        [FromQuery] long organizationId,
        [FromQuery] int? typeId,
        [FromQuery] int? stageId,
        [FromQuery] int? statusId,
        [FromQuery] string? search,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var query = new DocumentRegisterQuery(organizationId, typeId, stageId, statusId, search, page, pageSize);
        return Ok(await documentUploads.ListRegisterAsync(query, ct));
    }

    [HttpGet("{documentId:long}")]
    public async Task<IActionResult> Details(long documentId, CancellationToken ct)
    {
        var detail = await documentUploads.GetDetailsAsync(documentId, ct);
        return detail is null ? NotFound() : Ok(detail);
    }

    [HttpGet("{documentId:long}/distribution/departments")]
    public async Task<IActionResult> DistributionDepartments(long documentId, CancellationToken ct)
        => Ok(await documentUploads.GetDistributionDepartmentsAsync(documentId, ct));

    [HttpGet("{documentId:long}/distribution/employees")]
    public async Task<IActionResult> DistributionEmployees(long documentId, CancellationToken ct)
        => Ok(await documentUploads.GetDistributionEmployeesAsync(documentId, ct));

    // Streams the current file. Content-Type falls back to
    // application/octet-stream if the stored value is null (older rows).
    //
    // ?inline=true sends Content-Disposition: inline so browsers render
    // the file (e.g. PDF) in an <iframe> instead of downloading. Without
    // the param, File(...) uses attachment (download) semantics.
    [HttpGet("{documentId:long}/file")]
    public async Task<IActionResult> Download(long documentId, [FromQuery] bool inline, CancellationToken ct)
    {
        var file = await documentUploads.GetFileAsync(documentId, ct);
        if (file is null) return NotFound();
        var contentType = string.IsNullOrWhiteSpace(file.ContentType) ? "application/octet-stream" : file.ContentType;
        if (inline)
        {
            // Manually set Content-Disposition so the browser renders inline.
            var cd = new System.Net.Http.Headers.ContentDispositionHeaderValue("inline")
            {
                FileName = file.FileName
            };
            Response.Headers["Content-Disposition"] = cd.ToString();
            return File(file.FileData, contentType);
        }
        return File(file.FileData, contentType, file.FileName);
    }

    // ============================== Register (write) =================

    // Multipart. `File` field carries the binary; the rest are form fields.
    // Broad try/catch here (not just in the service) because THROW error
    // messages from the proc arrive as SqlException, but binding / IO /
    // reader-cast failures arrive as other exception types and would
    // otherwise surface as an opaque HTTP 500 with no body.
    [HttpPost]
    [Consumes("multipart/form-data")]
    [RequestSizeLimit(52_428_800)]   // 50 MB per upload; adjust in appsettings if needed later
    public async Task<IActionResult> Create([FromForm] DocumentUploadSaveForm form, CancellationToken ct)
    {
        try
        {
            if (form is null) return BadRequest(new { success = false, error = "form is required." });
            form.DocumentId = null;    // enforce New semantics
            var result = await documentUploads.SaveAsync("New", form, ct);
            if (!result.Success) return BadRequest(result);
            // Avoid CreatedAtAction blowing up when DocumentId is null.
            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "DocumentUpload.Create failed");
            return BadRequest(new { success = false, error = ex.Message, inner = ex.InnerException?.Message });
        }
    }

    [HttpPut("{documentId:long}")]
    [Consumes("multipart/form-data")]
    [RequestSizeLimit(52_428_800)]
    public async Task<IActionResult> Update(long documentId, [FromForm] DocumentUploadSaveForm form, CancellationToken ct)
    {
        try
        {
            if (form is null) return BadRequest(new { success = false, error = "form is required." });
            form.DocumentId = documentId;
            var result = await documentUploads.SaveAsync("Edit", form, ct);
            return result.Success ? Ok(result) : BadRequest(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "DocumentUpload.Update failed for {DocumentId}", documentId);
            return BadRequest(new { success = false, error = ex.Message, inner = ex.InnerException?.Message });
        }
    }

    [HttpPost("{documentId:long}/toggle-status")]
    public async Task<IActionResult> ToggleStatus(
        long documentId,
        [FromQuery] long organizationId,
        [FromBody] DocumentStatusToggleRequest? request,
        CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var result = await documentUploads.ToggleStatusAsync(
            documentId, organizationId, request ?? new DocumentStatusToggleRequest(null, null), ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    [HttpPost("{documentId:long}/workflow")]
    public async Task<IActionResult> Workflow(long documentId, [FromBody] DocumentWorkflowRequest request, CancellationToken ct)
    {
        if (request is null) return BadRequest(new { error = "request body is required." });
        var result = await documentUploads.TransitionAsync(documentId, request, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }
}
