// =====================================================================
// ProcParameterProbe
//
// Shared "does this procedure declare that parameter?" probe.
//
// Extracted from TaskService, which has carried a private copy since the
// Task Centre v2 work. RiskCentreService needed the same check when its
// register list finally started sending @analysis_pending, and copying
// the method a second time would have left two implementations of one
// rule to keep in step.
//
// WHY IT EXISTS. It lets the Api tier stay deployable against a database
// that has not yet received a migration: a newer optional parameter is
// bound only when the procedure actually declares it. The alternative is
// the failure this codebase has hit more than once —
//
//     "Procedure or function <name> has too many arguments specified."
//
// — which takes down the whole screen rather than degrading one filter.
// Cheap metadata query, and far better operationally than a hard failure.
//
// NOT a substitute for running migrations. It buys an ordered rollout
// (deploy Api, then database, or the reverse) without a hard outage in
// between; it does not make the feature work until the migration lands.
// =====================================================================
using System.Data;
using System.Data.Common;

namespace PracticeManagement.Api.Infrastructure;

public static class ProcParameterProbe
{
    /// <summary>
    /// True when <paramref name="procName"/> in the grac_practice schema
    /// declares <paramref name="parameterName"/>. Both are passed as
    /// values, never concatenated into the SQL text.
    /// </summary>
    /// <param name="procName">Bare procedure name, no schema prefix.</param>
    /// <param name="parameterName">Parameter name including its leading @.</param>
    public static async Task<bool> HasParameterAsync(
        DbConnection connection, string procName, string parameterName,
        CancellationToken cancellationToken)
    {
        await using var cmd = connection.CreateCommand();
        cmd.CommandType = CommandType.Text;
        cmd.CommandText = @"
            SELECT CASE WHEN EXISTS (
                       SELECT 1 FROM sys.parameters
                        WHERE object_id = OBJECT_ID('grac_practice.' + @proc)
                          AND name = @param)
                   THEN 1 ELSE 0 END;";

        var p1 = cmd.CreateParameter();
        p1.ParameterName = "@proc";
        p1.DbType = DbType.String;
        p1.Size = 128;
        p1.Value = procName;
        cmd.Parameters.Add(p1);

        var p2 = cmd.CreateParameter();
        p2.ParameterName = "@param";
        p2.DbType = DbType.String;
        p2.Size = 128;
        p2.Value = parameterName;
        cmd.Parameters.Add(p2);

        var result = await cmd.ExecuteScalarAsync(cancellationToken);
        return result is not null && Convert.ToInt32(result) == 1;
    }
}
