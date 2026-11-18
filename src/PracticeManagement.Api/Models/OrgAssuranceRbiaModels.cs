// =====================================================================
// OrgAssuranceRbiaModels (582, CR2 - AA Part D -- RBIA)
//
// Request bodies of OrgAssuranceRbiaController. Reads come back as the
// procedures' rows (OrgAssuranceRbiaService). Structured contents
// (the methodology draft, answers, override) are passed through as JSON
// to the procedures, which validate them.
// =====================================================================
using System.Text.Json;

namespace PracticeManagement.Api.Models;

/// <summary>Start a methodology draft: Source PUBLISHED (copy), RBI (preset)
/// or BLANK; Replace an existing draft.</summary>
public sealed record OrgAssuranceRbiaDraftRequest(
    long    OrganizationId,
    string  Source,
    bool    Replace = false,
    string? Actor   = null);

/// <summary>Save the draft: Content = { methodologyName, effectiveFrom,
/// inherentAggregation, residualMethod, maxReductionPct, requireReview,
/// notes, levels[], parameters[ { ..., questions[ { ..., options[] } ] } ],
/// bands[] } (sp_org_assurance_rbia_methodology_save).</summary>
public sealed record OrgAssuranceRbiaMethodologySaveRequest(
    long        OrganizationId,
    JsonElement Content,
    string?     Actor = null);

/// <summary>Publish / discard the draft.</summary>
public sealed record OrgAssuranceRbiaMethodologyActionRequest(
    long    OrganizationId,
    string? Actor = null);

/// <summary>Create assessments for one or many Active subjects. Type:
/// INITIAL / ANNUAL / EVENT (TriggerReason required).</summary>
public sealed record OrgAssuranceRbiaCreateRequest(
    long    OrganizationId,
    IReadOnlyList<long>? SubjectIds,
    string  Period,
    string  Type,
    string? TriggerReason,
    long    AssessorEmployeeId,
    string? Actor = null);

/// <summary>Save answers and the proposed override: Responses = [{ questionId,
/// levelValue, optionId, notApplicable, comment, evidenceReference }];
/// Override = { bandId (null = no override), justification, evidence } or
/// absent (unchanged).</summary>
public sealed record OrgAssuranceRbiaSaveRequest(
    long         OrganizationId,
    int          RowVersionNo,
    JsonElement? Responses,
    JsonElement? Override,
    string?      Actor = null);

/// <summary>SUBMIT / REVIEW / APPROVE / RETURN / CANCEL / REASSESS; Comment is
/// required to RETURN, CANCEL and REASSESS.</summary>
public sealed record OrgAssuranceRbiaActionRequest(
    long    OrganizationId,
    string  Action,
    string? Comment      = null,
    int?    RowVersionNo = null,
    string? Actor        = null);

public sealed record OrgAssuranceRbiaResult(
    bool    Success,
    long?   Id         = null,
    string? Error      = null,
    string? ReasonCode = null);
