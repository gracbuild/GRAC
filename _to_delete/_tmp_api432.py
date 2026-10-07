# Applies the 432 API / Web proxy changes in place. Run from src/ on the device.
def edit(path, pairs):
    s=open(path,encoding='utf-8').read()
    for a,b in pairs:
        assert s.count(a)==1,(path,a[:80],s.count(a))
        s=s.replace(a,b)
    return s
A='PracticeManagement.Api/'
files={}
files[A+'Models/AssetConfigModels.cs']=edit(A+'Models/AssetConfigModels.cs',[(
"""/// <summary>Outcome of a write: Success, the new/affected id, and on
/// failure the SQL error number + message so the controller can pick the""",
"""// ---------------------------------------------------------------------
// Asset verification exceptions (migration 432)
// ---------------------------------------------------------------------
/// <summary>Investigation action: START_REVIEW | AWAIT_EVIDENCE (Note) |
/// RESUME | RESOLVE (Outcome, Narrative, ClosureEvidence, Sec* = DONE | NA for
/// a lost asset) | APPROVE | REJECT (Note) | CLOSE | REASSIGN (Investigator =
/// E:id | T:id, Note) | CANCEL (Note).</summary>
public sealed record AssetVerificationActionRequest(
    long    OrganizationId,
    string? Action,
    string? Note,
    string? Outcome,
    string? Narrative,
    string? ClosureEvidence,
    string? SecRemoteLockWipe,
    string? SecCredentialReview,
    string? SecPrivacyAssessment,
    string? SecAccessRevocation,
    string? SecMonitoring,
    string? Investigator,
    long?   ExpectedRecordVersion);

/// <summary>Per-organization exception settings (asset administrator,
/// fallback team, escalation levels in overdue days).</summary>
public sealed record AssetVerificationSettingsSaveRequest(
    long  OrganizationId,
    long? AssetAdministratorEmployeeId,
    long? FallbackTeamId,
    int   EscalationLevel1Days,
    int   EscalationLevel2Days,
    int   EscalationLevel3Days,
    long? ExpectedRecordVersion);

/// <summary>Organization override of one disagreement category's
/// assignment / SLA rule; Reset = true returns to the BRD 5.3.8 default.</summary>
public sealed record AssetVerificationRuleSaveRequest(
    long    OrganizationId,
    string? Category,
    string? PrimaryAssignment,
    string? SupportingAssignment,
    int?    StartSlaDays,
    bool?   StartImmediate,
    int?    ResolutionSlaDays,
    bool?   ClosureApprovalRequired,
    bool?   ClosureEvidenceRequired,
    bool?   Reset);

/// <summary>Outcome of a write: Success, the new/affected id, and on
/// failure the SQL error number + message so the controller can pick the""")])

