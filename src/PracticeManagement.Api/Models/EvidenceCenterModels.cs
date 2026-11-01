// =====================================================================
// Evidence Center models (migration 476, Phase 1)
//
// List / detail rows are returned as column-name dictionaries, the
// RepositoryChange shape: the procedures own the projection, and a
// column a later migration adds reaches the screen without a model edit.
// Requests and command results are typed.
// =====================================================================
namespace PracticeManagement.Api.Models;

/// <summary>Grid filters for sp_evidence_center_list.</summary>
public sealed record EvidenceCenterListQuery(
    long    OrganizationId,
    string? Search,
    int?    EvidenceTypeId,
    long?   OwnerEmployeeId,
    string? Validity,          // Valid / Expiring / Expired / null = all
    string? Usage,             // Used / Unused / null = all
    string? Status,            // Active (default) / Retired / All
    int     PageNumber,
    int     PageSize,
    long?   CallerEmployeeId,
    bool    CallerIsAdmin);

public sealed record EvidenceCenterListResult(
    bool Success,
    IReadOnlyList<Dictionary<string, object?>> Rows,
    int TotalRows,
    string? Error = null);

/// <summary>Item, its versions and where it is used (sp_evidence_center_get).</summary>
public sealed record EvidenceCenterDetail(
    Dictionary<string, object?> Item,
    IReadOnlyList<Dictionary<string, object?>> Versions,
    IReadOnlyList<Dictionary<string, object?>> UsedIn);

public sealed record EvidenceCenterLookups(
    IReadOnlyList<Dictionary<string, object?>> EvidenceTypes,
    IReadOnlyList<Dictionary<string, object?>> Employees);

/// <summary>One stored version, for download.</summary>
public sealed record EvidenceCenterFileContent(
    long    EvidenceFileId,
    long    EvidenceItemId,
    int     VersionNo,
    string  FileName,
    string? ContentType,
    byte[]  FileData);

/// <summary>
/// Upload new (EvidenceItemId null) or New version. Metadata applies to a
/// new item only. AllowDuplicate: store even when an identical file is
/// already in the Evidence Center (the caller chose "Upload anyway").
/// </summary>
/// <summary>
/// Migration 499: the Evidence Center fields captured by the shared
/// upload dialog when a file is attached from Operationalize or from
/// Complete Task, rather than from the Evidence Center screen itself.
///
/// One record instead of eight more positional parameters on two already
/// long service signatures. Every field is optional: null means "no
/// opinion" and the procedure applies the value the item got before 499
/// (the evidence row's type, the uploader as owner, Internal).
///
/// Not applied when the upload links an identical file that is already
/// in the Evidence Center -- that item belongs to whoever described it.
/// </summary>
public sealed record EvidenceUploadMetadata(
    string?   EvidenceTitle = null,
    int?      EvidenceTypeId = null,
    string?   EvidenceDescription = null,
    long?     OwnerEmployeeId = null,
    DateTime? ValidFrom = null,
    DateTime? ValidTo = null,
    string?   Classification = null,
    string?   Tags = null)
{
    /// <summary>True when the caller actually filled something in.</summary>
    public bool HasAny =>
        !string.IsNullOrWhiteSpace(EvidenceTitle)
        || EvidenceTypeId is > 0
        || !string.IsNullOrWhiteSpace(EvidenceDescription)
        || OwnerEmployeeId is > 0
        || ValidFrom is not null
        || ValidTo is not null
        || !string.IsNullOrWhiteSpace(Classification)
        || !string.IsNullOrWhiteSpace(Tags);
}

public sealed record EvidenceCenterUploadRequest(
    long      OrganizationId,
    long?     EvidenceItemId,
    string    FileName,
    string?   ContentType,
    byte[]    FileData,
    string?   VersionNote,
    string?   EvidenceTitle,
    int?      EvidenceTypeId,
    string?   EvidenceDescription,
    long?     OwnerEmployeeId,
    DateTime? ValidFrom,
    DateTime? ValidTo,
    string?   Classification,
    string?   Tags,
    bool      AllowDuplicate,
    long?     CallerEmployeeId,
    bool      CallerIsAdmin,
    string    Actor);

/// <summary>
/// Duplicate = true: nothing was stored; DuplicateItemId is the item the
/// caller can already see whose current version is the identical file.
/// </summary>
public sealed record EvidenceCenterUploadResult(
    bool    Success,
    bool    Duplicate,
    long?   EvidenceItemId,
    long?   EvidenceFileId,
    int?    VersionNo,
    long?   DuplicateItemId,
    string? DuplicateTitle,
    int?    DuplicateVersionNo,
    string? Error = null);

public sealed record EvidenceCenterSaveRequest(
    long      OrganizationId,
    string?   EvidenceTitle,
    int?      EvidenceTypeId,
    string?   EvidenceDescription,
    long?     OwnerEmployeeId,
    DateTime? ValidFrom,
    DateTime? ValidTo,
    string?   Classification,
    string?   Tags);

/// <summary>Action: Retire / Restore / Delete.</summary>
public sealed record EvidenceCenterStatusRequest(
    long    OrganizationId,
    string? Action);

public sealed record EvidenceCenterCommandResult(
    bool Success, string? Message = null, string? Error = null);

// ---------- 477: expiry notifications ----------
/// <summary>One sweep (sp_evidence_expiry_sweep).</summary>
public sealed record EvidenceExpirySweepResult(int ExpiringRaised, int ExpiredRaised);

/// <summary>The caller's expiry notices (sp_evidence_expiry_notice_list).</summary>
public sealed record EvidenceNoticeListResult(
    bool Success,
    IReadOnlyList<Dictionary<string, object?>> Rows,
    int TotalRows,
    int UnreadCount,
    string? Error = null);

/// <summary>Mark one notice (EvidenceNoticeId) or all of the caller's read.</summary>
public sealed record EvidenceNoticeMarkRequest(
    long? OrganizationId,
    long? EvidenceNoticeId);
