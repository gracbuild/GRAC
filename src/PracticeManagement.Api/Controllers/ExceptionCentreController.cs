// =====================================================================
// ExceptionCentreController  (charter §5)
// Route: /api/practice/exception-centre/...
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/exception-centre")]
public sealed class ExceptionCentreController(
    IExceptionCentreService svc,
    ILogger<ExceptionCentreController> logger) : ControllerBase
{
    // Lookup for the UI evidence-type combo (from evidence_type_master).
    [HttpGet("lookups/evidence-types")]
    public async Task<IActionResult> EvidenceTypes(CancellationToken ct)
        => Ok(await svc.ListEvidenceTypesAsync(ct));

    // Lookup for the Exception Type dropdown (Temporary / Business / etc.)
    [HttpGet("lookups/exception-types")]
    public async Task<IActionResult> ExceptionTypes(CancellationToken ct)
        => Ok(await svc.ListExceptionTypesAsync(ct));

    // Review Frequency options for the Approve dialog's "Review frequency
    // (if applicable)" select. Reuses sp_risk_review_frequency_list (293)
    // unchanged -- frequency_master is a shared master table, not a
    // Risk-owned one (see ExceptionReviewFrequencyRow). No organizationId:
    // same reasoning as Risk Centre's own /review-frequencies.
    [HttpGet("lookups/review-frequencies")]
    public async Task<IActionResult> ReviewFrequencies(CancellationToken ct)
        => Ok(await svc.ListReviewFrequenciesAsync(ct));

    // Lookup for the Linked Practice combo. Scoped to the org derived
    // upstream in the Web tier -- server-side scope check applies before
    // this endpoint is reachable (same session guard as everything else).
    [HttpGet("lookups/practices")]
    public async Task<IActionResult> Practices([FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.ListPracticesAsync(organizationId, ct));
    }

    // Ops-scheduled job entry point: auto-expire Approved rows whose
    // effective_until is in the past. Idempotent; safe to run repeatedly.
    [HttpPost("expire-due")]
    public async Task<IActionResult> ExpireDue(CancellationToken ct)
    {
        try
        {
            var n = await svc.ExpireDueAsync("expiry-runner", ct);
            return Ok(new { success = true, expiredCount = n });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "ExceptionCentre.ExpireDue failed");
            return BadRequest(new { success = false, error = ex.Message });
        }
    }

    [HttpGet]
    public async Task<IActionResult> List(
        [FromQuery] long organizationId,
        [FromQuery] string? statusCode,
        // Migration 184: tab filter -- "GAP_CANDIDATE" or "SLA_CANDIDATE".
        // Omitted / NULL returns both (backwards compatible).
        [FromQuery] string? requestType,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.ListAsync(organizationId, statusCode, requestType, page, pageSize, ct));
    }

    // Migration 327 -- "+ Add Custom Exception." Same route shape as
    // List (POST vs GET on the collection route), same result shape as
    // every other action below: {error} on failure, the new id on
    // success. From here the row is an ordinary exception_request --
    // Analysis, Submit for approval, Approve/Reject, History, the
    // Exception Full View -- nothing downstream of this endpoint knows
    // or cares that the row started here instead of a gap analysis.
    [HttpPost]
    public async Task<IActionResult> CreateCustom(
        [FromBody] ExceptionCreateCustomRequest? body, CancellationToken ct)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(body.RequestTitle))
            return BadRequest(new { error = "requestTitle is required." });

        var r = await svc.CreateCustomAsync(body, ct);
        return r.Success
            ? StatusCode(StatusCodes.Status201Created, new { exceptionRequestId = r.ExceptionRequestId })
            : BadRequest(new { error = r.Error });
    }

    [HttpGet("{id:long}")]
    public async Task<IActionResult> Get(long id, CancellationToken ct)
    {
        var r = await svc.GetAsync(id, ct);
        return r is null ? NotFound() : Ok(r);
    }

    [HttpPost("{id:long}/approve")]
    public async Task<IActionResult> Approve(long id, [FromBody] ExceptionApproveRequest req, CancellationToken ct)
    {
        try
        {
            if (req is null) return BadRequest(new { success = false, error = "request body is required." });
            var result = await svc.ApproveAsync(id, req, ct);
            return result.Success ? Ok(result) : BadRequest(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "ExceptionCentre.Approve failed for {Id}", id);
            return BadRequest(new { success = false, error = ex.Message, inner = ex.InnerException?.Message });
        }
    }

    [HttpPost("{id:long}/reject")]
    public async Task<IActionResult> Reject(long id, [FromBody] ExceptionRejectRequest req, CancellationToken ct)
    {
        try
        {
            if (req is null) return BadRequest(new { success = false, error = "request body is required." });
            var result = await svc.RejectAsync(id, req, ct);
            return result.Success ? Ok(result) : BadRequest(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "ExceptionCentre.Reject failed for {Id}", id);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }

    // Migration 184 -- SLA Candidate approve. Distinct endpoint so the
    // shape of the request body (no effective_until / approval_note)
    // stays honest to what the SLA-override flow actually needs.
    [HttpPost("{id:long}/approve-sla")]
    public async Task<IActionResult> ApproveSla(long id, [FromBody] ExceptionApproveSlaRequest req, CancellationToken ct)
    {
        try
        {
            if (req is null) return BadRequest(new { success = false, error = "request body is required." });
            var result = await svc.ApproveSlaAsync(id, req, ct);
            return result.Success ? Ok(result) : BadRequest(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "ExceptionCentre.ApproveSla failed for {Id}", id);
            return BadRequest(new { success = false, error = ex.Message, inner = ex.InnerException?.Message });
        }
    }

    // =================================================================
    // Migration 257 -- Analysis stage
    //
    // A Pending request is analysed here, then submitted. Approve and
    // Reject refuse anything that is not SubmittedForApproval (except the
    // task-side request types, which never had an analysis stage).
    // =================================================================
    // Migration 260 -- the audit trail. Every action_code the procedures
    // write, newest first; the UI decides what to show.
    // A bare array, like the tasks and attachments listings above -- one
    // shape for every collection this controller returns.
    [HttpGet("{id:long}/history")]
    public async Task<IActionResult> History(long id, CancellationToken ct)
        => Ok(await svc.ListHistoryAsync(id, ct));

    [HttpPost("{id:long}/analysis")]
    public async Task<IActionResult> SaveAnalysis(
        long id, [FromBody] ExceptionAnalysisSaveRequest? body, CancellationToken ct)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        var r = await svc.SaveAnalysisAsync(id, body, ct);
        return r.Success ? Ok(new { exceptionRequestId = r.ExceptionRequestId })
                         : BadRequest(new { error = r.Error });
    }

    [HttpPost("{id:long}/submit-for-approval")]
    public async Task<IActionResult> SubmitForApproval(
        long id, [FromBody] ExceptionSubmitForApprovalRequest? body, CancellationToken ct)
    {
        var req = body ?? new ExceptionSubmitForApprovalRequest(null, null);
        var r = await svc.SubmitForApprovalAsync(id, req, ct);
        return r.Success ? Ok(new { exceptionRequestId = r.ExceptionRequestId })
                         : BadRequest(new { error = r.Error });
    }

    [HttpGet("{id:long}/tasks")]
    public async Task<IActionResult> ListTasks(long id, CancellationToken ct)
        => Ok(await svc.ListTasksAsync(id, ct));

    /// <summary>
    /// The "map an existing task" picker: tasks under this exception's
    /// linked practice. Already-linked ones come back flagged, not hidden.
    /// </summary>
    [HttpGet("{id:long}/task-candidates")]
    public async Task<IActionResult> ListTaskCandidates(
        long id, [FromQuery] string? search, CancellationToken ct)
        => Ok(await svc.ListTaskCandidatesAsync(id, search, ct));

    [HttpPost("{id:long}/tasks")]
    public async Task<IActionResult> LinkTask(
        long id, [FromBody] ExceptionTaskLinkRequest? body, CancellationToken ct)
    {
        if (body is null || body.TaskId <= 0)
            return BadRequest(new { error = "taskId is required." });
        var r = await svc.LinkTaskAsync(id, body, ct);
        return r.Success ? Ok(new { exceptionRequestId = r.ExceptionRequestId, taskId = body.TaskId })
                         : BadRequest(new { error = r.Error });
    }

    [HttpDelete("{id:long}/tasks/{taskId:long}")]
    public async Task<IActionResult> UnlinkTask(
        long id, long taskId, [FromQuery] string? callerDisplayName, CancellationToken ct)
    {
        var r = await svc.UnlinkTaskAsync(id, taskId, callerDisplayName, ct);
        return r.Success ? Ok(new { exceptionRequestId = r.ExceptionRequestId, taskId })
                         : BadRequest(new { error = r.Error });
    }

    [HttpGet("{id:long}/attachments")]
    public async Task<IActionResult> ListAttachments(long id, CancellationToken ct)
        => Ok(await svc.ListAttachmentsAsync(id, ct));

    // Multipart. CollectionMethodCode drives which fields are required:
    //   Manual    -> File must be present
    //   Automated -> EvidenceLocation + EvidenceLocator must be present
    // The proc validates the same rule server-side; controller checks
    // it here too so we return 400 with a clear message before hitting DB.
    [HttpPost("{id:long}/attachments")]
    [Consumes("multipart/form-data")]
    [RequestSizeLimit(52_428_800)]
    public async Task<IActionResult> UploadAttachment(long id,
        [FromForm] ExceptionAttachmentUploadForm form, CancellationToken ct)
    {
        try
        {
            if (form is null) return BadRequest(new { success = false, error = "form is required." });
            var method = string.IsNullOrWhiteSpace(form.CollectionMethodCode) ? "Manual" : form.CollectionMethodCode;

            if (method.Equals("Manual", StringComparison.OrdinalIgnoreCase))
            {
                if (form.File is null || form.File.Length == 0)
                    return BadRequest(new { success = false, error = "Manual attachment requires a file." });
            }
            else
            {
                if (string.IsNullOrWhiteSpace(form.EvidenceLocation) || string.IsNullOrWhiteSpace(form.EvidenceLocator))
                    return BadRequest(new { success = false, error = "Automated attachment requires evidenceLocation and evidenceLocator." });
            }

            byte[]? bytes = null;
            string? fileName = null;
            string? contentType = null;
            if (form.File is { Length: > 0 } f)
            {
                using var ms = new MemoryStream();
                await f.CopyToAsync(ms, ct);
                bytes = ms.ToArray();
                fileName = f.FileName;
                contentType = f.ContentType;
            }

            var attId = await svc.SaveAttachmentAsync(id, method, form.EvidenceTypeCode,
                fileName, contentType, bytes,
                form.EvidenceLocation, form.EvidenceLocator,
                form.UploadedByEmployeeId, form.CallerDisplayName, ct);
            return Ok(new { success = attId > 0, attachmentId = attId });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "ExceptionCentre.UploadAttachment failed for {Id}", id);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }

    [HttpGet("attachments/{attachmentId:long}")]
    public async Task<IActionResult> DownloadAttachment(long attachmentId,
        [FromQuery] bool inline, CancellationToken ct)
    {
        var (bytes, fileName, contentType) = await svc.GetAttachmentAsync(attachmentId, ct);
        if (bytes is null) return NotFound();
        var ct2 = string.IsNullOrWhiteSpace(contentType) ? "application/octet-stream" : contentType;
        if (inline)
        {
            var cd = new System.Net.Http.Headers.ContentDispositionHeaderValue("inline") { FileName = fileName };
            Response.Headers["Content-Disposition"] = cd.ToString();
            return File(bytes, ct2);
        }
        return File(bytes, ct2, fileName);
    }
}
