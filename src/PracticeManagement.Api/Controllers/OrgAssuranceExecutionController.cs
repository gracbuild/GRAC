// =====================================================================
// OrgAssuranceExecutionController
//
// Phase 2 Assurance Management -- Stage 3 Execution API.
//
// Route: /api/practice/org-assurance (shared with other org-assurance
// controllers -- ASP.NET Core routes by specific action template).
//
// Endpoints:
//   GET    /execution-statuses
//   GET    /executions?organizationId=&definitionId=&statusCode=&originType=&search=&page=&pageSize=
//   GET    /executions/{id}?organizationId=
//   POST   /executions/materialize                Materialize an execution
//                                                 (545: scopeResolutionId optional --
//                                                  omitted, the scope is resolved now)
//   DELETE /executions/{id}?organizationId=&actor=
//   POST   /executions/{id}/start
//   POST   /executions/{id}/submit
//   POST   /executions/{id}/review
//   POST   /executions/{id}/approve
//   POST   /executions/{id}/close
//   POST   /executions/{id}/cancel
//   GET    /executions/{id}/entities?organizationId=&dimensionCode=&statusCode=&search=&page=&pageSize=
//
//   555 -- My Audits, live scope, Freeze Scope. The caller is the
//   session employee the Web tier stamps (X-PM-Caller-Employee-Id).
//   POST   /my-audits/prepare                     start the caller's due
//          engagements (From <= today) -> { data: [{ planItemId,
//          engagementCode, started, message }] }
//   GET    /my-audits                             the caller's audits ->
//          { data: [{ ..., executionId, scopeFrozenAt, auditState }] }
//          auditState: Upcoming / Ready / ScopeLive / InProgress / Done / Cancelled
//   GET    /executions/{id}/live-scope?organizationId=   the scope Freeze
//          would take now (branch-narrowed; nothing saved); a frozen
//          execution returns its frozen entities
//   GET    /executions/{id}/scope-exclusions?organizationId=
//   GET    /executions/{id}/responses?organizationId=   558: { questions: [{
//          setOrder, questionSetCode, questionSetName, questionId, questionCode,
//          questionText, helpText, isMandatory, evidenceTypeName,
//          expectedEvidence, resultCode, description, ownerEmployeeId,
//          ownerDisplayName, answeredBy, answeredDt, observationId,
//          observationCode, observationStatusName }], counts: [{ resultCode,
//          questionCount }] }
//   POST   /executions/{id}/responses   558: { organizationId, questionId,
//          resultCode (Compliant / NotCompliant / NotApplicable), description,
//          ownerEmployeeId, actor } -- assigned auditor, In Progress only;
//          Not compliant raises / edits the finding, Compliant / Not
//          applicable withdraws an Open one -> { questionId, resultCode,
//          observationId, observationCode, observationStatusName }
//   GET    /executions/{id}/continuous-assurance?organizationId=   556:
//          { summary: [{ summaryKind, label, itemCount }], detail: [{
//          dimensionCode, entityName, practiceInstanceId, instanceName, via,
//          obligationId, obligationName, obligationType, frequency,
//          obligationStatusName, lastTaskNumber, lastTaskStatusName,
//          lastTaskDueDate, ... }] } -- over the frozen or live scope;
//          each obligation counted once in the summary
//   POST   /executions/{id}/freeze-scope          { organizationId,
//          exclusions: [{ dimensionCode, entityId, reason }], actor,
//          review: { categories: [{ code, isIncluded }], excluded: [{
//          categoryCode, recordId, reason }], manual: [{ categoryCode,
//          name, note }] } }   (563: Step 3 Review and Confirm)
//          assigned auditor only; Planned -> In Progress; final. The
//          review is kept as the approved scope snapshot (version 1) ->
//          { ..., reviewId, reviewVersionNo }
//   GET    /executions/{id}/scope-review?organizationId=   563: { header:
//          { reviewId, versionNo, reviewStatus, approvedBy, approvedDt,
//          isFrozen }, categories: [{ categoryCode, categoryName,
//          displayOrder, itemCount, isIncluded }], items: [{ categoryCode,
//          recordId, recordCode, recordName, status, reason, isKept,
//          exclusionReason, isManual, manualNote }] } -- live: the
//          discovery over the engagement's scope now; frozen: the snapshot
//   GET    /executions/{id} also returns scopeFrozenAt (null = live),
//          scopeFrozenBy, scopeExclusionCount. POST /executions/{id}/start
//          refuses a live scope (54030).
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-assurance")]
public sealed class OrgAssuranceExecutionController(
    IOrgAssuranceExecutionService service,
    ILogger<OrgAssuranceExecutionController> logger) : ControllerBase
{
    // 555: the signed-in employee, stamped by the Web tier from the session
    // (CallerIdentityHandler) -- never taken from the browser.
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";

    private long? CallerEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private string CallerActor(string? actor) =>
        !string.IsNullOrWhiteSpace(actor) ? actor : CallerEmployeeId is { } id ? $"employee:{id}" : "system";

    // ================================================================
    // Lookups
    // ================================================================
    [HttpGet("execution-statuses")]
    public async Task<IActionResult> ListStatuses(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListStatusesAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceExecutionController.ListStatuses failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // Executions
    // ================================================================
    [HttpGet("executions")]
    public async Task<IActionResult> List(
        [FromQuery] long?   organizationId,
        [FromQuery] long?   definitionId,
        [FromQuery] string? statusCode,
        [FromQuery] string? originType,
        [FromQuery] string? search,
        [FromQuery] int page     = 1,
        [FromQuery] int pageSize = 25,
        // Migration 414 -- management dashboard drill-down (?drillCode=,
        // statusText=, severityText=, minAgeDays=, maxAgeDays=, noOwner=).
        // Every value absent = the list exactly as before.
        [FromQuery] ListDrillQuery? drill = null,
        CancellationToken cancellationToken = default)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.ListAsync(
                new OrgAssuranceExecutionListQuery(
                    organizationId.Value, definitionId,
                    statusCode, originType, search, page, pageSize, drill?.ToFilter()),
                cancellationToken);
            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceExecutionController.List failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("executions/{id:long}")]
    public async Task<IActionResult> Get(
        long id,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var detail = await service.GetAsync(organizationId.Value, id, cancellationToken);
            return detail is null
                ? NotFound(new { error = "Execution not found." })
                : Ok(new { data = detail });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceExecutionController.Get failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("executions/materialize")]
    public async Task<IActionResult> Materialize(
        [FromBody] OrgAssuranceExecutionMaterializeRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await service.MaterializeAsync(body, cancellationToken);
        return result.Success
            ? Ok(new
              {
                  executionId      = result.ExecutionId,
                  executionCode    = result.ExecutionCode,
                  executionName    = result.ExecutionName,
                  totalEntityCount = result.TotalEntityCount
              })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpDelete("executions/{id:long}")]
    public async Task<IActionResult> Delete(
        long id,
        [FromQuery] long?   organizationId,
        [FromQuery] string? actor,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await service.DeleteAsync(
            new OrgAssuranceExecutionCommandRequest(organizationId.Value, id, actor),
            cancellationToken);
        return result.Success
            ? Ok(new { executionId = result.ExecutionId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // Lifecycle
    // ================================================================
    [HttpPost("executions/{id:long}/start")]
    public Task<IActionResult> Start   (long id, [FromBody] OrgAssuranceExecutionCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.StartAsync(r, c));

    [HttpPost("executions/{id:long}/submit")]
    public Task<IActionResult> Submit  (long id, [FromBody] OrgAssuranceExecutionCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.SubmitAsync(r, c));

    [HttpPost("executions/{id:long}/review")]
    public Task<IActionResult> Review  (long id, [FromBody] OrgAssuranceExecutionCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.ReviewAsync(r, c));

    [HttpPost("executions/{id:long}/approve")]
    public Task<IActionResult> Approve (long id, [FromBody] OrgAssuranceExecutionCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.ApproveAsync(r, c));

    [HttpPost("executions/{id:long}/close")]
    public Task<IActionResult> Close   (long id, [FromBody] OrgAssuranceExecutionCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.CloseAsync(r, c));

    [HttpPost("executions/{id:long}/cancel")]
    public Task<IActionResult> Cancel  (long id, [FromBody] OrgAssuranceExecutionCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.CancelAsync(r, c));

    private async Task<IActionResult> Invoke(
        long routeId,
        OrgAssuranceExecutionCommandRequest? body,
        CancellationToken cancellationToken,
        Func<IOrgAssuranceExecutionService, OrgAssuranceExecutionCommandRequest, CancellationToken, Task<OrgAssuranceExecutionCommandResult>> op)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var effective = body with { ExecutionId = routeId };
        var result    = await op(service, effective, cancellationToken);
        return result.Success
            ? Ok(new { executionId = result.ExecutionId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // Entities
    // ================================================================
    [HttpGet("executions/{id:long}/entities")]
    public async Task<IActionResult> ListEntities(
        long id,
        [FromQuery] long?   organizationId,
        [FromQuery] string? dimensionCode,
        [FromQuery] string? statusCode,
        [FromQuery] string? search,
        [FromQuery] int page     = 1,
        [FromQuery] int pageSize = 100,
        CancellationToken cancellationToken = default)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.ListEntitiesAsync(
                organizationId.Value, id,
                dimensionCode, statusCode, search,
                page, pageSize, cancellationToken);
            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceExecutionController.ListEntities failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // 120 -- per-entity Auditor assignment (role+employee hybrid)
    // ================================================================
    [HttpPost("executions/{id:long}/entities/{entityId:long}/auditor")]
    public async Task<IActionResult> AssignEntityAuditor(
        long id, long entityId,
        [FromBody] OrgAssuranceExecutionAuditorAssignRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null)
            return BadRequest(new { error = "Request body is required." });

        // Honor the route ids over any body-supplied values (defense in depth).
        var effective = body with { ExecutionId = id, ExecutionEntityId = entityId };

        var result = await service.AssignEntityAuditorAsync(effective, cancellationToken);
        return result.Success
            ? Ok(result)
            : BadRequest(new
              {
                  error      = result.Error,
                  reasonCode = result.ReasonCode
              });
    }

    // ================================================================
    // 555 -- My Audits, live scope, Freeze Scope
    // ================================================================
    [HttpPost("my-audits/prepare")]
    public async Task<IActionResult> PrepareMyAudits(CancellationToken cancellationToken)
    {
        if (CallerEmployeeId is not { } employeeId)
            return BadRequest(new { error = "My Audits needs a sign-in with an employee record." });
        try
        {
            var rows = await service.PrepareMyAuditsAsync(employeeId, CallerActor(null), cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceExecutionController.PrepareMyAudits failed for employee {Id}", employeeId);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("my-audits")]
    public async Task<IActionResult> ListMyAudits(CancellationToken cancellationToken)
    {
        if (CallerEmployeeId is not { } employeeId)
            return BadRequest(new { error = "My Audits needs a sign-in with an employee record." });
        try
        {
            var rows = await service.ListMyAuditsAsync(employeeId, cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceExecutionController.ListMyAudits failed for employee {Id}", employeeId);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("executions/{id:long}/live-scope")]
    public async Task<IActionResult> ListLiveScope(
        long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        try
        {
            var rows = await service.ListLiveScopeAsync(organizationId.Value, id, CallerActor(null), cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceExecutionController.ListLiveScope failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("executions/{id:long}/responses")]
    public async Task<IActionResult> ListResponses(
        long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        try
        {
            var result = await service.ListResponsesAsync(organizationId.Value, id, cancellationToken);
            return Ok(new { questions = result.Questions, counts = result.Counts });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceExecutionController.ListResponses failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("executions/{id:long}/responses")]
    public async Task<IActionResult> SaveResponse(
        long id, [FromBody] OrgAssuranceResponseSaveRequest? body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (CallerEmployeeId is not { } employeeId)
            return BadRequest(new { error = "Sign in as the assigned auditor to answer.", reasonCode = "RESPONSE_EMPLOYEE_REQUIRED" });

        var result = await service.SaveResponseAsync(id, employeeId, body, CallerActor(body.Actor), cancellationToken);
        return result.Success
            ? Ok(new
              {
                  questionId            = result.QuestionId,
                  resultCode            = result.ResultCode,
                  observationId         = result.ObservationId,
                  observationCode       = result.ObservationCode,
                  observationStatusCode = result.ObservationStatusCode,
                  observationStatusName = result.ObservationStatusName
              })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpGet("executions/{id:long}/continuous-assurance")]
    public async Task<IActionResult> GetContinuousAssurance(
        long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        try
        {
            var result = await service.GetContinuousAssuranceAsync(organizationId.Value, id, CallerActor(null), cancellationToken);
            return Ok(new { summary = result.Summary, detail = result.Detail });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceExecutionController.GetContinuousAssurance failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("executions/{id:long}/scope-exclusions")]
    public async Task<IActionResult> ListScopeExclusions(
        long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        try
        {
            var rows = await service.ListScopeExclusionsAsync(organizationId.Value, id, cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceExecutionController.ListScopeExclusions failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // 563: Scope Builder Step 3 -- the review to confirm, or the snapshot.
    [HttpGet("executions/{id:long}/scope-review")]
    public async Task<IActionResult> GetScopeReview(
        long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        try
        {
            var result = await service.GetScopeReviewAsync(organizationId.Value, id, cancellationToken);
            return Ok(new { header = result.Header, categories = result.Categories, items = result.Items });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceExecutionController.GetScopeReview failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("executions/{id:long}/freeze-scope")]
    public async Task<IActionResult> FreezeScope(
        long id, [FromBody] OrgAssuranceFreezeScopeRequest? body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (CallerEmployeeId is not { } employeeId)
            return BadRequest(new { error = "Sign in as the assigned auditor to freeze the scope.", reasonCode = "EMPLOYEE_REQUIRED" });

        var result = await service.FreezeScopeAsync(id, employeeId, body, CallerActor(body.Actor), cancellationToken);
        return result.Success
            ? Ok(new
              {
                  executionId      = result.ExecutionId,
                  executionCode    = result.ExecutionCode,
                  totalEntityCount = result.TotalEntityCount,
                  excludedCount    = result.ExcludedCount,
                  reviewId         = result.ReviewId,          // 563
                  reviewVersionNo  = result.ReviewVersionNo    // 563
              })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }
}
