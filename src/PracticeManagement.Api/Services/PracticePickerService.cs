// =====================================================================
// PracticePickerService
//
// Thin wrapper over the five sp_practice_picker_* procedures in
// migration 282. Read-only: every method is a SELECT, nothing here
// writes.
//
// Follows OrgAssuranceQuestionService / OrgAssuranceSetupService line
// for line -- primary-constructor injection,
// Infrastructure.SqlConnectionStringResolver for the connection, the
// AddParam helper with snake_case @-parameters, and the same
// Read*OrNull readers. No business rule lives here; the hierarchy and
// the organisation scoping are enforced in the procedures, so a second
// caller cannot bypass them.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IPracticePickerService
{
    Task<IReadOnlyList<PracticePickerFramework>> ListFrameworksAsync(
        long organizationId, CancellationToken cancellationToken);

    Task<IReadOnlyList<PracticePickerStructure>> ListStructuresAsync(
        long organizationId, long releaseId, CancellationToken cancellationToken);

    Task<IReadOnlyList<PracticePickerControl>> ListControlsAsync(
        long organizationId, long? releaseId, long structureNodeId, CancellationToken cancellationToken);

    Task<IReadOnlyList<PracticePickerPractice>> ListPracticesAsync(
        long organizationId, long organizationControlId, string? search,
        string? excludePracticeIds, long? riskRegisterId,
        bool includeAlreadyMapped, CancellationToken cancellationToken);

    Task<PracticePickerPath?> ResolveAsync(
        long organizationId, long practiceId, CancellationToken cancellationToken);
}

