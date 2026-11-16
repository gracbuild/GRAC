# api566.py -- 566 Api changes (Audit Engagements as a record). Run from the repo root.
import sys, os
API = 'src/PracticeManagement.Api'

def patch(path, pairs):
    p = os.path.join(API, path)
    raw = open(p, 'rb').read()
    crlf = b'\r\n' in raw
    s = raw.decode('utf-8').replace('\r\n', '\n')
    for old, new in pairs:
        n = s.count(old)
        if n != 1:
            sys.exit('%s: count %d for %r' % (path, n, old[:90]))
        s = s.replace(old, new)
    if crlf: s = s.replace('\n', '\r\n')
    open(p, 'wb').write(s.encode('utf-8'))
    print('patched', path)

# ------------------------------------------------------------------ models
ENG_MODELS = '''
// =====================================================================
// 566: Audit Engagements as a record of their own (spec 4.5). PLANNED
// (in a plan's programme, approved with the plan) or INDEPENDENT (no
// plan needed; initiation source, reason, approved by authority). Both
// run the same execution lifecycle. The audit team is kept against the
// engagement with its trail (removed members stay, with who / when).
// =====================================================================
public sealed record OrgAssuranceEngagementInitiationRow(string Code, string? Name);

/// <summary>One member picked for the team (MEMBER / SME / REVIEWER take
/// EmployeeId; EXTERNAL takes Name and Organisation). The lead is the
/// engagement's lead auditor.</summary>
public sealed record OrgAssuranceEngagementTeamPick(
    string  TeamRole,
    long?   EmployeeId   = null,
    string? Name         = null,
    string? Organisation = null);

public sealed record OrgAssuranceEngagementListQuery(
    long    OrganizationId,
    string? Status   = null,
    string? Origin   = null,
    long?   PlanId   = null,
    string? Search   = null,
    int     Page     = 1,
    int     PageSize = 25);

public sealed record OrgAssuranceEngagementRow(
    long      EngagementId,
    string?   EngagementCode,
    string?   EngagementName,
    string?   EngagementOrigin,
    long?     PlanId,
    string?   PlanCode,
    string?   PlanName,
    string?   PlanStatusCode,
    long?     ProgrammeId,
    string?   ProgrammeCode,
    string?   ProgrammeName,
    string?   AuditSubject,
    string?   EngagementObjective,
    string?   ScopeSummary,
    long?     AuditeeRoleId,
    string?   AuditeeRoleName,
    long?     AuditeeEmployeeId,
    string?   AuditeeName,
    long?     LeadAuditorRoleId,
    string?   LeadAuditorRoleName,
    long?     LeadAuditorEmployeeId,
    string?   LeadAuditorName,
    int       TeamCount,
    string?   TeamRemarks,
    string?   EngagementInstructions,
    string?   InitiationSourceCode,
    string?   InitiationSourceName,
    string?   InitiationReason,
    string?   ApprovalStatus,
    string?   ApprovalReference,
    string?   ApprovedBy,
    DateTime? ApprovedDt,
    DateTime? CancelledDt,
    string?   CancelledBy,
    string?   CancelReason,
    DateTime? PlannedStart,
    DateTime? PlannedEnd,
    DateTime? ActualStart,
    DateTime? ActualEnd,
    long?     BranchId,
    string?   BranchName,
    string?   DepartmentName,
    string?   Notes,
    int       DefinitionCount,
    string?   DefinitionCodes,
    int       ExecutionCount,
    int       ExecutionDoneCount,
    bool      CanStart,
    string?   EngagementStatus,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt);

public sealed record OrgAssuranceEngagementListResult(
    long TotalCount, int Page, int PageSize, IReadOnlyList<OrgAssuranceEngagementRow> Rows);

public sealed record OrgAssuranceEngagementAuditRow(
    long DefinitionId, string? DefinitionCode, string? DefinitionName, int DisplayOrder);

public sealed record OrgAssuranceEngagementTeamRow(
    long      TeamMemberId,
    string    TeamRole,
    long?     EmployeeId,
    string?   MemberName,
    string?   Designation,
    string?   RoleName,
    string?   ExternalOrganisation,
    bool      IsActive,
    string?   AddedBy,
    DateTime? AddedDt,
    string?   RemovedBy,
    DateTime? RemovedDt);

public sealed record OrgAssuranceEngagementDetail(
    OrgAssuranceEngagementRow                    Engagement,
    IReadOnlyList<OrgAssuranceEngagementAuditRow> Audits,
    IReadOnlyList<OrgAssuranceEngagementTeamRow>  Team);

public sealed record OrgAssuranceEngagementTeamSaveRequest(
    long OrganizationId,
    IReadOnlyList<OrgAssuranceEngagementTeamPick>? Team,
    string? TeamRemarks,
    string? Actor);

public sealed record OrgAssuranceEngagementCommandRequest(
    long    OrganizationId,
    string? Actor,
    string? ApprovalReference = null,   // approve
    string? Reason            = null);  // cancel
'''

