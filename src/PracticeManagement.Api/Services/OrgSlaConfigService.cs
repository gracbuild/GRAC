// =====================================================================
// OrgSlaConfigService
//
// Thin wrapper around the sp_ctrl_sla_master_list / sp_org_sla_*
// stored procedures (migrations 178, 179). Follows the same
// conventions as OrgAssuranceDefinitionService:
//   * Primary-constructor DI
//   * SqlConnectionStringResolver for the connection string
//   * AddParam helper + snake_case @-parameter names matching the SPs
//   * Result records (Success / Error) so the controller stays thin
//
// Wire-up: Infrastructure/OrgSlaConfigServiceRegistration.cs.
// =====================================================================
using System.Data;
using System.Data.Common;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Infrastructure;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IOrgSlaConfigService
{
    // Lookups
    Task<IReadOnlyList<CtrlSlaMasterRow>> ListSlaMastersAsync(CancellationToken cancellationToken);

    // Master-first grid (post-181): every master row for the org + status.
    Task<OrgSlaMasterGridResult> ListMastersWithConfigAsync(
        OrgSlaMasterGridQuery query, CancellationToken cancellationToken);

    // Grid + detail (pre-181 shape -- retained for the detail dialog).
    Task<OrgSlaConfigListResult> ListAsync(OrgSlaConfigListQuery query, CancellationToken cancellationToken);

    Task<OrgSlaConfigDetail?> GetAsync(long organizationId, long orgSlaConfigId, CancellationToken cancellationToken);

    // Mutations
    Task<OrgSlaConfigUpsertResult> UpsertAsync(OrgSlaConfigUpsertRequest request, CancellationToken cancellationToken);

    Task<OrgSlaMutationResult> SetNotifyRolesAsync(OrgSlaNotifyRoleSetRequest request, CancellationToken cancellationToken);

    // Toggle Active / Inactive (menu items on the master-first grid).
    Task<OrgSlaMutationResult> SetActiveAsync(
        OrgSlaConfigSetActiveRequest request, CancellationToken cancellationToken);
}

