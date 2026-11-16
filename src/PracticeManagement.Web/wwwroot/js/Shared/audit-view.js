// =====================================================================
// window.gracAuditView -- one audit, read-only, on one page (2026-11-13).
//
// The Audit Definition view page's rendering (_audit-definition-workspace,
// 2026-11-04: details, scope, question sets), moved here and extended
// with the configuration (sir): every setup step's latest status, then
// Workflow and Scoring (545: Scope Resolution is no longer a
// configuration step -- the scope is resolved per execution; 548: nor is
// Trigger -- executions start from plan slots). Used by
//   * Audit Definition  -- its view page (row click / View)
//   * Audit Configuration -- the list's 3-dot "View"
// so both show the same page. Nothing here writes.
//
//   window.gracAuditView.render(host, { orgId, definitionId, chipHtml, onSteps })
//     -> Promise<definition | null>
//   onSteps(steps), optional: the setup-status step rows (without
//   "details"), for a page that acts on them (Submit for Review).
//   window.gracAuditView.versionLabel(definition) -> "1.0" / "v2" / ''
//
// host gets the sections (h3.oa-wv-section, dl.oa-wv-facts, .oa-wv-group,
// .pm-table-wrap -- the .oa-ws-view styles in practice-management.css);
// the page keeps its own badges / heading and fills them from the
// definition the promise resolves to. chipHtml(status) draws a step
// status chip; without it a plain .oa-step-chip is drawn.
//
// Reads (each failure only empties its own section):
//   GET definitions/{id}, definitions/{id}/setup-status, /scope,
//   /question-sets (+ question-sets/{setId}/questions), /workflow-config,
//   /scoring-config, /mapping (564: Control and Practice Mapping). Scope sentences: window.gracAuditScopeSummary
//   (js/Shared/audit-scope-summary.js, loaded by the page).
// =====================================================================
(function () {
    'use strict';
    if (window.gracAuditView) return;

    const API = '/practice/api/org-assurance';
    const U   = function (p) { return String(window.appBasePath || window.pmPathBase || '').replace(/\/+$/, '') + p; };
    const esc = function (v) {
        return String(v == null ? '' : v).replace(/[&<>"']/g, function (c) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
        });
    };
    const pick = function (o, a, b) { return o ? (o[a] != null ? o[a] : o[b]) : null; };

    const CHIP = {
        Completed     : { text: 'Completed',      cls: 'is-complete' },
        InProgress    : { text: 'In progress',    cls: 'is-partial'  },
        NotConfigured : { text: 'Not configured', cls: 'is-empty'    }
    };
    function defaultChip(status) {
        const c = CHIP[status];
        return c ? '<span class="oa-step-chip ' + c.cls + '">' + c.text + '</span>' : '';
    }

    function fmtDate(v) {
        if (!v) return '';
        if (typeof window.gracFormatDisplayDate === 'function') {
            const g = window.gracFormatDisplayDate(v); if (g !== v) return g;
        }
        return String(v).slice(0, 10);
    }
    function facts(rows, wide) {
        return '<dl class="oa-wv-facts' + (wide ? ' oa-wv-facts-wide' : '') + '">' + rows.map(function (r) {
            const v = r[1];
            return '<div><dt>' + esc(r[0]) + '</dt>'
                 + (v || v === 0 ? '<dd>' + esc(v) + '</dd>' : '<dd class="oa-wv-empty">Not set</dd>') + '</div>';
        }).join('') + '</dl>';
    }
    function table(head, rows) {
        return '<div class="pm-table-wrap"><table><thead><tr>'
             + head.map(function (h) { return '<th>' + esc(h) + '</th>'; }).join('')
             + '</tr></thead><tbody>' + rows.join('') + '</tbody></table></div>';
    }
    function td(v) { return '<td>' + esc(v == null ? '' : v) + '</td>'; }
    function hint(text) { return '<p class="pm-hint">' + esc(text) + '</p>'; }
    function personWithRole(name, role) {
        const wf = window.__wfCommon;
        if (wf && wf.personWithRole) return wf.personWithRole(name, role);
        return [name, role].filter(Boolean).join(' - ');
    }

    async function render(host, opts) {
        if (!host || !opts || !opts.orgId || !opts.definitionId) return null;
        const chip = typeof opts.chipHtml === 'function' ? opts.chipHtml : defaultChip;
        const id   = encodeURIComponent(opts.definitionId);
        const org  = encodeURIComponent(opts.orgId);
        const get  = function (path) {
            return fetch(U(API + path), { credentials: 'same-origin' })
                .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); });
        };
        const maybe = function (path) { return get(path).catch(function () { return null; }); };

        host.innerHTML = hint('Loading...');
        const res = await Promise.all([
            get('/definitions/' + id + '?organizationId=' + org),
            maybe('/definitions/' + id + '/setup-status?organizationId=' + org),
            maybe('/definitions/' + id + '/scope?organizationId=' + org),
            maybe('/definitions/' + id + '/question-sets?organizationId=' + org),
            maybe('/definitions/' + id + '/workflow-config?organizationId=' + org),
            maybe('/definitions/' + id + '/scoring-config?organizationId=' + org),
            maybe('/definitions/' + id + '/mapping?organizationId=' + org)          // 564
        ]);
        const def = res[0] && (res[0].data || res[0].Data);
        if (!def) throw new Error('Definition not found.');

        const adopted = (res[3] && (res[3].adopted || res[3].Adopted)) || [];
        const questions = await Promise.all(adopted.map(function (s) {
            const sid = pick(s, 'questionSetId', 'QuestionSetId');
            return get('/question-sets/' + encodeURIComponent(sid) + '/questions?organizationId=' + org)
                .then(function (b) { return (b && (b.data || b.Data)) || []; })
                .catch(function () { return null; });
        }));

        const steps = ((res[1] && (res[1].steps || res[1].Steps)) || [])
            .filter(function (s) { return pick(s, 'stepKey', 'StepKey') !== 'details'; });
        if (typeof opts.onSteps === 'function') opts.onSteps(steps);
        const stepOf = function (key) {
            return steps.find(function (s) { return pick(s, 'stepKey', 'StepKey') === key; }) || null;
        };
        // A section heading with its step's status chip.
        const section = function (title, key) {
            const s = key ? stepOf(key) : null;
            return '<h3 class="oa-wv-section">' + esc(title)
                 + (s ? ' ' + chip(pick(s, 'status', 'Status')) : '') + '</h3>';
        };

        host.innerHTML = [
            section('Definition Details') + definitionHtml(def),
            section('Configuration Status') + statusHtml(steps, res[1] === null, chip),
            section('Scope Details', 'scope') + (window.gracAuditScopeSummary ? window.gracAuditScopeSummary.html(res[2]) : hint('Scope could not be loaded.')),
            section('Control and Practice Mapping', 'mapping') + mappingHtml(res[6]),   // 564
            section('Question Sets', 'questions') + questionSetsHtml(adopted, questions, res[3] === null),
            section('Workflow', 'workflow') + workflowHtml(res[4]),
            section('Scoring', 'scoring') + scoringHtml(res[5]),
            section('Created / Updated') + facts([
                ['Created by', pick(def, 'enteredBy', 'EnteredBy')], ['Created', fmtDate(pick(def, 'enteredDt', 'EnteredDt'))],
                ['Updated by', pick(def, 'updatedBy', 'UpdatedBy')], ['Updated', fmtDate(pick(def, 'updatedDt', 'UpdatedDt'))]
            ])
        ].join('');
        return def;
    }

    function versionLabel(d) {
        return pick(d, 'currentVersionLabel', 'CurrentVersionLabel')
            || (pick(d, 'currentVersionNumber', 'CurrentVersionNumber') ? 'v' + pick(d, 'currentVersionNumber', 'CurrentVersionNumber') : '');
    }

    // Definition facts (2026-11-04 rows, unchanged) and the narrative.
    function definitionHtml(d) {
        const p = function (a, b) { return pick(d, a, b); };
        const rows = [
            ['Code',               p('definitionCode', 'DefinitionCode')],
            ['Name',               p('definitionName', 'DefinitionName')],
            ['Assurance Category', p('assuranceCategoryName', 'AssuranceCategoryName')],
            ['Assurance Approach', p('assuranceApproachName', 'AssuranceApproachName')],   // 560
            ['Audit Mandate', (p('auditMandates', 'AuditMandates') || [])                  // 560
                .map(function (m) { return pick(m, 'mandateName', 'MandateName'); })
                .filter(Boolean).join(', ')],
            ['Applicable Frameworks', (p('applicableFrameworks', 'ApplicableFrameworks') || [])   // 560
                .map(function (f) { return pick(f, 'frameworkName', 'FrameworkName'); })
                .filter(Boolean).join(', ')],
            ['Owner',              personWithRole(p('ownerDisplayName', 'OwnerDisplayName'), p('ownerRoleName', 'OwnerRoleName'))],
            ['Effective Date',     fmtDate(p('effectiveDate', 'EffectiveDate'))],
            ['Status',             p('currentStatusName', 'CurrentStatusName')],
            ['Version',            versionLabel(d)]
        ];
        // Lifecycle stamps only once they happened.
        [['Submitted', 'submitted'], ['Approved', 'approved'], ['Activated', 'activated'], ['Retired', 'retired']]
            .forEach(function (s) {
                const cap = s[1].charAt(0).toUpperCase() + s[1].slice(1);
                const by = p(s[1] + 'By', cap + 'By');
                const dt = p(s[1] + 'Dt', cap + 'Dt');
                if (by || dt) rows.push([s[0], [by, fmtDate(dt)].filter(Boolean).join(' - ')]);
            });
        const narrative = [['Objective', p('objective', 'Objective')], ['Description', p('description', 'Description')]]
            .filter(function (r) { return r[1]; });
        return facts(rows) + (narrative.length ? facts(narrative, true) : '');
    }

    // The latest status of every setup step, and how many are complete.
    function statusHtml(steps, failed, chip) {
        if (failed) return hint('The configuration status could not be loaded.');
        if (!steps.length) return hint('No status available.');
        const done = steps.filter(function (s) { return pick(s, 'status', 'Status') === 'Completed'; }).length;
        // 564: an Optional step with nothing set is not counted.
        const total = steps.filter(function (s) { return pick(s, 'status', 'Status') !== 'Optional'; }).length;
        return table(['Step', 'Status', 'Items'], steps.map(function (s) {
            return '<tr>' + td(pick(s, 'stepName', 'StepName'))
                 + '<td>' + chip(pick(s, 'status', 'Status')) + '</td>'
                 + td(pick(s, 'itemCount', 'ItemCount')) + '</tr>';
        })) + '<p class="oa-ws-section-hint" style="margin-top:6px;">Configured ' + done + '/' + total + '.</p>';
    }

    // Question sets with their questions (2026-11-04, unchanged).
    function questionSetsHtml(adopted, questions, failed) {
        if (failed) return hint('Question sets could not be loaded.');
        if (!adopted.length) return hint('No question sets adopted yet.');
        return adopted.map(function (s, i) {
            const qs = questions[i];
            const mand = pick(s, 'isMandatory', 'IsMandatory');
            const head = '<div class="oa-wv-group-title">' + esc(pick(s, 'setName', 'SetName') || '(unnamed)')
                + (pick(s, 'setCode', 'SetCode') ? ' <span class="pm-badge">' + esc(pick(s, 'setCode', 'SetCode'))
                    // 551: the adopted question set version
                    + (pick(s, 'setVersionNumber', 'SetVersionNumber') ? ' v' + esc(pick(s, 'setVersionNumber', 'SetVersionNumber')) : '') + '</span>' : '')
                + (mand === false ? ' <span class="pm-badge">Optional</span>' : '') + '</div>';
            let body;
            if (qs === null)     body = hint('Questions could not be loaded.');
            else if (!qs.length) body = hint('No questions in this set.');
            else body = table(['Code', 'Question', 'Type', 'Mandatory'],
                qs.slice().sort(function (a, b) { return (pick(a, 'displayOrder', 'DisplayOrder') || 0) - (pick(b, 'displayOrder', 'DisplayOrder') || 0); })
                    .map(function (q) {
                        return '<tr>' + td(pick(q, 'questionCode', 'QuestionCode')) + td(pick(q, 'questionText', 'QuestionText'))
                             + td(pick(q, 'questionTypeName', 'QuestionTypeName'))
                             + td(pick(q, 'isMandatory', 'IsMandatory') ? 'Yes' : 'No') + '</tr>';
                    }));
            return '<div class="oa-wv-group">' + head + body + '</div>';
        }).join('');
    }

    // 564: the controls, practices, instances and manual items mapped.
    const MAPPING_TYPE = { CONTROL_STATEMENT: 'Control', PRACTICE: 'Practice', PRACTICE_INSTANCE: 'Practice Instance', MANUAL: 'Manual' };
    const MANUAL_KIND  = { CONTROL: 'Control', PRACTICE: 'Practice', PRACTICE_INSTANCE: 'Practice Instance', OTHER: 'Other' };
    function mappingHtml(json) {
        if (!json) return hint('The mapping could not be loaded.');
        const items = json.items || json.Items || [];
        if (!items.length) return hint('Nothing mapped (optional).');
        return table(['Type', 'Code / Reference', 'Name', 'Note'], items.map(function (m) {
            const type = pick(m, 'mappingType', 'MappingType');
            const manual = type === 'MANUAL';
            const label = manual ? 'Manual - ' + (MANUAL_KIND[pick(m, 'manualKind', 'ManualKind')] || 'Other') : (MAPPING_TYPE[type] || type);
            const name = (pick(m, 'recordName', 'RecordName') || '')
                + (!manual && pick(m, 'isAvailable', 'IsAvailable') === false ? ' (no longer active)' : '');
            return '<tr>' + td(label)
                 + td(manual ? pick(m, 'manualReference', 'ManualReference') : pick(m, 'recordCode', 'RecordCode'))
                 + td(name) + td(pick(m, 'note', 'Note')) + '</tr>';
        }));
    }

    function workflowHtml(json) {
        if (!json) return hint('The workflow could not be loaded.');
        const c = json.config || json.Config;
        const stages = (json.stages || json.Stages || []).slice().sort(function (a, b) {
            return (pick(a, 'stageOrder', 'StageOrder') || 0) - (pick(b, 'stageOrder', 'StageOrder') || 0);
        });
        if (!c && !stages.length) return hint('No workflow configured yet.');
        const sla = c ? pick(c, 'totalSlaDays', 'TotalSlaDays') : null;
        return facts([
            ['Template',       c ? pick(c, 'workflowTemplateName', 'WorkflowTemplateName') : ''],
            ['Workflow Name',  c ? pick(c, 'workflowName', 'WorkflowName') : ''],
            ['Total SLA',      sla != null ? sla + ' day(s)' : '']
        ]) + (c && pick(c, 'description', 'Description') ? facts([['Description', pick(c, 'description', 'Description')]], true) : '')
          + (stages.length
              ? table(['#', 'Stage', 'Type', 'Assigned To', 'SLA (days)', 'Escalation'], stages.map(function (s) {
                    const esc1 = pick(s, 'escalationRoleName', 'EscalationRoleName');
                    const after = pick(s, 'escalationAfterDays', 'EscalationAfterDays');
                    return '<tr>' + td(pick(s, 'stageOrder', 'StageOrder')) + td(pick(s, 'stageName', 'StageName'))
                         + td(pick(s, 'stageType', 'StageType'))
                         + td(personWithRole(pick(s, 'assignedEmployeeName', 'AssignedEmployeeName'), pick(s, 'assignedRoleName', 'AssignedRoleName')))
                         + td(pick(s, 'slaDays', 'SlaDays'))
                         + td(esc1 ? esc1 + (after != null ? ' after ' + after + ' day(s)' : '') : '') + '</tr>';
                }))
              : hint('No stages yet.'));
    }

    function scoringHtml(json) {
        if (!json) return hint('The scoring could not be loaded.');
        const c = json.config || json.Config;
        const bands = (json.bands || json.Bands || []).slice().sort(function (a, b) {
            return (pick(a, 'bandOrder', 'BandOrder') || 0) - (pick(b, 'bandOrder', 'BandOrder') || 0);
        });
        if (!c) return hint('No scoring configured yet.');
        return facts([
            ['Scoring Model',     pick(c, 'scoringModelName', 'ScoringModelName')],
            ['Model Type',        pick(c, 'scoringModelType', 'ScoringModelType')],
            ['Max Score',         pick(c, 'maxScore', 'MaxScore')],
            ['Pass Threshold',    pick(c, 'passThreshold', 'PassThreshold')],
            ['Warning Threshold', pick(c, 'warningThreshold', 'WarningThreshold')],
            ['Fail Threshold',    pick(c, 'failThreshold', 'FailThreshold')]
        ]) + (pick(c, 'description', 'Description') ? facts([['Description', pick(c, 'description', 'Description')]], true) : '')
          + (bands.length
              ? table(['#', 'Band', 'Min', 'Max', 'Outcome'], bands.map(function (b) {
                    return '<tr>' + td(pick(b, 'bandOrder', 'BandOrder')) + td(pick(b, 'bandName', 'BandName'))
                         + td(pick(b, 'minScore', 'MinScore')) + td(pick(b, 'maxScore', 'MaxScore'))
                         + td(pick(b, 'outcomeCode', 'OutcomeCode')) + '</tr>';
                }))
              : '');
    }

    window.gracAuditView = { render: render, versionLabel: versionLabel };
})();
