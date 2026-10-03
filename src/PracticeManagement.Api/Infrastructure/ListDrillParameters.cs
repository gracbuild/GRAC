// =====================================================================
// ListDrillParameters  (migration 414)
//
// Binds a dashboard drill-down (ListDrillFilter) onto a list procedure.
// One helper for the five lists that accept it -- Gap Register, Task
// Board, Exceptions, audit Executions, audit Observations -- so the
// parameter names and the "send it only when the procedure declares it"
// rule (ProcParameterProbe) are written once.
//
// Only set values are sent, and only when the procedure declares the
// parameter, so an Api deployed ahead of migration 414 still lists.
// =====================================================================
using System.Data;
using System.Data.Common;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Infrastructure;

public static class ListDrillParameters
{
    public static async Task AddAsync(
        DbConnection connection, DbCommand command, string procName,
        ListDrillFilter? filter, CancellationToken cancellationToken)
    {
        if (filter is null) return;

        async Task AddIf(string name, DbType type, object? value, int? size = null)
        {
            if (value is null) return;
            if (!await ProcParameterProbe.HasParameterAsync(connection, procName, name, cancellationToken)) return;
            var p = command.CreateParameter();
            p.ParameterName = name;
            p.DbType = type;
            if (size.HasValue) p.Size = size.Value;
            p.Value = value;
            command.Parameters.Add(p);
        }

        await AddIf("@drill_code",    DbType.String,  filter.DrillCode, 20);
        await AddIf("@status_text",   DbType.String,  filter.StatusText, 100);
        await AddIf("@severity_text", DbType.String,  filter.SeverityText, 200);
        await AddIf("@min_age_days",  DbType.Int32,   filter.MinAgeDays);
        await AddIf("@max_age_days",  DbType.Int32,   filter.MaxAgeDays);
        await AddIf("@no_owner",      DbType.Boolean, filter.NoOwner == true ? true : null);
    }
}
