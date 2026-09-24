// =====================================================================
// DEAD CODE. NOT WIRED UP. DO NOT BUILD ON THIS FILE.
//
// The narrative Impact Details feature was withdrawn -- see the banner
// on Models/RiskImpactDetailModels.cs. This service is no longer
// registered and no controller injects it, so every procedure it calls
// below may be absent from the database (migration 309 is meant to be
// rolled back). Delete it with the other three files of that feature.
// =====================================================================
// RiskImpactDetailService
//
// Facade over the migration-309 procedures:
//   sp_risk_impact_area_list
//   sp_risk_impact_detail_list / _save / _retire
//   sp_risk_dependency_obligation_list / _set
//
// A SEPARATE service, not six more methods on RiskCentreService. That
// class and its interface are ~3000 lines carrying the whole risk
// workflow; a new feature does not need to edit them to exist, and a
// small file is a reviewable diff on a critical path. Both are injected
// into the one RiskCentreController, so the routes stay where a reader
// expects them.
//
// Same shape as the sibling services otherwise: DbType-typed AddParam,
// connection through SqlConnectionStringResolver, SqlException caught and
// returned as a message rather than thrown at the controller -- the
// procedures' own THROWs (56800-56821) are written to be read by a
// person, so passing the text through is the point.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IRiskImpactDetailService
{
    /// <summary>
    /// The obligations to show on the risk pages: every obligation of
    /// every practice in this risk's scope. DERIVED — there is no
    /// risk-obligation table and this does not create one (decision 1,
    /// docs/risk-obligation-structure.md).
    /// </summary>
    Task<RiskObligationListResult> ListRiskObligationsAsync(
        long riskRegisterId, CancellationToken ct);

    /// <summary>
    /// The Impact area dropdown. Organisation-scoped master, and the
    /// organisation is resolved FROM THE RISK rather than taken from the
    /// caller: the risk knows which tenant it belongs to, and a client
    /// that passed the wrong id would be offered another organisation's
    /// areas and then refused on save (56807).
    /// </summary>
    Task<IReadOnlyList<RiskImpactAreaRow>> ListImpactAreasAsync(
        long riskRegisterId, CancellationToken ct);

    Task<RiskImpactDetailListResult> ListImpactDetailsAsync(
        long riskRegisterId, long? obligationId, bool includeRetired, CancellationToken ct);

    Task<RiskImpactDetailSaveResult> SaveImpactDetailAsync(
        long riskRegisterId, RiskImpactDetailSaveRequest req, CancellationToken ct);

    Task<RiskImpactDetailSaveResult> RetireImpactDetailAsync(
        long riskRegisterId, long riskImpactDetailId,
        long? actorEmployeeId, string? caller, CancellationToken ct);

    Task<RiskDependencyObligationListResult> ListDependencyObligationsAsync(
        long riskRegisterId, CancellationToken ct);

    Task<RiskDependencyObligationSetResult> SetDependencyObligationAsync(
        long riskRegisterId, RiskDependencyObligationSetRequest req, CancellationToken ct);
}

