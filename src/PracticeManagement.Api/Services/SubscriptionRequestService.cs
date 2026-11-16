// =====================================================================
// SubscriptionRequestService  (migration 511)
//
// Facade over the two migration-406 procedures Control Management already
// calls through its own dispatchers (cm_get_subscription_request /
// cm_manage_subscription_request). Practice Management's Organization
// Management -> Subscription Requests calls the SAME procedures, so the
// two modules share one queue and one rule set:
//   sp_repository_subscription_request_list    ListAsync
//   sp_repository_subscription_request_decide  DecideAsync
// The decide procedure locks the request and refuses one that is no longer
// Pending (51414), so a request decided in one module cannot be decided
// again in the other.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface ISubscriptionRequestService
{
    Task<List<Dictionary<string, object?>>> ListAsync(long? requestId, string? status, string? search, CancellationToken cancellationToken);
    Task<SubscriptionRequestDecisionResult> DecideAsync(long requestId, string decision, string? remark, string actor, CancellationToken cancellationToken);
}

public sealed class SubscriptionRequestService(IConfiguration configuration) : ISubscriptionRequestService
{
    public async Task<List<Dictionary<string, object?>>> ListAsync(long? requestId, string? status, string? search, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_repository_subscription_request_list";
        AddParam(command, "@request_id", DbType.Int64, requestId ?? 0);
        // "All" (or nothing) = every status; the procedure reads '' that way.
        AddParam(command, "@status", DbType.String,
            string.IsNullOrWhiteSpace(status) || status.Equals("All", StringComparison.OrdinalIgnoreCase)
                ? "" : status.Trim(), 20);
        AddParam(command, "@search", DbType.String, (search ?? "").Trim(), 250);

        var rows = new List<Dictionary<string, object?>>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(ReadRow(reader));
        return rows;
    }

    public async Task<SubscriptionRequestDecisionResult> DecideAsync(long requestId, string decision, string? remark, string actor, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_repository_subscription_request_decide";
            // Approve copies the release into the organization
            // (sp_repository_subscription_copy); allow more than the default.
            command.CommandTimeout = 300;
            AddParam(command, "@request_id", DbType.Int64, requestId);
            AddParam(command, "@decision", DbType.String, decision, 20);
            AddParam(command, "@remark", DbType.String, string.IsNullOrWhiteSpace(remark) ? DBNull.Value : remark.Trim(), 1000);
            AddParam(command, "@actor", DbType.String, actor, 100);

            // Approve runs the existing subscribe path, which returns its own
            // one-row result BEFORE the procedure's final row (406 header).
            // The outcome is the last result set that carries Success.
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

            var success = outcome is null || Convert.ToBoolean(outcome["Success"]);
            var message = outcome?.GetValueOrDefault("Message")?.ToString()
                          ?? (decision.Equals("Approve", StringComparison.OrdinalIgnoreCase) ? "Subscription request approved." : "Subscription request rejected.");
            long? subscriptionId = outcome?.GetValueOrDefault("SubscriptionId") is { } s ? Convert.ToInt64(s) : null;
            return new SubscriptionRequestDecisionResult(requestId, success, message, subscriptionId);
        }
        // 51411-51417: the procedure's own refusals (bad decision, reason
        // missing, not found, already decided, organization / release no
        // longer eligible, subscription not activated). Written for the user.
        catch (SqlException ex) when (ex.Number is >= 51411 and <= 51417)
        {
            return new SubscriptionRequestDecisionResult(requestId, false, ex.Message, null);
        }
    }

    // ------------------------------------------------------------------
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
