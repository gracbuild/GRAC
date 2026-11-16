"""Generates the TPRM API tier (models, service, controller) from the
procedure signatures in database/486-489 and 521-525 and the endpoint table below.

Why generated: the module has ~70 procedures. Hand-binding each parameter
is where mistakes hide (a renamed parameter, a size that truncates). The
generator reads the real signature, so a request record, its AddParam
calls and the procedure always agree. The OUTPUT is ordinary code in the
house style (typed request records, explicit AddParam, dictionary rows)
and is checked in; re-run after changing a TPRM procedure signature:

    python3 tools/tprm/gen_csharp.py
"""
import os
import re

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
DB = os.path.join(ROOT, 'database')
API = os.path.join(ROOT, 'src', 'PracticeManagement.Api')

# ---------------------------------------------------------------------------
# Procedure signatures
# ---------------------------------------------------------------------------
SIGS = {}
# 521 (Third-Party Management Phase 1) and 522 (CR 2 Round A) re-issue
# procedures of 486 / 488 / 489 / 521; read in order, the latest wins.
for f in ['486_tprm_configuration.sql', '488_tprm_third_parties_engagements.sql',
          '489_tprm_due_diligence_decision_monitoring.sql', '521_tpm_vendor_registry_foundation.sql',
          '522_tpm_cr2_registration_exposure.sql', '523_tpm_cr2_screening_admission.sql',
          '524_tpm_cr2_risk_register.sql', '525_tpm_dashboard_tasks_profile_review.sql']:
    t = open(os.path.join(DB, f)).read()
    for m in re.finditer(r'CREATE OR ALTER PROCEDURE grac_practice\.(\w+)\s*(.*?)\nAS\n', t, re.S):
        ps = []
        for pm in re.finditer(r'@(\w+)\s+([A-Z]+)(\(([^)]*)\))?(\s*=\s*[^,\n]+)?(\s+OUTPUT)?', m.group(2)):
            ps.append(dict(sql=pm.group(1), type=pm.group(2), size=pm.group(4),
                           optional=bool(pm.group(5)), output=bool(pm.group(6))))
        SIGS[m.group(1)] = ps

# Parameters the API fills from the caller, never from the request.
INJECTED = {
    'actor': 'caller.Actor',
    'actor_employee_id': 'caller.EmployeeId',
    'caller_employee_id': 'caller.EmployeeId',
    'caller_is_admin': 'caller.IsAdmin',
    'is_platform_admin': 'caller.IsPlatformAdmin',
    'caller_role_names': None,      # derived in SQL from the employee's GRAC role
    'suppress_result': None,        # 523: only procedure-to-procedure calls suppress the result
    'raise_impact_review': None,    # 524: only migration 524 links without an impact review
}


def camel(s):
    p = s.split('_')
    return p[0] + ''.join(x.title() for x in p[1:])


def pascal(s):
    return ''.join(x.title() for x in s.split('_'))


CS_TYPE = {'BIGINT': 'long?', 'INT': 'int?', 'BIT': 'bool?', 'DECIMAL': 'decimal?', 'DATE': 'DateTime?',
           'NVARCHAR': 'string?'}
DB_TYPE = {'BIGINT': 'DbType.Int64', 'INT': 'DbType.Int32', 'BIT': 'DbType.Boolean', 'DECIMAL': 'DbType.Decimal',
           'DATE': 'DbType.Date', 'NVARCHAR': 'DbType.String'}