patch('Models/OrgAssurancePlanModels.cs', [
    # the save request: plan optional (an independent engagement has none)
    ('''public sealed record OrgAssurancePlanItemSaveRequest(
    long      OrganizationId,
    long      PlanId,''',
     '''public sealed record OrgAssurancePlanItemSaveRequest(
    long      OrganizationId,
    long?     PlanId,          // 566: none for an independent engagement'''),
    ('''    // 565: the programme (mandatory; may be left out when the plan has one).
    long?                ProgrammeId    = null);''',
     '''    // 565: the programme (mandatory; may be left out when the plan has one).
    long?                ProgrammeId    = null,
    // 566: the engagement record -- origin (PLANNED / INDEPENDENT), subject,
    // objective, scope, auditee, instructions, the team (besides the lead),
    // and for an independent one its initiation source and reason.
    string?              EngagementOrigin       = null,
    string?              AuditSubject           = null,
    string?              EngagementObjective    = null,
    string?              ScopeSummary           = null,
    long?                AuditeeRoleId          = null,
    string?              AuditeeRoleName        = null,
    long?                AuditeeEmployeeId      = null,
    string?              AuditeeName            = null,
    string?              EngagementInstructions = null,
    string?              TeamRemarks            = null,
    IReadOnlyList<OrgAssuranceEngagementTeamPick>? Team = null,
    string?              InitiationSourceCode   = null,
    string?              InitiationReason       = null,
    string?              ApprovalReference      = null);'''),
    ('''    long?     ProgrammeId        = null,
    string?   ProgrammeCode      = null,
    string?   ProgrammeName      = null);

/// <summary>552: one audit of an engagement''',
     '''    long?     ProgrammeId        = null,
    string?   ProgrammeCode      = null,
    string?   ProgrammeName      = null,
    // 566: origin, subject, approval (independent) and cancelled.
    string?   EngagementOrigin   = null,
    string?   AuditSubject       = null,
    string?   ApprovalStatus     = null,
    DateTime? CancelledDt        = null);

/// <summary>552: one audit of an engagement'''),
    ('''public sealed record OrgAssuranceStartedExecutionRow(''',
     ENG_MODELS.lstrip('\n') + '\npublic sealed record OrgAssuranceStartedExecutionRow('),
])

patch('Models/OrgAssuranceExecutionModels.cs', [
    ('''    long      OrganizationId,
    string?   OrganizationName,
    long      PlanId,
    string?   PlanCode,''',
     '''    long      OrganizationId,
    string?   OrganizationName,
    long?     PlanId,          // 566: none for an independent engagement
    string?   PlanCode,'''),
])
patch('Services/OrgAssuranceExecutionService.cs', [
    ('''                Convert.ToInt64(r["PlanId"]),
                ReadStringOrNull(r,   "PlanCode"),''',
     '''                ReadLongOrNull(r,     "PlanId"),   // 566: independent engagements have none
                ReadStringOrNull(r,   "PlanCode"),'''),
])

