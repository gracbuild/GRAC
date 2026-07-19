// =====================================================================
// CustomGapService
//
// Thin facade over grac_practice.sp_custom_gap_* procedures.
// Kept in its own file so it can be reviewed / wired independently of
// TaskService / PracticeRepositoryService.
//
// Registered via Infrastructure/CustomGapServiceRegistration.cs.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface ICustomGapService
{
    Task<CustomGapListResult>   ListAsync(CustomGapListQuery query, CancellationToken cancellationToken);
    Task<CustomGapCommandResult> OpenAsync(CustomGapOpenRequest request, CancellationToken cancellationToken);
    Task<CustomGapCommandResult> CloseAsync(CustomGapCloseRequest request, CancellationToken cancellationToken);
}

public sealed class CustomGapService(IConfiguration configuration, ILogger<CustomGapService> logger) : ICustomGapService
{
    public async Task<CustomGapListResult> ListAsync(CustomGapListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_custom_gap_list";

        AddParam(command, "@organization_id",   DbType.Int64,  (object?)query.OrganizationId ?? DBNull.Value);
        AddParam(command, "@status_code",       DbType.String, (object?)query.StatusCode ?? DBNull.Value, 30);
        AddParam(command, "@priority",          DbType.String, (object?)query.Priority   ?? DBNull.Value, 30);
        AddParam(command, "@owner_employee_id", DbType.Int64,  (object?)query.OwnerEmployeeId ?? DBNull.Value);
        AddParam(command, "@search",            DbType.String, (object?)query.Search ?? DBNull.Value, 200);
        AddParam(command, "@page",              DbType.Int32,  Math.Max(1, query.Page));
        AddParam(command, "@page_size",         DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        long total = 0;
        int  page  = query.Page;
        int  size  = query.PageSize;
        if (await reader.ReadAsync(cancellationToken))
        {
            total = Convert.ToInt64(reader["TotalCount"]);
            page  = Convert.ToInt32(reader["PageNumber"]);
            size  = Convert.ToInt32(reader["PageSize"]);
        }

        var rows = new List<CustomGapListRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(MapRow(reader));
        }

        return new CustomGapListResult(total, page, size, rows);
    }

    public async Task<CustomGapCommandResult> OpenAsync(CustomGapOpenRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)             return Fail("OrganizationId is required.");
        if (string.IsNullOrWhiteSpace(request.Title)) return Fail("Title is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_custom_gap_open";

            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@title",             DbType.String, request.Title, 250);
            AddParam(command, "@description",       DbType.String, (object?)request.Description ?? DBNull.Value, -1);
            AddParam(command, "@priority",          DbType.String, (object?)(request.Priority ?? "Medium"), 30);
            AddParam(command, "@owner_employee_id", DbType.Int64,  (object?)request.OwnerEmployeeId ?? DBNull.Value);
            AddParam(command, "@due_date",          DbType.Date,   (object?)request.DueDate ?? DBNull.Value);
            AddParam(command, "@status",            DbType.String, (object?)(request.Status ?? "Open"), 30);
            AddParam(command, "@remarks",           DbType.String, (object?)request.Remarks ?? DBNull.Value, 1000);
            AddParam(command, "@gap_type_code",     DbType.String, (object?)(request.GapTypeCode ?? "Custom"), 60);
            AddParam(command, "@actor_employee_id", DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);

            var idParam = command.CreateParameter();
            idParam.ParameterName = "@custom_gap_id";
            idParam.DbType        = DbType.Int64;
            idParam.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idParam);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idParam.Value is long l ? l : Convert.ToInt64(idParam.Value);
            return new CustomGapCommandResult(true, id);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "CustomGapService.OpenAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new CustomGapCommandResult(false, null, ex.Message);
        }
    }

    public async Task<CustomGapCommandResult> CloseAsync(CustomGapCloseRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.CustomGapId <= 0) return Fail("CustomGapId is required.");
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_custom_gap_close";

            AddParam(command, "@custom_gap_id",     DbType.Int64,  request.CustomGapId);
            AddParam(command, "@actor_employee_id", DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            AddParam(command, "@remarks",           DbType.String, (object?)request.Remarks ?? DBNull.Value, 1000);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new CustomGapCommandResult(true, request.CustomGapId);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "CustomGapService.CloseAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new CustomGapCommandResult(false, null, ex.Message);
        }
    }

    // -----------------------------------------------------------------
    // Helpers
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
        p.DbType = type;
        if (size.HasValue) p.Size = size.Value;
        p.Value = value ?? DBNull.Value;
        command.Parameters.Add(p);
    }

    private static CustomGapListRow MapRow(DbDataReader r) => new(
        CustomGapId:      Convert.ToInt64(r["custom_gap_id"]),
        OrganizationId:   Convert.ToInt64(r["organization_id"]),
        GapTypeCode:      r["gap_type_code"]?.ToString() ?? "Custom",
        Title:            r["title"]?.ToString() ?? "",
        Description:      r["description"] as string,
        Priority:         r["priority"]?.ToString() ?? "Medium",
        OwnerEmployeeId:  r["owner_employee_id"] as long?,
        DueDate:          r["due_date"] as DateTime?,
        Status:           r["status"]?.ToString() ?? "Open",
        Remarks:          r["remarks"] as string,
        LinkedTaskId:     r["linked_task_id"] as long?,
        EnteredDt:        Convert.ToDateTime(r["entered_dt"]),
        EnteredBy:        r["entered_by"]?.ToString() ?? "");

    private static CustomGapCommandResult Fail(string error) => new(false, null, error);
}
