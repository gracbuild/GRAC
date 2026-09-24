// =====================================================================
// OrgAssuranceSetupService
//
// Phase 2 Audit Management -- thin wrapper over the three procedures in
// migration 278:
//   sp_org_assurance_definition_question_set_get
//   sp_org_assurance_definition_question_set_save
//   sp_org_assurance_setup_status
//
// Follows OrgAssuranceQuestionService line for line: primary-constructor
// injection, Infrastructure.SqlConnectionStringResolver for the
// connection, the AddParam helper with snake_case @-parameters, and
// structured *Result records. No business rules live here -- ownership,
// the Draft-only gate and the status vocabulary are all enforced in the
// procedures, so a second caller cannot bypass them.
// =====================================================================
using System.Data;
using System.Data.Common;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IOrgAssuranceSetupService
{
    Task<OrgAssuranceDefinitionQuestionSetResult> GetQuestionSetsAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken);

    Task<OrgAssuranceDefinitionQuestionSetSaveResult> SaveQuestionSetsAsync(
        OrgAssuranceDefinitionQuestionSetSaveRequest request, CancellationToken cancellationToken);

    Task<OrgAssuranceSetupStatusResult> GetSetupStatusAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken);
}

public sealed class OrgAssuranceSetupService(
    IConfiguration configuration,
    ILogger<OrgAssuranceSetupService> logger) : IOrgAssuranceSetupService
{
    // -----------------------------------------------------------------
    // Question set adoption -- read
    // -----------------------------------------------------------------
    public async Task<OrgAssuranceDefinitionQuestionSetResult> GetQuestionSetsAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_definition_question_set_get";
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@definition_id",   DbType.Int64, definitionId);
        AddParam(command, "@version_id",      DbType.Int64, (object?)versionId ?? DBNull.Value);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        // Result set 1 -- header.
        var header = new OrgAssuranceSetupHeader(definitionId, null, null, null, false);
        if (await reader.ReadAsync(cancellationToken)) header = ReadHeader(reader, definitionId);

        // Result set 2 -- adopted.
        var adopted = new List<OrgAssuranceDefinitionQuestionSetRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                adopted.Add(new OrgAssuranceDefinitionQuestionSetRow(
                    ReadLongOrNull(reader,   "DefinitionQuestionSetId"),
                    ReadLongOrNull(reader,   "QuestionSetId"),
                    ReadStringOrNull(reader, "SetCode"),
                    ReadStringOrNull(reader, "SetName"),
                    ReadIntOrNull(reader,    "DisplayOrder"),
                    ReadBool(reader,         "IsMandatory"),
                    ReadIntOrNull(reader,    "QuestionCount")));
            }
        }

        // Result set 3 -- available.
        var available = new List<OrgAssuranceAvailableQuestionSetRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                available.Add(new OrgAssuranceAvailableQuestionSetRow(
                    ReadLongOrNull(reader,   "QuestionSetId"),
                    ReadStringOrNull(reader, "SetCode"),
                    ReadStringOrNull(reader, "SetName"),
                    ReadIntOrNull(reader,    "QuestionCount")));
            }
        }

        return new OrgAssuranceDefinitionQuestionSetResult(header, adopted, available);
    }

    // -----------------------------------------------------------------
    // Question set adoption -- full-replacement save
    // -----------------------------------------------------------------
    public async Task<OrgAssuranceDefinitionQuestionSetSaveResult> SaveQuestionSetsAsync(
        OrgAssuranceDefinitionQuestionSetSaveRequest request, CancellationToken cancellationToken)
    {
        // camelCase keys, because the procedure's OPENJSON reads
        // $.questionSetId / $.displayOrder / $.isMandatory.
        var itemsJson = JsonSerializer.Serialize(
            (request.Items ?? []).Select(i => new
            {
                questionSetId = i.QuestionSetId,
                displayOrder  = i.DisplayOrder,
                isMandatory   = i.IsMandatory
            }));

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_definition_question_set_save";
        AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
        AddParam(command, "@definition_id",   DbType.Int64,  request.DefinitionId);
        AddParam(command, "@items_json",      DbType.String, itemsJson, -1);
        AddParam(command, "@actor",           DbType.String, (object?)request.Actor ?? (object)"system", 100);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (await reader.ReadAsync(cancellationToken))
        {
            return new OrgAssuranceDefinitionQuestionSetSaveResult(
                ReadBool(reader,       "Success"),
                ReadLongOrNull(reader, "DefinitionId"),
                ReadLongOrNull(reader, "VersionId"),
                ReadIntOrNull(reader,  "AdoptedCount"));
        }

        logger.LogWarning(
            "sp_org_assurance_definition_question_set_save returned no row for definition {DefinitionId}.",
            request.DefinitionId);
        return new OrgAssuranceDefinitionQuestionSetSaveResult(false, request.DefinitionId, null, null);
    }

    // -----------------------------------------------------------------
    // Setup status roll-up
    // -----------------------------------------------------------------
    public async Task<OrgAssuranceSetupStatusResult> GetSetupStatusAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_setup_status";
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@definition_id",   DbType.Int64, definitionId);
        AddParam(command, "@version_id",      DbType.Int64, (object?)versionId ?? DBNull.Value);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        var header = new OrgAssuranceSetupHeader(definitionId, null, null, null, false);
        if (await reader.ReadAsync(cancellationToken)) header = ReadHeader(reader, definitionId);

        var steps = new List<OrgAssuranceSetupStatusRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                steps.Add(new OrgAssuranceSetupStatusRow(
                    ReadStringOrNull(reader, "StepKey") ?? "",
                    ReadStringOrNull(reader, "StepName"),
                    ReadIntOrNull(reader,    "ItemCount"),
                    ReadStringOrNull(reader, "Status")));
            }
        }

        return new OrgAssuranceSetupStatusResult(header, steps);
    }

    // -----------------------------------------------------------------
    // Helpers -- identical to OrgAssuranceQuestionService.
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

    private static OrgAssuranceSetupHeader ReadHeader(DbDataReader r, long definitionId) => new(
        ReadLongOrNull(r, "DefinitionId") ?? definitionId,
        ReadLongOrNull(r, "VersionId"),
        ReadLongOrNull(r, "CurrentVersionId"),
        ReadStringOrNull(r, "CurrentStatusCode"),
        ReadBool(r, "IsEditable"));

    private static long?   ReadLongOrNull(DbDataReader r, string col)   => r[col] == DBNull.Value ? null : Convert.ToInt64(r[col]);
    private static int?    ReadIntOrNull(DbDataReader r, string col)    => r[col] == DBNull.Value ? null : Convert.ToInt32(r[col]);
    private static string? ReadStringOrNull(DbDataReader r, string col) => r[col] == DBNull.Value ? null : r[col].ToString();
    private static bool    ReadBool(DbDataReader r, string col)         => r[col] != DBNull.Value && Convert.ToBoolean(r[col]);
}
