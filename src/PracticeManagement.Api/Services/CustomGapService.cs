// =====================================================================
// CustomGapService (unified Gap Center)
//
// Thin facade over grac_practice.sp_custom_gap_* procedures.
//
// After migrations 109-113, custom_gap is the single source of truth
// for gaps across all modules (Implementation / Assurance / Custom /
// Exception / Risk / Audit). This service exposes:
//   * Legacy minimal ops (List / Open / Close) for the pre-existing
//     Practice/Partials/gaps.cshtml Custom tab.
//   * Unified operations for the Assurance flow: Get / Save / Delete,
//     lifecycle transitions, junction attach / detach / list, merge,
//     corrective actions, history, generate-from-observation, and the
//     reverse "gaps linked to observation" read.
//
// Registered via Infrastructure/CustomGapServiceRegistration.cs.
// =====================================================================
using System.Data;
using System.Text.Json;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface ICustomGapService
{
    // Legacy
    Task<CustomGapListResult>    ListAsync(CustomGapListQuery query, CancellationToken cancellationToken);
    Task<CustomGapCommandResult> OpenAsync(CustomGapOpenRequest request, CancellationToken cancellationToken);
    Task<CustomGapCommandResult> CloseAsync(CustomGapCloseRequest request, CancellationToken cancellationToken);

    // Migration 255 -- the unified Gap Centre list (both origins).
    // Additive: ListAsync above keeps backing /api/practice/gaps/custom.
    Task<GapCentreListResult> ListGapCentreAsync(
        GapCentreListQuery query, CancellationToken cancellationToken);
    Task<IReadOnlyList<GapCentreSourceCount>> ListGapCentreSourcesAsync(
        long? organizationId, CancellationToken cancellationToken);

    // Unified
    Task<CustomGapDetail?>       GetAsync(long organizationId, long customGapId, CancellationToken cancellationToken);
    // Migration 382: practices mapped to a Custom Gap (read-only display).
    Task<IReadOnlyList<CustomGapPracticeRow>> GetPracticesAsync(long customGapId, CancellationToken cancellationToken);
    Task<CustomGapSaveResult>    SaveAsync(CustomGapSaveRequest request, CancellationToken cancellationToken);
    Task<CustomGapCommandResult> DeleteAsync(CustomGapCommandRequest request, CancellationToken cancellationToken);
    Task<CustomGapGenerateResult> GenerateFromAssuranceObservationAsync(
        CustomGapGenerateRequest request, CancellationToken cancellationToken);

    // Migration 184 -- SLA auto-match + operator-driven override
    // Public because GapLifecycleService reuses it after analysis save.
    Task ApplyAutoSlaAsync(long customGapId, string? callerDisplayName, CancellationToken cancellationToken);

    Task<SlaOverrideRequestResult> RequestSlaOverrideAsync(
        SlaOverrideRequestPayload request, CancellationToken cancellationToken);

    // Lifecycle
    Task<CustomGapCommandResult> StartAsync            (CustomGapCommandRequest r, CancellationToken ct);
    Task<CustomGapCommandResult> SubmitRemediationAsync(CustomGapCommandRequest r, CancellationToken ct);
    Task<CustomGapCommandResult> VerifyAsync           (CustomGapCommandRequest r, CancellationToken ct);
    Task<CustomGapCommandResult> CloseLifecycleAsync   (CustomGapCommandRequest r, CancellationToken ct);
    Task<CustomGapCommandResult> ReopenAsync           (CustomGapCommandRequest r, CancellationToken ct);

    // Junction
    Task<IReadOnlyList<CustomGapObservationLinkRow>> ListLinkedObservationsAsync(
        long organizationId, long customGapId, bool includeDetached, CancellationToken cancellationToken);
    Task<IReadOnlyList<CustomGapObservationLinkRow>> ListLinkedGapsForObservationAsync(
        long organizationId, long observationId, bool includeDetached, CancellationToken cancellationToken);
    Task<CustomGapAttachResult>  AttachObservationAsync(CustomGapAttachRequest r, CancellationToken ct);
    Task<CustomGapCommandResult> DetachObservationAsync(CustomGapDetachRequest r, CancellationToken ct);
    Task<CustomGapMergeResult>   MergeGapsAsync(CustomGapMergeRequest r, CancellationToken ct);

    // Actions
    Task<IReadOnlyList<CustomGapActionRow>> ListActionsAsync(
        long organizationId, long customGapId, CancellationToken cancellationToken);
    Task<CustomGapActionSaveResult> SaveActionAsync(CustomGapActionSaveRequest r, CancellationToken ct);
    Task<CustomGapCommandResult>    CompleteActionAsync(
        long organizationId, long customGapId, long actionId, string? notes, string? actor, CancellationToken ct);
    Task<CustomGapCommandResult>    DeleteActionAsync(
        long organizationId, long customGapId, long actionId, string? actor, CancellationToken ct);

    // History
    Task<IReadOnlyList<CustomGapHistoryRow>> ListHistoryAsync(
        long organizationId, long customGapId, CancellationToken cancellationToken);
}

public sealed class CustomGapService(IConfiguration configuration, ILogger<CustomGapService> logger) : ICustomGapService
{
    // -------------------------------------------------------------
    // Legacy list / open / close (from migration 055) -- signatures
    // preserved for the existing gaps.cshtml Custom tab.
    // -------------------------------------------------------------
    public async Task<CustomGapListResult> ListAsync(CustomGapListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_custom_gap_list";

        AddParam(command, "@organization_id",         DbType.Int64,  (object?)query.OrganizationId ?? DBNull.Value);
        AddParam(command, "@status_code",             DbType.String, (object?)query.StatusCode     ?? DBNull.Value, 30);
        AddParam(command, "@priority",                DbType.String, (object?)query.Priority       ?? DBNull.Value, 30);
        AddParam(command, "@owner_employee_id",       DbType.Int64,  (object?)query.OwnerEmployeeId ?? DBNull.Value);
        AddParam(command, "@search",                  DbType.String, (object?)query.Search         ?? DBNull.Value, 200);
        AddParam(command, "@page",                    DbType.Int32,  Math.Max(1, query.Page));
        AddParam(command, "@page_size",               DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));
        // Stage 4b unified filters -- default NULL if the caller
        // did not supply them (existing consumers).
        AddParam(command, "@gap_source_module_code",  DbType.String, (object?)query.GapSourceModuleCode ?? DBNull.Value, 30);
        AddParam(command, "@severity_code",           DbType.String, (object?)query.SeverityCode        ?? DBNull.Value, 30);
        AddParam(command, "@observation_id",          DbType.Int64,  (object?)query.ObservationId       ?? DBNull.Value);
        AddParam(command, "@execution_id",            DbType.Int64,  (object?)query.ExecutionId         ?? DBNull.Value);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        long total = 0;
        int  page  = query.Page;
        int  size  = query.PageSize;
        if (await reader.ReadAsync(cancellationToken))
        {
            total = Convert.ToInt64(reader["TotalCount"]);
            page  = Convert.ToInt32(reader["PageNumber"]);
            size  = Convert.ToInt32(reader["PageSize"]);
        }

