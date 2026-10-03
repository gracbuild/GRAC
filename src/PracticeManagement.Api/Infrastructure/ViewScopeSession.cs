// =====================================================================
// ViewScopeSession  (migration 415 -- View Data Scope)
//
// The ONE place a database connection is told whose View Data Scope
// applies. Every service calls ApplyAsync right after opening its
// connection; it is a no-op unless the current request is a read with
// a known reader (CallerViewScope).
//
// For a reader it runs grac_practice.sp_pm_view_scope_session_set, which
// resolves the reader's roles' View Data Scope and, when it is not "All
// records", writes it into SESSION_CONTEXT. The row-level security policy
// grac_practice.pm_view_data_scope_policy (415) then filters every read
// of the scoped tables on that connection -- list, get, dashboard, any
// procedure or view -- in SQL. Nothing is filtered in the browser.
//
// SESSION_CONTEXT is cleared by sp_reset_connection when a pooled
// connection is reused, so one request's scope never leaks into another.
//
// Unrestricted readers (every role "All records" -- the default for every
// existing role) are remembered for a minute so their reads cost no extra
// round trip. A database without 415 (procedure missing, 2812) is treated
// as unrestricted, which is exactly the behaviour before 415. Any other
// failure is thrown: a scope that cannot be applied must not fall back to
// showing everything.
// =====================================================================
using System.Collections.Concurrent;
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;

namespace PracticeManagement.Api.Infrastructure;

public static class ViewScopeSession
{
    private static readonly TimeSpan UnrestrictedTtl = TimeSpan.FromSeconds(60);
    private static readonly ConcurrentDictionary<long, DateTime> Unrestricted = new();

    public static async Task ApplyAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        var employeeId = CallerViewScope.ReadingEmployeeId;
        if (employeeId is not { } reader) return;
        if (Unrestricted.TryGetValue(reader, out var until) && until > DateTime.UtcNow) return;

        object? scope;
        try
        {
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_pm_view_scope_session_set";
            var p = command.CreateParameter();
            p.ParameterName = "@employee_id";
            p.DbType = DbType.Int64;
            p.Value = reader;
            command.Parameters.Add(p);
            scope = await command.ExecuteScalarAsync(cancellationToken);
        }
        catch (SqlException ex) when (ex.Number == 2812)
        {
            // Migration 415 not applied yet: no View Data Scope exists.
            scope = "ALL";
        }

        if (scope is null or DBNull || string.Equals(Convert.ToString(scope), "ALL", StringComparison.OrdinalIgnoreCase))
            Unrestricted[reader] = DateTime.UtcNow.Add(UnrestrictedTtl);
        else
            Unrestricted.TryRemove(reader, out _);
    }
}
