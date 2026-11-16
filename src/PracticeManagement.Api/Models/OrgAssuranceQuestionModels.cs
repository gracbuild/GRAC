// =====================================================================
// OrgAssuranceQuestionModels
//
// Phase 2 Assurance Management -- Stage 2 Question Builder (BRD Part 2
// Sec 4). Kept in its own file to mirror TaskModels / WorkflowModels /
// CustomGapModels conventions.
// =====================================================================
namespace PracticeManagement.Api.Models;

// ---------- Admin-published question type ----------
public sealed record OrgAssuranceAdminQuestionTypeRow(
    long?   Id,
    string? Code,
    string? Name,
    string? Description);

// ---------- Question Set ----------
public sealed record OrgAssuranceQuestionSetListQuery(
    long    OrganizationId,
    string? Search   = null,
    int     Page     = 1,
    int     PageSize = 25);

public sealed record OrgAssuranceQuestionSetListRow(
    long      QuestionSetId,
    long      OrganizationId,
    string    SetCode,
    string    SetName,
    string?   Description,
    long?     OwnerEmployeeId,
    string?   OwnerDisplayName,
    string    Status,
    long      QuestionCount,
    DateTime? EnteredDt,
    DateTime? UpdatedDt,
    // 535 -- mandatory questions and SUM(weight) over the same questions
    // QuestionCount counts. Null when the database predates 535.
    long?     MandatoryCount = null,
    decimal?  TotalWeight    = null,
    // 551 -- the row is the set's latest version. Null before 551 is run.
    long?     RootQuestionSetId   = null,
    int?      VersionNumber       = null,
    string?   VersionStatus       = null,
    int?      ActiveVersionNumber = null);

public sealed record OrgAssuranceQuestionSetListResult(
    long TotalCount,
    int  PageNumber,
    int  PageSize,
    IReadOnlyList<OrgAssuranceQuestionSetListRow> Rows);

public sealed record OrgAssuranceQuestionSetDetail(
    long      QuestionSetId,
    long      OrganizationId,
    string    SetCode,
    string    SetName,
    string?   Description,
    long?     OwnerEmployeeId,
    string?   OwnerDisplayName,
    string    Status,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt,
    // 551 -- this version, and the set's Active / open (Draft or Under
    // Review) versions. Null before 551 is run.
    long?     RootQuestionSetId     = null,
    int?      VersionNumber         = null,
    string?   VersionStatus         = null,
    long?     PreviousQuestionSetId = null,
    string?   ChangeNote            = null,
    string?   SubmittedBy           = null,
    DateTime? SubmittedDt           = null,
    string?   ApprovedBy            = null,
    DateTime? ApprovedDt            = null,
    long?     ActiveQuestionSetId   = null,
    int?      ActiveVersionNumber   = null,
    long?     OpenQuestionSetId     = null,
    int?      OpenVersionNumber     = null,
    string?   OpenVersionStatus     = null);

// ---------- Question Set versions (551) ----------
public sealed record OrgAssuranceQuestionSetVersionRow(
    long      QuestionSetId,
    int       VersionNumber,
    string    VersionStatus,
    string?   SetName,
    string?   ChangeNote,
    long      QuestionCount,
    string?   SubmittedBy,
    DateTime? SubmittedDt,
    string?   ApprovedBy,
    DateTime? ApprovedDt,
    string?   EnteredBy,
    DateTime? EnteredDt);

// An audit definition affected by approving a question set version:
// ActionCode UPDATE_IN_PLACE (its Draft / Under Review version moves to
// the new set version) or NEW_VERSION (a new Draft version is created).
public sealed record OrgAssuranceQuestionSetImpactRow(
    long    DefinitionId,
    string  DefinitionCode,
    string  DefinitionName,
    int?    CurrentVersionNumber,
    string? CurrentStatusCode,
    string? CurrentStatusName,
    int?    LinkedSetVersion,
    string  ActionCode,
    string? ActionText,
    int?    NewVersionNumber = null);

// Recommend (Note = change note) / Return (Note = reason) / Approve / New Version.
public sealed record OrgAssuranceQuestionSetActionRequest(
    long    OrganizationId,
    string? Note,
    string? Actor);

public sealed record OrgAssuranceQuestionSetApproveResult(
    bool                                            Success,
    IReadOnlyList<OrgAssuranceQuestionSetImpactRow> Definitions,
    string?                                         Error      = null,
    string?                                         ReasonCode = null);

public sealed record OrgAssuranceQuestionSetSaveRequest(
    long    OrganizationId,
    long?   QuestionSetId,
    string  SetCode,
    string  SetName,
    string? Description,
    long?   OwnerEmployeeId,
    string? OwnerDisplayName,
    string? Status,
    string? Actor);

public sealed record OrgAssuranceQuestionSetSaveResult(
    bool    Success,
    long?   QuestionSetId = null,
    string? Error         = null,
    string? ReasonCode    = null);

// ---------- Question ----------
public sealed record OrgAssuranceQuestionRow(
    long      QuestionId,
    long      QuestionSetId,
    string    QuestionCode,
    string    QuestionText,
    string?   HelpText,
    long?     QuestionTypeId,
    string?   QuestionTypeCode,
    string?   QuestionTypeName,
    bool      IsMandatory,
    int       DisplayOrder,
    decimal?  Weight,
    string?   ExpectedResponse,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt,
    // 520
    bool      EvidenceRequired = false,    // derived: an Evidence Type is set
    string?   ExpectedEvidence = null,
    string    Status           = "Active",
    int       VersionNumber    = 1,
    int?      EvidenceTypeId   = null,     // null = Not Applicable
    string?   EvidenceTypeCode = null,
    string?   EvidenceTypeName = null);

public sealed record OrgAssuranceQuestionSaveRequest(
    long     OrganizationId,
    long     QuestionSetId,
    long?    QuestionId,
    string   QuestionCode,
    string   QuestionText,
    string?  HelpText,
    long?    QuestionTypeId,
    string?  QuestionTypeCode,
    string?  QuestionTypeName,
    bool?    IsMandatory,
    int?     DisplayOrder,
    decimal? Weight,
    string?  ExpectedResponse,
    string?  Actor,
    // 520: Evidence Type (null = Not Applicable; a type means evidence is required)
    int?     EvidenceTypeId   = null,
    string?  ExpectedEvidence = null,
    string?  Status           = null);

// 520: the set page's questions grid, saved in one call. A row with a
// QuestionId updates it; a row without one is added; a saved question
// left out of the list is removed from the set.
public sealed record OrgAssuranceQuestionGridRow(
    long?    QuestionId,
    string?  QuestionCode,
    string?  QuestionText,
    string?  HelpText,
    long?    QuestionTypeId,
    string?  QuestionTypeCode,
    string?  QuestionTypeName,
    bool?    IsMandatory,
    int?     EvidenceTypeId,      // null = Not Applicable
    string?  ExpectedEvidence,
    decimal? Weight,
    string?  Status,
    int?     DisplayOrder);

public sealed record OrgAssuranceQuestionGridSaveRequest(
    long                                       OrganizationId,
    IReadOnlyList<OrgAssuranceQuestionGridRow>? Questions,
    string?                                    Actor);

public sealed record OrgAssuranceQuestionSaveResult(
    bool    Success,
    long?   QuestionId = null,
    string? Error      = null,
    string? ReasonCode = null);

public sealed record OrgAssuranceCommandResult(
    bool    Success,
    long?   Id         = null,
    string? Error      = null,
    string? ReasonCode = null);
