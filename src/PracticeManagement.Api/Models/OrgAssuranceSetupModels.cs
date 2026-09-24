// =====================================================================
// OrgAssuranceSetupModels
//
// Phase 2 Audit Management -- contracts for the audit -> question-set
// adoption (migration 277) and the setup-status roll-up that drives the
// Completed / In Progress / Not Configured chips on the flow tabs
// (migration 278).
//
// Header mirrors the evidence-config header so the Web tier can reuse
// its existing isEditable handling verbatim.
// =====================================================================
namespace PracticeManagement.Api.Models;

/// <summary>Which version the read applies to, and whether it is editable.</summary>
public sealed record OrgAssuranceSetupHeader(
    long     DefinitionId,
    long?    VersionId,
    long?    CurrentVersionId,
    string?  CurrentStatusCode,
    bool     IsEditable);

/// <summary>A question set this audit version has adopted.</summary>
public sealed record OrgAssuranceDefinitionQuestionSetRow(
    long?   DefinitionQuestionSetId,
    long?   QuestionSetId,
    string? SetCode,
    string? SetName,
    int?    DisplayOrder,
    bool    IsMandatory,
    int?    QuestionCount);

/// <summary>A question set in the organization that could be adopted.</summary>
public sealed record OrgAssuranceAvailableQuestionSetRow(
    long?   QuestionSetId,
    string? SetCode,
    string? SetName,
    int?    QuestionCount);

/// <summary>Everything the Question Sets step needs in one round trip.</summary>
public sealed record OrgAssuranceDefinitionQuestionSetResult(
    OrgAssuranceSetupHeader                             Header,
    IReadOnlyList<OrgAssuranceDefinitionQuestionSetRow> Adopted,
    IReadOnlyList<OrgAssuranceAvailableQuestionSetRow>  Available);

/// <summary>Full-replacement adoption payload for the current version.</summary>
public sealed record OrgAssuranceDefinitionQuestionSetSaveRequest(
    long   OrganizationId,
    long   DefinitionId,
    IReadOnlyList<OrgAssuranceQuestionSetAdoption> Items,
    string? Actor);

public sealed record OrgAssuranceQuestionSetAdoption(
    long  QuestionSetId,
    int?  DisplayOrder,
    bool? IsMandatory);

public sealed record OrgAssuranceDefinitionQuestionSetSaveResult(
    bool  Success,
    long? DefinitionId,
    long? VersionId,
    int?  AdoptedCount);

/// <summary>
/// One setup step's state. <paramref name="StepKey"/> matches the
/// AuditFlowStep keys in the Web tier, so a row maps straight onto a tab.
/// Status is one of Completed / InProgress / NotConfigured.
/// </summary>
public sealed record OrgAssuranceSetupStatusRow(
    string  StepKey,
    string? StepName,
    int?    ItemCount,
    string? Status);

public sealed record OrgAssuranceSetupStatusResult(
    OrgAssuranceSetupHeader                   Header,
    IReadOnlyList<OrgAssuranceSetupStatusRow>  Steps);
