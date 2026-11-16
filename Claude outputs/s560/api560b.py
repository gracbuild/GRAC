import sys, os
ROOT = sys.argv[1]

def patch(rel, pairs):
    p = os.path.join(ROOT, rel)
    raw = open(p, 'rb').read()
    crlf = b'\r\n' in raw
    bom = raw.startswith(b'\xef\xbb\xbf')
    s = raw.decode('utf-8-sig').replace('\r\n', '\n')
    for old, new in pairs:
        n = s.count(old)
        assert n == 1, (rel, old[:80], n)
        s = s.replace(old, new)
    if crlf: s = s.replace('\n', '\r\n')
    open(p, 'wb').write((b'\xef\xbb\xbf' if bom else b'') + s.encode('utf-8'))
    print('patched', rel)

M = 'src/PracticeManagement.Api/Models/OrgAssuranceDefinitionModels.cs'
patch(M, [
("""/// <summary>560: Assurance Approach dropdown row (how the audit is conducted),
/// from grac_practice.org_assurance_approach_master via sp_org_assurance_approach_list.</summary>
public sealed record OrgAssuranceApproachRow(""",
"""/// <summary>560: a row of an Audit Definition master dropdown -- Assurance Approach
/// (org_assurance_approach_master, how the audit is conducted) and Audit Mandate
/// (org_assurance_mandate_master, the basis of the audit).</summary>
public sealed record OrgAssuranceMasterRow("""),
("""    // 560: Assurance Approach (id + code / name as saved) and Audit Mandate.
    long?     AssuranceApproachId,
    string?   AssuranceApproachCode,
    string?   AssuranceApproachName,
    string?   AuditMandate,""",
"""    // 560: Assurance Approach and Audit Mandate (id + code / name as saved).
    long?     AssuranceApproachId,
    string?   AssuranceApproachCode,
    string?   AssuranceApproachName,
    long?     AuditMandateId,
    string?   AuditMandateCode,
    string?   AuditMandateName,"""),
("""    string? AuditMandate        = null,""",
"""    long?   AuditMandateId      = null,"""),
])

S = 'src/PracticeManagement.Api/Services/OrgAssuranceDefinitionService.cs'
patch(S, [
("""    // 560
    Task<IReadOnlyList<OrgAssuranceApproachRow>> ListApproachesAsync(CancellationToken cancellationToken);
""",
"""    // 560
    Task<IReadOnlyList<OrgAssuranceMasterRow>> ListApproachesAsync(CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssuranceMasterRow>> ListMandatesAsync(CancellationToken cancellationToken);
"""),
("""    public async Task<IReadOnlyList<OrgAssuranceApproachRow>> ListApproachesAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_approach_list";

        var rows = new List<OrgAssuranceApproachRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceApproachRow(
                ReadLongOrNull(reader, "Id"),
                ReadStringOrNull(reader, "Code"),
                ReadStringOrNull(reader, "Name"),
                ReadStringOrNull(reader, "Description")));
        }
        return rows;
    }""",
"""    public Task<IReadOnlyList<OrgAssuranceMasterRow>> ListApproachesAsync(CancellationToken cancellationToken) =>
        ListMasterAsync("grac_practice.sp_org_assurance_approach_list", cancellationToken);

    // 560: Audit Mandates (grac_practice.org_assurance_mandate_master)
    public Task<IReadOnlyList<OrgAssuranceMasterRow>> ListMandatesAsync(CancellationToken cancellationToken) =>
        ListMasterAsync("grac_practice.sp_org_assurance_mandate_list", cancellationToken);

    // One reader for the Definition masters -- each list proc returns Id, Code, Name, Description.
    private async Task<IReadOnlyList<OrgAssuranceMasterRow>> ListMasterAsync(string procName, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = procName;

        var rows = new List<OrgAssuranceMasterRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceMasterRow(
                ReadLongOrNull(reader, "Id"),
                ReadStringOrNull(reader, "Code"),
                ReadStringOrNull(reader, "Name"),
                ReadStringOrNull(reader, "Description")));
        }
        return rows;
    }"""),
("""            AddParam(command, "@audit_mandate",           DbType.String, (object?)request.AuditMandate ?? DBNull.Value, -1);""",
"""            AddParam(command, "@audit_mandate_id",        DbType.Int64,  (object?)request.AuditMandateId ?? DBNull.Value);"""),
("""        HasColumn(r, "AuditMandate")          ? ReadStringOrNull(r, "AuditMandate")          : null,""",
"""        HasColumn(r, "AuditMandateId")        ? ReadLongOrNull(r, "AuditMandateId")          : null,
        HasColumn(r, "AuditMandateCode")      ? ReadStringOrNull(r, "AuditMandateCode")      : null,
        HasColumn(r, "AuditMandateName")      ? ReadStringOrNull(r, "AuditMandateName")      : null,"""),
("""        53614 => "FRAMEWORKS_INVALID",         // 560: Applicable Frameworks list not valid JSON
""",
"""        53614 => "FRAMEWORKS_INVALID",         // 560: Applicable Frameworks list not valid JSON
        53615 => "MANDATE_NOT_FOUND",          // 560: Audit Mandate missing or inactive
"""),
])

C = 'src/PracticeManagement.Api/Controllers/OrgAssuranceDefinitionController.cs'
patch(C, [
("""            logger.LogError(ex, "OrgAssuranceDefinitionController.ListApproaches failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }
""",
"""            logger.LogError(ex, "OrgAssuranceDefinitionController.ListApproaches failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // 560: Audit Mandates (dropdown feed)
    // ================================================================
    [HttpGet("mandates")]
    public async Task<IActionResult> ListMandates(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListMandatesAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListMandates failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }
"""),
])