# ------------------------------------------------------------------ service
SVC_METHODS = '''
    // -----------------------------------------------------------------
    // 566: Audit Engagements (planned and independent), their team,
    // approval (independent), cancellation and deletion.
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceEngagementInitiationRow>> ListInitiationSourcesAsync(
        CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_engagement_initiation_list";
        var rows = new List<OrgAssuranceEngagementInitiationRow>();
        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
            rows.Add(new OrgAssuranceEngagementInitiationRow(r["Code"].ToString()!, ReadStringOrNull(r, "Name")));
        return rows;
    }

    public async Task<OrgAssuranceEngagementListResult> ListEngagementsAsync(
        OrgAssuranceEngagementListQuery query, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_engagement_list";
        AddParam(command, "@organization_id", DbType.Int64,  query.OrganizationId);
        AddParam(command, "@status",          DbType.String, (object?)query.Status ?? DBNull.Value, 30);
        AddParam(command, "@origin",          DbType.String, (object?)query.Origin ?? DBNull.Value, 20);
        AddParam(command, "@plan_id",         DbType.Int64,  query.PlanId is > 0 ? (object)query.PlanId.Value : DBNull.Value);
        AddParam(command, "@search",          DbType.String, (object?)query.Search ?? DBNull.Value, 200);
        AddParam(command, "@page",            DbType.Int32,  query.Page);
        AddParam(command, "@page_size",       DbType.Int32,  query.PageSize);

        long total = 0; int page = query.Page, size = query.PageSize;
        var rows = new List<OrgAssuranceEngagementRow>();
        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        if (await r.ReadAsync(cancellationToken))
        {
            total = Convert.ToInt64(r["TotalCount"]);
            page  = Convert.ToInt32(r["PageNumber"]);
            size  = Convert.ToInt32(r["PageSize"]);
        }
        if (await r.NextResultAsync(cancellationToken))
            while (await r.ReadAsync(cancellationToken))
                rows.Add(MapEngagementRow(r));
        return new OrgAssuranceEngagementListResult(total, page, size, rows);
    }

    public async Task<OrgAssuranceEngagementDetail?> GetEngagementAsync(
        long organizationId, long engagementId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_engagement_get";
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@plan_item_id",    DbType.Int64, engagementId);

        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        if (!await r.ReadAsync(cancellationToken)) return null;
        var engagement = MapEngagementRow(r);
        var audits = new List<OrgAssuranceEngagementAuditRow>();
        if (await r.NextResultAsync(cancellationToken))
            while (await r.ReadAsync(cancellationToken))
                audits.Add(new OrgAssuranceEngagementAuditRow(
                    Convert.ToInt64(r["DefinitionId"]),
                    ReadStringOrNull(r, "DefinitionCode"),
                    ReadStringOrNull(r, "DefinitionName"),
                    Convert.ToInt32(r["DisplayOrder"])));
        var team = new List<OrgAssuranceEngagementTeamRow>();
        if (await r.NextResultAsync(cancellationToken))
            while (await r.ReadAsync(cancellationToken))
                team.Add(MapTeamRow(r));
        return new OrgAssuranceEngagementDetail(engagement, audits, team);
    }

    public async Task<IReadOnlyList<OrgAssuranceEngagementTeamRow>> ListEngagementTeamAsync(
        long organizationId, long engagementId, bool includeHistory, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_engagement_team_list";
        AddParam(command, "@organization_id", DbType.Int64,   organizationId);
        AddParam(command, "@plan_item_id",    DbType.Int64,   engagementId);
        AddParam(command, "@include_history", DbType.Boolean, includeHistory);
        var rows = new List<OrgAssuranceEngagementTeamRow>();
        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
            rows.Add(MapTeamRow(r));
        return rows;
    }

    public Task<OrgAssurancePlanCommandResult> SaveEngagementTeamAsync(
        long engagementId, OrgAssuranceEngagementTeamSaveRequest request, CancellationToken cancellationToken)
        => RunEngagementCommandAsync("sp_org_assurance_engagement_team_save", engagementId, request.OrganizationId,
            request.Actor, command =>
            {
                AddParam(command, "@team_json",    DbType.String, TeamJson(request.Team) ?? "[]", -1);
                AddParam(command, "@team_remarks", DbType.String, (object?)request.TeamRemarks ?? DBNull.Value, 2000);
            }, cancellationToken);

    public Task<OrgAssurancePlanCommandResult> ApproveEngagementAsync(
        long engagementId, OrgAssuranceEngagementCommandRequest request, CancellationToken cancellationToken)
        => RunEngagementCommandAsync("sp_org_assurance_engagement_approve", engagementId, request.OrganizationId,
            request.Actor, command =>
                AddParam(command, "@approval_reference", DbType.String, (object?)request.ApprovalReference ?? DBNull.Value, 200),
            cancellationToken);

    public Task<OrgAssurancePlanCommandResult> CancelEngagementAsync(
        long engagementId, OrgAssuranceEngagementCommandRequest request, CancellationToken cancellationToken)
        => RunEngagementCommandAsync("sp_org_assurance_engagement_cancel", engagementId, request.OrganizationId,
            request.Actor, command =>
                AddParam(command, "@reason", DbType.String, (object?)request.Reason ?? DBNull.Value, 2000),
            cancellationToken);

    public Task<OrgAssurancePlanCommandResult> DeleteEngagementAsync(
        long organizationId, long engagementId, string? actor, CancellationToken cancellationToken)
        => RunEngagementCommandAsync("sp_org_assurance_engagement_delete", engagementId, organizationId,
            actor, _ => { }, cancellationToken);

    private async Task<OrgAssurancePlanCommandResult> RunEngagementCommandAsync(
        string procedure, long engagementId, long organizationId, string? actor,
        Action<DbCommand> addParams, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice." + procedure;
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@plan_item_id",    DbType.Int64, engagementId);
            addParams(command);
            AddParam(command, "@actor", DbType.String, (object?)actor ?? (object)"system", 100);
            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssurancePlanCommandResult(true, engagementId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssurancePlanService.{Procedure} SQL error {Number}: {Message}",
                procedure, ex.Number, ex.Message);
            return new OrgAssurancePlanCommandResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // camelCase keys for the procedure's OPENJSON (teamRole, employeeId, name, organisation).
    private static string? TeamJson(IReadOnlyList<OrgAssuranceEngagementTeamPick>? team)
        => team is null ? null : System.Text.Json.JsonSerializer.Serialize(team.Select(t => new
        {
            teamRole     = t.TeamRole,
            employeeId   = t.EmployeeId,
            name         = t.Name,
            organisation = t.Organisation
        }));

    private static OrgAssuranceEngagementRow MapEngagementRow(DbDataReader r) => new(
        Convert.ToInt64(r["EngagementId"]),
        ReadStringOrNull(r, "EngagementCode"),
        ReadStringOrNull(r, "EngagementName"),
        ReadStringOrNull(r, "EngagementOrigin"),
        ReadLongOrNull(r,   "PlanId"),
        ReadStringOrNull(r, "PlanCode"),
        ReadStringOrNull(r, "PlanName"),
        ReadStringOrNull(r, "PlanStatusCode"),
        ReadLongOrNull(r,   "ProgrammeId"),
        ReadStringOrNull(r, "ProgrammeCode"),
        ReadStringOrNull(r, "ProgrammeName"),
        ReadStringOrNull(r, "AuditSubject"),
        ReadStringOrNull(r, "EngagementObjective"),
        ReadStringOrNull(r, "ScopeSummary"),
        ReadLongOrNull(r,   "AuditeeRoleId"),
        ReadStringOrNull(r, "AuditeeRoleName"),
        ReadLongOrNull(r,   "AuditeeEmployeeId"),
        ReadStringOrNull(r, "AuditeeName"),
        ReadLongOrNull(r,   "LeadAuditorRoleId"),
        ReadStringOrNull(r, "LeadAuditorRoleName"),
        ReadLongOrNull(r,   "LeadAuditorEmployeeId"),
        ReadStringOrNull(r, "LeadAuditorName"),
        ReadIntOrNull(r,    "TeamCount") ?? 0,
        ReadStringOrNull(r, "TeamRemarks"),
        ReadStringOrNull(r, "EngagementInstructions"),
        ReadStringOrNull(r, "InitiationSourceCode"),
        ReadStringOrNull(r, "InitiationSourceName"),
        ReadStringOrNull(r, "InitiationReason"),
        ReadStringOrNull(r, "ApprovalStatus"),
        ReadStringOrNull(r, "ApprovalReference"),
        ReadStringOrNull(r, "ApprovedBy"),
        ReadDateTimeOrNull(r, "ApprovedDt"),
        ReadDateTimeOrNull(r, "CancelledDt"),
        ReadStringOrNull(r, "CancelledBy"),
        ReadStringOrNull(r, "CancelReason"),
        ReadDateTimeOrNull(r, "PlannedStart"),
        ReadDateTimeOrNull(r, "PlannedEnd"),
        ReadDateTimeOrNull(r, "ActualStart"),
        ReadDateTimeOrNull(r, "ActualEnd"),
        ReadLongOrNull(r,   "BranchId"),
        ReadStringOrNull(r, "BranchName"),
        ReadStringOrNull(r, "DepartmentName"),
        ReadStringOrNull(r, "Notes"),
        ReadIntOrNull(r,    "DefinitionCount") ?? 0,
        ReadStringOrNull(r, "DefinitionCodes"),
        ReadIntOrNull(r,    "ExecutionCount") ?? 0,
        ReadIntOrNull(r,    "ExecutionDoneCount") ?? 0,
        r["CanStart"] != DBNull.Value && Convert.ToBoolean(r["CanStart"]),
        ReadStringOrNull(r, "EngagementStatus"),
        ReadStringOrNull(r, "EnteredBy"),
        ReadDateTimeOrNull(r, "EnteredDt"),
        ReadStringOrNull(r, "UpdatedBy"),
        ReadDateTimeOrNull(r, "UpdatedDt"));

    private static OrgAssuranceEngagementTeamRow MapTeamRow(DbDataReader r) => new(
        Convert.ToInt64(r["TeamMemberId"]),
        r["TeamRole"].ToString()!,
        ReadLongOrNull(r,   "EmployeeId"),
        ReadStringOrNull(r, "MemberName"),
        ReadStringOrNull(r, "Designation"),
        ReadStringOrNull(r, "RoleName"),
        ReadStringOrNull(r, "ExternalOrganisation"),
        r["IsActive"] != DBNull.Value && Convert.ToBoolean(r["IsActive"]),
        ReadStringOrNull(r, "AddedBy"),
        ReadDateTimeOrNull(r, "AddedDt"),
        ReadStringOrNull(r, "RemovedBy"),
        ReadDateTimeOrNull(r, "RemovedDt"));

    // -----------------------------------------------------------------
    // Helpers
'''

