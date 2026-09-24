// =====================================================================
// RiskCentreController  (charter §5)
// Route: /api/practice/risk-centre/...
// Mirrors ExceptionCentreController; risk terminology (Accept/Reject/
// Withdraw) instead of Approve/Reject/Withdraw.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/risk-centre")]
public sealed class RiskCentreController(
    IRiskCentreService svc,
    ILogger<RiskCentreController> logger) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> List(
        [FromQuery] long organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.ListAsync(organizationId, statusCode, page, pageSize, ct));
    }

    [HttpGet("{id:long}")]
    public async Task<IActionResult> Get(long id, CancellationToken ct)
    {
        var r = await svc.GetAsync(id, ct);
        return r is null ? NotFound() : Ok(r);
    }

    [HttpPost("{id:long}/accept")]
    public async Task<IActionResult> Accept(long id, [FromBody] RiskAcceptRequest req, CancellationToken ct)
    {
        try
        {
            if (req is null) return BadRequest(new { success = false, error = "request body is required." });
            var result = await svc.AcceptAsync(id, req, ct);
            return result.Success ? Ok(result) : BadRequest(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "RiskCentre.Accept failed for {Id}", id);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }

    [HttpPost("{id:long}/reject")]
    public async Task<IActionResult> Reject(long id, [FromBody] RiskRejectRequest req, CancellationToken ct)
    {
        try
        {
            if (req is null) return BadRequest(new { success = false, error = "request body is required." });
            var result = await svc.RejectAsync(id, req, ct);
            return result.Success ? Ok(result) : BadRequest(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "RiskCentre.Reject failed for {Id}", id);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }

    [HttpPost("{id:long}/withdraw")]
    public async Task<IActionResult> Withdraw(long id, [FromBody] RiskWithdrawRequest req, CancellationToken ct)
    {
        try
        {
            if (req is null) return BadRequest(new { success = false, error = "request body is required." });
            var result = await svc.WithdrawAsync(id, req, ct);
            return result.Success ? Ok(result) : BadRequest(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "RiskCentre.Withdraw failed for {Id}", id);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }

    [HttpGet("{id:long}/attachments")]
    public async Task<IActionResult> ListAttachments(long id, CancellationToken ct)
        => Ok(await svc.ListAttachmentsAsync(id, ct));

    // Same evidence-style semantics as exception centre.
    [HttpPost("{id:long}/attachments")]
    [Consumes("multipart/form-data")]
    [RequestSizeLimit(52_428_800)]
    public async Task<IActionResult> UploadAttachment(long id,
        [FromForm] RiskAttachmentUploadForm form, CancellationToken ct)
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
            logger.LogError(ex, "RiskCentre.UploadAttachment failed for {Id}", id);
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

    // =================================================================
    // Risk Register (migrations 204-207)
    // BRD: "Risk Candidate Analysis and Risk Register"
    //
    // Validation lives in the stored procedures — see 206's header for
    // why. These actions therefore only guard what SQL cannot see (a
    // missing body, a non-positive id) and pass the proc's message
    // through unchanged, because those messages cite the BRD clause the
    // caller violated.
    // =================================================================

    // §7, §12, §13 — the organisation's own scale, categories and sources.
    [HttpGet("scoring-options")]
    public async Task<IActionResult> ScoringOptions([FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.GetScoringOptionsAsync(organizationId, ct));
    }

    // §7.1 — current analysis for a candidate.
    [HttpGet("{id:long}/analysis")]
    public async Task<IActionResult> GetAnalysis(long id, CancellationToken ct)
    {
        var a = await svc.GetAnalysisAsync(id, null, ct);
        return a is null ? NotFound() : Ok(a);
    }

    // §20 — every retained version.
    [HttpGet("{id:long}/analysis/history")]
    public async Task<IActionResult> GetAnalysisHistory(long id, CancellationToken ct)
        => Ok(await svc.GetAnalysisHistoryAsync(id, ct));

    // §7 — save. Each call writes a NEW version; nothing is overwritten.
    [HttpPost("{id:long}/analysis")]
    public async Task<IActionResult> SaveAnalysis(long id, [FromBody] RiskAnalysisSaveRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.SaveAnalysisAsync(id, null, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // §6.2, §18 — assign the Risk Analyst.
    [HttpPost("{id:long}/assign")]
    public async Task<IActionResult> Assign(long id, [FromBody] RiskCandidateAssignRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.AssignAsync(id, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // §8C — return for clarification / re-analysis.
    [HttpPost("{id:long}/clarify")]
    public async Task<IActionResult> Clarify(long id, [FromBody] RiskCandidateClarifyRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.ClarifyAsync(id, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // §15 — close the candidate against an existing register entry.
    [HttpPost("{id:long}/close-duplicate")]
    public async Task<IActionResult> CloseDuplicate(long id, [FromBody] RiskCandidateDuplicateRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.CloseDuplicateAsync(id, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // §8A — Route A. Fails with a 560xx message if the analysis is
    // absent or incomplete; that failure IS BRD §24 rule 1.
    [HttpPost("{id:long}/register")]
    public async Task<IActionResult> Register(long id, [FromBody] RiskRegisterRequest? req, CancellationToken ct)
    {
        var result = await svc.RegisterAsync(id,
            req ?? new RiskRegisterRequest(null, null, null, null, null, null, null, null, null), ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // §15 — advisory duplicate detection, used before either route
    // registers. Never blocks; the analyst decides.
    [HttpPost("duplicate-check")]
    public async Task<IActionResult> DuplicateCheck([FromBody] RiskDuplicateCheckRequest req, CancellationToken ct)
    {
        if (req is null || req.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.CheckDuplicatesAsync(req, ct));
    }

    // §4B, §11 — Route B. Creation and analysis in one call; no
    // candidate row is created.
    [HttpPost("custom")]
    public async Task<IActionResult> CreateCustom([FromBody] RiskCustomCreateRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.CreateCustomRiskAsync(req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // §9, §23 — the register grid.
    [HttpGet("register")]
    public async Task<IActionResult> ListRegister(
        [FromQuery] long organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] string? sourceTypeCode,
        [FromQuery] string? categoryCode,
        [FromQuery] string? ratingCode,
        [FromQuery] long? ownerEmployeeId,
        [FromQuery] string? search,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        // The Register toolbar has sent analysisPending since 216, but no
        // parameter here ever received it, so the "Analysis pending"
        // filter silently did nothing. sp_risk_register_list has always
        // supported it.
        //
        // Bound as a STRING, not bool?. The screen sends "1" / "0", and
        // .NET's bool binder accepts only "true" / "false" -- declaring
        // it as bool? would turn every filtered request into an automatic
        // 400 under [ApiController], which the screen reports as "no
        // risks match these filters". Anything unrecognised is treated as
        // "no opinion" rather than rejected.
        [FromQuery] string? analysisPending = null,
        // Migration 258 — the residual half of the grid. residualPending
        // is bound as a string for the same reason analysisPending is:
        // the screen sends "1" / "0" and the bool? binder would turn a
        // filtered request into an automatic 400.
        [FromQuery] string? residualRatingCode = null,
        [FromQuery] string? residualPending = null,
        // Migrations 261-264. treatmentOptionCode is one of Terminate /
        // Treat / Transfer / Tolerate; workflowStageCode is one of the
        // derived stages from vw_pm_risk_workflow_stage. reviewDue is a
        // string for the same reason the two pending filters are.
        [FromQuery] string? treatmentOptionCode = null,
        [FromQuery] string? workflowStageCode = null,
        [FromQuery] string? reviewDue = null,
        CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });

        return Ok(await svc.ListRegisterAsync(organizationId, statusCode, sourceTypeCode,
            categoryCode, ratingCode, ownerEmployeeId, search, page, pageSize,
            TriState(analysisPending), residualRatingCode, TriState(residualPending),
            treatmentOptionCode, workflowStageCode, TriState(reviewDue), ct));
    }

    // "1"/"0" from the screen, "true"/"false" from anything hand-rolled,
    // anything else means "no opinion" rather than a 400. One helper, so
    // the two pending filters cannot interpret the same string
    // differently.
    private static bool? TriState(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        "1" or "true"  or "yes" => true,
        "0" or "false" or "no"  => false,
        _                       => null
    };

    // §9.1 + §10 — the risk and its whole traceability chain.
    [HttpGet("register/{riskId:long}")]
    public async Task<IActionResult> GetRegister(long riskId, CancellationToken ct)
    {
        var r = await svc.GetRegisterAsync(riskId, ct);
        return r is null ? NotFound() : Ok(r);
    }

    // §17 — Active / UnderTreatment / Accepted / Monitoring / Closed / Retired.
    [HttpPost("register/{riskId:long}/status")]
    public async Task<IActionResult> SetRegisterStatus(long riskId, [FromBody] RiskRegisterStatusRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.SetRegisterStatusAsync(riskId, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // §18 — Risk Owner accepts ownership of the registered risk.
    [HttpPost("register/{riskId:long}/owner")]
    public async Task<IActionResult> SetRegisterOwner(long riskId, [FromBody] RiskRegisterOwnerRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.SetRegisterOwnerAsync(riskId, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // =================================================================
    // Phase B — migrations 208-211
    // =================================================================

    // ---- §19 configuration ------------------------------------------
    [HttpGet("config")]
    public async Task<IActionResult> GetConfig([FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var c = await svc.GetConfigAsync(organizationId, ct);
        return c is null ? NotFound() : Ok(c);
    }

    [HttpPost("config")]
    public async Task<IActionResult> SaveConfig([FromQuery] long organizationId,
        [FromBody] RiskConfigSaveRequest req, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { success = false, error = "organizationId is required." });
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        try
        {
            var c = await svc.SaveConfigAsync(organizationId, req, ct);
            return c is null ? NotFound() : Ok(c);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex)
        {
            // 56222 / 56223 carry the configuration mistake in plain
            // words — a rating the matrix does not produce, or an unknown
            // role. Passing them through is the whole value.
            logger.LogWarning(ex, "RiskCentre.SaveConfig failed for org {Org}", organizationId);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }

    // ---- §19 approval workflow ---------------------------------------
    [HttpPost("{id:long}/submit-approval")]
    public async Task<IActionResult> SubmitApproval(long id, [FromBody] RiskApprovalRequest? req, CancellationToken ct)
    {
        var result = await svc.SubmitForApprovalAsync(id, req ?? new RiskApprovalRequest(null, null, null), ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    [HttpPost("{id:long}/approve")]
    public async Task<IActionResult> DecideApproval(long id, [FromBody] RiskApprovalDecisionRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.DecideApprovalAsync(id, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    [HttpGet("approval-queue")]
    public async Task<IActionResult> ApprovalQueue([FromQuery] long organizationId,
        [FromQuery] int page = 1, [FromQuery] int pageSize = 25, CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.ListApprovalQueueAsync(organizationId, page, pageSize, ct));
    }

    // ---- §21 notifications -------------------------------------------
    // This is an OUTBOX, not a sender. The sweep records who should have
    // been told; a dispatcher marks rows Sent.
    [HttpPost("notifications/sweep")]
    public async Task<IActionResult> SweepNotifications([FromQuery] long? organizationId,
        [FromQuery] int sinceHours = 168, [FromQuery] int maxEvents = 500, CancellationToken ct = default)
    {
        var result = await svc.SweepNotificationsAsync(organizationId, sinceHours, maxEvents, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    [HttpGet("notifications")]
    public async Task<IActionResult> ListNotifications(
        [FromQuery] long organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] string? notifyEventCode,
        [FromQuery] string? subjectTypeCode,
        [FromQuery] long? subjectRecordId,
        [FromQuery] long? recipientEmployeeId,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.ListNotificationsAsync(organizationId, statusCode, notifyEventCode,
            subjectTypeCode, subjectRecordId, recipientEmployeeId, page, pageSize, ct));
    }

    [HttpGet("notifications/counts")]
    public async Task<IActionResult> NotificationCounts([FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.GetNotificationCountsAsync(organizationId, ct));
    }

    [HttpPost("notifications/{notificationId:long}/mark")]
    public async Task<IActionResult> MarkNotification(long notificationId,
        [FromBody] RiskNotificationMarkRequest req, CancellationToken ct)
    {
        if (req is null || string.IsNullOrWhiteSpace(req.StatusCode))
            return BadRequest(new { success = false, error = "statusCode is required." });
        var ok = await svc.MarkNotificationAsync(notificationId, req, ct);
        return Ok(new { success = ok, notificationId, statusCode = req.StatusCode });
    }

    // ---- §23 dashboard -----------------------------------------------
    [HttpGet("dashboard")]
    public async Task<IActionResult> Dashboard([FromQuery] long organizationId,
        [FromQuery] int trendMonths = 12, CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.GetDashboardAsync(organizationId, trendMonths, ct));
    }

    [HttpGet("ageing")]
    public async Task<IActionResult> Ageing([FromQuery] long organizationId,
        [FromQuery] int minAgeDays = 0, [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25, CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.ListAgeingAsync(organizationId, minAgeDays, page, pageSize, ct));
    }

    // ---- §22 treatment task, opt-in ----------------------------------
    // Deliberately a separate action on a REGISTERED risk, not a flag on
    // registration: §22 puts the decision after registration.
    [HttpPost("register/{riskId:long}/treatment-task")]
    public async Task<IActionResult> RaiseTreatmentTask(long riskId,
        [FromBody] RiskTreatmentTaskRequest? req, CancellationToken ct)
    {
        var result = await svc.RaiseTreatmentTaskAsync(riskId,
            req ?? new RiskTreatmentTaskRequest(null, null, null, null, null, null, null), ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    [HttpGet("register/{riskId:long}/treatment-tasks")]
    public async Task<IActionResult> ListTreatmentTasks(long riskId, CancellationToken ct)
        => Ok(await svc.ListTreatmentWorkAsync(riskId, ct));

    // =================================================================
    // Two-stage assessment — migration 216
    //
    //   Stage 1  the candidate assessment: statement, threat,
    //            vulnerability, owner, business function -> register
    //   Stage 2  the scored analysis on a registered risk: category,
    //            likelihood, impact -> rating, then the §19 approval
    // =================================================================

    // The threat / vulnerability / business-function picklists. Separate
    // from /scoring-options because that one is the org's SCALE, which
    // stage 1 does not use.
    [HttpGet("assessment-options")]
    public async Task<IActionResult> AssessmentOptions([FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.GetAssessmentOptionsAsync(organizationId, ct));
    }

    // =================================================================
    // Organisation-owned threats and vulnerabilities (285, 286)
    //
    // assessment-options above is untouched and still serves the legacy
    // single-select picklists. These are the multi-select's own routes:
    // they carry ownership, exclude the "Others" placeholder, and can
    // create.
    // =================================================================

    [HttpGet("threats")]
    public async Task<IActionResult> ListThreats([FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.ListThreatsAsync(organizationId, ct));
    }

    [HttpGet("vulnerabilities")]
    public async Task<IActionResult> ListVulnerabilities([FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.ListVulnerabilitiesAsync(organizationId, ct));
    }

    // 200 on an existing name, not 409. sp_risk_threat_create is
    // idempotent by name and the response says which happened via
    // wasCreated -- the caller's next move is the same either way (show
    // the chip), so a conflict status would only make it go and look up
    // the row it was just handed.
    [HttpPost("threats")]
    public async Task<IActionResult> CreateThreat([FromBody] RiskThreatCreateRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { error = "request body is required." });
        if (req.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(req.Name)) return BadRequest(new { error = "name is required." });
        return Ok(await svc.CreateThreatAsync(req.OrganizationId, req.Name, req.CallerDisplayName, ct));
    }

    [HttpPost("vulnerabilities")]
    public async Task<IActionResult> CreateVulnerability([FromBody] RiskThreatCreateRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { error = "request body is required." });
        if (req.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(req.Name)) return BadRequest(new { error = "name is required." });
        return Ok(await svc.CreateVulnerabilityAsync(req.OrganizationId, req.Name, req.CallerDisplayName, ct));
    }

    [HttpGet("register/{riskId:long}/threats")]
    public async Task<IActionResult> GetThreatSelection(long riskId, CancellationToken ct)
        => Ok(await svc.GetThreatSelectionAsync(riskId, ct));

    [HttpPost("register/{riskId:long}/threats")]
    public async Task<IActionResult> SetThreatSelection(long riskId,
        [FromBody] RiskThreatSelectionRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { error = "request body is required." });
        if (req.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var count = await svc.SetThreatSelectionAsync(
            req.OrganizationId, null, riskId, req.ThreatIds, req.VulnerabilityIds,
            req.CallerDisplayName, ct);
        return Ok(new { success = true, threatCount = count });
    }

    // ANALYSIS-scoped twin of the route above. The candidate Analysis
    // form saves an analysis for a candidate that has not been
    // registered yet -- there is no risk_register_id to key on, and the
    // versioned analysis row is the correct owner of that selection
    // anyway. Registration later copies it forward.
    [HttpPost("analysis/{analysisId:long}/threats")]
    public async Task<IActionResult> SetAnalysisThreatSelection(long analysisId,
        [FromBody] RiskThreatSelectionRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { error = "request body is required." });
        if (req.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var count = await svc.SetThreatSelectionAsync(
            req.OrganizationId, analysisId, null, req.ThreatIds, req.VulnerabilityIds,
            req.CallerDisplayName, ct);
        return Ok(new { success = true, threatCount = count });
    }

    // =================================================================
    // Risk Type: Confidentiality / Integrity / Availability (313, 314)
    //
    // Master-table driven (313's header) -- the combo's options come
    // from here, not a hardcoded three-string list. No create route:
    // 313 deliberately has no free-text escape hatch for this field.
    // =================================================================

    [HttpGet("risk-types")]
    public async Task<IActionResult> ListRiskTypes([FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.ListRiskTypesAsync(organizationId, ct));
    }

    [HttpGet("register/{riskId:long}/risk-types")]
    public async Task<IActionResult> GetRiskTypeSelection(long riskId, CancellationToken ct)
        => Ok(await svc.GetRiskTypeSelectionAsync(riskId, ct));

    // Called right after register/{riskId}/assess succeeds, carrying the
    // RiskAnalysisId that call just returned -- one save writes both the
    // versioned analysis set and the register's current set, the same
    // way sp_risk_register_assess itself keeps both in step.
    [HttpPost("register/{riskId:long}/risk-types")]
    public async Task<IActionResult> SetRiskTypeSelection(long riskId,
        [FromBody] RiskTypeSelectionRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        if (req.OrganizationId <= 0) return BadRequest(new { success = false, error = "organizationId is required." });
        var result = await svc.SetRiskTypeSelectionAsync(
            req.OrganizationId, req.RiskAnalysisId, riskId, req.RiskTypeIds, req.CallerDisplayName, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // =================================================================
    // Risk Category, multi-select (375, 376)
    //
    // Same shape as Risk Type above and for the same reason -- master-
    // table driven, no create route (375 has no free-text escape hatch
    // either). No GET-all-options route here: the combo's options come
    // from GetScoringOptions's Categories, which already carries
    // RiskCategoryId.
    // =================================================================

    [HttpGet("register/{riskId:long}/risk-categories")]
    public async Task<IActionResult> GetRiskCategorySelection(long riskId, CancellationToken ct)
        => Ok(await svc.GetRiskCategorySelectionAsync(riskId, ct));

    // Called right after register/{riskId}/assess succeeds, carrying the
    // RiskAnalysisId that call just returned -- same second-call pattern
    // as Risk Type's POST above, and for the same reason: sp_risk_
    // register_assess is not touched.
    [HttpPost("register/{riskId:long}/risk-categories")]
    public async Task<IActionResult> SetRiskCategorySelection(long riskId,
        [FromBody] RiskCategorySelectionRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        if (req.OrganizationId <= 0) return BadRequest(new { success = false, error = "organizationId is required." });
        var result = await svc.SetRiskCategorySelectionAsync(
            req.OrganizationId, req.RiskAnalysisId, riskId, req.RiskCategoryIds, req.CallerDisplayName, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // Stage 2. Succeeds whether or not approval is required — the result
    // says which happened, because "saved, and the rating is live" and
    // "saved, and the rating is waiting for an approver" are different
    // outcomes the caller must be able to tell apart.
    [HttpPost("register/{riskId:long}/assess")]
    public async Task<IActionResult> AssessRegisteredRisk(long riskId,
        [FromBody] RiskRegisterAssessRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.AssessRegisteredRiskAsync(riskId, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // §19 at stage 2 — approving is what lets a rating reach the
    // authoritative register.
    [HttpPost("register/{riskId:long}/assess/approve")]
    public async Task<IActionResult> DecideRegisterAnalysis(long riskId,
        [FromBody] RiskApprovalDecisionRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.DecideRegisterAnalysisAsync(riskId, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // =================================================================
    // Residual Risk Analysis — migration 258
    //
    //   Inherent rating = the score BEFORE treatment  (stage 2, above)
    //   Residual rating = the score AFTER  treatment  (here)
    //
    // Both are resolved server-side from the organisation's own matrix
    // by the same procedure, so the register's two rating columns are
    // comparable. The client never sends a score.
    //
    // These do NOT pass through the §19 approval gate: that gate exists
    // to validate the inherent rating a threshold is written against.
    // =================================================================

    [HttpPost("register/{riskId:long}/residual")]
    public async Task<IActionResult> SaveResidualAnalysis(long riskId,
        [FromBody] RiskResidualSaveRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.SaveResidualAnalysisAsync(riskId, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // 204, not 404. "No residual assessment yet" is the normal state of
    // a newly registered risk; answering NotFound would make the screen
    // report a missing risk when the risk is fine.
    [HttpGet("register/{riskId:long}/residual")]
    public async Task<IActionResult> GetResidualAnalysis(long riskId, CancellationToken ct)
    {
        var r = await svc.GetResidualAnalysisAsync(riskId, ct);
        return r is null ? NoContent() : Ok(r);
    }

    // §20 — every retained version, newest first.
    [HttpGet("register/{riskId:long}/residual/history")]
    public async Task<IActionResult> GetResidualHistory(long riskId, CancellationToken ct)
        => Ok(await svc.GetResidualHistoryAsync(riskId, ct));

    // =================================================================
    // Practice / Asset mapping — migrations 261, 262
    //
    // The mapping panel on Risk Analysis. Three ways an asset reaches a
    // risk, all of them ending in ONE risk-level asset mapping:
    //   1. inherited from the risk's own practice
    //   2. inherited from an additionally mapped practice
    //   3. mapped directly, with no practice involved
    //
    // The API does not compute any of that. sp_risk_mapping_get returns
    // each asset already labelled, because the label is a rule and rules
    // live in the procedures.
    // =================================================================

    [HttpGet("register/{riskId:long}/mapping")]
    public async Task<IActionResult> GetMapping(long riskId, CancellationToken ct)
        => Ok(await svc.GetMappingAsync(riskId, ct));

    // Only what is still mappable — practices and assets this risk does
    // NOT already have. Offering something the constraints will reject is
    // worse than not offering it.
    [HttpGet("register/{riskId:long}/mapping/options")]
    public async Task<IActionResult> GetMappingOptions(long riskId,
        [FromQuery] string? search, [FromQuery] int top = 200, CancellationToken ct = default)
        => Ok(await svc.GetMappingOptionsAsync(riskId, search, top, ct));

    // Mapping a practice also inherits its dependency assets. Mapping the
    // same practice twice is a no-op, not an error — the analysis screen
    // re-syncs on every open and a screen that threw on its own second
    // open would be unusable.
    [HttpPost("register/{riskId:long}/practices")]
    public async Task<IActionResult> MapPractice(long riskId,
        [FromBody] RiskPracticeMapRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.MapPracticeAsync(riskId, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // Removes the practice and the assets nothing else vouches for. The
    // result reports both counts, because a user who removes a practice
    // and sees assets remain needs to be told why they remained.
    // Migration 284 -- "Existing Controls" on the risk analysis page.
    // Each mapped practice with its Framework / Source-structure root /
    // Statement, plus the tasks running under it. Read-only.
    [HttpGet("register/{riskId:long}/practice-context")]
    public async Task<IActionResult> GetPracticeContext(
        long riskId, [FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        var result = await svc.GetScopePracticeContextAsync(organizationId.Value, riskId, ct);
        return Ok(new { practices = result.Practices, tasks = result.Tasks });
    }

    [HttpDelete("register/{riskId:long}/practices/{practiceId:long}")]
    public async Task<IActionResult> UnmapPractice(long riskId, long practiceId,
        [FromQuery] long? actorEmployeeId, [FromQuery] string? caller, CancellationToken ct)
    {
        var result = await svc.UnmapPracticeAsync(riskId, practiceId, actorEmployeeId, caller, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // A dependency in ANY category, with no practice involved. The
    // category id comes from sp_risk_mapping_get's category result set,
    // and the object id from the repository gateway's
    // `dependency-options/query` — the same endpoint the Operationalize
    // picker uses. Neither is enumerated here.
    [HttpPost("register/{riskId:long}/dependencies")]
    public async Task<IActionResult> MapDependency(long riskId,
        [FromBody] RiskDependencyMapRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.MapDependencyAsync(riskId, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // Removes the DIRECT reason only. A dependency a mapped practice
    // still reaches stays on the risk, relabelled as inherited —
    // dependencyRemoved is false and remainingSources says how many
    // reasons survive.
    [HttpDelete("register/{riskId:long}/dependencies/{dependencyTypeId:int}/{dependencyObjectId:long}")]
    public async Task<IActionResult> UnmapDependency(long riskId, int dependencyTypeId, long dependencyObjectId,
        [FromQuery] long? actorEmployeeId, [FromQuery] string? caller, CancellationToken ct)
    {
        var result = await svc.UnmapDependencyAsync(riskId, dependencyTypeId, dependencyObjectId, actorEmployeeId, caller, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // =================================================================
    // Treatment Option — migrations 261, 263
    //
    //   Terminate / Treat / Transfer -> a RiskDriven task, owned by the
    //                                   risk owner, created once
    //   Tolerate                     -> no task; NextStep = 'Acceptance'
    //
    // Idempotent: posting the same option twice does not raise a second
    // task. TaskCreated says which happened.
    // =================================================================

    [HttpPost("register/{riskId:long}/treatment-option")]
    public async Task<IActionResult> SetTreatmentOption(long riskId,
        [FromBody] RiskTreatmentOptionRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.SetTreatmentOptionAsync(riskId, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // The counts, the task list and the answer to "can residual analysis
    // start yet?" — with the reason, so a disabled button can explain
    // itself instead of just being grey.
    [HttpGet("register/{riskId:long}/treatment-state")]
    public async Task<IActionResult> GetTreatmentState(long riskId, CancellationToken ct)
    {
        var r = await svc.GetTreatmentStateAsync(riskId, ct);
        return r is null ? NotFound() : Ok(r);
    }

    // Moves risks whose treatment tasks have all closed to Monitoring.
    // A sweep, not a callback: Task Centre does not know Risk Centre
    // exists and must not be made to. Idempotent, so it is safe to call
    // on every register load and after every task completion.
    [HttpPost("register/treatment-sync")]
    public async Task<IActionResult> SyncTreatment(
        [FromQuery] long? riskRegisterId, [FromQuery] long? organizationId,
        [FromQuery] string? caller, CancellationToken ct)
    {
        if (riskRegisterId is null && organizationId is null)
            return BadRequest(new { error = "riskRegisterId or organizationId is required." });
        var moved = await svc.SyncTreatmentAsync(riskRegisterId, organizationId, caller, ct);
        return Ok(new { risksMovedToMonitoring = moved });
    }

    // =================================================================
    // Acceptance, Review and the Risk Calendar — migration 264
    // =================================================================

    [HttpGet("register/{riskId:long}/acceptance")]
    public async Task<IActionResult> GetAcceptance(long riskId, CancellationToken ct)
    {
        var r = await svc.GetAcceptanceAsync(riskId, ct);
        return r is null ? NotFound() : Ok(r);
    }

    /// <summary>
    /// The Review Frequency options the acceptance select is built from
    /// (293, <c>sp_risk_review_frequency_list</c>).
    ///
    /// <para>No <c>organizationId</c>, and no org guard on the Web tier's
    /// forward either: <c>frequency_master</c> is a master table with no
    /// tenant column, so there is nothing here to scope to one
    /// organisation. The Web tier takes the session guard instead.</para>
    ///
    /// <para>Each row carries <c>frequencyValue</c>, <c>frequencyUnit</c>
    /// and <c>isCustom</c> so the client derives the review date from the
    /// data. A row with <c>isCustom: true</c> (or a null value/unit) means
    /// no date can be derived and the user types one.</para>
    /// </summary>
    [HttpGet("review-frequencies")]
    public async Task<IActionResult> ListReviewFrequencies(CancellationToken ct)
        => Ok(await svc.ListReviewFrequenciesAsync(ct));

    // nextReviewDate is REQUIRED and must be in the future. Without one
    // the risk would never return for review — see 264's header.
    // reviewFrequencyId (293) is optional and records what that date was
    // derived from; it does not relax the date rule in any way.
    [HttpPost("register/{riskId:long}/acceptance")]
    public async Task<IActionResult> SaveAcceptance(long riskId,
        [FromBody] RiskAcceptanceSaveRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.SaveAcceptanceAsync(riskId, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // The Review Risk list: next_review_date <= today, not closed.
    // Future dates do not appear. includeFutureDays widens the horizon
    // for a "coming up" panel without a second endpoint whose rules could
    // drift from these.
    [HttpGet("review-due")]
    public async Task<IActionResult> ListReviewDue(
        [FromQuery] long organizationId,
        [FromQuery] long? ownerEmployeeId,
        [FromQuery] string? ratingCode,
        [FromQuery] string? search,
        [FromQuery] int? includeFutureDays,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.ListReviewDueAsync(organizationId, ownerEmployeeId, ratingCode,
            search, includeFutureDays, page, pageSize, ct));
    }

    // The Risk Calendar feed. One row per risk with a review date in the
    // window, already shaped for a month grid — EventDate is the bucket
    // key and every field the day cell and side panel need is on the row.
    [HttpGet("review-calendar")]
    public async Task<IActionResult> GetReviewCalendar(
        [FromQuery] long organizationId,
        [FromQuery] DateTime? fromDate,
        [FromQuery] DateTime? toDate,
        [FromQuery] long? ownerEmployeeId,
        CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.GetReviewCalendarAsync(organizationId, fromDate, toDate, ownerEmployeeId, ct));
    }

    // A review IS a re-analysis: this delegates to the same
    // sp_risk_register_assess the Risk Analysis screen uses, then stamps
    // the review bookkeeping. No analysis logic is duplicated, so the two
    // paths cannot drift.
    [HttpPost("register/{riskId:long}/review")]
    public async Task<IActionResult> PerformReview(long riskId,
        [FromBody] RiskReviewPerformRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.PerformReviewAsync(riskId, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    /// <summary>
    /// Bulk review (270) — one disposition across a selection: remarks,
    /// status and next review date.
    ///
    /// <para><b>200 does not mean every risk was updated.</b> The response
    /// carries one row per risk with an outcome of Applied / Skipped /
    /// Unchanged; a risk that fails a rule (no treatment option, analysis
    /// incomplete) is skipped with its reason while the rest proceed. A
    /// client that reports "saved" without reading <c>skippedCount</c> is
    /// telling the user something false.</para>
    ///
    /// <para>400 means the BATCH was rejected — nothing selected, a review
    /// date in the past, or an attempt to Close/Retire in bulk.</para>
    ///
    /// <para>Not a loop over <c>/review</c>: that one re-assesses and needs
    /// per-risk likelihood and impact. See RiskBulkReviewRequest.</para>
    /// </summary>
    // =================================================================
    // Risk acceptance approval authority — migration 271
    //
    // Organization -> Risk Acceptance Approval Authority. Org-scoped
    // configuration, so organizationId is required on the read and
    // carried in the body on the save — the same scoping every other
    // org-configuration endpoint in this product uses.
    // =================================================================

    /// <summary>
    /// The configuration grid for one organisation: one row per rating
    /// level its own risk matrix produces, the roles available, and the
    /// migration-212 settings an unconfigured level falls back to.
    ///
    /// <para>The levels are derived, not enumerated — an organisation
    /// with a five-band matrix gets five rows with no code change.</para>
    /// </summary>
    [HttpGet("acceptance-authority")]
    public async Task<IActionResult> GetAcceptanceAuthority(
        [FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0)
            return BadRequest(new { success = false, error = "organizationId is required." });

        var result = await svc.GetAcceptanceAuthorityAsync(organizationId, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    /// <summary>
    /// Saves the whole grid, all or nothing.
    ///
    /// <para>400 carries the procedure's own message: a rating the
    /// organisation's matrix does not produce (56745), a role belonging
    /// to another organisation (56746), or "same as inherent" with no
    /// inherent approver to be the same as (56747). Nothing is written in
    /// any of those cases.</para>
    ///
    /// <para>On success the response is the configuration AS STORED —
    /// the procedure re-reads it — so the page never renders what it
    /// merely hoped it saved.</para>
    /// </summary>
    [HttpPost("acceptance-authority")]
    public async Task<IActionResult> SaveAcceptanceAuthority(
        [FromBody] RiskAcceptanceAuthoritySaveRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        if (req.OrganizationId <= 0)
            return BadRequest(new { success = false, error = "organizationId is required." });

        var result = await svc.SaveAcceptanceAuthorityAsync(req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    /// <summary>
    /// Who may approve accepting this risk — the single answer, used by
    /// the acceptance screen. <c>scope</c> is optional; omitted, the
    /// procedure picks Residual for a residually assessed risk and
    /// Inherent otherwise.
    /// </summary>
    [HttpGet("register/{riskId:long}/acceptance-authority")]
    public async Task<IActionResult> ResolveAcceptanceAuthority(
        long riskId, [FromQuery] string? scope, CancellationToken ct)
    {
        var result = await svc.ResolveAcceptanceAuthorityAsync(riskId, scope, ct);
        return result is null
            ? NotFound(new { success = false, error = $"Risk {riskId} was not found." })
            : Ok(result);
    }

    /// <summary>
    /// Bulk accept (295) — accept a selection in one operation.
    ///
    /// <para><b>Not <c>bulk-review</c> with status Accepted.</b> That one
    /// stamps a review (<c>last_reviewed_dt</c>, <c>review_count</c>),
    /// which is right when a risk returns at its review date and wrong
    /// for a first acceptance. Both compose
    /// <c>sp_risk_acceptance_save</c>, so the rules cannot diverge.</para>
    ///
    /// <para><b>200 does not mean every risk was accepted</b> — read
    /// <c>skippedCount</c> and the per-risk rows. 400 means the batch was
    /// refused outright: nothing selected, no review date, a past date,
    /// or an unknown cadence.</para>
    /// </summary>
    [HttpPost("register/bulk-accept")]
    public async Task<IActionResult> BulkAccept(
        [FromBody] RiskBulkAcceptRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });

        var result = await svc.BulkAcceptAsync(req, ct);
        if (!result.Success) return BadRequest(result);

        return Ok(new
        {
            success      = true,
            rows         = result.Rows,
            appliedCount = result.AppliedCount,
            skippedCount = result.SkippedCount
        });
    }

    [HttpPost("register/bulk-review")]
    public async Task<IActionResult> BulkReview(
        [FromBody] RiskBulkReviewRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });

        var result = await svc.BulkReviewAsync(req, ct);
        if (!result.Success) return BadRequest(result);

        return Ok(new
        {
            success        = true,
            rows           = result.Rows,
            appliedCount   = result.AppliedCount,
            skippedCount   = result.SkippedCount,
            unchangedCount = result.UnchangedCount
        });
    }
}
