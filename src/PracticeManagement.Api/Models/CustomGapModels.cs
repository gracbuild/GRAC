// =====================================================================
// CustomGapModels
//
// Request / response contracts for CustomGapController.
// Kept in its own file per project convention (do not extend
// PracticeRepositoryModels or TaskModels).
// =====================================================================
namespace PracticeManagement.Api.Models;

public sealed record CustomGapOpenRequest(
    long   OrganizationId,
    string Title,
    string? Description,
    string? Priority,
    long?   OwnerEmployeeId,
    DateTime? DueDate,
    string? Status,
    string? Remarks,
    string? GapTypeCode,
    long?   ActorEmployeeId);

public sealed record CustomGapCloseRequest(
    long   CustomGapId,
    long?  ActorEmployeeId,
    string? Remarks);

public sealed record CustomGapListQuery(
    long?  OrganizationId,
    string? StatusCode,
    string? Priority,
    long?  OwnerEmployeeId,
    string? Search,
    int Page = 1,
    int PageSize = 25);

public sealed record CustomGapListRow(
    long   CustomGapId,
    long   OrganizationId,
    string GapTypeCode,
    string Title,
    string? Description,
    string Priority,
    long?  OwnerEmployeeId,
    DateTime? DueDate,
    string Status,
    string? Remarks,
    long?  LinkedTaskId,
    DateTime EnteredDt,
    string EnteredBy);

public sealed record CustomGapListResult(
    long TotalCount,
    int PageNumber,
    int PageSize,
    IReadOnlyList<CustomGapListRow> Rows);

public sealed record CustomGapCommandResult(
    bool Success,
    long? CustomGapId,
    string? Error = null);
