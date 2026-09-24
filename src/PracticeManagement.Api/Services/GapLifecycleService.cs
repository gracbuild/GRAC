// =====================================================================
// GapLifecycleService  (charter §5)  -- Gap Centre v1.0
//
// Thin facade over grac_practice.sp_custom_gap_lifecycle_* and
// sp_custom_gap_analysis_* / sp_custom_gap_downstream_link_* procs.
//
// Independent from the existing CustomGapService per AES §3 (Prefer
// extension over replacement) -- this service ADDS lifecycle+analysis
// capabilities without altering the legacy Custom Gap surface.
//
// Wire-up: GapLifecycleServiceRegistration.cs
//     builder.Services.AddPracticeGapLifecycleService();
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IGapLifecycleService
{
    Task<GapMaterializeResult>                 MaterializeFromInstanceAsync(GapMaterializeFromInstanceRequest request, CancellationToken ct);
    Task<GapHeader?>                           GetHeaderAsync(long customGapId, CancellationToken ct);
    Task<IReadOnlyList<GapLifecycleStateRow>>  ListStatesAsync(CancellationToken ct);
    Task<IReadOnlyList<GapLifecycleActionRow>> ListActionsFromAsync(string fromStateCode, CancellationToken ct);

    Task<GapLifecycleTransitionResult> TransitionAsync(long customGapId, GapLifecycleTransitionRequest request, CancellationToken ct);

    Task<GapAnalysisModel?>       GetAnalysisAsync(long customGapId, CancellationToken ct);
    Task<GapAnalysisSaveResult>   SaveAnalysisAsync(long customGapId, GapAnalysisSaveRequest request, CancellationToken ct);

    Task<IReadOnlyList<GapDownstreamLinkRow>> ListDownstreamAsync(long customGapId, bool includeCancelled, CancellationToken ct);
    Task<long>                                 AddDownstreamAsync(long customGapId, GapDownstreamLinkAddRequest request, CancellationToken ct);
    Task<bool>                                 CancelDownstreamAsync(long linkId, GapDownstreamLinkCancelRequest request, CancellationToken ct);
    Task<GapLinkedArtefactsResult>             ListLinkedArtefactsAsync(long customGapId, CancellationToken ct);
}

