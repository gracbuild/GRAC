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
        assert n == 1, (rel, old[:90], n)
        s = s.replace(old, new)
    if crlf: s = s.replace('\n', '\r\n')
    open(p, 'wb').write((b'\xef\xbb\xbf' if bom else b'') + s.encode('utf-8'))
    print('patched', rel)

M = 'src/PracticeManagement.Api/Models/OrgAssuranceDefinitionModels.cs'
patch(M, [
("""/// <summary>560: an Applicable Framework sent on save.</summary>""",
"""/// <summary>560: one Audit Mandate of a definition version (code / name as saved).</summary>
public sealed record OrgAssuranceDefinitionMandateRow(
    long?  DefinitionMandateId,
    long   AuditMandateId,
    string MandateCode,
    string MandateName,
    int    DisplayOrder);

/// <summary>560: an Applicable Framework sent on save.</summary>"""),
("""    // 560: Assurance Approach and Audit Mandate (id + code / name as saved).
    long?     AssuranceApproachId,
    string?   AssuranceApproachCode,
    string?   AssuranceApproachName,
    long?     AuditMandateId,
    string?   AuditMandateCode,
    string?   AuditMandateName,""",
"""    // 560: Assurance Approach (id + code / name as saved).
    long?     AssuranceApproachId,
    string?   AssuranceApproachCode,
    string?   AssuranceApproachName,"""),
("""    IReadOnlyList<OrgAssuranceDefinitionFrameworkRow>? ApplicableFrameworks = null);

/// <summary>Save request""",
"""    IReadOnlyList<OrgAssuranceDefinitionFrameworkRow>? ApplicableFrameworks = null,
    // 560: the current version's Audit Mandates (third result set).
    IReadOnlyList<OrgAssuranceDefinitionMandateRow>? AuditMandates = null);

/// <summary>Save request"""),
("""    // 560: Assurance Approach, Audit Mandate, Applicable Frameworks
    // (ApplicableFrameworks null = leave the saved list as it is; empty = clear it).
    long?   AssuranceApproachId = null,
    long?   AuditMandateId      = null,""",
"""    // 560: Assurance Approach, Audit Mandates, Applicable Frameworks
    // (a list left null = leave the saved list as it is; empty = clear it).
    long?   AssuranceApproachId = null,
    IReadOnlyList<long>? AuditMandateIds = null,"""),
])

S = 'src/PracticeManagement.Api/Services/OrgAssuranceDefinitionService.cs'
patch(S, [
("""        // 560: second result set -- the current version's Applicable Frameworks
        // (absent before 560 is run: the list stays empty).
        var frameworks = new List<OrgAssuranceDefinitionFrameworkRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                frameworks.Add(new OrgAssuranceDefinitionFrameworkRow(
                    ReadLongOrNull(reader, "DefinitionFrameworkId"),
                    ReadLongOrNull(reader, "ReleaseId"),
                    reader["FrameworkName"]?.ToString() ?? "",
                    ReadIntOrNull(reader, "DisplayOrder") ?? 0));
        }
        return detail with { ApplicableFrameworks = frameworks };""",
"""        // 560: second result set -- the current version's Applicable Frameworks;
        // third -- its Audit Mandates (both absent before 560 is run: empty lists).
        var frameworks = new List<OrgAssuranceDefinitionFrameworkRow>();
        var mandates   = new List<OrgAssuranceDefinitionMandateRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                frameworks.Add(new OrgAssuranceDefinitionFrameworkRow(
                    ReadLongOrNull(reader, "DefinitionFrameworkId"),
                    ReadLongOrNull(reader, "ReleaseId"),
                    reader["FrameworkName"]?.ToString() ?? "",
                    ReadIntOrNull(reader, "DisplayOrder") ?? 0));
            if (await reader.NextResultAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                    mandates.Add(new OrgAssuranceDefinitionMandateRow(
                        ReadLongOrNull(reader, "DefinitionMandateId"),
                        Convert.ToInt64(reader["AuditMandateId"]),
                        reader["MandateCode"]?.ToString() ?? "",
                        reader["MandateName"]?.ToString() ?? "",
                        ReadIntOrNull(reader, "DisplayOrder") ?? 0));
            }
        }
        return detail with { ApplicableFrameworks = frameworks, AuditMandates = mandates };"""),
("""            AddParam(command, "@audit_mandate_id",        DbType.Int64,  (object?)request.AuditMandateId ?? DBNull.Value);""",
"""            AddParam(command, "@audit_mandate_ids_json",  DbType.String,
                request.AuditMandateIds is null
                    ? (object)DBNull.Value
                    : System.Text.Json.JsonSerializer.Serialize(request.AuditMandateIds), -1);"""),
("""        HasColumn(r, "AuditMandateId")        ? ReadLongOrNull(r, "AuditMandateId")          : null,
        HasColumn(r, "AuditMandateCode")      ? ReadStringOrNull(r, "AuditMandateCode")      : null,
        HasColumn(r, "AuditMandateName")      ? ReadStringOrNull(r, "AuditMandateName")      : null,
""", ""),
("""        53615 => "MANDATE_NOT_FOUND",          // 560: Audit Mandate missing or inactive""",
"""        53615 => "MANDATE_INVALID",            // 560: an Audit Mandate missing / inactive, or the list not valid JSON"""),
])