public sealed class OrgSlaConfigService(
    IConfiguration configuration,
    ILogger<OrgSlaConfigService> logger) : IOrgSlaConfigService
{
    // ----------------------------------------------------------------
    // Lookups
    // ----------------------------------------------------------------
    public async Task<IReadOnlyList<CtrlSlaMasterRow>> ListSlaMastersAsync(CancellationToken cancellationToken)
    {
        var rows = new List<CtrlSlaMasterRow>();
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_ctrl_sla_master_list";
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new CtrlSlaMasterRow(
                Id:             reader["Id"]           == DBNull.Value ? 0 : Convert.ToInt64(reader["Id"]),
                Code:           reader["Code"]?.ToString() ?? "",
                Name:           reader["Name"]?.ToString() ?? "",
                Description:    reader["Description"]  == DBNull.Value ? null : reader["Description"]?.ToString(),
                TotalSlaDays:   reader["TotalSlaDays"] == DBNull.Value ? (int?)null : Convert.ToInt32(reader["TotalSlaDays"]),
                ProcessCode:    ColStringOrNull(reader, "ProcessCode"),
                Classification: ColStringOrNull(reader, "Classification"),
                DurationValue:  ColIntOrNull(reader, "DurationValue"),
                DurationUnit:   ColStringOrNull(reader, "DurationUnit"),
                TimeBasis:      ColStringOrNull(reader, "TimeBasis"),
                WarningPct:     ColDecimalOrNull(reader, "WarningPct"),
                EscalationPct:  ColDecimalOrNull(reader, "EscalationPct"),
                EffectiveFrom:  ColDateTimeOrNull(reader, "EffectiveFrom"),
                Status:         ColStringOrNull(reader, "Status")));
        }
        return rows;
    }

    // ----------------------------------------------------------------
    // Master-first grid (sp_org_sla_master_grid -- 181)
    // ----------------------------------------------------------------
    public async Task<OrgSlaMasterGridResult> ListMastersWithConfigAsync(
        OrgSlaMasterGridQuery query, CancellationToken cancellationToken)
    {
        var rows = new List<OrgSlaMasterGridRow>();
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_sla_master_grid";
        AddParam(command, "@organization_id", DbType.Int64,  query.OrganizationId);
        AddParam(command, "@search",          DbType.String, (object?)query.Search ?? DBNull.Value, 200);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgSlaMasterGridRow(
                SlaMasterId:         Convert.ToInt64(reader["SlaMasterId"]),
                SlaMasterCode:       ColStringOrNull(reader, "SlaMasterCode"),
                SlaMasterName:       ColStringOrNull(reader, "SlaMasterName"),
                Description:         ColStringOrNull(reader, "Description"),
                ProcessCode:         ColStringOrNull(reader, "ProcessCode"),
                Classification:      ColStringOrNull(reader, "Classification"),
                DurationValue:       ColIntOrNull(reader, "DurationValue"),
                DurationUnit:        ColStringOrNull(reader, "DurationUnit"),
                MasterTimeBasis:     ColStringOrNull(reader, "MasterTimeBasis"),
                MasterWarningPct:    ColDecimalOrNull(reader, "MasterWarningPct"),
                MasterEscalationPct: ColDecimalOrNull(reader, "MasterEscalationPct"),
                TotalSlaDays:        ColIntOrNull(reader, "TotalSlaDays"),
                EffectiveFrom:       ColDateTimeOrNull(reader, "EffectiveFrom"),
                OrgSlaConfigId:      reader["OrgSlaConfigId"] == DBNull.Value ? (long?)null : Convert.ToInt64(reader["OrgSlaConfigId"]),
                ConfigStatusCode:    reader["ConfigStatusCode"]?.ToString()  ?? "NotConfigured",
                ConfigStatusLabel:   reader["ConfigStatusLabel"]?.ToString() ?? "Not Configured",
                WarningPct:          ColDecimalOrNull(reader, "WarningPct"),
                EscalationPct:       ColDecimalOrNull(reader, "EscalationPct"),
                TimeBasis:           ColStringOrNull(reader, "TimeBasis"),
                NotifyRoleCount:     Convert.ToInt32(reader["NotifyRoleCount"]),
                ConfiguredDt:        ColDateTimeOrNull(reader, "ConfiguredDt")));
        }
        return new OrgSlaMasterGridResult(rows);
    }

    // ----------------------------------------------------------------
    // Grid
    // ----------------------------------------------------------------
    public async Task<OrgSlaConfigListResult> ListAsync(OrgSlaConfigListQuery query, CancellationToken cancellationToken)
    {
        var rows = new List<OrgSlaConfigListRow>();
        var total = 0;

        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_sla_config_list";
        AddParam(command, "@organization_id", DbType.Int64,  query.OrganizationId);
        AddParam(command, "@search",          DbType.String, (object?)query.Search ?? DBNull.Value, 200);
        AddParam(command, "@page",            DbType.Int32,  query.Page);
        AddParam(command, "@page_size",       DbType.Int32,  query.PageSize);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgSlaConfigListRow(
                OrgSlaConfigId:      Convert.ToInt64(reader["OrgSlaConfigId"]),
                OrganizationId:      Convert.ToInt64(reader["OrganizationId"]),
                SlaMasterId:         Convert.ToInt64(reader["SlaMasterId"]),
                SlaMasterCode:       ColStringOrNull(reader, "SlaMasterCode"),
                SlaMasterName:       ColStringOrNull(reader, "SlaMasterName"),
                TotalSlaDays:        ColIntOrNull(reader, "TotalSlaDays"),
                WarningPct:          ColDecimalOrNull(reader, "WarningPct"),
                EscalationPct:       ColDecimalOrNull(reader, "EscalationPct"),
                TimeBasis:           ColStringOrNull(reader, "TimeBasis"),
                Notes:               ColStringOrNull(reader, "Notes"),
                NotifyRoleCount:     Convert.ToInt32(reader["NotifyRoleCount"]),
                EnteredBy:           ColStringOrNull(reader, "EnteredBy"),
                EnteredDt:           ColDateTimeOrNull(reader, "EnteredDt"),
                UpdatedBy:           ColStringOrNull(reader, "UpdatedBy"),
                UpdatedDt:           ColDateTimeOrNull(reader, "UpdatedDt")));
            total = reader["TotalCount"] == DBNull.Value ? total : Convert.ToInt32(reader["TotalCount"]);
        }

        return new OrgSlaConfigListResult(rows, total, query.Page, query.PageSize);
    }

    // ----------------------------------------------------------------
    // Detail
    // ----------------------------------------------------------------
    public async Task<OrgSlaConfigDetail?> GetAsync(
        long organizationId, long orgSlaConfigId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_sla_config_get";
        AddParam(command, "@organization_id",   DbType.Int64, organizationId);
        AddParam(command, "@org_sla_config_id", DbType.Int64, orgSlaConfigId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        // Result set 1 -- header
        OrgSlaConfigHeader? header = null;
        if (await reader.ReadAsync(cancellationToken))
        {
            header = new OrgSlaConfigHeader(
                OrgSlaConfigId: Convert.ToInt64(reader["OrgSlaConfigId"]),
                OrganizationId: Convert.ToInt64(reader["OrganizationId"]),
                SlaMasterId:    Convert.ToInt64(reader["SlaMasterId"]),
                SlaMasterCode:  ColStringOrNull(reader, "SlaMasterCode"),
                SlaMasterName:  ColStringOrNull(reader, "SlaMasterName"),
                TotalSlaDays:   ColIntOrNull(reader, "TotalSlaDays"),
                WarningPct:     ColDecimalOrNull(reader, "WarningPct"),
                EscalationPct:  ColDecimalOrNull(reader, "EscalationPct"),
                TimeBasis:      ColStringOrNull(reader, "TimeBasis"),
                Notes:          ColStringOrNull(reader, "Notes"),
                EnteredBy:      ColStringOrNull(reader, "EnteredBy"),
                EnteredDt:      ColDateTimeOrNull(reader, "EnteredDt"),
                UpdatedBy:      ColStringOrNull(reader, "UpdatedBy"),
                UpdatedDt:      ColDateTimeOrNull(reader, "UpdatedDt"));
        }
        if (header is null) return null;

        // Result set 2 -- notify roles
        var notifyRoles = new List<OrgSlaNotifyRoleRow>();
        await reader.NextResultAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            notifyRoles.Add(new OrgSlaNotifyRoleRow(
                NotifyRoleId:    Convert.ToInt64(reader["NotifyRoleId"]),
                NotifyEventCode: reader["NotifyEventCode"]?.ToString() ?? "",
                RoleId:          Convert.ToInt64(reader["RoleId"]),
                RoleName:        reader["RoleName"] == DBNull.Value ? null : reader["RoleName"]?.ToString()));
        }

        // Result set 3 (process bindings) was retired in migration 186.
        return new OrgSlaConfigDetail(header, notifyRoles);
    }

    // ----------------------------------------------------------------
    // Mutations
    // ----------------------------------------------------------------
    public async Task<OrgSlaConfigUpsertResult> UpsertAsync(
        OrgSlaConfigUpsertRequest request, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_sla_config_upsert";
            AddParam(command, "@organization_id",   DbType.Int64,   request.OrganizationId);
            AddParam(command, "@org_sla_config_id", DbType.Int64,   (object?)request.OrgSlaConfigId ?? DBNull.Value);
            AddParam(command, "@sla_master_id",     DbType.Int64,   request.SlaMasterId);
            AddParam(command, "@sla_master_code",   DbType.String,  (object?)request.SlaMasterCode ?? DBNull.Value, 120);
            AddParam(command, "@sla_master_name",   DbType.String,  (object?)request.SlaMasterName ?? DBNull.Value, 200);
            AddParam(command, "@total_sla_days",    DbType.Int32,   (object?)request.TotalSlaDays  ?? DBNull.Value);
            AddParam(command, "@warning_pct",       DbType.Decimal, request.WarningPct);
            AddParam(command, "@escalation_pct",    DbType.Decimal, request.EscalationPct);
            AddParam(command, "@time_basis",        DbType.String,  (object?)request.TimeBasis ?? DBNull.Value, 60);
            AddParam(command, "@notes",             DbType.String,  (object?)request.Notes ?? DBNull.Value, 1000);
            AddParam(command, "@actor",             DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);

            var pOut = command.CreateParameter();
            pOut.ParameterName = "@out_org_sla_config_id";
            pOut.DbType        = DbType.Int64;
            pOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(pOut);

            await command.ExecuteNonQueryAsync(cancellationToken);

            var id = pOut.Value == DBNull.Value ? (long?)null : Convert.ToInt64(pOut.Value);
            return new OrgSlaConfigUpsertResult(true, id, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "OrgSlaConfigService.UpsertAsync failed for org {OrgId}", request.OrganizationId);
            return new OrgSlaConfigUpsertResult(false, request.OrgSlaConfigId, ex.Message);
        }
    }

    public async Task<OrgSlaMutationResult> SetNotifyRolesAsync(
        OrgSlaNotifyRoleSetRequest request, CancellationToken cancellationToken)
    {
        try
        {
            var payload = JsonSerializer.Serialize(request.Roles.Select(r => new
            {
                notifyEventCode = r.NotifyEventCode,
                roleId          = r.RoleId
            }));

            await using var connection = await OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_sla_config_notify_role_set";
            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@org_sla_config_id", DbType.Int64,  request.OrgSlaConfigId);
            AddParam(command, "@roles_json",        DbType.String, payload);
            AddParam(command, "@actor",             DbType.String, string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgSlaMutationResult(true, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "OrgSlaConfigService.SetNotifyRolesAsync failed for config {ConfigId}", request.OrgSlaConfigId);
            return new OrgSlaMutationResult(false, ex.Message);
        }
    }

    // SetProcessBindingsAsync removed in migration 186 -- the whole
    // process-binding surface (grac_practice.org_sla_process_binding
    // table + sp_org_sla_process_binding_set proc) was dropped.

    // ----------------------------------------------------------------
    // Toggle Active / Inactive (181)
    // ----------------------------------------------------------------
    public async Task<OrgSlaMutationResult> SetActiveAsync(
        OrgSlaConfigSetActiveRequest request, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_sla_config_set_active";
            AddParam(command, "@organization_id", DbType.Int64,   request.OrganizationId);
            AddParam(command, "@sla_master_id",   DbType.Int64,   request.SlaMasterId);
            AddParam(command, "@is_active",       DbType.Boolean, request.IsActive);
            AddParam(command, "@actor",           DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgSlaMutationResult(true, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "OrgSlaConfigService.SetActiveAsync failed for master {MasterId}", request.SlaMasterId);
            return new OrgSlaMutationResult(false, ex.Message);
        }
    }

    // GetForProcessAsync removed in migration 186 -- sp_org_sla_config_for_process
    // was the resolver over org_sla_process_binding, which is gone.
    // If a future feature (Task SLA, Observation SLA) needs a similar
    // resolver, re-introduce it there alongside its caller.

    // ----------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------
    private async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connString = SqlConnectionStringResolver.Resolve(configuration);
        var connection = new SqlConnection(connString);
        await connection.OpenAsync(cancellationToken);
        return connection;
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

    // Column readers -- tolerant of columns that a proc may or may not
    // emit (sp_ctrl_sla_master_list gained new columns in 181; some
    // callers still hit the 179 shape when 181 is not yet deployed).
    private static string? ColStringOrNull(System.Data.Common.DbDataReader reader, string col)
    {
        try { var v = reader[col]; return v == DBNull.Value ? null : v?.ToString(); }
        catch (IndexOutOfRangeException) { return null; }
    }
    private static int? ColIntOrNull(System.Data.Common.DbDataReader reader, string col)
    {
        try { var v = reader[col]; return v == DBNull.Value ? (int?)null : Convert.ToInt32(v); }
        catch (IndexOutOfRangeException) { return null; }
    }
    private static decimal? ColDecimalOrNull(System.Data.Common.DbDataReader reader, string col)
    {
        try { var v = reader[col]; return v == DBNull.Value ? (decimal?)null : Convert.ToDecimal(v); }
        catch (IndexOutOfRangeException) { return null; }
    }
    private static DateTime? ColDateTimeOrNull(System.Data.Common.DbDataReader reader, string col)
    {
        try { var v = reader[col]; return v == DBNull.Value ? (DateTime?)null : Convert.ToDateTime(v); }
        catch (IndexOutOfRangeException) { return null; }
    }
}