files[A+'Services/AssetConfigService.cs']=edit(A+'Services/AssetConfigService.cs',[
("""//   sp_asset_attestation_* / sp_asset_custody_get (431 -- custody and attestation)""",
"""//   sp_asset_attestation_* / sp_asset_custody_get (431 -- custody and attestation)
//   sp_asset_verification_* (432 -- verification exceptions)"""),
("""    Task<AssetLifecycleResult> DecideAttestationAsync(long attestationId, AssetLifecycleDecisionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);""",
"""    Task<AssetLifecycleResult> DecideAttestationAsync(long attestationId, AssetLifecycleDecisionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);

    // 432 -- Verification exceptions
    Task<object> ListVerificationExceptionsAsync(long organizationId, string? scope, string? status, string? search, long? actorEmployeeId, int pageNumber, int pageSize, CancellationToken ct);
    Task<object?> GetVerificationExceptionAsync(long organizationId, long exceptionId, long? actorEmployeeId, CancellationToken ct);
    Task<AssetLifecycleResult> VerificationExceptionActionAsync(long exceptionId, AssetVerificationActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<object> GetVerificationSettingsAsync(long organizationId, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveVerificationSettingsAsync(AssetVerificationSettingsSaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveVerificationRuleAsync(AssetVerificationRuleSaveRequest request, string actor, CancellationToken ct);"""),
("""            var attestations = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { state = state.Count > 0 ? state[0] : null, assignments, attestations };""",
"""            var attestations = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var exceptions   = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;   // 432
            return new { state = state.Count > 0 ? state[0] : null, assignments, attestations, exceptions };"""),
("""    /// <summary>The lifecycle (429) and technology (430) write procedures""",
"""    // ----------------------------------------------------------------
    // 432 -- Verification exceptions
    // ----------------------------------------------------------------
    public async Task<object> ListVerificationExceptionsAsync(long organizationId, string? scope, string? status, string? search,
        long? actorEmployeeId, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_verification_exception_list");
        AddParam(command, "@organization_id",   DbType.Int64,  organizationId);
        AddParam(command, "@scope",             DbType.String, Blank(scope) ?? "ALL", 20);
        AddParam(command, "@status_code",       DbType.String, Blank(status), 60);
        AddParam(command, "@search",            DbType.String, Blank(search), 200);
        AddParam(command, "@actor_employee_id", DbType.Int64,  actorEmployeeId);
        AddParam(command, "@page_number",       DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",         DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object?> GetVerificationExceptionAsync(long organizationId, long exceptionId, long? actorEmployeeId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_verification_exception_get");
            AddParam(command, "@organization_id",   DbType.Int64, organizationId);
            AddParam(command, "@exception_id",      DbType.Int64, exceptionId);
            AddParam(command, "@actor_employee_id", DbType.Int64, actorEmployeeId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var header = await ReadRowsAsync(reader, ct);
            if (header.Count == 0) return null;
            var history = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
            return new { exception = header[0], history };
        }
        catch (SqlException ex) when (ex.Number == 54411) { return null; }
    }

    public Task<AssetLifecycleResult> VerificationExceptionActionAsync(long exceptionId, AssetVerificationActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_verification_exception_action", "exceptionId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@exception_id",            DbType.Int64,  exceptionId);
            AddParam(command, "@action",                  DbType.String, request.Action, 20);
            AddParam(command, "@note",                    DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@outcome",                 DbType.String, Blank(request.Outcome), 30);
            AddParam(command, "@narrative",               DbType.String, Blank(request.Narrative), 2000);
            AddParam(command, "@closure_evidence",        DbType.String, Blank(request.ClosureEvidence), 1000);
            AddParam(command, "@sec_remote_lock_wipe",    DbType.String, Blank(request.SecRemoteLockWipe), 4);
            AddParam(command, "@sec_credential_review",   DbType.String, Blank(request.SecCredentialReview), 4);
            AddParam(command, "@sec_privacy_assessment",  DbType.String, Blank(request.SecPrivacyAssessment), 4);
            AddParam(command, "@sec_access_revocation",   DbType.String, Blank(request.SecAccessRevocation), 4);
            AddParam(command, "@sec_monitoring",          DbType.String, Blank(request.SecMonitoring), 4);
            AddParam(command, "@investigator",            DbType.String, Blank(request.Investigator), 40);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public async Task<object> GetVerificationSettingsAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_verification_settings_get");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var settings = await ReadRowsAsync(reader, ct);
        var empty = new List<Dictionary<string, object?>>();
        var rules     = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var employees = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var teams     = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        return new { settings = settings.Count > 0 ? settings[0] : null, rules, employees, teams };
    }

    public Task<AssetConfigWriteResult> SaveVerificationSettingsAsync(AssetVerificationSettingsSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_verification_settings_save", command =>
        {
            AddParam(command, "@organization_id",                 DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_administrator_employee_id", DbType.Int64,  request.AssetAdministratorEmployeeId);
            AddParam(command, "@fallback_team_id",                DbType.Int64,  request.FallbackTeamId);
            AddParam(command, "@escalation_level1_days",          DbType.Int32,  request.EscalationLevel1Days);
            AddParam(command, "@escalation_level2_days",          DbType.Int32,  request.EscalationLevel2Days);
            AddParam(command, "@escalation_level3_days",          DbType.Int32,  request.EscalationLevel3Days);
            AddParam(command, "@expected_record_version",         DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor",                           DbType.String, actor, 100);
            return null;
        }, ct, request.OrganizationId);

    public Task<AssetConfigWriteResult> SaveVerificationRuleAsync(AssetVerificationRuleSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_verification_rule_save", command =>
        {
            AddParam(command, "@organization_id",           DbType.Int64,   request.OrganizationId);
            AddParam(command, "@category",                  DbType.String,  request.Category, 40);
            AddParam(command, "@primary_assignment",        DbType.String,  Blank(request.PrimaryAssignment), 30);
            AddParam(command, "@supporting_assignment",     DbType.String,  Blank(request.SupportingAssignment), 200);
            AddParam(command, "@start_sla_days",            DbType.Int32,   request.StartSlaDays);
            AddParam(command, "@start_immediate",           DbType.Boolean, request.StartImmediate ?? false);
            AddParam(command, "@resolution_sla_days",       DbType.Int32,   request.ResolutionSlaDays);
            AddParam(command, "@closure_approval_required", DbType.Boolean, request.ClosureApprovalRequired ?? false);
            AddParam(command, "@closure_evidence_required", DbType.Boolean, request.ClosureEvidenceRequired ?? false);
            AddParam(command, "@reset",                     DbType.Boolean, request.Reset ?? false);
            AddParam(command, "@actor",                     DbType.String,  actor, 100);
            return null;
        }, ct, request.OrganizationId);

    /// <summary>The lifecycle (429) and technology (430) write procedures"""),
])