# ---------------------------------------------------------------------------
# Endpoints: (Name, METHOD, route, procedure, kind, set names / options)
#   kind rows    -> TprmRowsResult  (data + totalRows)
#   kind sets    -> TprmSetsResult  (named result sets)
#   kind command -> TprmCommandResult (the row with a Result column)
# Route ids bind to the procedure parameter of the same name
# ({engagementId} -> @engagement_id) unless mapped in ROUTE_MAP.
# ---------------------------------------------------------------------------
E = [
    # ---- lookups / configuration (486) --------------------------------
    ('Lookups', 'GET', 'lookups', 'sp_tprm_lookups', 'sets',
     ['values', 'employees', 'businessFunctions', 'processes', 'applications', 'thirdParties', 'contracts', 'library',
      'customFields', 'riskModel', 'dimensions', 'bands', 'evidenceTypes', 'roles']),
    ('ConfigReference', 'GET', 'config/reference', 'sp_tprm_config_reference_get', 'sets', ['lists', 'values']),
    ('SaveReferenceValue', 'POST', 'config/reference/values', 'sp_tprm_reference_value_save', 'command', None),
    ('OverrideReferenceValue', 'POST', 'config/reference/overrides', 'sp_tprm_reference_value_override', 'command', None),
    ('Library', 'GET', 'config/library', 'sp_tprm_library_list', 'rows', None),
    ('SaveLibraryItem', 'POST', 'config/library/items', 'sp_tprm_library_save', 'command', None),
    ('OverrideLibraryItem', 'POST', 'config/library/overrides', 'sp_tprm_library_override', 'command', None),
    ('Rules', 'GET', 'config/rules', 'sp_tprm_rules_get', 'sets', ['approvalRules', 'reviewRules', 'delegations', 'roles']),
    ('SaveApprovalRule', 'POST', 'config/rules/approval', 'sp_tprm_approval_rule_save', 'command', None),
    ('SaveReviewRule', 'POST', 'config/rules/review', 'sp_tprm_review_rule_save', 'command', None),
    ('SaveDelegation', 'POST', 'config/delegations', 'sp_tprm_delegation_save', 'command', None),
    ('CustomFields', 'GET', 'config/custom-fields', 'sp_tprm_custom_field_list', 'rows', None),
    ('SaveCustomField', 'POST', 'config/custom-fields', 'sp_tprm_custom_field_save', 'command', None),
    ('Templates', 'GET', 'config/templates', 'sp_tprm_template_list', 'rows', None),
    ('TemplateVersion', 'GET', 'config/templates/versions/{versionId}', 'sp_tprm_template_version_get', 'sets', 'TEMPLATE'),
    ('CompareTemplateVersions', 'GET', 'config/templates/compare', 'sp_tprm_template_compare', 'rows', None),
    ('CreateTemplate', 'POST', 'config/templates', 'sp_tprm_template_create', 'command', None),
    ('AdoptTemplate', 'POST', 'config/templates/{baselineTemplateId}/adopt', 'sp_tprm_template_adopt', 'command', None),
    ('NewTemplateVersion', 'POST', 'config/templates/{templateId}/new-version', 'sp_tprm_template_new_version', 'command', None),
    ('RetireTemplate', 'POST', 'config/templates/{templateId}/retire', 'sp_tprm_template_retire', 'command', None),
    ('SaveTemplateVersionHeader', 'POST', 'config/templates/versions/{versionId}/header', 'sp_tprm_template_version_header_save', 'command', None),
    ('SaveRiskModelItem', 'POST', 'config/templates/versions/{versionId}/risk-items', 'sp_tprm_rm_item_save', 'command', None),
    ('SaveQuestionnaireItem', 'POST', 'config/templates/versions/{versionId}/questionnaire-items', 'sp_tprm_q_item_save', 'command', None),
    ('RemoveTemplateItem', 'POST', 'config/templates/versions/{versionId}/items/remove', 'sp_tprm_template_item_remove', 'command', None),
    ('ActivateTemplateVersion', 'POST', 'config/templates/versions/{versionId}/activate', 'sp_tprm_template_version_activate', 'command', None),
    # ---- Vendor Registry (488, restructured by 521) ----------------------
    ('ThirdParties', 'GET', 'third-parties', 'sp_tprm_third_party_list', 'rows', None),
    ('ThirdParty', 'GET', 'third-parties/{thirdPartyId}', 'sp_tprm_third_party_get', 'sets',
     ['header', 'categories', 'contacts', 'engagements', 'history', 'customValues', 'duplicates', 'transitions',
      'matchReviews']),
    ('SaveThirdParty', 'POST', 'third-parties', 'sp_tprm_third_party_save', 'command', None),
    ('SetThirdPartyStatus', 'POST', 'third-parties/{thirdPartyId}/status', 'sp_tprm_third_party_status', 'command', None),
    ('ReviewVendorMatch', 'POST', 'third-parties/{thirdPartyId}/match-reviews', 'sp_tprm_vendor_match_review_save',
     'command', None),
    ('LoadSamples', 'POST', 'samples/load', 'sp_tprm_sample_load', 'command', None),
    # ---- engagements, discovery, inherent risk (488) --------------------
    ('Engagements', 'GET', 'engagements', 'sp_tprm_engagement_list', 'rows', None),
    ('Engagement', 'GET', 'engagements/{engagementId}', 'sp_tprm_engagement_get', 'sets',
     ['header', 'scope', 'links', 'snapshots', 'history', 'customValues', 'dimensions']),
    ('SaveEngagement', 'POST', 'engagements', 'sp_tprm_engagement_save', 'command', None),
    # 522 (CR 2 5.2): Scope & Exposure -- gating answers, exposure fields and
    # the proposed scope items as one set.
    ('SaveEngagementExposure', 'POST', 'engagements/{engagementId}/exposure', 'sp_tprm_engagement_exposure_save',
     'command', None),
    # 523 (CR 2 6-7): screening, applicability decision, admission approval
    ('Applicability', 'GET', 'engagements/{engagementId}/applicability', 'sp_tprm_applicability_get', 'sets',
     ['reports', 'report', 'observations', 'decisions', 'admissions', 'approvals']),
    ('RunScreening', 'POST', 'engagements/{engagementId}/screening', 'sp_tprm_screening_run', 'command', None),
    ('DecideApplicability', 'POST', 'engagements/{engagementId}/applicability', 'sp_tprm_applicability_decide', 'command', None),
    ('ActOnAdmission', 'POST', 'admissions/{admissionId}/act', 'sp_tprm_admission_act', 'command', None),
    ('WithdrawAdmission', 'POST', 'admissions/{admissionId}/withdraw', 'sp_tprm_admission_withdraw', 'command', None),
    # 524 (CR 2 8): TP Risk Register -- vendor-level records of admitted vendors
    ('RiskRegister', 'GET', 'risk-register', 'sp_tprm_register_list', 'rows', None),
    ('RiskRegisterRecord', 'GET', 'risk-register/{registerId}', 'sp_tprm_register_get', 'sets',
     ['header', 'areas', 'ratingHistory', 'dimensions', 'engagements', 'findings', 'decisions', 'admissions',
      'impactReviews', 'reviews', 'history', 'profileReviews']),
    ('RateProfileArea', 'POST', 'risk-register/{registerId}/ratings', 'sp_tprm_register_rating_save', 'command', None),
    ('DecideImpactReview', 'POST', 'risk-register/impact-reviews/{impactReviewId}/decide',
     'sp_tprm_register_impact_review_decide', 'command', None),
    ('CloseRegisterRecord', 'POST', 'risk-register/{registerId}/close', 'sp_tprm_register_close', 'command', None),
    # 525: periodic review of the vendor profile
    ('RecordProfileReview', 'POST', 'risk-register/{registerId}/profile-reviews', 'sp_tprm_register_profile_review_save',
     'command', None),
    ('SaveScopeItem', 'POST', 'engagements/{engagementId}/scope', 'sp_tprm_scope_item_save', 'command', None),
    ('RemoveScopeItem', 'POST', 'engagements/scope/{scopeItemId}/remove', 'sp_tprm_scope_item_remove', 'command', None),
    ('Discovery', 'GET', 'engagements/{engagementId}/discovery', 'sp_tprm_engagement_discover', 'sets',
     ['summary', 'instances', 'obligations', 'dependencies', 'findings', 'gaps', 'risks', 'contracts']),
    ('PersistDiscovery', 'POST', 'engagements/{engagementId}/discovery', 'sp_tprm_engagement_discover', 'sets',
     ['summary', 'instances', 'obligations', 'dependencies', 'findings', 'gaps', 'risks', 'contracts']),
    ('SaveLink', 'POST', 'engagements/{engagementId}/links', 'sp_tprm_link_save', 'command', None),
    ('LinkAction', 'POST', 'engagements/links/{linkId}/action', 'sp_tprm_link_action', 'command', None),
    ('StartRiskAssessment', 'POST', 'engagements/{engagementId}/risk-assessments', 'sp_tprm_risk_assessment_start', 'command', None),
    ('RiskAssessment', 'GET', 'risk-assessments/{assessmentId}', 'sp_tprm_risk_assessment_get', 'sets',
     ['header', 'dimensions', 'factors', 'options', 'answers', 'bands']),
    ('SaveRiskAnswers', 'POST', 'risk-assessments/{assessmentId}/answers', 'sp_tprm_risk_answers_save', 'command', None),
    ('CompleteRiskAssessment', 'POST', 'risk-assessments/{assessmentId}/complete', 'sp_tprm_risk_assessment_complete', 'command', None),
    ('RecalculateResidual', 'POST', 'engagements/{engagementId}/residual', 'sp_tprm_residual_recalculate', 'command', None),
    # ---- due diligence, evidence, findings (489) ------------------------
    ('StartDueDiligence', 'POST', 'engagements/{engagementId}/due-diligence', 'sp_tprm_dd_start', 'command', None),
    ('DueDiligence', 'GET', 'engagements/{engagementId}/due-diligence', 'sp_tprm_dd_get', 'sets',
     ['header', 'questionnaires', 'sections', 'questions', 'options', 'safeguards', 'evidence', 'findings',
      'dimensions', 'rounds']),
    ('SaveResponse', 'POST', 'due-diligence/responses/{responseId}', 'sp_tprm_dd_response_save', 'command', None),
    ('RateResponse', 'POST', 'due-diligence/responses/{responseId}/rate', 'sp_tprm_dd_response_rate', 'command', None),
    ('SaveSafeguard', 'POST', 'due-diligence/safeguards/{sgAssessmentId}', 'sp_tprm_safeguard_save', 'command', None),
    ('CompleteDueDiligence', 'POST', 'due-diligence/{ddId}/complete', 'sp_tprm_dd_complete', 'command', None),
    ('EvidenceCandidates', 'GET', 'evidence/candidates', 'sp_tprm_evidence_candidates', 'rows', None),
    ('AddEvidence', 'POST', 'engagements/{engagementId}/evidence', 'sp_tprm_evidence_link_add', 'command', None),
    ('ReviewEvidence', 'POST', 'evidence/{tprmEvidenceId}/review', 'sp_tprm_evidence_review', 'command', None),
    ('SaveFinding', 'POST', 'engagements/{engagementId}/findings', 'sp_tprm_finding_save', 'command', None),
    ('FindingAction', 'POST', 'findings/{findingId}/action', 'sp_tprm_finding_action', 'command', None),
    # ---- decision (489) -------------------------------------------------
    ('Decision', 'GET', 'engagements/{engagementId}/decision', 'sp_tprm_decision_get', 'sets',
     ['pack', 'rule', 'decisions', 'approvals', 'openFindings', 'riskLinks', 'outcomes', 'delegations']),
    ('SubmitDecision', 'POST', 'engagements/{engagementId}/decision/submit', 'sp_tprm_decision_submit', 'command', None),
    ('ActOnDecision', 'POST', 'decisions/{decisionId}/act', 'sp_tprm_decision_act', 'command', None),
    ('WithdrawDecision', 'POST', 'decisions/{decisionId}/withdraw', 'sp_tprm_decision_withdraw', 'command', None),
    ('EscalateRisk', 'POST', 'engagements/{engagementId}/risk-centre', 'sp_tprm_risk_escalate', 'command', None),
    # ---- onboarding and lifecycle (489) ---------------------------------
    ('StartOnboarding', 'POST', 'engagements/{engagementId}/onboarding/start', 'sp_tprm_onboarding_start', 'command', None),
    ('Onboarding', 'GET', 'engagements/{engagementId}/onboarding', 'sp_tprm_onboarding_get', 'sets',
     ['readiness', 'onboardingChecks', 'exitChecks', 'conditions', 'deviations', 'snapshots', 'reviews', 'reviewRule']),
    ('CheckAction', 'POST', 'onboarding/items/{itemId}/action', 'sp_tprm_onboarding_item_action', 'command', None),
    ('CompareExposure', 'POST', 'engagements/{engagementId}/exposure/compare', 'sp_tprm_exposure_compare', 'command', None),
    ('DeviationAction', 'POST', 'deviations/{deviationId}/action', 'sp_tprm_deviation_action', 'command', None),
    ('ActivateEngagement', 'POST', 'engagements/{engagementId}/activate', 'sp_tprm_engagement_activate', 'command', None),
    ('EngagementLifecycle', 'POST', 'engagements/{engagementId}/lifecycle', 'sp_tprm_engagement_lifecycle', 'command', None),
    # ---- reviews and monitoring (489) -----------------------------------
    ('Reviews', 'GET', 'reviews', 'sp_tprm_review_list', 'rows', None),
    ('RaiseReview', 'POST', 'engagements/{engagementId}/reviews', 'sp_tprm_review_raise', 'command', None),
    ('CompleteReview', 'POST', 'reviews/{reviewId}/complete', 'sp_tprm_review_complete', 'command', None),
    ('RunMonitoring', 'POST', 'monitoring/run', 'sp_tprm_monitoring_sweep', 'command', None),
]

