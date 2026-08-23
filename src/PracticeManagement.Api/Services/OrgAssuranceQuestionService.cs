// =====================================================================
// OrgAssuranceQuestionService
//
// Phase 2 Assurance Management -- Stage 2 Question Builder service.
//
// Thin wrapper over the sp_org_assurance_question_* stored procedures
// in migration 077. Follows the exact TaskService / OrgAssuranceDefinition-
// Service conventions:
//   * Primary-constructor injection
//   * Infrastructure.SqlConnectionStringResolver for the connection
//   * AddParam helper + snake_case @-parameters
//   * Structured *Result records
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IOrgAssuranceQuestionService
{
    Task<IReadOnlyList<OrgAssuranceAdminQuestionTypeRow>> ListAdminQuestionTypesAsync(CancellationToken cancellationToken);

    // Sets
    Task<OrgAssuranceQuestionSetListResult> ListSetsAsync(
        OrgAssuranceQuestionSetListQuery query, CancellationToken cancellationToken);
    Task<OrgAssuranceQuestionSetDetail?> GetSetAsync(
        long organizationId, long questionSetId, CancellationToken cancellationToken);
    Task<OrgAssuranceQuestionSetSaveResult> SaveSetAsync(
        OrgAssuranceQuestionSetSaveRequest request, CancellationToken cancellationToken);
    Task<OrgAssuranceCommandResult> DeleteSetAsync(
        long organizationId, long questionSetId, string? actor, CancellationToken cancellationToken);

    // Questions
    Task<IReadOnlyList<OrgAssuranceQuestionRow>> ListQuestionsAsync(
        long organizationId, long questionSetId, CancellationToken cancellationToken);
    Task<OrgAssuranceQuestionRow?> GetQuestionAsync(
        long organizationId, long questionId, CancellationToken cancellationToken);
    Task<OrgAssuranceQuestionSaveResult> SaveQuestionAsync(
        OrgAssuranceQuestionSaveRequest request, CancellationToken cancellationToken);
    Task<OrgAssuranceCommandResult> DeleteQuestionAsync(
        long organizationId, long questionId, string? actor, CancellationToken cancellationToken);
}

