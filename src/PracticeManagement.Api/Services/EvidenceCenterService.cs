// =====================================================================
// EvidenceCenterService  (migration 476, Phase 1)
//
// Facade over the Evidence Center procedures:
//   sp_evidence_center_list      ListAsync
//   sp_evidence_center_get       GetAsync      (item, versions, Used in)
//   sp_evidence_center_file_get  GetFileAsync  (one version, download)
//   sp_evidence_center_upload    UploadAsync   (new item / new version)
//   sp_evidence_center_save      SaveAsync     (metadata)
//   sp_evidence_center_status    SetStatusAsync (Retire / Restore / Delete)
//   sp_evidence_center_lookups   LookupsAsync
//   sp_evidence_expiry_sweep     RunExpirySweepAsync   (477, worker pass)
//   sp_evidence_expiry_notice_list / _mark  ListMyNoticesAsync /
//                                MarkMyNoticesAsync    (477, My Notifications)
//
// WHO SEES WHAT is decided in SQL (fn_pm_evidence_item_visible): admin,
// owner, uploader, or a user who can see an instance the item is linked
// to. That last test reads practice_instance under the View Data Scope
// policy (415), so every call that evaluates visibility runs on a
// connection that carries the caller as the reader: GETs get it from the
// request middleware (CallerViewScope.BeginForRequest); the upload (a POST
// that looks for an identical file the caller can see) sets it here.
//
// Errors: a THROW in 51000-52999 is a sentence for the user and is
// returned as is; anything else is logged and replaced by a generic one.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Infrastructure;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IEvidenceCenterService
{
    Task<EvidenceCenterListResult>     ListAsync(EvidenceCenterListQuery query, CancellationToken cancellationToken);
    Task<EvidenceCenterDetail?>        GetAsync(long organizationId, long evidenceItemId, long? callerEmployeeId, bool callerIsAdmin, CancellationToken cancellationToken);
    Task<EvidenceCenterFileContent?>   GetFileAsync(long organizationId, long evidenceFileId, long? callerEmployeeId, bool callerIsAdmin, CancellationToken cancellationToken);
    Task<EvidenceCenterUploadResult>   UploadAsync(EvidenceCenterUploadRequest request, CancellationToken cancellationToken);
    Task<EvidenceCenterCommandResult>  SaveAsync(long evidenceItemId, EvidenceCenterSaveRequest request, long? callerEmployeeId, bool callerIsAdmin, string actor, CancellationToken cancellationToken);
    Task<EvidenceCenterCommandResult>  SetStatusAsync(long evidenceItemId, EvidenceCenterStatusRequest request, long? callerEmployeeId, bool callerIsAdmin, string actor, CancellationToken cancellationToken);
    Task<EvidenceCenterLookups>        LookupsAsync(long organizationId, CancellationToken cancellationToken);
    // 477: expiry notifications.
    Task<EvidenceExpirySweepResult>    RunExpirySweepAsync(long? organizationId, int days, CancellationToken cancellationToken);
    Task<EvidenceNoticeListResult>     ListMyNoticesAsync(long recipientEmployeeId, long? organizationId, string? status, int pageNumber, int pageSize, CancellationToken cancellationToken);
    Task<int>                          MarkMyNoticesAsync(long recipientEmployeeId, long? organizationId, long? evidenceNoticeId, CancellationToken cancellationToken);
}