# GET discovery is a preview; POST persists (fixed values, not request fields).
FIXED = {('Discovery', 'persist'): 'false', ('PersistDiscovery', 'persist'): 'true',
         ('RunScreening', 'trigger_code'): '"REFRESH"'}

for name, method, route, proc, kind, extra in E:
    assert proc in SIGS, proc
    for rid in re.findall(r'\{(\w+)\}', route):
        sqlname = re.sub(r'([A-Z])', lambda m: '_' + m.group(1).lower(), rid)
        assert any(p['sql'] == sqlname for p in SIGS[proc]), (name, rid)


def route_ids(route):
    return re.findall(r'\{(\w+)\}', route)


def sql_of_route(rid):
    return re.sub(r'([A-Z])', lambda m: '_' + m.group(1).lower(), rid)


def fields(name, proc, route):
    """(param, source) where source is 'route', 'injected', 'fixed' or 'request'."""
    ids = {sql_of_route(r) for r in route_ids(route)}
    out = []
    for p in SIGS[proc]:
        if p['output'] and p['sql'] not in ids:
            continue
        if p['sql'].startswith('out_') or p['sql'] in ('review_id',) and proc == 'sp_tprm_review_create':
            continue
        if (name, p['sql']) in FIXED:
            out.append((p, 'fixed'))
        elif p['sql'] in ids:
            out.append((p, 'route'))
        elif p['sql'] in INJECTED:
            out.append((p, 'injected'))
        else:
            out.append((p, 'request'))
    return out


