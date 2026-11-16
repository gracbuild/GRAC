// =====================================================================
// OrgAssuranceReportModels (568, Audit Change spec 4.9 -- reports)
//
// Request bodies of OrgAssuranceReportController. Reads come back as the
// procedures' rows (OrgAssuranceReportService).
// =====================================================================
namespace PracticeManagement.Api.Models;

public sealed record OrgAssuranceReportTemplateSectionInput(
    string  SectionCode,
    string? Heading,
    int     DisplayOrder,
    bool    IsIncluded,
    string? StandardText);

public sealed record OrgAssuranceReportTemplateSaveRequest(
    long    OrganizationId,
    long?   ReportTemplateId,
    string  TemplateName,
    string? Description,
    bool    IsDefault,
    bool    IsActive,
    IReadOnlyList<OrgAssuranceReportTemplateSectionInput>? Sections,
    string? Actor = null);

public sealed record OrgAssuranceReportCreateRequest(
    long    OrganizationId,
    long    EngagementId,
    long?   ReportTemplateId = null,
    string? Actor            = null);

public sealed record OrgAssuranceReportSectionInput(
    string  SectionCode,
    bool?   IsIncluded,
    string? Narrative);

public sealed record OrgAssuranceReportSectionsSaveRequest(
    long    OrganizationId,
    IReadOnlyList<OrgAssuranceReportSectionInput>? Sections,
    string? Actor = null);

/// <summary>SUBMIT / RETURN / APPROVE / ISSUE / REVISE; Comment is required
/// to RETURN or REVISE.</summary>
public sealed record OrgAssuranceReportActionRequest(
    long    OrganizationId,
    string  Action,
    string? Comment = null,
    string? Actor   = null);

public sealed record OrgAssuranceReportResult(
    bool    Success,
    long?   Id         = null,
    string? Error      = null,
    string? ReasonCode = null);
