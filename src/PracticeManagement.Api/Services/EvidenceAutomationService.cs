// =====================================================================
// EvidenceAutomationService  (migration 530 -- plan Part A, Phase 1)
//
// Automated evidence capture. A source system sends evidence for ONE
// obligation (a "binding") through one of two channels:
//   Webhook   POST to the intake endpoint with the binding's token
//             (JSON with the file in base64, or multipart/form-data);
//   FileDrop  a file written to <FileDropRoot>/<organizationId>/<folder>,
//             picked up by the TaskNotificationWorker pass.
//   Email     (531) a mail sent to the intake mailbox at
//             <local>+<source code>@<domain> (or with "[<source code>]" in
//             the subject) from one of the source's allowed senders, read
//             over IMAP by the TaskNotificationWorker pass. Each attachment
//             is one evidence event; a mail without attachments is stored
//             as the .eml itself.
// Either way the file becomes an ordinary Evidence Center item
// (sp_evidence_item_store, 476) and the event is recorded as a PROPOSAL.
// Nothing is linked, completed or changed until a person accepts it;
// accepting links through the unchanged 476 / 482 link procedures.
//
// Facade over:
//   sp_evidence_automation_lookups / _obligation_search / _obligation_evidence
//   sp_evidence_automation_binding_list / _get / _save / _status / _token_set
//   sp_evidence_automation_binding_resolve_token / _error / _filedrop_bindings
//   sp_evidence_automation_email_bindings                              (531)
//   sp_evidence_automation_ingest
//   sp_evidence_automation_event_list / _targets / _accept / _reject
//   sp_evidence_automation_missing_sweep / _notice_list / _notice_mark
//
// TOKENS: generated here ("grac_ei_" + 32 random bytes, base64url), shown
// to the user once, and stored ONLY as their SHA-256. A token identifies
// exactly one binding, so the intake needs no other credential.
//
// WHO SEES WHAT is decided in SQL (fn_pm_evidence_automation_can_manage):
// an organisation admin, the source owner or the obligation owner.
//
// Errors: a THROW in 51000-58999 is a sentence for the user and is
// returned as is; anything else is logged and replaced by a generic one.
// =====================================================================
using System.Collections.Concurrent;
using System.Data;
using System.Data.Common;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using MailKit;
using MailKit.Net.Imap;
using MailKit.Search;
using MailKit.Security;
using Microsoft.Data.SqlClient;
using MimeKit;
using PracticeManagement.Api.Infrastructure;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public sealed class EvidenceAutomationOptions
{
    public const string SectionName = "EvidenceAutomation";

    /// <summary>Root of the watched folders. Empty = file drop is off.
    /// A source's folder is &lt;root&gt;/&lt;organizationId&gt;/&lt;drop folder&gt;.</summary>
    public string? FileDropRoot { get; set; }

    /// <summary>A file is picked up only when it has not changed for this
    /// many seconds, so a copy still in progress is never read half-written.</summary>
    public int FileDropStableSeconds { get; set; } = 60;

    /// <summary>Files taken per source per pass.</summary>
    public int FileDropMaxFilesPerPass { get; set; } = 50;

    /// <summary>Largest evidence file accepted (bytes). 50 MB, the Evidence Center limit.</summary>
    public long MaxFileBytes { get; set; } = 52_428_800;

    /// <summary>531: the intake mailbox (IMAP). Host empty = email off.</summary>
    public EvidenceEmailOptions Email { get; set; } = new();
}

public sealed class EvidenceEmailOptions
{
    /// <summary>IMAP server, e.g. imap.gmail.com, imap.zoho.in, mail.company.local.</summary>
    public string? Host { get; set; }
    public int Port { get; set; } = 993;
    /// <summary>SslOnConnect (993), StartTls (143) or Auto.</summary>
    public string Security { get; set; } = "SslOnConnect";
    public string? Username { get; set; }
    public string? Password { get; set; }
    /// <summary>The mailbox's address as users write it, e.g. evidence@grac.in.
    /// A source is reached at evidence+&lt;source code&gt;@grac.in.</summary>
    public string? Address { get; set; }
    public string Folder { get; set; } = "INBOX";
    /// <summary>Read mail is MOVED here (stored) or to FailedFolder (refused). Nothing is deleted.</summary>
    public string ProcessedFolder { get; set; } = "GRAC-Processed";
    public string FailedFolder { get; set; } = "GRAC-Failed";
    public int MaxMessagesPerPass { get; set; } = 50;
    /// <summary>Refuse mail whose Authentication-Results header does not say
    /// dmarc=pass. Mail that says dmarc=fail or spf=fail is always refused.</summary>
    public bool RequireDmarcPass { get; set; }
}

public interface IEvidenceAutomationService
{
    Task<Dictionary<string, object?>> LookupsAsync(long organizationId, CancellationToken ct);
    Task<EvidenceAutomationListResult> ObligationSearchAsync(long organizationId, string? search, long? callerEmployeeId, bool callerIsAdmin, CancellationToken ct);
    Task<EvidenceAutomationListResult> ObligationEvidenceAsync(long organizationId, long practiceInstanceObligationId, CancellationToken ct);
    Task<EvidenceAutomationListResult> ListBindingsAsync(long organizationId, string? search, string? channel, string? status, string? health, int pageNumber, int pageSize, long? callerEmployeeId, bool callerIsAdmin, CancellationToken ct);
    Task<EvidenceAutomationBindingDetail?> GetBindingAsync(long organizationId, long bindingId, long? callerEmployeeId, bool callerIsAdmin, CancellationToken ct);
    Task<EvidenceAutomationCommandResult> SaveBindingAsync(long? bindingId, EvidenceAutomationBindingSaveRequest request, long? callerEmployeeId, bool callerIsAdmin, string actor, CancellationToken ct);
    Task<EvidenceAutomationCommandResult> SetBindingStatusAsync(long bindingId, EvidenceAutomationStatusRequest request, long? callerEmployeeId, bool callerIsAdmin, string actor, CancellationToken ct);
    Task<EvidenceAutomationTokenResult> IssueTokenAsync(long bindingId, long organizationId, long? callerEmployeeId, bool callerIsAdmin, string actor, CancellationToken ct);
    Task<EvidenceAutomationListResult> ListEventsAsync(long organizationId, long? bindingId, string? status, string? result, string? search, int pageNumber, int pageSize, long? callerEmployeeId, bool callerIsAdmin, CancellationToken ct);
    Task<EvidenceAutomationListResult> EventTargetsAsync(long organizationId, long eventId, long? callerEmployeeId, bool callerIsAdmin, CancellationToken ct);
    Task<EvidenceAutomationCommandResult> AcceptEventAsync(long eventId, EvidenceAutomationAcceptRequest request, long? callerEmployeeId, bool callerIsAdmin, string actor, CancellationToken ct);
    Task<EvidenceAutomationCommandResult> RejectEventAsync(long eventId, EvidenceAutomationRejectRequest request, long? callerEmployeeId, bool callerIsAdmin, string actor, CancellationToken ct);
    // Intake
    Task<EvidenceIntakeResult> IngestWebhookAsync(string? token, EvidenceIntakeEvent evt, byte[]? fileData, string? fileName, string? contentType, CancellationToken ct);
    Task<EvidenceFileDropResult> RunFileDropAsync(long? organizationId, CancellationToken ct);
    Task<EvidenceEmailResult> RunEmailAsync(CancellationToken ct);   // 531
    // Missing evidence
    Task<EvidenceMissingSweepResult> RunMissingSweepAsync(long? organizationId, CancellationToken ct);
    Task<EvidenceAutomationNoticeListResult> ListMyNoticesAsync(long recipientEmployeeId, long? organizationId, string? status, int pageNumber, int pageSize, CancellationToken ct);
    Task<int> MarkMyNoticesAsync(long recipientEmployeeId, long? organizationId, long? noticeId, CancellationToken ct);
}