public sealed class OrgAssuranceQuestionService(
    IConfiguration configuration,
    ILogger<OrgAssuranceQuestionService> logger) : IOrgAssuranceQuestionService
{
    // -----------------------------------------------------------------
    // Admin question types
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceAdminQuestionTypeRow>> ListAdminQuestionTypesAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_admin_question_type_list";

        var rows = new List<OrgAssuranceAdminQuestionTypeRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceAdminQuestionTypeRow(
                ReadLongOrNull(reader,   "Id"),
                ReadStringOrNull(reader, "Code"),
                ReadStringOrNull(reader, "Name"),
                ReadStringOrNull(reader, "Description")));
        }
        return rows;
    }

    // -----------------------------------------------------------------
    // Question Sets
    // -----------------------------------------------------------------
    public async Task<OrgAssuranceQuestionSetListResult> ListSetsAsync(
        OrgAssuranceQuestionSetListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_question_set_list";

        AddParam(command, "@organization_id", DbType.Int64,  query.OrganizationId);
        AddParam(command, "@search",          DbType.String, (object?)query.Search ?? DBNull.Value, 200);
        AddParam(command, "@page",            DbType.Int32,  Math.Max(1, query.Page));
        AddParam(command, "@page_size",       DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));

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

        var rows = new List<OrgAssuranceQuestionSetListRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                rows.Add(new OrgAssuranceQuestionSetListRow(
                    Convert.ToInt64(reader["QuestionSetId"]),
                    Convert.ToInt64(reader["OrganizationId"]),
                    reader["SetCode"]?.ToString() ?? "",
                    reader["SetName"]?.ToString() ?? "",
                    ReadStringOrNull(reader, "Description"),
                    ReadLongOrNull(reader,   "OwnerEmployeeId"),
                    ReadStringOrNull(reader, "OwnerDisplayName"),
                    reader["Status"]?.ToString() ?? "Active",
                    Convert.ToInt64(reader["QuestionCount"]),
                    ReadDateTimeOrNull(reader, "EnteredDt"),
                    ReadDateTimeOrNull(reader, "UpdatedDt")));
            }
        }

        return new OrgAssuranceQuestionSetListResult(total, page, size, rows);
    }

    public async Task<OrgAssuranceQuestionSetDetail?> GetSetAsync(
        long organizationId, long questionSetId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_question_set_get";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@question_set_id", DbType.Int64, questionSetId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken)) return null;

        return new OrgAssuranceQuestionSetDetail(
            Convert.ToInt64(reader["QuestionSetId"]),
            Convert.ToInt64(reader["OrganizationId"]),
            reader["SetCode"]?.ToString() ?? "",
            reader["SetName"]?.ToString() ?? "",
            ReadStringOrNull(reader, "Description"),
            ReadLongOrNull(reader,   "OwnerEmployeeId"),
            ReadStringOrNull(reader, "OwnerDisplayName"),
            reader["Status"]?.ToString() ?? "Active",
            ReadStringOrNull(reader, "EnteredBy"),
            ReadDateTimeOrNull(reader, "EnteredDt"),
            ReadStringOrNull(reader, "UpdatedBy"),
            ReadDateTimeOrNull(reader, "UpdatedDt"));
    }

    public async Task<OrgAssuranceQuestionSetSaveResult> SaveSetAsync(
        OrgAssuranceQuestionSetSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.SetCode))
            return new OrgAssuranceQuestionSetSaveResult(false, Error: "SetCode is required.");
        if (string.IsNullOrWhiteSpace(request.SetName))
            return new OrgAssuranceQuestionSetSaveResult(false, Error: "SetName is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_question_set_save";

            AddParam(command, "@organization_id",    DbType.Int64,  request.OrganizationId);
            AddParam(command, "@question_set_id",    DbType.Int64,  (object?)request.QuestionSetId ?? DBNull.Value);
            AddParam(command, "@set_code",           DbType.String, request.SetCode.Trim(), 80);
            AddParam(command, "@set_name",           DbType.String, request.SetName.Trim(), 240);
            AddParam(command, "@description",        DbType.String, (object?)request.Description ?? DBNull.Value, -1);
            AddParam(command, "@owner_employee_id",  DbType.Int64,  (object?)request.OwnerEmployeeId ?? DBNull.Value);
            AddParam(command, "@owner_display_name", DbType.String, (object?)request.OwnerDisplayName ?? DBNull.Value, 240);
            AddParam(command, "@status",             DbType.String, (object?)request.Status ?? (object)"Active", 30);
            AddParam(command, "@actor",              DbType.String, (object?)request.Actor  ?? (object)"system", 100);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@question_set_id_out";
            idOut.DbType        = DbType.Int64;
            idOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idOut);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idOut.Value is long l ? l : Convert.ToInt64(idOut.Value);
            return new OrgAssuranceQuestionSetSaveResult(true, id);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex,
                "OrgAssuranceQuestionService.SaveSetAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceQuestionSetSaveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    public async Task<OrgAssuranceCommandResult> DeleteSetAsync(
        long organizationId, long questionSetId, string? actor, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_question_set_delete";

            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@question_set_id", DbType.Int64,  questionSetId);
            AddParam(command, "@actor",           DbType.String, (object?)actor ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssuranceCommandResult(true, questionSetId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssuranceQuestionService.DeleteSetAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceCommandResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // -----------------------------------------------------------------
    // Questions
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceQuestionRow>> ListQuestionsAsync(
        long organizationId, long questionSetId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_question_list";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@question_set_id", DbType.Int64, questionSetId);

        var rows = new List<OrgAssuranceQuestionRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(MapQuestionRow(reader));
        return rows;
    }

    public async Task<OrgAssuranceQuestionRow?> GetQuestionAsync(
        long organizationId, long questionId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_question_get";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@question_id",     DbType.Int64, questionId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await reader.ReadAsync(cancellationToken) ? MapQuestionRow(reader) : null;
    }

    public async Task<OrgAssuranceQuestionSaveResult> SaveQuestionAsync(
        OrgAssuranceQuestionSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.QuestionCode))
            return new OrgAssuranceQuestionSaveResult(false, Error: "QuestionCode is required.");
        if (string.IsNullOrWhiteSpace(request.QuestionText))
            return new OrgAssuranceQuestionSaveResult(false, Error: "QuestionText is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_question_save";

            AddParam(command, "@organization_id",     DbType.Int64,   request.OrganizationId);
            AddParam(command, "@question_set_id",     DbType.Int64,   request.QuestionSetId);
            AddParam(command, "@question_id",         DbType.Int64,   (object?)request.QuestionId ?? DBNull.Value);
            AddParam(command, "@question_code",       DbType.String,  request.QuestionCode.Trim(), 80);
            AddParam(command, "@question_text",       DbType.String,  request.QuestionText.Trim(), -1);
            AddParam(command, "@help_text",           DbType.String,  (object?)request.HelpText ?? DBNull.Value, -1);
            AddParam(command, "@question_type_id",    DbType.Int64,   (object?)request.QuestionTypeId ?? DBNull.Value);
            AddParam(command, "@question_type_code",  DbType.String,  (object?)request.QuestionTypeCode ?? DBNull.Value, 120);
            AddParam(command, "@question_type_name",  DbType.String,  (object?)request.QuestionTypeName ?? DBNull.Value, 200);
            AddParam(command, "@is_mandatory",        DbType.Boolean, request.IsMandatory ?? false);
            AddParam(command, "@display_order",       DbType.Int32,   request.DisplayOrder ?? 0);
            AddParam(command, "@weight",              DbType.Decimal, (object?)request.Weight ?? DBNull.Value);
            AddParam(command, "@expected_response",   DbType.String,  (object?)request.ExpectedResponse ?? DBNull.Value, -1);
            AddParam(command, "@actor",               DbType.String,  (object?)request.Actor ?? (object)"system", 100);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@question_id_out";
            idOut.DbType        = DbType.Int64;
            idOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idOut);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idOut.Value is long l ? l : Convert.ToInt64(idOut.Value);
            return new OrgAssuranceQuestionSaveResult(true, id);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex,
                "OrgAssuranceQuestionService.SaveQuestionAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceQuestionSaveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    public async Task<OrgAssuranceCommandResult> DeleteQuestionAsync(
        long organizationId, long questionId, string? actor, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_question_delete";

            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@question_id",     DbType.Int64,  questionId);
            AddParam(command, "@actor",           DbType.String, (object?)actor ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssuranceCommandResult(true, questionId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssuranceQuestionService.DeleteQuestionAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceCommandResult(false, Error: ex.Message, ReasonCode: reason);
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
        p.DbType        = type;
        if (size.HasValue) p.Size = size.Value;
        p.Value = value ?? DBNull.Value;
        command.Parameters.Add(p);
    }

    private static long?    ReadLongOrNull(System.Data.Common.DbDataReader r, string col)     => r[col] == DBNull.Value ? null : Convert.ToInt64(r[col]);
    private static int?     ReadIntOrNull(System.Data.Common.DbDataReader r, string col)      => r[col] == DBNull.Value ? null : Convert.ToInt32(r[col]);
    private static decimal? ReadDecimalOrNull(System.Data.Common.DbDataReader r, string col)  => r[col] == DBNull.Value ? null : Convert.ToDecimal(r[col]);
    private static DateTime? ReadDateTimeOrNull(System.Data.Common.DbDataReader r, string col)=> r[col] == DBNull.Value ? null : Convert.ToDateTime(r[col]);
    private static string?  ReadStringOrNull(System.Data.Common.DbDataReader r, string col)   => r[col] == DBNull.Value ? null : r[col].ToString();

    private static OrgAssuranceQuestionRow MapQuestionRow(System.Data.Common.DbDataReader r) => new(
        Convert.ToInt64(r["QuestionId"]),
        Convert.ToInt64(r["QuestionSetId"]),
        r["QuestionCode"]?.ToString() ?? "",
        r["QuestionText"]?.ToString() ?? "",
        ReadStringOrNull(r, "HelpText"),
        ReadLongOrNull(r,   "QuestionTypeId"),
        ReadStringOrNull(r, "QuestionTypeCode"),
        ReadStringOrNull(r, "QuestionTypeName"),
        Convert.ToBoolean(r["IsMandatory"]),
        Convert.ToInt32(r["DisplayOrder"]),
        ReadDecimalOrNull(r, "Weight"),
        ReadStringOrNull(r, "ExpectedResponse"),
        ReadStringOrNull(r, "EnteredBy"),
        ReadDateTimeOrNull(r, "EnteredDt"),
        ReadStringOrNull(r, "UpdatedBy"),
        ReadDateTimeOrNull(r, "UpdatedDt"));

    // Reason mapping for SP THROW numbers (077).
    private static string MapReason(int errorNumber) => errorNumber switch
    {
        53801 => "ORGANIZATION_ID_REQUIRED",
        53802 => "IDS_REQUIRED",
        53803 => "CODE_REQUIRED",
        53804 => "NAME_REQUIRED",
        53805 => "DUPLICATE_SET_CODE",
        53806 => "SET_NOT_FOUND",
        53807 => "WRONG_ORGANIZATION",
        53808 => "QUESTION_CODE_REQUIRED",
        53809 => "QUESTION_TEXT_REQUIRED",
        53810 => "DUPLICATE_QUESTION_CODE",
        53811 => "QUESTION_NOT_FOUND",
        53812 => "SET_MISMATCH",
        _     => "SQL_ERROR"
    };
}
