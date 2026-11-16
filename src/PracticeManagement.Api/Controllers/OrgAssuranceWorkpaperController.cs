// =====================================================================
// OrgAssuranceWorkpaperController (567, Audit Change spec 4.6 / 4.7)
//
// Test Working Papers. Route: /api/practice/org-assurance (shared with the
// other assurance controllers; each action has its own template).
// The caller is the signed-in employee the Web tier stamps from the
// session (X-PM-Caller-Employee-Id, 555) -- never taken from the browser.
//
// Endpoints (rows are the procedures' columns):
//   GET  /testing-methods                     { data: [{ Code, Name }] }
//   GET  /observation-origins                 { data: [{ Code, Name }] }
//   GET  /workpapers/executions?organizationId=&mine=true&status=&search=
//        the executions the caller is lead / team / reviewer of (mine) or
//        all past Planned -> { data: [{ ExecutionId, ExecutionCode,
//        ExecutionName, DefinitionName, EngagementCode, ExecutionStatusCode,
//        LeadAuditorName, ReviewerName, IsLead, IsTeam, IsReviewer,
//        QuestionCount, ConcludedCount, AwaitingReviewCount, ScorePct,
//        ScoreBandName, PlannedStart, PlannedEnd }] }
//   GET  /executions/{id}/workpapers?organizationId=   { execution: {
//        ..., IsLead, IsTeam, IsReviewer, IsOpen, ScorePct, ScoreBandName,
//        AuditConclusion }, questions: [{ ExecutionQuestionId, QuestionCode,
//        QuestionText, TestingGuidance, Weight, AssignedEmployeeId,
//        AssignedName, ConclusionCode, ConclusionReason, PaperCount,
//        ApprovedCount, InReviewCount, OpenCount, SuggestedConclusion }],
//        papers: [{ WorkingPaperId, ExecutionQuestionId, PaperCode, ...,
//        TestResult, ReviewStatus, PreparedByName, FindingCode }],
//        team: [{ EmployeeId, EmployeeName, TeamRole }] }
//   GET  /executions/{id}/workpaper-activity?organizationId=&questionId=&workingPaperId=
//   POST /execution-questions/{id}/assign     { organizationId, assigneeEmployeeId } (lead)
//   POST /execution-questions/{id}/conclude   { organizationId, conclusionCode, reason }
//   POST /execution-questions/{id}/working-papers   { organizationId,
//        workingPaperId?, testingMethodCode, testingGuidance,
//        procedurePerformed, population, samplingMethod, sampleSize,
//        sampleDetails, evidenceReferences, testResult, deviations,
//        auditorComments, conclusion } -> { workingPaperId }
//   POST /working-papers/{id}/action          { organizationId, action:
//        SUBMIT / REVIEW / RETURN / APPROVE / REOPEN / DELETE, comment }
//   POST /working-papers/{id}/finding         { organizationId, title,
//        description, severityCode, ownerEmployeeId, dueDate, auditCriteria,
//        conditionText, rootCause, riskImpact, recommendation,
//        supportingEvidence } -> { observationId }
//   POST /executions/{id}/audit-conclusion    { organizationId, conclusion } (lead)
//   GET  /observations/{id}/finding?organizationId=   the spec 4.7 details
//   POST /observations/{id}/finding           { organizationId, originCode,
//        auditCriteria, conditionText, rootCause, riskImpact,
//        recommendation, managementResponse, correctiveAction,
//        supportingEvidence }
// Errors: { error, reasonCode } -- WP_NOT_ON_TEAM, WP_EXECUTION_NOT_IN_PROGRESS,
// WP_NOT_FOUND, WP_NOT_EDITABLE, WP_INCOMPLETE, WP_REVIEWER_ONLY,
// WP_REASON_REQUIRED, WP_LEAD_ONLY, WP_ASSIGNEE_NOT_ON_TEAM,
// WP_PAPERS_NOT_APPROVED, WP_CONCLUSION_REASON_REQUIRED, WP_INVALID_VALUE,
// WP_FINDING_NOT_ALLOWED, OBSERVATION_CLOSED, WP_EMPLOYEE_REQUIRED.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-assurance")]
public sealed class OrgAssuranceWorkpaperController(
    IOrgAssuranceWorkpaperService service,
    ILogger<OrgAssuranceWorkpaperController> logger) : ControllerBase
{
    // 555: the signed-in employee, stamped by the Web tier (CallerIdentityHandler).
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";

    private long? CallerEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private string CallerActor(string? actor) =>
        !string.IsNullOrWhiteSpace(actor) ? actor : CallerEmployeeId is { } id ? $"employee:{id}" : "system";

    private static BadRequestObjectResult NoEmployee() =>
        new(new { error = "Sign in as an auditor of this engagement.", reasonCode = "WP_EMPLOYEE_REQUIRED" });

    private IActionResult Result(OrgAssuranceWorkpaperResult result, string idName)
        => result.Success
            ? Ok(new Dictionary<string, object?> { [idName] = result.Id })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });

    private async Task<IActionResult> Read(Func<Task<object?>> read, string what)
    {
        try { return Ok(await read()); }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceWorkpaperController {What} failed", what);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // Reads
    // ================================================================
    [HttpGet("testing-methods")]
    public Task<IActionResult> ListTestingMethods(CancellationToken cancellationToken)
        => Read(async () => (object?)new { data = await service.ListTestingMethodsAsync(cancellationToken) }, "ListTestingMethods");

    [HttpGet("observation-origins")]
    public Task<IActionResult> ListObservationOrigins(CancellationToken cancellationToken)
        => Read(async () => (object?)new { data = await service.ListObservationOriginsAsync(cancellationToken) }, "ListObservationOrigins");

    [HttpGet("workpapers/executions")]
    public async Task<IActionResult> ListExecutions(
        [FromQuery] long? organizationId, [FromQuery] bool mine = true,
        [FromQuery] string? status = null, [FromQuery] string? search = null,
        CancellationToken cancellationToken = default)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        return await Read(async () => (object?)new
        {
            data = await service.ListExecutionsAsync(organizationId.Value, CallerEmployeeId, mine, status, search, cancellationToken)
        }, "ListExecutions");
    }

    [HttpGet("executions/{id:long}/workpapers")]
    public async Task<IActionResult> GetOverview(long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        return await Read(async () => (object?)await service.GetOverviewAsync(organizationId.Value, id, CallerEmployeeId, cancellationToken),
                          "GetOverview");
    }

    [HttpGet("executions/{id:long}/workpaper-activity")]
    public async Task<IActionResult> ListActivity(
        long id, [FromQuery] long? organizationId, [FromQuery] long? questionId, [FromQuery] long? workingPaperId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        return await Read(async () => (object?)new
        {
            data = await service.ListActivityAsync(organizationId.Value, id, questionId, workingPaperId, cancellationToken)
        }, "ListActivity");
    }

    [HttpGet("observations/{id:long}/finding")]
    public async Task<IActionResult> GetObservationFinding(long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var row = await service.GetObservationFindingAsync(organizationId.Value, id, cancellationToken);
            return row is null ? NotFound(new { error = "Observation not found." }) : Ok(row);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceWorkpaperController.GetObservationFinding failed for {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // Writes (the caller must be signed in as an employee)
    // ================================================================
    [HttpPost("execution-questions/{id:long}/assign")]
    public async Task<IActionResult> AssignQuestion(long id, [FromBody] OrgAssuranceQuestionAssignRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.AssignQuestionAsync(id, emp, body, CallerActor(body.Actor), cancellationToken), "executionQuestionId");
    }

    [HttpPost("execution-questions/{id:long}/conclude")]
    public async Task<IActionResult> ConcludeQuestion(long id, [FromBody] OrgAssuranceQuestionConcludeRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.ConcludeQuestionAsync(id, emp, body, CallerActor(body.Actor), cancellationToken), "executionQuestionId");
    }

    [HttpPost("execution-questions/{id:long}/working-papers")]
    public async Task<IActionResult> SaveWorkingPaper(long id, [FromBody] OrgAssuranceWorkingPaperSaveRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.SaveWorkingPaperAsync(id, emp, body, CallerActor(body.Actor), cancellationToken), "workingPaperId");
    }

    [HttpPost("working-papers/{id:long}/action")]
    public async Task<IActionResult> WorkingPaperAction(long id, [FromBody] OrgAssuranceWorkingPaperActionRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(body.Action)) return BadRequest(new { error = "action is required." });
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.WorkingPaperActionAsync(id, emp, body, CallerActor(body.Actor), cancellationToken), "workingPaperId");
    }

    [HttpPost("working-papers/{id:long}/finding")]
    public async Task<IActionResult> RaiseFinding(long id, [FromBody] OrgAssuranceRaiseFindingRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.RaiseFindingAsync(id, emp, body, CallerActor(body.Actor), cancellationToken), "observationId");
    }

    [HttpPost("executions/{id:long}/audit-conclusion")]
    public async Task<IActionResult> SaveAuditConclusion(long id, [FromBody] OrgAssuranceAuditConclusionRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.SaveAuditConclusionAsync(id, emp, body, CallerActor(body.Actor), cancellationToken), "executionId");
    }

    [HttpPost("observations/{id:long}/finding")]
    public async Task<IActionResult> SaveObservationFinding(long id, [FromBody] OrgAssuranceObservationFindingRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Result(await service.SaveObservationFindingAsync(id, body, CallerActor(body.Actor), cancellationToken), "observationId");
    }
}