def size_arg(p):
    if p['type'] != 'NVARCHAR':
        return ''
    return ', -1' if p['size'] == 'MAX' else f", {p['size']}"


def decimal_extra(p):
    if p['type'] == 'DECIMAL' and p['size']:
        prec, scale = p['size'].split(',')
        return prec.strip(), scale.strip()
    return None


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------
models = ['''// =====================================================================
// TPRM models (migrations 486-490)
//
// GENERATED by tools/tprm/gen_csharp.py from the procedure signatures --
// re-run it after changing a TPRM procedure; do not edit by hand.
//
// Rows are returned as column-name dictionaries (the Evidence Center /
// RepositoryChange shape): the procedures own the projection. Requests and
// command results are typed. Every request field is optional at this tier;
// the procedure validates and answers with a sentence (THROW 57500-57899).
// A field left out (null) is not sent, so the procedure's own default
// applies.
// =====================================================================
namespace PracticeManagement.Api.Models;

/// <summary>Who is calling: stamped by the Web tier from the session
/// (X-PM-Caller-*), never taken from the request body.</summary>
public sealed record TprmCaller(long? EmployeeId, bool IsAdmin, bool IsPlatformAdmin, string Actor);

public sealed record TprmRowsResult(
    bool Success,
    IReadOnlyList<Dictionary<string, object?>> Rows,
    int TotalRows,
    string? Error = null);

public sealed record TprmSetsResult(
    bool Success,
    IReadOnlyDictionary<string, IReadOnlyList<Dictionary<string, object?>>> Sets,
    string? Error = null);

/// <summary>Row: the procedure's result row (its Result column says what
/// happened). Duplicates: the possible duplicates when Result = DUPLICATES
/// (nothing was saved).</summary>
public sealed record TprmCommandResult(
    bool Success,
    Dictionary<string, object?>? Row,
    IReadOnlyList<Dictionary<string, object?>> Duplicates,
    string? Error = null);
''']