F = 'src/PracticeManagement.Web/Views/Practice/Partials/org-assurance-definitions.cshtml'
patch(F, [
("""           Audit Mandate (a dropdown -- the basis of the audit,
           /practice/api/org-assurance/mandates) under Audit Category;""",
"""           Audit Mandate (a multi-select, .pm-checkcombo -- the bases of
           the audit, /practice/api/org-assurance/mandates) under Audit
           Category;"""),
("""            <label class="pm-field" style="min-width:0;">
                <span>Audit Mandate</span>
                <select class="pm-input" id="oaDefMandate">
                    <option value="">Loading mandates...</option>
                </select>
            </label>""",
"""            <div class="pm-field" style="min-width:0;">
                <span>Audit Mandate</span>
                <div id="oaDefMandates"></div>
            </div>"""),
("""        await loadMaster('mandates',   '/mandates',   'oaDefMandate',  'mandates');""",
"""        await loadMaster('mandates',   '/mandates',   null,            'mandates');   // multi-select, drawn per form"""),
("""    // state[key] and drawn into their select. One loader for both.
    async function loadMaster(key, path, selectId, noun) {
        const sel = document.getElementById(selectId);
        try {
            const r = await fetch(U(API + path), { credentials: 'same-origin' });
            if (!r.ok) {
                sel.innerHTML = '<option value="">(no ' + noun + ' available)</option>';
                return;
            }
            const b = await r.json();
            state[key] = (b && (b.data || b.Data)) || [];
            renderMasterOptions(key, selectId, noun);
        } catch (_) {
            sel.innerHTML = '<option value="">(failed to load ' + noun + ')</option>';
        }
    }""",
"""    // state[key] and, for a dropdown (selectId), drawn into its select.
    // One loader for both; the mandates are a multi-select (renderMandates).
    async function loadMaster(key, path, selectId, noun) {
        const sel = selectId ? document.getElementById(selectId) : null;
        try {
            const r = await fetch(U(API + path), { credentials: 'same-origin' });
            if (!r.ok) {
                if (sel) sel.innerHTML = '<option value="">(no ' + noun + ' available)</option>';
                return;
            }
            const b = await r.json();
            state[key] = (b && (b.data || b.Data)) || [];
            if (sel) renderMasterOptions(key, selectId, noun);
        } catch (_) {
            if (sel) sel.innerHTML = '<option value="">(failed to load ' + noun + ')</option>';
        }
    }

    // 560: Audit Mandate -- a multi-select (.pm-checkcombo) of the mandate
    // master; saved values are ticked by mandate id.
    function renderMandates(saved) {
        const options = (state.mandates || []).map(function (m) {
            return { value: String(m.id != null ? m.id : m.Id), label: m.name || m.Name || '' };
        });
        const ticked = (saved || []).map(function (m) {
            return String(m.auditMandateId != null ? m.auditMandateId : m.AuditMandateId);
        });
        document.getElementById('oaDefMandates').innerHTML = window.gracCheckCombo
            ? window.gracCheckCombo.html(options, ticked, { ariaLabel: 'Audit Mandate' })
            : '';
    }

    function readMandates() {
        const combo = document.querySelector('#oaDefMandates [data-checkcombo]');
        return (window.gracCheckCombo ? window.gracCheckCombo.values(combo) : []).map(Number);
    }"""),
("""                const mdId = d.auditMandateId != null ? d.auditMandateId : d.AuditMandateId;
                renderMasterOptions('mandates', 'oaDefMandate', 'mandates', mdId != null ? String(mdId) : '');""",
"""                renderMandates(d.auditMandates || d.AuditMandates || []);"""),
("""            renderMasterOptions('mandates',   'oaDefMandate',  'mandates',   '');   // 560""",
"""            renderMandates([]);                                                      // 560"""),
("""            auditMandateId          : document.getElementById('oaDefMandate').value
                                          ? Number(document.getElementById('oaDefMandate').value) : null,""",
"""            auditMandateIds         : readMandates(),"""),
])

V = 'src/PracticeManagement.Web/wwwroot/js/Shared/audit-view.js'
patch(V, [
("""            ['Audit Mandate',      p('auditMandateName', 'AuditMandateName')],             // 560""",
"""            ['Audit Mandate', (p('auditMandates', 'AuditMandates') || [])                  // 560
                .map(function (m) { return pick(m, 'mandateName', 'MandateName'); })
                .filter(Boolean).join(', ')],"""),
])