patch('Services/OrgAssurancePlanService.cs', [
    ('''    Task<IReadOnlyList<OrgAssurancePlanRevisionRow>> ListRevisionsAsync(
        long organizationId, long planId, CancellationToken cancellationToken);
}''',
     '''    Task<IReadOnlyList<OrgAssurancePlanRevisionRow>> ListRevisionsAsync(
        long organizationId, long planId, CancellationToken cancellationToken);

    // 566: Audit Engagements (planned and independent) and their team
    Task<IReadOnlyList<OrgAssuranceEngagementInitiationRow>> ListInitiationSourcesAsync(CancellationToken cancellationToken);
    Task<OrgAssuranceEngagementListResult> ListEngagementsAsync(
        OrgAssuranceEngagementListQuery query, CancellationToken cancellationToken);
    Task<OrgAssuranceEngagementDetail?> GetEngagementAsync(
        long organizationId, long engagementId, CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssuranceEngagementTeamRow>> ListEngagementTeamAsync(
        long organizationId, long engagementId, bool includeHistory, CancellationToken cancellationToken);
    Task<OrgAssurancePlanCommandResult> SaveEngagementTeamAsync(
        long engagementId, OrgAssuranceEngagementTeamSaveRequest request, CancellationToken cancellationToken);
    Task<OrgAssurancePlanCommandResult> ApproveEngagementAsync(
        long engagementId, OrgAssuranceEngagementCommandRequest request, CancellationToken cancellationToken);
    Task<OrgAssurancePlanCommandResult> CancelEngagementAsync(
        long engagementId, OrgAssuranceEngagementCommandRequest request, CancellationToken cancellationToken);
    Task<OrgAssurancePlanCommandResult> DeleteEngagementAsync(
        long organizationId, long engagementId, string? actor, CancellationToken cancellationToken);
}'''),
    ('''        if (request.PlanId <= 0)       return new OrgAssurancePlanItemSaveResult(false, Error: "PlanId is required.");''',
     '''        // 566: an independent engagement needs no plan; a planned one does.
        var independent = string.Equals(request.EngagementOrigin, "INDEPENDENT", StringComparison.OrdinalIgnoreCase)
                          || (request.EngagementOrigin is null && request.PlanItemId is null && request.PlanId is null or <= 0);
        if (!independent && request.PlanId is null or <= 0)
            return new OrgAssurancePlanItemSaveResult(false, Error: "PlanId is required.");'''),
    ('''            AddParam(command, "@plan_id",                        DbType.Int64,  request.PlanId);
            AddParam(command, "@plan_item_id",                   DbType.Int64,  (object?)request.PlanItemId ?? DBNull.Value);
            AddParam(command, "@org_assurance_definition_id",''',
     '''            AddParam(command, "@plan_id",                        DbType.Int64,  request.PlanId is > 0 ? (object)request.PlanId.Value : DBNull.Value);
            AddParam(command, "@plan_item_id",                   DbType.Int64,  (object?)request.PlanItemId ?? DBNull.Value);
            AddParam(command, "@org_assurance_definition_id",'''),
    ('''            if (request.ProgrammeId is > 0)   // 565: sent only when picked (the procedure falls back to the plan's only programme)
                AddParam(command, "@programme_id",               DbType.Int64,  request.ProgrammeId.Value);''',
     '''            if (request.ProgrammeId is > 0)   // 565: sent only when picked (the procedure falls back to the plan's only programme)
                AddParam(command, "@programme_id",               DbType.Int64,  request.ProgrammeId.Value);
            // 566: the engagement record and its team (null team = left as it is).
            AddParam(command, "@engagement_origin",              DbType.String, (object?)request.EngagementOrigin ?? DBNull.Value, 20);
            AddParam(command, "@audit_subject",                  DbType.String, (object?)request.AuditSubject ?? DBNull.Value, 400);
            AddParam(command, "@engagement_objective",           DbType.String, (object?)request.EngagementObjective ?? DBNull.Value, -1);
            AddParam(command, "@scope_summary",                  DbType.String, (object?)request.ScopeSummary ?? DBNull.Value, -1);
            AddParam(command, "@auditee_role_id",                DbType.Int64,  (object?)request.AuditeeRoleId ?? DBNull.Value);
            AddParam(command, "@auditee_role_name",              DbType.String, (object?)request.AuditeeRoleName ?? DBNull.Value, 120);
            AddParam(command, "@auditee_employee_id",            DbType.Int64,  (object?)request.AuditeeEmployeeId ?? DBNull.Value);
            AddParam(command, "@auditee_name",                   DbType.String, (object?)request.AuditeeName ?? DBNull.Value, 240);
            AddParam(command, "@engagement_instructions",        DbType.String, (object?)request.EngagementInstructions ?? DBNull.Value, -1);
            AddParam(command, "@team_remarks",                   DbType.String, (object?)request.TeamRemarks ?? DBNull.Value, 2000);
            AddParam(command, "@team_json",                      DbType.String, (object?)TeamJson(request.Team) ?? DBNull.Value, -1);
            AddParam(command, "@initiation_source_code",         DbType.String, (object?)request.InitiationSourceCode ?? DBNull.Value, 40);
            AddParam(command, "@initiation_reason",              DbType.String, (object?)request.InitiationReason ?? DBNull.Value, 2000);
            AddParam(command, "@approval_reference",             DbType.String, (object?)request.ApprovalReference ?? DBNull.Value, 200);'''),
    ('''            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@plan_id",         DbType.Int64,  planId);
            AddParam(command, "@plan_item_id",    DbType.Int64,  planItemId);
            AddParam(command, "@actor",           DbType.String, (object?)actor ?? (object)"system", 100);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@execution_id_out";''',
     '''            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@plan_id",         DbType.Int64,  planId > 0 ? (object)planId : DBNull.Value);   // 566: none for an independent engagement
            AddParam(command, "@plan_item_id",    DbType.Int64,  planItemId);
            AddParam(command, "@actor",           DbType.String, (object?)actor ?? (object)"system", 100);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@execution_id_out";'''),
    ('''        HasColumn(r, "ProgrammeName") ? ReadStringOrNull(r, "ProgrammeName") : null);

    // 551: a column''',
     '''        HasColumn(r, "ProgrammeName") ? ReadStringOrNull(r, "ProgrammeName") : null,
        // 566: tolerated as absent before 566 is run.
        HasColumn(r, "EngagementOrigin") ? ReadStringOrNull(r, "EngagementOrigin") : null,
        HasColumn(r, "AuditSubject")     ? ReadStringOrNull(r, "AuditSubject") : null,
        HasColumn(r, "ApprovalStatus")   ? ReadStringOrNull(r, "ApprovalStatus") : null,
        HasColumn(r, "CancelledDt")      ? ReadDateTimeOrNull(r, "CancelledDt") : null);

    // 551: a column'''),
    ('''        53949 => "REVISION_NOT_ALLOWED",      // 565
''',
     '''        53949 => "REVISION_NOT_ALLOWED",      // 565
        53950 => "AUDIT_SUBJECT_REQUIRED",    // 566
        53951 => "SCOPE_REQUIRED",            // 566
        53952 => "LEAD_AUDITOR_REQUIRED",     // 566
        53953 => "INITIATION_REQUIRED",       // 566
        53954 => "NOT_AN_AUDITOR",            // 566
        53955 => "LEAD_LOCKED",               // 566
        53956 => "APPROVAL_STATE",            // 566
        53957 => "ENGAGEMENT_CLOSED",         // 566
        53958 => "CANCEL_NOT_ALLOWED",        // 566
        53959 => "TEAM_INVALID",              // 566
'''),
])