for name, method, route, proc, kind, extra in E:
    fs = fields(name, proc, route)
    req = [(p, s) for p, s in fs if s == 'request']
    rec = f'Tprm{name}Request' if method == 'POST' else f'Tprm{name}Query'
    lines = []
    for p, s in req:
        lines.append(f"    {CS_TYPE[p['type']]} {pascal(p['sql'])} = null")
    body = ',\n'.join(lines)
    models.append(f"/// <summary>{method} {route} -> grac_practice.{proc}.</summary>\n"
                  f"public sealed record {rec}(\n{body});\n" if lines else
                  f"/// <summary>{method} {route} -> grac_practice.{proc}.</summary>\npublic sealed record {rec};\n")

open(os.path.join(API, 'Models', 'TprmModels.cs'), 'w').write('\n'.join(models))

# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------
iface, impl = [], []
for name, method, route, proc, kind, extra in E:
    fs = fields(name, proc, route)
    rids = route_ids(route)
    rec = f'Tprm{name}Request' if method == 'POST' else f'Tprm{name}Query'
    ret = {'rows': 'TprmRowsResult', 'sets': 'TprmSetsResult', 'command': 'TprmCommandResult'}[kind]
    args = ''.join(f'long {r}, ' for r in rids)
    sig = f'Task<{ret}> {name}Async({args}{rec} request, TprmCaller caller, CancellationToken cancellationToken)'
    iface.append(f'    {sig};')
    binds = []
    for p, s in fs:
        n = p['sql']
        if s == 'route':
            val = camel(n)
            always = True
        elif s == 'fixed':
            val = FIXED[(name, n)]
            always = True
        elif s == 'injected':
            if INJECTED[n] is None:
                continue
            val = INJECTED[n]
            always = True
        else:
            val = f'request.{pascal(n)}'
            if p['type'] == 'NVARCHAR':
                val = f'Text({val})'
            elif p['type'] == 'DATE':
                val = f'{val}?.Date'
            always = not p['optional']
        dec = decimal_extra(p)
        extra_args = size_arg(p)
        call = f'AddParam(command, "@{n}", {DB_TYPE[p["type"]]}, {val}{extra_args}'
        if dec:
            call += f', precision: {dec[0]}, scale: {dec[1]}'
        call += ');'
        if always:
            binds.append(f'            {call}')
        else:
            raw = val
            if p['type'] == 'NVARCHAR':
                test = f'!string.IsNullOrWhiteSpace(request.{pascal(n)})'
            elif s == 'injected':
                test = f'{raw} is not null'
            else:
                test = f'request.{pascal(n)} is not null'
            binds.append(f'            if ({test}) {call}')
    bind_block = '\n'.join(binds)
    fail = f'"{route} failed"'
    if kind == 'rows':
        run = '            return await RowsAsync(command, cancellationToken);'
        catch = f'            return new TprmRowsResult(false, [], 0, UserMessage(ex, "The list could not be loaded.", "{proc}"));'
    elif kind == 'sets':
        if extra == 'TEMPLATE':
            run = '            return await SetsAsync(command, TemplateVersionSetNames, cancellationToken);'
        else:
            names = ', '.join(f'"{x}"' for x in extra)
            run = f'            return await SetsAsync(command, _ => [{names}], cancellationToken);'
        catch = f'            return new TprmSetsResult(false, new Dictionary<string, IReadOnlyList<Dictionary<string, object?>>>(), UserMessage(ex, "The record could not be loaded.", "{proc}"));'
    else:
        run = '            return await CommandAsync(command, cancellationToken);'
        catch = f'            return new TprmCommandResult(false, null, [], UserMessage(ex, "The change could not be saved.", "{proc}"));'
    impl.append(f'''    // {method} {route}
    public async {sig}
    {{
        ArgumentNullException.ThrowIfNull(request);
        try
        {{
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = Proc(connection, "grac_practice.{proc}");
{bind_block}
{run}
        }}
        catch (Exception ex)
        {{
{catch}
        }}
    }}
''')

