// =====================================================================
// OrgAssuranceReportController (568, Audit Change spec 4.9 -- reports)
//
// Audit reports: one per engagement, built from a section template,
// prepared by the lead, reviewed / approved by the engagement Reviewer
// (else the lead), issued by the lead (the data frozen as that version).
// Route: /api/practice/org-assurance. The caller is the session employee
// the Web tier stamps (X-PM-Caller-Employee-Id, 555).
//
// Endpoints (rows are the procedures' columns):
//   GET  /report-sections                      { data: [{ SectionCode, DefaultHeading, Description, DisplayOrder }] }
//   GET  /report-templates?organizationId=     { data: [{ ReportTemplateId, TemplateCode, TemplateName,
//        Description, IsDefault, IsActive, IncludedSectionCount, ReportCount }] }
//        (the "Standard Audit Report" template is made the first time)
//   GET  /report-templates/{id}?organizationId=   { data: [{ SectionCode, Heading,
//        DisplayOrder, IsIncluded, StandardText, Description }] }
//   POST /report-templates   { organizationId, reportTemplateId?, templateName,
//        description, isDefault, isActive, sections: [{ sectionCode, heading,
//        displayOrder, isIncluded, standardText }] } -> { reportTemplateId }
//   GET  /reports?organizationId=&status=&search=   the engagements with an
//        execution and their report -> { data: [{ EngagementId, EngagementCode,
//        EngagementName, PlanCode, LeadAuditorName, ReviewerName, IsLead,
//        IsReviewer, ExecutionTotal, ExecutionApproved, FindingCount, ReportId,
//        ReportCode, ReportStatus, VersionNo, IssuedDt }] }  status: NONE /
//        Draft / InReview / Returned / Approved / Issued
//   POST /reports            { organizationId, engagementId, reportTemplateId? } -> { reportId } (lead)
//   GET  /reports/{id}?organizationId=&versionNo=   { report: { ..., ReportStatus,
//        IsFrozen, IsLead, IsReviewer, DataJson }, sections: [...], history:
//        [...], versions: [...] } -- DataJson is the report data (engagement,
//        team, executions, methods, findings), frozen once issued
//   POST /reports/{id}/sections   { organizationId, sections: [{ sectionCode,
//        isIncluded, narrative }] } (lead; Draft / Returned)
//   POST /reports/{id}/action     { organizationId, action: SUBMIT / RETURN /
//        APPROVE / ISSUE / REVISE, comment }
// Errors: { error, reasonCode } -- REPORT_LEAD_ONLY, REPORT_REVIEWER_ONLY,
// REPORT_STATE, REPORT_NO_EXECUTION, REPORT_EXISTS, REPORT_NOT_FOUND,
// REPORT_NARRATIVE_REQUIRED, REPORT_EXECUTIONS_NOT_APPROVED,
// REPORT_REASON_REQUIRED, REPORT_TEMPLATE_INVALID, REPORT_EMPLOYEE_REQUIRED.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-assurance")]
public sealed class OrgAssuranceReportController(
    IOrgAssuranceReportService service,
    ILogger<OrgAssuranceReportController> logger) : ControllerBase
{
    // 555: the signed-in employee, stamped by the Web tier (CallerIdentityHandler).
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";

    private long? CallerEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private string CallerActor(string? actor) =>
        !string.IsNullOrWhiteSpace(actor) ? actor : CallerEmployeeId is { } id ? $"employee:{id}" : "system";

    private static BadRequestObjectResult NoEmployee() =>
        new(new { error = "Sign in as the engagement's auditor.", reasonCode = "REPORT_EMPLOYEE_REQUIRED" });

    private IActionResult Result(OrgAssuranceReportResult result, string idName)
        => result.Success
            ? Ok(new Dictionary<string, object?> { [idName] = result.Id })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });

    private async Task<IActionResult> Read(Func<Task<object?>> read, string what)
    {
        try { return Ok(await read()); }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceReportController {What} failed", what);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("report-sections")]
    public Task<IActionResult> ListSections(CancellationToken cancellationToken)
        => Read(async () => (object?)new { data = await service.ListSectionsAsync(cancellationToken) }, "ListSections");

    [HttpGet("report-templates")]
    public async Task<IActionResult> ListTemplates([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        return await Read(async () => (object?)new
        {
            data = await service.ListTemplatesAsync(organizationId.Value, CallerActor(null), cancellationToken)
        }, "ListTemplates");
    }

    [HttpGet("report-templates/{id:long}")]
    public async Task<IActionResult> GetTemplate(long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        return await Read(async () => (object?)new
        {
            data = await service.GetTemplateAsync(organizationId.Value, id, cancellationToken)
        }, "GetTemplate");
    }

    [HttpPost("report-templates")]
    public async Task<IActionResult> SaveTemplate([FromBody] OrgAssuranceReportTemplateSaveRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(body.TemplateName)) return BadRequest(new { error = "templateName is required." });
        return Result(await service.SaveTemplateAsync(body, CallerActor(body.Actor), cancellationToken), "reportTemplateId");
    }

    [HttpGet("reports")]
    public async Task<IActionResult> ListReports(
        [FromQuery] long? organizationId, [FromQuery] string? status, [FromQuery] string? search,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        return await Read(async () => (object?)new
        {
            data = await service.ListReportsAsync(organizationId.Value, CallerEmployeeId, status, search, cancellationToken)
        }, "ListReports");
    }

    [HttpPost("reports")]
    public async Task<IActionResult> CreateReport([FromBody] OrgAssuranceReportCreateRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.CreateReportAsync(emp, body, CallerActor(body.Actor), cancellationToken), "reportId");
    }

    [HttpGet("reports/{id:long}")]
    public async Task<IActionResult> GetReport(
        long id, [FromQuery] long? organizationId, [FromQuery] int? versionNo, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var report = await service.GetReportAsync(organizationId.Value, id, CallerEmployeeId, versionNo, cancellationToken);
            return report is null ? NotFound(new { error = "Report not found." }) : Ok(report);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 54075)
        {
            return NotFound(new { error = ex.Message, reasonCode = "REPORT_NOT_FOUND" });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceReportController.GetReport failed for {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("reports/{id:long}/sections")]
    public async Task<IActionResult> SaveSections(long id, [FromBody] OrgAssuranceReportSectionsSaveRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.SaveSectionsAsync(id, emp, body, CallerActor(body.Actor), cancellationToken), "reportId");
    }

    [HttpPost("reports/{id:long}/action")]
    public async Task<IActionResult> ReportAction(long id, [FromBody] OrgAssuranceReportActionRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(body.Action)) return BadRequest(new { error = "action is required." });
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.ReportActionAsync(id, emp, body, CallerActor(body.Actor), cancellationToken), "reportId");
    }
}