files[A+'Controllers/AssetConfigController.cs']=edit(A+'Controllers/AssetConfigController.cs',[
("""//   POST attestation/{id}/decide                APPROVE | RETURN (manager) | CANCEL
""","""//   POST attestation/{id}/decide                APPROVE | RETURN (manager) | CANCEL
//   GET  attestation/exceptions?organizationId=&scope=ALL|MINE&status=&search=&pageNumber=&pageSize=   (432)
//   GET  attestation/exceptions/{id}?organizationId=  exception + status history
//   POST attestation/exceptions/{id}/action      START_REVIEW | AWAIT_EVIDENCE | RESUME | RESOLVE | APPROVE | REJECT | CLOSE | REASSIGN | CANCEL
//   GET  attestation/exception-settings?organizationId=  settings + effective rules + pickers
//   POST attestation/exception-settings | attestation/exception-rules
"""),
("""            54350 or 54352 => NotFound(body),                  // 431: organization / attestation profile""",
"""            54350 or 54352 => NotFound(body),                  // 431: organization / attestation profile
            54410 => NotFound(body),                           // 432: organization"""),
("""            54205 or 54253 or 54284 or 54805 or 54855 or 54915 or 54353 or 53520 => Conflict(body),""",
"""            54205 or 54253 or 54284 or 54805 or 54855 or 54915 or 54353 or 54426 or 53520 => Conflict(body),"""),
("""    // 431: 54357 -> 404; 54358 (stale) -> 409.""",
"""    // ---------------------------------------------------------------- 432: verification exceptions
    [HttpGet("attestation/exceptions")]
    public Task<IActionResult> VerificationExceptions([FromQuery] long? organizationId, [FromQuery] string? scope, [FromQuery] string? status,
        [FromQuery] string? search, [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListVerificationExceptionsAsync(organizationId.Value, scope, status, search, ActorEmployeeId,
            pageNumber ?? 1, pageSize ?? 25, ct), "verification exceptions");
    }

    [HttpGet("attestation/exceptions/{id:long}")]
    public Task<IActionResult> VerificationException(long id, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetVerificationExceptionAsync(o, id, ActorEmployeeId, ct), "Verification exception not found.", "verification exception");

    [HttpPost("attestation/exceptions/{id:long}/action")]
    public async Task<IActionResult> VerificationExceptionAction(long id, [FromBody] AssetVerificationActionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Action)) return BadRequest(new { error = "action is required." });
        return ResultWritten(await service.VerificationExceptionActionAsync(id, request, ActorEmployeeId, Actor, ct), ExceptionNotFound, ExceptionConflict);
    }

    [HttpGet("attestation/exception-settings")]
    public Task<IActionResult> VerificationSettings([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetVerificationSettingsAsync(organizationId.Value, ct), "verification settings");
    }

    [HttpPost("attestation/exception-settings")]
    public async Task<IActionResult> SaveVerificationSettings([FromBody] AssetVerificationSettingsSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Written(await service.SaveVerificationSettingsAsync(request, Actor, ct));
    }

    [HttpPost("attestation/exception-rules")]
    public async Task<IActionResult> SaveVerificationRule([FromBody] AssetVerificationRuleSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Category)) return BadRequest(new { error = "category is required." });
        return Written(await service.SaveVerificationRuleAsync(request, Actor, ct));
    }

    // 432: 54410 / 54411 -> 404; 54412 (stale) -> 409.
    private static readonly int[] ExceptionNotFound = { 54410, 54411 };
    private static readonly int[] ExceptionConflict = { 54412 };

    // 431: 54357 -> 404; 54358 (stale) -> 409."""),
])

W='PracticeManagement.Web/Controllers/AssetConfigController.cs'
files[W]=edit(W,[
("""//                                      only the manager); register/{id}/custody: register VIEW
""","""//                                      only the manager); register/{id}/custody: register VIEW;
//                                      attestation/exceptions/{id}/action (432) APPROVE / REJECT /
//                                      REASSIGN / CANCEL -> APPROVE, the investigator actions ->
//                                      VIEW (the procedure allows only the investigator);
//                                      attestation/exception-settings | exception-rules -> EDIT
"""),
("""        string? decision = null;                                // 429: lifecycle change decision
""","""        string? decision = null;                                // 429: lifecycle change decision
        string? exceptionAction = null;                         // 432: verification exception action
"""),
("""            if (doc.RootElement.TryGetProperty("decision", out var dc) && dc.ValueKind == JsonValueKind.String)
                decision = dc.GetString()?.Trim().ToUpperInvariant();
""","""            if (doc.RootElement.TryGetProperty("decision", out var dc) && dc.ValueKind == JsonValueKind.String)
                decision = dc.GetString()?.Trim().ToUpperInvariant();
            if (doc.RootElement.TryGetProperty("action", out var ac) && ac.ValueKind == JsonValueKind.String)
                exceptionAction = ac.GetString()?.Trim().ToUpperInvariant();
"""),
("""            : isAttestation && lower.EndsWith("/decide")         // manager identity enforced in SQL; cancel needs APPROVE""",
"""            : isAttestation && lower.StartsWith("attestation/exceptions/") && lower.EndsWith("/action")   // 432
            ? (exceptionAction is "APPROVE" or "REJECT" or "REASSIGN" or "CANCEL" ? Can(area, "APPROVE") : Can(area, "VIEW"))
            : isAttestation && (lower == "attestation/exception-settings" || lower == "attestation/exception-rules")
            ? Can(area, "EDIT")
            : isAttestation && lower.EndsWith("/decide")         // manager identity enforced in SQL; cancel needs APPROVE"""),
])
for p,s in files.items():
    open(p,'w',encoding='utf-8',newline='').write(s)
print('ok')