service = f'''// =====================================================================
// TprmService  (migrations 486-490, Third-Party Risk Management)
//
// GENERATED by tools/tprm/gen_csharp.py from the procedure signatures --
// re-run it after changing a TPRM procedure; do not edit by hand.
//
// Facade over the grac_practice.sp_tprm_* procedures: one method per
// endpoint of TprmController. The procedures own every rule (scope,
// segregation of duties, lifecycle gates, versioning); this class binds
// parameters and shapes results:
//   rows     -> the rows + TotalRows (paged lists)
//   sets     -> named result sets (detail screens)
//   command  -> the row that carries a Result column (a procedure that
//               calls another, e.g. sp_risk_candidate_create, may return
//               that procedure's row first); Result DUPLICATES also
//               returns the duplicate candidates (nothing was saved).
//
// Caller: employee id, organization-admin flag and platform-admin flag
// come from the X-PM-Caller-* headers the Web tier stamps from the
// session (TprmCaller); @caller_role_names is left to SQL, which derives
// it from organization_employee.role_id.
//
// Errors: a THROW in 57500-58149 (TPRM; 521-523 use 58000-58149), 55000-56299 (Gap Register / Risk
// Centre procedures TPRM calls) or 50000 is a sentence for the user and is
// returned as is; a missing procedure (2812) says which migrations to
// run; anything else is logged and replaced by a generic sentence.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Infrastructure;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface ITprmService
{{
{chr(10).join(iface)}
    /// <summary>The monitoring pass of TaskNotificationWorker (NULL = every organization).</summary>
    Task<int> RunMonitoringSweepAsync(long? organizationId, CancellationToken cancellationToken);
}}

public sealed class TprmService(
    IConfiguration configuration,
    ILogger<TprmService> logger) : ITprmService
{{
{chr(10).join(impl)}
    public async Task<int> RunMonitoringSweepAsync(long? organizationId, CancellationToken cancellationToken)
    {{
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = Proc(connection, "grac_practice.sp_tprm_monitoring_sweep");
        command.CommandTimeout = 300;
        if (organizationId is > 0) AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@actor", DbType.String, "tprm-scheduler", 100);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await reader.ReadAsync(cancellationToken) ? Convert.ToInt32(reader["ReviewsRaised"]) : 0;
    }}

    // ==============================================================
    // Helpers -- the sibling services' shape
    // ==============================================================

    // sp_tprm_template_version_get: the sets after header + versions
    // depend on the template kind (risk model or questionnaire).
    private static string[] TemplateVersionSetNames(IReadOnlyList<Dictionary<string, object?>> header)
    {{
        var kind = header.Count > 0 && header[0].TryGetValue("TemplateKind", out var k) ? k?.ToString() : null;
        return string.Equals(kind, "RISK_MODEL", StringComparison.OrdinalIgnoreCase)
            ? ["header", "versions", "dimensions", "factors", "options", "bands", "tierRules"]
            : ["header", "versions", "sections", "questions", "options"];
    }}

    private string UserMessage(Exception ex, string fallback, string procedure)
    {{
        if (ex is SqlException sql)
        {{
            if (sql.Number is (>= 57500 and <= 58149) or (>= 55000 and <= 56299) or 50000)
                return sql.Message;
            if (sql.Number == 2812)
            {{
                logger.LogError(ex, "{{Procedure}} is missing.", procedure);
                return "Third-Party Risk Management is not installed on this database (run migrations 486-490).";
            }}
        }}
        logger.LogError(ex, "{{Procedure}} failed.", procedure);
        return fallback;
    }}

    private static async Task<TprmRowsResult> RowsAsync(DbCommand command, CancellationToken cancellationToken)
    {{
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var rows  = await ReadRowsAsync(reader, cancellationToken);
        var total = rows.Count > 0 && rows[0].TryGetValue("TotalRows", out var t) && t is not null ? Convert.ToInt32(t) : rows.Count;
        return new TprmRowsResult(true, rows, total);
    }}

    private static async Task<TprmSetsResult> SetsAsync(
        DbCommand command, Func<IReadOnlyList<Dictionary<string, object?>>, string[]> names, CancellationToken cancellationToken)
    {{
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var sets = new List<IReadOnlyList<Dictionary<string, object?>>>();
        do {{ sets.Add(await ReadRowsAsync(reader, cancellationToken)); }}
        while (await reader.NextResultAsync(cancellationToken));

        var named = names(sets.Count > 0 ? sets[0] : Array.Empty<Dictionary<string, object?>>());
        var result = new Dictionary<string, IReadOnlyList<Dictionary<string, object?>>>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < sets.Count; i++)
            result[i < named.Length ? named[i] : $"set{{i + 1}}"] = sets[i];
        foreach (var n in named)
            result.TryAdd(n, []);   // a set the procedure did not return is empty, not absent
        return new TprmSetsResult(true, result);
    }}

    private static async Task<TprmCommandResult> CommandAsync(DbCommand command, CancellationToken cancellationToken)
    {{
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        Dictionary<string, object?>? row = null, fallback = null;
        IReadOnlyList<Dictionary<string, object?>> duplicates = [];
        do
        {{
            var rows = await ReadRowsAsync(reader, cancellationToken);
            if (rows.Count == 0) continue;
            if (rows[0].ContainsKey("Result")) row = rows[0];
            else if (rows[0].ContainsKey("MatchKind")) duplicates = rows;
            else fallback ??= rows[0];
        }}
        while (await reader.NextResultAsync(cancellationToken));
        return new TprmCommandResult(true, row ?? fallback, duplicates);
    }}

    private static async Task<List<Dictionary<string, object?>>> ReadRowsAsync(DbDataReader reader, CancellationToken cancellationToken)
    {{
        var rows = new List<Dictionary<string, object?>>();
        while (await reader.ReadAsync(cancellationToken))
        {{
            var row = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
            for (var i = 0; i < reader.FieldCount; i++)
                row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            rows.Add(row);
        }}
        return rows;
    }}

    private async Task<DbConnection> OpenAsync(CancellationToken cancellationToken)
    {{
        var connString = SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connString))
            throw new InvalidOperationException("PracticeManagement connection string is not configured.");
        var connection = new SqlConnection(connString);
        await connection.OpenAsync(cancellationToken);
        await ViewScopeSession.ApplyAsync(connection, cancellationToken);   // 415: View Data Scope
        return connection;
    }}

    private static DbCommand Proc(DbConnection connection, string name)
    {{
        var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = name;
        command.CommandTimeout = 120;
        return command;
    }}

    private static object Text(string? value) =>
        string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();

    private static void AddParam(DbCommand command, string name, DbType type, object? value, int? size = null,
        byte? precision = null, byte? scale = null)
    {{
        var p = command.CreateParameter();
        p.ParameterName = name;
        p.DbType = type;
        if (size.HasValue) p.Size = size.Value;
        if (precision.HasValue) p.Precision = precision.Value;
        if (scale.HasValue) p.Scale = scale.Value;
        p.Value = value ?? DBNull.Value;
        command.Parameters.Add(p);
    }}
}}
'''
open(os.path.join(API, 'Services', 'TprmService.cs'), 'w').write(service)