        var rows = new List<CustomGapListRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(MapListRow(reader));
        }
        return new CustomGapListResult(total, page, size, rows);
    }

    public async Task<CustomGapCommandResult> OpenAsync(CustomGapOpenRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        // Migration 382: at least one Practice must be mapped to a Custom Gap.
        if (request.PracticeIds is null || request.PracticeIds.Count == 0)
            return new CustomGapCommandResult(false, null,
                "At least one Practice must be mapped to the Custom Gap.", "PRACTICE_REQUIRED");
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_custom_gap_open";

            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@title",             DbType.String, request.Title, 250);
            AddParam(command, "@description",       DbType.String, (object?)request.Description ?? DBNull.Value, -1);
            AddParam(command, "@priority",          DbType.String, (object?)request.Priority    ?? (object)"Medium", 30);
            AddParam(command, "@owner_employee_id", DbType.Int64,  (object?)request.OwnerEmployeeId ?? DBNull.Value);
            AddParam(command, "@due_date",          DbType.Date,   (object?)request.DueDate     ?? DBNull.Value);
            AddParam(command, "@status",            DbType.String, (object?)request.Status      ?? (object)"Open", 30);
            AddParam(command, "@remarks",           DbType.String, (object?)request.Remarks     ?? DBNull.Value, 1000);
            AddParam(command, "@gap_type_code",     DbType.String, (object?)request.GapTypeCode ?? (object)"Custom", 60);
            AddParam(command, "@actor_employee_id", DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            // Migration 250: captured at Add-Gap time. NULLs on a pre-250
            // proc are silently dropped -- the parameter simply won't
            // match anything, and the sproc keeps its old default
            // behaviour (severity later derived, detection method left
            // to the analysis form).
            AddParam(command, "@severity_code",         DbType.String, (object?)request.SeverityCode        ?? DBNull.Value, 30);
            AddParam(command, "@severity_name",         DbType.String, (object?)request.SeverityName        ?? DBNull.Value, 120);
            AddParam(command, "@detection_method_code", DbType.String, (object?)request.DetectionMethodCode ?? DBNull.Value, 60);
            AddParam(command, "@detection_method_name", DbType.String, (object?)request.DetectionMethodName ?? DBNull.Value, 200);
            // Migration 382: JSON array of practice ids to map to this gap.
            AddParam(command, "@practice_ids_json", DbType.String,
                (object?)JsonSerializer.Serialize(request.PracticeIds) ?? DBNull.Value, -1);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@custom_gap_id";
            idOut.DbType        = DbType.Int64;
            idOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idOut);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idOut.Value is long l ? l : Convert.ToInt64(idOut.Value);

            // Migration 189: custom gaps only carry priority at Add Gap
            // time; sp_custom_gap_apply_sla falls back to priority when
            // severity_code is null, so an SLA auto-lands even here.
            await ApplyAutoSlaAsync(id, request.ActorEmployeeId?.ToString() ?? "system", cancellationToken);

            return new CustomGapCommandResult(true, id);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "CustomGapService.OpenAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new CustomGapCommandResult(false, null, ex.Message, reason);
        }
    }

    // Migration 382: read the practices mapped to a Custom Gap.
    public async Task<IReadOnlyList<CustomGapPracticeRow>> GetPracticesAsync(long customGapId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_custom_gap_practice_map_list";
        AddParam(command, "@custom_gap_id", DbType.Int64, customGapId);

        var rows = new List<CustomGapPracticeRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new CustomGapPracticeRow(
                Convert.ToInt64(reader["CustomGapPracticeMapId"]),
                Convert.ToInt64(reader["CustomGapId"]),
                Convert.ToInt64(reader["PracticeId"]),
                reader["PracticeName"] as string,
                reader["PracticeCode"] as string,
                reader["MappedDt"] == DBNull.Value ? (DateTime?)null : Convert.ToDateTime(reader["MappedDt"])));
        }
        return rows;
    }

    public async Task<CustomGapCommandResult> CloseAsync(CustomGapCloseRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_custom_gap_close";

            AddParam(command, "@custom_gap_id",     DbType.Int64,  request.CustomGapId);
            AddParam(command, "@actor_employee_id", DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            AddParam(command, "@remarks",           DbType.String, (object?)request.Remarks ?? DBNull.Value, 1000);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new CustomGapCommandResult(true, request.CustomGapId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "CustomGapService.CloseAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new CustomGapCommandResult(false, null, ex.Message, reason);
        }
    }

    // -------------------------------------------------------------
    // Unified Get / Save / Delete
    // -------------------------------------------------------------
    public async Task<CustomGapDetail?> GetAsync(long organizationId, long customGapId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_custom_gap_get";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@custom_gap_id",   DbType.Int64, customGapId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await reader.ReadAsync(cancellationToken) ? MapDetailRow(reader) : null;
    }

    public async Task<CustomGapSaveResult> SaveAsync(CustomGapSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.Title))
            return new CustomGapSaveResult(false, Error: "Title is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_custom_gap_save";

            AddParam(command, "@organization_id",                DbType.Int64,  request.OrganizationId);
            AddParam(command, "@custom_gap_id",                  DbType.Int64,  (object?)request.CustomGapId ?? DBNull.Value);
            AddParam(command, "@gap_source_module_code",         DbType.String, (object?)request.GapSourceModuleCode ?? (object)"Custom", 30);
            AddParam(command, "@source_reference_type",          DbType.String, (object?)request.SourceReferenceType ?? DBNull.Value, 60);
            AddParam(command, "@source_reference_id",            DbType.Int64,  (object?)request.SourceReferenceId ?? DBNull.Value);
            AddParam(command, "@gap_type_code",                  DbType.String, (object?)request.GapTypeCode ?? DBNull.Value, 60);
            AddParam(command, "@title",                          DbType.String, request.Title.Trim(), 250);
            AddParam(command, "@description",                    DbType.String, (object?)request.Description ?? DBNull.Value, -1);
            AddParam(command, "@priority",                       DbType.String, (object?)request.Priority ?? (object)"Medium", 30);
            AddParam(command, "@severity_code",                  DbType.String, (object?)request.SeverityCode ?? DBNull.Value, 30);
            AddParam(command, "@severity_name",                  DbType.String, (object?)request.SeverityName ?? DBNull.Value, 120);
            AddParam(command, "@owner_employee_id",              DbType.Int64,  (object?)request.OwnerEmployeeId ?? DBNull.Value);
            AddParam(command, "@owner_display_name",             DbType.String, (object?)request.OwnerDisplayName ?? DBNull.Value, 240);
            AddParam(command, "@assigned_reviewer_employee_id",  DbType.Int64,  (object?)request.AssignedReviewerEmployeeId ?? DBNull.Value);
            AddParam(command, "@assigned_reviewer_display_name", DbType.String, (object?)request.AssignedReviewerDisplayName ?? DBNull.Value, 240);
            AddParam(command, "@due_date",                       DbType.Date,   (object?)request.DueDate ?? DBNull.Value);
            AddParam(command, "@target_resolution_date",         DbType.Date,   (object?)request.TargetResolutionDate ?? DBNull.Value);
            AddParam(command, "@remediation_plan",               DbType.String, (object?)request.RemediationPlan ?? DBNull.Value, -1);
            AddParam(command, "@remarks",                        DbType.String, (object?)request.Remarks ?? DBNull.Value, 1000);
            // 116b hybrid role+employee
            AddParam(command, "@owner_role_id",                  DbType.Int64,  (object?)request.OwnerRoleId ?? DBNull.Value);
            AddParam(command, "@owner_role_name",                DbType.String, (object?)request.OwnerRoleName ?? DBNull.Value, 120);
            AddParam(command, "@assigned_reviewer_role_id",      DbType.Int64,  (object?)request.AssignedReviewerRoleId ?? DBNull.Value);
            AddParam(command, "@assigned_reviewer_role_name",    DbType.String, (object?)request.AssignedReviewerRoleName ?? DBNull.Value, 120);
            AddParam(command, "@actor",                          DbType.String, (object?)request.Actor ?? (object)"system", 100);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@custom_gap_id_out";
            idOut.DbType        = DbType.Int64;
            idOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idOut);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idOut.Value is long l ? l : Convert.ToInt64(idOut.Value);

            // Migration 184: auto-apply SLA from Control Management master
            // when severity_code matches a classification for which this
            // org has an Active org_sla_config. Best-effort -- proc no-ops
            // silently when no match, so a missing SLA never blocks a save.
            await ApplyAutoSlaAsync(id, request.Actor, cancellationToken);

            return new CustomGapSaveResult(true, id);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "CustomGapService.SaveAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new CustomGapSaveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // -------------------------------------------------------------
    // Migration 184: SLA auto-match + operator override
    // -------------------------------------------------------------
    public async Task ApplyAutoSlaAsync(long customGapId, string? callerDisplayName, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_custom_gap_apply_sla";
            AddParam(command, "@custom_gap_id",       DbType.Int64,  customGapId);
            AddParam(command, "@caller_display_name", DbType.String, callerDisplayName ?? "system", 100);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        catch (SqlException ex)
        {
            // Best-effort: never fail the caller because the SLA apply
            // could not find a match / hit a transient error.
            logger.LogWarning(ex, "CustomGapService.ApplyAutoSlaAsync warning for gap {GapId}: {Msg}", customGapId, ex.Message);
        }
    }

    public async Task<SlaOverrideRequestResult> RequestSlaOverrideAsync(
        SlaOverrideRequestPayload request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.CustomGapId <= 0)
            return new SlaOverrideRequestResult(false, null, "customGapId is required.");
        if (request.SlaDaysRequested < 0)
            return new SlaOverrideRequestResult(false, null, "slaDaysRequested must be >= 0.");
        if (string.IsNullOrWhiteSpace(request.RequestReason))
            return new SlaOverrideRequestResult(false, null, "requestReason is required.");
        // requestedByEmployeeId is OPTIONAL post-188. Server-side, if
        // the browser did not send one, try resolving from the caller's
        // email (organization_employee.email = callerDisplayName). This
        // rescues Practice Admin sessions that don't carry an
        // employee_id in window.pmEmployeeId.

        long? resolvedRequesterId = request.RequestedByEmployeeId;
        if ((resolvedRequesterId is null or <= 0)
            && !string.IsNullOrWhiteSpace(request.CallerDisplayName)
            && request.CallerDisplayName.Contains('@'))
        {
            try
            {
                await using var lookupConn = await OpenAsync(cancellationToken);
                await using var lookupCmd  = lookupConn.CreateCommand();
                lookupCmd.CommandType = CommandType.Text;
                // Match by email OR employee_code -- covers both login styles.
                lookupCmd.CommandText = @"
                    SELECT TOP 1 employee_id
                      FROM grac_practice.organization_employee
                     WHERE (email = @caller OR employee_code = @caller)
                       AND status = N'Active'
                     ORDER BY employee_id DESC;";
                AddParam(lookupCmd, "@caller", DbType.String, request.CallerDisplayName, 240);
                var v = await lookupCmd.ExecuteScalarAsync(cancellationToken);
                if (v is not null && v != DBNull.Value)
                    resolvedRequesterId = Convert.ToInt64(v);
            }
            catch (SqlException ex)
            {
                logger.LogWarning(ex,
                    "CustomGapService.RequestSlaOverrideAsync: email->employee lookup failed for {Email}; passing null.",
                    request.CallerDisplayName);
            }
        }

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_sla_override_request_create";
            AddParam(command, "@custom_gap_id",            DbType.Int64,  request.CustomGapId);
            AddParam(command, "@sla_days_requested",       DbType.Int32,  request.SlaDaysRequested);
            AddParam(command, "@request_reason",           DbType.String, request.RequestReason.Trim(), -1);
            AddParam(command, "@requested_by_employee_id", DbType.Int64,
                     (resolvedRequesterId is > 0 ? (object)resolvedRequesterId.Value : DBNull.Value));
            AddParam(command, "@caller_display_name",      DbType.String, request.CallerDisplayName ?? "system", 100);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            long? requestId = null;
            if (await reader.ReadAsync(cancellationToken))
                requestId = ReadLongOrNull(reader, "ExceptionRequestId");
            return new SlaOverrideRequestResult(true, requestId, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "CustomGapService.RequestSlaOverrideAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new SlaOverrideRequestResult(false, null, ex.Message);
        }
    }

    public Task<CustomGapCommandResult> DeleteAsync(CustomGapCommandRequest r, CancellationToken ct) =>
        TransitionAsync("grac_practice.sp_custom_gap_delete", r, ct, includeNotes: false);

    public async Task<CustomGapGenerateResult> GenerateFromAssuranceObservationAsync(
        CustomGapGenerateRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.ObservationId <= 0)
            return new CustomGapGenerateResult(false, Error: "ObservationId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_custom_gap_generate_from_assurance_observation";

            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@observation_id",  DbType.Int64,  request.ObservationId);
            AddParam(command, "@actor",           DbType.String, (object?)request.Actor ?? (object)"system", 100);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@custom_gap_id_out";
            idOut.DbType        = DbType.Int64;
            idOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idOut);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idOut.Value is DBNull ? (long?)null
                                            : (idOut.Value is long l ? l : Convert.ToInt64(idOut.Value));

            // Migration 187: severity_code already lands on the new gap
            // (sp_custom_gap_generate_from_assurance_observation copies
            // it from observation.severity_code -- see 116b). Auto-apply
            // SLA immediately so warning / escalation timers are in
            // force before analysis touches the gap.
            if (id is long gapId)
                await ApplyAutoSlaAsync(gapId, request.Actor, cancellationToken);

            return new CustomGapGenerateResult(true, id);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "CustomGapService.GenerateFromAssuranceObservationAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new CustomGapGenerateResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // -------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------
    public Task<CustomGapCommandResult> StartAsync             (CustomGapCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_custom_gap_start",               r, ct, includeNotes: true);
    public Task<CustomGapCommandResult> SubmitRemediationAsync (CustomGapCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_custom_gap_submit_remediation", r, ct, includeNotes: true);
    public Task<CustomGapCommandResult> VerifyAsync            (CustomGapCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_custom_gap_verify",              r, ct, includeNotes: true);
    public Task<CustomGapCommandResult> CloseLifecycleAsync    (CustomGapCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_custom_gap_close_lifecycle",    r, ct, includeNotes: true);
    public Task<CustomGapCommandResult> ReopenAsync            (CustomGapCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_custom_gap_reopen",              r, ct, includeNotes: true);

    private async Task<CustomGapCommandResult> TransitionAsync(
        string procName, CustomGapCommandRequest request,
        CancellationToken cancellationToken, bool includeNotes)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.CustomGapId <= 0)
            return new CustomGapCommandResult(false, null, "CustomGapId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = procName;

            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@custom_gap_id",   DbType.Int64,  request.CustomGapId);
            if (includeNotes)
                AddParam(command, "@notes", DbType.String, (object?)request.Notes ?? DBNull.Value, -1);
            AddParam(command, "@actor", DbType.String, (object?)request.Actor ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new CustomGapCommandResult(true, request.CustomGapId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "CustomGapService.{Proc} SQL error {Number}: {Message}", procName, ex.Number, ex.Message);
            return new CustomGapCommandResult(false, null, ex.Message, reason);
        }
    }

    // -------------------------------------------------------------
    // Junction
    // -------------------------------------------------------------
    public async Task<IReadOnlyList<CustomGapObservationLinkRow>> ListLinkedObservationsAsync(
        long organizationId, long customGapId, bool includeDetached, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_custom_gap_observation_list";

        AddParam(command, "@organization_id",  DbType.Int64,   organizationId);
        AddParam(command, "@custom_gap_id",    DbType.Int64,   customGapId);
        AddParam(command, "@include_detached", DbType.Boolean, includeDetached);

        var rows = new List<CustomGapObservationLinkRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(MapLinkForGap(reader));
        return rows;
    }

    public async Task<IReadOnlyList<CustomGapObservationLinkRow>> ListLinkedGapsForObservationAsync(
        long organizationId, long observationId, bool includeDetached, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_observation_linked_custom_gaps_list";

        AddParam(command, "@organization_id",  DbType.Int64,   organizationId);
        AddParam(command, "@observation_id",   DbType.Int64,   observationId);
        AddParam(command, "@include_detached", DbType.Boolean, includeDetached);

        var rows = new List<CustomGapObservationLinkRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(MapLinkForObservation(reader, observationId));
        return rows;
    }

    public async Task<CustomGapAttachResult> AttachObservationAsync(CustomGapAttachRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.CustomGapId <= 0 || request.ObservationId <= 0)
            return new CustomGapAttachResult(false, Error: "CustomGapId and ObservationId are required.");
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_custom_gap_observation_attach";

            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@custom_gap_id",   DbType.Int64,  request.CustomGapId);
            AddParam(command, "@observation_id",  DbType.Int64,  request.ObservationId);
            AddParam(command, "@link_source",     DbType.String, (object?)request.LinkSource ?? (object)"MANUAL", 30);
            AddParam(command, "@notes",           DbType.String, (object?)request.Notes ?? DBNull.Value, 1000);
            AddParam(command, "@actor",           DbType.String, (object?)request.Actor ?? (object)"system", 100);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@junction_id_out";
            idOut.DbType        = DbType.Int64;
            idOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idOut);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idOut.Value is long l ? l : Convert.ToInt64(idOut.Value);
            return new CustomGapAttachResult(true, id);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "CustomGapService.AttachObservationAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new CustomGapAttachResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    public async Task<CustomGapCommandResult> DetachObservationAsync(CustomGapDetachRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.CustomGapId <= 0 || request.ObservationId <= 0)
            return new CustomGapCommandResult(false, null, "CustomGapId and ObservationId are required.");
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_custom_gap_observation_detach";

            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@custom_gap_id",   DbType.Int64,  request.CustomGapId);
            AddParam(command, "@observation_id",  DbType.Int64,  request.ObservationId);
            AddParam(command, "@reason",          DbType.String, (object?)request.Reason ?? DBNull.Value, 1000);
            AddParam(command, "@actor",           DbType.String, (object?)request.Actor  ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new CustomGapCommandResult(true, request.CustomGapId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "CustomGapService.DetachObservationAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new CustomGapCommandResult(false, null, ex.Message, reason);
        }
    }

    public async Task<CustomGapMergeResult> MergeGapsAsync(CustomGapMergeRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.SourceCustomGapId <= 0 || request.TargetCustomGapId <= 0)
            return new CustomGapMergeResult(false, Error: "SourceCustomGapId and TargetCustomGapId are required.");
        if (request.SourceCustomGapId == request.TargetCustomGapId)
            return new CustomGapMergeResult(false, Error: "Cannot merge a gap into itself.");
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_custom_gap_merge";

            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@source_gap_id",   DbType.Int64,  request.SourceCustomGapId);
            AddParam(command, "@target_gap_id",   DbType.Int64,  request.TargetCustomGapId);
            AddParam(command, "@reason",          DbType.String, (object?)request.Reason ?? DBNull.Value, 1000);
            AddParam(command, "@actor",           DbType.String, (object?)request.Actor  ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new CustomGapMergeResult(true, request.TargetCustomGapId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "CustomGapService.MergeGapsAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new CustomGapMergeResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // -------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------
    public async Task<IReadOnlyList<CustomGapActionRow>> ListActionsAsync(
        long organizationId, long customGapId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_custom_gap_action_list";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@custom_gap_id",   DbType.Int64, customGapId);

        var rows = new List<CustomGapActionRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(MapActionRow(reader));
        return rows;
    }

    public async Task<CustomGapActionSaveResult> SaveActionAsync(CustomGapActionSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.ActionTitle))
            return new CustomGapActionSaveResult(false, Error: "ActionTitle is required.");
        if (request.CustomGapId <= 0)
            return new CustomGapActionSaveResult(false, Error: "CustomGapId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_custom_gap_action_save";

            AddParam(command, "@organization_id",       DbType.Int64,  request.OrganizationId);
            AddParam(command, "@custom_gap_id",         DbType.Int64,  request.CustomGapId);
            AddParam(command, "@action_id",             DbType.Int64,  (object?)request.ActionId ?? DBNull.Value);
            AddParam(command, "@action_order",          DbType.Int32,  request.ActionOrder);
            AddParam(command, "@action_title",          DbType.String, request.ActionTitle.Trim(), 300);
            AddParam(command, "@action_description",    DbType.String, (object?)request.ActionDescription ?? DBNull.Value, -1);
            AddParam(command, "@assigned_employee_id",  DbType.Int64,  (object?)request.AssignedEmployeeId ?? DBNull.Value);
            AddParam(command, "@assigned_display_name", DbType.String, (object?)request.AssignedDisplayName ?? DBNull.Value, 240);
            AddParam(command, "@due_date",              DbType.Date,   (object?)request.DueDate ?? DBNull.Value);
            AddParam(command, "@action_status_code",    DbType.String, (object?)request.ActionStatusCode ?? (object)"Pending", 30);
            AddParam(command, "@notes",                 DbType.String, (object?)request.Notes ?? DBNull.Value, -1);
            // 116b hybrid role+employee
            AddParam(command, "@assigned_role_id",      DbType.Int64,  (object?)request.AssignedRoleId ?? DBNull.Value);
            AddParam(command, "@assigned_role_name",    DbType.String, (object?)request.AssignedRoleName ?? DBNull.Value, 120);
            AddParam(command, "@actor",                 DbType.String, (object?)request.Actor ?? (object)"system", 100);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@action_id_out";
            idOut.DbType        = DbType.Int64;
            idOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idOut);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idOut.Value is long l ? l : Convert.ToInt64(idOut.Value);
            return new CustomGapActionSaveResult(true, id);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "CustomGapService.SaveActionAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new CustomGapActionSaveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    public async Task<CustomGapCommandResult> CompleteActionAsync(
        long organizationId, long customGapId, long actionId, string? notes, string? actor, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_custom_gap_action_complete";

            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@custom_gap_id",   DbType.Int64,  customGapId);
            AddParam(command, "@action_id",       DbType.Int64,  actionId);
            AddParam(command, "@notes",           DbType.String, (object?)notes ?? DBNull.Value, -1);
            AddParam(command, "@actor",           DbType.String, (object?)actor ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new CustomGapCommandResult(true, actionId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "CustomGapService.CompleteActionAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new CustomGapCommandResult(false, null, ex.Message, reason);
        }
    }

    public async Task<CustomGapCommandResult> DeleteActionAsync(
        long organizationId, long customGapId, long actionId, string? actor, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_custom_gap_action_delete";

            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@custom_gap_id",   DbType.Int64,  customGapId);
            AddParam(command, "@action_id",       DbType.Int64,  actionId);
            AddParam(command, "@actor",           DbType.String, (object?)actor ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new CustomGapCommandResult(true, actionId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "CustomGapService.DeleteActionAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new CustomGapCommandResult(false, null, ex.Message, reason);
        }
    }

    // -------------------------------------------------------------
    // History
    // -------------------------------------------------------------
    public async Task<IReadOnlyList<CustomGapHistoryRow>> ListHistoryAsync(
        long organizationId, long customGapId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_custom_gap_history_list";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@custom_gap_id",   DbType.Int64, customGapId);

        var rows = new List<CustomGapHistoryRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new CustomGapHistoryRow(
                Convert.ToInt64(reader["HistoryId"]),
                reader["ActionCode"]?.ToString() ?? "",
                ReadStringOrNull(reader, "FromStatusCode"),
                ReadStringOrNull(reader, "ToStatusCode"),
                ReadStringOrNull(reader, "ReasonText"),
                ReadStringOrNull(reader, "ActorDisplayName"),
                ReadStringOrNull(reader, "EnteredBy"),
                ReadDateTimeOrNull(reader, "EnteredDt")));
        }
        return rows;
    }

    // -------------------------------------------------------------
    // Migration 255 -- the unified Gap Centre list
    //
    // ListAsync above is left exactly as it was. It still backs
    // /api/practice/gaps/custom, which the assurance-observation screens
    // and the by-observation route call with their own filters; this is a
    // second, wider read, not a replacement for it.
    // -------------------------------------------------------------
    public async Task<GapCentreListResult> ListGapCentreAsync(
        GapCentreListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_gap_centre_list";

            AddParam(command, "@organization_id",    DbType.Int64,  (object?)query.OrganizationId ?? DBNull.Value);
            AddParam(command, "@source_module_code", DbType.String, (object?)query.SourceModuleCode ?? DBNull.Value, 30);
            AddParam(command, "@status_code",        DbType.String, (object?)query.StatusCode ?? DBNull.Value, 30);
            AddParam(command, "@search",             DbType.String, (object?)query.Search ?? DBNull.Value, 200);
            AddParam(command, "@observation_id",     DbType.Int64,  (object?)query.ObservationId ?? DBNull.Value);
            AddParam(command, "@page",               DbType.Int32,  Math.Max(1, query.Page));
            AddParam(command, "@page_size",          DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);

            long total = 0;
            int  page  = query.Page;
            int  size  = query.PageSize;
            if (await reader.ReadAsync(cancellationToken))
            {
                total = Convert.ToInt64(reader["TotalCount"]);
                page  = Convert.ToInt32(reader["PageNumber"]);
                size  = Convert.ToInt32(reader["PageSize"]);
            }

            var rows = new List<GapCentreListRow>();
            if (await reader.NextResultAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                    rows.Add(new GapCentreListRow(
                        RowKey:             reader["RowKey"]?.ToString() ?? "",
                        SourceModuleCode:   reader["SourceModuleCode"]?.ToString() ?? "",
                        CustomGapId:        ReadLongOrNull(reader, "CustomGapId"),
                        PracticeGapId:      ReadLongOrNull(reader, "PracticeGapId"),
                        PracticeInstanceId: ReadLongOrNull(reader, "PracticeInstanceId"),
                        IsMaterialized:     reader["IsMaterialized"] is bool m && m,
                        Title:              ReadStringOrNull(reader, "Title"),
                        Context:            ReadStringOrNull(reader, "Context"),
                        StatusText:         ReadStringOrNull(reader, "StatusText"),
                        SeverityText:       ReadStringOrNull(reader, "SeverityText"),
                        OwnerText:          ReadStringOrNull(reader, "OwnerText"),
                        DueDate:            ReadDateTimeOrNull(reader, "DueDate"),
                        OpenedDt:           ReadDateTimeOrNull(reader, "OpenedDt"),
                        LinkedCount:        ReadIntOrNull(reader, "LinkedCount") ?? 0,
                        InstanceCode:       ReadStringOrNull(reader, "InstanceCode"),
                        InstanceName:       ReadStringOrNull(reader, "InstanceName"),
                        ExistingTaskCount:  ReadIntOrNull(reader, "ExistingTaskCount") ?? 0,
                        // Migration 318. Absent on a pre-318 database --
                        // HasColumn-guarded the same way the rest of this
                        // reader tolerates schema this call predates.
                        RawStatusCode:      HasColumn(reader, "RawStatusCode") ? ReadStringOrNull(reader, "RawStatusCode") : null,
                        // Migration 324. Same HasColumn guard for a
                        // pre-324 database.
                        LifecycleStateCode: HasColumn(reader, "LifecycleStateCode") ? ReadStringOrNull(reader, "LifecycleStateCode") : null,
                        // Migration 371. Practice Instance / Task / Risk /
                        // Exception status columns -- HasColumn-guarded the
                        // same way for a pre-371 database.
                        PracticeInstanceStatusText: HasColumn(reader, "PracticeInstanceStatusText") ? ReadStringOrNull(reader, "PracticeInstanceStatusText") : null,
                        TaskStatusText:             HasColumn(reader, "TaskStatusText") ? ReadStringOrNull(reader, "TaskStatusText") : null,
                        RiskStatusText:             HasColumn(reader, "RiskStatusText") ? ReadStringOrNull(reader, "RiskStatusText") : null,
                        ExceptionStatusText:        HasColumn(reader, "ExceptionStatusText") ? ReadStringOrNull(reader, "ExceptionStatusText") : null));
            }
            return new GapCentreListResult(total, page, size, rows);
        }
        catch (SqlException ex)
        {
            logger.LogError(ex, "sp_gap_centre_list failed for organization {OrgId}.", query.OrganizationId);
            // 2812 = "Could not find stored procedure". Named explicitly
            // because an un-applied migration is by far the likeliest
            // cause here, and "HTTP 500" on its own sends people looking
            // at the wrong layer.
            var message = ex.Number == 2812
                ? "Gap Centre list procedure is missing. Run database migration "
                  + "255_gap_centre_unified_list.sql."
                : ex.Message;
            return new GapCentreListResult(0, query.Page, query.PageSize, [], message);
        }
    }

    public async Task<IReadOnlyList<GapCentreSourceCount>> ListGapCentreSourcesAsync(
        long? organizationId, CancellationToken cancellationToken)
    {
        // Non-fatal by contract: the screen treats an empty list as "no
        // filter options" and still renders the grid, so a missing
        // migration degrades the dropdown rather than the page.
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_gap_centre_source_counts";
            AddParam(command, "@organization_id", DbType.Int64, (object?)organizationId ?? DBNull.Value);

            var rows = new List<GapCentreSourceCount>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(new GapCentreSourceCount(
                    reader["SourceModuleCode"]?.ToString() ?? "",
                    Convert.ToInt32(reader["DisplayOrder"]),
                    Convert.ToInt64(reader["GapCount"])));
            return rows;
        }
        catch (SqlException ex)
        {
            logger.LogError(ex, "sp_gap_centre_source_counts failed for organization {OrgId}.", organizationId);
            return [];
        }
    }

    // -------------------------------------------------------------
    // Helpers + Mappers
    // -------------------------------------------------------------
    private async Task<DbConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connString = Infrastructure.SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connString))
            throw new InvalidOperationException("PracticeManagement connection string is not configured.");
        var connection = new SqlConnection(connString);
        await connection.OpenAsync(cancellationToken);
        return connection;
    }

    private static void AddParam(DbCommand command, string name, DbType type, object? value, int? size = null)
    {
        var p = command.CreateParameter();
        p.ParameterName = name;
        p.DbType        = type;
        if (size.HasValue) p.Size = size.Value;
        p.Value = value ?? DBNull.Value;
        command.Parameters.Add(p);
    }

    private static long?    ReadLongOrNull(DbDataReader r, string col)     => r[col] == DBNull.Value ? null : Convert.ToInt64(r[col]);
    private static int?     ReadIntOrNull(DbDataReader r, string col)      => r[col] == DBNull.Value ? null : Convert.ToInt32(r[col]);
    private static DateTime? ReadDateTimeOrNull(DbDataReader r, string col)=> r[col] == DBNull.Value ? null : Convert.ToDateTime(r[col]);
    private static string?  ReadStringOrNull(DbDataReader r, string col)   => r[col] == DBNull.Value ? null : r[col].ToString();

    // Migration 318: sp_gap_centre_list's RawStatusCode column is new, so
    // a pre-318 database still returns the pre-318 shape. Same
    // GetOrdinal-by-name tolerant-column check used elsewhere in the API
    // (GapLifecycleService/ResolveWorkspaceService/etc.) -- an unguarded
    // reader[col] on a missing column throws and takes the whole list
    // down instead of degrading the one new field.
    private static bool HasColumn(DbDataReader r, string name)
    {
        for (var i = 0; i < r.FieldCount; i++)
            if (string.Equals(r.GetName(i), name, StringComparison.OrdinalIgnoreCase))
                return true;
        return false;
    }

    private static CustomGapListRow MapListRow(DbDataReader r) => new(
        Convert.ToInt64(r["custom_gap_id"]),
        Convert.ToInt64(r["organization_id"]),
        r["gap_type_code"]?.ToString() ?? "",
        r["title"]?.ToString() ?? "",
        ReadStringOrNull(r, "description"),
        r["priority"]?.ToString() ?? "",
        ReadLongOrNull(r, "owner_employee_id"),
        ReadDateTimeOrNull(r, "due_date"),
        r["status"]?.ToString() ?? "",
        ReadStringOrNull(r, "remarks"),
        ReadLongOrNull(r, "linked_task_id"),
        Convert.ToDateTime(r["entered_dt"]),
        r["entered_by"]?.ToString() ?? "",
        // Stage 4b extensions
        ReadStringOrNull(r, "gap_source_module_code"),
        ReadStringOrNull(r, "source_reference_type"),
        ReadLongOrNull(r,   "source_reference_id"),
        ReadStringOrNull(r, "severity_code"),
        ReadStringOrNull(r, "severity_name"),
        ReadStringOrNull(r, "owner_display_name"),
        ReadStringOrNull(r, "assigned_reviewer_display_name"),
        ReadDateTimeOrNull(r, "target_resolution_date"),
        ReadStringOrNull(r, "execution_code"),
        ReadStringOrNull(r, "execution_name"),
        ReadStringOrNull(r, "entity_dimension_code"),
        ReadStringOrNull(r, "entity_dimension_name"),
        ReadStringOrNull(r, "entity_code"),
        ReadStringOrNull(r, "entity_name"),
        ReadStringOrNull(r, "observation_code"),
        ReadStringOrNull(r, "observation_title"),
        ReadDateTimeOrNull(r, "opened_dt"),
        ReadDateTimeOrNull(r, "closed_dt"),
        ReadLongOrNull(r,   "risk_id"),
        Convert.ToInt64(r["linked_observation_count"]),
        Convert.ToInt64(r["action_count"]),
        Convert.ToInt64(r["action_completed_count"]),
        // 116b hybrid role+employee
        ReadLongOrNull(r,   "owner_role_id"),
        ReadStringOrNull(r, "owner_role_name"),
        ReadLongOrNull(r,   "assigned_reviewer_role_id"),
        ReadStringOrNull(r, "assigned_reviewer_role_name"));

    private static CustomGapDetail MapDetailRow(DbDataReader r) => new(
        Convert.ToInt64(r["custom_gap_id"]),
        Convert.ToInt64(r["organization_id"]),
        r["gap_type_code"]?.ToString() ?? "",
        r["gap_source_module_code"]?.ToString() ?? "Custom",
        ReadStringOrNull(r, "source_reference_type"),
        ReadLongOrNull(r,   "source_reference_id"),
        r["title"]?.ToString() ?? "",
        ReadStringOrNull(r, "description"),
        r["priority"]?.ToString() ?? "",
        ReadStringOrNull(r, "severity_code"),
        ReadStringOrNull(r, "severity_name"),
        ReadLongOrNull(r,   "owner_employee_id"),
        ReadStringOrNull(r, "owner_display_name"),
        ReadLongOrNull(r,   "owner_role_id"),
        ReadStringOrNull(r, "owner_role_name"),
        ReadLongOrNull(r,   "assigned_reviewer_employee_id"),
        ReadStringOrNull(r, "assigned_reviewer_display_name"),
        ReadLongOrNull(r,   "assigned_reviewer_role_id"),
        ReadStringOrNull(r, "assigned_reviewer_role_name"),
        ReadDateTimeOrNull(r, "due_date"),
        ReadDateTimeOrNull(r, "target_resolution_date"),
        r["status"]?.ToString() ?? "",
        ReadStringOrNull(r, "execution_code"),
        ReadStringOrNull(r, "execution_name"),
        ReadStringOrNull(r, "entity_dimension_code"),
        ReadStringOrNull(r, "entity_dimension_name"),
        ReadStringOrNull(r, "entity_code"),
        ReadStringOrNull(r, "entity_name"),
        ReadStringOrNull(r, "observation_code"),
        ReadStringOrNull(r, "observation_title"),
        ReadDateTimeOrNull(r, "opened_dt"),
        ReadDateTimeOrNull(r, "remediation_submitted_dt"),
        ReadDateTimeOrNull(r, "verified_dt"),
        ReadDateTimeOrNull(r, "closed_dt"),
        ReadDateTimeOrNull(r, "reopened_dt"),
        ReadStringOrNull(r, "remediation_plan"),
        ReadStringOrNull(r, "resolution_notes"),
        ReadStringOrNull(r, "verification_notes"),
        ReadStringOrNull(r, "closure_notes"),
        ReadStringOrNull(r, "remarks"),
        ReadLongOrNull(r,   "linked_task_id"),
        ReadLongOrNull(r,   "risk_id"),
        ReadStringOrNull(r, "entered_by"),
        ReadDateTimeOrNull(r, "entered_dt"),
        ReadStringOrNull(r, "updated_by"),
        ReadDateTimeOrNull(r, "updated_dt"),
        Convert.ToInt64(r["LinkedObservationCount"]));

    private static CustomGapObservationLinkRow MapLinkForGap(DbDataReader r) => new(
        Convert.ToInt64(r["JunctionId"]),
        Convert.ToInt64(r["GapId"]),
        Convert.ToInt64(r["ObservationId"]),
        ReadStringOrNull(r, "ObservationCode"),
        ReadStringOrNull(r, "ObservationTitle"),
        ReadStringOrNull(r, "SeverityCode"),
        ReadStringOrNull(r, "SeverityName"),
        ReadStringOrNull(r, "ObservationStatusCode"),
        ReadStringOrNull(r, "ObservationStatusName"),
        ReadStringOrNull(r, "ExecutionCode"),
        ReadStringOrNull(r, "ExecutionName"),
        ReadStringOrNull(r, "EntityName"),
        null, null, null,
        r["LinkSource"]?.ToString() ?? "",
        r["LinkedBy"]?.ToString()   ?? "",
        Convert.ToDateTime(r["LinkedDt"]),
        ReadStringOrNull(r, "Notes"),
        Convert.ToBoolean(r["IsActive"]),
        ReadStringOrNull(r, "DetachBy"),
        ReadDateTimeOrNull(r, "DetachDt"),
        ReadStringOrNull(r, "DetachReason"));

    private static CustomGapObservationLinkRow MapLinkForObservation(DbDataReader r, long observationId) => new(
        Convert.ToInt64(r["JunctionId"]),
        Convert.ToInt64(r["GapId"]),
        observationId,
        null, null,
        ReadStringOrNull(r, "SeverityCode"),
        ReadStringOrNull(r, "SeverityName"),
        null, null, null, null, null,
        ReadStringOrNull(r, "GapTitle"),
        ReadStringOrNull(r, "SourceModule"),
        ReadStringOrNull(r, "GapStatusCode"),
        r["LinkSource"]?.ToString() ?? "",
        r["LinkedBy"]?.ToString()   ?? "",
        Convert.ToDateTime(r["LinkedDt"]),
        ReadStringOrNull(r, "Notes"),
        Convert.ToBoolean(r["IsActive"]),
        ReadStringOrNull(r, "DetachBy"),
        ReadDateTimeOrNull(r, "DetachDt"),
        ReadStringOrNull(r, "DetachReason"));

    private static CustomGapActionRow MapActionRow(DbDataReader r) => new(
        Convert.ToInt64(r["ActionId"]),
        Convert.ToInt64(r["GapId"]),
        Convert.ToInt32(r["ActionOrder"]),
        r["ActionTitle"]?.ToString() ?? "",
        ReadStringOrNull(r, "ActionDescription"),
        ReadLongOrNull(r,   "AssignedEmployeeId"),
        ReadStringOrNull(r, "AssignedDisplayName"),
        ReadDateTimeOrNull(r, "DueDate"),
        ReadDateTimeOrNull(r, "CompletedDt"),
        r["ActionStatusCode"]?.ToString() ?? "",
        ReadLongOrNull(r,   "TaskId"),
        ReadStringOrNull(r, "Notes"),
        ReadStringOrNull(r, "EnteredBy"),
        ReadDateTimeOrNull(r, "EnteredDt"),
        ReadStringOrNull(r, "UpdatedBy"),
        ReadDateTimeOrNull(r, "UpdatedDt"),
        // 116b hybrid role+employee
        ReadLongOrNull(r,   "AssignedRoleId"),
        ReadStringOrNull(r, "AssignedRoleName"));

    // THROW numbers used in 112 (55000-55099).
    private static string MapReason(int errorNumber) => errorNumber switch
    {
        55000 => "IDS_REQUIRED",
        55001 => "ORGANIZATION_ID_REQUIRED",
        55002 => "TITLE_REQUIRED",
        55003 => "INVALID_SOURCE_MODULE",
        55004 => "GAP_NOT_FOUND",
        55005 => "GAP_WRONG_ORGANIZATION",
        55006 => "NOT_EDITABLE_IN_STATUS",
        55007 => "DELETE_NOT_ALLOWED_IN_STATUS",
        55008 => "ILLEGAL_TRANSITION",
        55010 => "GENERATE_IDS_REQUIRED",
        55011 => "OBSERVATION_NOT_FOUND",
        55012 => "OBSERVATION_WRONG_ORGANIZATION",
        55013 => "OBSERVATION_NOT_ACCEPTED",
        55020 => "JUNCTION_IDS_REQUIRED",
        55021 => "INVALID_LINK_SOURCE",
        55022 => "JUNCTION_OBSERVATION_NOT_FOUND",
        55023 => "JUNCTION_OBSERVATION_WRONG_ORGANIZATION",
        55024 => "JUNCTION_ROW_NOT_FOUND",
        55030 => "MERGE_IDS_REQUIRED",
        55031 => "MERGE_SELF_REJECTED",
        55032 => "MERGE_SOURCE_NOT_FOUND",
        55033 => "MERGE_SOURCE_WRONG_ORGANIZATION",
        55034 => "MERGE_SOURCE_CLOSED",
        55035 => "MERGE_TARGET_NOT_FOUND",
        55036 => "MERGE_TARGET_WRONG_ORGANIZATION",
        55037 => "MERGE_TARGET_CLOSED",
        55040 => "ACTION_IDS_REQUIRED",
        55041 => "ACTION_TITLE_REQUIRED",
        55042 => "INVALID_ACTION_STATUS",
        55043 => "ACTIONS_LOCKED_ON_CLOSED",
        55044 => "ACTION_NOT_FOUND",
        55045 => "ACTION_GAP_MISMATCH",
        55050 => "HISTORY_IDS_REQUIRED",
        _     => "SQL_ERROR"
    };
}
