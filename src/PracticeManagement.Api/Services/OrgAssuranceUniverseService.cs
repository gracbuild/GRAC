// =====================================================================
// OrgAssuranceUniverseService (577, CR2 - AA Part A -- Audit Universe)
//
// The Audit Universe over the 577 procedures: Universe Configuration
// masters, discovery of Organization Registry records (include / exclude /
// release), the register, one subject, saves, the lifecycle,
// relationships and the Universe History; 580: the Framework & Practice
// Mapping (list, options, suggestions, manual adds, decisions); 581: the
// Enterprise Risk Intelligence view of a subject. Reads return the procedures'
// rows (EvidenceCenterService's ReadRowsAsync pattern, as
// OrgAssuranceReportService).
//
// Wire-up: Infrastructure/OrgAssuranceUniverseServiceRegistration.cs.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IOrgAssuranceUniverseService
{
    Task<List<Dictionary<string, object?>>> ListMastersAsync(long organizationId, string? group, string actor, CancellationToken cancellationToken);
    Task<OrgAssuranceUniverseResult> SaveMasterAsync(OrgAssuranceUniverseMasterSaveRequest request, long? employeeId, string actor, CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> DiscoverAsync(
        long organizationId, string? kind, string? show, string? search, CancellationToken cancellationToken);
    Task<OrgAssuranceUniverseResult> ApplyDiscoveryAsync(OrgAssuranceUniverseDiscoverRequest request, long? employeeId, string actor, CancellationToken cancellationToken);
    Task<Dictionary<string, object?>> GetLookupsAsync(long organizationId, CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> ListSubjectsAsync(
        long organizationId, long? categoryId, string? status, string? source, long? criticalityId,
        long? ownerEmployeeId, long? departmentId, string? search, long? employeeId, string actor, CancellationToken cancellationToken);
    Task<Dictionary<string, object?>?> GetSubjectAsync(long organizationId, long subjectId, long? employeeId, CancellationToken cancellationToken);
    Task<OrgAssuranceUniverseResult> SaveSubjectAsync(OrgAssuranceUniverseSaveRequest request, long? employeeId, string actor, CancellationToken cancellationToken);
    Task<OrgAssuranceUniverseResult> SubjectActionAsync(
        long subjectId, long employeeId, OrgAssuranceUniverseActionRequest request, string actor, CancellationToken cancellationToken);
    Task<OrgAssuranceUniverseResult> SaveRelationshipAsync(
        OrgAssuranceUniverseRelationshipSaveRequest request, long? employeeId, string actor, CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> ListHistoryAsync(
        long organizationId, long? subjectId, string? action, DateTime? from, DateTime? to, string? search, CancellationToken cancellationToken);
    // 580: Framework & Practice Mapping
    Task<Dictionary<string, object?>> ListMappingsAsync(
        long organizationId, long subjectId, string? level, string? status, string? source, string? search, CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> ListMappingOptionsAsync(long organizationId, string level, CancellationToken cancellationToken);
    Task<OrgAssuranceUniverseResult> SuggestMappingsAsync(long subjectId, long organizationId, long? employeeId, string actor, CancellationToken cancellationToken);
    Task<OrgAssuranceUniverseResult> AddMappingsAsync(
        long subjectId, OrgAssuranceUniverseMappingAddRequest request, long? employeeId, string actor, CancellationToken cancellationToken);
    Task<OrgAssuranceUniverseResult> MappingActionAsync(
        long subjectId, OrgAssuranceUniverseMappingActionRequest request, long? employeeId, string actor, CancellationToken cancellationToken);
    // 581: Enterprise Risk Intelligence of a subject
    Task<Dictionary<string, object?>> GetRiskIntelligenceAsync(long organizationId, long subjectId, CancellationToken cancellationToken);
}

public sealed class OrgAssuranceUniverseService(
    IConfiguration configuration,
    ILogger<OrgAssuranceUniverseService> logger) : IOrgAssuranceUniverseService
{
    // -----------------------------------------------------------------
    // Reads
    // -----------------------------------------------------------------
    public Task<List<Dictionary<string, object?>>> ListMastersAsync(long organizationId, string? group, string actor, CancellationToken cancellationToken)
        => ReadAsync("sp_org_assurance_universe_master_list", c =>
        {
            AddParam(c, "@organization_id", DbType.Int64,  organizationId);
            AddParam(c, "@master_group",    DbType.String, (object?)group ?? DBNull.Value, 30);
            AddParam(c, "@actor",           DbType.String, actor, 100);
        }, cancellationToken);

    public Task<List<Dictionary<string, object?>>> DiscoverAsync(
        long organizationId, string? kind, string? show, string? search, CancellationToken cancellationToken)
        => ReadAsync("sp_org_assurance_universe_discover", c =>
        {
            AddParam(c, "@organization_id", DbType.Int64,  organizationId);
            AddParam(c, "@source_kind",     DbType.String, (object?)kind ?? DBNull.Value, 30);
            AddParam(c, "@show",            DbType.String, (object?)show ?? "NEW", 20);
            AddParam(c, "@search",          DbType.String, (object?)search ?? DBNull.Value, 200);
        }, cancellationToken);

    public async Task<Dictionary<string, object?>> GetLookupsAsync(long organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = Proc(connection, "sp_org_assurance_universe_lookups");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var people      = await ReadRowsAsync(reader, cancellationToken);
        var units       = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : new List<Dictionary<string, object?>>();
        var departments = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : new List<Dictionary<string, object?>>();
        var subjects    = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : new List<Dictionary<string, object?>>();
        return new Dictionary<string, object?>
        {
            ["people"]      = people,
            ["units"]       = units,
            ["departments"] = departments,
            ["subjects"]    = subjects
        };
    }

    public Task<List<Dictionary<string, object?>>> ListSubjectsAsync(
        long organizationId, long? categoryId, string? status, string? source, long? criticalityId,
        long? ownerEmployeeId, long? departmentId, string? search, long? employeeId, string actor, CancellationToken cancellationToken)
        => ReadAsync("sp_org_assurance_universe_list", c =>
        {
            AddParam(c, "@organization_id",   DbType.Int64,  organizationId);
            AddParam(c, "@category_id",       DbType.Int64,  (object?)categoryId ?? DBNull.Value);
            AddParam(c, "@status_code",       DbType.String, (object?)status ?? DBNull.Value, 30);
            AddParam(c, "@subject_source",    DbType.String, (object?)source ?? DBNull.Value, 20);
            AddParam(c, "@criticality_id",    DbType.Int64,  (object?)criticalityId ?? DBNull.Value);
            AddParam(c, "@owner_employee_id", DbType.Int64,  (object?)ownerEmployeeId ?? DBNull.Value);
            AddParam(c, "@department_id",     DbType.Int64,  (object?)departmentId ?? DBNull.Value);
            AddParam(c, "@search",            DbType.String, (object?)search ?? DBNull.Value, 200);
            AddParam(c, "@employee_id",       DbType.Int64,  (object?)employeeId ?? DBNull.Value);
            AddParam(c, "@actor",             DbType.String, actor, 100);
        }, cancellationToken);

    public async Task<Dictionary<string, object?>?> GetSubjectAsync(long organizationId, long subjectId, long? employeeId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = Proc(connection, "sp_org_assurance_universe_get");
        AddParam(command, "@organization_id",     DbType.Int64, organizationId);
        AddParam(command, "@universe_subject_id", DbType.Int64, subjectId);
        AddParam(command, "@employee_id",         DbType.Int64, (object?)employeeId ?? DBNull.Value);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var subject       = await ReadRowsAsync(reader, cancellationToken);
        var sources       = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : new List<Dictionary<string, object?>>();
        var relationships = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : new List<Dictionary<string, object?>>();
        var children      = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : new List<Dictionary<string, object?>>();
        var history       = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : new List<Dictionary<string, object?>>();
        if (subject.Count == 0) return null;
        return new Dictionary<string, object?>
        {
            ["subject"]       = subject[0],
            ["sources"]       = sources,
            ["relationships"] = relationships,
            ["children"]      = children,
            ["history"]       = history
        };
    }

    public Task<List<Dictionary<string, object?>>> ListHistoryAsync(
        long organizationId, long? subjectId, string? action, DateTime? from, DateTime? to, string? search, CancellationToken cancellationToken)
        => ReadAsync("sp_org_assurance_universe_history_list", c =>
        {
            AddParam(c, "@organization_id",     DbType.Int64,  organizationId);
            AddParam(c, "@universe_subject_id", DbType.Int64,  (object?)subjectId ?? DBNull.Value);
            AddParam(c, "@action_code",         DbType.String, (object?)action ?? DBNull.Value, 30);
            AddParam(c, "@from_dt",             DbType.Date,   (object?)from ?? DBNull.Value);
            AddParam(c, "@to_dt",               DbType.Date,   (object?)to ?? DBNull.Value);
            AddParam(c, "@search",              DbType.String, (object?)search ?? DBNull.Value, 200);
        }, cancellationToken);

    // -----------------------------------------------------------------
    // Writes
    // -----------------------------------------------------------------
    public Task<OrgAssuranceUniverseResult> SaveMasterAsync(OrgAssuranceUniverseMasterSaveRequest r, long? employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_universe_master_save", "@universe_master_id_out", c =>
        {
            AddParam(c, "@organization_id",    DbType.Int64,   r.OrganizationId);
            AddParam(c, "@universe_master_id", DbType.Int64,   (object?)r.UniverseMasterId ?? DBNull.Value);
            AddParam(c, "@master_group",       DbType.String,  r.MasterGroup, 30);
            AddParam(c, "@code",               DbType.String,  r.Code, 40);
            AddParam(c, "@name",               DbType.String,  r.Name, 200);
            AddParam(c, "@description",        DbType.String,  (object?)r.Description ?? DBNull.Value, 1000);
            AddParam(c, "@parent_master_id",   DbType.Int64,   (object?)r.ParentMasterId ?? DBNull.Value);
            AddParam(c, "@rank_value",         DbType.Int32,   (object?)r.RankValue ?? DBNull.Value);
            AddParam(c, "@display_order",      DbType.Int32,   r.DisplayOrder);
            AddParam(c, "@is_active",          DbType.Boolean, r.IsActive);
            AddParam(c, "@employee_id",        DbType.Int64,   (object?)employeeId ?? DBNull.Value);
            AddParam(c, "@actor",              DbType.String,  actor, 100);
        }, r.UniverseMasterId, cancellationToken);

    public Task<OrgAssuranceUniverseResult> ApplyDiscoveryAsync(OrgAssuranceUniverseDiscoverRequest r, long? employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_universe_discover_apply", "@applied_count", c =>
        {
            AddParam(c, "@organization_id", DbType.Int64,  r.OrganizationId);
            AddParam(c, "@action",          DbType.String, r.Action, 20);
            // camelCase keys for the procedure's OPENJSON
            AddParam(c, "@records_json",    DbType.String, System.Text.Json.JsonSerializer.Serialize(
                (r.Records ?? []).Select(x => new { kind = x.Kind, id = x.Id })), -1);
            AddParam(c, "@reason",          DbType.String, (object?)r.Reason ?? DBNull.Value, 2000);
            AddParam(c, "@category_id",     DbType.Int64,  (object?)r.CategoryId ?? DBNull.Value);
            AddParam(c, "@employee_id",     DbType.Int64,  (object?)employeeId ?? DBNull.Value);
            AddParam(c, "@actor",           DbType.String, actor, 100);
        }, null, cancellationToken, DbType.Int32);

    public Task<OrgAssuranceUniverseResult> SaveSubjectAsync(OrgAssuranceUniverseSaveRequest r, long? employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_universe_save", "@universe_subject_id_out", c =>
        {
            AddParam(c, "@organization_id",     DbType.Int64,  r.OrganizationId);
            AddParam(c, "@universe_subject_id", DbType.Int64,  (object?)r.UniverseSubjectId ?? DBNull.Value);
            AddParam(c, "@version_no",          DbType.Int32,  (object?)r.VersionNo ?? DBNull.Value);
            AddParam(c, "@subject_name",        DbType.String, r.SubjectName, 300);
            AddParam(c, "@description",         DbType.String, (object?)r.Description ?? DBNull.Value, -1);
            AddParam(c, "@category_id",         DbType.Int64,  (object?)r.CategoryId ?? DBNull.Value);
            AddParam(c, "@subcategory_id",      DbType.Int64,  (object?)r.SubcategoryId ?? DBNull.Value);
            AddParam(c, "@classification_id",   DbType.Int64,  (object?)r.ClassificationId ?? DBNull.Value);
            AddParam(c, "@reg_significance_id", DbType.Int64,  (object?)r.RegSignificanceId ?? DBNull.Value);
            AddParam(c, "@criticality_id",      DbType.Int64,  (object?)r.CriticalityId ?? DBNull.Value);
            AddParam(c, "@parent_subject_id",   DbType.Int64,  (object?)r.ParentSubjectId ?? DBNull.Value);
            AddParam(c, "@subject_source",      DbType.String, (object?)r.SubjectSource ?? DBNull.Value, 20);
            AddParam(c, "@owner_employee_id",   DbType.Int64,  (object?)r.OwnerEmployeeId ?? DBNull.Value);
            AddParam(c, "@division_id",         DbType.Int64,  (object?)r.DivisionId ?? DBNull.Value);
            AddParam(c, "@department_id",       DbType.Int64,  (object?)r.DepartmentId ?? DBNull.Value);
            AddParam(c, "@effective_from",      DbType.Date,   (object?)r.EffectiveFrom ?? DBNull.Value);
            AddParam(c, "@remarks",             DbType.String, (object?)r.Remarks ?? DBNull.Value, 2000);
            AddParam(c, "@sources_json",        DbType.String, r.Sources is null ? DBNull.Value : (object)System.Text.Json.JsonSerializer.Serialize(
                r.Sources.Select(x => new { kind = x.Kind, id = x.Id, isPrimary = x.IsPrimary ?? false })), -1);
            AddParam(c, "@employee_id",         DbType.Int64,  (object?)employeeId ?? DBNull.Value);
            AddParam(c, "@actor",               DbType.String, actor, 100);
        }, r.UniverseSubjectId, cancellationToken);

    public Task<OrgAssuranceUniverseResult> SubjectActionAsync(
        long subjectId, long employeeId, OrgAssuranceUniverseActionRequest r, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_universe_action", null, c =>
        {
            AddParam(c, "@organization_id",     DbType.Int64,  r.OrganizationId);
            AddParam(c, "@universe_subject_id", DbType.Int64,  subjectId);
            AddParam(c, "@action",              DbType.String, r.Action, 20);
            AddParam(c, "@comment",             DbType.String, (object?)r.Comment ?? DBNull.Value, -1);
            AddParam(c, "@version_no",          DbType.Int32,  (object?)r.VersionNo ?? DBNull.Value);
            AddParam(c, "@employee_id",         DbType.Int64,  employeeId);
            AddParam(c, "@actor",               DbType.String, actor, 100);
        }, subjectId, cancellationToken);

    public Task<OrgAssuranceUniverseResult> SaveRelationshipAsync(
        OrgAssuranceUniverseRelationshipSaveRequest r, long? employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_universe_relationship_save", "@universe_relationship_id_out", c =>
        {
            AddParam(c, "@organization_id",          DbType.Int64,   r.OrganizationId);
            AddParam(c, "@universe_relationship_id", DbType.Int64,   (object?)r.UniverseRelationshipId ?? DBNull.Value);
            AddParam(c, "@from_subject_id",          DbType.Int64,   (object?)r.FromSubjectId ?? DBNull.Value);
            AddParam(c, "@to_subject_id",            DbType.Int64,   (object?)r.ToSubjectId ?? DBNull.Value);
            AddParam(c, "@relationship_type_id",     DbType.Int64,   (object?)r.RelationshipTypeId ?? DBNull.Value);
            AddParam(c, "@remarks",                  DbType.String,  (object?)r.Remarks ?? DBNull.Value, 1000);
            AddParam(c, "@is_active",                DbType.Boolean, r.IsActive);
            AddParam(c, "@employee_id",              DbType.Int64,   (object?)employeeId ?? DBNull.Value);
            AddParam(c, "@actor",                    DbType.String,  actor, 100);
        }, r.UniverseRelationshipId, cancellationToken);

    // -----------------------------------------------------------------
    // 580: Framework & Practice Mapping
    // -----------------------------------------------------------------
    public async Task<Dictionary<string, object?>> ListMappingsAsync(
        long organizationId, long subjectId, string? level, string? status, string? source, string? search, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = Proc(connection, "sp_org_assurance_universe_mapping_list");
        AddParam(command, "@organization_id",     DbType.Int64,  organizationId);
        AddParam(command, "@universe_subject_id", DbType.Int64,  subjectId);
        AddParam(command, "@mapping_level",       DbType.String, (object?)level ?? DBNull.Value, 30);
        AddParam(command, "@mapping_status",      DbType.String, (object?)status ?? DBNull.Value, 20);
        AddParam(command, "@mapping_source",      DbType.String, (object?)source ?? DBNull.Value, 10);
        AddParam(command, "@search",              DbType.String, (object?)search ?? DBNull.Value, 200);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var rows   = await ReadRowsAsync(reader, cancellationToken);
        var counts = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : new List<Dictionary<string, object?>>();
        return new Dictionary<string, object?> { ["data"] = rows, ["counts"] = counts };
    }

    public Task<List<Dictionary<string, object?>>> ListMappingOptionsAsync(long organizationId, string level, CancellationToken cancellationToken)
        => ReadAsync("sp_org_assurance_universe_mapping_options", c =>
        {
            AddParam(c, "@organization_id", DbType.Int64,  organizationId);
            AddParam(c, "@mapping_level",   DbType.String, level, 30);
        }, cancellationToken);

    public Task<OrgAssuranceUniverseResult> SuggestMappingsAsync(long subjectId, long organizationId, long? employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_universe_mapping_suggest", "@suggested_count", c =>
        {
            AddParam(c, "@organization_id",     DbType.Int64,  organizationId);
            AddParam(c, "@universe_subject_id", DbType.Int64,  subjectId);
            AddParam(c, "@employee_id",         DbType.Int64,  (object?)employeeId ?? DBNull.Value);
            AddParam(c, "@actor",               DbType.String, actor, 100);
        }, null, cancellationToken, DbType.Int32);

    public Task<OrgAssuranceUniverseResult> AddMappingsAsync(
        long subjectId, OrgAssuranceUniverseMappingAddRequest r, long? employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_universe_mapping_add", "@added_count", c =>
        {
            AddParam(c, "@organization_id",     DbType.Int64,  r.OrganizationId);
            AddParam(c, "@universe_subject_id", DbType.Int64,  subjectId);
            AddParam(c, "@mapping_level",       DbType.String, r.Level, 30);
            AddParam(c, "@keys_json",           DbType.String, System.Text.Json.JsonSerializer.Serialize(r.Keys ?? Array.Empty<string>()), -1);
            AddParam(c, "@remarks",             DbType.String, (object?)r.Remarks ?? DBNull.Value, 1000);
            AddParam(c, "@employee_id",         DbType.Int64,  (object?)employeeId ?? DBNull.Value);
            AddParam(c, "@actor",               DbType.String, actor, 100);
        }, null, cancellationToken, DbType.Int32);

    public Task<OrgAssuranceUniverseResult> MappingActionAsync(
        long subjectId, OrgAssuranceUniverseMappingActionRequest r, long? employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_universe_mapping_action", "@applied_count", c =>
        {
            AddParam(c, "@organization_id",     DbType.Int64,  r.OrganizationId);
            AddParam(c, "@universe_subject_id", DbType.Int64,  subjectId);
            AddParam(c, "@action",              DbType.String, r.Action, 20);
            AddParam(c, "@mapping_ids_json",    DbType.String, System.Text.Json.JsonSerializer.Serialize(r.MappingIds ?? Array.Empty<long>()), -1);
            AddParam(c, "@remarks",             DbType.String, (object?)r.Remarks ?? DBNull.Value, 1000);
            AddParam(c, "@employee_id",         DbType.Int64,  (object?)employeeId ?? DBNull.Value);
            AddParam(c, "@actor",               DbType.String, actor, 100);
        }, null, cancellationToken, DbType.Int32);

    // -----------------------------------------------------------------
    // 581: Enterprise Risk Intelligence (read only -- Risk Management's
    // records as they are now)
    // -----------------------------------------------------------------
    public async Task<Dictionary<string, object?>> GetRiskIntelligenceAsync(long organizationId, long subjectId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = Proc(connection, "sp_org_assurance_universe_risk_intelligence");
        AddParam(command, "@organization_id",     DbType.Int64, organizationId);
        AddParam(command, "@universe_subject_id", DbType.Int64, subjectId);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var result = new Dictionary<string, object?>();
        var names  = new[] { "risks", "gaps", "exceptions", "instances", "findings", "summary" };
        for (var i = 0; i < names.Length; i++)
        {
            if (i > 0 && !await reader.NextResultAsync(cancellationToken)) { result[names[i]] = new List<Dictionary<string, object?>>(); continue; }
            result[names[i]] = await ReadRowsAsync(reader, cancellationToken);
        }
        return result;
    }

    // -----------------------------------------------------------------
    // Helpers (as OrgAssuranceReportService)
    // -----------------------------------------------------------------
    private async Task<List<Dictionary<string, object?>>> ReadAsync(
        string procedure, Action<DbCommand> addParams, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = Proc(connection, procedure);
        addParams(command);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await ReadRowsAsync(reader, cancellationToken);
    }

    private async Task<OrgAssuranceUniverseResult> WriteAsync(
        string procedure, string? idOutput, Action<DbCommand> addParams, long? id, CancellationToken cancellationToken,
        DbType outputType = DbType.Int64)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = Proc(connection, procedure);
            addParams(command);
            DbParameter? output = null;
            if (idOutput is not null)
            {
                output = command.CreateParameter();
                output.ParameterName = idOutput;
                output.DbType        = outputType;
                output.Direction     = ParameterDirection.Output;
                command.Parameters.Add(output);
            }
            await command.ExecuteNonQueryAsync(cancellationToken);
            var outId = output?.Value is null or DBNull ? id : Convert.ToInt64(output.Value);
            return new OrgAssuranceUniverseResult(true, outId);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "OrgAssuranceUniverseService.{Procedure} SQL error {Number}: {Message}",
                procedure, ex.Number, ex.Message);
            return new OrgAssuranceUniverseResult(false, Error: ex.Message, ReasonCode: MapReason(ex.Number));
        }
    }

    private static DbCommand Proc(DbConnection connection, string procedure)
    {
        var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice." + procedure;
        return command;
    }

    private static async Task<List<Dictionary<string, object?>>> ReadRowsAsync(DbDataReader reader, CancellationToken cancellationToken)
    {
        var rows = new List<Dictionary<string, object?>>();
        while (await reader.ReadAsync(cancellationToken))
        {
            var row = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
            for (var i = 0; i < reader.FieldCount; i++)
                row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            rows.Add(row);
        }
        return rows;
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
        p.Value         = value ?? DBNull.Value;
        if (size.HasValue) p.Size = size.Value;
        command.Parameters.Add(p);
    }

    // 577 THROW numbers (54090-54099); 580 (54120-54126).
    private static string MapReason(int errorNumber) => errorNumber switch
    {
        54090 => "UNIVERSE_NOT_FOUND",
        54091 => "UNIVERSE_STATE",
        54092 => "UNIVERSE_HIA_ONLY",
        54093 => "UNIVERSE_OWN_SUBMISSION",
        54094 => "UNIVERSE_REASON_REQUIRED",
        54095 => "UNIVERSE_FIELD_REQUIRED",
        54096 => "UNIVERSE_INVALID_REFERENCE",
        54097 => "UNIVERSE_DUPLICATE",
        54098 => "UNIVERSE_CONCURRENCY",
        54099 => "UNIVERSE_MASTER_LOCKED",
        // 580 (54120-54126)
        54120 => "UNIVERSE_NOT_FOUND",
        54121 => "UNIVERSE_STATE",
        54122 => "MAPPING_UNKNOWN",
        54123 => "MAPPING_NOTHING_SELECTED",
        54124 => "MAPPING_NOT_AVAILABLE",
        54125 => "MAPPING_STATE",
        54126 => "UNIVERSE_REASON_REQUIRED",
        _     => "SQL_ERROR"
    };
}
