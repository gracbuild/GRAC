// =====================================================================
// OrgAssurancePlanService
//
// Phase 2 Assurance Management -- Stage 3 Assurance Plans service.
//
// Thin wrapper over the sp_org_assurance_plan_* stored procedures
// (migration 090). Mirrors TaskService / OrgAssuranceQuestionService
// conventions.
//
// Wire-up: Infrastructure/OrgAssurancePlanServiceRegistration.cs.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IOrgAssurancePlanService
{
    Task<IReadOnlyList<OrgAssurancePlanStatusRow>> ListStatusesAsync(CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssurancePlanTypeRow>>   ListPlanTypesAsync(CancellationToken cancellationToken);

    // Plans
    Task<OrgAssurancePlanListResult> ListAsync(
        OrgAssurancePlanListQuery query, CancellationToken cancellationToken);
    Task<OrgAssurancePlanDetail?> GetAsync(
        long organizationId, long planId, CancellationToken cancellationToken);
    Task<OrgAssurancePlanSaveResult> SaveAsync(
        OrgAssurancePlanSaveRequest request, CancellationToken cancellationToken);
    Task<OrgAssurancePlanCommandResult> DeleteAsync(
        OrgAssurancePlanCommandRequest request, CancellationToken cancellationToken);

    // Lifecycle
    Task<OrgAssurancePlanCommandResult> SubmitAsync(
        OrgAssurancePlanCommandRequest request, CancellationToken cancellationToken);
    Task<OrgAssurancePlanCommandResult> ApproveAsync(
        OrgAssurancePlanCommandRequest request, CancellationToken cancellationToken);
    Task<OrgAssurancePlanCommandResult> ActivateAsync(
        OrgAssurancePlanCommandRequest request, CancellationToken cancellationToken);
    Task<OrgAssurancePlanCommandResult> CloseAsync(
        OrgAssurancePlanCommandRequest request, CancellationToken cancellationToken);

    // Items
    Task<IReadOnlyList<OrgAssurancePlanItemRow>> ListItemsAsync(
        long organizationId, long planId, CancellationToken cancellationToken);
    Task<OrgAssurancePlanItemSaveResult> SaveItemAsync(
        OrgAssurancePlanItemSaveRequest request, CancellationToken cancellationToken);
    Task<OrgAssurancePlanCommandResult> DeleteItemAsync(
        long organizationId, long planId, long planItemId, string? actor, CancellationToken cancellationToken);
    // 546: a plan slot becomes an execution.
    // 552: engagements
    Task<IReadOnlyList<OrgAssuranceEngagementDefinitionRow>> ListEngagementDefinitionsAsync(
        long organizationId, long planItemId, CancellationToken cancellationToken);
    Task<OrgAssuranceEngagementScopeResult> PreviewEngagementScopeAsync(
        OrgAssuranceEngagementScopeRequest request, CancellationToken cancellationToken);
    Task<OrgAssurancePlanItemExecutionResult> StartItemExecutionAsync(
        long organizationId, long planId, long planItemId, string? actor, CancellationToken cancellationToken);

    // 565: programmes, planning methodologies, plan revisions
    Task<IReadOnlyList<OrgAssurancePlanningMethodologyRow>> ListPlanningMethodologiesAsync(CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssurancePlanProgrammeRow>> ListProgrammesAsync(
        long organizationId, long planId, CancellationToken cancellationToken);
    Task<OrgAssurancePlanProgrammeSaveResult> SaveProgrammeAsync(
        OrgAssurancePlanProgrammeSaveRequest request, CancellationToken cancellationToken);
    Task<OrgAssurancePlanCommandResult> DeleteProgrammeAsync(
        long organizationId, long planId, long programmeId, string? actor, CancellationToken cancellationToken);
    Task<OrgAssurancePlanCommandResult> ReviseAsync(
        OrgAssurancePlanReviseRequest request, CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssurancePlanRevisionRow>> ListRevisionsAsync(
        long organizationId, long planId, CancellationToken cancellationToken);

    // 566: Audit Engagements (planned and independent) and their team
    Task<IReadOnlyList<OrgAssuranceEngagementInitiationRow>> ListInitiationSourcesAsync(CancellationToken cancellationToken);
    Task<OrgAssuranceEngagementListResult> ListEngagementsAsync(
        OrgAssuranceEngagementListQuery query, CancellationToken cancellationToken);
    Task<OrgAssuranceEngagementDetail?> GetEngagementAsync(
        long organizationId, long engagementId, CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssuranceEngagementTeamRow>> ListEngagementTeamAsync(
        long organizationId, long engagementId, bool includeHistory, CancellationToken cancellationToken);
    Task<OrgAssurancePlanCommandResult> SaveEngagementTeamAsync(
        long engagementId, OrgAssuranceEngagementTeamSaveRequest request, CancellationToken cancellationToken);
    Task<OrgAssurancePlanCommandResult> ApproveEngagementAsync(
        long engagementId, OrgAssuranceEngagementCommandRequest request, CancellationToken cancellationToken);
    Task<OrgAssurancePlanCommandResult> CancelEngagementAsync(
        long engagementId, OrgAssuranceEngagementCommandRequest request, CancellationToken cancellationToken);
    Task<OrgAssurancePlanCommandResult> DeleteEngagementAsync(
        long organizationId, long engagementId, string? actor, CancellationToken cancellationToken);
}

public sealed class OrgAssurancePlanService(
    IConfiguration configuration,
    ILogger<OrgAssurancePlanService> logger) : IOrgAssurancePlanService
{
    // -----------------------------------------------------------------
    // Lookups
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssurancePlanStatusRow>> ListStatusesAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_plan_status_list";

        var rows = new List<OrgAssurancePlanStatusRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssurancePlanStatusRow(
                Convert.ToInt32(reader["StatusId"]),
                reader["StatusCode"]?.ToString() ?? "",
                reader["StatusName"]?.ToString() ?? "",
                Convert.ToInt32(reader["DisplayOrder"]),
                Convert.ToBoolean(reader["IsTerminal"])));
        }
        return rows;
    }

    public async Task<IReadOnlyList<OrgAssurancePlanTypeRow>> ListPlanTypesAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_plan_type_list";

        var rows = new List<OrgAssurancePlanTypeRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssurancePlanTypeRow(
                reader["PlanTypeCode"]?.ToString() ?? "",
                reader["PlanTypeName"]?.ToString() ?? "",
                Convert.ToInt32(reader["DisplayOrder"])));
        }
        return rows;
    }

    // -----------------------------------------------------------------
    // Plans
    // -----------------------------------------------------------------
    public async Task<OrgAssurancePlanListResult> ListAsync(
        OrgAssurancePlanListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_plan_list";

        AddParam(command, "@organization_id", DbType.Int64,  query.OrganizationId);
        AddParam(command, "@status_code",     DbType.String, (object?)query.StatusCode ?? DBNull.Value, 60);
        AddParam(command, "@plan_type",       DbType.String, (object?)query.PlanType   ?? DBNull.Value, 30);
        AddParam(command, "@search",          DbType.String, (object?)query.Search     ?? DBNull.Value, 200);
        AddParam(command, "@page",            DbType.Int32,  Math.Max(1, query.Page));
        AddParam(command, "@page_size",       DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));

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

        var rows = new List<OrgAssurancePlanListRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(MapListRow(reader));
        }
        return new OrgAssurancePlanListResult(total, page, size, rows);
    }

    public async Task<OrgAssurancePlanDetail?> GetAsync(
        long organizationId, long planId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_plan_get";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@plan_id",         DbType.Int64, planId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await reader.ReadAsync(cancellationToken) ? MapDetailRow(reader) : null;
    }

    public async Task<OrgAssurancePlanSaveResult> SaveAsync(
        OrgAssurancePlanSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.PlanCode))
            return new OrgAssurancePlanSaveResult(false, Error: "PlanCode is required.");
        if (string.IsNullOrWhiteSpace(request.PlanName))
            return new OrgAssurancePlanSaveResult(false, Error: "PlanName is required.");
        if (string.IsNullOrWhiteSpace(request.PlanType))
            return new OrgAssurancePlanSaveResult(false, Error: "PlanType is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_plan_save";

            AddParam(command, "@organization_id",    DbType.Int64,  request.OrganizationId);
            AddParam(command, "@plan_id",            DbType.Int64,  (object?)request.PlanId ?? DBNull.Value);
            AddParam(command, "@plan_code",          DbType.String, request.PlanCode.Trim(), 80);
            AddParam(command, "@plan_name",          DbType.String, request.PlanName.Trim(), 240);
            AddParam(command, "@plan_type",          DbType.String, request.PlanType.Trim().ToUpperInvariant(), 30);
            AddParam(command, "@period_from",        DbType.Date,   (object?)request.PeriodFrom ?? DBNull.Value);
            AddParam(command, "@period_to",          DbType.Date,   (object?)request.PeriodTo   ?? DBNull.Value);
            // 121 hybrid role+employee Owner -- SP auto-resolves whichever side is missing.
            AddParam(command, "@owner_role_id",      DbType.Int64,  (object?)request.OwnerRoleId ?? DBNull.Value);
            AddParam(command, "@owner_role_name",    DbType.String, (object?)request.OwnerRoleName ?? DBNull.Value, 120);
            AddParam(command, "@owner_employee_id",  DbType.Int64,  (object?)request.OwnerEmployeeId ?? DBNull.Value);
            AddParam(command, "@owner_display_name", DbType.String, (object?)request.OwnerDisplayName ?? DBNull.Value, 240);
            AddParam(command, "@description",        DbType.String, (object?)request.Description ?? DBNull.Value, -1);
            // 565: annual plan fields
            AddParam(command, "@financial_year",      DbType.String,  (object?)request.FinancialYear ?? DBNull.Value, 40);
            AddParam(command, "@objectives",          DbType.String,  (object?)request.Objectives ?? DBNull.Value, -1);
            AddParam(command, "@planned_coverage",    DbType.String,  (object?)request.PlannedCoverage ?? DBNull.Value, -1);
            AddParam(command, "@planned_budget",      DbType.Decimal, (object?)request.PlannedBudget ?? DBNull.Value);
            AddParam(command, "@budget_currency",     DbType.String,  (object?)request.BudgetCurrency ?? DBNull.Value, 10);
            AddParam(command, "@planned_effort_days", DbType.Decimal, (object?)request.PlannedEffortDays ?? DBNull.Value);
            AddParam(command, "@resources_note",      DbType.String,  (object?)request.ResourcesNote ?? DBNull.Value, 2000);
            AddParam(command, "@actor",              DbType.String, (object?)request.Actor ?? (object)"system", 100);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@plan_id_out";
            idOut.DbType        = DbType.Int64;
            idOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idOut);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idOut.Value is long l ? l : Convert.ToInt64(idOut.Value);
            return new OrgAssurancePlanSaveResult(true, id);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssurancePlanService.SaveAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssurancePlanSaveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    public async Task<OrgAssurancePlanCommandResult> DeleteAsync(
        OrgAssurancePlanCommandRequest request, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_plan_delete";

            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@plan_id",         DbType.Int64,  request.PlanId);
            AddParam(command, "@actor",           DbType.String, (object?)request.Actor ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssurancePlanCommandResult(true, request.PlanId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssurancePlanService.DeleteAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssurancePlanCommandResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // Lifecycle transitions -- each uses its own SP so error-mapping stays clear.
    public Task<OrgAssurancePlanCommandResult> SubmitAsync  (OrgAssurancePlanCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_plan_submit",   r, ct);
    public Task<OrgAssurancePlanCommandResult> ApproveAsync (OrgAssurancePlanCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_plan_approve",  r, ct);
    public Task<OrgAssurancePlanCommandResult> ActivateAsync(OrgAssurancePlanCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_plan_activate", r, ct);
    public Task<OrgAssurancePlanCommandResult> CloseAsync   (OrgAssurancePlanCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_plan_close",    r, ct);

    private async Task<OrgAssurancePlanCommandResult> TransitionAsync(
        string procName, OrgAssurancePlanCommandRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.PlanId <= 0)
            return new OrgAssurancePlanCommandResult(false, Error: "PlanId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = procName;

            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@plan_id",         DbType.Int64,  request.PlanId);
            AddParam(command, "@actor",           DbType.String, (object?)request.Actor ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssurancePlanCommandResult(true, request.PlanId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssurancePlanService.{Proc} SQL error {Number}: {Message}",
                procName, ex.Number, ex.Message);
            return new OrgAssurancePlanCommandResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // -----------------------------------------------------------------
    // Plan items
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssurancePlanItemRow>> ListItemsAsync(
        long organizationId, long planId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_plan_item_list";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@plan_id",         DbType.Int64, planId);

        var rows = new List<OrgAssurancePlanItemRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(MapItemRow(reader));
        return rows;
    }

    public async Task<OrgAssurancePlanItemSaveResult> SaveItemAsync(
        OrgAssurancePlanItemSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        // 566: an independent engagement needs no plan; a planned one does.
        var independent = string.Equals(request.EngagementOrigin, "INDEPENDENT", StringComparison.OrdinalIgnoreCase)
                          || (request.EngagementOrigin is null && request.PlanItemId is null && request.PlanId is null or <= 0);
        if (!independent && request.PlanId is null or <= 0)
            return new OrgAssurancePlanItemSaveResult(false, Error: "PlanId is required.");
        // 552: DefinitionIds (in order) or the single DefinitionId.
        var definitionIds = (request.DefinitionIds ?? []).Where(x => x > 0).ToList();
        if (definitionIds.Count == 0 && request.DefinitionId > 0) definitionIds.Add(request.DefinitionId);
        if (definitionIds.Count == 0) return new OrgAssurancePlanItemSaveResult(false, Error: "Pick at least one audit.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_plan_item_save";

            AddParam(command, "@organization_id",                DbType.Int64,  request.OrganizationId);
            AddParam(command, "@plan_id",                        DbType.Int64,  request.PlanId is > 0 ? (object)request.PlanId.Value : DBNull.Value);
            AddParam(command, "@plan_item_id",                   DbType.Int64,  (object?)request.PlanItemId ?? DBNull.Value);
            AddParam(command, "@org_assurance_definition_id",    DbType.Int64,  definitionIds[0]);
            AddParam(command, "@definition_code",                DbType.String, (object?)request.DefinitionCode ?? DBNull.Value, 80);
            AddParam(command, "@definition_name",                DbType.String, (object?)request.DefinitionName ?? DBNull.Value, 240);
            AddParam(command, "@item_order",                     DbType.Int32,  request.ItemOrder ?? 0);
            AddParam(command, "@scheduled_from",                 DbType.Date,   (object?)request.ScheduledFrom ?? DBNull.Value);
            AddParam(command, "@scheduled_to",                   DbType.Date,   (object?)request.ScheduledTo   ?? DBNull.Value);
            // 121 hybrid role+employee Auditor -- SP auto-resolves whichever side is missing.
            AddParam(command, "@assigned_auditor_role_id",       DbType.Int64,  (object?)request.AssignedAuditorRoleId ?? DBNull.Value);
            AddParam(command, "@assigned_auditor_role_name",     DbType.String, (object?)request.AssignedAuditorRoleName ?? DBNull.Value, 120);
            AddParam(command, "@assigned_auditor_employee_id",   DbType.Int64,  (object?)request.AssignedAuditorEmployeeId ?? DBNull.Value);
            AddParam(command, "@assigned_auditor_name",          DbType.String, (object?)request.AssignedAuditorName ?? DBNull.Value, 240);
            AddParam(command, "@assigned_team_name",             DbType.String, (object?)request.AssignedTeamName ?? DBNull.Value, 200);
            AddParam(command, "@assigned_department_id",         DbType.Int64,  (object?)request.AssignedDepartmentId ?? DBNull.Value);
            AddParam(command, "@assigned_department_name",       DbType.String, (object?)request.AssignedDepartmentName ?? DBNull.Value, 200);
            AddParam(command, "@assigned_branch_id",             DbType.Int64,  (object?)request.AssignedBranchId ?? DBNull.Value);
            AddParam(command, "@assigned_branch_name",           DbType.String, (object?)request.AssignedBranchName ?? DBNull.Value, 200);
            AddParam(command, "@notes",                          DbType.String, (object?)request.Notes ?? DBNull.Value, -1);
            // 552: the engagement's name and audits; camelCase keys for the
            // procedure's JSON_VALUE('$.definitionId').
            AddParam(command, "@engagement_name",                DbType.String, (object?)request.EngagementName ?? DBNull.Value, 240);
            AddParam(command, "@definitions_json",               DbType.String,
                System.Text.Json.JsonSerializer.Serialize(definitionIds.Select(x => new { definitionId = x })), -1);
            if (request.ProgrammeId is > 0)   // 565: sent only when picked (the procedure falls back to the plan's only programme)
                AddParam(command, "@programme_id",               DbType.Int64,  request.ProgrammeId.Value);
            // 566: the engagement record and its team (null team = left as it is).
            AddParam(command, "@engagement_origin",              DbType.String, (object?)request.EngagementOrigin ?? DBNull.Value, 20);
            AddParam(command, "@audit_subject",                  DbType.String, (object?)request.AuditSubject ?? DBNull.Value, 400);
            AddParam(command, "@engagement_objective",           DbType.String, (object?)request.EngagementObjective ?? DBNull.Value, -1);
            AddParam(command, "@scope_summary",                  DbType.String, (object?)request.ScopeSummary ?? DBNull.Value, -1);
            AddParam(command, "@auditee_role_id",                DbType.Int64,  (object?)request.AuditeeRoleId ?? DBNull.Value);
            AddParam(command, "@auditee_role_name",              DbType.String, (object?)request.AuditeeRoleName ?? DBNull.Value, 120);
            AddParam(command, "@auditee_employee_id",            DbType.Int64,  (object?)request.AuditeeEmployeeId ?? DBNull.Value);
            AddParam(command, "@auditee_name",                   DbType.String, (object?)request.AuditeeName ?? DBNull.Value, 240);
            AddParam(command, "@engagement_instructions",        DbType.String, (object?)request.EngagementInstructions ?? DBNull.Value, -1);
            AddParam(command, "@team_remarks",                   DbType.String, (object?)request.TeamRemarks ?? DBNull.Value, 2000);
            AddParam(command, "@team_json",                      DbType.String, (object?)TeamJson(request.Team) ?? DBNull.Value, -1);
            AddParam(command, "@initiation_source_code",         DbType.String, (object?)request.InitiationSourceCode ?? DBNull.Value, 40);
            AddParam(command, "@initiation_reason",              DbType.String, (object?)request.InitiationReason ?? DBNull.Value, 2000);
            AddParam(command, "@approval_reference",             DbType.String, (object?)request.ApprovalReference ?? DBNull.Value, 200);
            AddParam(command, "@actor",                          DbType.String, (object?)request.Actor ?? (object)"system", 100);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@plan_item_id_out";
            idOut.DbType        = DbType.Int64;
            idOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idOut);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idOut.Value is long l ? l : Convert.ToInt64(idOut.Value);
            return new OrgAssurancePlanItemSaveResult(true, id);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssurancePlanService.SaveItemAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssurancePlanItemSaveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    public async Task<OrgAssurancePlanCommandResult> DeleteItemAsync(
        long organizationId, long planId, long planItemId, string? actor, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_plan_item_delete";

            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@plan_id",         DbType.Int64,  planId);
            AddParam(command, "@plan_item_id",    DbType.Int64,  planItemId);
            AddParam(command, "@actor",           DbType.String, (object?)actor ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssurancePlanCommandResult(true, planItemId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssurancePlanService.DeleteItemAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssurancePlanCommandResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // -----------------------------------------------------------------
    // 546: Start Execution from a plan slot. The procedure checks the slot,
    // the plan (Approved / Active), the audit (Active) and that the slot
    // has no live execution, then materializes it (origin PLAN; the scope
    // is resolved now, 545) and returns the new execution's row.
    // -----------------------------------------------------------------
    public async Task<OrgAssurancePlanItemExecutionResult> StartItemExecutionAsync(
        long organizationId, long planId, long planItemId, string? actor, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_plan_item_start_execution";

            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@plan_id",         DbType.Int64,  planId > 0 ? (object)planId : DBNull.Value);   // 566: none for an independent engagement
            AddParam(command, "@plan_item_id",    DbType.Int64,  planItemId);
            AddParam(command, "@actor",           DbType.String, (object?)actor ?? (object)"system", 100);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@execution_id_out";
            idOut.DbType        = DbType.Int64;
            idOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idOut);

            // 552: one row per execution started.
            var started = new List<OrgAssuranceStartedExecutionRow>();
            await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                {
                    started.Add(new OrgAssuranceStartedExecutionRow(
                        Convert.ToInt64(reader["ExecutionId"]),
                        ReadStringOrNull(reader, "ExecutionCode"),
                        ReadStringOrNull(reader, "ExecutionName"),
                        HasColumn(reader, "DefinitionCode") ? ReadStringOrNull(reader, "DefinitionCode") : null,
                        ReadLongOrNull(reader,   "TotalEntityCount")));
                }
            }
            var id = idOut.Value is long l ? l : Convert.ToInt64(idOut.Value);
            var first = started.FirstOrDefault();
            return new OrgAssurancePlanItemExecutionResult(true, id, first?.ExecutionCode, first?.ExecutionName,
                first?.TotalEntityCount, Executions: started);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssurancePlanService.StartItemExecutionAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssurancePlanItemExecutionResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // -----------------------------------------------------------------
    // 552: an engagement's audits, and its View Scope (live, nothing saved)
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceEngagementDefinitionRow>> ListEngagementDefinitionsAsync(
        long organizationId, long planItemId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_engagement_definition_list";
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@plan_item_id",    DbType.Int64, planItemId);

        var rows = new List<OrgAssuranceEngagementDefinitionRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceEngagementDefinitionRow(
                Convert.ToInt64(reader["EngagementDefinitionId"]),
                Convert.ToInt64(reader["DefinitionId"]),
                ReadStringOrNull(reader, "DefinitionCode"),
                ReadStringOrNull(reader, "DefinitionName"),
                Convert.ToInt32(reader["DisplayOrder"]),
                ReadStringOrNull(reader, "DefinitionStatusCode"),
                ReadStringOrNull(reader, "DefinitionStatusName"),
                reader["ActiveVersionNumber"] == DBNull.Value ? (int?)null : Convert.ToInt32(reader["ActiveVersionNumber"]),
                reader["IsPlannable"] != DBNull.Value && Convert.ToBoolean(reader["IsPlannable"]),
                ReadLongOrNull(reader,   "ExecutionId"),
                ReadStringOrNull(reader, "ExecutionCode"),
                ReadStringOrNull(reader, "ExecutionStatusCode"),
                ReadStringOrNull(reader, "ExecutionStatusName")));
        }
        return rows;
    }

    public async Task<OrgAssuranceEngagementScopeResult> PreviewEngagementScopeAsync(
        OrgAssuranceEngagementScopeRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType    = CommandType.StoredProcedure;
        command.CommandText    = "grac_practice.sp_org_assurance_engagement_scope_preview";
        command.CommandTimeout = 120;   // one resolver run per audit
        var ids = (request.DefinitionIds ?? []).Where(x => x > 0).ToList();
        AddParam(command, "@organization_id",  DbType.Int64,  request.OrganizationId);
        AddParam(command, "@plan_item_id",     DbType.Int64,  (object?)request.PlanItemId ?? DBNull.Value);
        AddParam(command, "@definitions_json", DbType.String,
            ids.Count == 0 ? DBNull.Value : (object)System.Text.Json.JsonSerializer.Serialize(ids.Select(x => new { definitionId = x })), -1);
        AddParam(command, "@location_id",      DbType.Int64,  request.LocationId is > 0 ? (object)request.LocationId.Value : DBNull.Value);   // 554
        AddParam(command, "@actor",            DbType.String, (object?)request.Actor ?? (object)"system", 100);

        var dims = new List<OrgAssuranceEngagementScopeDimensionRow>();
        var ents = new List<OrgAssuranceEngagementScopeEntityRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            dims.Add(new OrgAssuranceEngagementScopeDimensionRow(
                ReadStringOrNull(reader, "DimensionCode"),
                ReadStringOrNull(reader, "DimensionName"),
                Convert.ToInt32(reader["EntityCount"])));
        if (await reader.NextResultAsync(cancellationToken))
            while (await reader.ReadAsync(cancellationToken))
                ents.Add(new OrgAssuranceEngagementScopeEntityRow(
                    ReadStringOrNull(reader, "DimensionCode"),
                    ReadStringOrNull(reader, "DimensionName"),
                    ReadLongOrNull(reader,   "EntityId"),
                    ReadStringOrNull(reader, "EntityCode"),
                    ReadStringOrNull(reader, "EntityName"),
                    ReadStringOrNull(reader, "DefinitionCodes")));
        return new OrgAssuranceEngagementScopeResult(dims, ents);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------
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

    // -----------------------------------------------------------------
    // 565: programmes, planning methodologies, plan revisions
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssurancePlanningMethodologyRow>> ListPlanningMethodologiesAsync(
        CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_planning_methodology_list";
        var rows = new List<OrgAssurancePlanningMethodologyRow>();
        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
            rows.Add(new OrgAssurancePlanningMethodologyRow(
                Convert.ToInt32(r["Id"]),
                r["Code"]?.ToString() ?? "",
                r["Name"]?.ToString() ?? "",
                ReadStringOrNull(r, "Description")));
        return rows;
    }

    public async Task<IReadOnlyList<OrgAssurancePlanProgrammeRow>> ListProgrammesAsync(
        long organizationId, long planId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_plan_programme_list";
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@plan_id",         DbType.Int64, planId);
        var rows = new List<OrgAssurancePlanProgrammeRow>();
        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
            rows.Add(new OrgAssurancePlanProgrammeRow(
                Convert.ToInt64(r["ProgrammeId"]),
                Convert.ToInt64(r["PlanId"]),
                r["ProgrammeCode"]?.ToString() ?? "",
                r["ProgrammeName"]?.ToString() ?? "",
                ReadStringOrNull(r, "Objective"),
                ReadIntOrNull(r,    "PlanningMethodologyId"),
                ReadStringOrNull(r, "MethodologyCode"),
                ReadStringOrNull(r, "MethodologyName"),
                ReadLongOrNull(r,   "OwnerRoleId"),
                ReadStringOrNull(r, "OwnerRoleName"),
                ReadLongOrNull(r,   "OwnerEmployeeId"),
                ReadStringOrNull(r, "OwnerDisplayName"),
                ReadIntOrNull(r,    "DisplayOrder") ?? 0,
                r["IsDefault"] != DBNull.Value && Convert.ToBoolean(r["IsDefault"]),
                ReadIntOrNull(r,    "EngagementCount") ?? 0,
                ReadIntOrNull(r,    "EngagementInProgressCount") ?? 0,
                ReadIntOrNull(r,    "EngagementCompletedCount") ?? 0));
        return rows;
    }

    public async Task<OrgAssurancePlanProgrammeSaveResult> SaveProgrammeAsync(
        OrgAssurancePlanProgrammeSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.ProgrammeName))
            return new OrgAssurancePlanProgrammeSaveResult(false, Error: "The programme needs a name.", ReasonCode: "PROGRAMME_NAME_REQUIRED");
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_plan_programme_save";
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@plan_id",                 DbType.Int64,  request.PlanId);
            AddParam(command, "@programme_id",            DbType.Int64,  (object?)request.ProgrammeId ?? DBNull.Value);
            AddParam(command, "@programme_name",          DbType.String, request.ProgrammeName.Trim(), 240);
            AddParam(command, "@objective",               DbType.String, (object?)request.Objective ?? DBNull.Value, -1);
            AddParam(command, "@planning_methodology_id", DbType.Int32,  (object?)request.PlanningMethodologyId ?? DBNull.Value);
            AddParam(command, "@owner_role_id",           DbType.Int64,  (object?)request.OwnerRoleId ?? DBNull.Value);
            AddParam(command, "@owner_role_name",         DbType.String, (object?)request.OwnerRoleName ?? DBNull.Value, 120);
            AddParam(command, "@owner_employee_id",       DbType.Int64,  (object?)request.OwnerEmployeeId ?? DBNull.Value);
            AddParam(command, "@owner_display_name",      DbType.String, (object?)request.OwnerDisplayName ?? DBNull.Value, 240);
            AddParam(command, "@display_order",           DbType.Int32,  (object?)request.DisplayOrder ?? DBNull.Value);
            AddParam(command, "@actor",                   DbType.String, (object?)request.Actor ?? (object)"system", 100);
            var idOut = command.CreateParameter();
            idOut.ParameterName = "@programme_id_out";
            idOut.DbType        = DbType.Int64;
            idOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idOut);
            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssurancePlanProgrammeSaveResult(true, Convert.ToInt64(idOut.Value));
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssurancePlanService.SaveProgrammeAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new OrgAssurancePlanProgrammeSaveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    public async Task<OrgAssurancePlanCommandResult> DeleteProgrammeAsync(
        long organizationId, long planId, long programmeId, string? actor, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_plan_programme_delete";
            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@plan_id",         DbType.Int64,  planId);
            AddParam(command, "@programme_id",    DbType.Int64,  programmeId);
            AddParam(command, "@actor",           DbType.String, (object?)actor ?? (object)"system", 100);
            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssurancePlanCommandResult(true, planId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssurancePlanService.DeleteProgrammeAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new OrgAssurancePlanCommandResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    public async Task<OrgAssurancePlanCommandResult> ReviseAsync(
        OrgAssurancePlanReviseRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.Reason))
            return new OrgAssurancePlanCommandResult(false, Error: "Give the reason for revising the plan.", ReasonCode: "REVISION_NOT_ALLOWED");
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_plan_revise";
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@plan_id",         DbType.Int64,  request.PlanId);
            AddParam(command, "@reason",          DbType.String, request.Reason.Trim(), 2000);
            AddParam(command, "@actor",           DbType.String, (object?)request.Actor ?? (object)"system", 100);
            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssurancePlanCommandResult(true, request.PlanId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssurancePlanService.ReviseAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new OrgAssurancePlanCommandResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    public async Task<IReadOnlyList<OrgAssurancePlanRevisionRow>> ListRevisionsAsync(
        long organizationId, long planId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_plan_revision_list";
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@plan_id",         DbType.Int64, planId);
        var rows = new List<OrgAssurancePlanRevisionRow>();
        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
            rows.Add(new OrgAssurancePlanRevisionRow(
                Convert.ToInt64(r["RevisionId"]),
                Convert.ToInt32(r["FromVersion"]),
                Convert.ToInt32(r["ToVersion"]),
                ReadStringOrNull(r,   "FromStatusCode"),
                r["Reason"]?.ToString() ?? "",
                ReadStringOrNull(r,   "SnapshotJson"),
                ReadStringOrNull(r,   "RevisedBy"),
                ReadDateTimeOrNull(r, "RevisedDt")));
        return rows;
    }

    // -----------------------------------------------------------------
    // 566: Audit Engagements (planned and independent), their team,
    // approval (independent), cancellation and deletion.
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceEngagementInitiationRow>> ListInitiationSourcesAsync(
        CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_engagement_initiation_list";
        var rows = new List<OrgAssuranceEngagementInitiationRow>();
        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
            rows.Add(new OrgAssuranceEngagementInitiationRow(r["Code"].ToString()!, ReadStringOrNull(r, "Name")));
        return rows;
    }

    public async Task<OrgAssuranceEngagementListResult> ListEngagementsAsync(
        OrgAssuranceEngagementListQuery query, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_engagement_list";
        AddParam(command, "@organization_id", DbType.Int64,  query.OrganizationId);
        AddParam(command, "@status",          DbType.String, (object?)query.Status ?? DBNull.Value, 30);
        AddParam(command, "@origin",          DbType.String, (object?)query.Origin ?? DBNull.Value, 20);
        AddParam(command, "@plan_id",         DbType.Int64,  query.PlanId is > 0 ? (object)query.PlanId.Value : DBNull.Value);
        AddParam(command, "@search",          DbType.String, (object?)query.Search ?? DBNull.Value, 200);
        AddParam(command, "@page",            DbType.Int32,  query.Page);
        AddParam(command, "@page_size",       DbType.Int32,  query.PageSize);

        long total = 0; int page = query.Page, size = query.PageSize;
        var rows = new List<OrgAssuranceEngagementRow>();
        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        if (await r.ReadAsync(cancellationToken))
        {
            total = Convert.ToInt64(r["TotalCount"]);
            page  = Convert.ToInt32(r["PageNumber"]);
            size  = Convert.ToInt32(r["PageSize"]);
        }
        if (await r.NextResultAsync(cancellationToken))
            while (await r.ReadAsync(cancellationToken))
                rows.Add(MapEngagementRow(r));
        return new OrgAssuranceEngagementListResult(total, page, size, rows);
    }

    public async Task<OrgAssuranceEngagementDetail?> GetEngagementAsync(
        long organizationId, long engagementId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_engagement_get";
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@plan_item_id",    DbType.Int64, engagementId);

        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        if (!await r.ReadAsync(cancellationToken)) return null;
        var engagement = MapEngagementRow(r);
        var audits = new List<OrgAssuranceEngagementAuditRow>();
        if (await r.NextResultAsync(cancellationToken))
            while (await r.ReadAsync(cancellationToken))
                audits.Add(new OrgAssuranceEngagementAuditRow(
                    Convert.ToInt64(r["DefinitionId"]),
                    ReadStringOrNull(r, "DefinitionCode"),
                    ReadStringOrNull(r, "DefinitionName"),
                    Convert.ToInt32(r["DisplayOrder"])));
        var team = new List<OrgAssuranceEngagementTeamRow>();
        if (await r.NextResultAsync(cancellationToken))
            while (await r.ReadAsync(cancellationToken))
                team.Add(MapTeamRow(r));
        return new OrgAssuranceEngagementDetail(engagement, audits, team);
    }

    public async Task<IReadOnlyList<OrgAssuranceEngagementTeamRow>> ListEngagementTeamAsync(
        long organizationId, long engagementId, bool includeHistory, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_engagement_team_list";
        AddParam(command, "@organization_id", DbType.Int64,   organizationId);
        AddParam(command, "@plan_item_id",    DbType.Int64,   engagementId);
        AddParam(command, "@include_history", DbType.Boolean, includeHistory);
        var rows = new List<OrgAssuranceEngagementTeamRow>();
        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
            rows.Add(MapTeamRow(r));
        return rows;
    }

    public Task<OrgAssurancePlanCommandResult> SaveEngagementTeamAsync(
        long engagementId, OrgAssuranceEngagementTeamSaveRequest request, CancellationToken cancellationToken)
        => RunEngagementCommandAsync("sp_org_assurance_engagement_team_save", engagementId, request.OrganizationId,
            request.Actor, command =>
            {
                AddParam(command, "@team_json",    DbType.String, TeamJson(request.Team) ?? "[]", -1);
                AddParam(command, "@team_remarks", DbType.String, (object?)request.TeamRemarks ?? DBNull.Value, 2000);
            }, cancellationToken);

    public Task<OrgAssurancePlanCommandResult> ApproveEngagementAsync(
        long engagementId, OrgAssuranceEngagementCommandRequest request, CancellationToken cancellationToken)
        => RunEngagementCommandAsync("sp_org_assurance_engagement_approve", engagementId, request.OrganizationId,
            request.Actor, command =>
                AddParam(command, "@approval_reference", DbType.String, (object?)request.ApprovalReference ?? DBNull.Value, 200),
            cancellationToken);

    public Task<OrgAssurancePlanCommandResult> CancelEngagementAsync(
        long engagementId, OrgAssuranceEngagementCommandRequest request, CancellationToken cancellationToken)
        => RunEngagementCommandAsync("sp_org_assurance_engagement_cancel", engagementId, request.OrganizationId,
            request.Actor, command =>
                AddParam(command, "@reason", DbType.String, (object?)request.Reason ?? DBNull.Value, 2000),
            cancellationToken);

    public Task<OrgAssurancePlanCommandResult> DeleteEngagementAsync(
        long organizationId, long engagementId, string? actor, CancellationToken cancellationToken)
        => RunEngagementCommandAsync("sp_org_assurance_engagement_delete", engagementId, organizationId,
            actor, _ => { }, cancellationToken);

    private async Task<OrgAssurancePlanCommandResult> RunEngagementCommandAsync(
        string procedure, long engagementId, long organizationId, string? actor,
        Action<DbCommand> addParams, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice." + procedure;
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@plan_item_id",    DbType.Int64, engagementId);
            addParams(command);
            AddParam(command, "@actor", DbType.String, (object?)actor ?? (object)"system", 100);
            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssurancePlanCommandResult(true, engagementId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssurancePlanService.{Procedure} SQL error {Number}: {Message}",
                procedure, ex.Number, ex.Message);
            return new OrgAssurancePlanCommandResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // camelCase keys for the procedure's OPENJSON (teamRole, employeeId, name, organisation).
    private static string? TeamJson(IReadOnlyList<OrgAssuranceEngagementTeamPick>? team)
        => team is null ? null : System.Text.Json.JsonSerializer.Serialize(team.Select(t => new
        {
            teamRole     = t.TeamRole,
            employeeId   = t.EmployeeId,
            name         = t.Name,
            organisation = t.Organisation
        }));

    private static OrgAssuranceEngagementRow MapEngagementRow(DbDataReader r) => new(
        Convert.ToInt64(r["EngagementId"]),
        ReadStringOrNull(r, "EngagementCode"),
        ReadStringOrNull(r, "EngagementName"),
        ReadStringOrNull(r, "EngagementOrigin"),
        ReadIntOrNull(r,    "ItemOrder") ?? 1,
        ReadLongOrNull(r,   "PlanId"),
        ReadStringOrNull(r, "PlanCode"),
        ReadStringOrNull(r, "PlanName"),
        ReadStringOrNull(r, "PlanStatusCode"),
        ReadLongOrNull(r,   "ProgrammeId"),
        ReadStringOrNull(r, "ProgrammeCode"),
        ReadStringOrNull(r, "ProgrammeName"),
        ReadStringOrNull(r, "AuditSubject"),
        ReadStringOrNull(r, "EngagementObjective"),
        ReadStringOrNull(r, "ScopeSummary"),
        ReadLongOrNull(r,   "AuditeeRoleId"),
        ReadStringOrNull(r, "AuditeeRoleName"),
        ReadLongOrNull(r,   "AuditeeEmployeeId"),
        ReadStringOrNull(r, "AuditeeName"),
        ReadLongOrNull(r,   "LeadAuditorRoleId"),
        ReadStringOrNull(r, "LeadAuditorRoleName"),
        ReadLongOrNull(r,   "LeadAuditorEmployeeId"),
        ReadStringOrNull(r, "LeadAuditorName"),
        ReadIntOrNull(r,    "TeamCount") ?? 0,
        ReadStringOrNull(r, "TeamRemarks"),
        ReadStringOrNull(r, "TeamText"),
        ReadStringOrNull(r, "EngagementInstructions"),
        ReadStringOrNull(r, "InitiationSourceCode"),
        ReadStringOrNull(r, "InitiationSourceName"),
        ReadStringOrNull(r, "InitiationReason"),
        ReadStringOrNull(r, "ApprovalStatus"),
        ReadStringOrNull(r, "ApprovalReference"),
        ReadStringOrNull(r, "ApprovedBy"),
        ReadDateTimeOrNull(r, "ApprovedDt"),
        ReadDateTimeOrNull(r, "CancelledDt"),
        ReadStringOrNull(r, "CancelledBy"),
        ReadStringOrNull(r, "CancelReason"),
        ReadDateTimeOrNull(r, "PlannedStart"),
        ReadDateTimeOrNull(r, "PlannedEnd"),
        ReadDateTimeOrNull(r, "ActualStart"),
        ReadDateTimeOrNull(r, "ActualEnd"),
        ReadLongOrNull(r,   "BranchId"),
        ReadStringOrNull(r, "BranchName"),
        ReadStringOrNull(r, "DepartmentName"),
        ReadStringOrNull(r, "Notes"),
        ReadIntOrNull(r,    "DefinitionCount") ?? 0,
        ReadStringOrNull(r, "DefinitionCodes"),
        ReadIntOrNull(r,    "ExecutionCount") ?? 0,
        ReadIntOrNull(r,    "ExecutionDoneCount") ?? 0,
        r["CanStart"] != DBNull.Value && Convert.ToBoolean(r["CanStart"]),
        ReadStringOrNull(r, "EngagementStatus"),
        ReadStringOrNull(r, "EnteredBy"),
        ReadDateTimeOrNull(r, "EnteredDt"),
        ReadStringOrNull(r, "UpdatedBy"),
        ReadDateTimeOrNull(r, "UpdatedDt"));

    private static OrgAssuranceEngagementTeamRow MapTeamRow(DbDataReader r) => new(
        Convert.ToInt64(r["TeamMemberId"]),
        r["TeamRole"].ToString()!,
        ReadLongOrNull(r,   "EmployeeId"),
        ReadStringOrNull(r, "MemberName"),
        ReadStringOrNull(r, "Designation"),
        ReadStringOrNull(r, "RoleName"),
        ReadStringOrNull(r, "ExternalOrganisation"),
        r["IsActive"] != DBNull.Value && Convert.ToBoolean(r["IsActive"]),
        ReadStringOrNull(r, "AddedBy"),
        ReadDateTimeOrNull(r, "AddedDt"),
        ReadStringOrNull(r, "RemovedBy"),
        ReadDateTimeOrNull(r, "RemovedDt"));



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

    private static OrgAssurancePlanListRow MapListRow(DbDataReader r) => new(
        Convert.ToInt64(r["PlanId"]),
        Convert.ToInt64(r["OrganizationId"]),
        r["PlanCode"]?.ToString() ?? "",
        r["PlanName"]?.ToString() ?? "",
        r["PlanType"]?.ToString() ?? "",
        ReadDateTimeOrNull(r, "PeriodFrom"),
        ReadDateTimeOrNull(r, "PeriodTo"),
        // 121 hybrid role+employee Owner
        ReadLongOrNull(r,     "OwnerRoleId"),
        ReadStringOrNull(r,   "OwnerRoleName"),
        ReadLongOrNull(r,     "OwnerEmployeeId"),
        ReadStringOrNull(r,   "OwnerDisplayName"),
        r["StatusCode"]?.ToString() ?? "",
        r["StatusName"]?.ToString() ?? "",
        Convert.ToBoolean(r["StatusIsTerminal"]),
        Convert.ToInt32(r["Version"]),
        Convert.ToInt64(r["ItemCount"]),
        ReadDateTimeOrNull(r, "EnteredDt"),
        ReadDateTimeOrNull(r, "UpdatedDt"),
        // 565: tolerated as absent before 565 is run.
        HasColumn(r, "FinancialYear")             ? ReadStringOrNull(r, "FinancialYear") : null,
        HasColumn(r, "ProgrammeCount")            ? ReadIntOrNull(r, "ProgrammeCount") : null,
        HasColumn(r, "Methodologies")             ? ReadStringOrNull(r, "Methodologies") : null,
        HasColumn(r, "EngagementInProgressCount") ? ReadIntOrNull(r, "EngagementInProgressCount") : null,
        HasColumn(r, "EngagementCompletedCount")  ? ReadIntOrNull(r, "EngagementCompletedCount") : null);

    private static OrgAssurancePlanDetail MapDetailRow(DbDataReader r) => new(
        Convert.ToInt64(r["PlanId"]),
        Convert.ToInt64(r["OrganizationId"]),
        r["PlanCode"]?.ToString() ?? "",
        r["PlanName"]?.ToString() ?? "",
        r["PlanType"]?.ToString() ?? "",
        ReadDateTimeOrNull(r, "PeriodFrom"),
        ReadDateTimeOrNull(r, "PeriodTo"),
        // 121 hybrid role+employee Owner
        ReadLongOrNull(r,     "OwnerRoleId"),
        ReadStringOrNull(r,   "OwnerRoleName"),
        ReadLongOrNull(r,     "OwnerEmployeeId"),
        ReadStringOrNull(r,   "OwnerDisplayName"),
        r["StatusCode"]?.ToString() ?? "",
        r["StatusName"]?.ToString() ?? "",
        Convert.ToBoolean(r["StatusIsTerminal"]),
        ReadStringOrNull(r, "Description"),
        Convert.ToInt32(r["Version"]),
        ReadStringOrNull(r, "EnteredBy"),
        ReadDateTimeOrNull(r, "EnteredDt"),
        ReadStringOrNull(r, "UpdatedBy"),
        ReadDateTimeOrNull(r, "UpdatedDt"),
        // 565: tolerated as absent before 565 is run.
        HasColumn(r, "FinancialYear")             ? ReadStringOrNull(r, "FinancialYear") : null,
        HasColumn(r, "Objectives")                ? ReadStringOrNull(r, "Objectives") : null,
        HasColumn(r, "PlannedCoverage")           ? ReadStringOrNull(r, "PlannedCoverage") : null,
        HasColumn(r, "PlannedBudget")             && r["PlannedBudget"]     != DBNull.Value ? (decimal?)Convert.ToDecimal(r["PlannedBudget"])     : null,
        HasColumn(r, "BudgetCurrency")            ? ReadStringOrNull(r, "BudgetCurrency") : null,
        HasColumn(r, "PlannedEffortDays")         && r["PlannedEffortDays"] != DBNull.Value ? (decimal?)Convert.ToDecimal(r["PlannedEffortDays"]) : null,
        HasColumn(r, "ResourcesNote")             ? ReadStringOrNull(r, "ResourcesNote") : null,
        HasColumn(r, "ProgrammeCount")            ? ReadIntOrNull(r, "ProgrammeCount") : null,
        HasColumn(r, "Methodologies")             ? ReadStringOrNull(r, "Methodologies") : null,
        HasColumn(r, "EngagementCount")           ? ReadIntOrNull(r, "EngagementCount") : null,
        HasColumn(r, "EngagementInProgressCount") ? ReadIntOrNull(r, "EngagementInProgressCount") : null,
        HasColumn(r, "EngagementCompletedCount")  ? ReadIntOrNull(r, "EngagementCompletedCount") : null);

    private static OrgAssurancePlanItemRow MapItemRow(DbDataReader r) => new(
        Convert.ToInt64(r["PlanItemId"]),
        Convert.ToInt64(r["PlanId"]),
        Convert.ToInt64(r["DefinitionId"]),
        ReadStringOrNull(r, "DefinitionCode"),
        ReadStringOrNull(r, "DefinitionName"),
        ReadLongOrNull(r,   "DefinitionVersionId"),
        Convert.ToInt32(r["ItemOrder"]),
        ReadDateTimeOrNull(r, "ScheduledFrom"),
        ReadDateTimeOrNull(r, "ScheduledTo"),
        // 121 hybrid role+employee Auditor
        ReadLongOrNull(r,   "AssignedAuditorRoleId"),
        ReadStringOrNull(r, "AssignedAuditorRoleName"),
        ReadLongOrNull(r,   "AssignedAuditorEmployeeId"),
        ReadStringOrNull(r, "AssignedAuditorName"),
        ReadStringOrNull(r, "AssignedTeamName"),
        ReadLongOrNull(r,   "AssignedDepartmentId"),
        ReadStringOrNull(r, "AssignedDepartmentName"),
        ReadLongOrNull(r,   "AssignedBranchId"),
        ReadStringOrNull(r, "AssignedBranchName"),
        ReadStringOrNull(r, "Notes"),
        ReadStringOrNull(r, "EnteredBy"),
        ReadDateTimeOrNull(r, "EnteredDt"),
        ReadStringOrNull(r, "UpdatedBy"),
        ReadDateTimeOrNull(r, "UpdatedDt"),
        // 546
        ReadStringOrNull(r, "DefinitionStatusCode"),
        ReadStringOrNull(r, "DefinitionStatusName"),
        ReadLongOrNull(r,   "ExecutionId"),
        ReadStringOrNull(r, "ExecutionCode"),
        ReadStringOrNull(r, "ExecutionStatusCode"),
        ReadStringOrNull(r, "ExecutionStatusName"),
        ReadStringOrNull(r, "SlotStatus"),
        HasColumn(r, "DefinitionIsPlannable") && r["DefinitionIsPlannable"] != DBNull.Value
            ? (bool?)Convert.ToBoolean(r["DefinitionIsPlannable"]) : null,   // 551
        // 552: the engagement; tolerated as absent before 552 is run.
        HasColumn(r, "EngagementCode")     ? ReadStringOrNull(r, "EngagementCode") : null,
        HasColumn(r, "EngagementName")     ? ReadStringOrNull(r, "EngagementName") : null,
        HasColumn(r, "DefinitionCount")    && r["DefinitionCount"]    != DBNull.Value ? (int?)Convert.ToInt32(r["DefinitionCount"])    : null,
        HasColumn(r, "DefinitionCodes")    ? ReadStringOrNull(r, "DefinitionCodes") : null,
        HasColumn(r, "ExecutionCount")     && r["ExecutionCount"]     != DBNull.Value ? (int?)Convert.ToInt32(r["ExecutionCount"])     : null,
        HasColumn(r, "ExecutionDoneCount") && r["ExecutionDoneCount"] != DBNull.Value ? (int?)Convert.ToInt32(r["ExecutionDoneCount"]) : null,
        HasColumn(r, "CanStart")           && r["CanStart"]           != DBNull.Value ? (bool?)Convert.ToBoolean(r["CanStart"])         : null,
        // 565: the programme; tolerated as absent before 565 is run.
        HasColumn(r, "ProgrammeId")   ? ReadLongOrNull(r, "ProgrammeId") : null,
        HasColumn(r, "ProgrammeCode") ? ReadStringOrNull(r, "ProgrammeCode") : null,
        HasColumn(r, "ProgrammeName") ? ReadStringOrNull(r, "ProgrammeName") : null,
        // 566: tolerated as absent before 566 is run.
        HasColumn(r, "EngagementOrigin") ? ReadStringOrNull(r, "EngagementOrigin") : null,
        HasColumn(r, "AuditSubject")     ? ReadStringOrNull(r, "AuditSubject") : null,
        HasColumn(r, "ApprovalStatus")   ? ReadStringOrNull(r, "ApprovalStatus") : null,
        HasColumn(r, "CancelledDt")      ? ReadDateTimeOrNull(r, "CancelledDt") : null);

    // 551: a column the procedure returns only once its migration has run.
    private static bool HasColumn(System.Data.Common.DbDataReader r, string col)
    {
        for (var i = 0; i < r.FieldCount; i++)
            if (string.Equals(r.GetName(i), col, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    // THROW numbers used in 090 (546: 53933-53936).
    private static string MapReason(int errorNumber) => errorNumber switch
    {
        53901 => "ORGANIZATION_ID_REQUIRED",
        53902 => "IDS_REQUIRED",
        53903 => "PLAN_CODE_REQUIRED",
        53904 => "PLAN_NAME_REQUIRED",
        53905 => "INVALID_PLAN_TYPE",
        53906 => "DUPLICATE_PLAN_CODE",
        53907 => "PLAN_NOT_FOUND",
        53908 => "WRONG_ORGANIZATION",
        53909 => "NOT_EDITABLE_IN_STATUS",
        53910 => "ACTIVE_PLAN",
        53911 => "STATUS_LOOKUP_FAILED",
        53912 => "ILLEGAL_TRANSITION",
        53913 => "DEFINITION_ID_REQUIRED",
        53914 => "DEFINITION_NOT_ACCESSIBLE",
        53915 => "ITEM_NOT_FOUND",
        53916 => "ITEM_PLAN_MISMATCH",
        53933 => "AUDIT_NOT_ACTIVE",       // 546
        53934 => "SLOT_OUTSIDE_PERIOD",    // 546
        53935 => "PLAN_NOT_EXECUTABLE",    // 546
        53936 => "SLOT_ALREADY_EXECUTED",  // 546
        53937 => "DUPLICATE_DEFINITION",   // 552
        53938 => "DEFINITION_STARTED",     // 552
        53939 => "IDS_REQUIRED",           // 554
        53940 => "BRANCH_NOT_A_LOCATION",  // 554
        53941 => "SCOPE_SNAPSHOT_NOT_FOUND", // 554
        53942 => "NOTHING_AT_BRANCH",      // 554
        53943 => "PROGRAMME_REQUIRED",     // 565
        53944 => "PROGRAMME_NOT_IN_PLAN",  // 565
        53945 => "NEGATIVE_BUDGET",        // 565
        53946 => "PROGRAMME_HAS_ENGAGEMENTS", // 565
        53947 => "PROGRAMME_NAME_REQUIRED",   // 565
        53948 => "METHODOLOGY_REQUIRED",      // 565
        53949 => "REVISION_NOT_ALLOWED",      // 565
        53950 => "AUDIT_SUBJECT_REQUIRED",    // 566
        53951 => "SCOPE_REQUIRED",            // 566
        53952 => "LEAD_AUDITOR_REQUIRED",     // 566
        53953 => "INITIATION_REQUIRED",       // 566
        53954 => "NOT_AN_AUDITOR",            // 566
        53955 => "LEAD_LOCKED",               // 566
        53956 => "APPROVAL_STATE",            // 566
        53957 => "ENGAGEMENT_CLOSED",         // 566
        53958 => "CANCEL_NOT_ALLOWED",        // 566
        53959 => "TEAM_INVALID",              // 566
        _     => "SQL_ERROR"
    };
}