public sealed class GapLifecycleService(IConfiguration configuration, ILogger<GapLifecycleService> logger)
    : IGapLifecycleService
{
    // -------- materialize (on demand for Implementation gaps) --------

    public async Task<GapMaterializeResult> MaterializeFromInstanceAsync(GapMaterializeFromInstanceRequest request, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.PracticeInstanceId <= 0 || request.OrganizationId <= 0)
            return new GapMaterializeResult(false, null, false, "PracticeInstanceId and OrganizationId are required.");

        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_custom_gap_materialize_for_instance");
            AddParam(cmd, "@practice_instance_id", DbType.Int64,  request.PracticeInstanceId);
            AddParam(cmd, "@organization_id",      DbType.Int64,  request.OrganizationId);
            AddParam(cmd, "@caller_employee_id",   DbType.Int64,  (object?)request.CallerEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",  DbType.String, request.CallerDisplayName ?? "system", 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            long? gapId = null;
            bool  created = false;
            if (await r.ReadAsync(ct))
            {
                gapId   = Convert.ToInt64(r["CustomGapId"]);
                created = Convert.ToBoolean(r["Created"]);
            }
            // Reader must be closed before we can issue another command
            // on the same connection. Using `await using` above -- fine
            // once we exit the reader scope by hitting the next `await`
            // on a fresh command below.
            if (gapId is null)
                return new GapMaterializeResult(false, null, false, "Materialize returned no row.");

            // Migration 187: severity_code now travels on the new
            // custom_gap row (copied from practice_instance.criticality).
            // Auto-apply SLA immediately so warning / escalation timers
            // are in force without waiting for analysis. Best-effort --
            // no-ops silently when no matching org_sla_config exists.
            await ApplyAutoSlaAsync(gapId.Value, request.CallerDisplayName, ct);

            return new GapMaterializeResult(true, gapId, created, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "GapLifecycleService.MaterializeFromInstance failed for {InstanceId}: {Msg}",
                request.PracticeInstanceId, ex.Message);
            return new GapMaterializeResult(false, null, false, ex.Message);
        }
    }

    // -------- header (bootstrap context) --------

    public async Task<GapHeader?> GetHeaderAsync(long customGapId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_custom_gap_header");
        AddParam(cmd, "@custom_gap_id", DbType.Int64, customGapId);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        return new GapHeader(
            Convert.ToInt64(r["CustomGapId"]),
            Convert.ToInt64(r["OrganizationId"]),
            r["Title"]?.ToString() ?? "",
            r["Description"] as string,
            r["StatusCode"] as string,
            r["Priority"] as string,
            r["SeverityCode"] as string,
            r["SeverityName"] as string,
            r["OwnerName"] as string,
            r["OwnerEmployeeId"] as long?,
            r["DueDate"] as DateTime?,
            r["LifecycleStateCode"] as string,
            r["LifecycleStateName"] as string,
            r["LifecycleIsTerminal"] is null || r["LifecycleIsTerminal"] is DBNull
                ? false : Convert.ToBoolean(r["LifecycleIsTerminal"]),
            r["LifecycleIsValidTerminal"] is null || r["LifecycleIsValidTerminal"] is DBNull
                ? false : Convert.ToBoolean(r["LifecycleIsValidTerminal"]),
            r["SourceModuleCode"] as string,
            // Migration 177: parent-gap linkage + invalid rationale.
            // Columns may be absent on a pre-177 server, so tolerate.
            HasColumn(r, "DuplicateOfGapId")     ? r["DuplicateOfGapId"]     as long?   : null,
            HasColumn(r, "DuplicateOfGapTitle")  ? r["DuplicateOfGapTitle"]  as string  : null,
            HasColumn(r, "InvalidReason")        ? r["InvalidReason"]        as string  : null,
            // Migration 185: SLA snapshot + pending-override flag. Also
            // tolerant of pre-185 servers where the columns don't exist.
            HasColumn(r, "SlaMasterId")       && r["SlaMasterId"]       != DBNull.Value ? Convert.ToInt64(r["SlaMasterId"])   : (long?)null,
            HasColumn(r, "SlaMasterName")     && r["SlaMasterName"]     != DBNull.Value ? r["SlaMasterName"]?.ToString()      : null,
            HasColumn(r, "SlaDaysEffective")  && r["SlaDaysEffective"]  != DBNull.Value ? Convert.ToInt32(r["SlaDaysEffective"]) : (int?)null,
            HasColumn(r, "SlaSourceCode")     && r["SlaSourceCode"]     != DBNull.Value ? r["SlaSourceCode"]?.ToString()      : null,
            HasColumn(r, "SlaOverridePending")&& r["SlaOverridePending"]!= DBNull.Value ? Convert.ToBoolean(r["SlaOverridePending"]) : false,
            // Migration 250: detection method captured at Add Gap.
            // Guarded so a pre-250 header proc still binds.
            HasColumn(r, "DetectionMethodCode") ? r["DetectionMethodCode"] as string : null,
            HasColumn(r, "DetectionMethodName") ? r["DetectionMethodName"] as string : null,
            // Migration 321: linked Practice Instance. Guarded so a
            // pre-321 header proc still binds.
            HasColumn(r, "PracticeInstanceId")   && r["PracticeInstanceId"]   != DBNull.Value ? Convert.ToInt64(r["PracticeInstanceId"]) : (long?)null,
            HasColumn(r, "PracticeInstanceCode") ? r["PracticeInstanceCode"] as string : null,
            HasColumn(r, "PracticeInstanceName") ? r["PracticeInstanceName"] as string : null,
            // Migration 325: Identified Date. Guarded so a pre-325 header
            // proc still binds.
            HasColumn(r, "IdentifiedDate") && r["IdentifiedDate"] != DBNull.Value ? Convert.ToDateTime(r["IdentifiedDate"]) : (DateTime?)null,
            // Migration 367: Practice Instance Operationalized flag.
            // Guarded so a pre-367 header proc still binds.
            HasColumn(r, "IsPracticeOperationalized") && r["IsPracticeOperationalized"] != DBNull.Value ? Convert.ToBoolean(r["IsPracticeOperationalized"]) : (bool?)null);
    }

    // Tolerant column-presence check for forward/back compatibility with
    // the header proc's schema across migrations.
    private static bool HasColumn(System.Data.Common.DbDataReader r, string name)
    {
        for (int i = 0; i < r.FieldCount; i++)
            if (string.Equals(r.GetName(i), name, StringComparison.OrdinalIgnoreCase))
                return true;
        return false;
    }

    // -------- lookups --------

    public async Task<IReadOnlyList<GapLifecycleStateRow>> ListStatesAsync(CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_custom_gap_lifecycle_states");
        var rows = new List<GapLifecycleStateRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new GapLifecycleStateRow(
                Convert.ToInt32(r["LifecycleStateId"]),
                r["StateCode"]?.ToString() ?? "",
                r["StateName"]?.ToString() ?? "",
                r["Description"] as string,
                Convert.ToInt32(r["SortOrder"]),
                Convert.ToBoolean(r["IsTerminal"]),
                Convert.ToBoolean(r["IsValidTerminal"])));
        return rows;
    }

    public async Task<IReadOnlyList<GapLifecycleActionRow>> ListActionsFromAsync(string fromStateCode, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_custom_gap_lifecycle_actions");
        AddParam(cmd, "@from_state_code", DbType.String, fromStateCode, 60);
        var rows = new List<GapLifecycleActionRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new GapLifecycleActionRow(
                r["ActionCode"]?.ToString() ?? "",
                r["ActionName"]?.ToString() ?? "",
                r["Description"] as string,
                Convert.ToBoolean(r["RemarkRequired"]),
                r["ToStateCode"]?.ToString() ?? "",
                r["ToStateName"]?.ToString() ?? ""));
        return rows;
    }

    // -------- transition --------

    public async Task<GapLifecycleTransitionResult> TransitionAsync(long customGapId, GapLifecycleTransitionRequest request, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.ActionCode))
            return new GapLifecycleTransitionResult(false, customGapId, null, null, null, "ActionCode is required.");

        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_custom_gap_lifecycle_transition");
            AddParam(cmd, "@custom_gap_id",       DbType.Int64,  customGapId);
            AddParam(cmd, "@action_code",         DbType.String, request.ActionCode, 60);
            AddParam(cmd, "@remark",              DbType.String, (object?)request.Remark ?? DBNull.Value, -1);
            AddParam(cmd, "@duplicate_of_gap_id", DbType.Int64,  (object?)request.DuplicateOfGapId ?? DBNull.Value);
            AddParam(cmd, "@invalid_reason",      DbType.String, (object?)request.InvalidReason ?? DBNull.Value, 1000);
            AddParam(cmd, "@caller_employee_id",  DbType.Int64,  (object?)request.CallerEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name", DbType.String, request.CallerDisplayName ?? "system", 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
            {
                return new GapLifecycleTransitionResult(
                    true,
                    Convert.ToInt64(r["CustomGapId"]),
                    r["FromStateCode"]?.ToString(),
                    r["ToStateCode"]?.ToString(),
                    r["StatusCode"]?.ToString(),
                    null);
            }
            return new GapLifecycleTransitionResult(true, customGapId, null, null, null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "GapLifecycleService.Transition failed for {GapId}: {Msg}", customGapId, ex.Message);
            return new GapLifecycleTransitionResult(false, customGapId, null, null, null, ex.Message);
        }
    }

    // -------- analysis --------

    public async Task<GapAnalysisModel?> GetAnalysisAsync(long customGapId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_custom_gap_analysis_get");
        AddParam(cmd, "@custom_gap_id", DbType.Int64, customGapId);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;

        return new GapAnalysisModel(
            Convert.ToInt64(r["CustomGapId"]),
            r["DetectionMethodCode"] as string,
            r["DetectionMethodName"] as string,
            r["SeverityCode"] as string,
            r["SeverityName"] as string,
            r["BusinessImpactCode"] as string,
            r["BusinessImpactSummary"] as string,
            r["RegulatoryImpactCode"] as string,
            r["RegulatoryImpactSummary"] as string,
            Convert.ToBoolean(r["RcaRequired"]),
            r["RcaMethodCode"] as string,
            r["RcaSummary"] as string,
            r["RecommendedActionSummary"] as string,
            // Migration 249: optional read -- returns null on a database
            // without the column so the model still binds against older
            // procs while a rollout is in flight.
            HasColumn(r, "PreventiveAction") ? r["PreventiveAction"] as string : null,
            // Migration 323: these three are the independent decisions
            // the Analysis tab's checkboxes read and write directly.
            Convert.ToBoolean(r["RecommendTask"]),
            Convert.ToBoolean(r["RecommendException"]),
            Convert.ToBoolean(r["RecommendRisk"]),
            // Migration 252: same optional read as PreventiveAction above.
            // 249/250 briefly re-emitted this proc from 157's body and
            // dropped both 168 columns from the projection; guarding here
            // means an un-migrated database degrades to null instead of
            // throwing IndexOutOfRange. Migration 323 retired these from
            // the Analysis tab (kept here only for a historical row's
            // stored value; sp_custom_gap_analysis_get itself is
            // unchanged by 323 and still always projects them).
            HasColumn(r, "RemediationPossible") ? r["RemediationPossible"] as string : null,
            HasColumn(r, "BusinessRiskPresent") ? r["BusinessRiskPresent"] as string : null,
            r["AnalysedByEmployeeId"] as long?,
            r["AnalysedOn"] as DateTime?,
            r["EnteredBy"] as string,
            r["EnteredDt"] as DateTime?,
            r["UpdatedBy"] as string,
            r["UpdatedDt"] as DateTime?);
    }

    public async Task<GapAnalysisSaveResult> SaveAnalysisAsync(long customGapId, GapAnalysisSaveRequest request, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_custom_gap_analysis_save");
            AddParam(cmd, "@custom_gap_id",             DbType.Int64,  customGapId);
            AddParam(cmd, "@detection_method_code",     DbType.String, (object?)request.DetectionMethodCode ?? DBNull.Value, 60);
            AddParam(cmd, "@detection_method_name",     DbType.String, (object?)request.DetectionMethodName ?? DBNull.Value, 200);
            AddParam(cmd, "@severity_code",             DbType.String, (object?)request.SeverityCode ?? DBNull.Value, 30);
            AddParam(cmd, "@severity_name",             DbType.String, (object?)request.SeverityName ?? DBNull.Value, 120);
            AddParam(cmd, "@business_impact_code",      DbType.String, (object?)request.BusinessImpactCode ?? DBNull.Value, 30);
            AddParam(cmd, "@business_impact_summary",   DbType.String, (object?)request.BusinessImpactSummary ?? DBNull.Value, -1);
            AddParam(cmd, "@regulatory_impact_code",    DbType.String, (object?)request.RegulatoryImpactCode ?? DBNull.Value, 30);
            AddParam(cmd, "@regulatory_impact_summary", DbType.String, (object?)request.RegulatoryImpactSummary ?? DBNull.Value, -1);
            AddParam(cmd, "@rca_required",              DbType.Boolean, request.RcaRequired);
            AddParam(cmd, "@rca_method_code",           DbType.String, (object?)request.RcaMethodCode ?? DBNull.Value, 60);
            AddParam(cmd, "@rca_summary",               DbType.String, (object?)request.RcaSummary ?? DBNull.Value, -1);
            AddParam(cmd, "@recommended_action_summary",DbType.String, (object?)request.RecommendedActionSummary ?? DBNull.Value, -1);
            // Migration 249: Preventive Action is a separate free-text
            // column. NULL means "no opinion" and the proc COALESCE-
            // preserves the stored value; the UI sends NULL when the
            // textarea is empty or absent.
            AddParam(cmd, "@preventive_action",         DbType.String, (object?)request.PreventiveAction ?? DBNull.Value, -1);
            // Migration 323: three independent decisions -- any
            // combination, each driving its own auto-trigger. See
            // GapAnalysisSaveRequest's doc comment.
            AddParam(cmd, "@recommend_task",            DbType.Boolean, request.RecommendTask);
            AddParam(cmd, "@recommend_exception",       DbType.Boolean, request.RecommendException);
            AddParam(cmd, "@recommend_risk",            DbType.Boolean, request.RecommendRisk);
            // Migration 168, retired by 323: request.RemediationPossible/
            // BusinessRiskPresent are always null from this UI now. Still
            // sent through (as DBNull) so an un-migrated proc on an older
            // database does not see a missing-argument error.
            AddParam(cmd, "@remediation_possible",      DbType.StringFixedLength,
                     string.IsNullOrWhiteSpace(request.RemediationPossible) ? (object)DBNull.Value : request.RemediationPossible!, 1);
            AddParam(cmd, "@business_risk_present",     DbType.StringFixedLength,
                     string.IsNullOrWhiteSpace(request.BusinessRiskPresent) ? (object)DBNull.Value : request.BusinessRiskPresent!, 1);
            AddParam(cmd, "@analysed_by_employee_id",   DbType.Int64,  (object?)request.AnalysedByEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",       DbType.String, request.CallerDisplayName ?? "system", 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct)) { /* consume CustomGapId result set */ }

            // Migration 323: second result set -- per-artefact outcome of
            // the three auto-triggers (TaskCreated/TaskError/...). Guarded
            // with NextResultAsync's own return value so a database still
            // on the pre-323 proc (single result set) degrades to the
            // all-false/null defaults on GapAnalysisSaveResult instead of
            // throwing.
            bool taskCreated = false, exceptionCreated = false, riskCreated = false;
            string? taskError = null, exceptionError = null, riskError = null;
            // Migration 324: the same second result set gains the auto-
            // Delegate ("Analysed") transition's own outcome. HasColumn-
            // guarded like every field above so a database still on the
            // pre-324 proc degrades to false/null instead of throwing.
            bool lifecycleTransitioned = false;
            string? lifecycleError = null, lifecycleStateCode = null, lifecycleStateName = null;
            if (await r.NextResultAsync(ct) && await r.ReadAsync(ct))
            {
                if (HasColumn(r, "TaskCreated"))      taskCreated      = Convert.ToBoolean(r["TaskCreated"]);
                if (HasColumn(r, "TaskError"))        taskError        = r["TaskError"] as string;
                if (HasColumn(r, "ExceptionCreated")) exceptionCreated = Convert.ToBoolean(r["ExceptionCreated"]);
                if (HasColumn(r, "ExceptionError"))   exceptionError   = r["ExceptionError"] as string;
                if (HasColumn(r, "RiskCreated"))      riskCreated      = Convert.ToBoolean(r["RiskCreated"]);
                if (HasColumn(r, "RiskError"))        riskError        = r["RiskError"] as string;
                if (HasColumn(r, "LifecycleTransitioned")) lifecycleTransitioned = Convert.ToBoolean(r["LifecycleTransitioned"]);
                if (HasColumn(r, "LifecycleError"))        lifecycleError        = r["LifecycleError"] as string;
                if (HasColumn(r, "LifecycleStateCode"))    lifecycleStateCode    = r["LifecycleStateCode"] as string;
                if (HasColumn(r, "LifecycleStateName"))    lifecycleStateName    = r["LifecycleStateName"] as string;
            }

            // Migration 184: severity is captured during analysis. Retrigger
            // auto SLA-match so an updated severity_code lands the right
            // Active org_sla_config for this org. sp_custom_gap_apply_sla is
            // a no-op when sla_source_code = 'OVERRIDDEN', so an operator's
            // approved override survives re-analyses.
            await ApplyAutoSlaAsync(customGapId, request.CallerDisplayName, ct);

            // A best-effort trigger that was requested (checkbox ticked)
            // but failed is still a successful analysis SAVE -- surfaced
            // via the per-artefact fields below, not as request.Error,
            // matching how this proc has always treated these triggers
            // (best-effort, never rolling back the save itself).
            if (request.RecommendTask && !taskCreated && taskError != null)
                logger.LogWarning("GapLifecycleService.SaveAnalysis: Task auto-create failed for {GapId}: {Msg}", customGapId, taskError);
            if (request.RecommendException && !exceptionCreated && exceptionError != null)
                logger.LogWarning("GapLifecycleService.SaveAnalysis: Exception auto-create failed for {GapId}: {Msg}", customGapId, exceptionError);
            if (request.RecommendRisk && !riskCreated && riskError != null)
                logger.LogWarning("GapLifecycleService.SaveAnalysis: Risk auto-create failed for {GapId}: {Msg}", customGapId, riskError);
            // Migration 324: a failed auto-Delegate is the direct cause of
            // "status did not become Analysed" -- log it exactly like a
            // failed Task/Exception/Risk auto-create above, instead of it
            // being visible only via a server-side PRINT (or, before 324,
            // not at all for a gap with no lifecycle_state_id yet).
            if (!lifecycleTransitioned && lifecycleError != null)
                logger.LogWarning("GapLifecycleService.SaveAnalysis: auto-delegate (Analysed) transition failed for {GapId}: {Msg}", customGapId, lifecycleError);

            return new GapAnalysisSaveResult(true, customGapId, null,
                taskCreated, taskError, exceptionCreated, exceptionError, riskCreated, riskError,
                lifecycleTransitioned, lifecycleError, lifecycleStateCode, lifecycleStateName);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "GapLifecycleService.SaveAnalysis failed for {GapId}: {Msg}", customGapId, ex.Message);
            return new GapAnalysisSaveResult(false, customGapId, ex.Message);
        }
    }

    // Migration 184 -- SLA auto-match hook. Duplicated (small) helper so
    // GapLifecycleService does not need to take a dependency on
    // ICustomGapService just for this one proc call.
    private async Task ApplyAutoSlaAsync(long customGapId, string? callerDisplayName, CancellationToken ct)
    {
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_custom_gap_apply_sla");
            AddParam(cmd, "@custom_gap_id",       DbType.Int64,  customGapId);
            AddParam(cmd, "@caller_display_name", DbType.String, callerDisplayName ?? "system", 100);
            await cmd.ExecuteNonQueryAsync(ct);
        }
        catch (SqlException ex)
        {
            // Best-effort: SLA apply must never fail the analysis save.
            logger.LogWarning(ex, "GapLifecycleService.ApplyAutoSlaAsync warning for gap {GapId}: {Msg}", customGapId, ex.Message);
        }
    }

    // -------- downstream links --------

    public async Task<IReadOnlyList<GapDownstreamLinkRow>> ListDownstreamAsync(long customGapId, bool includeCancelled, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_custom_gap_downstream_link_list");
        AddParam(cmd, "@custom_gap_id",     DbType.Int64,   customGapId);
        AddParam(cmd, "@include_cancelled", DbType.Boolean, includeCancelled);
        var rows = new List<GapDownstreamLinkRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new GapDownstreamLinkRow(
                Convert.ToInt64(r["LinkId"]),
                Convert.ToInt64(r["CustomGapId"]),
                r["ArtefactTypeCode"]?.ToString() ?? "",
                r["ArtefactId"] as long?,
                r["ExternalRef"] as string,
                r["Title"] as string,
                r["LinkStatusCode"]?.ToString() ?? "",
                r["InitiatedByEmployeeId"] as long?,
                Convert.ToDateTime(r["InitiatedOn"]),
                r["CancelledByEmployeeId"] as long?,
                r["CancelledOn"] as DateTime?,
                r["CancellationReason"] as string));
        return rows;
    }

    public async Task<GapLinkedArtefactsResult> ListLinkedArtefactsAsync(long customGapId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_custom_gap_linked_artefacts");
        AddParam(cmd, "@custom_gap_id", DbType.Int64, customGapId);

        GapLinkedArtefactRow? task = null;
        GapLinkedArtefactRow? exception = null;
        GapLinkedArtefactRow? risk = null;
        var failedObligations = new List<GapFailedObligationRow>();

        // The proc returns four result sets: Task, Exception, Risk (each
        // zero or one row, unchanged since 174) and, since migration 317,
        // FailedObligations (zero or more rows -- an instance can have
        // several Obligations in gap territory at once). Iterate with
        // NextResult; the fourth set reads every row instead of just the
        // first. A pre-317 database's proc still ends after Risk, so
        // NextResultAsync returns false before the fourth branch is ever
        // reached and failedObligations simply stays empty -- no guard
        // needed beyond that.
        await using var r = await cmd.ExecuteReaderAsync(ct);
        int idx = 0;
        do
        {
            if (idx < 3)
            {
                if (await r.ReadAsync(ct))
                {
                    var row = new GapLinkedArtefactRow(
                        r["ArtefactType"]?.ToString() ?? "",
                        Convert.ToInt64(r["ArtefactId"]),
                        r["Title"] as string,
                        r["StatusCode"] as string);
                    if (idx == 0) task = row;
                    else if (idx == 1) exception = row;
                    else if (idx == 2) risk = row;
                }
            }
            else
            {
                while (await r.ReadAsync(ct))
                {
                    failedObligations.Add(new GapFailedObligationRow(
                        Convert.ToInt64(r["ObligationId"]),
                        r["ObligationName"] as string,
                        r["ObligationTypeCode"] as string,
                        r["LoggedStatusCode"]?.ToString() ?? "",
                        r["AddedDt"] as DateTime?,
                        // Migration 372: live status, additive column. Guarded so a
                        // pre-372 sp_custom_gap_linked_artefacts still binds.
                        HasColumn(r, "CurrentStatusCode") ? r["CurrentStatusCode"]?.ToString() : null));
                }
            }
            idx++;
        } while (await r.NextResultAsync(ct));

        return new GapLinkedArtefactsResult(task, exception, risk, failedObligations);
    }

    public async Task<long> AddDownstreamAsync(long customGapId, GapDownstreamLinkAddRequest request, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(request);
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_custom_gap_downstream_link_add");
        AddParam(cmd, "@custom_gap_id",            DbType.Int64,  customGapId);
        AddParam(cmd, "@artefact_type_code",       DbType.String, request.ArtefactTypeCode, 30);
        AddParam(cmd, "@artefact_id",              DbType.Int64,  (object?)request.ArtefactId ?? DBNull.Value);
        AddParam(cmd, "@external_ref",             DbType.String, (object?)request.ExternalRef ?? DBNull.Value, 200);
        AddParam(cmd, "@title",                    DbType.String, (object?)request.Title ?? DBNull.Value, 300);
        AddParam(cmd, "@initiated_by_employee_id", DbType.Int64,  (object?)request.InitiatedByEmployeeId ?? DBNull.Value);
        AddParam(cmd, "@caller_display_name",      DbType.String, request.CallerDisplayName ?? "system", 100);

        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (await r.ReadAsync(ct)) return Convert.ToInt64(r["LinkId"]);
        return 0;
    }

    public async Task<bool> CancelDownstreamAsync(long linkId, GapDownstreamLinkCancelRequest request, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_custom_gap_downstream_link_cancel");
            AddParam(cmd, "@link_id",                DbType.Int64,  linkId);
            AddParam(cmd, "@reason",                 DbType.String, request.Reason, 1000);
            AddParam(cmd, "@cancelled_by_employee_id", DbType.Int64, (object?)request.CancelledByEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",    DbType.String, request.CallerDisplayName ?? "system", 100);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            return await r.ReadAsync(ct);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "GapLifecycleService.CancelDownstream failed for {LinkId}: {Msg}", linkId, ex.Message);
            return false;
        }
    }

    // -------- helpers --------

    private async Task<DbConnection> OpenAsync(CancellationToken ct)
    {
        var cs = Infrastructure.SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(cs))
            throw new InvalidOperationException("PracticeManagement connection string is not configured.");
        var c = new SqlConnection(cs);
        await c.OpenAsync(ct);
        return c;
    }

    private static DbCommand Proc(DbConnection connection, string name)
    {
        var cmd = connection.CreateCommand();
        cmd.CommandType = CommandType.StoredProcedure;
        cmd.CommandText = name;
        return cmd;
    }

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