# ---------------------------------------------------------------------------
# Controller
# ---------------------------------------------------------------------------
doc = []
for name, method, route, proc, kind, extra in E:
    doc.append(f'//   {method:<4} {route:<62} {proc}')
actions = []
for name, method, route, proc, kind, extra in E:
    rids = route_ids(route)
    rec = f'Tprm{name}Request' if method == 'POST' else f'Tprm{name}Query'
    route_c = route
    for r in rids:
        route_c = route_c.replace('{' + r + '}', '{' + r + ':long}')
    rargs = ''.join(f'long {r}, ' for r in rids)
    call_ids = ''.join(f'{r}, ' for r in rids)
    fs = fields(name, proc, route)
    org_required = any(p['sql'] == 'organization_id' and not p['optional'] for p, s in fs if s == 'request')
    if method == 'GET':
        source = f'[FromQuery] {rec} request'
    else:
        source = f'[FromBody] {rec} request'
    check = ''
    if org_required:
        check = ('        if (request.OrganizationId is not > 0) return BadRequest(new { error = "organizationId is required." });\n')
    respond = {'rows': 'Rows', 'sets': 'Sets', 'command': 'Command'}[kind]
    attr = 'HttpGet' if method == 'GET' else 'HttpPost'
    actions.append(f'''    [{attr}("{route_c}")]
    public async Task<IActionResult> {name}({rargs}{source}, CancellationToken cancellationToken)
    {{
        if (request is null) return BadRequest(new {{ error = "Request body is required." }});
{check}        return {respond}(await tprmService.{name}Async({call_ids}request, Caller, cancellationToken));
    }}
''')