# MapItemRow helpers section marker: put the new methods before the AddParam helper.
p = os.path.join(API, 'Services/OrgAssurancePlanService.cs')
s = open(p, encoding='utf-8').read()
anchor = '    private static void AddParam(DbCommand command, string name, DbType type, object? value, int? size = null)'
if s.count(anchor) != 1: sys.exit('AddParam anchor')
# find the comment block line just above AddParam (keep it), insert before it
i = s.index(anchor)
j = s.rfind('\n\n', 0, i) + 1
block = SVC_METHODS.rstrip('\n').rsplit('\n    // -----------------------------------------------------------------\n    // Helpers', 1)[0] + '\n\n'
s = s[:j] + block + s[j:]
open(p, 'w', encoding='utf-8', newline='').write(s)
print('service methods inserted')

# ------------------------------------------------------------------ controller
CTRL = '''
    // ================================================================
    // 566: Audit Engagements -- planned (in a plan's programme) and
    // independent (initiation source, reason, approved by authority).
    // ================================================================
    [HttpGet("engagement-initiation-sources")]
    public async Task<IActionResult> ListInitiationSources(CancellationToken cancellationToken)
    {
        try { return Ok(new { data = await service.ListInitiationSourcesAsync(cancellationToken) }); }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.ListInitiationSources failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("engagements")]
    public async Task<IActionResult> ListEngagements(
        [FromQuery] long?   organizationId,
        [FromQuery] string? status,
        [FromQuery] string? origin,
        [FromQuery] long?   planId,
        [FromQuery] string? search,
        [FromQuery] int     page     = 1,
        [FromQuery] int     pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        try
        {
            var result = await service.ListEngagementsAsync(
                new OrgAssuranceEngagementListQuery(organizationId.Value, status, origin, planId, search, page, pageSize),
                cancellationToken);
            return Ok(new { totalCount = result.TotalCount, page = result.Page, pageSize = result.PageSize, data = result.Rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.ListEngagements failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("engagements/{id:long}")]
    public async Task<IActionResult> GetEngagement(
        long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        try
        {
            var detail = await service.GetEngagementAsync(organizationId.Value, id, cancellationToken);
            return detail is null ? NotFound(new { error = "Engagement not found." }) : Ok(detail);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.GetEngagement failed for {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // The team with its trail (removed members, who / when) when includeHistory.
    [HttpGet("engagements/{id:long}/team")]
    public async Task<IActionResult> ListEngagementTeam(
        long id, [FromQuery] long? organizationId, [FromQuery] bool includeHistory, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        try
        {
            var rows = await service.ListEngagementTeamAsync(organizationId.Value, id, includeHistory, cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.ListEngagementTeam failed for {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("engagements/{id:long}/team")]
    public async Task<IActionResult> SaveEngagementTeam(
        long id, [FromBody] OrgAssuranceEngagementTeamSaveRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return CommandResult(await service.SaveEngagementTeamAsync(id, body, cancellationToken));
    }

    [HttpPost("engagements/{id:long}/approve")]
    public async Task<IActionResult> ApproveEngagement(
        long id, [FromBody] OrgAssuranceEngagementCommandRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return CommandResult(await service.ApproveEngagementAsync(id, body, cancellationToken));
    }

    [HttpPost("engagements/{id:long}/cancel")]
    public async Task<IActionResult> CancelEngagement(
        long id, [FromBody] OrgAssuranceEngagementCommandRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return CommandResult(await service.CancelEngagementAsync(id, body, cancellationToken));
    }

    [HttpDelete("engagements/{id:long}")]
    public async Task<IActionResult> DeleteEngagement(
        long id, [FromQuery] long? organizationId, [FromQuery] string? actor, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        return CommandResult(await service.DeleteEngagementAsync(organizationId.Value, id, actor, cancellationToken));
    }

    // Start Execution of any engagement (planned: the plan Approved / Active;
    // independent: approved -- its executions are MANUAL with the engagement).
    [HttpPost("engagements/{id:long}/start-execution")]
    public async Task<IActionResult> StartEngagementExecution(
        long id, [FromBody] OrgAssurancePlanCommandRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var result = await service.StartItemExecutionAsync(body.OrganizationId, body.PlanId, id, body.Actor, cancellationToken);
        return result.Success
            ? Ok(new
              {
                  executionId      = result.ExecutionId,
                  executionCode    = result.ExecutionCode,
                  executionName    = result.ExecutionName,
                  totalEntityCount = result.TotalEntityCount,
                  executions       = result.Executions
              })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    private IActionResult CommandResult(OrgAssurancePlanCommandResult result)
        => result.Success
            ? Ok(new { engagementId = result.PlanId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
}
'''
patch('Controllers/OrgAssurancePlanController.cs', [
    ('''//   546: items are saved / removed only while the plan is Draft or''',
     '''//   566 -- Audit Engagements as a record (planned or independent):
//   GET    /engagement-initiation-sources       { data: [{ code, name }] }
//   GET    /engagements?organizationId=&status=&origin=&planId=&search=&page=&pageSize=
//          { totalCount, page, pageSize, data: [engagement rows] }
//          status: Draft / Planned / InProgress / Completed / Cancelled
//   GET    /engagements/{id}?organizationId=    { engagement, audits, team }
//   GET    /engagements/{id}/team?organizationId=&includeHistory=
//   POST   /engagements/{id}/team               { organizationId, team: [{ teamRole,
//          employeeId?, name?, organisation? }], teamRemarks, actor }
//   POST   /engagements/{id}/approve            { organizationId, approvalReference, actor } (independent)
//   POST   /engagements/{id}/cancel             { organizationId, reason, actor } (no live execution)
//   DELETE /engagements/{id}?organizationId=&actor=   (independent Draft, no execution)
//   POST   /engagements/{id}/start-execution    { organizationId, planId?, actor }
//   POST   /plan-items   planId optional for engagementOrigin INDEPENDENT; +
//          auditSubject, engagementObjective, scopeSummary, auditee..., team[],
//          teamRemarks, engagementInstructions, initiationSourceCode,
//          initiationReason, approvalReference (lead = assignedAuditor...)
//   546: items are saved / removed only while the plan is Draft or'''),
    ('''            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }
}
''', '''            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }
''' + CTRL),
])