public sealed class EvidenceCenterService(
    IConfiguration configuration,
    ILogger<EvidenceCenterService> logger) : IEvidenceCenterService
{
    public async Task<EvidenceCenterListResult> ListAsync(EvidenceCenterListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);
        if (query.OrganizationId <= 0)
            return new EvidenceCenterListResult(false, [], 0, "Select an organization.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_evidence_center_list";
            AddParam(command, "@organization_id",    DbType.Int64,   query.OrganizationId);
            AddParam(command, "@caller_employee_id", DbType.Int64,   query.CallerEmployeeId is > 0 ? query.CallerEmployeeId : DBNull.Value);
            AddParam(command, "@caller_is_admin",    DbType.Boolean, query.CallerIsAdmin);
            AddParam(command, "@search",             DbType.String,  Text(query.Search), 200);
            AddParam(command, "@evidence_type_id",   DbType.Int32,   query.EvidenceTypeId is > 0 ? query.EvidenceTypeId : DBNull.Value);
            AddParam(command, "@owner_employee_id",  DbType.Int64,   query.OwnerEmployeeId is > 0 ? query.OwnerEmployeeId : DBNull.Value);
            AddParam(command, "@validity",           DbType.String,  Text(query.Validity), 20);
            AddParam(command, "@usage",              DbType.String,  Text(query.Usage), 20);
            AddParam(command, "@status",             DbType.String,  string.IsNullOrWhiteSpace(query.Status) ? "Active" : query.Status.Trim(), 20);
            AddParam(command, "@page_number",        DbType.Int32,   query.PageNumber);
            AddParam(command, "@page_size",          DbType.Int32,   query.PageSize);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            var rows  = await ReadRowsAsync(reader, cancellationToken);
            var total = rows.Count > 0 && rows[0].TryGetValue("TotalRows", out var t) && t is not null ? Convert.ToInt32(t) : 0;
            return new EvidenceCenterListResult(true, rows, total);
        }
        catch (Exception ex)
        {
            return new EvidenceCenterListResult(false, [], 0, UserMessage(ex, "The Evidence Center could not be loaded.", "sp_evidence_center_list"));
        }
    }

    public async Task<EvidenceCenterDetail?> GetAsync(
        long organizationId, long evidenceItemId, long? callerEmployeeId, bool callerIsAdmin, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_evidence_center_get";
        AddParam(command, "@organization_id",    DbType.Int64,   organizationId);
        AddParam(command, "@evidence_item_id",   DbType.Int64,   evidenceItemId);
        AddParam(command, "@caller_employee_id", DbType.Int64,   callerEmployeeId is > 0 ? callerEmployeeId : DBNull.Value);
        AddParam(command, "@caller_is_admin",    DbType.Boolean, callerIsAdmin);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var item = await ReadRowsAsync(reader, cancellationToken);
        if (item.Count == 0) return null;   // not found, or not visible to the caller
        var versions = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : [];
        var usedIn   = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : [];
        return new EvidenceCenterDetail(item[0], versions, usedIn);
    }

    public async Task<EvidenceCenterFileContent?> GetFileAsync(
        long organizationId, long evidenceFileId, long? callerEmployeeId, bool callerIsAdmin, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_evidence_center_file_get";
        AddParam(command, "@organization_id",    DbType.Int64,   organizationId);
        AddParam(command, "@evidence_file_id",   DbType.Int64,   evidenceFileId);
        AddParam(command, "@caller_employee_id", DbType.Int64,   callerEmployeeId is > 0 ? callerEmployeeId : DBNull.Value);
        AddParam(command, "@caller_is_admin",    DbType.Boolean, callerIsAdmin);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken)) return null;
        return new EvidenceCenterFileContent(
            EvidenceFileId: Convert.ToInt64(reader["EvidenceFileId"]),
            EvidenceItemId: Convert.ToInt64(reader["EvidenceItemId"]),
            VersionNo:      Convert.ToInt32(reader["VersionNo"]),
            FileName:       reader["FileName"]?.ToString() ?? "download",
            ContentType:    reader["ContentType"] as string,
            FileData:       (byte[])reader["FileData"]);
    }

    public async Task<EvidenceCenterUploadResult> UploadAsync(EvidenceCenterUploadRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)
            return UploadFailed("Select an organization.");
        if (request.FileData is null || request.FileData.Length == 0)
            return UploadFailed("The file is empty.");

        try
        {
            // A POST is not a read for the middleware; the identical-file
            // lookup still has to see only what this caller may see.
            CallerViewScope.BeginRead(request.CallerEmployeeId);

            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_evidence_center_upload";
            AddParam(command, "@organization_id",      DbType.Int64,   request.OrganizationId);
            AddParam(command, "@evidence_item_id",     DbType.Int64,   request.EvidenceItemId is > 0 ? request.EvidenceItemId : DBNull.Value);
            AddParam(command, "@file_name",            DbType.String,  request.FileName, 500);
            AddParam(command, "@content_type",         DbType.String,  Text(request.ContentType), 200);
            AddParam(command, "@file_data",            DbType.Binary,  request.FileData, -1);
            AddParam(command, "@version_note",         DbType.String,  Text(request.VersionNote), 1000);
            AddParam(command, "@evidence_title",       DbType.String,  Text(request.EvidenceTitle), 300);
            AddParam(command, "@evidence_type_id",     DbType.Int32,   request.EvidenceTypeId is > 0 ? request.EvidenceTypeId : DBNull.Value);
            AddParam(command, "@evidence_description", DbType.String,  Text(request.EvidenceDescription), 2000);
            AddParam(command, "@owner_employee_id",    DbType.Int64,   request.OwnerEmployeeId is > 0 ? request.OwnerEmployeeId : DBNull.Value);
            AddParam(command, "@valid_from",           DbType.Date,    request.ValidFrom?.Date);
            AddParam(command, "@valid_to",             DbType.Date,    request.ValidTo?.Date);
            AddParam(command, "@classification",       DbType.String,  Text(request.Classification), 30);
            AddParam(command, "@tags",                 DbType.String,  Text(request.Tags), 500);
            AddParam(command, "@allow_duplicate",      DbType.Boolean, request.AllowDuplicate);
            AddParam(command, "@caller_employee_id",   DbType.Int64,   request.CallerEmployeeId is > 0 ? request.CallerEmployeeId : DBNull.Value);
            AddParam(command, "@caller_is_admin",      DbType.Boolean, request.CallerIsAdmin);
            AddParam(command, "@actor",                DbType.String,  request.Actor, 100);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return UploadFailed("The file could not be stored.");

            return new EvidenceCenterUploadResult(
                Success:            true,
                Duplicate:          Convert.ToBoolean(reader["Duplicate"]),
                EvidenceItemId:     reader["EvidenceItemId"]     is DBNull ? null : Convert.ToInt64(reader["EvidenceItemId"]),
                EvidenceFileId:     reader["EvidenceFileId"]     is DBNull ? null : Convert.ToInt64(reader["EvidenceFileId"]),
                VersionNo:          reader["VersionNo"]          is DBNull ? null : Convert.ToInt32(reader["VersionNo"]),
                DuplicateItemId:    reader["DuplicateItemId"]    is DBNull ? null : Convert.ToInt64(reader["DuplicateItemId"]),
                DuplicateTitle:     reader["DuplicateTitle"] as string,
                DuplicateVersionNo: reader["DuplicateVersionNo"] is DBNull ? null : Convert.ToInt32(reader["DuplicateVersionNo"]));
        }
        catch (Exception ex)
        {
            return UploadFailed(UserMessage(ex, "The file could not be stored.", "sp_evidence_center_upload"));
        }
    }

    public async Task<EvidenceCenterCommandResult> SaveAsync(
        long evidenceItemId, EvidenceCenterSaveRequest request, long? callerEmployeeId, bool callerIsAdmin, string actor,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0 || evidenceItemId <= 0)
            return new EvidenceCenterCommandResult(false, null, "Organization and evidence item are both required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_evidence_center_save";
            AddParam(command, "@organization_id",      DbType.Int64,   request.OrganizationId);
            AddParam(command, "@evidence_item_id",     DbType.Int64,   evidenceItemId);
            AddParam(command, "@evidence_title",       DbType.String,  Text(request.EvidenceTitle), 300);
            AddParam(command, "@evidence_type_id",     DbType.Int32,   request.EvidenceTypeId is > 0 ? request.EvidenceTypeId : DBNull.Value);
            AddParam(command, "@evidence_description", DbType.String,  Text(request.EvidenceDescription), 2000);
            AddParam(command, "@owner_employee_id",    DbType.Int64,   request.OwnerEmployeeId is > 0 ? request.OwnerEmployeeId : DBNull.Value);
            AddParam(command, "@valid_from",           DbType.Date,    request.ValidFrom?.Date);
            AddParam(command, "@valid_to",             DbType.Date,    request.ValidTo?.Date);
            AddParam(command, "@classification",       DbType.String,  Text(request.Classification), 30);
            AddParam(command, "@tags",                 DbType.String,  Text(request.Tags), 500);
            AddParam(command, "@caller_employee_id",   DbType.Int64,   callerEmployeeId is > 0 ? callerEmployeeId : DBNull.Value);
            AddParam(command, "@caller_is_admin",      DbType.Boolean, callerIsAdmin);
            AddParam(command, "@actor",                DbType.String,  actor, 100);

            return await ReadCommandResultAsync(command, "Evidence item saved.", cancellationToken);
        }
        catch (Exception ex)
        {
            return new EvidenceCenterCommandResult(false, null, UserMessage(ex, "The evidence item could not be saved.", "sp_evidence_center_save"));
        }
    }

    public async Task<EvidenceCenterCommandResult> SetStatusAsync(
        long evidenceItemId, EvidenceCenterStatusRequest request, long? callerEmployeeId, bool callerIsAdmin, string actor,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0 || evidenceItemId <= 0)
            return new EvidenceCenterCommandResult(false, null, "Organization and evidence item are both required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_evidence_center_status";
            AddParam(command, "@organization_id",    DbType.Int64,   request.OrganizationId);
            AddParam(command, "@evidence_item_id",   DbType.Int64,   evidenceItemId);
            AddParam(command, "@action",             DbType.String,  Text(request.Action), 20);
            AddParam(command, "@caller_employee_id", DbType.Int64,   callerEmployeeId is > 0 ? callerEmployeeId : DBNull.Value);
            AddParam(command, "@caller_is_admin",    DbType.Boolean, callerIsAdmin);
            AddParam(command, "@actor",              DbType.String,  actor, 100);

            return await ReadCommandResultAsync(command, "Done.", cancellationToken);
        }
        catch (Exception ex)
        {
            return new EvidenceCenterCommandResult(false, null, UserMessage(ex, "The evidence item could not be changed.", "sp_evidence_center_status"));
        }
    }

    public async Task<EvidenceCenterLookups> LookupsAsync(long organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_evidence_center_lookups";
        AddParam(command, "@organization_id", DbType.Int64, organizationId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var types     = await ReadRowsAsync(reader, cancellationToken);
        var employees = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : [];
        return new EvidenceCenterLookups(types, employees);
    }

    // ==============================================================
    // 477: expiry notifications
    // ==============================================================
    public async Task<EvidenceExpirySweepResult> RunExpirySweepAsync(long? organizationId, int days, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_evidence_expiry_sweep";
        AddParam(command, "@organization_id", DbType.Int64, organizationId is > 0 ? organizationId : DBNull.Value);
        AddParam(command, "@days",            DbType.Int32, days);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await reader.ReadAsync(cancellationToken)
            ? new EvidenceExpirySweepResult(Convert.ToInt32(reader["ExpiringRaised"]), Convert.ToInt32(reader["ExpiredRaised"]))
            : new EvidenceExpirySweepResult(0, 0);
    }

    public async Task<EvidenceNoticeListResult> ListMyNoticesAsync(
        long recipientEmployeeId, long? organizationId, string? status, int pageNumber, int pageSize, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_evidence_expiry_notice_list";
            AddParam(command, "@recipient_employee_id", DbType.Int64,  recipientEmployeeId);
            AddParam(command, "@organization_id",       DbType.Int64,  organizationId is > 0 ? organizationId : DBNull.Value);
            AddParam(command, "@status",                DbType.String, Text(status), 10);
            AddParam(command, "@page_number",           DbType.Int32,  pageNumber);
            AddParam(command, "@page_size",             DbType.Int32,  pageSize);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            var rows   = await ReadRowsAsync(reader, cancellationToken);
            var total  = rows.Count > 0 && rows[0].TryGetValue("TotalRows", out var t) && t is not null ? Convert.ToInt32(t) : 0;
            var unread = rows.Count > 0 && rows[0].TryGetValue("UnreadCount", out var u) && u is not null ? Convert.ToInt32(u) : 0;
            // An empty page still needs the badge: ask for the unread count alone.
            if (rows.Count == 0 && !string.Equals(status, "Unread", StringComparison.OrdinalIgnoreCase))
                unread = (await ListMyNoticesAsync(recipientEmployeeId, organizationId, "Unread", 1, 1, cancellationToken)).UnreadCount;
            return new EvidenceNoticeListResult(true, rows, total, unread);
        }
        catch (SqlException ex) when (ex.Number == 2812)
        {
            // A database without 477: no notices, not a broken page.
            return new EvidenceNoticeListResult(true, [], 0, 0);
        }
        catch (Exception ex)
        {
            return new EvidenceNoticeListResult(false, [], 0, 0, UserMessage(ex, "The evidence notices could not be loaded.", "sp_evidence_expiry_notice_list"));
        }
    }

    public async Task<int> MarkMyNoticesAsync(
        long recipientEmployeeId, long? organizationId, long? evidenceNoticeId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_evidence_expiry_notice_mark";
        AddParam(command, "@recipient_employee_id", DbType.Int64, recipientEmployeeId);
        AddParam(command, "@evidence_notice_id",    DbType.Int64, evidenceNoticeId is > 0 ? evidenceNoticeId : DBNull.Value);
        AddParam(command, "@organization_id",       DbType.Int64, organizationId is > 0 ? organizationId : DBNull.Value);
        var marked = await command.ExecuteScalarAsync(cancellationToken);
        return marked is null or DBNull ? 0 : Convert.ToInt32(marked);
    }

    // ==============================================================
    // Helpers -- the sibling services' shape
    // ==============================================================
    private static EvidenceCenterUploadResult UploadFailed(string error) =>
        new(false, false, null, null, null, null, null, null, error);

    private string UserMessage(Exception ex, string fallback, string procedure)
    {
        if (ex is SqlException sql && sql.Number is >= 51000 and <= 52999)
            return sql.Message;
        logger.LogError(ex, "{Procedure} failed.", procedure);
        return fallback;
    }

    private static async Task<EvidenceCenterCommandResult> ReadCommandResultAsync(
        DbCommand command, string fallbackMessage, CancellationToken cancellationToken)
    {
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        string? message = null;
        if (await reader.ReadAsync(cancellationToken))
        {
            for (var i = 0; i < reader.FieldCount; i++)
                if (string.Equals(reader.GetName(i), "Message", StringComparison.OrdinalIgnoreCase))
                    message = reader.IsDBNull(i) ? null : reader.GetString(i);
        }
        return new EvidenceCenterCommandResult(true, message ?? fallbackMessage);
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
        var connString = SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connString))
            throw new InvalidOperationException("PracticeManagement connection string is not configured.");
        var connection = new SqlConnection(connString);
        await connection.OpenAsync(cancellationToken);
        await ViewScopeSession.ApplyAsync(connection, cancellationToken);   // 415: View Data Scope
        return connection;
    }

    private static object Text(string? value) =>
        string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();

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