public sealed class PracticePickerService(
    IConfiguration configuration,
    ILogger<PracticePickerService> logger) : IPracticePickerService
{
    public async Task<IReadOnlyList<PracticePickerFramework>> ListFrameworksAsync(
        long organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = Proc(connection, "grac_practice.sp_practice_picker_frameworks");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);

        var rows = new List<PracticePickerFramework>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new PracticePickerFramework(
                ReadLongOrNull(reader,   "SubscriptionId") ?? 0,
                ReadLongOrNull(reader,   "ReleaseId"),
                ReadLongOrNull(reader,   "ArtifactId"),
                ReadStringOrNull(reader, "AuthorityName"),
                ReadStringOrNull(reader, "ArtifactName"),
                ReadStringOrNull(reader, "ReleaseVersion"),
                ReadStringOrNull(reader, "FrameworkName")));
        }
        return rows;
    }

    public async Task<IReadOnlyList<PracticePickerStructure>> ListStructuresAsync(
        long organizationId, long releaseId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = Proc(connection, "grac_practice.sp_practice_picker_structures");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@release_id",      DbType.Int64, releaseId);

        var rows = new List<PracticePickerStructure>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new PracticePickerStructure(
                ReadLongOrNull(reader,   "StructureNodeId") ?? 0,
                ReadLongOrNull(reader,   "ParentNodeId"),
                ReadIntOrNull(reader,    "NodeLevel"),
                ReadStringOrNull(reader, "NodeReference"),
                ReadStringOrNull(reader, "NodeTitle"),
                ReadStringOrNull(reader, "StructureName"),
                ReadIntOrNull(reader,    "ControlCount") ?? 0));
        }
        return rows;
    }

    public async Task<IReadOnlyList<PracticePickerControl>> ListControlsAsync(
        long organizationId, long? releaseId, long structureNodeId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = Proc(connection, "grac_practice.sp_practice_picker_controls");
        AddParam(command, "@organization_id",   DbType.Int64, organizationId);
        AddParam(command, "@release_id",        DbType.Int64, (object?)releaseId ?? DBNull.Value);
        AddParam(command, "@structure_node_id", DbType.Int64, structureNodeId);

        var rows = new List<PracticePickerControl>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new PracticePickerControl(
                ReadLongOrNull(reader,   "OrganizationControlId") ?? 0,
                ReadStringOrNull(reader, "ControlCode"),
                ReadStringOrNull(reader, "ControlName"),
                ReadStringOrNull(reader, "ApplicabilityStatus"),
                ReadIntOrNull(reader,    "PracticeCount") ?? 0));
        }
        return rows;
    }

    public async Task<IReadOnlyList<PracticePickerPractice>> ListPracticesAsync(
        long organizationId, long organizationControlId, string? search,
        string? excludePracticeIds, long? riskRegisterId,
        bool includeAlreadyMapped, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = Proc(connection, "grac_practice.sp_practice_picker_practices");
        AddParam(command, "@organization_id",         DbType.Int64,  organizationId);
        AddParam(command, "@organization_control_id", DbType.Int64,  organizationControlId);
        AddParam(command, "@search",                  DbType.String, (object?)search ?? DBNull.Value, 200);
        AddParam(command, "@exclude_practice_ids",    DbType.String, (object?)excludePracticeIds ?? DBNull.Value, -1);
        // 312. Bound only when the procedure actually declares them, so
        // an API tier ahead of the database keeps working: a database
        // still on 282 has neither parameter and would otherwise fail
        // with "procedure has too many arguments specified".
        if (await ProcHasParameterAsync(connection, "sp_practice_picker_practices", "@risk_register_id", cancellationToken))
        {
            AddParam(command, "@risk_register_id",       DbType.Int64,   (object?)riskRegisterId ?? DBNull.Value);
            AddParam(command, "@include_already_mapped", DbType.Boolean, includeAlreadyMapped);
        }

        var rows = new List<PracticePickerPractice>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new PracticePickerPractice(
                ReadLongOrNull(reader,   "PracticeId") ?? 0,
                ReadStringOrNull(reader, "PracticeCode"),
                ReadStringOrNull(reader, "PracticeName"),
                ReadStringOrNull(reader, "ApplicabilityStatus"),
                ReadLongOrNull(reader,   "OrganizationRequirementId"),
                ReadLongOrNull(reader,   "OrganizationControlId"),
                ReadStringOrNull(reader, "ControlCode"),
                // Absent on a pre-312 database -> false / null, which is
                // exactly the old behaviour.
                HasColumn(reader, "AlreadyMappedToRisk")
                    && reader["AlreadyMappedToRisk"] != DBNull.Value
                    && Convert.ToBoolean(reader["AlreadyMappedToRisk"]),
                HasColumn(reader, "MapSourceCode") ? ReadStringOrNull(reader, "MapSourceCode") : null));
        }
        return rows;
    }

    public async Task<PracticePickerPath?> ResolveAsync(
        long organizationId, long practiceId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = Proc(connection, "grac_practice.sp_practice_picker_resolve");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@practice_id",     DbType.Int64, practiceId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            // Not an error: a manually added practice reaches no control,
            // so it simply has no hierarchy to preselect. The caller shows
            // the picker empty and keeps the stored practice as-is.
            logger.LogInformation(
                "Practice {PracticeId} in organization {OrganizationId} has no control path to resolve.",
                practiceId, organizationId);
            return null;
        }

        return new PracticePickerPath(
            ReadLongOrNull(reader,   "PracticeId") ?? practiceId,
            ReadStringOrNull(reader, "PracticeCode"),
            ReadStringOrNull(reader, "PracticeName"),
            ReadLongOrNull(reader,   "OrganizationControlId"),
            ReadStringOrNull(reader, "ControlCode"),
            ReadStringOrNull(reader, "ControlName"),
            ReadLongOrNull(reader,   "StructureNodeId"),
            ReadStringOrNull(reader, "NodeTitle"),
            ReadStringOrNull(reader, "StructureName"),
            ReadLongOrNull(reader,   "ReleaseId"),
            ReadStringOrNull(reader, "FrameworkName"));
    }

    // -----------------------------------------------------------------
    // Helpers -- identical to the other org-assurance services.
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

    private static DbCommand Proc(DbConnection connection, string name)
    {
        var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = name;
        return command;
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

    // 312. The SHARED probe (Infrastructure.ProcParameterProbe), not a
    // local copy: TaskService already routes through it for exactly this
    // "is the database ahead of or behind this tier?" question, and two
    // implementations of that check would be two caches to warm and two
    // places to fix.
    private static Task<bool> ProcHasParameterAsync(
        DbConnection connection, string procName, string parameterName, CancellationToken cancellationToken)
        => Infrastructure.ProcParameterProbe.HasParameterAsync(
               connection, procName, parameterName, cancellationToken);

    // Column-presence guard, so a pre-312 result set (no
    // AlreadyMappedToRisk, no MapSourceCode) reads as the old behaviour
    // instead of throwing IndexOutOfRange. File-local, matching every
    // other service in this project.
    private static bool HasColumn(DbDataReader reader, string name)
    {
        for (var i = 0; i < reader.FieldCount; i++)
            if (string.Equals(reader.GetName(i), name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    private static long?   ReadLongOrNull(DbDataReader r, string col)   => r[col] == DBNull.Value ? null : Convert.ToInt64(r[col]);
    private static int?    ReadIntOrNull(DbDataReader r, string col)    => r[col] == DBNull.Value ? null : Convert.ToInt32(r[col]);
    private static string? ReadStringOrNull(DbDataReader r, string col) => r[col] == DBNull.Value ? null : r[col].ToString();
}
