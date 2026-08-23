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
    DateTime? UpdatedDt);

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
    DateTime? UpdatedDt);

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
    DateTime? UpdatedDt);

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
    string?  Actor);

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
