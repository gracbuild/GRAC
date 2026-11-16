// =====================================================================
// Evidence Automation models (migration 530 -- plan Part A, Phase 1)
//
// Same shape as the Evidence Center models: list / detail rows are
// column-name dictionaries (the procedures own the projection); requests
// and command results are typed.
// =====================================================================
namespace PracticeManagement.Api.Models;

/// <summary>Create (BindingId null) or edit an automated evidence source.</summary>
public sealed record EvidenceAutomationBindingSaveRequest(
    long    OrganizationId,
    string? BindingName,
    long    PracticeInstanceObligationId,
    long?   InstanceEvidenceId,
    string? Channel,              // Webhook / FileDrop
    string? SourceSystem,
    string? ExternalControlRef,
    string? Independence,         // SelfAttested / Independent
    string? ExpectedCadence,      // None / Daily / Weekly / Monthly / Quarterly / HalfYearly / Yearly
    int?    GraceDays,
    int?    ValidityDays,
    int?    EvidenceTypeId,
    long?   OwnerEmployeeId,
    string? Classification,
    string? DropFolder,
    string? AllowedSenders = null);   // 531: Email -- addresses or @domains, comma separated

public sealed record EvidenceAutomationStatusRequest(long OrganizationId, string? Action);   // Pause / Resume / Retire

public sealed record EvidenceAutomationTokenRequest(long OrganizationId);

public sealed record EvidenceAutomationAcceptRequest(
    long    OrganizationId,
    string? TargetType,           // InstanceEvidence / Task / None
    long?   TargetId,
    string? Note);

public sealed record EvidenceAutomationRejectRequest(long OrganizationId, string? Note);

public sealed record EvidenceAutomationNoticeMarkRequest(long? OrganizationId, long? NoticeId);

public sealed record EvidenceAutomationListResult(
    bool Success,
    IReadOnlyList<Dictionary<string, object?>> Rows,
    int TotalRows,
    string? Error = null);

public sealed record EvidenceAutomationBindingDetail(
    Dictionary<string, object?> Binding,
    IReadOnlyList<Dictionary<string, object?>> RecentEvents);

public sealed record EvidenceAutomationCommandResult(
    bool Success,
    Dictionary<string, object?>? Row,
    string? Error = null);

/// <summary>The token is returned ONCE, at issue; only its hash is stored.</summary>
public sealed record EvidenceAutomationTokenResult(bool Success, string? Token, string? Message, string? Error = null);

public sealed record EvidenceAutomationNoticeListResult(
    bool Success,
    IReadOnlyList<Dictionary<string, object?>> Rows,
    int TotalRows,
    int UnreadCount,
    string? Error = null);

// ---------------------------------------------------------------------
// Intake
// ---------------------------------------------------------------------

/// <summary>
/// The evidence event a source system sends (JSON body of the intake
/// endpoint, or the fields of its multipart form, or a file-drop sidecar
/// "&lt;file&gt;.json"). Every field is optional except the token.
/// </summary>
public sealed class EvidenceIntakeEvent
{
    public string?   EventId      { get; set; }   // idempotency key: a repeat returns the first event
    public DateTime? OccurredAt   { get; set; }
    public DateTime? PeriodFrom   { get; set; }
    public DateTime? PeriodTo     { get; set; }
    public string?   Result       { get; set; }   // Pass / Fail / Unknown
    public string?   Metric       { get; set; }
    public string?   Summary      { get; set; }
    public string?   SourceSystem { get; set; }
    public EvidenceIntakeFile? File { get; set; }
}

public sealed class EvidenceIntakeFile
{
    public string? Name          { get; set; }
    public string? ContentType   { get; set; }
    public string? ContentBase64 { get; set; }
}

/// <summary>A binding the intake resolved (from a token, or a drop folder).</summary>
public sealed record EvidenceIntakeBinding(long BindingId, long OrganizationId, string BindingCode, string Channel, string Status);

public sealed record EvidenceIntakeResult(
    bool    Success,
    int     StatusCode,          // HTTP status for the intake endpoint
    long?   EventId,
    long?   EvidenceItemId,
    bool    Duplicate,
    string? Message,
    string? Error = null);

public sealed record EvidenceEmailResult(int Messages, int Received, int Refused, string? Note = null);

public sealed record EvidenceFileDropResult(int Bindings, int Received, int Failed, string? Note = null);

public sealed record EvidenceMissingSweepResult(int NoticesRaised);
