// =====================================================================
// OrgAssuranceUniverseController (577, CR2 - AA Part A -- Audit Universe;
// 580, Part B -- Framework & Practice Mapping; 581, Part C -- Enterprise
// Risk Intelligence)
//
// Audit Assurance -> Audit Intelligence -> Audit Universe: a governed
// inventory of auditable subjects that references Organization Registry
// records (never copies them). Route: /api/practice/org-assurance. The
// caller is the session employee the Web tier stamps
// (X-PM-Caller-Employee-Id, 555).
//
// Endpoints (rows are the procedures' columns):
//   GET  /universe-masters?organizationId=&group=   { data: [{ MasterId, MasterGroup,
//        Code, Name, Description, ParentMasterId, ParentName, RankValue,
//        DisplayOrder, IsSystem, IsActive, UsageCount }] } (defaults made the
//        first time)
//   POST /universe-masters  { organizationId, universeMasterId?, masterGroup,
//        code, name, description, parentMasterId, rankValue, displayOrder,
//        isActive } -> { universeMasterId }
//   GET  /universe-discovery?organizationId=&kind=&show=&search=   registry records
//        { data: [{ SourceKind, KindLabel, RecordId, RecordCode, RecordName,
//        TypeLabel, RecordStatus, OwnerName, SubjectCount, SubjectRefs,
//        IsExcluded, ExclusionReason, ExcludedBy, ExcludedDt }] }
//        kind: LEGAL_ENTITY / UNIT / LOCATION / DEPARTMENT / FUNCTION / PROCESS;
//        show: NEW (default) / INCLUDED / EXCLUDED / ALL
//   POST /universe-discovery  { organizationId, action: INCLUDE / EXCLUDE /
//        RELEASE, records: [{ kind, id }], reason, categoryId } -> { appliedCount }
//   GET  /universe-lookups?organizationId=   { people, units, departments, subjects }
//   GET  /universe?organizationId=&categoryId=&status=&source=&criticalityId=
//        &ownerEmployeeId=&departmentId=&search=   the register { data: [{
//        UniverseSubjectId, UniverseRef, SubjectName, ParentSubjectId, ParentRef,
//        CategoryName, SubcategoryName, ClassificationName, RegSignificanceName,
//        CriticalityName, SubjectSource, OwnerName, DivisionName, DepartmentName,
//        StatusCode, StatusName, EffectiveFrom, LastReviewedOn, ApprovedBy,
//        VersionNo, SourceCount, RelationshipCount, ChildCount, IsApprover,
//        IsMySubmission }] }
//   GET  /universe/{id}?organizationId=   { subject, sources, relationships,
//        children, history }
//   POST /universe  { organizationId, universeSubjectId?, versionNo, subjectName,
//        description, categoryId, subcategoryId, classificationId,
//        regSignificanceId, criticalityId, parentSubjectId, subjectSource,
//        ownerEmployeeId, divisionId, departmentId, effectiveFrom, remarks,
//        sources: [{ kind, id, isPrimary }] | null } -> { universeSubjectId }
//   POST /universe/{id}/action  { organizationId, action: SUBMIT / APPROVE /
//        RETURN / REVIEW / DEACTIVATE / REACTIVATE / RETIRE / DISCARD, comment,
//        versionNo }
//   POST /universe-relationships  { organizationId, universeRelationshipId?,
//        fromSubjectId, toSubjectId, relationshipTypeId, remarks, isActive }
//        -> { universeRelationshipId }
//   GET  /universe-history?organizationId=&subjectId=&action=&from=&to=&search=
// 580 -- Framework & Practice Mapping (CR2 Part B):
//   GET  /universe/{id}/mappings?organizationId=&level=&status=&source=&search=
//        { data: [{ UniverseMappingId, MappingLevel, RecordKey, RecordCode,
//        RecordName, FrameworkName, ReleaseName, ControlName, ContextLabel,
//        IsAvailable, MappingSource (AUTO / MANUAL), MappingStatus (SUGGESTED /
//        CONFIRMED / REJECTED / INACTIVE), SuggestionBasis, ConfirmedBy,
//        ConfirmedDt, Remarks }], counts: [{ MappingLevel, MappingStatus,
//        MappingCount }] }
//   GET  /universe-mapping-options?organizationId=&level=   { data: [{ RecordKey,
//        RecordCode, RecordName, FrameworkName, ReleaseName, ContextLabel }] }
//        level: FRAMEWORK / RELEASE / CONTROL / REQUIREMENT / OBLIGATION /
//        PRACTICE / PRACTICE_INSTANCE / RISK (581) (requirements: the page uses
//        /scope-statement-tree, whose StatementId is the key)
//   POST /universe/{id}/mappings/suggest  { organizationId } -> { suggestedCount }
//   POST /universe/{id}/mappings  { organizationId, level, keys: ["..."], remarks }
//        -> { addedCount } (added Confirmed, source MANUAL)
//   POST /universe/{id}/mappings/action  { organizationId, action: CONFIRM /
//        REJECT / DEACTIVATE / REACTIVATE, mappingIds: [..], remarks }
//        -> { appliedCount }
// 581 -- Enterprise Risk Intelligence (CR2 Part C; read only, from Risk
// Management and GRAC's own records; level RISK added to the mappings):
//   GET  /universe/{id}/risk-intelligence?organizationId=   { risks: [{ RiskRegisterId,
//        RiskNumber, RiskTitle, RiskStatement, RiskCategoryName, RiskOwnerName,
//        StatusCode, InherentRatingName, InherentRatingScore, ResidualRatingName,
//        ResidualRatingScore, CurrentStage, AppetiteStatus (Above / Within /
//        NotSet / null), AppetiteMaxRatingCode, Trend (Up / Down / Same / New /
//        null), PreviousRatingCode, TreatmentOptionName, OpenTreatmentActions,
//        AcceptedDt, AcceptedByName, AcceptanceNote, LastReviewedDt,
//        NextReviewDate, ReviewOverdue, MappingStatus, MappingSource,
//        SuggestionBasis }], gaps: [{ CustomGapId, GapNumber, GapTitle,
//        SeverityName, Status, OwnerName, OpenedDt, TargetResolutionDate,
//        ClosedDt, IsOpen, InstanceCode, InstanceName, RiskNumber }],
//        exceptions: [{ ExceptionRequestId, RequestTitle, StatusCode, RequestedDt,
//        ApprovedDt, EffectiveUntil, GapNumber, Practices }], instances: [{
//        PracticeInstanceId, InstanceCode, InstanceName, PracticeCode,
//        PracticeName, PrimaryOwner, ImplementationStatus, MappingStatus,
//        OpenGaps, Obligations }], findings: [{ ObservationId, ObservationCode,
//        ObservationTitle, SeverityName, StatusCode, ExecutionCode,
//        ExecutionName, ObservedDt, ClosedDt, InstanceCode, InstanceName }],
//        summary: [{ ConfirmedRisks, SuggestedRisks, AboveAppetite,
//        AcceptedRisks, OpenGaps, PracticeInstances, Findings }] }
// Errors: { error, reasonCode } -- UNIVERSE_NOT_FOUND, UNIVERSE_STATE,
// UNIVERSE_HIA_ONLY, UNIVERSE_OWN_SUBMISSION, UNIVERSE_REASON_REQUIRED,
// UNIVERSE_FIELD_REQUIRED, UNIVERSE_INVALID_REFERENCE, UNIVERSE_DUPLICATE,
// UNIVERSE_CONCURRENCY, UNIVERSE_MASTER_LOCKED, UNIVERSE_EMPLOYEE_REQUIRED;
// 580: MAPPING_UNKNOWN, MAPPING_NOTHING_SELECTED, MAPPING_NOT_AVAILABLE,
// MAPPING_STATE.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-assurance")]
public sealed class OrgAssuranceUniverseController(
    IOrgAssuranceUniverseService service,
    ILogger<OrgAssuranceUniverseController> logger) : ControllerBase
{
    // 555: the signed-in employee, stamped by the Web tier (CallerIdentityHandler).
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";

    private long? CallerEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private string CallerActor(string? actor) =>
        !string.IsNullOrWhiteSpace(actor) ? actor : CallerEmployeeId is { } id ? $"employee:{id}" : "system";

    private IActionResult Result(OrgAssuranceUniverseResult result, string idName)
        => result.Success
            ? Ok(new Dictionary<string, object?> { [idName] = result.Id })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });

    private async Task<IActionResult> Read(Func<Task<object?>> read, string what)
    {
        try { return Ok(await read()); }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceUniverseController {What} failed", what);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    private static BadRequestObjectResult NoOrganization() => new(new { error = "organizationId is required." });

    // -----------------------------------------------------------------
    // Universe Configuration
    // -----------------------------------------------------------------
    [HttpGet("universe-masters")]
    public async Task<IActionResult> ListMasters([FromQuery] long? organizationId, [FromQuery] string? group, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return NoOrganization();
        return await Read(async () => (object?)new
        {
            data = await service.ListMastersAsync(organizationId.Value, group, CallerActor(null), cancellationToken)
        }, "ListMasters");
    }

    [HttpPost("universe-masters")]
    public async Task<IActionResult> SaveMaster([FromBody] OrgAssuranceUniverseMasterSaveRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        if (string.IsNullOrWhiteSpace(body.MasterGroup)) return BadRequest(new { error = "masterGroup is required." });
        return Result(await service.SaveMasterAsync(body, CallerEmployeeId, CallerActor(body.Actor), cancellationToken), "universeMasterId");
    }

    // -----------------------------------------------------------------
    // Discovery from the Organization Registry
    // -----------------------------------------------------------------
    [HttpGet("universe-discovery")]
    public async Task<IActionResult> Discover(
        [FromQuery] long? organizationId, [FromQuery] string? kind, [FromQuery] string? show, [FromQuery] string? search,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return NoOrganization();
        return await Read(async () => (object?)new
        {
            data = await service.DiscoverAsync(organizationId.Value, kind, show, search, cancellationToken)
        }, "Discover");
    }

    [HttpPost("universe-discovery")]
    public async Task<IActionResult> ApplyDiscovery([FromBody] OrgAssuranceUniverseDiscoverRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        if (string.IsNullOrWhiteSpace(body.Action)) return BadRequest(new { error = "action is required." });
        if (body.Records is null || body.Records.Count == 0) return BadRequest(new { error = "Select at least one record." });
        return Result(await service.ApplyDiscoveryAsync(body, CallerEmployeeId, CallerActor(body.Actor), cancellationToken), "appliedCount");
    }

    [HttpGet("universe-lookups")]
    public async Task<IActionResult> Lookups([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return NoOrganization();
        return await Read(async () => (object?)await service.GetLookupsAsync(organizationId.Value, cancellationToken), "Lookups");
    }

    // -----------------------------------------------------------------
    // Audit Universe Register
    // -----------------------------------------------------------------
    [HttpGet("universe")]
    public async Task<IActionResult> ListSubjects(
        [FromQuery] long? organizationId, [FromQuery] long? categoryId, [FromQuery] string? status, [FromQuery] string? source,
        [FromQuery] long? criticalityId, [FromQuery] long? ownerEmployeeId, [FromQuery] long? departmentId, [FromQuery] string? search,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return NoOrganization();
        return await Read(async () => (object?)new
        {
            data = await service.ListSubjectsAsync(organizationId.Value, categoryId, status, source, criticalityId,
                ownerEmployeeId, departmentId, search, CallerEmployeeId, CallerActor(null), cancellationToken)
        }, "ListSubjects");
    }

    [HttpGet("universe/{id:long}")]
    public async Task<IActionResult> GetSubject(long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return NoOrganization();
        try
        {
            var subject = await service.GetSubjectAsync(organizationId.Value, id, CallerEmployeeId, cancellationToken);
            return subject is null ? NotFound(new { error = "Subject not found." }) : Ok(subject);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 54090)
        {
            return NotFound(new { error = ex.Message, reasonCode = "UNIVERSE_NOT_FOUND" });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceUniverseController.GetSubject failed for {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("universe")]
    public async Task<IActionResult> SaveSubject([FromBody] OrgAssuranceUniverseSaveRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        if (string.IsNullOrWhiteSpace(body.SubjectName)) return BadRequest(new { error = "Subject Name is required.", reasonCode = "UNIVERSE_FIELD_REQUIRED" });
        return Result(await service.SaveSubjectAsync(body, CallerEmployeeId, CallerActor(body.Actor), cancellationToken), "universeSubjectId");
    }

    [HttpPost("universe/{id:long}/action")]
    public async Task<IActionResult> SubjectAction(long id, [FromBody] OrgAssuranceUniverseActionRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        if (string.IsNullOrWhiteSpace(body.Action)) return BadRequest(new { error = "action is required." });
        if (CallerEmployeeId is not { } emp)
            return BadRequest(new { error = "Sign in as a person of the organization.", reasonCode = "UNIVERSE_EMPLOYEE_REQUIRED" });
        return Result(await service.SubjectActionAsync(id, emp, body, CallerActor(body.Actor), cancellationToken), "universeSubjectId");
    }

    [HttpPost("universe-relationships")]
    public async Task<IActionResult> SaveRelationship([FromBody] OrgAssuranceUniverseRelationshipSaveRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        return Result(await service.SaveRelationshipAsync(body, CallerEmployeeId, CallerActor(body.Actor), cancellationToken), "universeRelationshipId");
    }

    // -----------------------------------------------------------------
    // 580: Framework & Practice Mapping
    // -----------------------------------------------------------------
    [HttpGet("universe/{id:long}/mappings")]
    public async Task<IActionResult> ListMappings(
        long id, [FromQuery] long? organizationId, [FromQuery] string? level, [FromQuery] string? status,
        [FromQuery] string? source, [FromQuery] string? search, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return NoOrganization();
        try
        {
            return Ok(await service.ListMappingsAsync(organizationId.Value, id, level, status, source, search, cancellationToken));
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 54120)
        {
            return NotFound(new { error = ex.Message, reasonCode = "UNIVERSE_NOT_FOUND" });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceUniverseController.ListMappings failed for {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("universe-mapping-options")]
    public async Task<IActionResult> MappingOptions([FromQuery] long? organizationId, [FromQuery] string? level, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return NoOrganization();
        if (string.IsNullOrWhiteSpace(level)) return BadRequest(new { error = "level is required." });
        return await Read(async () => (object?)new
        {
            data = await service.ListMappingOptionsAsync(organizationId.Value, level, cancellationToken)
        }, "MappingOptions");
    }

    [HttpPost("universe/{id:long}/mappings/suggest")]
    public async Task<IActionResult> SuggestMappings(long id, [FromBody] OrgAssuranceUniverseMappingSuggestRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        return Result(await service.SuggestMappingsAsync(id, body.OrganizationId, CallerEmployeeId, CallerActor(body.Actor), cancellationToken), "suggestedCount");
    }

    [HttpPost("universe/{id:long}/mappings")]
    public async Task<IActionResult> AddMappings(long id, [FromBody] OrgAssuranceUniverseMappingAddRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        if (string.IsNullOrWhiteSpace(body.Level)) return BadRequest(new { error = "level is required." });
        if (body.Keys is null || body.Keys.Count == 0)
            return BadRequest(new { error = "Select at least one record.", reasonCode = "MAPPING_NOTHING_SELECTED" });
        return Result(await service.AddMappingsAsync(id, body, CallerEmployeeId, CallerActor(body.Actor), cancellationToken), "addedCount");
    }

    [HttpPost("universe/{id:long}/mappings/action")]
    public async Task<IActionResult> MappingAction(long id, [FromBody] OrgAssuranceUniverseMappingActionRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        if (string.IsNullOrWhiteSpace(body.Action)) return BadRequest(new { error = "action is required." });
        if (body.MappingIds is null || body.MappingIds.Count == 0)
            return BadRequest(new { error = "Select at least one mapping.", reasonCode = "MAPPING_NOTHING_SELECTED" });
        return Result(await service.MappingActionAsync(id, body, CallerEmployeeId, CallerActor(body.Actor), cancellationToken), "appliedCount");
    }

    [HttpGet("universe/{id:long}/risk-intelligence")]
    public async Task<IActionResult> RiskIntelligence(long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return NoOrganization();
        try
        {
            return Ok(await service.GetRiskIntelligenceAsync(organizationId.Value, id, cancellationToken));
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 54120)
        {
            return NotFound(new { error = ex.Message, reasonCode = "UNIVERSE_NOT_FOUND" });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceUniverseController.RiskIntelligence failed for {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // -----------------------------------------------------------------
    // Universe History
    // -----------------------------------------------------------------
    [HttpGet("universe-history")]
    public async Task<IActionResult> History(
        [FromQuery] long? organizationId, [FromQuery] long? subjectId, [FromQuery] string? action,
        [FromQuery] DateTime? from, [FromQuery] DateTime? to, [FromQuery] string? search, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return NoOrganization();
        return await Read(async () => (object?)new
        {
            data = await service.ListHistoryAsync(organizationId.Value, subjectId, action, from, to, search, cancellationToken)
        }, "History");
    }
}
