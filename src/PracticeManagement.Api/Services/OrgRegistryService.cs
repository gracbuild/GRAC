// =====================================================================
// OrgRegistryService  (migrations 569-572)
//
// Facade over the Organization Registry procedures (571):
//   sp_orgreg_lookups           LookupsAsync   controlled values + pickable records
//   sp_orgreg_summary           SummaryAsync   Legal Entities with per-area counts
//   sp_orgreg_<area>_list       ListAsync      one area's rows
//   sp_orgreg_<area>_save       SaveAsync      insert (id 0) or update
//
// <area> is one of Areas below and nothing else: the procedure name is
// built from a fixed whitelist, never from free text. Every rule (mandatory
// fields, controlled values, references, unique codes, parent loops) is in
// the save procedure; its refusals are THROW 52700-52706 with a message
// that starts "[fieldKey] ", returned here as Field + Message.
// allowed (575): the caller's Legal Entities when the call comes from
// Practice Management -> Organization (organization users); null from
// Organization Management (GRAC administration). There is no
// delete -- a record is retired through its status (workbook START HERE:
// keep inactive / closed records for traceability).
// =====================================================================
using System.Data;
using System.Data.Common;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IOrgRegistryService
{
    bool IsArea(string? area);
    // allowed (575): null = every Legal Entity (GRAC administration);
    // otherwise only these organization ids -- see sp_orgreg_* @allowed_legal_entity_ids.
    Task<object> LookupsAsync(long registryOrganizationId, long legalEntityId, long[]? allowed, CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> SummaryAsync(long registryOrganizationId, long[]? allowed, CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> ListAsync(string area, long registryOrganizationId, long legalEntityId, long id,
        string? status, string? search, long[]? allowed, CancellationToken cancellationToken);
    Task<OrgRegistrySaveResult> SaveAsync(string area, long id, string payloadJson, string actor, long[]? allowed, CancellationToken cancellationToken);
}

public sealed class OrgRegistryService(IConfiguration configuration) : IOrgRegistryService
{
    // Area key (URL) -> procedure stem. Same keys as the screen's tabs.
    private static readonly Dictionary<string, string> Areas = new(StringComparer.OrdinalIgnoreCase)
    {
        ["organizations"]     = "organizations",
        ["legal-entities"]    = "legal_entities",
        ["units"]             = "units",
        ["locations"]         = "locations",
        ["departments"]       = "departments",
        ["functions"]         = "functions",
        ["teams"]             = "teams",
        ["people"]            = "people",
        ["committees"]        = "committees",
        ["committee-members"] = "committee_members",
        ["processes"]         = "processes",
        ["products"]          = "products",
        ["channels"]          = "channels"
    };

    public bool IsArea(string? area) => area is not null && Areas.ContainsKey(area);

    public async Task<object> LookupsAsync(long registryOrganizationId, long legalEntityId, long[]? allowed, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_orgreg_lookups";
        AddParam(command, "@registry_organization_id", DbType.Int64, registryOrganizationId);
        AddParam(command, "@legal_entity_id", DbType.Int64, legalEntityId);
        AddAllowed(command, allowed);

        var masters = new List<Dictionary<string, object?>>();
        var records = new List<Dictionary<string, object?>>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken)) masters.Add(ReadRow(reader));
        if (await reader.NextResultAsync(cancellationToken))
            while (await reader.ReadAsync(cancellationToken)) records.Add(ReadRow(reader));
        return new { masters, records };
    }

    public async Task<List<Dictionary<string, object?>>> SummaryAsync(long registryOrganizationId, long[]? allowed, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_orgreg_summary";
        AddParam(command, "@registry_organization_id", DbType.Int64, registryOrganizationId);
        AddAllowed(command, allowed);
        return await ReadAllAsync(command, cancellationToken);
    }

    public async Task<List<Dictionary<string, object?>>> ListAsync(string area, long registryOrganizationId, long legalEntityId, long id,
        string? status, string? search, long[]? allowed, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = $"grac_practice.sp_orgreg_{Areas[area]}_list";
        AddParam(command, "@registry_organization_id", DbType.Int64, registryOrganizationId);
        AddParam(command, "@legal_entity_id", DbType.Int64, legalEntityId);
        AddParam(command, "@id", DbType.Int64, id);
        // "All" (or nothing) = every status; the procedure reads '' that way.
        AddParam(command, "@status", DbType.String,
            string.IsNullOrWhiteSpace(status) || status.Equals("All", StringComparison.OrdinalIgnoreCase) ? "" : status.Trim(), 40);
        AddParam(command, "@search", DbType.String, (search ?? "").Trim(), 200);
        AddAllowed(command, allowed);
        return await ReadAllAsync(command, cancellationToken);
    }

    public async Task<OrgRegistrySaveResult> SaveAsync(string area, long id, string payloadJson, string actor, long[]? allowed, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = $"grac_practice.sp_orgreg_{Areas[area]}_save";
            AddParam(command, "@id", DbType.Int64, id);
            AddParam(command, "@payload", DbType.String, payloadJson, -1);
            AddParam(command, "@actor", DbType.String, actor, 100);
            AddAllowed(command, allowed);

            Dictionary<string, object?>? outcome = null;
            await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
            {
                do
                {
                    while (await reader.ReadAsync(cancellationToken))
                    {
                        var row = ReadRow(reader);
                        if (row.ContainsKey("Success")) outcome = row;
                    }
                } while (await reader.NextResultAsync(cancellationToken));
            }
            long? savedId = outcome?.GetValueOrDefault("Id") is { } v ? Convert.ToInt64(v) : null;
            return new OrgRegistrySaveResult(true, outcome?.GetValueOrDefault("Message")?.ToString() ?? "Saved.", savedId, null);
        }
        // 52700-52707: the procedure's own refusals, written for the user
        // (52707, 575: outside the caller's Legal Entities).
        catch (SqlException ex) when (ex.Number is >= 52700 and <= 52707)
        {
            var (field, message) = SplitField(ex.Message);
            return new OrgRegistrySaveResult(false, message, null, field);
        }
        // A unique index caught a race the procedure's own check missed.
        catch (SqlException ex) when (ex.Number is 2601 or 2627)
        {
            return new OrgRegistrySaveResult(false, "Another record already uses this code or name. Reload the list and try again.", null, null);
        }
        // A foreign key: something the form pointed at went away meanwhile.
        catch (SqlException ex) when (ex.Number == 547)
        {
            return new OrgRegistrySaveResult(false, "A selected record no longer exists or is still in use. Reload the list and try again.", null, null);
        }
    }

    // "[fieldKey] message" -> (fieldKey, message); "[] message" -> (null, message).
    private static (string? Field, string Message) SplitField(string raw)
    {
        var m = FieldPrefix.Match(raw ?? "");
        if (!m.Success) return (null, raw ?? "");
        var field = m.Groups[1].Value;
        return (string.IsNullOrWhiteSpace(field) ? null : field, m.Groups[2].Value.Trim());
    }

    private static readonly Regex FieldPrefix = new(@"^\[([A-Za-z0-9]*)\]\s*(.*)$", RegexOptions.Singleline | RegexOptions.Compiled);

    // ------------------------------------------------------------------
    private static async Task<List<Dictionary<string, object?>>> ReadAllAsync(DbCommand command, CancellationToken cancellationToken)
    {
        var rows = new List<Dictionary<string, object?>>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(ReadRow(reader));
        return rows;
    }

    private static Dictionary<string, object?> ReadRow(DbDataReader reader)
    {
        var row = new Dictionary<string, object?>(reader.FieldCount, StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < reader.FieldCount; i++)
            row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
        return row;
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

    // null -> NULL (every Legal Entity); otherwise a JSON array of ids. An
    // empty array is kept as "[]": a caller with no organizations sees nothing.
    private static void AddAllowed(DbCommand command, long[]? allowed) =>
        AddParam(command, "@allowed_legal_entity_ids", DbType.String,
            allowed is null ? null : System.Text.Json.JsonSerializer.Serialize(allowed), -1);

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
