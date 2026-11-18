// =====================================================================
// OrgAssuranceFindingModels (584, CR2 - AA Part F / G 9.2 -- audit
// findings to Gap and Risk candidates)
// =====================================================================
namespace PracticeManagement.Api.Models;

/// <summary>Raise a Risk Candidate from an Accepted, non-Informational audit
/// finding (sp_org_assurance_finding_raise_risk).</summary>
public sealed record OrgAssuranceFindingRiskRequest(
    long    OrganizationId,
    string? Actor = null);

public sealed record OrgAssuranceFindingRiskResult(
    bool    Success,
    long?   RiskCandidateId = null,
    string? CandidateNumber = null,
    string? StatusCode      = null,
    bool    Created         = false,
    string? Error           = null,
    string? ReasonCode      = null);
