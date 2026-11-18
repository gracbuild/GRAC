// =====================================================================
// OrgAssuranceRbiaController (582, CR2 - AA Part D -- RBIA)
//
// Risk-Based Internal Audit: the organization's versioned RBIA
// methodology and the assessments of Audit Universe subjects. Route:
// /api/practice/org-assurance (the Web's generic org-assurance proxy). The
// caller is the session employee the Web tier stamps
// (X-PM-Caller-Employee-Id, 555).
//
// Endpoints (rows are the procedures' columns):
//   GET  /rbia/methodologies?organizationId=   { data: [{ RbiaMethodologyId, VersionNo,
//        MethodologyName, Status (Draft / Published / Superseded), PresetCode,
//        EffectiveFrom, PublishedBy, PublishedDt, AssessmentCount }] }
//   GET  /rbia/methodology?organizationId=&id=   (no id: the draft, else the
//        published) { methodology, levels, parameters, questions, options, bands }
//   POST /rbia/methodology/draft  { organizationId, source: PUBLISHED / RBI / BLANK,
//        replace } -> { rbiaMethodologyId }
//   POST /rbia/methodology/{id}/save  { organizationId, content } (the draft)
//   POST /rbia/methodology/{id}/publish  { organizationId } (Head of Internal Audit)
//   POST /rbia/methodology/{id}/discard  { organizationId }
//   GET  /rbia/assessments?organizationId=&status=&period=&band=&currentOnly=&search=
//        { data: [{ RbiaAssessmentId, AssessmentRef, UniverseRef, SubjectName,
//        AssessmentPeriod, AssessmentType, Status, InherentScore, ControlScore,
//        ResidualScore, SystemBandName, FinalBandName, FinalPriority,
//        FrequencyMonths, NextAuditDue, IsOverridden, AssessorName, ApprovedDt,
//        IsCurrent, RowVersionNo, IsAssessor, CanReview, CanApprove, ... }] }
//   POST /rbia/assessments  { organizationId, subjectIds: [..], period, type:
//        INITIAL / ANNUAL / EVENT, triggerReason, assessorEmployeeId } -> { createdCount }
//   GET  /rbia/assessments/{id}?organizationId=   { assessment, parameters,
//        questions (with the answers), options, levels, bands, history }
//   POST /rbia/assessments/{id}/save  { organizationId, rowVersionNo, responses:
//        [{ questionId, levelValue, optionId, notApplicable, comment,
//        evidenceReference }], override: { bandId, justification, evidence } }
//   POST /rbia/assessments/{id}/action  { organizationId, action: SUBMIT / REVIEW /
//        APPROVE / RETURN / CANCEL / REASSESS, comment, rowVersionNo }
//        -> { newAssessmentId } (REASSESS); APPROVE freezes the subject's
//        enterprise risk intelligence (581) as the assessment's snapshot.
// Errors: { error, reasonCode } -- RBIA_* (OrgAssuranceRbiaService.MapReason),
// RBIA_EMPLOYEE_REQUIRED.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-assurance/rbia")]
public sealed class OrgAssuranceRbiaController(
    IOrgAssuranceRbiaService service,
    ILogger<OrgAssuranceRbiaController> logger) : ControllerBase
{
    // 555: the signed-in employee, stamped by the Web tier (CallerIdentityHandler).
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";

    private long? CallerEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private string CallerActor(string? actor) =>
        !string.IsNullOrWhiteSpace(actor) ? actor : CallerEmployeeId is { } id ? $"employee:{id}" : "system";

    private static BadRequestObjectResult NoOrganization() => new(new { error = "organizationId is required." });
    private static BadRequestObjectResult NoEmployee() =>
        new(new { error = "Sign in as a person of the organization.", reasonCode = "RBIA_EMPLOYEE_REQUIRED" });

    private IActionResult Result(OrgAssuranceRbiaResult result, string idName)
        => result.Success
            ? Ok(new Dictionary<string, object?> { [idName] = result.Id })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });

    private async Task<IActionResult> Read(Func<Task<object?>> read, string what)
    {
        try { return Ok(await read()); }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceRbiaController {What} failed", what);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // -----------------------------------------------------------------
    // Methodology
    // -----------------------------------------------------------------
    [HttpGet("methodologies")]
    public async Task<IActionResult> ListMethodologies([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return NoOrganization();
        return await Read(async () => (object?)new { data = await service.ListMethodologiesAsync(organizationId.Value, cancellationToken) }, "ListMethodologies");
    }

    [HttpGet("methodology")]
    public async Task<IActionResult> GetMethodology([FromQuery] long? organizationId, [FromQuery] long? id, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return NoOrganization();
        return await Read(async () => (object?)await service.GetMethodologyAsync(organizationId.Value, id, cancellationToken), "GetMethodology");
    }

    [HttpPost("methodology/draft")]
    public async Task<IActionResult> StartDraft([FromBody] OrgAssuranceRbiaDraftRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        return Result(await service.StartDraftAsync(body, CallerEmployeeId, CallerActor(body.Actor), cancellationToken), "rbiaMethodologyId");
    }

    [HttpPost("methodology/{id:long}/save")]
    public async Task<IActionResult> SaveMethodology(long id, [FromBody] OrgAssuranceRbiaMethodologySaveRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        if (body.Content.ValueKind != System.Text.Json.JsonValueKind.Object) return BadRequest(new { error = "content is required." });
        return Result(await service.SaveMethodologyAsync(id, body, CallerEmployeeId, CallerActor(body.Actor), cancellationToken), "rbiaMethodologyId");
    }

    [HttpPost("methodology/{id:long}/publish")]
    public async Task<IActionResult> PublishMethodology(long id, [FromBody] OrgAssuranceRbiaMethodologyActionRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.PublishMethodologyAsync(id, body.OrganizationId, emp, CallerActor(body.Actor), cancellationToken), "rbiaMethodologyId");
    }

    [HttpPost("methodology/{id:long}/discard")]
    public async Task<IActionResult> DiscardMethodology(long id, [FromBody] OrgAssuranceRbiaMethodologyActionRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        return Result(await service.DiscardMethodologyAsync(id, body.OrganizationId, CallerEmployeeId, CallerActor(body.Actor), cancellationToken), "rbiaMethodologyId");
    }

    // -----------------------------------------------------------------
    // Assessments
    // -----------------------------------------------------------------
    [HttpGet("assessments")]
    public async Task<IActionResult> ListAssessments(
        [FromQuery] long? organizationId, [FromQuery] string? status, [FromQuery] string? period, [FromQuery] string? band,
        [FromQuery] bool? currentOnly, [FromQuery] string? search, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return NoOrganization();
        return await Read(async () => (object?)new
        {
            data = await service.ListAssessmentsAsync(organizationId.Value, status, period, band, currentOnly ?? false, search, CallerEmployeeId, cancellationToken)
        }, "ListAssessments");
    }

    [HttpPost("assessments")]
    public async Task<IActionResult> CreateAssessments([FromBody] OrgAssuranceRbiaCreateRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        if (body.SubjectIds is null || body.SubjectIds.Count == 0)
            return BadRequest(new { error = "Select at least one subject.", reasonCode = "RBIA_NOTHING_SELECTED" });
        if (body.AssessorEmployeeId <= 0) return BadRequest(new { error = "Choose the assessor." });
        return Result(await service.CreateAssessmentsAsync(body, CallerEmployeeId, CallerActor(body.Actor), cancellationToken), "createdCount");
    }

    [HttpGet("assessments/{id:long}")]
    public async Task<IActionResult> GetAssessment(long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return NoOrganization();
        try
        {
            var a = await service.GetAssessmentAsync(organizationId.Value, id, CallerEmployeeId, cancellationToken);
            return a is null ? NotFound(new { error = "Assessment not found." }) : Ok(a);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 54130)
        {
            return NotFound(new { error = ex.Message, reasonCode = "RBIA_NOT_FOUND" });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceRbiaController.GetAssessment failed for {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("assessments/{id:long}/save")]
    public async Task<IActionResult> SaveAssessment(long id, [FromBody] OrgAssuranceRbiaSaveRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.SaveAssessmentAsync(id, body, emp, CallerActor(body.Actor), cancellationToken), "rbiaAssessmentId");
    }

    [HttpPost("assessments/{id:long}/action")]
    public async Task<IActionResult> AssessmentAction(long id, [FromBody] OrgAssuranceRbiaActionRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        if (string.IsNullOrWhiteSpace(body.Action)) return BadRequest(new { error = "action is required." });
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.AssessmentActionAsync(id, body, emp, CallerActor(body.Actor), cancellationToken), "newAssessmentId");
    }
}
