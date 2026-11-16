// =====================================================================
// OrgAssuranceExecutionService
//
// Phase 2 Assurance Management -- Stage 3 Execution service.
//
// Thin wrapper over the sp_org_assurance_execution_* stored procedures
// (migration 099). Mirrors OrgAssurancePlanService conventions.
//
// Wire-up: Infrastructure/OrgAssuranceExecutionServiceRegistration.cs.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IOrgAssuranceExecutionService
{
    Task<IReadOnlyList<OrgAssuranceExecutionStatusRow>> ListStatusesAsync(CancellationToken cancellationToken);

    // Header
    Task<OrgAssuranceExecutionListResult> ListAsync(
        OrgAssuranceExecutionListQuery query, CancellationToken cancellationToken);
    Task<OrgAssuranceExecutionDetail?> GetAsync(
        long organizationId, long executionId, CancellationToken cancellationToken);

    // Materialize + delete
    Task<OrgAssuranceExecutionMaterializeResult> MaterializeAsync(
        OrgAssuranceExecutionMaterializeRequest request, CancellationToken cancellationToken);
    Task<OrgAssuranceExecutionCommandResult> DeleteAsync(
        OrgAssuranceExecutionCommandRequest request, CancellationToken cancellationToken);

    // Lifecycle
    Task<OrgAssuranceExecutionCommandResult> StartAsync(
        OrgAssuranceExecutionCommandRequest request, CancellationToken cancellationToken);
    Task<OrgAssuranceExecutionCommandResult> SubmitAsync(
        OrgAssuranceExecutionCommandRequest request, CancellationToken cancellationToken);
    Task<OrgAssuranceExecutionCommandResult> ReviewAsync(
        OrgAssuranceExecutionCommandRequest request, CancellationToken cancellationToken);
    Task<OrgAssuranceExecutionCommandResult> ApproveAsync(
        OrgAssuranceExecutionCommandRequest request, CancellationToken cancellationToken);
    Task<OrgAssuranceExecutionCommandResult> CloseAsync(
        OrgAssuranceExecutionCommandRequest request, CancellationToken cancellationToken);
    Task<OrgAssuranceExecutionCommandResult> CancelAsync(
        OrgAssuranceExecutionCommandRequest request, CancellationToken cancellationToken);

    // Entities
    Task<OrgAssuranceExecutionEntityListResult> ListEntitiesAsync(
        long organizationId, long executionId,
        string? dimensionCode, string? statusCode, string? search,
        int page, int pageSize, CancellationToken cancellationToken);

    // 120 -- per-entity auditor assignment (role+employee hybrid).
    Task<OrgAssuranceExecutionAuditorAssignResult> AssignEntityAuditorAsync(
        OrgAssuranceExecutionAuditorAssignRequest request, CancellationToken cancellationToken);

    // 555 -- My Audits, live scope, Freeze Scope.
    Task<IReadOnlyList<OrgAssuranceMyAuditPrepareRow>> PrepareMyAuditsAsync(
        long employeeId, string actor, CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssuranceMyAuditRow>> ListMyAuditsAsync(
        long employeeId, CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssuranceScopeItemRow>> ListLiveScopeAsync(
        long organizationId, long executionId, string actor, CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssuranceScopeExclusionRow>> ListScopeExclusionsAsync(
        long organizationId, long executionId, CancellationToken cancellationToken);
    Task<OrgAssuranceFreezeScopeResult> FreezeScopeAsync(
        long executionId, long employeeId, OrgAssuranceFreezeScopeRequest request, string actor,
        CancellationToken cancellationToken);
    // 563 -- Scope Builder Step 3: the review to confirm (live) or the approved snapshot (frozen).
    Task<OrgAssuranceScopeReviewResult> GetScopeReviewAsync(
        long organizationId, long executionId, CancellationToken cancellationToken);

    // 558 -- question responses (one per question per execution) and findings.
    Task<OrgAssuranceResponseListResult> ListResponsesAsync(
        long organizationId, long executionId, CancellationToken cancellationToken);
    Task<OrgAssuranceResponseSaveResult> SaveResponseAsync(
        long executionId, long employeeId, OrgAssuranceResponseSaveRequest request, string actor,
        CancellationToken cancellationToken);

    // 556 -- Continuous Assurance view (same procedure as the live scope, ASSURANCE mode).
    Task<OrgAssuranceContinuousAssuranceResult> GetContinuousAssuranceAsync(
        long organizationId, long executionId, string actor, CancellationToken cancellationToken);
}

public sealed class OrgAssuranceExecutionService(
    IConfiguration configuration,
    ILogger<OrgAssuranceExecutionService> logger) : IOrgAssuranceExecutionService
{
    // -----------------------------------------------------------------
    // Lookups
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceExecutionStatusRow>> ListStatusesAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_execution_status_list";

        var rows = new List<OrgAssuranceExecutionStatusRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceExecutionStatusRow(
                Convert.ToInt32(reader["StatusId"]),
                reader["StatusCode"]?.ToString() ?? "",
                reader["StatusName"]?.ToString() ?? "",
                Convert.ToInt32(reader["DisplayOrder"]),
                Convert.ToBoolean(reader["IsTerminal"])));
        }
        return rows;
    }

    // -----------------------------------------------------------------
    // Header
    // -----------------------------------------------------------------
    public async Task<OrgAssuranceExecutionListResult> ListAsync(
        OrgAssuranceExecutionListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_execution_list";

        AddParam(command, "@organization_id", DbType.Int64,  query.OrganizationId);
        AddParam(command, "@definition_id",   DbType.Int64,  (object?)query.DefinitionId ?? DBNull.Value);
        AddParam(command, "@status_code",     DbType.String, (object?)query.StatusCode   ?? DBNull.Value, 60);
        AddParam(command, "@origin_type",     DbType.String, (object?)query.OriginType   ?? DBNull.Value, 20);
        AddParam(command, "@search",          DbType.String, (object?)query.Search       ?? DBNull.Value, 200);
        AddParam(command, "@page",            DbType.Int32,  Math.Max(1, query.Page));
        AddParam(command, "@page_size",       DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));
        // 414: dashboard drill-down, sent only when declared.
        await Infrastructure.ListDrillParameters.AddAsync(connection, command, "sp_org_assurance_execution_list", query.Drill, cancellationToken);

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

        var rows = new List<OrgAssuranceExecutionListRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(MapListRow(reader));
        }
        return new OrgAssuranceExecutionListResult(total, page, size, rows);
    }

    public async Task<OrgAssuranceExecutionDetail?> GetAsync(
        long organizationId, long executionId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_execution_get";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@execution_id",    DbType.Int64, executionId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await reader.ReadAsync(cancellationToken) ? MapDetailRow(reader) : null;
    }

    // -----------------------------------------------------------------
    // Materialize
    // -----------------------------------------------------------------
    public async Task<OrgAssuranceExecutionMaterializeResult> MaterializeAsync(
        OrgAssuranceExecutionMaterializeRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)
            return new OrgAssuranceExecutionMaterializeResult(false, Error: "OrganizationId is required.");
        if (request.DefinitionId <= 0)
            return new OrgAssuranceExecutionMaterializeResult(false, Error: "DefinitionId is required.");
        // 545: ScopeResolutionId is optional -- without it the procedure
        // resolves the scope now, for this execution.
        if (request.ScopeResolutionId is <= 0)
            return new OrgAssuranceExecutionMaterializeResult(false, Error: "ScopeResolutionId must be positive when given.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_execution_materialize";

            AddParam(command, "@organization_id",     DbType.Int64,  request.OrganizationId);
            AddParam(command, "@definition_id",       DbType.Int64,  request.DefinitionId);
            AddParam(command, "@version_id",          DbType.Int64,  (object?)request.VersionId ?? DBNull.Value);
            AddParam(command, "@scope_resolution_id", DbType.Int64,  (object?)request.ScopeResolutionId ?? DBNull.Value);
            AddParam(command, "@execution_code",      DbType.String, (object?)request.ExecutionCode ?? DBNull.Value, 120);
            AddParam(command, "@execution_name",      DbType.String, (object?)request.ExecutionName ?? DBNull.Value, 300);
            AddParam(command, "@origin_type",         DbType.String,
                (object?)(request.OriginType?.Trim().ToUpperInvariant()) ?? (object)"MANUAL", 20);
            AddParam(command, "@plan_id",             DbType.Int64,  (object?)request.PlanId ?? DBNull.Value);
            AddParam(command, "@plan_item_id",        DbType.Int64,  (object?)request.PlanItemId ?? DBNull.Value);
            AddParam(command, "@trigger_config_id",   DbType.Int64,  (object?)request.TriggerConfigId ?? DBNull.Value);
            AddParam(command, "@planned_start_dt",    DbType.Date,   (object?)request.PlannedStartDt ?? DBNull.Value);
            AddParam(command, "@planned_end_dt",      DbType.Date,   (object?)request.PlannedEndDt   ?? DBNull.Value);
            // 120 hybrid role+employee Owner -- SP auto-resolves whichever side is missing.
            AddParam(command, "@owner_role_id",       DbType.Int64,  (object?)request.OwnerRoleId ?? DBNull.Value);
            AddParam(command, "@owner_role_name",     DbType.String, (object?)request.OwnerRoleName ?? DBNull.Value, 120);
            AddParam(command, "@owner_employee_id",   DbType.Int64,  (object?)request.OwnerEmployeeId ?? DBNull.Value);
            AddParam(command, "@owner_display_name",  DbType.String, (object?)request.OwnerDisplayName ?? DBNull.Value, 240);
            AddParam(command, "@assigned_team_name",  DbType.String, (object?)request.AssignedTeamName ?? DBNull.Value, 200);
            AddParam(command, "@notes",               DbType.String, (object?)request.Notes ?? DBNull.Value, -1);
            AddParam(command, "@actor",               DbType.String, (object?)request.Actor ?? (object)"system", 100);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@execution_id_out";
            idOut.DbType        = DbType.Int64;
            idOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idOut);

            long?   totalOut = null;
            string? codeOut  = null;
            string? nameOut  = null;

            await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
            {
                if (await reader.ReadAsync(cancellationToken))
                {
                    codeOut  = ReadStringOrNull(reader, "ExecutionCode");
                    nameOut  = ReadStringOrNull(reader, "ExecutionName");
                    totalOut = ReadLongOrNull(reader, "TotalEntityCount");
                }
            }

            var id = idOut.Value is long l ? l : Convert.ToInt64(idOut.Value);
            return new OrgAssuranceExecutionMaterializeResult(
                true, id, codeOut, nameOut, totalOut);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssuranceExecutionService.MaterializeAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceExecutionMaterializeResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // -----------------------------------------------------------------
    // Delete + Lifecycle transitions
    // -----------------------------------------------------------------
    public Task<OrgAssuranceExecutionCommandResult> DeleteAsync (OrgAssuranceExecutionCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_execution_delete",  r, ct);
    public Task<OrgAssuranceExecutionCommandResult> StartAsync  (OrgAssuranceExecutionCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_execution_start",   r, ct);
    public Task<OrgAssuranceExecutionCommandResult> SubmitAsync (OrgAssuranceExecutionCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_execution_submit",  r, ct);
    public Task<OrgAssuranceExecutionCommandResult> ReviewAsync (OrgAssuranceExecutionCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_execution_review",  r, ct);
    public Task<OrgAssuranceExecutionCommandResult> ApproveAsync(OrgAssuranceExecutionCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_execution_approve", r, ct);
    public Task<OrgAssuranceExecutionCommandResult> CloseAsync  (OrgAssuranceExecutionCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_execution_close",   r, ct);
    public Task<OrgAssuranceExecutionCommandResult> CancelAsync (OrgAssuranceExecutionCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_execution_cancel",  r, ct);

    private async Task<OrgAssuranceExecutionCommandResult> TransitionAsync(
        string procName, OrgAssuranceExecutionCommandRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.ExecutionId <= 0)
            return new OrgAssuranceExecutionCommandResult(false, Error: "ExecutionId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = procName;

            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@execution_id",    DbType.Int64,  request.ExecutionId);
            AddParam(command, "@actor",           DbType.String, (object?)request.Actor ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssuranceExecutionCommandResult(true, request.ExecutionId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssuranceExecutionService.{Proc} SQL error {Number}: {Message}",
                procName, ex.Number, ex.Message);
            return new OrgAssuranceExecutionCommandResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // -----------------------------------------------------------------
    // Entities
    // -----------------------------------------------------------------
    public async Task<OrgAssuranceExecutionEntityListResult> ListEntitiesAsync(
        long organizationId, long executionId,
        string? dimensionCode, string? statusCode, string? search,
        int page, int pageSize, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_execution_entity_list";

        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@execution_id",    DbType.Int64,  executionId);
        AddParam(command, "@dimension_code",  DbType.String, (object?)dimensionCode ?? DBNull.Value, 60);
        AddParam(command, "@status_code",     DbType.String, (object?)statusCode    ?? DBNull.Value, 30);
        AddParam(command, "@search",          DbType.String, (object?)search        ?? DBNull.Value, 200);
        AddParam(command, "@page",            DbType.Int32,  Math.Max(1, page));
        AddParam(command, "@page_size",       DbType.Int32,  Math.Clamp(pageSize, 1, 500));

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        long total = 0;
        int  pageOut = page;
        int  sizeOut = pageSize;
        if (await reader.ReadAsync(cancellationToken))
        {
            total   = Convert.ToInt64(reader["TotalCount"]);
            pageOut = Convert.ToInt32(reader["PageNumber"]);
            sizeOut = Convert.ToInt32(reader["PageSize"]);
        }

        var rows = new List<OrgAssuranceExecutionEntityRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(MapEntityRow(reader));
        }
        return new OrgAssuranceExecutionEntityListResult(total, pageOut, sizeOut, rows);
    }

    // -----------------------------------------------------------------
    // 120 -- per-entity Auditor assignment (role+employee hybrid)
    // -----------------------------------------------------------------
    public async Task<OrgAssuranceExecutionAuditorAssignResult> AssignEntityAuditorAsync(
        OrgAssuranceExecutionAuditorAssignRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)
            return new OrgAssuranceExecutionAuditorAssignResult(false, Error: "OrganizationId is required.");
        if (request.ExecutionId <= 0)
            return new OrgAssuranceExecutionAuditorAssignResult(false, Error: "ExecutionId is required.");
        if (request.ExecutionEntityId <= 0)
            return new OrgAssuranceExecutionAuditorAssignResult(false, Error: "ExecutionEntityId is required.");
        if (request.AuditorRoleId == null && request.AuditorEmployeeId == null)
            return new OrgAssuranceExecutionAuditorAssignResult(false, Error: "Provide at least AuditorRoleId or AuditorEmployeeId.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_execution_entity_auditor_assign";

            AddParam(command, "@organization_id",      DbType.Int64,  request.OrganizationId);
            AddParam(command, "@execution_id",         DbType.Int64,  request.ExecutionId);
            AddParam(command, "@execution_entity_id",  DbType.Int64,  request.ExecutionEntityId);
            AddParam(command, "@auditor_role_id",      DbType.Int64,  (object?)request.AuditorRoleId ?? DBNull.Value);
            AddParam(command, "@auditor_role_name",    DbType.String, (object?)request.AuditorRoleName ?? DBNull.Value, 120);
            AddParam(command, "@auditor_employee_id",  DbType.Int64,  (object?)request.AuditorEmployeeId ?? DBNull.Value);
            AddParam(command, "@auditor_display_name", DbType.String, (object?)request.AuditorDisplayName ?? DBNull.Value, 240);
            AddParam(command, "@actor",                DbType.String, (object?)request.Actor ?? (object)"system", 100);

            long? entityIdOut = null;
            await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
            {
                if (await reader.ReadAsync(cancellationToken))
                    entityIdOut = ReadLongOrNull(reader, "ExecutionEntityId");
            }
            return new OrgAssuranceExecutionAuditorAssignResult(true, entityIdOut);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssuranceExecutionService.AssignEntityAuditorAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceExecutionAuditorAssignResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // -----------------------------------------------------------------
    // 555 -- My Audits, live scope, Freeze Scope
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceMyAuditPrepareRow>> PrepareMyAuditsAsync(
        long employeeId, string actor, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType    = CommandType.StoredProcedure;
        command.CommandText    = "grac_practice.sp_org_assurance_my_audits_prepare";
        command.CommandTimeout = 120;   // one resolver run per audit started
        AddParam(command, "@employee_id", DbType.Int64,  employeeId);
        AddParam(command, "@actor",       DbType.String, actor, 100);

        var rows = new List<OrgAssuranceMyAuditPrepareRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(new OrgAssuranceMyAuditPrepareRow(
                Convert.ToInt64(reader["PlanItemId"]),
                ReadStringOrNull(reader, "EngagementCode"),
                Convert.ToBoolean(reader["Started"]),
                ReadStringOrNull(reader, "Message")));
        return rows;
    }

    public async Task<IReadOnlyList<OrgAssuranceMyAuditRow>> ListMyAuditsAsync(
        long employeeId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_my_audit_list";
        AddParam(command, "@employee_id", DbType.Int64, employeeId);

        var rows = new List<OrgAssuranceMyAuditRow>();
        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
            rows.Add(new OrgAssuranceMyAuditRow(
                Convert.ToInt64(r["OrganizationId"]),
                ReadStringOrNull(r,   "OrganizationName"),
                ReadLongOrNull(r,     "PlanId"),   // 566: independent engagements have none
                ReadStringOrNull(r,   "PlanCode"),
                ReadStringOrNull(r,   "PlanName"),
                Convert.ToInt64(r["PlanItemId"]),
                ReadStringOrNull(r,   "EngagementCode"),
                ReadStringOrNull(r,   "EngagementName"),
                ReadLongOrNull(r,     "BranchId"),
                ReadStringOrNull(r,   "BranchName"),
                ReadDateTimeOrNull(r, "ScheduledFrom"),
                ReadDateTimeOrNull(r, "ScheduledTo"),
                Convert.ToInt64(r["DefinitionId"]),
                ReadStringOrNull(r,   "DefinitionCode"),
                ReadStringOrNull(r,   "DefinitionName"),
                ReadLongOrNull(r,     "ExecutionId"),
                ReadStringOrNull(r,   "ExecutionCode"),
                ReadStringOrNull(r,   "ExecutionStatusCode"),
                ReadStringOrNull(r,   "ExecutionStatusName"),
                ReadDateTimeOrNull(r, "ScopeFrozenAt"),
                ReadLongOrNull(r,     "TotalEntityCount"),
                ReadLongOrNull(r,     "CompletedEntityCount"),
                r["AuditState"]?.ToString() ?? ""));
        return rows;
    }

    public async Task<IReadOnlyList<OrgAssuranceScopeItemRow>> ListLiveScopeAsync(
        long organizationId, long executionId, string actor, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType    = CommandType.StoredProcedure;
        command.CommandText    = "grac_practice.sp_org_assurance_execution_live_scope";
        command.CommandTimeout = 120;   // one resolver run
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@execution_id",    DbType.Int64,  executionId);
        AddParam(command, "@actor",           DbType.String, actor, 100);

        var rows = new List<OrgAssuranceScopeItemRow>();
        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
            rows.Add(new OrgAssuranceScopeItemRow(
                r["DimensionCode"]?.ToString() ?? "",
                ReadStringOrNull(r, "DimensionName"),
                ReadLongOrNull(r,   "EntityId"),
                ReadStringOrNull(r, "EntityCode"),
                ReadStringOrNull(r, "EntityName")));
        return rows;
    }

    public async Task<OrgAssuranceResponseListResult> ListResponsesAsync(
        long organizationId, long executionId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_execution_response_list";
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@execution_id",    DbType.Int64, executionId);

        var questions = new List<OrgAssuranceResponseRow>();
        var counts    = new List<OrgAssuranceResponseCountRow>();
        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
            questions.Add(new OrgAssuranceResponseRow(
                ReadIntOrNull(r,      "SetOrder"),
                ReadStringOrNull(r,   "QuestionSetCode"),
                ReadStringOrNull(r,   "QuestionSetName"),
                Convert.ToInt64(r["QuestionId"]),
                ReadStringOrNull(r,   "QuestionCode"),
                ReadStringOrNull(r,   "QuestionText"),
                ReadStringOrNull(r,   "HelpText"),
                r["IsMandatory"] != DBNull.Value && Convert.ToBoolean(r["IsMandatory"]),
                ReadIntOrNull(r,      "DisplayOrder"),
                ReadStringOrNull(r,   "EvidenceTypeName"),
                ReadStringOrNull(r,   "ExpectedEvidence"),
                ReadStringOrNull(r,   "ResultCode"),
                ReadStringOrNull(r,   "Description"),
                ReadLongOrNull(r,     "OwnerEmployeeId"),
                ReadStringOrNull(r,   "OwnerDisplayName"),
                ReadStringOrNull(r,   "AnsweredBy"),
                ReadDateTimeOrNull(r, "AnsweredDt"),
                ReadLongOrNull(r,     "ObservationId"),
                ReadStringOrNull(r,   "ObservationCode"),
                ReadStringOrNull(r,   "ObservationStatusCode"),
                ReadStringOrNull(r,   "ObservationStatusName")));
        if (await r.NextResultAsync(cancellationToken))
            while (await r.ReadAsync(cancellationToken))
                counts.Add(new OrgAssuranceResponseCountRow(
                    r["ResultCode"]?.ToString() ?? "",
                    Convert.ToInt32(r["QuestionCount"])));
        return new OrgAssuranceResponseListResult(questions, counts);
    }

    public async Task<OrgAssuranceResponseSaveResult> SaveResponseAsync(
        long executionId, long employeeId, OrgAssuranceResponseSaveRequest request, string actor,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_execution_response_save";
            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@execution_id",      DbType.Int64,  executionId);
            AddParam(command, "@question_id",       DbType.Int64,  request.QuestionId);
            AddParam(command, "@result_code",       DbType.String, request.ResultCode, 20);
            AddParam(command, "@description",       DbType.String, (object?)request.Description ?? DBNull.Value, -1);
            AddParam(command, "@owner_employee_id", DbType.Int64,  request.OwnerEmployeeId is > 0 ? (object)request.OwnerEmployeeId.Value : DBNull.Value);
            AddParam(command, "@employee_id",       DbType.Int64,  employeeId);
            AddParam(command, "@actor",             DbType.String, actor, 100);

            await using var r = await command.ExecuteReaderAsync(cancellationToken);
            if (!await r.ReadAsync(cancellationToken))
                return new OrgAssuranceResponseSaveResult(true, request.QuestionId, request.ResultCode);
            return new OrgAssuranceResponseSaveResult(true,
                Convert.ToInt64(r["QuestionId"]),
                ReadStringOrNull(r, "ResultCode"),
                ReadLongOrNull(r,   "ObservationId"),
                ReadStringOrNull(r, "ObservationCode"),
                ReadStringOrNull(r, "ObservationStatusCode"),
                ReadStringOrNull(r, "ObservationStatusName"));
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssuranceExecutionService.SaveResponseAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceResponseSaveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    public async Task<OrgAssuranceContinuousAssuranceResult> GetContinuousAssuranceAsync(
        long organizationId, long executionId, string actor, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType    = CommandType.StoredProcedure;
        command.CommandText    = "grac_practice.sp_org_assurance_execution_live_scope";
        command.CommandTimeout = 120;   // a live scope runs the resolver
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@execution_id",    DbType.Int64,  executionId);
        AddParam(command, "@actor",           DbType.String, actor, 100);
        AddParam(command, "@mode",            DbType.String, "ASSURANCE", 20);

        var summary = new List<OrgAssuranceCaSummaryRow>();
        var detail  = new List<OrgAssuranceCaDetailRow>();
        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
            summary.Add(new OrgAssuranceCaSummaryRow(
                r["SummaryKind"]?.ToString() ?? "",
                r["Label"]?.ToString() ?? "",
                Convert.ToInt32(r["ItemCount"])));
        if (await r.NextResultAsync(cancellationToken))
            while (await r.ReadAsync(cancellationToken))
                detail.Add(new OrgAssuranceCaDetailRow(
                    r["DimensionCode"]?.ToString() ?? "",
                    ReadStringOrNull(r,   "DimensionName"),
                    ReadLongOrNull(r,     "EntityId"),
                    ReadStringOrNull(r,   "EntityCode"),
                    ReadStringOrNull(r,   "EntityName"),
                    ReadLongOrNull(r,     "PracticeInstanceId"),
                    ReadStringOrNull(r,   "InstanceCode"),
                    ReadStringOrNull(r,   "InstanceName"),
                    ReadStringOrNull(r,   "Via"),
                    ReadLongOrNull(r,     "ObligationId"),
                    ReadStringOrNull(r,   "ObligationName"),
                    ReadStringOrNull(r,   "ObligationType"),
                    ReadStringOrNull(r,   "Frequency"),
                    ReadStringOrNull(r,   "ObligationStatusCode"),
                    ReadStringOrNull(r,   "ObligationStatusName"),
                    ReadLongOrNull(r,     "LastTaskId"),
                    ReadStringOrNull(r,   "LastTaskNumber"),
                    ReadStringOrNull(r,   "LastTaskStatusCode"),
                    ReadStringOrNull(r,   "LastTaskStatusName"),
                    ReadDateTimeOrNull(r, "LastTaskDueDate")));
        return new OrgAssuranceContinuousAssuranceResult(summary, detail);
    }

    public async Task<IReadOnlyList<OrgAssuranceScopeExclusionRow>> ListScopeExclusionsAsync(
        long organizationId, long executionId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_execution_scope_exclusion_list";
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@execution_id",    DbType.Int64, executionId);

        var rows = new List<OrgAssuranceScopeExclusionRow>();
        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
            rows.Add(new OrgAssuranceScopeExclusionRow(
                r["DimensionCode"]?.ToString() ?? "",
                ReadStringOrNull(r,   "DimensionName"),
                Convert.ToInt64(r["EntityId"]),
                ReadStringOrNull(r,   "EntityCode"),
                ReadStringOrNull(r,   "EntityName"),
                r["Reason"]?.ToString() ?? "",
                ReadStringOrNull(r,   "EnteredBy"),
                ReadDateTimeOrNull(r, "EnteredDt")));
        return rows;
    }

    public async Task<OrgAssuranceFreezeScopeResult> FreezeScopeAsync(
        long executionId, long employeeId, OrgAssuranceFreezeScopeRequest request, string actor,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType    = CommandType.StoredProcedure;
            command.CommandText    = "grac_practice.sp_org_assurance_execution_freeze_scope";
            command.CommandTimeout = 120;   // one resolver run
            var excl = (request.Exclusions ?? [])
                .Select(x => new { dimensionCode = x.DimensionCode, entityId = x.EntityId, reason = x.Reason })
                .ToList();
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@execution_id",    DbType.Int64,  executionId);
            AddParam(command, "@employee_id",     DbType.Int64,  employeeId);
            AddParam(command, "@exclusions_json", DbType.String,
                excl.Count == 0 ? DBNull.Value : (object)System.Text.Json.JsonSerializer.Serialize(excl), -1);
            AddParam(command, "@actor",           DbType.String, actor, 100);
            // 563: Step 3 Review and Confirm -- category ticks, unticked
            // related records (with reasons) and manual items.
            // Sent only with a review, so a freeze without one also runs
            // against the 555 procedure.
            if (request.Review is { } rv)
                AddParam(command, "@review_json", DbType.String, System.Text.Json.JsonSerializer.Serialize(new
                {
                    categories = (rv.Categories ?? []).Select(c => new { code = c.Code, isIncluded = c.IsIncluded }),
                    excluded   = (rv.Excluded   ?? []).Select(x => new { categoryCode = x.CategoryCode, recordId = x.RecordId, reason = x.Reason }),
                    manual     = (rv.Manual     ?? []).Select(m => new { categoryCode = m.CategoryCode, name = m.Name, note = m.Note })
                }), -1);

            await using var r = await command.ExecuteReaderAsync(cancellationToken);
            if (!await r.ReadAsync(cancellationToken))
                return new OrgAssuranceFreezeScopeResult(true, executionId);
            return new OrgAssuranceFreezeScopeResult(true,
                Convert.ToInt64(r["ExecutionId"]),
                ReadStringOrNull(r, "ExecutionCode"),
                ReadLongOrNull(r,   "TotalEntityCount"),
                ReadIntOrNull(r,    "ExcludedCount"),
                ReviewId:        HasColumn(r, "ReviewId")        ? ReadLongOrNull(r, "ReviewId")       : null,   // 563
                ReviewVersionNo: HasColumn(r, "ReviewVersionNo") ? ReadIntOrNull(r,  "ReviewVersionNo") : null);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssuranceExecutionService.FreezeScopeAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceFreezeScopeResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // 563 -- Scope Builder Step 3: header, categories, items.
    public async Task<OrgAssuranceScopeReviewResult> GetScopeReviewAsync(
        long organizationId, long executionId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType    = CommandType.StoredProcedure;
        command.CommandText    = "grac_practice.sp_org_assurance_execution_scope_review_get";
        command.CommandTimeout = 120;   // one resolver run and the discovery
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@execution_id",    DbType.Int64, executionId);

        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        var header = new OrgAssuranceScopeReviewHeader(null, null, null, null, null, false);
        if (await r.ReadAsync(cancellationToken))
            header = new OrgAssuranceScopeReviewHeader(
                ReadLongOrNull(r,     "ReviewId"),
                ReadIntOrNull(r,      "VersionNo"),
                ReadStringOrNull(r,   "ReviewStatus"),
                ReadStringOrNull(r,   "ApprovedBy"),
                ReadDateTimeOrNull(r, "ApprovedDt"),
                r["IsFrozen"] != DBNull.Value && Convert.ToBoolean(r["IsFrozen"]));

        var categories = new List<OrgAssuranceScopeReviewCategoryRow>();
        if (await r.NextResultAsync(cancellationToken))
            while (await r.ReadAsync(cancellationToken))
                categories.Add(new OrgAssuranceScopeReviewCategoryRow(
                    r["CategoryCode"]?.ToString() ?? "",
                    ReadStringOrNull(r, "CategoryName"),
                    ReadIntOrNull(r,    "DisplayOrder"),
                    ReadLongOrNull(r,   "ItemCount") ?? 0,
                    r["IsIncluded"] != DBNull.Value && Convert.ToBoolean(r["IsIncluded"])));

        var items = new List<OrgAssuranceScopeReviewItemRow>();
        if (await r.NextResultAsync(cancellationToken))
            while (await r.ReadAsync(cancellationToken))
                items.Add(new OrgAssuranceScopeReviewItemRow(
                    r["CategoryCode"]?.ToString() ?? "",
                    ReadLongOrNull(r,   "RecordId"),
                    ReadStringOrNull(r, "RecordCode"),
                    ReadStringOrNull(r, "RecordName"),
                    ReadStringOrNull(r, "Status"),
                    ReadStringOrNull(r, "Reason"),
                    r["IsKept"]   != DBNull.Value && Convert.ToBoolean(r["IsKept"]),
                    ReadStringOrNull(r, "ExclusionReason"),
                    r["IsManual"] != DBNull.Value && Convert.ToBoolean(r["IsManual"]),
                    ReadStringOrNull(r, "ManualNote")));

        return new OrgAssuranceScopeReviewResult(header, categories, items);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------
    private static bool HasColumn(DbDataReader r, string col)
    {
        for (var i = 0; i < r.FieldCount; i++)
            if (string.Equals(r.GetName(i), col, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    private async Task<DbConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connString = Infrastructure.SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connString))
            throw new InvalidOperationException("PracticeManagement connection string is not configured.");
        var connection = new SqlConnection(connString);
        await connection.OpenAsync(cancellationToken);
        await Infrastructure.ViewScopeSession.ApplyAsync(connection, cancellationToken);   // 415: View Data Scope
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

    private static OrgAssuranceExecutionListRow MapListRow(DbDataReader r) => new(
        Convert.ToInt64(r["ExecutionId"]),
        Convert.ToInt64(r["OrganizationId"]),
        Convert.ToInt64(r["DefinitionId"]),
        Convert.ToInt64(r["DefinitionVersionId"]),
        r["DefinitionCode"]?.ToString() ?? "",
        r["DefinitionName"]?.ToString() ?? "",
        Convert.ToInt32(r["VersionNumber"]),
        r["ExecutionCode"]?.ToString() ?? "",
        r["ExecutionName"]?.ToString() ?? "",
        r["StatusCode"]?.ToString() ?? "",
        r["StatusName"]?.ToString() ?? "",
        Convert.ToBoolean(r["StatusIsTerminal"]),
        r["OriginType"]?.ToString() ?? "",
        ReadLongOrNull(r,     "PlanId"),
        ReadLongOrNull(r,     "PlanItemId"),
        ReadLongOrNull(r,     "TriggerConfigId"),
        Convert.ToInt64(r["ScopeResolutionId"]),
        // 120 hybrid role+employee Owner
        ReadLongOrNull(r,     "OwnerRoleId"),
        ReadStringOrNull(r,   "OwnerRoleName"),
        ReadLongOrNull(r,     "OwnerEmployeeId"),
        ReadStringOrNull(r,   "OwnerDisplayName"),
        ReadDateTimeOrNull(r, "PlannedStartDt"),
        ReadDateTimeOrNull(r, "PlannedEndDt"),
        ReadDateTimeOrNull(r, "ActualStartDt"),
        ReadDateTimeOrNull(r, "ActualEndDt"),
        Convert.ToInt64(r["TotalEntityCount"]),
        Convert.ToInt64(r["CompletedEntityCount"]),
        ReadDateTimeOrNull(r, "EnteredDt"),
        ReadDateTimeOrNull(r, "UpdatedDt"));

    private static OrgAssuranceExecutionDetail MapDetailRow(DbDataReader r) => new(
        Convert.ToInt64(r["ExecutionId"]),
        Convert.ToInt64(r["OrganizationId"]),
        Convert.ToInt64(r["DefinitionId"]),
        Convert.ToInt64(r["DefinitionVersionId"]),
        r["DefinitionCode"]?.ToString() ?? "",
        r["DefinitionName"]?.ToString() ?? "",
        Convert.ToInt32(r["VersionNumber"]),
        r["ExecutionCode"]?.ToString() ?? "",
        r["ExecutionName"]?.ToString() ?? "",
        r["StatusCode"]?.ToString() ?? "",
        r["StatusName"]?.ToString() ?? "",
        Convert.ToBoolean(r["StatusIsTerminal"]),
        r["OriginType"]?.ToString() ?? "",
        ReadLongOrNull(r,     "PlanId"),
        ReadLongOrNull(r,     "PlanItemId"),
        ReadLongOrNull(r,     "TriggerConfigId"),
        Convert.ToInt64(r["ScopeResolutionId"]),
        ReadStringOrNull(r, "DefinitionSnapshotJson"),
        ReadStringOrNull(r, "QuestionsSnapshotJson"),
        ReadStringOrNull(r, "EvidenceSnapshotJson"),
        ReadStringOrNull(r, "WorkflowSnapshotJson"),
        ReadStringOrNull(r, "ScoringSnapshotJson"),
        // 120 hybrid role+employee Owner
        ReadLongOrNull(r,   "OwnerRoleId"),
        ReadStringOrNull(r, "OwnerRoleName"),
        ReadLongOrNull(r,   "OwnerEmployeeId"),
        ReadStringOrNull(r, "OwnerDisplayName"),
        ReadStringOrNull(r, "AssignedTeamName"),
        ReadDateTimeOrNull(r, "PlannedStartDt"),
        ReadDateTimeOrNull(r, "PlannedEndDt"),
        ReadDateTimeOrNull(r, "ActualStartDt"),
        ReadDateTimeOrNull(r, "ActualEndDt"),
        Convert.ToInt64(r["TotalEntityCount"]),
        Convert.ToInt64(r["CompletedEntityCount"]),
        ReadStringOrNull(r, "Notes"),
        ReadStringOrNull(r, "EnteredBy"),
        ReadDateTimeOrNull(r, "EnteredDt"),
        ReadStringOrNull(r, "UpdatedBy"),
        ReadDateTimeOrNull(r, "UpdatedDt"),
        // 555 -- tolerant: a database before 555 has no scope-freeze columns.
        HasColumn(r, "ScopeFrozenAt")       ? ReadDateTimeOrNull(r, "ScopeFrozenAt") : ReadDateTimeOrNull(r, "EnteredDt"),
        HasColumn(r, "ScopeFrozenBy")       ? ReadStringOrNull(r, "ScopeFrozenBy")   : null,
        HasColumn(r, "ScopeExclusionCount") ? (ReadIntOrNull(r, "ScopeExclusionCount") ?? 0) : 0);

    private static OrgAssuranceExecutionEntityRow MapEntityRow(DbDataReader r) => new(
        Convert.ToInt64(r["ExecutionEntityId"]),
        r["DimensionCode"]?.ToString() ?? "",
        ReadStringOrNull(r, "DimensionName"),
        ReadLongOrNull(r,   "EntityId"),
        ReadStringOrNull(r, "EntityCode"),
        ReadStringOrNull(r, "EntityName"),
        ReadIntOrNull(r,    "SourceGroupOrder"),
        ReadIntOrNull(r,    "SourceConditionOrder"),
        r["EntityStatusCode"]?.ToString() ?? "",
        ReadDateTimeOrNull(r, "StartedDt"),
        ReadDateTimeOrNull(r, "CompletedDt"),
        // 120 hybrid role+employee Auditor
        ReadLongOrNull(r,   "AssignedAuditorRoleId"),
        ReadStringOrNull(r, "AssignedAuditorRoleName"),
        ReadLongOrNull(r,   "AssignedAuditorEmployeeId"),
        ReadStringOrNull(r, "AssignedAuditorName"));

    // THROW numbers used in 099 (54008-54099).
    private static string MapReason(int errorNumber) => errorNumber switch
    {
        54008 => "ORGANIZATION_ID_REQUIRED",
        54009 => "IDS_REQUIRED",
        54010 => "EXECUTION_NOT_FOUND",
        54011 => "DEFINITION_ID_REQUIRED",
        54012 => "SCOPE_RESOLUTION_ID_REQUIRED",
        54013 => "INVALID_ORIGIN_TYPE",
        54014 => "DEFINITION_NOT_FOUND",
        54015 => "DEFINITION_WRONG_ORGANIZATION",
        54016 => "VERSION_MISSING",
        54017 => "VERSION_NOT_FOUND",
        54018 => "VERSION_NOT_MATERIALIZABLE",
        54019 => "SCOPE_RESOLUTION_NOT_FOUND",
        54020 => "SCOPE_WRONG_ORGANIZATION",
        54021 => "SCOPE_VERSION_MISMATCH",
        54022 => "PLAN_ORIGIN_MISSING_IDS",
        54023 => "TRIGGER_ORIGIN_MISSING_ID",
        54024 => "DUPLICATE_EXECUTION_CODE",
        54025 => "STATUS_LOOKUP_FAILED",
        54026 => "ILLEGAL_TRANSITION",
        54027 => "DELETE_NOT_ALLOWED_IN_STATUS",
        // 120 -- entity auditor assign
        54080 => "AUDITOR_ASSIGN_IDS_REQUIRED",
        54081 => "AUDITOR_ASSIGN_ENTITY_NOT_FOUND",
        54082 => "AUDITOR_ASSIGN_TERMINAL_EXECUTION",
        // 555 -- live scope / Freeze Scope
        54030 => "SCOPE_LIVE",
        54031 => "SCOPE_ALREADY_FROZEN",
        54032 => "NOT_ASSIGNED_AUDITOR",
        54033 => "FREEZE_NOT_PLANNED",
        54034 => "EXCLUSION_INVALID",
        54035 => "SCOPE_EMPTY",
        54036 => "EMPLOYEE_REQUIRED",
        // 563 -- Step 3 Review and Confirm
        54037 => "REVIEW_INVALID",
        54038 => "REVIEW_MANUAL_NAME_REQUIRED",
        54039 => "REVIEW_UNKNOWN_CATEGORY",
        // 558 -- question responses
        54040 => "RESPONSE_NOT_IN_PROGRESS",
        54041 => "RESPONSE_NOT_ASSIGNED_AUDITOR",
        54042 => "RESPONSE_QUESTION_NOT_IN_EXECUTION",
        54043 => "RESPONSE_RESULT_INVALID",
        54044 => "RESPONSE_DESCRIPTION_OWNER_REQUIRED",
        54045 => "RESPONSE_FINDING_PAST_OPEN",
        54046 => "RESPONSE_EMPLOYEE_REQUIRED",
        // 567 -- Submit needs the working papers done
        54064 => "WORKPAPERS_INCOMPLETE",
        // observation procedures called by the response save
        54109 => "OBSERVATION_CODE_EXISTS",
        54112 => "OBSERVATION_NOT_EDITABLE",
        54113 => "OBSERVATION_NOT_DELETABLE",
        _     => "SQL_ERROR"
    };
}