public sealed class RiskImpactDetailService(
    IConfiguration configuration,
    ILogger<RiskImpactDetailService> logger) : IRiskImpactDetailService
{
    // ==============================================================
    // The risk's obligations -- derived from its scope
    //
    // Two steps, on one connection:
    //
    //   1. the practices in risk_practice_map -- a plain SELECT, because
    //      the only alternative is sp_risk_mapping_get, which returns
    //      three result sets and does a primary-practice sync on the way
    //      through. Asking it for one column would be paying for all of
    //      that;
    //   2. dbo.sp_pm_view_obligations_typed per practice -- the SAME
    //      procedure the Practice View obligations panel calls. That walk
    //      (practice -> organization_requirement -> the repository's
    //      obligations) belongs to migration 301, and re-implementing it
    //      here in SQL would be a second copy of the thing 301 owns.
    //
    // One call per mapped practice, and a risk's scope is a handful of
    // practices. If that ever stops being true, the fix is a procedure
    // that does the join once -- not a cache here.
    // ==============================================================
    public async Task<RiskObligationListResult> ListRiskObligationsAsync(
        long riskRegisterId, CancellationToken ct)
    {
        if (riskRegisterId <= 0)
            return new RiskObligationListResult(false, riskRegisterId, [], "riskRegisterId is required.");

        try
        {
            await using var conn = await OpenAsync(ct);

            var practices = new List<(long Id, string? Name, string? Code, string? Source)>();
            await using (var pc = conn.CreateCommand())
            {
                pc.CommandText = """
                    SELECT m.practice_id,
                           COALESCE(m.practice_name, p.practice_name) AS practice_name,
                           COALESCE(m.practice_code, p.practice_code) AS practice_code,
                           m.map_source_code
                    FROM   grac_practice.risk_practice_map m
                    LEFT   JOIN grac_practice.practice p ON p.practice_id = m.practice_id
                    WHERE  m.risk_register_id = @risk
                    ORDER  BY CASE WHEN m.map_source_code = 'Primary' THEN 0 ELSE 1 END,
                              COALESCE(m.practice_name, p.practice_name)
                    """;
                AddParam(pc, "@risk", DbType.Int64, riskRegisterId);

                await using var pr = await pc.ExecuteReaderAsync(ct);
                while (await pr.ReadAsync(ct))
                    practices.Add((
                        Convert.ToInt64(pr["practice_id"]),
                        pr["practice_name"] as string,
                        pr["practice_code"] as string,
                        pr["map_source_code"] as string));
            }

            var rows = new List<RiskObligationRow>();
            foreach (var practice in practices)
            {
                await using var oc = Proc(conn, "dbo.sp_pm_view_obligations_typed");
                AddParam(oc, "@p_practice_id", DbType.Int64,  practice.Id);
                AddParam(oc, "@p_search",      DbType.String, "", 200);
                AddParam(oc, "@p_offset",      DbType.Int32,  0);
                AddParam(oc, "@p_page_size",   DbType.Int32,  500);

                await using var orr = await oc.ExecuteReaderAsync(ct);
                while (await orr.ReadAsync(ct))
                {
                    var obligationId = NullableLong(HasColumn(orr, "ObligationId") ? orr["ObligationId"] : null);
                    if (obligationId is null or <= 0) continue;

                    rows.Add(new RiskObligationRow(
                        PracticeId:       practice.Id,
                        PracticeName:     practice.Name,
                        PracticeCode:     practice.Code,
                        MapSourceCode:    practice.Source,
                        ObligationId:     obligationId.Value,
                        ObligationName:   Str(orr, "ObligationName"),
                        ObligationText:   Str(orr, "ObligationText"),
                        TypeCode:         Str(orr, "TypeCode"),
                        TypeName:         Str(orr, "TypeName"),
                        FrameworkRelease: Str(orr, "FrameworkRelease")));
                }
            }

            return new RiskObligationListResult(true, riskRegisterId, rows);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskImpactDetailService.ListRiskObligations failed for {Id}: {Msg}",
                riskRegisterId, ex.Message);
            return new RiskObligationListResult(false, riskRegisterId, [], ex.Message);
        }
    }

    // ==============================================================
    // Impact areas
    // ==============================================================
    public async Task<IReadOnlyList<RiskImpactAreaRow>> ListImpactAreasAsync(
        long riskRegisterId, CancellationToken ct)
    {
        if (riskRegisterId <= 0) return [];

        try
        {
            await using var conn = await OpenAsync(ct);

            var organizationId = await ResolveOrganizationAsync(conn, riskRegisterId, ct);
            if (organizationId is null) return [];

            await using var cmd = Proc(conn, "grac_practice.sp_risk_impact_area_list");
            AddParam(cmd, "@organization_id", DbType.Int64, organizationId.Value);

            var rows = new List<RiskImpactAreaRow>();
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
                rows.Add(new RiskImpactAreaRow(
                    RiskImpactAreaId: Convert.ToInt64(r["RiskImpactAreaId"]),
                    AreaCode:         r["AreaCode"] as string,
                    AreaName:         r["AreaName"] as string,
                    DisplayOrder:     NullableInt(r["DisplayOrder"])));
            return rows;
        }
        catch (SqlException ex)
        {
            // The dropdown is not worth failing the page over: an empty
            // list shows the placeholder, and the save still refuses an
            // area that does not exist.
            logger.LogWarning(ex, "RiskImpactDetailService.ListImpactAreas failed for {Id}: {Msg}",
                riskRegisterId, ex.Message);
            return [];
        }
    }

    // ==============================================================
    // Impact details
    // ==============================================================
    public async Task<RiskImpactDetailListResult> ListImpactDetailsAsync(
        long riskRegisterId, long? obligationId, bool includeRetired, CancellationToken ct)
    {
        if (riskRegisterId <= 0)
            return new RiskImpactDetailListResult(false, riskRegisterId, [], "riskRegisterId is required.");

        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_impact_detail_list");
            AddParam(cmd, "@risk_register_id", DbType.Int64,   riskRegisterId);
            AddParam(cmd, "@obligation_id",    DbType.Int64,   obligationId is > 0 ? obligationId : DBNull.Value);
            AddParam(cmd, "@include_retired",  DbType.Boolean, includeRetired);

            var rows = new List<RiskImpactDetailRow>();
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
                rows.Add(new RiskImpactDetailRow(
                    RiskImpactDetailId:   Convert.ToInt64(r["RiskImpactDetailId"]),
                    RiskRegisterId:       Convert.ToInt64(r["RiskRegisterId"]),
                    ObligationId:         NullableLong(r["ObligationId"]),
                    ObligationName:       r["ObligationName"] as string,
                    ObligationOriginCode: r["ObligationOriginCode"] as string,
                    RiskImpactAreaId:     Convert.ToInt64(r["RiskImpactAreaId"]),
                    AreaCode:             r["AreaCode"] as string,
                    AreaName:             r["AreaName"] as string,
                    ImpactDescription:    r["ImpactDescription"] as string,
                    ImpactCode:           r["ImpactCode"] as string,
                    ImpactName:           r["ImpactName"] as string,
                    ImpactValue:          NullableIntOrNull(r["ImpactValue"]),
                    AffectedParty:        r["AffectedParty"] as string,
                    EstimatedValue:       r["EstimatedValue"] as string,
                    TimeHorizonCode:      r["TimeHorizonCode"] as string,
                    Remarks:              r["Remarks"] as string,
                    AddedStageCode:       r["AddedStageCode"] as string,
                    AddedByEmployeeId:    NullableLong(r["AddedByEmployeeId"]),
                    AddedByName:          r["AddedByName"] as string,
                    AddedDt:              NullableDate(r["AddedDt"]),
                    Status:               r["Status_"] as string));

            return new RiskImpactDetailListResult(true, riskRegisterId, rows);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskImpactDetailService.ListImpactDetails failed for {Id}: {Msg}",
                riskRegisterId, ex.Message);
            return new RiskImpactDetailListResult(false, riskRegisterId, [], ex.Message);
        }
    }

    public async Task<RiskImpactDetailSaveResult> SaveImpactDetailAsync(
        long riskRegisterId, RiskImpactDetailSaveRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);

        if (riskRegisterId <= 0)
            return new RiskImpactDetailSaveResult(false, riskRegisterId, null, false,
                Error: "riskRegisterId is required.");

        // The procedure refuses both of these too (56805 / 56806).
        // Catching them here turns a SQL error into a sentence the form
        // can put next to the field.
        if (string.IsNullOrWhiteSpace(req.ImpactDescription))
            return new RiskImpactDetailSaveResult(false, riskRegisterId, null, false,
                Error: "An impact description is required.");
        if (req.RiskImpactAreaId <= 0)
            return new RiskImpactDetailSaveResult(false, riskRegisterId, null, false,
                Error: "An impact area is required.");

        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_impact_detail_save");
            AddParam(cmd, "@risk_register_id",       DbType.Int64,  riskRegisterId);
            AddParam(cmd, "@risk_impact_detail_id",  DbType.Int64,  req.RiskImpactDetailId);
            AddParam(cmd, "@obligation_id",          DbType.Int64,  req.ObligationId is > 0 ? req.ObligationId : DBNull.Value);
            AddParam(cmd, "@obligation_name",        DbType.String, Text(req.ObligationName), 500);
            AddParam(cmd, "@obligation_origin_code", DbType.String, Text(req.ObligationOriginCode), 20);
            AddParam(cmd, "@risk_impact_area_id",    DbType.Int64,  req.RiskImpactAreaId);
            AddParam(cmd, "@impact_description",     DbType.String, Text(req.ImpactDescription), 4000);
            AddParam(cmd, "@impact_code",            DbType.String, Text(req.ImpactCode), 60);
            AddParam(cmd, "@affected_party",         DbType.String, Text(req.AffectedParty), 300);
            AddParam(cmd, "@estimated_value",        DbType.String, Text(req.EstimatedValue), 120);
            AddParam(cmd, "@time_horizon_code",      DbType.String, Text(req.TimeHorizonCode), 20);
            AddParam(cmd, "@remarks",                DbType.String, Text(req.Remarks), 1000);
            AddParam(cmd, "@added_stage_code",       DbType.String,
                     string.IsNullOrWhiteSpace(req.AddedStageCode) ? "Analysis" : req.AddedStageCode, 20);
            AddParam(cmd, "@actor_employee_id",      DbType.Int64,  (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",    DbType.String,
                     string.IsNullOrWhiteSpace(req.CallerDisplayName) ? "system" : req.CallerDisplayName, 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskImpactDetailSaveResult(
                    true, riskRegisterId,
                    NullableLong(r["RiskImpactDetailId"]),
                    r["Created"] != DBNull.Value && Convert.ToBoolean(r["Created"]),
                    r["Message"] as string);

            return new RiskImpactDetailSaveResult(true, riskRegisterId,
                req.RiskImpactDetailId > 0 ? req.RiskImpactDetailId : null, false, "Saved.");
        }
        catch (SqlException ex)
        {
            // 56802-56811 are 309's refusals and each names the rule that
            // refused: risk closed, unknown area, unknown severity, bad
            // time horizon, no such impact on this risk.
            logger.LogWarning(ex, "RiskImpactDetailService.SaveImpactDetail failed for {Id}: {Msg}",
                riskRegisterId, ex.Message);
            // The id goes back on the failure path too, so a retry edits
            // the row already written instead of adding a second one.
            return new RiskImpactDetailSaveResult(false, riskRegisterId,
                req.RiskImpactDetailId > 0 ? req.RiskImpactDetailId : null, false,
                Error: ex.Message);
        }
    }

    public async Task<RiskImpactDetailSaveResult> RetireImpactDetailAsync(
        long riskRegisterId, long riskImpactDetailId,
        long? actorEmployeeId, string? caller, CancellationToken ct)
    {
        if (riskRegisterId <= 0 || riskImpactDetailId <= 0)
            return new RiskImpactDetailSaveResult(false, riskRegisterId, null, false,
                Error: "risk and impact detail are both required.");

        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_impact_detail_retire");
            AddParam(cmd, "@risk_register_id",      DbType.Int64,  riskRegisterId);
            AddParam(cmd, "@risk_impact_detail_id", DbType.Int64,  riskImpactDetailId);
            AddParam(cmd, "@actor_employee_id",     DbType.Int64,  (object?)actorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",   DbType.String,
                     string.IsNullOrWhiteSpace(caller) ? "system" : caller, 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskImpactDetailSaveResult(true, riskRegisterId,
                    NullableLong(r["RiskImpactDetailId"]), false, r["Message"] as string);

            return new RiskImpactDetailSaveResult(true, riskRegisterId, riskImpactDetailId, false,
                "Impact detail removed.");
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskImpactDetailService.RetireImpactDetail failed for {Id}: {Msg}",
                riskRegisterId, ex.Message);
            return new RiskImpactDetailSaveResult(false, riskRegisterId, riskImpactDetailId, false,
                Error: ex.Message);
        }
    }

    // ==============================================================
    // Dependency -> obligation attribution
    // ==============================================================
    public async Task<RiskDependencyObligationListResult> ListDependencyObligationsAsync(
        long riskRegisterId, CancellationToken ct)
    {
        if (riskRegisterId <= 0)
            return new RiskDependencyObligationListResult(false, riskRegisterId, [], "riskRegisterId is required.");

        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_dependency_obligation_list");
            AddParam(cmd, "@risk_register_id", DbType.Int64, riskRegisterId);

            var rows = new List<RiskDependencyObligationRow>();
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
                rows.Add(new RiskDependencyObligationRow(
                    RiskDependencyObligationId: Convert.ToInt64(r["RiskDependencyObligationId"]),
                    RiskDependencyMapId:        Convert.ToInt64(r["RiskDependencyMapId"]),
                    ObligationId:              Convert.ToInt64(r["ObligationId"]),
                    ObligationName:            r["ObligationName"] as string,
                    ObligationOriginCode:      r["ObligationOriginCode"] as string,
                    DependencyTypeId:          NullableInt(r["DependencyTypeId"]),
                    DependencyTypeName:        r["DependencyTypeName"] as string,
                    DependencyObjectId:        Convert.ToInt64(r["DependencyObjectId"]),
                    DependencyObjectName:      r["DependencyObjectName"] as string,
                    AttributedDt:              NullableDate(r["AttributedDt"]),
                    AttributedByName:          r["AttributedByName"] as string));

            return new RiskDependencyObligationListResult(true, riskRegisterId, rows);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskImpactDetailService.ListDependencyObligations failed for {Id}: {Msg}",
                riskRegisterId, ex.Message);
            return new RiskDependencyObligationListResult(false, riskRegisterId, [], ex.Message);
        }
    }

    public async Task<RiskDependencyObligationSetResult> SetDependencyObligationAsync(
        long riskRegisterId, RiskDependencyObligationSetRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);

        if (req.RiskDependencyMapId <= 0 || req.ObligationId <= 0)
            return new RiskDependencyObligationSetResult(false, riskRegisterId,
                req.RiskDependencyMapId, req.ObligationId, req.Attach, false,
                "riskDependencyMapId and obligationId are both required.");

        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_dependency_obligation_set");
            AddParam(cmd, "@risk_register_id",       DbType.Int64,   riskRegisterId);
            AddParam(cmd, "@risk_dependency_map_id", DbType.Int64,   req.RiskDependencyMapId);
            AddParam(cmd, "@obligation_id",          DbType.Int64,   req.ObligationId);
            AddParam(cmd, "@obligation_name",        DbType.String,  Text(req.ObligationName), 500);
            AddParam(cmd, "@obligation_origin_code", DbType.String,
                     string.IsNullOrWhiteSpace(req.ObligationOriginCode) ? "Published" : req.ObligationOriginCode, 20);
            AddParam(cmd, "@attach",                 DbType.Boolean, req.Attach);
            AddParam(cmd, "@remarks",                DbType.String,  Text(req.Remarks), 1000);
            AddParam(cmd, "@actor_employee_id",      DbType.Int64,   (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",    DbType.String,
                     string.IsNullOrWhiteSpace(req.CallerDisplayName) ? "system" : req.CallerDisplayName, 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskDependencyObligationSetResult(
                    true, riskRegisterId,
                    Convert.ToInt64(r["RiskDependencyMapId"]),
                    Convert.ToInt64(r["ObligationId"]),
                    r["Attached"] != DBNull.Value && Convert.ToBoolean(r["Attached"]),
                    r["Changed"] != DBNull.Value && Convert.ToBoolean(r["Changed"]));

            return new RiskDependencyObligationSetResult(true, riskRegisterId,
                req.RiskDependencyMapId, req.ObligationId, req.Attach, false);
        }
        catch (SqlException ex)
        {
            // 56816-56820: risk closed, dependency not on this risk, bad
            // origin code.
            logger.LogWarning(ex, "RiskImpactDetailService.SetDependencyObligation failed for {Id}: {Msg}",
                riskRegisterId, ex.Message);
            return new RiskDependencyObligationSetResult(false, riskRegisterId,
                req.RiskDependencyMapId, req.ObligationId, req.Attach, false, ex.Message);
        }
    }

    // ==============================================================
    // Infrastructure helpers -- identical to the sibling services
    // ==============================================================

    /// <summary>
    /// The risk's own organisation. One indexed lookup, so the caller
    /// never has to pass a tenant id that could be wrong.
    /// </summary>
    private static async Task<long?> ResolveOrganizationAsync(
        DbConnection conn, long riskRegisterId, CancellationToken ct)
    {
        await using var cmd = conn.CreateCommand();
        cmd.CommandText =
            "SELECT organization_id FROM grac_practice.risk_register WHERE risk_register_id = @id";
        AddParam(cmd, "@id", DbType.Int64, riskRegisterId);
        var value = await cmd.ExecuteScalarAsync(ct);
        return value is null || value == DBNull.Value ? null : Convert.ToInt64(value);
    }

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

    /// <summary>Empty string means "not answered", which is DBNull here.</summary>
    private static object Text(string? value)
        => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value;

    private static int NullableInt(object? value)
        => value is null || value == DBNull.Value ? 0 : Convert.ToInt32(value);

    private static int? NullableIntOrNull(object? value)
        => value is null || value == DBNull.Value ? null : Convert.ToInt32(value);

    private static long? NullableLong(object? value)
        => value is null || value == DBNull.Value ? null : Convert.ToInt64(value);

    private static DateTime? NullableDate(object? value)
        => value is null || value == DBNull.Value ? null : Convert.ToDateTime(value);

    // A column a migration added, read from a result set that may predate
    // it. reader["Missing"] throws, so asking first lets one field
    // degrade instead of taking the whole read down -- which matters most
    // for sp_pm_view_obligations_typed, whose projection this module does
    // not own and which grew columns in 224 and 301.
    private static bool HasColumn(DbDataReader reader, string name)
    {
        for (var i = 0; i < reader.FieldCount; i++)
            if (string.Equals(reader.GetName(i), name, StringComparison.OrdinalIgnoreCase))
                return true;
        return false;
    }

    private static string? Str(DbDataReader reader, string name)
        => HasColumn(reader, name) ? reader[name] as string : null;
}
