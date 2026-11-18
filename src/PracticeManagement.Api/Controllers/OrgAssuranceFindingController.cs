// =====================================================================
// OrgAssuranceFindingController (584, CR2 - AA Part F / G 9.2 -- audit
// findings to Gap and Risk candidates)
//
// Route: /api/practice/org-assurance (the Web's generic org-assurance
// proxy). The caller is the session employee the Web tier stamps
// (X-PM-Caller-Employee-Id, 555).
//
// Endpoints:
//   POST /audit-findings/{observationId}/risk-candidate  { organizationId }
//        -> { riskCandidateId, candidateNumber, statusCode, created }
//        (Accepted, non-Informational findings; an open candidate of the
//        same finding is returned, not duplicated)
//   GET  /audit-findings/gap-source?organizationId=&gapId=   { data: [{
//        ObservationId, ObservationCode, ObservationTitle, SeverityName,
//        ObservationStatus, EngagementCode, EngagementName, ExecutionCode,
//        ExecutionName, UniverseSubjects, EntityDimensionName, EntityCode,
//        EntityName, AuditCriteria, ConditionText, RootCause, RiskImpact,
//        Recommendation, ManagementResponse, SupportingEvidence, ObservedDt }] }
// A Gap Candidate is raised by POST /api/practice/gaps/custom/generate
// (CustomGapController, unchanged).
// Errors: { error, reasonCode } -- FINDING_NOT_FOUND, FINDING_NOT_ACCEPTED,
// FINDING_INFORMATIONAL, RISK_CANDIDATE_REJECTED.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-assurance")]
public sealed class OrgAssuranceFindingController(
    IOrgAssuranceFindingService service,
    ILogger<OrgAssuranceFindingController> logger) : ControllerBase
{
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";

    private long? CallerEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private string CallerActor(string? actor) =>
        !string.IsNullOrWhiteSpace(actor) ? actor : CallerEmployeeId is { } id ? $"employee:{id}" : "system";

    [HttpPost("audit-findings/{observationId:long}/risk-candidate")]
    public async Task<IActionResult> RaiseRiskCandidate(long observationId, [FromBody] OrgAssuranceFindingRiskRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var r = await service.RaiseRiskCandidateAsync(observationId, body, CallerEmployeeId, CallerActor(body.Actor), cancellationToken);
        return r.Success
            ? Ok(new { riskCandidateId = r.RiskCandidateId, candidateNumber = r.CandidateNumber, statusCode = r.StatusCode, created = r.Created })
            : BadRequest(new { error = r.Error, reasonCode = r.ReasonCode });
    }

    [HttpGet("audit-findings/gap-source")]
    public async Task<IActionResult> GapSource([FromQuery] long? organizationId, [FromQuery] long? gapId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        if (gapId is null or <= 0) return BadRequest(new { error = "gapId is required." });
        try { return Ok(new { data = await service.GapAuditSourceAsync(organizationId.Value, gapId.Value, cancellationToken) }); }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceFindingController.GapSource failed for {GapId}", gapId);
            return StatusCode(500, new { error = ex.Message });
        }
    }
}