public sealed class EvidenceAutomationService(
    IConfiguration configuration,
    ILogger<EvidenceAutomationService> logger) : IEvidenceAutomationService
{
    private const string TokenPrefix = "grac_ei_";
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private EvidenceAutomationOptions Options
    {
        get
        {
            var o = new EvidenceAutomationOptions();
            configuration.GetSection(EvidenceAutomationOptions.SectionName).Bind(o);
            return o;
        }
    }

    // ==================================================================
    // Configuration screen
    // ==================================================================
    public async Task<Dictionary<string, object?>> LookupsAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_evidence_automation_lookups");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var types     = await ReadRowsAsync(reader, ct);
        var employees = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : [];
        var o = Options;
        return new Dictionary<string, object?>
        {
            ["evidenceTypes"] = types,
            ["employees"]     = employees,
            // The screen says whether file drop / email are available on this install.
            ["fileDropEnabled"] = !string.IsNullOrWhiteSpace(o.FileDropRoot),
            ["emailEnabled"]    = !string.IsNullOrWhiteSpace(o.Email.Host) && !string.IsNullOrWhiteSpace(o.Email.Address),
            ["emailAddress"]    = o.Email.Address,
            ["maxFileBytes"]    = o.MaxFileBytes
        };
    }

    public Task<EvidenceAutomationListResult> ObligationSearchAsync(
        long organizationId, string? search, long? callerEmployeeId, bool callerIsAdmin, CancellationToken ct) =>
        ListAsync("grac_practice.sp_evidence_automation_obligation_search", "The obligations could not be loaded.", command =>
        {
            AddParam(command, "@organization_id",    DbType.Int64,   organizationId);
            AddParam(command, "@search",             DbType.String,  Text(search), 200);
            AddParam(command, "@caller_employee_id", DbType.Int64,   Id(callerEmployeeId));
            AddParam(command, "@caller_is_admin",    DbType.Boolean, callerIsAdmin);
        }, ct);

    public Task<EvidenceAutomationListResult> ObligationEvidenceAsync(
        long organizationId, long practiceInstanceObligationId, CancellationToken ct) =>
        ListAsync("grac_practice.sp_evidence_automation_obligation_evidence", "The evidence of this obligation could not be loaded.", command =>
        {
            AddParam(command, "@organization_id",                 DbType.Int64, organizationId);
            AddParam(command, "@practice_instance_obligation_id", DbType.Int64, practiceInstanceObligationId);
        }, ct);

    public Task<EvidenceAutomationListResult> ListBindingsAsync(
        long organizationId, string? search, string? channel, string? status, string? health, int pageNumber, int pageSize,
        long? callerEmployeeId, bool callerIsAdmin, CancellationToken ct) =>
        ListAsync("grac_practice.sp_evidence_automation_binding_list", "The automated evidence sources could not be loaded.", command =>
        {
            AddParam(command, "@organization_id",    DbType.Int64,   organizationId);
            AddParam(command, "@search",             DbType.String,  Text(search), 200);
            AddParam(command, "@channel",            DbType.String,  Text(channel), 20);
            AddParam(command, "@status",             DbType.String,  Text(status), 20);
            AddParam(command, "@health",             DbType.String,  Text(health), 20);
            AddParam(command, "@caller_employee_id", DbType.Int64,   Id(callerEmployeeId));
            AddParam(command, "@caller_is_admin",    DbType.Boolean, callerIsAdmin);
            AddParam(command, "@page_number",        DbType.Int32,   pageNumber);
            AddParam(command, "@page_size",          DbType.Int32,   pageSize);
        }, ct);

    public async Task<EvidenceAutomationBindingDetail?> GetBindingAsync(
        long organizationId, long bindingId, long? callerEmployeeId, bool callerIsAdmin, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_evidence_automation_binding_get");
        AddParam(command, "@organization_id",    DbType.Int64,   organizationId);
        AddParam(command, "@binding_id",         DbType.Int64,   bindingId);
        AddParam(command, "@caller_employee_id", DbType.Int64,   Id(callerEmployeeId));
        AddParam(command, "@caller_is_admin",    DbType.Boolean, callerIsAdmin);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var binding = await ReadRowsAsync(reader, ct);
        if (binding.Count == 0) return null;   // not found, or not the caller's
        var events = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : [];
        return new EvidenceAutomationBindingDetail(binding[0], events);
    }

    public async Task<EvidenceAutomationCommandResult> SaveBindingAsync(
        long? bindingId, EvidenceAutomationBindingSaveRequest r, long? callerEmployeeId, bool callerIsAdmin, string actor,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(r);
        // 531: bound only when the procedure declares it, so this Api runs
        // against a database that has 530 but not yet 531.
        var hasSenders = await HasParameterAsync("sp_evidence_automation_binding_save", "@allowed_senders", ct);
        return await CommandAsync("grac_practice.sp_evidence_automation_binding_save", "The automated evidence source could not be saved.", command =>
        {
            AddParam(command, "@organization_id",                 DbType.Int64,   r.OrganizationId);
            AddParam(command, "@binding_id",                      DbType.Int64,   Id(bindingId));
            AddParam(command, "@binding_name",                    DbType.String,  Text(r.BindingName), 200);
            AddParam(command, "@practice_instance_obligation_id", DbType.Int64,   r.PracticeInstanceObligationId);
            AddParam(command, "@instance_evidence_id",            DbType.Int64,   Id(r.InstanceEvidenceId));
            AddParam(command, "@channel",                         DbType.String,  Text(r.Channel), 20);
            AddParam(command, "@source_system",                   DbType.String,  Text(r.SourceSystem), 200);
            AddParam(command, "@external_control_ref",            DbType.String,  Text(r.ExternalControlRef), 300);
            AddParam(command, "@independence",                    DbType.String,  Text(r.Independence), 20);
            AddParam(command, "@expected_cadence",                DbType.String,  Text(r.ExpectedCadence), 20);
            AddParam(command, "@grace_days",                      DbType.Int32,   r.GraceDays ?? 1);
            AddParam(command, "@validity_days",                   DbType.Int32,   r.ValidityDays is > 0 ? r.ValidityDays : DBNull.Value);
            AddParam(command, "@evidence_type_id",                DbType.Int32,   r.EvidenceTypeId is > 0 ? r.EvidenceTypeId : DBNull.Value);
            AddParam(command, "@owner_employee_id",               DbType.Int64,   Id(r.OwnerEmployeeId));
            AddParam(command, "@classification",                  DbType.String,  Text(r.Classification), 30);
            AddParam(command, "@drop_folder",                     DbType.String,  Text(r.DropFolder), 200);
            AddParam(command, "@caller_employee_id",              DbType.Int64,   Id(callerEmployeeId));
            AddParam(command, "@caller_is_admin",                 DbType.Boolean, callerIsAdmin);
            AddParam(command, "@actor",                           DbType.String,  actor, 100);
            if (hasSenders)
                AddParam(command, "@allowed_senders",             DbType.String,  Text(r.AllowedSenders), 2000);
        }, ct);
    }

    public Task<EvidenceAutomationCommandResult> SetBindingStatusAsync(
        long bindingId, EvidenceAutomationStatusRequest r, long? callerEmployeeId, bool callerIsAdmin, string actor,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(r);
        return CommandAsync("grac_practice.sp_evidence_automation_binding_status", "The automated evidence source could not be changed.", command =>
        {
            AddParam(command, "@organization_id",    DbType.Int64,   r.OrganizationId);
            AddParam(command, "@binding_id",         DbType.Int64,   bindingId);
            AddParam(command, "@action",             DbType.String,  Text(r.Action), 20);
            AddParam(command, "@caller_employee_id", DbType.Int64,   Id(callerEmployeeId));
            AddParam(command, "@caller_is_admin",    DbType.Boolean, callerIsAdmin);
            AddParam(command, "@actor",              DbType.String,  actor, 100);
        }, ct);
    }

    public async Task<EvidenceAutomationTokenResult> IssueTokenAsync(
        long bindingId, long organizationId, long? callerEmployeeId, bool callerIsAdmin, string actor, CancellationToken ct)
    {
        var token = TokenPrefix + Base64Url(RandomNumberGenerator.GetBytes(32));
        var result = await CommandAsync("grac_practice.sp_evidence_automation_binding_token_set", "The token could not be issued.", command =>
        {
            AddParam(command, "@organization_id",    DbType.Int64,   organizationId);
            AddParam(command, "@binding_id",         DbType.Int64,   bindingId);
            AddParam(command, "@token_hash",         DbType.Binary,  HashToken(token), 32);
            AddParam(command, "@token_hint",         DbType.String,  token[^4..], 12);
            AddParam(command, "@caller_employee_id", DbType.Int64,   Id(callerEmployeeId));
            AddParam(command, "@caller_is_admin",    DbType.Boolean, callerIsAdmin);
            AddParam(command, "@actor",              DbType.String,  actor, 100);
        }, ct);
        return result.Success
            ? new EvidenceAutomationTokenResult(true, token, result.Row?.GetValueOrDefault("Message") as string)
            : new EvidenceAutomationTokenResult(false, null, null, result.Error);
    }

    public Task<EvidenceAutomationListResult> ListEventsAsync(
        long organizationId, long? bindingId, string? status, string? result, string? search, int pageNumber, int pageSize,
        long? callerEmployeeId, bool callerIsAdmin, CancellationToken ct) =>
        ListAsync("grac_practice.sp_evidence_automation_event_list", "The received evidence could not be loaded.", command =>
        {
            AddParam(command, "@organization_id",    DbType.Int64,   organizationId);
            AddParam(command, "@binding_id",         DbType.Int64,   Id(bindingId));
            AddParam(command, "@status",             DbType.String,  Text(status), 20);
            AddParam(command, "@result",             DbType.String,  Text(result), 20);
            AddParam(command, "@search",             DbType.String,  Text(search), 200);
            AddParam(command, "@caller_employee_id", DbType.Int64,   Id(callerEmployeeId));
            AddParam(command, "@caller_is_admin",    DbType.Boolean, callerIsAdmin);
            AddParam(command, "@page_number",        DbType.Int32,   pageNumber);
            AddParam(command, "@page_size",          DbType.Int32,   pageSize);
        }, ct);

    public Task<EvidenceAutomationListResult> EventTargetsAsync(
        long organizationId, long eventId, long? callerEmployeeId, bool callerIsAdmin, CancellationToken ct) =>
        ListAsync("grac_practice.sp_evidence_automation_event_targets", "The places to attach this evidence could not be loaded.", command =>
        {
            AddParam(command, "@organization_id",    DbType.Int64,   organizationId);
            AddParam(command, "@event_id",           DbType.Int64,   eventId);
            AddParam(command, "@caller_employee_id", DbType.Int64,   Id(callerEmployeeId));
            AddParam(command, "@caller_is_admin",    DbType.Boolean, callerIsAdmin);
        }, ct);

    public Task<EvidenceAutomationCommandResult> AcceptEventAsync(
        long eventId, EvidenceAutomationAcceptRequest r, long? callerEmployeeId, bool callerIsAdmin, string actor, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(r);
        // The link procedure the accept calls returns its own result set
        // first; CommandAsync reads the LAST one, which is the accept's.
        return CommandAsync("grac_practice.sp_evidence_automation_event_accept", "The evidence could not be accepted.", command =>
        {
            AddParam(command, "@organization_id",    DbType.Int64,   r.OrganizationId);
            AddParam(command, "@event_id",           DbType.Int64,   eventId);
            AddParam(command, "@target_type",        DbType.String,  Text(r.TargetType), 40);
            AddParam(command, "@target_id",          DbType.Int64,   Id(r.TargetId));
            AddParam(command, "@decision_note",      DbType.String,  Text(r.Note), 1000);
            AddParam(command, "@caller_employee_id", DbType.Int64,   Id(callerEmployeeId));
            AddParam(command, "@caller_is_admin",    DbType.Boolean, callerIsAdmin);
            AddParam(command, "@actor",              DbType.String,  actor, 100);
        }, ct);
    }

    public Task<EvidenceAutomationCommandResult> RejectEventAsync(
        long eventId, EvidenceAutomationRejectRequest r, long? callerEmployeeId, bool callerIsAdmin, string actor, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(r);
        return CommandAsync("grac_practice.sp_evidence_automation_event_reject", "The evidence could not be rejected.", command =>
        {
            AddParam(command, "@organization_id",    DbType.Int64,   r.OrganizationId);
            AddParam(command, "@event_id",           DbType.Int64,   eventId);
            AddParam(command, "@decision_note",      DbType.String,  Text(r.Note), 1000);
            AddParam(command, "@caller_employee_id", DbType.Int64,   Id(callerEmployeeId));
            AddParam(command, "@caller_is_admin",    DbType.Boolean, callerIsAdmin);
            AddParam(command, "@actor",              DbType.String,  actor, 100);
        }, ct);
    }

    // ==================================================================
    // Intake -- webhook
    // ==================================================================
    public async Task<EvidenceIntakeResult> IngestWebhookAsync(
        string? token, EvidenceIntakeEvent evt, byte[]? fileData, string? fileName, string? contentType, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(evt);
        if (string.IsNullOrWhiteSpace(token) || !token.StartsWith(TokenPrefix, StringComparison.Ordinal) || token.Length > 200)
            return IntakeFailed(401, "A valid intake token is required.");

        EvidenceIntakeBinding? binding;
        try { binding = await ResolveTokenAsync(token.Trim(), ct); }
        catch (Exception ex)
        {
            logger.LogError(ex, "Evidence intake: token lookup failed.");
            return IntakeFailed(503, "Evidence intake is not available right now. Try again later.");
        }
        // Unknown and revoked tokens read the same: nothing is revealed.
        if (binding is null) return IntakeFailed(401, "A valid intake token is required.");

        // The file: multipart part, else base64 in the JSON, else a JSON
        // record of the event itself (the event IS the evidence).
        if (fileData is null && !string.IsNullOrWhiteSpace(evt.File?.ContentBase64))
        {
            try { fileData = Convert.FromBase64String(evt.File!.ContentBase64!); }
            catch (FormatException)
            {
                await RecordBindingErrorAsync(binding.BindingId, "file.contentBase64 is not valid base64.", ct);
                return IntakeFailed(400, "file.contentBase64 is not valid base64.");
            }
            fileName    ??= evt.File.Name;
            contentType ??= evt.File.ContentType;
        }

        return await IngestAsync(binding, "Webhook", evt, fileData, fileName, contentType, ct);
    }

    private async Task<EvidenceIntakeResult> IngestAsync(
        EvidenceIntakeBinding binding, string channel, EvidenceIntakeEvent evt, byte[]? fileData, string? fileName,
        string? contentType, CancellationToken ct, string? senderAddress = null)
    {
        var max = Options.MaxFileBytes;
        if (fileData is { Length: > 0 } && fileData.LongLength > max)
        {
            var tooBig = $"The evidence file is larger than {max / 1_048_576} MB.";
            await RecordBindingErrorAsync(binding.BindingId, tooBig, ct);
            return IntakeFailed(413, tooBig);
        }

        // Metadata only -- never the bytes.
        var metadata = JsonSerializer.Serialize(new
        {
            evt.EventId, evt.OccurredAt, evt.PeriodFrom, evt.PeriodTo, evt.Result, evt.Metric, evt.Summary, evt.SourceSystem,
            file = fileData is null ? null : new { name = fileName, contentType, sizeBytes = fileData.LongLength }
        }, Json);

        if (fileData is null || fileData.Length == 0)
        {
            // No file: the event record is stored as the evidence artifact.
            fileData    = Encoding.UTF8.GetBytes(metadata);
            fileName    = $"automated-evidence-{binding.BindingCode}-{DateTime.UtcNow:yyyyMMddHHmmss}.json";
            contentType = "application/json";
        }

        fileName = SafeFileName(fileName) ?? $"automated-evidence-{DateTime.UtcNow:yyyyMMddHHmmss}.bin";

        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_evidence_automation_ingest");
            AddParam(command, "@binding_id",        DbType.Int64,     binding.BindingId);
            AddParam(command, "@channel",           DbType.String,    channel, 20);
            AddParam(command, "@external_event_id", DbType.String,    Text(Cap(evt.EventId, 200)), 200);
            AddParam(command, "@occurred_at",       DbType.DateTime2, evt.OccurredAt?.ToUniversalTime());
            AddParam(command, "@period_from",       DbType.Date,      evt.PeriodFrom?.Date);
            AddParam(command, "@period_to",         DbType.Date,      evt.PeriodTo?.Date);
            AddParam(command, "@result",            DbType.String,    Text(Cap(evt.Result, 20)), 20);
            AddParam(command, "@metric_value",      DbType.String,    Text(Cap(evt.Metric, 200)), 200);
            AddParam(command, "@summary",           DbType.String,    Text(Cap(evt.Summary, 2000)), 2000);
            AddParam(command, "@source_system",     DbType.String,    Text(Cap(evt.SourceSystem, 200)), 200);
            AddParam(command, "@file_name",         DbType.String,    fileName, 500);
            AddParam(command, "@content_type",      DbType.String,    Text(Cap(contentType, 200)), 200);
            AddParam(command, "@file_data",         DbType.Binary,    fileData, -1);
            AddParam(command, "@payload_json",      DbType.String,    metadata, -1);
            if (senderAddress is not null)   // 531: Email only (the procedure checks the allowed senders)
                AddParam(command, "@sender_address", DbType.String,   Cap(senderAddress, 320), 320);

            await using var reader = await command.ExecuteReaderAsync(ct);
            if (!await reader.ReadAsync(ct))
                return IntakeFailed(500, "The evidence could not be stored.");
            var duplicate = Convert.ToBoolean(reader["Duplicate"]);
            return new EvidenceIntakeResult(
                Success:        true,
                StatusCode:     duplicate ? 200 : 201,
                EventId:        Convert.ToInt64(reader["EventId"]),
                EvidenceItemId: reader["EvidenceItemId"] is DBNull ? null : Convert.ToInt64(reader["EvidenceItemId"]),
                Duplicate:      duplicate,
                Message:        reader["Message"] as string);
        }
        catch (SqlException ex) when (ex.Number is >= 58400 and <= 58429)
        {
            await RecordBindingErrorAsync(binding.BindingId,
                senderAddress is null ? ex.Message : $"{ex.Message} (from {Cap(senderAddress, 200)})", ct);
            // 58415 paused / 58416 retired: the source must be changed by its
            // owner, not the request -- 409 rather than 400.
            return IntakeFailed(ex.Number is 58415 or 58416 ? 409 : 400, ex.Message);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Evidence intake for binding {BindingId} failed.", binding.BindingId);
            return IntakeFailed(500, "The evidence could not be stored.");
        }
    }

    private async Task<EvidenceIntakeBinding?> ResolveTokenAsync(string token, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_evidence_automation_binding_resolve_token");
        AddParam(command, "@token_hash", DbType.Binary, HashToken(token), 32);
        await using var reader = await command.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return null;
        return new EvidenceIntakeBinding(
            Convert.ToInt64(reader["BindingId"]), Convert.ToInt64(reader["OrganizationId"]),
            reader["BindingCode"].ToString()!, reader["Channel"].ToString()!, reader["Status"].ToString()!);
    }

    private async Task RecordBindingErrorAsync(long bindingId, string error, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_evidence_automation_binding_error");
            AddParam(command, "@binding_id", DbType.Int64,  bindingId);
            AddParam(command, "@error",      DbType.String, Cap(error, 1000), 1000);
            await command.ExecuteNonQueryAsync(ct);
        }
        catch (Exception ex)
        {
            // Recording the refusal must never hide it from the sender.
            logger.LogWarning(ex, "Could not record the intake error for binding {BindingId}.", bindingId);
        }
    }

    // ==================================================================
    // Intake -- file drop (worker pass)
    //   <root>/<organizationId>/<drop folder>/<file>        the evidence
    //   <root>/<organizationId>/<drop folder>/<file>.json   optional sidecar
    //                                                        (EvidenceIntakeEvent)
    // A stored file moves to _processed/<yyyyMMdd>/, a refused one to
    // _failed/ with <file>.error.txt saying why. Nothing is deleted.
    // ==================================================================
    public async Task<EvidenceFileDropResult> RunFileDropAsync(long? organizationId, CancellationToken ct)
    {
        var o = Options;
        if (string.IsNullOrWhiteSpace(o.FileDropRoot))
            return new EvidenceFileDropResult(0, 0, 0, "FileDropRoot is not configured.");
        var root = Path.GetFullPath(o.FileDropRoot.Trim());
        if (!Directory.Exists(root))
            return new EvidenceFileDropResult(0, 0, 0, $"FileDropRoot '{root}' does not exist.");
        var rootWithSep = root.EndsWith(Path.DirectorySeparatorChar) ? root : root + Path.DirectorySeparatorChar;

        var bindings = new List<(long BindingId, long OrganizationId, string Code, string Folder)>();
        await using (var connection = await OpenAsync(ct))
        await using (var command = Proc(connection, "grac_practice.sp_evidence_automation_filedrop_bindings"))
        {
            AddParam(command, "@organization_id", DbType.Int64, Id(organizationId));
            await using var reader = await command.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
                bindings.Add((Convert.ToInt64(reader["BindingId"]), Convert.ToInt64(reader["OrganizationId"]),
                              reader["BindingCode"].ToString()!, reader["DropFolder"].ToString()!));
        }

        int received = 0, failed = 0;
        var stableBefore = DateTime.UtcNow.AddSeconds(-Math.Clamp(o.FileDropStableSeconds, 0, 3600));
        foreach (var b in bindings)
        {
            ct.ThrowIfCancellationRequested();
            var folder = Path.GetFullPath(Path.Combine(root, b.OrganizationId.ToString(),
                b.Folder.Replace('/', Path.DirectorySeparatorChar)));
            // The folder is validated in SQL as well; this is the last word.
            if (!folder.StartsWith(rootWithSep, StringComparison.OrdinalIgnoreCase)) continue;
            try { Directory.CreateDirectory(folder); }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "File drop folder {Folder} could not be created.", folder);
                continue;
            }

            var binding = new EvidenceIntakeBinding(b.BindingId, b.OrganizationId, b.Code, "FileDrop", "Active");
            var files = Directory.EnumerateFiles(folder, "*", SearchOption.TopDirectoryOnly)
                .Select(p => new FileInfo(p))
                .Where(f => !f.Name.StartsWith('.') && !f.Name.StartsWith("~$", StringComparison.Ordinal)
                            && !f.Name.EndsWith(".json", StringComparison.OrdinalIgnoreCase)
                            && f.LastWriteTimeUtc <= stableBefore)
                .OrderBy(f => f.LastWriteTimeUtc)
                .Take(Math.Clamp(o.FileDropMaxFilesPerPass, 1, 500))
                .ToList();

            foreach (var f in files)
            {
                ct.ThrowIfCancellationRequested();
                var sidecar = new FileInfo(f.FullName + ".json");
                EvidenceIntakeResult result;
                try
                {
                    var evt = new EvidenceIntakeEvent();
                    if (sidecar.Exists)
                        evt = JsonSerializer.Deserialize<EvidenceIntakeEvent>(await File.ReadAllTextAsync(sidecar.FullName, ct), Json)
                              ?? new EvidenceIntakeEvent();
                    // Same file, same size, same time = the same event: a
                    // pass that stored it but could not move it never stores
                    // it twice.
                    evt.EventId ??= $"file:{Cap(f.Name, 150)}:{f.Length}:{f.LastWriteTimeUtc.Ticks}";
                    evt.PeriodTo ??= f.LastWriteTimeUtc.Date;
                    result = f.Length > o.MaxFileBytes
                        ? IntakeFailed(413, $"The evidence file is larger than {o.MaxFileBytes / 1_048_576} MB.")
                        : await IngestAsync(binding, "FileDrop", evt, await File.ReadAllBytesAsync(f.FullName, ct),
                                            f.Name, ContentTypeFor(f.Extension), ct);
                }
                catch (JsonException ex)
                {
                    result = IntakeFailed(400, $"The sidecar {sidecar.Name} is not valid JSON: {ex.Message}");
                    await RecordBindingErrorAsync(b.BindingId, result.Error!, ct);
                }
                catch (IOException ex)
                {
                    // Still locked by the writer: try again next pass.
                    logger.LogInformation(ex, "File drop {File} not readable yet.", f.FullName);
                    continue;
                }

                if (result.Success) received++;
                else failed++;
                MoveAfterIntake(folder, f, sidecar, result);
            }
        }
        return new EvidenceFileDropResult(bindings.Count, received, failed);
    }

    private void MoveAfterIntake(string folder, FileInfo file, FileInfo sidecar, EvidenceIntakeResult result)
    {
        try
        {
            var target = result.Success
                ? Path.Combine(folder, "_processed", DateTime.UtcNow.ToString("yyyyMMdd"))
                : Path.Combine(folder, "_failed");
            Directory.CreateDirectory(target);
            var dest = UniquePath(target, file.Name);
            File.Move(file.FullName, dest);
            if (sidecar.Exists) File.Move(sidecar.FullName, dest + ".json");
            if (!result.Success)
                File.WriteAllText(dest + ".error.txt", $"{DateTime.UtcNow:u}  {result.Error}{Environment.NewLine}");
        }
        catch (Exception ex)
        {
            // Stored but not moved: the next pass finds the same event id
            // and gets "already received" -- harmless.
            logger.LogWarning(ex, "File drop {File} could not be moved after intake.", file.FullName);
        }
    }

    private static string UniquePath(string folder, string name)
    {
        var path = Path.Combine(folder, name);
        if (!File.Exists(path)) return path;
        var stem = Path.GetFileNameWithoutExtension(name);
        var ext  = Path.GetExtension(name);
        for (var i = 1; ; i++)
        {
            path = Path.Combine(folder, $"{stem}-{i}{ext}");
            if (!File.Exists(path)) return path;
        }
    }

    // ==================================================================
    // Intake -- email (531, worker pass)
    //   One intake mailbox per installation, read over IMAP. A mail reaches
    //   the source whose code is the "+tag" of a recipient address
    //   (evidence+eab-1a2b...@grac.in) or appears in the subject as
    //   "[eab-1a2b...]". The sender must be on that source's allowed list
    //   (checked in sp_evidence_automation_ingest). Each attachment is one
    //   event; no attachment = the mail itself (.eml). Result: a "Result:"
    //   line in the body, else the subject's words ([Success] / [Failed]
    //   ...), else Unknown. Period: "PeriodFrom:" / "PeriodTo:" (or
    //   "Period:") lines, else the mail's date. Stored mail is moved to
    //   ProcessedFolder, refused mail to FailedFolder -- nothing is deleted.
    // ==================================================================
    private static readonly Regex SourceCodePattern = new(@"\b(eab-[0-9a-f]{20})\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex FailWords = new(@"\b(fail|failed|failure|error|unsuccessful)\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex PassWords = new(@"\b(pass|passed|success|successful|succeeded|completed|ok)\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public async Task<EvidenceEmailResult> RunEmailAsync(CancellationToken ct)
    {
        var e = Options.Email;
        if (string.IsNullOrWhiteSpace(e.Host) || string.IsNullOrWhiteSpace(e.Username))
            return new EvidenceEmailResult(0, 0, 0, "EvidenceAutomation:Email is not configured.");

        var routes = new Dictionary<string, EvidenceIntakeBinding>(StringComparer.OrdinalIgnoreCase);
        await using (var connection = await OpenAsync(ct))
        await using (var command = Proc(connection, "grac_practice.sp_evidence_automation_email_bindings"))
        {
            await using var reader = await command.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                var b = new EvidenceIntakeBinding(Convert.ToInt64(reader["BindingId"]), Convert.ToInt64(reader["OrganizationId"]),
                                                  reader["BindingCode"].ToString()!, "Email", "Active");
                routes[b.BindingCode] = b;
            }
        }

        using var client = new ImapClient();
        await client.ConnectAsync(e.Host, e.Port, e.Security?.Trim().ToLowerInvariant() switch
        {
            "starttls" => SecureSocketOptions.StartTls,
            "auto"     => SecureSocketOptions.Auto,
            "none"     => SecureSocketOptions.None,
            _          => SecureSocketOptions.SslOnConnect
        }, ct);
        await client.AuthenticateAsync(e.Username, e.Password ?? "", ct);

        var inbox = string.IsNullOrWhiteSpace(e.Folder) || e.Folder.Equals("INBOX", StringComparison.OrdinalIgnoreCase)
            ? client.Inbox
            : await client.GetFolderAsync(e.Folder, ct);
        await inbox.OpenAsync(FolderAccess.ReadWrite, ct);
        var processed = await EnsureFolderAsync(client, e.ProcessedFolder, ct);
        var failed    = await EnsureFolderAsync(client, e.FailedFolder, ct);

        var uids = await inbox.SearchAsync(SearchQuery.All, ct);
        int messages = 0, received = 0, refused = 0;
        foreach (var uid in uids.Take(Math.Clamp(e.MaxMessagesPerPass, 1, 500)))
        {
            ct.ThrowIfCancellationRequested();
            MimeMessage message;
            try { message = await inbox.GetMessageAsync(uid, ct); }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogWarning(ex, "Evidence email {Uid} could not be read.", uid);
                continue;
            }
            messages++;
            var (ok, error) = await IngestEmailAsync(message, routes, e, ct);
            if (ok) received++;
            else
            {
                refused++;
                logger.LogInformation("Evidence email \"{Subject}\" refused: {Error}", message.Subject, error);
            }
            try { await inbox.MoveToAsync(uid, ok ? processed : failed, ct); }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // Stored but not moved: the next pass meets the same event id
                // ("already received") -- harmless.
                logger.LogWarning(ex, "Evidence email {Uid} could not be moved after intake.", uid);
            }
        }
        await client.DisconnectAsync(true, ct);
        return new EvidenceEmailResult(messages, received, refused);
    }

    private async Task<(bool Ok, string? Error)> IngestEmailAsync(
        MimeMessage message, Dictionary<string, EvidenceIntakeBinding> routes, EvidenceEmailOptions e, CancellationToken ct)
    {
        // Which source: a "+tag" recipient first, then the subject.
        var recipients = message.To.Mailboxes.Concat(message.Cc.Mailboxes).Select(m => m.Address)
            .Concat(new[] { "Delivered-To", "X-Original-To", "Envelope-To" }
                .Select(h => message.Headers[h]).Where(v => !string.IsNullOrWhiteSpace(v)).Select(v => v!.Trim('<', '>', ' ')));
        EvidenceIntakeBinding? binding = null;
        foreach (var address in recipients)
        {
            var at = address.LastIndexOf('@');
            var plus = address.IndexOf('+');
            if (plus < 0 || at <= plus) continue;
            if (routes.TryGetValue(address[(plus + 1)..at], out binding)) break;
        }
        if (binding is null)
        {
            var m = SourceCodePattern.Match(message.Subject ?? "");
            if (m.Success) routes.TryGetValue(m.Groups[1].Value, out binding);
        }
        if (binding is null)
            return (false, "No active email source matches this mail (address +tag or [source code] in the subject).");

        var sender = message.From.Mailboxes.FirstOrDefault()?.Address ?? message.Sender?.Address;
        if (string.IsNullOrWhiteSpace(sender))
        {
            await RecordBindingErrorAsync(binding.BindingId, "Mail refused: it has no sender address.", ct);
            return (false, "no sender");
        }

        // Spoofing guard: what the receiving mail server concluded.
        var auth = (message.Headers["Authentication-Results"] ?? "").ToLowerInvariant();
        if (auth.Contains("dmarc=fail") || auth.Contains("spf=fail") || (e.RequireDmarcPass && !auth.Contains("dmarc=pass")))
        {
            var why = $"Mail from {Cap(sender, 200)} refused: the mail server could not verify the sender (SPF / DMARC).";
            await RecordBindingErrorAsync(binding.BindingId, why, ct);
            return (false, why);
        }

        var body = message.TextBody ?? "";
        var evt = new EvidenceIntakeEvent
        {
            Result       = ResultFromMail(message.Subject ?? "", body),
            Metric       = Line(body, "metric"),
            Summary      = Cap(message.Subject, 2000),
            PeriodFrom   = DateLine(body, "periodfrom"),
            PeriodTo     = DateLine(body, "periodto") ?? DateLine(body, "period") ?? message.Date.UtcDateTime.Date,
            OccurredAt   = message.Date.UtcDateTime
        };
        var mailId = "mail:" + Cap(string.IsNullOrWhiteSpace(message.MessageId)
            ? Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{sender}|{message.Date:O}|{message.Subject}")))[..32]
            : message.MessageId, 180);

        // The files: every attachment, else the mail itself.
        var files = new List<(string Name, string? Type, byte[] Data)>();
        foreach (var part in message.Attachments)
        {
            using var ms = new MemoryStream();
            if (part is MimePart mp)
            {
                await mp.Content.DecodeToAsync(ms, ct);
                files.Add((mp.FileName ?? "attachment", mp.ContentType.MimeType, ms.ToArray()));
            }
            else if (part is MessagePart msg)
            {
                await msg.Message.WriteToAsync(ms, ct);
                files.Add(("attached-message.eml", "message/rfc822", ms.ToArray()));
            }
        }
        if (files.Count == 0)
        {
            using var ms = new MemoryStream();
            await message.WriteToAsync(ms, ct);
            files.Add(($"{SafeFileName(message.Subject) ?? "mail"}.eml", "message/rfc822", ms.ToArray()));
        }

        string? lastError = null;
        for (var i = 0; i < files.Count; i++)
        {
            evt.EventId = files.Count == 1 ? mailId : $"{mailId}:{i + 1}";
            var r = await IngestAsync(binding, "Email", evt, files[i].Data, files[i].Name, files[i].Type, ct, sender);
            if (!r.Success) lastError = r.Error;
        }
        return lastError is null ? (true, null) : (false, lastError);
    }

    private static async Task<IMailFolder> EnsureFolderAsync(ImapClient client, string name, CancellationToken ct)
    {
        var root = client.PersonalNamespaces.Count > 0 ? client.GetFolder(client.PersonalNamespaces[0]) : client.Inbox;
        try { return await root.GetSubfolderAsync(name, ct); }
        catch (FolderNotFoundException) { return await root.CreateAsync(name, true, ct); }
    }

    /// <summary>"Result:" line, else the subject's words, else Unknown --
    /// always one of the values sp_evidence_automation_ingest accepts.</summary>
    private static string ResultFromMail(string subject, string body)
    {
        var stated = Line(body, "result");
        if (stated is not null)
            return FailWords.IsMatch(stated) ? "Fail" : PassWords.IsMatch(stated) ? "Pass" : "Unknown";
        return FailWords.IsMatch(subject) ? "Fail" : PassWords.IsMatch(subject) ? "Pass" : "Unknown";
    }

    private static string? Line(string body, string key)
    {
        var m = Regex.Match(body, @"^[ \t]*" + key + @"[ \t]*[:=][ \t]*(.+?)[ \t]*$", RegexOptions.IgnoreCase | RegexOptions.Multiline);
        return m.Success ? Cap(m.Groups[1].Value.Trim(), 200) : null;
    }

    private static DateTime? DateLine(string body, string key) =>
        Line(body, key) is { } v && DateTime.TryParseExact(v.Length >= 10 ? v[..10] : v, "yyyy-MM-dd",
            System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out var d) ? d : null;

    // ==================================================================
    // Missing evidence -- notices (worker pass + My Notifications)
    // ==================================================================
    public async Task<EvidenceMissingSweepResult> RunMissingSweepAsync(long? organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_evidence_automation_missing_sweep");
        AddParam(command, "@organization_id", DbType.Int64, Id(organizationId));
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct)
            ? new EvidenceMissingSweepResult(Convert.ToInt32(reader["NoticesRaised"]))
            : new EvidenceMissingSweepResult(0);
    }

    public async Task<EvidenceAutomationNoticeListResult> ListMyNoticesAsync(
        long recipientEmployeeId, long? organizationId, string? status, int pageNumber, int pageSize, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_evidence_automation_notice_list");
            AddParam(command, "@recipient_employee_id", DbType.Int64,  recipientEmployeeId);
            AddParam(command, "@organization_id",       DbType.Int64,  Id(organizationId));
            AddParam(command, "@status",                DbType.String, Text(status), 10);
            AddParam(command, "@page_number",           DbType.Int32,  pageNumber);
            AddParam(command, "@page_size",             DbType.Int32,  pageSize);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var rows   = await ReadRowsAsync(reader, ct);
            var total  = rows.Count > 0 && rows[0].TryGetValue("TotalRows", out var t) && t is not null ? Convert.ToInt32(t) : 0;
            var unread = rows.Count > 0 && rows[0].TryGetValue("UnreadCount", out var u) && u is not null ? Convert.ToInt32(u) : 0;
            if (rows.Count == 0 && !string.Equals(status, "Unread", StringComparison.OrdinalIgnoreCase))
                unread = (await ListMyNoticesAsync(recipientEmployeeId, organizationId, "Unread", 1, 1, ct)).UnreadCount;
            return new EvidenceAutomationNoticeListResult(true, rows, total, unread);
        }
        catch (SqlException ex) when (ex.Number == 2812)
        {
            // A database without 530: no notices, not a broken page.
            return new EvidenceAutomationNoticeListResult(true, [], 0, 0);
        }
        catch (Exception ex)
        {
            return new EvidenceAutomationNoticeListResult(false, [], 0, 0,
                UserMessage(ex, "The automated evidence notices could not be loaded.", "sp_evidence_automation_notice_list"));
        }
    }

    public async Task<int> MarkMyNoticesAsync(long recipientEmployeeId, long? organizationId, long? noticeId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_evidence_automation_notice_mark");
        AddParam(command, "@recipient_employee_id", DbType.Int64, recipientEmployeeId);
        AddParam(command, "@notice_id",             DbType.Int64, Id(noticeId));
        AddParam(command, "@organization_id",       DbType.Int64, Id(organizationId));
        var marked = await command.ExecuteScalarAsync(ct);
        return marked is null or DBNull ? 0 : Convert.ToInt32(marked);
    }

    // ==================================================================
    // Helpers -- the sibling services' shape (EvidenceCenterService)
    // ==================================================================
    public static byte[] HashToken(string token) => SHA256.HashData(Encoding.UTF8.GetBytes(token));

    // Parameters added by a later migration are bound only when declared
    // (ProcParameterProbe). A "yes" is remembered for the process; a "no" is
    // asked again, so running the migration needs no restart.
    private static readonly ConcurrentDictionary<string, bool> DeclaredParameters = new();

    private async Task<bool> HasParameterAsync(string procedure, string parameter, CancellationToken ct)
    {
        var key = procedure + "|" + parameter;
        if (DeclaredParameters.ContainsKey(key)) return true;
        await using var connection = await OpenAsync(ct);
        if (!await ProcParameterProbe.HasParameterAsync(connection, procedure, parameter, ct)) return false;
        DeclaredParameters[key] = true;
        return true;
    }

    private static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static EvidenceIntakeResult IntakeFailed(int status, string error) =>
        new(false, status, null, null, false, null, error);

    private static string? SafeFileName(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return null;
        var clean = Path.GetFileName(name.Replace('\\', '/').Split('/').Last()).Trim();
        foreach (var c in Path.GetInvalidFileNameChars()) clean = clean.Replace(c, '_');
        return string.IsNullOrWhiteSpace(clean) ? null : Cap(clean, 500);
    }

    private static string ContentTypeFor(string extension) => extension.ToLowerInvariant() switch
    {
        ".pdf"  => "application/pdf",
        ".csv"  => "text/csv",
        ".txt" or ".log" => "text/plain",
        ".json" => "application/json",
        ".xml"  => "application/xml",
        ".html" or ".htm" => "text/html",
        ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ".png"  => "image/png",
        ".jpg" or ".jpeg" => "image/jpeg",
        ".zip"  => "application/zip",
        _       => "application/octet-stream"
    };

    private static string? Cap(string? value, int max) =>
        value is null ? null : value.Length <= max ? value : value[..max];

    private async Task<EvidenceAutomationListResult> ListAsync(
        string procedure, string fallback, Action<DbCommand> bind, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, procedure);
            bind(command);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var rows  = await ReadRowsAsync(reader, ct);
            var total = rows.Count > 0 && rows[0].TryGetValue("TotalRows", out var t) && t is not null ? Convert.ToInt32(t) : rows.Count;
            return new EvidenceAutomationListResult(true, rows, total);
        }
        catch (Exception ex)
        {
            return new EvidenceAutomationListResult(false, [], 0, UserMessage(ex, fallback, procedure));
        }
    }

    /// <summary>Runs a command procedure and returns the first row of its
    /// LAST result set (a procedure that calls another returns that one's
    /// result first).</summary>
    private async Task<EvidenceAutomationCommandResult> CommandAsync(
        string procedure, string fallback, Action<DbCommand> bind, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, procedure);
            bind(command);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var rows = await ReadRowsAsync(reader, ct);
            while (await reader.NextResultAsync(ct))
                rows = await ReadRowsAsync(reader, ct);
            return new EvidenceAutomationCommandResult(true, rows.Count > 0 ? rows[0] : null);
        }
        catch (Exception ex)
        {
            return new EvidenceAutomationCommandResult(false, null, UserMessage(ex, fallback, procedure));
        }
    }

    private string UserMessage(Exception ex, string fallback, string procedure)
    {
        // 51000-52999: the Evidence Center / Task Centre sentences the link
        // procedures raise; 58400-58429: this module's.
        if (ex is SqlException sql && sql.Number is (>= 51000 and <= 52999) or (>= 58400 and <= 58429))
            return sql.Message;
        logger.LogError(ex, "{Procedure} failed.", procedure);
        return fallback;
    }

    private static DbCommand Proc(DbConnection connection, string name)
    {
        var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = name;
        return command;
    }

    private static async Task<List<Dictionary<string, object?>>> ReadRowsAsync(DbDataReader reader, CancellationToken ct)
    {
        var rows = new List<Dictionary<string, object?>>();
        while (await reader.ReadAsync(ct))
        {
            var row = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
            for (var i = 0; i < reader.FieldCount; i++)
                row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            rows.Add(row);
        }
        return rows;
    }

    private async Task<DbConnection> OpenAsync(CancellationToken ct)
    {
        var connString = SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connString))
            throw new InvalidOperationException("PracticeManagement connection string is not configured.");
        var connection = new SqlConnection(connString);
        await connection.OpenAsync(ct);
        await ViewScopeSession.ApplyAsync(connection, ct);   // 415: View Data Scope
        return connection;
    }

    private static object Text(string? value) =>
        string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();

    private static object Id(long? value) => value is > 0 ? value.Value : DBNull.Value;

    private static void AddParam(DbCommand command, string name, DbType type, object? value, int? size = null)
    {
        var p = command.CreateParameter();
        p.ParameterName = name;
        p.DbType = type;
        if (size.HasValue) p.Size = size.Value;
        p.Value = value ?? DBNull.Value;
        command.Parameters.Add(p);
    }
}
