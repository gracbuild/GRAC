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
        if (request.PlanId <= 0)       return new OrgAssurancePlanItemSaveResult(false, Error: "PlanId is required.");
        if (request.DefinitionId <= 0) return new OrgAssurancePlanItemSaveResult(false, Error: "DefinitionId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_plan_item_save";

            AddParam(command, "@organization_id",                DbType.Int64,  request.OrganizationId);
            AddParam(command, "@plan_id",                        DbType.Int64,  request.PlanId);
            AddParam(command, "@plan_item_id",                   DbType.Int64,  (object?)request.PlanItemId ?? DBNull.Value);
            AddParam(command, "@org_assurance_definition_id",    DbType.Int64,  request.DefinitionId);
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
    // Helpers
    // -----------------------------------------------------------------
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
        ReadDateTimeOrNull(r, "UpdatedDt"));

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
        ReadDateTimeOrNull(r, "UpdatedDt"));

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
        ReadDateTimeOrNull(r, "UpdatedDt"));

    // THROW numbers used in 090.
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
        _     => "SQL_ERROR"
    };
}