controller = f'''// =====================================================================
// TprmController  (migrations 486-490, Third-Party Risk Management)
//
// GENERATED by tools/tprm/gen_csharp.py -- re-run it after changing the
// endpoint table or a TPRM procedure signature; do not edit by hand.
// docs/tprm.md section 9 is the endpoint reference.
//
// Route: /api/practice/tprm/...  (GET: query string; POST: JSON body;
// organizationId is in the query / body of every call)
{chr(10).join(doc)}
//
// The caller (employee id, organization-admin flag, platform-admin flag)
// comes from the headers the Web tier stamps from the SESSION
// (X-PM-Caller-*), never from the browser. The Web tier checks the menu
// grant of the screen; the procedures decide everything else.
// Responses: rows -> {{ data, totalRows }}; sets -> {{ <setName>: rows ... }};
// command -> {{ success, result }} or 409 {{ duplicate, result, duplicates }};
// a refusal -> 400 {{ error }}.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/tprm")]
public sealed class TprmController(ITprmService tprmService) : ControllerBase
{{
    private const string CallerEmployeeHeader      = "X-PM-Caller-Employee-Id";
    private const string CallerAdminHeader         = "X-PM-Caller-Is-Admin";
    private const string CallerPlatformAdminHeader = "X-PM-Caller-Is-Platform-Admin";

    private long? CallerEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private bool HeaderFlag(string header) =>
        Request.Headers[header].ToString() is "1" or "true" or "True";

    private TprmCaller Caller => new(
        CallerEmployeeId,
        HeaderFlag(CallerAdminHeader),
        HeaderFlag(CallerPlatformAdminHeader),
        CallerEmployeeId is {{ }} id ? $"employee:{{id}}" : "system");

{chr(10).join(actions)}
    // ------------------------------------------------------------------
    private IActionResult Rows(TprmRowsResult result) =>
        result.Success
            ? Ok(new {{ data = result.Rows, totalRows = result.TotalRows }})
            : BadRequest(new {{ error = result.Error }});

    private IActionResult Sets(TprmSetsResult result) =>
        result.Success ? Ok(result.Sets) : BadRequest(new {{ error = result.Error }});

    private IActionResult Command(TprmCommandResult result)
    {{
        if (!result.Success) return BadRequest(new {{ error = result.Error }});
        var outcome = result.Row is not null && result.Row.TryGetValue("Result", out var r) ? r?.ToString() : null;
        // 409: nothing saved -- possible duplicates that still need a review
        // (521); the screen shows them and asks, for each, why it is a
        // different vendor, then saves again with matchReviewsJson.
        return string.Equals(outcome, "DUPLICATES", StringComparison.OrdinalIgnoreCase)
            ? Conflict(new
              {{
                  duplicate = true,
                  result = result.Row,
                  duplicates = result.Duplicates,
                  error = "Possible duplicates found. Nothing was saved: review each match below."
              }})
            : Ok(new {{ success = true, result = result.Row }});
    }}
}}
'''
open(os.path.join(API, 'Controllers', 'TprmController.cs'), 'w').write(controller)
print('endpoints:', len(E))
