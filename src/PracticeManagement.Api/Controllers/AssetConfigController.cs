// =====================================================================
// AssetConfigController  (migration 420)
//
// Asset & Contract Management -- Phase 2 increment 1: the global asset
// field dictionary (BRD 5.1) and per-organization, versioned asset form
// templates (BRD 5.2). docs/asset-contract-management.md section 6 is the
// endpoint reference.
//
// Route: /api/practice/asset-config
//   GET  field-groups                         dictionary groups + data types
//   GET  field-definitions?groupCode=&dataTypeCode=&sensitivityCode=&search=
//                          &placeableOnly=&includeRetired=&pageNumber=&pageSize=
//   GET  taxonomy                             category / subcategory / type rows
//   GET  templates?organizationId=&assetTypeId=&statusCode=&search=&pageNumber=&pageSize=
//   GET  templates/{id}?organizationId=       header + sections + fields + history
//   GET  templates/{id}/readiness?organizationId=
//   POST templates                            create Draft v1 for an asset type
//   POST templates/{id}/new-version           clone into a new Draft
//   POST templates/{id}/header                Draft only
//   POST templates/{id}/sections              Draft only (add / update one)
//   POST templates/{id}/fields                Draft only (add / update one)
//   POST templates/{id}/fields/remove         Draft only
//   POST templates/{id}/transition            lifecycle move
//   POST templates/{id}/rules                 Draft only (add / update one rule)   (421)
//   POST templates/{id}/rules/remove          Draft only                           (421)
//   POST templates/{id}/evaluate              preview: effective visible/mandatory (421, read-only)
//   GET  valuation?organizationId=            valuation configuration versions     (422)
//   GET  valuation/{id}?organizationId=       header + CIA levels + bands + criticality + history
//   GET  valuation/{id}/readiness?organizationId=
//   POST valuation                            new Draft (v1 = BRD defaults; later = copy)
//   POST valuation/{id}/header                Draft only
//   POST valuation/{id}/items                 Draft only: CIA level / band / criticality level
//   POST valuation/{id}/transition            lifecycle move
//   POST valuation/{id}/calculate             CIA -> Asset Value score + category (read-only)
//   GET  option-lists?organizationId=&search=  option-list catalogue with counts      (423)
//   GET  option-lists/{group}?organizationId=  list + values (global/override/org) + parent candidates
//   POST option-lists/{group}/values            add / edit / retire an organization value
//   POST option-lists/{group}/override          relabel / reorder / hide / reset a global default
//   GET  taxonomy/governance?organizationId=    categories, subcategories, types (+ org defaults),
//                                               criticality, roles, teams                 (424)
//   POST taxonomy/categories                    add / edit a category        (global -- platform admin)
//   POST taxonomy/subcategories                 add / edit an L1 / L2 subcategory (global)
//   POST taxonomy/types                         add / edit an asset type     (global)
//   POST taxonomy/types/{id}/org-defaults       business owner role / support group for one organization
//   GET  tech-catalog?organizationId=           makes, models, selectable asset types, criticality (425)
//   GET  tech-catalog/models/{id}?organizationId=  model + lifecycle events + approval history
//   POST tech-catalog/makes                     add / edit a make   (shared = platform admin)
//   POST tech-catalog/models                    add / edit a model  (shared = platform admin)
//   POST tech-catalog/models/{id}/transition    submit / approve / return / withdraw / reopen
//   GET  tech-catalog/firmware?organizationId=  firmware products + releases               (426)
//   GET  tech-catalog/firmware/releases/{id}?organizationId=  release + compatibility + history
//   GET  tech-catalog/models/{id}/firmware?organizationId=    approved, in-effect compatible firmware
//   POST tech-catalog/firmware/products         add / edit a firmware product
//   POST tech-catalog/firmware/releases         add / edit a release
//   POST tech-catalog/firmware/releases/{id}/transition  Draft / Approved / Recommended / ... / Withdrawn
//   POST tech-catalog/firmware/compatibility    add / edit a compatibility record (returns it to Draft)
//   POST tech-catalog/firmware/compatibility/{id}/approve
//   GET  tech-catalog/os?organizationId=         OS products + releases                      (427)
//   GET  tech-catalog/os/releases/{id}?organizationId=  release + compatibility + history
//   GET  tech-catalog/models/{id}/os?organizationId=    approved compatible operating systems
//   POST tech-catalog/os/products | os/releases | os/releases/{id}/transition
//   POST tech-catalog/os/compatibility | os/compatibility/{id}/approve
//   GET  register?organizationId=&search=&assetTypeId=&statusCode=&pageNumber=&pageSize=   (428)
//   GET  register/{id}?organizationId=          asset + stored values + status history
//   GET  register/form?organizationId=&assetTypeId=&templateId=  form definition (template get)
//   GET  register/lookups?organizationId=&sources=  MASTER: picker values
//   POST register/evaluate                      live rules for the form (read-only)
//   POST register                               save (issues returned; 400 when not saved)
//   GET  register/{id}/lifecycle?organizationId=  status, open moves + gates, changes (429)
//   GET  register/lifecycle-matrix?organizationId=  every Asset transition with its BRD gate
//   POST register/{id}/transition               move to a status (completed or awaiting approval)
//   POST register/lifecycle-changes/{id}/decide APPROVE | REJECT | CANCEL a pending change
//   GET  register/{id}/technology?organizationId=  firmware / OS status, history, exceptions (430)
//   POST register/{id}/technology/installations  record a firmware / OS installation
//   POST register/{id}/technology/exceptions     request a technology exception
//   POST register/technology-exceptions/{id}/decide  APPROVE | REJECT | WITHDRAW | REVOKE
//   GET  register/{id}/custody?organizationId=   verification state, assignment history, attestations (431)
//   GET  attestation/profiles?organizationId=    profiles + scope picker
//   POST attestation/profiles                   add / edit a profile
//   GET  attestation/campaigns?organizationId=   recent runs / campaigns
//   POST attestation/generate                   periodic run or campaign (idempotent)
//   GET  attestation?organizationId=&scope=ALL|MINE|APPROVALS&status=&campaignId=&search=&pageNumber=&pageSize=
//   POST attestation/{id}/respond               CONFIRM | DISAGREE (assignee only)
//   POST attestation/{id}/decide                APPROVE | RETURN (manager) | CANCEL
//   GET  attestation/exceptions?organizationId=&scope=ALL|MINE&status=&search=&pageNumber=&pageSize=   (432)
//   GET  attestation/exceptions/{id}?organizationId=  exception + status history
//   POST attestation/exceptions/{id}/action      START_REVIEW | AWAIT_EVIDENCE | RESUME | RESOLVE | APPROVE | REJECT | CLOSE | REASSIGN | CANCEL
//   GET  attestation/exception-settings?organizationId=  settings + effective rules + pickers
//   POST attestation/exception-settings | attestation/exception-rules
//   GET  register/workflows/definitions?organizationId=   workflows, steps, building / floor / room options (433)
//   GET  register/workflows?organizationId=&assetId=&openOnly=   cases
//   GET  register/workflows/{caseId}?organizationId=      case + steps + history
//   POST register/{assetId}/workflows                     start a workflow
//   POST register/workflows/{caseId}/step                 COMPLETE | APPROVE | REJECT | CONFIRM | DECLINE
//   POST register/workflows/{caseId}/cancel               cancel (starter only)
//   GET  contracts?organizationId=&search=&status=&vendorId=&contractType=&pageNumber=&pageSize=   (434)
//   GET  contracts/lookups?organizationId=          vendors, vendor users, employees, types, roles, contracts
//   GET  contracts/{id}?organizationId=             summary, versions, contacts, documents, approvals, warnings, contact history
//   GET  contracts/versions/{versionId}?organizationId=   version details (contacts, documents, history, warnings)
//   GET  contracts/versions/compare?organizationId=&versionA=&versionB=   field + contact-role differences
//   POST contracts                                  create (Version 1 Draft) / edit a contract
//   POST contracts/{id}/versions                    new draft version
//   POST contracts/versions/{versionId}             save a Draft version
//   POST contracts/versions/{versionId}/action      SUBMIT | REVIEW | RETURN | REJECT | APPROVE | WITHDRAW
//   POST contracts/versions/{versionId}/documents   add a document reference
//   POST contracts/documents/{documentId}/remove    remove a document reference (Draft)
//   POST contracts/{id}/contacts                    add / edit a vendor contact mapping
//   POST contracts/contacts/{mappingId}/action      VALIDATE | END
//   GET  contracts/assets?organizationId=&search=&assetTypeId=&versionId=   asset picker (435)
//   GET  contracts/coverage-gaps?organizationId=&search=&coverageType=&pageNumber=&pageSize=
//   GET  contracts/coverage-config?organizationId=  settings, requirements, asset types, coverage types
//   GET  register/{id}/coverage?organizationId=     coverage status per type, lines, requirements / gaps
//   POST contracts/versions/{versionId}/entitlements | contracts/entitlements/{id}/remove
//   POST contracts/versions/{versionId}/coverage | .../coverage/bulk | contracts/coverage/{id}/remove
//   POST contracts/coverage-requirements | contracts/coverage-settings
//   GET  contracts/renewals?organizationId=&contractId=&status=&search=&pageNumber=&pageSize=   (436)
//   GET  contracts/renewals/due?organizationId=&withinDays=   contracts reaching their renewal date
//   GET  contracts/renewals/{id}?organizationId=    renewal + reconciliation + history + linkable versions
//   POST contracts/{id}/renewals                    start a renewal occurrence
//   POST contracts/renewals/{id}                    save an Open renewal
//   POST contracts/renewals/{id}/action             SUBMIT | APPROVE | RETURN | REOPEN | CREATE_VERSION | LINK_VERSION | COMPLETE | CANCEL
//   POST contracts/renewal-items/{itemId}/resolve   resolve an unresolved reconciliation item
//   GET  notifications/config?organizationId=       activities, recipient types, profiles, stages, matrix, roles (437)
//   POST notifications/profiles                     create / edit a profile with its stages and recipients
//   POST notifications/matrix                       replace the escalation matrix of one severity
//   GET  notifications/occurrences?organizationId=&status=&activityCode=&search=&pageNumber=&pageSize=
//   GET  notifications/occurrences/{id}?organizationId=   occurrence + stage schedule + notices
//   POST notifications/occurrences/{id}/snooze      snooze / reschedule (revised date + reason) or resume
//   GET  notifications/log?organizationId=&statusCode=&activityCode=&notificationClass=&search=&pageNumber=&pageSize=
//   POST notifications/log/{id}/delivery            a dispatcher reports SENT / FAILED
//   GET  notifications/runs?organizationId=         scheduler run log
//   POST notifications/run                          run the scheduler now for the organization
//   GET  notifications/mine?filter=&pageNumber=&pageSize=   the caller's own notices (no organization)
//   GET  notifications/mine/counts
//   POST notifications/mine/{id}/action             READ | ACKNOWLEDGE | CONFIRM
//   POST notifications/mine/read-all
//   GET  activities/config?organizationId=          templates with organization settings, employees (438)
//   POST activities/settings                        save the settings of one template
//   GET  activities/schedules?organizationId=&templateCode=&status=&search=&pageNumber=&pageSize=
//   GET  activities/occurrences?organizationId=&templateCode=&status=&reconcileOnly=&campaignId=&search=&pageNumber=&pageSize=
//   GET  activities/campaigns?organizationId=&pageNumber=&pageSize=
//   POST activities/occurrences/{id}/reconcile      record the reconciliation of a flagged occurrence
//   POST activities/run                             run the scheduler now for the organization (as notifications/run)
//   GET  activities/occurrences/{id}?organizationId=  occurrence, result, dispositions, reviews (439)
//   POST activities/occurrences/{id}/result          save / submit the result
//   POST activities/occurrences/{id}/result-decision APPROVE | RETURN a submitted result
//   POST activities/occurrences/{id}/disposition     request RESCHEDULE | WAIVE | NOT_APPLICABLE | EXCEPTION
//   POST activities/dispositions/{id}/decision       APPROVE | REJECT | WITHDRAW a request
//   GET  activities/reviews?organizationId=&status=&search=&pageNumber=&pageSize=   restrictive-use reviews
//   POST activities/reviews/{id}/decision            decide a review (action code + note)
//   GET  relationships/config?organizationId=        relationship types, employees (440)
//   GET  relationships/ci-lookup?organizationId=&kind=&search=   configuration-item picker
//   GET  relationships?organizationId=&ciKind=&ciId=&typeCode=&status=&criticalOnly=&pendingOnly=&search=&pageNumber=&pageSize=
//   GET  relationships/{id}?organizationId=          relationship and its history
//   POST relationships                               propose (relationshipId null) or change a relationship
//   POST relationships/{id}/action                   APPROVE | REJECT | WITHDRAW | DISPUTE | CONFIRM | RETIRE | ACCEPT_RETIREMENT
//   GET  relationships/impact?organizationId=&ciKind=&ciId=&direction=&maxDepth=&criticalOnly=&previewRelationshipId=
//        (441: adds the business services reached)
//   GET  business-services/config?organizationId=    settings, employees, departments, business functions, locations, criticalities (441)
//   GET  business-services?organizationId=&status=&serviceType=&search=&pageNumber=&pageSize=
//   GET  business-services/{id}?organizationId=      service, consumers, supporting items, supports, conflicts, history
//   POST business-services                           create (serviceId null) or change a service
//   POST business-services/{id}/transition           status change
//   POST business-services/{id}/retirement-decision  APPROVE | REJECT | WITHDRAW a pending retirement
//   POST business-services/settings                  organization settings
//   GET  business-services/conflicts?organizationId=&serviceId=&search=&pageNumber=&pageSize=
//   GET  business-services/tree?organizationId=      service hierarchy
//   GET  discovery/config?organizationId=            settings, sources with health, precedence, rules, employees, fields (442)
//   POST discovery/sources                           add / change a source
//   POST discovery/sources/{id}/priorities           field precedence of a source (replaces it)
//   POST discovery/sources/{id}/batches              ingest a batch (UI, import or API) -> batch + per-record results
//   POST discovery/rules                             add / change an identification rule
//   POST discovery/settings                          thresholds, stale multiplier, verification window, conflict tasks
//   GET  discovery/batches?organizationId=&sourceId=&pageNumber=&pageSize=
//   GET  discovery/batches/{id}?organizationId=      batch + records
//   GET  discovery/exceptions?organizationId=&status=&kind=&sourceId=&assetId=&search=&pageNumber=&pageSize=
//   POST discovery/exceptions/{id}/resolve           LINK | IGNORE | NOT_DUPLICATE | ACCEPT_OBSERVED | KEEP_CURRENT
//   GET  discovery/confidence?organizationId=&status=&search=&pageNumber=&pageSize=
//   GET  discovery/assets/{assetId}?organizationId=  confidence, links, values per source, open exceptions
//   GET  discovery/exceptions/{id}/candidate?organizationId=   exception + observed values for the register form (443)
//        (discovery/exceptions/{id}/resolve also takes REGISTER -- 443)
//   GET  discovery/stale?organizationId=&view=&search=&pageNumber=&pageSize=   aging rule + stale assets / closed reviews
//   GET  discovery/stale/assets/{assetId}?organizationId=   stale state + open review, links, dependencies, reviews
//   POST discovery/stale/settings                    aging rule
//   POST discovery/stale/reviews                     open a review on a stale asset
//   POST discovery/stale/reviews/{id}/action         CONFIRM_SOURCE | REVIEW_DEPENDENCIES | DISMISS | REQUEST_DECOMMISSION
//   GET  discovery/merges?organizationId=&status=&search=&pageNumber=&pageSize=   merge events (444)
//   GET  discovery/merges/{id}?organizationId=       event, assets, approvals, blockers, plan, outcomes, fields, impact
//   POST discovery/merges                            new / changed draft merge
//   POST discovery/merges/{id}/action                SUBMIT | CANCEL | APPROVE | REJECT | EXECUTE | RECOVER
//   GET  discovery/splits?organizationId=&status=&search=&pageNumber=&pageSize=   split events (445)
//   GET  discovery/splits/{id}?organizationId=       event, assets, approvals, blockers, plan / allocation, outcomes, impact
//   POST discovery/splits                            new / changed draft split (results, allocations)
//   POST discovery/splits/{id}/action                as merges (same procedure)
//   GET  register/{id}/valuation?organizationId=     Asset Value: current, state vs the Active configuration, history (446)
//   POST register/{id}/valuation/recalculate         recalculate one asset now (reason when the configuration changed)
//   POST register/{id}/valuation/method              asset-level method override (method or null, reason)
//   GET  valuation/recalculation?organizationId=     impact analysis: summary, category moves, affected assets, runs
//   POST valuation/recalculation                     controlled recalculation run (reason, expectedAffected)
//   GET  register/{id}/valuation now also returns risks (linked risks, review flag) and findings (447)
//   GET  valuation/consistency/rules?organizationId=  consistency rules, every version (447)
//   GET  valuation/consistency/rules/{id}?organizationId=   rule, conditions, versions
//   GET  valuation/consistency/rules/{id}/preview?organizationId=   in-scope and matching assets (bulk preview)
//   GET  valuation/consistency/operands?organizationId=   operands and scope choices
//   POST valuation/consistency/rules                 new rule (v1 Draft) or Draft change
//   POST valuation/consistency/rules/{id}/action     ACTIVATE | RETIRE | NEW_VERSION | DISCARD
//   GET  register/consistency/findings?organizationId=&status=&severity=&assetId=&search=&pageNumber=&pageSize=
//   POST register/consistency/findings/{id}/action   ACCEPT | WITHDRAW | APPROVE | REJECT | REVOKE
//   POST register/consistency/run                    re-evaluate one asset or the organization
//   GET  register/{id}/privacy?organizationId=       privacy status, gaps, exceptions, reviews of an asset (448)
//   GET  privacy/assets?organizationId=&status=&search=&pageNumber=&pageSize=   privacy register + counts
//   GET  privacy/assets/{id}?organizationId=         as register/{id}/privacy
//   GET  privacy/exceptions?organizationId=&status=&pageNumber=&pageSize=
//   GET  privacy/reviews?organizationId=&status=&kind=&pageNumber=&pageSize=
//   GET  privacy/requirements?organizationId=        requirements with settings, overrides, asset types, employees
//   POST privacy/requirements                        organization / asset-type setting of one requirement
//   POST privacy/exceptions                          request an exception for an open gap
//   POST privacy/exceptions/{id}/action              APPROVE | REJECT | WITHDRAW | REVOKE
//   POST privacy/reviews/{id}/complete               REVIEWED | DELETE | ARCHIVE | LEGAL_HOLD | EXTEND
//   POST privacy/run                                 refresh reviews and exception expiry
//   GET  governance?organizationId=&snapshotId=&trendDays=   KPI scorecard of a snapshot (default: current) + trend (450)
//   GET  governance/items?organizationId=&snapshotId=&kpiCode=&outcome=&search=&pageNumber=&pageSize=   record drill-down
//   GET  governance/snapshots?organizationId=&pageNumber=&pageSize=   every snapshot version
//   GET  governance/settings?organizationId=         KPI settings, overall thresholds, relationship requirements
//   POST governance/settings                         one KPI (enabled, weight, thresholds, period) or reset
//   POST governance/settings/overall                 overall thresholds and record-detail retention
//   POST governance/relationship-rules               relationship requirement of an asset type
//   POST governance/snapshot                         take a snapshot now
//   GET  reports?organizationId=                     report catalogue of the screens the caller may view (452)
//   GET  reports/{code}/run?organizationId=&search=&status=&assetTypeId=&dateFrom=&dateTo=&days=&pageNumber=&pageSize=
//                                                    one page of a report (columns, rows, totalRows)
//   POST reports/{code}/export                       governed CSV export: checks the export policy, records the export,
//                                                    returns the recorded heading, the columns and every row (max 50000)
//   GET  reports/exports?organizationId=&reportCode=&pageNumber=&pageSize=   export history
//   POST reports/settings                            organization setting of a report (enabled, classification, policy)
//   GET  reports/schedules?organizationId=           schedules, distribution lists, employees and roles (453)
//   POST reports/schedules                           create / change a schedule and its distribution list
//   POST reports/schedules/{id}/run                  deliver one schedule now (recipients checked as at a scheduled run)
//   GET  reports/deliveries?organizationId=&scheduleId=&pageNumber=&pageSize=   deliveries (distribution results)
//   GET  reports/deliveries/{id}/recipients?organizationId=   per recipient: delivered, skipped (reason), failed
//   GET  reports/deliveries/mine?organizationId=&pageNumber=&pageSize=   the caller delivered files
//   POST reports/deliveries/recipients/{id}/download download a delivered file (checked again, recorded as an export)
//
// The Web proxy (practice/api/asset-config) checks the session, the
// organization and the menu grant; it stamps X-PM-Caller-Employee-Id,
// which is the only source of the actor here. For reports (452) it also
// stamps X-PM-Caller-Report-Areas (the report screens the session may
// VIEW) and X-PM-Caller-Report-Approve (Asset Reports APPROVE); the
// procedures check every report against them.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/asset-config")]
public sealed class AssetConfigController(
    IAssetConfigService service,
    ILogger<AssetConfigController> logger) : ControllerBase
{
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";

    private long? ActorEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private string Actor => ActorEmployeeId is { } id ? $"employee:{id}" : "system";

    // ---------------------------------------------------------------- dictionary
    [HttpGet("field-groups")]
    public Task<IActionResult> FieldGroups(CancellationToken ct) =>
        ReadAsync(() => service.ListFieldGroupsAsync(ct), "field-groups");

    [HttpGet("field-definitions")]
    public Task<IActionResult> FieldDefinitions(
        [FromQuery] string? groupCode, [FromQuery] string? dataTypeCode, [FromQuery] string? sensitivityCode,
        [FromQuery] string? search, [FromQuery] bool? placeableOnly, [FromQuery] bool? includeRetired,
        [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct) =>
        ReadAsync(() => service.ListFieldDefinitionsAsync(groupCode, dataTypeCode, sensitivityCode, search,
            placeableOnly ?? false, includeRetired ?? false, pageNumber ?? 1, pageSize ?? 25, ct), "field-definitions");

    [HttpGet("taxonomy")]
    public Task<IActionResult> Taxonomy(CancellationToken ct) =>
        ReadAsync(async () => (object)await service.GetTaxonomyAsync(ct), "taxonomy");

    // ---------------------------------------------------------------- templates (read)
    [HttpGet("templates")]
    public Task<IActionResult> Templates(
        [FromQuery] long? organizationId, [FromQuery] int? assetTypeId, [FromQuery] string? statusCode,
        [FromQuery] string? search, [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListTemplatesAsync(organizationId.Value, assetTypeId, statusCode, search,
            pageNumber ?? 1, pageSize ?? 25, ct), "templates");
    }

    [HttpGet("templates/{id:long}")]
    public async Task<IActionResult> Template(long id, [FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var detail = await service.GetTemplateAsync(organizationId.Value, id, ct);
            return detail is null ? NotFound(new { error = "Asset form template not found." }) : Ok(new { data = detail });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "AssetConfig template {Id} read failed", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("templates/{id:long}/readiness")]
    public async Task<IActionResult> Readiness(long id, [FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var result = await service.GetReadinessAsync(organizationId.Value, id, ct);
            return result is null ? NotFound(new { error = "Asset form template not found." }) : Ok(new { data = result });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "AssetConfig readiness {Id} failed", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ---------------------------------------------------------------- templates (write)
    [HttpPost("templates")]
    public async Task<IActionResult> Create([FromBody] AssetTemplateCreateRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.AssetTypeId <= 0) return BadRequest(new { error = "assetTypeId is required." });
        return Written(await service.CreateTemplateAsync(request, ActorEmployeeId, Actor, ct));
    }

    [HttpPost("templates/{id:long}/new-version")]
    public async Task<IActionResult> NewVersion(long id, [FromBody] AssetTemplateNewVersionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Written(await service.NewVersionAsync(id, request, ActorEmployeeId, Actor, ct));
    }

    [HttpPost("templates/{id:long}/header")]
    public async Task<IActionResult> Header(long id, [FromBody] AssetTemplateHeaderSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Written(await service.SaveHeaderAsync(id, request, Actor, ct));
    }

    [HttpPost("templates/{id:long}/sections")]
    public async Task<IActionResult> Section(long id, [FromBody] AssetTemplateSectionSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Written(await service.SaveSectionAsync(id, request, Actor, ct));
    }

    [HttpPost("templates/{id:long}/fields")]
    public async Task<IActionResult> Field(long id, [FromBody] AssetTemplateFieldSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.FieldDefinitionId <= 0 || request.SectionId <= 0)
            return BadRequest(new { error = "fieldDefinitionId and sectionId are required." });
        return Written(await service.SaveFieldAsync(id, request, Actor, ct));
    }

    [HttpPost("templates/{id:long}/fields/remove")]
    public async Task<IActionResult> RemoveField(long id, [FromBody] AssetTemplateFieldRemoveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.FieldDefinitionId <= 0) return BadRequest(new { error = "fieldDefinitionId is required." });
        return Written(await service.RemoveFieldAsync(id, request, Actor, ct));
    }

    [HttpPost("templates/{id:long}/transition")]
    public async Task<IActionResult> Transition(long id, [FromBody] AssetTemplateTransitionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.ToStatusCode)) return BadRequest(new { error = "toStatusCode is required." });
        return Written(await service.TransitionAsync(id, request, ActorEmployeeId, Actor, ct));
    }

    // ---------------------------------------------------------------- 421: rules + preview
    [HttpPost("templates/{id:long}/rules")]
    public async Task<IActionResult> SaveRule(long id, [FromBody] AssetTemplateRuleSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.TargetFieldDefinitionId <= 0) return BadRequest(new { error = "targetFieldDefinitionId is required." });
        return Written(await service.SaveRuleAsync(id, request, Actor, ct));
    }

    [HttpPost("templates/{id:long}/rules/remove")]
    public async Task<IActionResult> RemoveRule(long id, [FromBody] AssetTemplateRuleRemoveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.RuleId <= 0) return BadRequest(new { error = "ruleId is required." });
        return Written(await service.RemoveRuleAsync(id, request, Actor, ct));
    }

    [HttpPost("templates/{id:long}/evaluate")]
    public async Task<IActionResult> Evaluate(long id, [FromBody] AssetTemplateEvaluateRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var result = await service.EvaluateAsync(id, request, ct);
            return result is null ? NotFound(new { error = "Asset form template not found." }) : Ok(new { data = result });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "AssetConfig evaluate {Id} failed", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ---------------------------------------------------------------- 422: asset valuation
    [HttpGet("valuation")]
    public Task<IActionResult> Valuations([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListValuationAsync(organizationId.Value, ct), "valuation");
    }

    [HttpGet("valuation/{id:long}")]
    public async Task<IActionResult> Valuation(long id, [FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var detail = await service.GetValuationAsync(organizationId.Value, id, ct);
            return detail is null ? NotFound(new { error = "Valuation configuration not found." }) : Ok(new { data = detail });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "AssetConfig valuation {Id} read failed", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("valuation/{id:long}/readiness")]
    public async Task<IActionResult> ValuationReadiness(long id, [FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var result = await service.GetValuationReadinessAsync(organizationId.Value, id, ct);
            return result is null ? NotFound(new { error = "Valuation configuration not found." }) : Ok(new { data = result });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "AssetConfig valuation readiness {Id} failed", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("valuation")]
    public async Task<IActionResult> CreateValuation([FromBody] AssetValuationCreateRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Written(await service.CreateValuationAsync(request, ActorEmployeeId, Actor, ct));
    }

    [HttpPost("valuation/{id:long}/header")]
    public async Task<IActionResult> ValuationHeader(long id, [FromBody] AssetValuationHeaderSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Written(await service.SaveValuationHeaderAsync(id, request, Actor, ct));
    }

    [HttpPost("valuation/{id:long}/items")]
    public async Task<IActionResult> ValuationItem(long id, [FromBody] AssetValuationItemSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.ItemKind)) return BadRequest(new { error = "itemKind is required." });
        return Written(await service.SaveValuationItemAsync(id, request, Actor, ct));
    }

    [HttpPost("valuation/{id:long}/transition")]
    public async Task<IActionResult> ValuationTransition(long id, [FromBody] AssetValuationTransitionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.ToStatusCode)) return BadRequest(new { error = "toStatusCode is required." });
        return Written(await service.TransitionValuationAsync(id, request, ActorEmployeeId, Actor, ct));
    }

    [HttpPost("valuation/{id:long}/calculate")]
    public async Task<IActionResult> ValuationCalculate(long id, [FromBody] AssetValuationCalculateRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var result = await service.CalculateValuationAsync(id, request, ct);
            return result is null ? NotFound(new { error = "Valuation configuration not found." }) : Ok(new { data = result });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "AssetConfig valuation calculate {Id} failed", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ---------------------------------------------------------------- 423: option lists
    [HttpGet("option-lists")]
    public Task<IActionResult> OptionLists([FromQuery] long? organizationId, [FromQuery] string? search, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListOptionListsAsync(organizationId.Value, search, ct), "option-lists");
    }

    [HttpGet("option-lists/{group}")]
    public async Task<IActionResult> OptionList(string group, [FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(group)) return BadRequest(new { error = "option group is required." });
        try
        {
            var detail = await service.GetOptionListAsync(organizationId.Value, group.Trim(), ct);
            return detail is null ? NotFound(new { error = "Option list not found." }) : Ok(new { data = detail });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "AssetConfig option list {Group} read failed", group);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("option-lists/{group}/values")]
    public async Task<IActionResult> SaveOrgOption(string group, [FromBody] AssetOptionOrgSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.OptionLabel)) return BadRequest(new { error = "optionLabel is required." });
        return Written(await service.SaveOrgOptionAsync(group.Trim(), request, Actor, ct));
    }

    [HttpPost("option-lists/{group}/override")]
    public async Task<IActionResult> OverrideOption(string group, [FromBody] AssetOptionOverrideRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.OptionValue)) return BadRequest(new { error = "optionValue is required." });
        return Written(await service.OverrideOptionAsync(group.Trim(), request, Actor, ct));
    }

    // ---------------------------------------------------------------- 424: taxonomy governance
    [HttpGet("taxonomy/governance")]
    public async Task<IActionResult> TaxonomyGovernance([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var data = await service.GetTaxonomyGovernanceAsync(organizationId.Value, ct);
            return data is null ? NotFound(new { error = "Organization not found." }) : Ok(new { data });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "AssetConfig taxonomy governance read failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("taxonomy/categories")]
    public async Task<IActionResult> SaveTaxonomyCategory([FromBody] AssetTaxonomyCategorySaveRequest request, CancellationToken ct)
    {
        if (request is null || string.IsNullOrWhiteSpace(request.CategoryName)) return BadRequest(new { error = "categoryName is required." });
        return Written(await service.SaveTaxonomyCategoryAsync(request, Actor, ct));
    }

    [HttpPost("taxonomy/subcategories")]
    public async Task<IActionResult> SaveTaxonomySubcategory([FromBody] AssetTaxonomySubcategorySaveRequest request, CancellationToken ct)
    {
        if (request is null || request.CategoryId <= 0) return BadRequest(new { error = "categoryId is required." });
        if (string.IsNullOrWhiteSpace(request.SubcategoryName)) return BadRequest(new { error = "subcategoryName is required." });
        return Written(await service.SaveTaxonomySubcategoryAsync(request, Actor, ct));
    }

    [HttpPost("taxonomy/types")]
    public async Task<IActionResult> SaveTaxonomyType([FromBody] AssetTaxonomyTypeSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.SubcategoryId <= 0) return BadRequest(new { error = "subcategoryId is required." });
        if (string.IsNullOrWhiteSpace(request.AssetTypeName)) return BadRequest(new { error = "assetTypeName is required." });
        return Written(await service.SaveTaxonomyTypeAsync(request, Actor, ct));
    }

    [HttpPost("taxonomy/types/{id:int}/org-defaults")]
    public async Task<IActionResult> SaveTypeOrgDefault(int id, [FromBody] AssetTypeOrgDefaultSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Written(await service.SaveTypeOrgDefaultAsync(id, request, Actor, ct));
    }

    // ---------------------------------------------------------------- 425: technology catalogue
    [HttpGet("tech-catalog")]
    public async Task<IActionResult> TechCatalog([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var data = await service.GetTechCatalogAsync(organizationId.Value, ct);
            return data is null ? NotFound(new { error = "Organization not found." }) : Ok(new { data });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "AssetConfig technology catalogue read failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("tech-catalog/models/{id:long}")]
    public async Task<IActionResult> TechModel(long id, [FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var data = await service.GetModelAsync(organizationId.Value, id, ct);
            return data is null ? NotFound(new { error = "Model not found." }) : Ok(new { data });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "AssetConfig model {Id} read failed", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("tech-catalog/makes")]
    public async Task<IActionResult> SaveMake([FromBody] AssetMakeSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.MakeName)) return BadRequest(new { error = "makeName is required." });
        return Written(await service.SaveMakeAsync(request, Actor, ct));
    }

    [HttpPost("tech-catalog/models")]
    public async Task<IActionResult> SaveModel([FromBody] AssetModelSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.MakeId <= 0 || request.AssetTypeId <= 0) return BadRequest(new { error = "makeId and assetTypeId are required." });
        if (string.IsNullOrWhiteSpace(request.ModelName)) return BadRequest(new { error = "modelName is required." });
        return Written(await service.SaveModelAsync(request, ActorEmployeeId, Actor, ct));
    }

    [HttpPost("tech-catalog/models/{id:long}/transition")]
    public async Task<IActionResult> TransitionModel(long id, [FromBody] AssetCatalogTransitionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.ToStatusCode)) return BadRequest(new { error = "toStatusCode is required." });
        return Written(await service.TransitionModelAsync(id, request, ActorEmployeeId, Actor, ct));
    }

    // ---------------------------------------------------------------- 426: firmware
    [HttpGet("tech-catalog/firmware")]
    public Task<IActionResult> FirmwareCatalog([FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetFirmwareCatalogAsync(o, ct), "Organization not found.", "firmware catalogue");

    [HttpGet("tech-catalog/firmware/releases/{id:long}")]
    public Task<IActionResult> FirmwareRelease(long id, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetFirmwareReleaseAsync(o, id, ct), "Firmware release not found.", "firmware release");

    [HttpGet("tech-catalog/models/{id:long}/firmware")]
    public Task<IActionResult> ModelFirmware(long id, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetModelFirmwareAsync(o, id, ct), "Model not found.", "model firmware");

    [HttpPost("tech-catalog/firmware/products")]
    public async Task<IActionResult> SaveFirmwareProduct([FromBody] AssetFirmwareProductSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.PublisherMakeId <= 0 || string.IsNullOrWhiteSpace(request.ProductName))
            return BadRequest(new { error = "publisherMakeId and productName are required." });
        return Written(await service.SaveFirmwareProductAsync(request, Actor, ct));
    }

    [HttpPost("tech-catalog/firmware/releases")]
    public async Task<IActionResult> SaveFirmwareRelease([FromBody] AssetFirmwareReleaseSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.ProductId <= 0 || string.IsNullOrWhiteSpace(request.Version))
            return BadRequest(new { error = "productId and version are required." });
        return Written(await service.SaveFirmwareReleaseAsync(request, ActorEmployeeId, Actor, ct));
    }

    [HttpPost("tech-catalog/firmware/releases/{id:long}/transition")]
    public async Task<IActionResult> TransitionFirmwareRelease(long id, [FromBody] AssetCatalogTransitionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.ToStatusCode)) return BadRequest(new { error = "toStatusCode is required." });
        return Written(await service.TransitionFirmwareReleaseAsync(id, request, ActorEmployeeId, Actor, ct));
    }

    [HttpPost("tech-catalog/firmware/compatibility")]
    public async Task<IActionResult> SaveFirmwareCompat([FromBody] AssetFirmwareCompatSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.ReleaseId <= 0 || request.AssetTypeId <= 0) return BadRequest(new { error = "releaseId and assetTypeId are required." });
        return Written(await service.SaveFirmwareCompatAsync(request, Actor, ct));
    }

    [HttpPost("tech-catalog/firmware/compatibility/{id:long}/approve")]
    public async Task<IActionResult> ApproveFirmwareCompat(long id, [FromBody] AssetCatalogApproveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Written(await service.ApproveFirmwareCompatAsync(id, request, Actor, ct));
    }

    // ---------------------------------------------------------------- 427: operating systems
    [HttpGet("tech-catalog/os")]
    public Task<IActionResult> OsCatalog([FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetOsCatalogAsync(o, ct), "Organization not found.", "OS catalogue");

    [HttpGet("tech-catalog/os/releases/{id:long}")]
    public Task<IActionResult> OsRelease(long id, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetOsReleaseAsync(o, id, ct), "Operating-system release not found.", "OS release");

    [HttpGet("tech-catalog/models/{id:long}/os")]
    public Task<IActionResult> ModelOs(long id, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetModelOsAsync(o, id, ct), "Model not found.", "model OS");

    [HttpPost("tech-catalog/os/products")]
    public async Task<IActionResult> SaveOsProduct([FromBody] AssetOsProductSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.PublisherMakeId <= 0 || string.IsNullOrWhiteSpace(request.ProductName))
            return BadRequest(new { error = "publisherMakeId and productName are required." });
        return Written(await service.SaveOsProductAsync(request, Actor, ct));
    }

    [HttpPost("tech-catalog/os/releases")]
    public async Task<IActionResult> SaveOsRelease([FromBody] AssetOsReleaseSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.ProductId <= 0 || string.IsNullOrWhiteSpace(request.Version))
            return BadRequest(new { error = "productId and version are required." });
        return Written(await service.SaveOsReleaseAsync(request, ActorEmployeeId, Actor, ct));
    }

    [HttpPost("tech-catalog/os/releases/{id:long}/transition")]
    public async Task<IActionResult> TransitionOsRelease(long id, [FromBody] AssetCatalogTransitionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.ToStatusCode)) return BadRequest(new { error = "toStatusCode is required." });
        return Written(await service.TransitionOsReleaseAsync(id, request, ActorEmployeeId, Actor, ct));
    }

    [HttpPost("tech-catalog/os/compatibility")]
    public async Task<IActionResult> SaveOsCompat([FromBody] AssetOsCompatSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.ReleaseId <= 0 || request.AssetTypeId <= 0) return BadRequest(new { error = "releaseId and assetTypeId are required." });
        return Written(await service.SaveOsCompatAsync(request, Actor, ct));
    }

    [HttpPost("tech-catalog/os/compatibility/{id:long}/approve")]
    public async Task<IActionResult> ApproveOsCompat(long id, [FromBody] AssetCatalogApproveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Written(await service.ApproveOsCompatAsync(id, request, Actor, ct));
    }

    // ---------------------------------------------------------------- 428: Asset Register
    [HttpGet("register")]
    public Task<IActionResult> Register([FromQuery] long? organizationId, [FromQuery] string? search, [FromQuery] int? assetTypeId,
        [FromQuery] string? statusCode, [FromQuery] int? pageNumber, [FromQuery] int? pageSize, [FromQuery] bool? pendingOnly,
        CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListRegisterAsync(organizationId.Value, search, assetTypeId, statusCode,
            pageNumber ?? 1, pageSize ?? 25, pendingOnly ?? false, ct), "register");
    }

    [HttpGet("register/{id:long}")]
    public Task<IActionResult> RegisterAsset(long id, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetRegisterAssetAsync(o, id, ct), "Asset not found.", "register asset");

    [HttpGet("register/form")]
    public async Task<IActionResult> RegisterForm([FromQuery] long? organizationId, [FromQuery] int? assetTypeId,
        [FromQuery] long? templateId, CancellationToken ct)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        if (assetTypeId is null && templateId is null) return BadRequest(new { error = "assetTypeId or templateId is required." });
        try
        {
            var data = await service.GetRegisterFormAsync(organizationId.Value, assetTypeId, templateId, ct);
            return data is null ? NotFound(new { error = "Form template not found." }) : Ok(new { data });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number is 54955 or 54202)
        {
            return NotFound(new { error = ex.Message, errorNumber = ex.Number });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "AssetConfig register form read failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("register/lookups")]
    public Task<IActionResult> RegisterLookups([FromQuery] long? organizationId, [FromQuery] string? sources, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetRegisterLookupsAsync(organizationId.Value, sources, ct), "register lookups");
    }

    [HttpPost("register/evaluate")]
    public async Task<IActionResult> RegisterEvaluate([FromBody] AssetRegisterEvaluateRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0 || request.TemplateId <= 0)
            return BadRequest(new { error = "organizationId and templateId are required." });
        try
        {
            var result = await service.EvaluateAsync(request.TemplateId, new AssetTemplateEvaluateRequest(request.OrganizationId, request.Values), ct);
            return result is null ? NotFound(new { error = "Asset form template not found." }) : Ok(new { data = result });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "AssetConfig register evaluate failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("register")]
    public async Task<IActionResult> RegisterSave([FromBody] AssetRegisterSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var r = await service.SaveRegisterAssetAsync(request, ActorEmployeeId, Actor, ct);
        var body = new { success = r.Result == "SAVED", result = r.Result, id = r.AssetId, issues = r.Issues, error = r.Error, errorNumber = r.ErrorNumber };
        return r.Result switch
        {
            "SAVED" => Ok(body),
            "REFUSED" => r.ErrorNumber switch
            {
                54950 or 54951 or 54955 => NotFound(body),
                54952 => Conflict(body),
                _ => BadRequest(body)
            },
            _ => BadRequest(body)       // INVALID / NEEDS_DECISION: the issues say what to fix or decide
        };
    }

    // ---------------------------------------------------------------- 429: lifecycle transitions
    [HttpGet("register/{id:long}/lifecycle")]
    public Task<IActionResult> AssetLifecycle(long id, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetAssetLifecycleAsync(o, id, ct), "Asset not found.", "asset lifecycle");

    [HttpGet("register/lifecycle-matrix")]
    public Task<IActionResult> LifecycleMatrix([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetLifecycleMatrixAsync(ct), "lifecycle matrix");
    }

    [HttpPost("register/{id:long}/transition")]
    public async Task<IActionResult> TransitionAsset(long id, [FromBody] AssetLifecycleTransitionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.ToStatusCode)) return BadRequest(new { error = "toStatusCode is required." });
        return ResultWritten(await service.TransitionAssetAsync(id, request, ActorEmployeeId, Actor, ct), LifecycleNotFound, LifecycleConflict);
    }

    [HttpPost("register/lifecycle-changes/{id:long}/decide")]
    public async Task<IActionResult> DecideLifecycleChange(long id, [FromBody] AssetLifecycleDecisionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Decision)) return BadRequest(new { error = "decision is required." });
        return ResultWritten(await service.DecideLifecycleChangeAsync(id, request, ActorEmployeeId, Actor, ct), LifecycleNotFound, LifecycleConflict);
    }

    // ---------------------------------------------------------------- 430: installed technology
    [HttpGet("register/{id:long}/technology")]
    public Task<IActionResult> AssetTechnology(long id, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetAssetTechnologyAsync(o, id, ct), "Asset not found.", "asset technology");

    [HttpPost("register/{id:long}/technology/installations")]
    public async Task<IActionResult> RecordInstallation(long id, [FromBody] AssetTechInstallRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Kind) || request.ReleaseId <= 0) return BadRequest(new { error = "kind and releaseId are required." });
        return ResultWritten(await service.RecordInstallationAsync(id, request, ActorEmployeeId, Actor, ct), TechNotFound, TechConflict);
    }

    [HttpPost("register/{id:long}/technology/exceptions")]
    public async Task<IActionResult> RequestTechException(long id, [FromBody] AssetTechExceptionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Kind) || request.ReleaseId <= 0) return BadRequest(new { error = "kind and releaseId are required." });
        return ResultWritten(await service.RequestTechExceptionAsync(id, request, ActorEmployeeId, Actor, ct), TechNotFound, TechConflict);
    }

    [HttpPost("register/technology-exceptions/{id:long}/decide")]
    public async Task<IActionResult> DecideTechException(long id, [FromBody] AssetLifecycleDecisionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Decision)) return BadRequest(new { error = "decision is required." });
        return ResultWritten(await service.DecideTechExceptionAsync(id, request, ActorEmployeeId, Actor, ct), TechNotFound, TechConflict);
    }

    // ---------------------------------------------------------------- 431: custody and attestation
    [HttpGet("register/{id:long}/custody")]
    public Task<IActionResult> AssetCustody(long id, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetAssetCustodyAsync(o, id, ct), "Asset not found.", "asset custody");

    [HttpGet("attestation/profiles")]
    public Task<IActionResult> AttestationProfiles([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetAttestationProfilesAsync(organizationId.Value, ct), "attestation profiles");
    }

    [HttpPost("attestation/profiles")]
    public async Task<IActionResult> SaveAttestationProfile([FromBody] AssetAttestationProfileSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.ScopeKind) || request.ScopeId <= 0) return BadRequest(new { error = "scopeKind and scopeId are required." });
        return Written(await service.SaveAttestationProfileAsync(request, Actor, ct));
    }

    [HttpGet("attestation/campaigns")]
    public Task<IActionResult> AttestationCampaigns([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetAttestationCampaignsAsync(organizationId.Value, ct), "attestation campaigns");
    }

    [HttpPost("attestation/generate")]
    public async Task<IActionResult> GenerateAttestations([FromBody] AssetAttestationGenerateRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var (data, number, error) = await service.GenerateAttestationsAsync(request, Actor, ct);
        if (number is null) return Ok(new { success = true, data });
        var body = new { success = false, error, errorNumber = number };
        return number == 54350 ? NotFound(body) : BadRequest(body);
    }

    [HttpGet("attestation")]
    public Task<IActionResult> Attestations([FromQuery] long? organizationId, [FromQuery] string? scope, [FromQuery] string? status,
        [FromQuery] long? campaignId, [FromQuery] string? search, [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListAttestationsAsync(organizationId.Value, scope, status, campaignId, search, ActorEmployeeId,
            pageNumber ?? 1, pageSize ?? 25, ct), "attestations");
    }

    [HttpPost("attestation/{id:long}/respond")]
    public async Task<IActionResult> RespondAttestation(long id, [FromBody] AssetAttestationRespondRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Response)) return BadRequest(new { error = "response is required." });
        return ResultWritten(await service.RespondAttestationAsync(id, request, ActorEmployeeId, Actor, ct), AttestationNotFound, AttestationConflict);
    }

    [HttpPost("attestation/{id:long}/decide")]
    public async Task<IActionResult> DecideAttestation(long id, [FromBody] AssetLifecycleDecisionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Decision)) return BadRequest(new { error = "decision is required." });
        return ResultWritten(await service.DecideAttestationAsync(id, request, ActorEmployeeId, Actor, ct), AttestationNotFound, AttestationConflict);
    }

    // ---------------------------------------------------------------- 432: verification exceptions
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

    // ---------------------------------------------------------------- 433: asset workflows
    [HttpGet("register/workflows/definitions")]
    public Task<IActionResult> WorkflowDefinitions([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetWorkflowDefinitionsAsync(organizationId.Value, ct), "workflow definitions");
    }

    [HttpGet("register/workflows")]
    public Task<IActionResult> WorkflowCases([FromQuery] long? organizationId, [FromQuery] long? assetId, [FromQuery] bool? openOnly, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListWorkflowCasesAsync(organizationId.Value, assetId, openOnly ?? true, ActorEmployeeId, ct), "workflow cases");
    }

    [HttpGet("register/workflows/{caseId:long}")]
    public Task<IActionResult> WorkflowCase(long caseId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetWorkflowCaseAsync(o, caseId, ActorEmployeeId, ct), "Workflow case not found.", "workflow case");

    [HttpPost("register/{assetId:long}/workflows")]
    public async Task<IActionResult> StartWorkflow(long assetId, [FromBody] AssetWorkflowStartRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.WorkflowCode)) return BadRequest(new { error = "workflowCode is required." });
        return ResultWritten(await service.StartWorkflowAsync(assetId, request, ActorEmployeeId, Actor, ct), WorkflowNotFound, WorkflowConflict);
    }

    [HttpPost("register/workflows/{caseId:long}/step")]
    public async Task<IActionResult> WorkflowStep(long caseId, [FromBody] AssetWorkflowStepRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Action)) return BadRequest(new { error = "action is required." });
        return ResultWritten(await service.WorkflowStepAsync(caseId, request, ActorEmployeeId, Actor, ct), WorkflowNotFound, WorkflowConflict);
    }

    [HttpPost("register/workflows/{caseId:long}/cancel")]
    public async Task<IActionResult> CancelWorkflow(long caseId, [FromBody] AssetWorkflowCancelRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.CancelWorkflowAsync(caseId, request, ActorEmployeeId, Actor, ct), WorkflowNotFound, WorkflowConflict);
    }

    // 433: 54450 / 54451 / 54470 -> 404; 54453 (stale), 54455 (open case) and 54456 (pending lifecycle change) -> 409.
    private static readonly int[] WorkflowNotFound = { 54450, 54451, 54470 };
    private static readonly int[] WorkflowConflict = { 54453, 54455, 54456 };

    // ---------------------------------------------------------------- 434: contracts
    [HttpGet("contracts")]
    public Task<IActionResult> Contracts([FromQuery] long? organizationId, [FromQuery] string? search, [FromQuery] string? status,
        [FromQuery] long? vendorId, [FromQuery] string? contractType, [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListContractsAsync(organizationId.Value, search, status, vendorId, contractType,
            pageNumber ?? 1, pageSize ?? 25, ct), "contracts");
    }

    [HttpGet("contracts/lookups")]
    public Task<IActionResult> ContractLookups([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetContractLookupsAsync(organizationId.Value, ct), "contract lookups");
    }

    [HttpGet("contracts/{contractId:long}")]
    public Task<IActionResult> Contract(long contractId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetContractAsync(o, contractId, ActorEmployeeId, ct), "Contract not found.", "contract");

    [HttpGet("contracts/versions/{versionId:long}")]
    public Task<IActionResult> ContractVersion(long versionId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetContractVersionAsync(o, versionId, ActorEmployeeId, ct), "Contract version not found.", "contract version");

    [HttpGet("contracts/versions/compare")]
    public Task<IActionResult> CompareContractVersions([FromQuery] long? organizationId, [FromQuery] long? versionA, [FromQuery] long? versionB, CancellationToken ct)
    {
        if (versionA is null or <= 0 || versionB is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "versionA and versionB are required." }));
        return ReadOrNotFound(organizationId, o => service.CompareContractVersionsAsync(o, versionA.Value, versionB.Value, ActorEmployeeId, Actor, ct),
            "Select two different versions of the same contract.", "contract version comparison");
    }

    [HttpPost("contracts")]
    public async Task<IActionResult> SaveContract([FromBody] AssetContractSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveContractAsync(request, ActorEmployeeId, Actor, ct), ContractNotFound, ContractConflict);
    }

    [HttpPost("contracts/{contractId:long}/versions")]
    public async Task<IActionResult> CreateContractVersion(long contractId, [FromBody] AssetContractVersionCreateRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.VersionType)) return BadRequest(new { error = "versionType is required." });
        return ResultWritten(await service.CreateContractVersionAsync(contractId, request, ActorEmployeeId, Actor, ct), ContractNotFound, ContractConflict);
    }

    [HttpPost("contracts/versions/{versionId:long}")]
    public async Task<IActionResult> SaveContractVersion(long versionId, [FromBody] AssetContractVersionSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveContractVersionAsync(versionId, request, ActorEmployeeId, Actor, ct), ContractNotFound, ContractConflict);
    }

    [HttpPost("contracts/versions/{versionId:long}/action")]
    public async Task<IActionResult> ContractVersionAction(long versionId, [FromBody] AssetContractVersionActionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Action)) return BadRequest(new { error = "action is required." });
        return ResultWritten(await service.ContractVersionActionAsync(versionId, request, ActorEmployeeId, Actor, ct), ContractNotFound, ContractConflict);
    }

    [HttpPost("contracts/versions/{versionId:long}/documents")]
    public async Task<IActionResult> AddContractDocument(long versionId, [FromBody] AssetContractDocumentRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.AddContractDocumentAsync(versionId, request, Actor, ct), ContractNotFound, ContractConflict);
    }

    [HttpPost("contracts/documents/{documentId:long}/remove")]
    public async Task<IActionResult> RemoveContractDocument(long documentId, [FromBody] AssetContractDocumentRemoveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.RemoveContractDocumentAsync(documentId, request, Actor, ct), ContractNotFound, ContractConflict);
    }

    [HttpPost("contracts/{contractId:long}/contacts")]
    public async Task<IActionResult> SaveContractContact(long contractId, [FromBody] AssetContractContactSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveContractContactAsync(contractId, request, ActorEmployeeId, Actor, ct), ContractNotFound, ContractConflict);
    }

    [HttpPost("contracts/contacts/{mappingId:long}/action")]
    public async Task<IActionResult> ContractContactAction(long mappingId, [FromBody] AssetContractContactActionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Action)) return BadRequest(new { error = "action is required." });
        return ResultWritten(await service.ContractContactActionAsync(mappingId, request, ActorEmployeeId, Actor, ct), ContractNotFound, ContractConflict);
    }

    // ---------------------------------------------------------------- 435: coverage and entitlements
    [HttpGet("contracts/assets")]
    public Task<IActionResult> ContractAssets([FromQuery] long? organizationId, [FromQuery] string? search, [FromQuery] int? assetTypeId,
        [FromQuery] long? versionId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.SearchContractAssetsAsync(organizationId.Value, search, assetTypeId, versionId, ct), "contract assets");
    }

    [HttpGet("contracts/coverage-gaps")]
    public Task<IActionResult> CoverageGaps([FromQuery] long? organizationId, [FromQuery] string? search, [FromQuery] string? coverageType,
        [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListCoverageGapsAsync(organizationId.Value, search, coverageType, pageNumber ?? 1, pageSize ?? 25, ct), "coverage gaps");
    }

    [HttpGet("contracts/coverage-config")]
    public Task<IActionResult> CoverageConfig([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetCoverageConfigAsync(organizationId.Value, ct), "coverage configuration");
    }

    [HttpGet("register/{assetId:long}/coverage")]
    public Task<IActionResult> AssetCoverage(long assetId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetAssetCoverageAsync(o, assetId, ct), "Asset not found.", "asset coverage");

    [HttpPost("contracts/versions/{versionId:long}/entitlements")]
    public async Task<IActionResult> SaveEntitlement(long versionId, [FromBody] AssetContractEntitlementRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveEntitlementAsync(versionId, request, Actor, ct), CoverageNotFound, CoverageConflict);
    }

    [HttpPost("contracts/entitlements/{entitlementId:long}/remove")]
    public async Task<IActionResult> RemoveEntitlement(long entitlementId, [FromBody] AssetContractLineRemoveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.RemoveEntitlementAsync(entitlementId, request, Actor, ct), CoverageNotFound, CoverageConflict);
    }

    [HttpPost("contracts/versions/{versionId:long}/coverage")]
    public async Task<IActionResult> SaveCoverage(long versionId, [FromBody] AssetContractCoverageRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveCoverageAsync(versionId, request, Actor, ct), CoverageNotFound, CoverageConflict);
    }

    [HttpPost("contracts/versions/{versionId:long}/coverage/bulk")]
    public async Task<IActionResult> BulkAddCoverage(long versionId, [FromBody] AssetContractCoverageBulkRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.AssetIds is null || request.AssetIds.Length == 0) return BadRequest(new { error = "assetIds is required." });
        return ResultWritten(await service.BulkAddCoverageAsync(versionId, request, Actor, ct), CoverageNotFound, CoverageConflict);
    }

    [HttpPost("contracts/coverage/{coverageId:long}/remove")]
    public async Task<IActionResult> RemoveCoverage(long coverageId, [FromBody] AssetContractLineRemoveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.RemoveCoverageAsync(coverageId, request, Actor, ct), CoverageNotFound, CoverageConflict);
    }

    [HttpPost("contracts/coverage-requirements")]
    public async Task<IActionResult> SaveCoverageRequirement([FromBody] AssetCoverageRequirementRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveCoverageRequirementAsync(request, Actor, ct), CoverageNotFound, CoverageConflict);
    }

    [HttpPost("contracts/coverage-settings")]
    public async Task<IActionResult> SaveCoverageSettings([FromBody] AssetCoverageSettingsRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveCoverageSettingsAsync(request, Actor, ct), CoverageNotFound, CoverageConflict);
    }

    // ---------------------------------------------------------------- 436: renewal occurrences
    [HttpGet("contracts/renewals")]
    public Task<IActionResult> Renewals([FromQuery] long? organizationId, [FromQuery] long? contractId, [FromQuery] string? status,
        [FromQuery] string? search, [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListRenewalsAsync(organizationId.Value, contractId, status, search, pageNumber ?? 1, pageSize ?? 25, ct), "renewals");
    }

    [HttpGet("contracts/renewals/due")]
    public Task<IActionResult> RenewalsDue([FromQuery] long? organizationId, [FromQuery] int? withinDays, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListRenewalsDueAsync(organizationId.Value, withinDays ?? 90, ct), "renewals due");
    }

    [HttpGet("contracts/renewals/{renewalId:long}")]
    public Task<IActionResult> Renewal(long renewalId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetRenewalAsync(o, renewalId, ActorEmployeeId, ct), "Renewal not found.", "renewal");

    [HttpPost("contracts/{contractId:long}/renewals")]
    public async Task<IActionResult> StartRenewal(long contractId, [FromBody] AssetContractRenewalStartRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.StartRenewalAsync(contractId, request, ActorEmployeeId, Actor, ct), RenewalNotFound, RenewalConflict);
    }

    [HttpPost("contracts/renewals/{renewalId:long}")]
    public async Task<IActionResult> SaveRenewal(long renewalId, [FromBody] AssetContractRenewalSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveRenewalAsync(renewalId, request, Actor, ct), RenewalNotFound, RenewalConflict);
    }

    [HttpPost("contracts/renewals/{renewalId:long}/action")]
    public async Task<IActionResult> RenewalAction(long renewalId, [FromBody] AssetContractRenewalActionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Action)) return BadRequest(new { error = "action is required." });
        return ResultWritten(await service.RenewalActionAsync(renewalId, request, ActorEmployeeId, Actor, ct), RenewalNotFound, RenewalConflict);
    }

    [HttpPost("contracts/renewal-items/{itemId:long}/resolve")]
    public async Task<IActionResult> ResolveRenewalItem(long itemId, [FromBody] AssetContractRenewalResolveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.ResolveRenewalItemAsync(itemId, request, Actor, ct), RenewalNotFound, RenewalConflict);
    }

    // ---------------------------------------------------------------- 437: notifications and scheduler
    [HttpGet("notifications/config")]
    public Task<IActionResult> NotificationConfig([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetNotificationConfigAsync(organizationId.Value, Actor, ct), "notification config");
    }

    [HttpPost("notifications/profiles")]
    public async Task<IActionResult> SaveNotificationProfile([FromBody] AssetNotificationProfileRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveNotificationProfileAsync(request, Actor, ct), NotificationNotFound, NotificationConflict);
    }

    [HttpPost("notifications/matrix")]
    public async Task<IActionResult> SaveEscalationMatrix([FromBody] AssetEscalationMatrixRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveEscalationMatrixAsync(request, Actor, ct), NotificationNotFound, NotificationConflict);
    }

    [HttpGet("notifications/occurrences")]
    public Task<IActionResult> NotificationOccurrences([FromQuery] long? organizationId, [FromQuery] string? status, [FromQuery] string? activityCode,
        [FromQuery] string? search, [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListNotificationOccurrencesAsync(organizationId.Value, status, activityCode, search, pageNumber ?? 1, pageSize ?? 25, ct),
            "notification occurrences");
    }

    [HttpGet("notifications/occurrences/{occurrenceId:long}")]
    public Task<IActionResult> NotificationOccurrence(long occurrenceId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetNotificationOccurrenceAsync(o, occurrenceId, ct), "Notification occurrence not found.", "notification occurrence");

    [HttpPost("notifications/occurrences/{occurrenceId:long}/snooze")]
    public async Task<IActionResult> SnoozeNotificationOccurrence(long occurrenceId, [FromBody] AssetNotificationSnoozeRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SnoozeNotificationOccurrenceAsync(occurrenceId, request, ActorEmployeeId, Actor, ct), NotificationNotFound, NotificationConflict);
    }

    [HttpGet("notifications/log")]
    public Task<IActionResult> NotificationLog([FromQuery] long? organizationId, [FromQuery] string? statusCode, [FromQuery] string? activityCode,
        [FromQuery] string? notificationClass, [FromQuery] string? search, [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListNotificationLogAsync(organizationId.Value, statusCode, activityCode, notificationClass, search,
            pageNumber ?? 1, pageSize ?? 25, ct), "notification log");
    }

    [HttpPost("notifications/log/{notificationId:long}/delivery")]
    public async Task<IActionResult> ReportNotificationDelivery(long notificationId, [FromBody] AssetNotificationDeliveryRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.ReportNotificationDeliveryAsync(notificationId, request, Actor, ct), NotificationNotFound, NotificationConflict);
    }

    [HttpGet("notifications/runs")]
    public Task<IActionResult> SchedulerRuns([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListSchedulerRunsAsync(organizationId.Value, ct), "scheduler runs");
    }

    [HttpPost("notifications/run")]
    public async Task<IActionResult> RunScheduler([FromBody] AssetSchedulerRunRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var run = await service.RunSchedulerAsync(request.OrganizationId, "MANUAL", Actor, ct);
            return Ok(new { success = true, data = run });
        }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == 54610)
        {
            return NotFound(new { success = false, error = ex.Message, errorNumber = ex.Number });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "AssetConfig scheduler run failed");
            return StatusCode(500, new { success = false, error = ex.Message });
        }
    }

    // The caller's own notices: addressed to the employee the Web tier stamped
    // (X-PM-Caller-Employee-Id); no organization or menu grant is involved.
    [HttpGet("notifications/mine")]
    public Task<IActionResult> MyNotifications([FromQuery] string? filter, [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (ActorEmployeeId is not { } me) return Task.FromResult(NotLinked());
        return ReadAsync(() => service.ListMyNotificationsAsync(me, filter, pageNumber ?? 1, pageSize ?? 25, ct), "my notifications");
    }

    [HttpGet("notifications/mine/counts")]
    public Task<IActionResult> MyNotificationCounts(CancellationToken ct)
    {
        if (ActorEmployeeId is not { } me) return Task.FromResult(NotLinked());
        return ReadAsync(() => service.CountMyNotificationsAsync(me, ct), "my notification counts");
    }

    [HttpPost("notifications/mine/{notificationId:long}/action")]
    public async Task<IActionResult> MyNotificationAction(long notificationId, [FromBody] AssetNotificationMineActionRequest request, CancellationToken ct)
    {
        if (ActorEmployeeId is not { } me) return NotLinked();
        if (request is null || string.IsNullOrWhiteSpace(request.Action)) return BadRequest(new { error = "action is required." });
        return ResultWritten(await service.MyNotificationActionAsync(me, notificationId, request, Actor, ct), NotificationNotFound, NotificationConflict);
    }

    [HttpPost("notifications/mine/read-all")]
    public async Task<IActionResult> ReadAllMyNotifications(CancellationToken ct)
    {
        if (ActorEmployeeId is not { } me) return NotLinked();
        try { return Ok(new { success = true, markedCount = await service.ReadAllMyNotificationsAsync(me, ct) }); }
        catch (Exception ex)
        {
            logger.LogError(ex, "AssetConfig read-all failed");
            return StatusCode(500, new { success = false, error = ex.Message });
        }
    }

    private IActionResult NotLinked() =>
        StatusCode(403, new { error = "Your sign-in is not linked to an employee record, so no notifications can be addressed to you." });

    // ---------------------------------------------------------------- 438: recurring asset activities
    [HttpGet("activities/config")]
    public Task<IActionResult> ActivityConfig([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetActivityConfigAsync(organizationId.Value, ct), "activity config");
    }

    [HttpPost("activities/settings")]
    public async Task<IActionResult> SaveActivitySetting([FromBody] AssetActivitySettingRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveActivitySettingAsync(request, Actor, ct), ActivityNotFound, ActivityConflict);
    }

    [HttpGet("activities/schedules")]
    public Task<IActionResult> ActivitySchedules([FromQuery] long? organizationId, [FromQuery] string? templateCode, [FromQuery] string? status,
        [FromQuery] string? search, [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListActivitySchedulesAsync(organizationId.Value, templateCode, status, search, pageNumber ?? 1, pageSize ?? 25, Actor, ct),
            "activity schedules");
    }

    [HttpGet("activities/occurrences")]
    public Task<IActionResult> ActivityOccurrences([FromQuery] long? organizationId, [FromQuery] string? templateCode, [FromQuery] string? status,
        [FromQuery] bool? reconcileOnly, [FromQuery] long? campaignId, [FromQuery] string? search, [FromQuery] int? pageNumber,
        [FromQuery] int? pageSize, [FromQuery] bool? awaitingDecision, CancellationToken ct)   // 439: awaitingDecision
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListActivityOccurrencesAsync(organizationId.Value, templateCode, status, reconcileOnly ?? false, campaignId, search,
            awaitingDecision ?? false, pageNumber ?? 1, pageSize ?? 25, ct), "activity occurrences");
    }

    // ---------------------------------------------------------------- 439: results, dispositions, reviews
    [HttpGet("activities/occurrences/{occurrenceId:long}")]
    public Task<IActionResult> ActivityOccurrence(long occurrenceId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetActivityOccurrenceAsync(o, occurrenceId, ct), "Activity occurrence not found.", "activity occurrence");

    [HttpPost("activities/occurrences/{occurrenceId:long}/result")]
    public async Task<IActionResult> SaveActivityResult(long occurrenceId, [FromBody] AssetActivityResultRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveActivityResultAsync(occurrenceId, request, ActorEmployeeId, Actor, ct), ActivityNotFound, ActivityConflict);
    }

    [HttpPost("activities/occurrences/{occurrenceId:long}/result-decision")]
    public async Task<IActionResult> DecideActivityResult(long occurrenceId, [FromBody] AssetLifecycleDecisionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Decision)) return BadRequest(new { error = "decision is required." });
        return ResultWritten(await service.DecideActivityResultAsync(occurrenceId, request, ActorEmployeeId, Actor, ct), ActivityNotFound, ActivityConflict);
    }

    [HttpPost("activities/occurrences/{occurrenceId:long}/disposition")]
    public async Task<IActionResult> RequestActivityDisposition(long occurrenceId, [FromBody] AssetActivityDispositionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.RequestActivityDispositionAsync(occurrenceId, request, ActorEmployeeId, Actor, ct), ActivityNotFound, ActivityConflict);
    }

    [HttpPost("activities/dispositions/{dispositionId:long}/decision")]
    public async Task<IActionResult> DecideActivityDisposition(long dispositionId, [FromBody] AssetLifecycleDecisionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Decision)) return BadRequest(new { error = "decision is required." });
        return ResultWritten(await service.DecideActivityDispositionAsync(dispositionId, request, ActorEmployeeId, Actor, ct), ActivityNotFound, ActivityConflict);
    }

    [HttpGet("activities/reviews")]
    public Task<IActionResult> RestrictiveReviews([FromQuery] long? organizationId, [FromQuery] string? status, [FromQuery] string? search,
        [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListRestrictiveReviewsAsync(organizationId.Value, status, search, pageNumber ?? 1, pageSize ?? 25, Actor, ct),
            "restrictive-use reviews");
    }

    [HttpPost("activities/reviews/{reviewId:long}/decision")]
    public async Task<IActionResult> DecideRestrictiveReview(long reviewId, [FromBody] AssetLifecycleDecisionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Decision)) return BadRequest(new { error = "decision is required." });
        return ResultWritten(await service.DecideRestrictiveReviewAsync(reviewId, request, ActorEmployeeId, Actor, ct), ActivityNotFound, ActivityConflict);
    }

    [HttpGet("activities/campaigns")]
    public Task<IActionResult> ActivityCampaigns([FromQuery] long? organizationId, [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListActivityCampaignsAsync(organizationId.Value, pageNumber ?? 1, pageSize ?? 25, ct), "activity campaigns");
    }

    [HttpPost("activities/occurrences/{occurrenceId:long}/reconcile")]
    public async Task<IActionResult> ReconcileActivity(long occurrenceId, [FromBody] AssetActivityReconcileRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.ReconcileActivityAsync(occurrenceId, request, Actor, ct), ActivityNotFound, ActivityConflict);
    }

    // The same scheduler pass as notifications/run, for the Asset Activities screen.
    [HttpPost("activities/run")]
    public Task<IActionResult> RunActivityScheduler([FromBody] AssetSchedulerRunRequest request, CancellationToken ct) =>
        RunScheduler(request, ct);

    // ---------------------------------------------------------------- 440: CMDB relationships
    [HttpGet("relationships/config")]
    public Task<IActionResult> RelationshipConfig([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetRelationshipConfigAsync(organizationId.Value, ct), "relationship config");
    }

    [HttpGet("relationships/ci-lookup")]
    public Task<IActionResult> CiLookup([FromQuery] long? organizationId, [FromQuery] string? kind, [FromQuery] string? search, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.LookupCisAsync(organizationId.Value, kind, search, ct), "configuration-item lookup");
    }

    [HttpGet("relationships")]
    public Task<IActionResult> Relationships([FromQuery] long? organizationId, [FromQuery] string? ciKind, [FromQuery] long? ciId,
        [FromQuery] string? typeCode, [FromQuery] string? status, [FromQuery] bool? criticalOnly, [FromQuery] bool? pendingOnly,
        [FromQuery] string? search, [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListRelationshipsAsync(organizationId.Value, ciKind, ciId, typeCode, status, criticalOnly ?? false,
            pendingOnly ?? false, search, pageNumber ?? 1, pageSize ?? 25, Actor, ct), "relationships");
    }

    [HttpGet("relationships/{relationshipId:long}")]
    public Task<IActionResult> Relationship(long relationshipId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetRelationshipAsync(o, relationshipId, ct), "Relationship not found.", "relationship");

    [HttpPost("relationships")]
    public async Task<IActionResult> SaveRelationship([FromBody] AssetRelationshipSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveRelationshipAsync(request, ActorEmployeeId, Actor, ct), RelationshipNotFound, RelationshipConflict);
    }

    [HttpPost("relationships/{relationshipId:long}/action")]
    public async Task<IActionResult> RelationshipAction(long relationshipId, [FromBody] AssetRelationshipActionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Action)) return BadRequest(new { error = "action is required." });
        return ResultWritten(await service.RelationshipActionAsync(relationshipId, request, ActorEmployeeId, Actor, ct), RelationshipNotFound, RelationshipConflict);
    }

    [HttpGet("relationships/impact")]
    public Task<IActionResult> Impact([FromQuery] long? organizationId, [FromQuery] string? ciKind, [FromQuery] long? ciId,
        [FromQuery] string? direction, [FromQuery] int? maxDepth, [FromQuery] bool? criticalOnly, [FromQuery] long? previewRelationshipId,
        CancellationToken ct)
    {
        if (organizationId is null or <= 0 || string.IsNullOrWhiteSpace(ciKind) || ciId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId, ciKind and ciId are required." }));
        var dir = string.IsNullOrWhiteSpace(direction) ? "DOWNSTREAM" : direction.Trim().ToUpperInvariant();
        if (dir is not ("DOWNSTREAM" or "UPSTREAM"))
            return Task.FromResult<IActionResult>(BadRequest(new { error = "direction is DOWNSTREAM or UPSTREAM." }));
        return ReadAsync(() => service.GetImpactAsync(organizationId.Value, ciKind, ciId.Value, dir, maxDepth ?? 5, criticalOnly ?? false,
            previewRelationshipId, ct), "impact analysis");
    }

    // ---------------------------------------------------------------- 441: business services
    [HttpGet("business-services/config")]
    public Task<IActionResult> BusinessServiceConfig([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetBusinessServiceConfigAsync(organizationId.Value, ct), "business service config");
    }

    [HttpGet("business-services")]
    public Task<IActionResult> BusinessServices([FromQuery] long? organizationId, [FromQuery] string? status, [FromQuery] string? serviceType,
        [FromQuery] string? search, [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListBusinessServicesAsync(organizationId.Value, status, serviceType, search, pageNumber ?? 1, pageSize ?? 25, ct),
            "business services");
    }

    [HttpGet("business-services/{serviceId:long}")]
    public Task<IActionResult> BusinessService(long serviceId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetBusinessServiceAsync(o, serviceId, ct), "Business service not found.", "business service");

    [HttpPost("business-services")]
    public async Task<IActionResult> SaveBusinessService([FromBody] BusinessServiceSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveBusinessServiceAsync(request, ActorEmployeeId, Actor, ct), ServiceNotFound, ServiceConflict);
    }

    [HttpPost("business-services/{serviceId:long}/transition")]
    public async Task<IActionResult> TransitionBusinessService(long serviceId, [FromBody] BusinessServiceTransitionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.TransitionBusinessServiceAsync(serviceId, request, ActorEmployeeId, Actor, ct), ServiceNotFound, ServiceConflict);
    }

    [HttpPost("business-services/{serviceId:long}/retirement-decision")]
    public async Task<IActionResult> DecideBusinessServiceRetirement(long serviceId, [FromBody] AssetLifecycleDecisionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Decision)) return BadRequest(new { error = "decision is required." });
        return ResultWritten(await service.DecideBusinessServiceRetirementAsync(serviceId, request, ActorEmployeeId, Actor, ct), ServiceNotFound, ServiceConflict);
    }

    [HttpPost("business-services/settings")]
    public async Task<IActionResult> SaveBusinessServiceSetting([FromBody] BusinessServiceSettingRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveBusinessServiceSettingAsync(request, Actor, ct), ServiceNotFound, ServiceConflict);
    }

    [HttpGet("business-services/conflicts")]
    public Task<IActionResult> BusinessServiceConflicts([FromQuery] long? organizationId, [FromQuery] long? serviceId, [FromQuery] string? search,
        [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListBusinessServiceConflictsAsync(organizationId.Value, serviceId, search, pageNumber ?? 1, pageSize ?? 25, ct),
            "business service conflicts");
    }

    [HttpGet("business-services/tree")]
    public Task<IActionResult> BusinessServiceTree([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetBusinessServiceTreeAsync(organizationId.Value, ct), "business service tree");
    }

    // ---------------------------------------------------------------- 442: discovery and reconciliation
    [HttpGet("discovery/config")]
    public Task<IActionResult> DiscoveryConfig([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetDiscoveryConfigAsync(organizationId.Value, ct), "discovery config");
    }

    [HttpPost("discovery/sources")]
    public async Task<IActionResult> SaveDiscoverySource([FromBody] AssetDiscoverySourceRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveDiscoverySourceAsync(request, Actor, ct), DiscoveryNotFound, DiscoveryConflict);
    }

    [HttpPost("discovery/sources/{sourceId:long}/priorities")]
    public async Task<IActionResult> SaveDiscoveryPriorities(long sourceId, [FromBody] AssetDiscoveryPrioritiesRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveDiscoveryPrioritiesAsync(sourceId, request, Actor, ct), DiscoveryNotFound, DiscoveryConflict);
    }

    [HttpPost("discovery/sources/{sourceId:long}/batches")]
    public async Task<IActionResult> IngestDiscoveryBatch(long sourceId, [FromBody] AssetDiscoveryIngestRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var (data, number, error) = await service.IngestDiscoveryBatchAsync(sourceId, request, ActorEmployeeId, Actor, ct);
        if (number is null) return Ok(new { success = true, data });
        var body = new { success = false, error, errorNumber = number };
        return number is int n && DiscoveryNotFound.Contains(n) ? NotFound(body) : BadRequest(body);
    }

    [HttpPost("discovery/rules")]
    public async Task<IActionResult> SaveIdentificationRule([FromBody] AssetIdentificationRuleRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveIdentificationRuleAsync(request, Actor, ct), DiscoveryNotFound, DiscoveryConflict);
    }

    [HttpPost("discovery/settings")]
    public async Task<IActionResult> SaveDiscoverySetting([FromBody] AssetDiscoverySettingRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveDiscoverySettingAsync(request, Actor, ct), DiscoveryNotFound, DiscoveryConflict);
    }

    [HttpGet("discovery/batches")]
    public Task<IActionResult> DiscoveryBatches([FromQuery] long? organizationId, [FromQuery] long? sourceId, [FromQuery] int? pageNumber,
        [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListDiscoveryBatchesAsync(organizationId.Value, sourceId, pageNumber ?? 1, pageSize ?? 25, ct), "discovery batches");
    }

    [HttpGet("discovery/batches/{batchId:long}")]
    public Task<IActionResult> DiscoveryBatch(long batchId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetDiscoveryBatchAsync(o, batchId, ct), "Discovery batch not found.", "discovery batch");

    [HttpGet("discovery/exceptions")]
    public Task<IActionResult> ReconciliationExceptions([FromQuery] long? organizationId, [FromQuery] string? status, [FromQuery] string? kind,
        [FromQuery] long? sourceId, [FromQuery] long? assetId, [FromQuery] string? search, [FromQuery] int? pageNumber, [FromQuery] int? pageSize,
        CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListReconciliationExceptionsAsync(organizationId.Value, status, kind, sourceId, assetId, search,
            pageNumber ?? 1, pageSize ?? 25, ct), "reconciliation exceptions");
    }

    [HttpPost("discovery/exceptions/{exceptionId:long}/resolve")]
    public async Task<IActionResult> ResolveReconciliationException(long exceptionId, [FromBody] AssetReconciliationResolveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Action)) return BadRequest(new { error = "action is required." });
        return ResultWritten(await service.ResolveReconciliationExceptionAsync(exceptionId, request, ActorEmployeeId, Actor, ct),
            DiscoveryNotFound, DiscoveryConflict);
    }

    [HttpGet("discovery/confidence")]
    public Task<IActionResult> DiscoveryConfidence([FromQuery] long? organizationId, [FromQuery] string? status, [FromQuery] string? search,
        [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListDiscoveryConfidenceAsync(organizationId.Value, status, search, pageNumber ?? 1, pageSize ?? 25, ct),
            "data confidence");
    }

    [HttpGet("discovery/assets/{assetId:long}")]
    public Task<IActionResult> DiscoveryAsset(long assetId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetDiscoveryAssetAsync(o, assetId, ct), "Asset not found.", "discovery asset");

    // 442: 54760 (organization), 54761 (source), 54767 (rule), 54773 (exception), 54779 (batch) -> 404;
    //      54774 (stale) -> 409.
    private static readonly int[] DiscoveryNotFound = { 54760, 54761, 54767, 54773, 54779 };
    private static readonly int[] DiscoveryConflict = { 54774 };

    // ---------------------------------------------------------------- 443: candidate registration, stale review
    [HttpGet("discovery/exceptions/{exceptionId:long}/candidate")]
    public Task<IActionResult> DiscoveryCandidate(long exceptionId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetDiscoveryCandidateAsync(o, exceptionId, ct), "Reconciliation exception not found.", "discovery candidate");

    [HttpGet("discovery/stale")]
    public Task<IActionResult> StaleReviews([FromQuery] long? organizationId, [FromQuery] string? view, [FromQuery] string? search,
        [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListStaleReviewsAsync(organizationId.Value, view, search, pageNumber ?? 1, pageSize ?? 25, ct), "stale reviews");
    }

    [HttpGet("discovery/stale/assets/{assetId:long}")]
    public Task<IActionResult> StaleReview(long assetId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetStaleReviewAsync(o, assetId, ct), "Asset not found.", "stale review");

    [HttpPost("discovery/stale/settings")]
    public async Task<IActionResult> SaveStaleSetting([FromBody] AssetStaleSettingRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveStaleSettingAsync(request, Actor, ct), StaleNotFound, StaleConflict);
    }

    [HttpPost("discovery/stale/reviews")]
    public async Task<IActionResult> OpenStaleReview([FromBody] AssetStaleReviewOpenRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.AssetId <= 0) return BadRequest(new { error = "assetId is required." });
        return ResultWritten(await service.OpenStaleReviewAsync(request, Actor, ct), StaleNotFound, StaleConflict);
    }

    [HttpPost("discovery/stale/reviews/{reviewId:long}/action")]
    public async Task<IActionResult> StaleReviewAction(long reviewId, [FromBody] AssetStaleReviewActionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Action)) return BadRequest(new { error = "action is required." });
        return ResultWritten(await service.StaleReviewActionAsync(reviewId, request, ActorEmployeeId, Actor, ct), StaleNotFound, StaleConflict);
    }

    // 443: 54780 (organization), 54781 (asset), 54784 (review) -> 404; 54785 (stale) -> 409.
    //      Lifecycle refusals of REQUEST_DECOMMISSION (5497x, 54719) -> 400.
    private static readonly int[] StaleNotFound = { 54780, 54781, 54784 };
    private static readonly int[] StaleConflict = { 54785 };

    // ---------------------------------------------------------------- 444: asset merge
    [HttpGet("discovery/merges")]
    public Task<IActionResult> Merges([FromQuery] long? organizationId, [FromQuery] string? status, [FromQuery] string? search,
        [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListMergesAsync(organizationId.Value, status, search, pageNumber ?? 1, pageSize ?? 25, ct), "merges");
    }

    [HttpGet("discovery/merges/{eventId:long}")]
    public Task<IActionResult> Merge(long eventId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetMergeAsync(o, eventId, ct), "Merge not found.", "merge");

    [HttpPost("discovery/merges")]
    public async Task<IActionResult> SaveMerge([FromBody] AssetMergeSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.SurvivorAssetId <= 0) return BadRequest(new { error = "survivorAssetId is required." });
        return ResultWritten(await service.SaveMergeAsync(request, ActorEmployeeId, Actor, ct), MergeNotFound, MergeConflict);
    }

    [HttpPost("discovery/merges/{eventId:long}/action")]
    public async Task<IActionResult> MergeAction(long eventId, [FromBody] AssetMergeActionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Action)) return BadRequest(new { error = "action is required." });
        return ResultWritten(await service.MergeActionAsync(eventId, request, ActorEmployeeId, Actor, ct), MergeNotFound, MergeConflict);
    }

    // 444: 52900 (organization), 52901 (asset), 52902 (merge) -> 404; 52903 (stale) -> 409.
    private static readonly int[] MergeNotFound = { 52900, 52901, 52902 };
    private static readonly int[] MergeConflict = { 52903 };

    // ---------------------------------------------------------------- 445: asset split
    [HttpGet("discovery/splits")]
    public Task<IActionResult> Splits([FromQuery] long? organizationId, [FromQuery] string? status, [FromQuery] string? search,
        [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListSplitsAsync(organizationId.Value, status, search, pageNumber ?? 1, pageSize ?? 25, ct), "splits");
    }

    [HttpGet("discovery/splits/{eventId:long}")]
    public Task<IActionResult> Split(long eventId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetSplitAsync(o, eventId, ct), "Split not found.", "split");

    [HttpPost("discovery/splits")]
    public async Task<IActionResult> SaveSplit([FromBody] AssetSplitSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.SourceAssetId <= 0) return BadRequest(new { error = "sourceAssetId is required." });
        return ResultWritten(await service.SaveSplitAsync(request, ActorEmployeeId, Actor, ct), MergeNotFound, MergeConflict);
    }

    [HttpPost("discovery/splits/{eventId:long}/action")]
    public async Task<IActionResult> SplitAction(long eventId, [FromBody] AssetMergeActionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Action)) return BadRequest(new { error = "action is required." });
        return ResultWritten(await service.MergeActionAsync(eventId, request, ActorEmployeeId, Actor, ct), MergeNotFound, MergeConflict);
    }

    // ---------------------------------------------------------------- 446: Asset Value per asset
    [HttpGet("register/{assetId:long}/valuation")]
    public Task<IActionResult> AssetValuation(long assetId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetAssetValuationAsync(o, assetId, ct), "Asset not found.", "asset valuation");

    [HttpPost("register/{assetId:long}/valuation/recalculate")]
    public async Task<IActionResult> RecalculateAssetValuation(long assetId, [FromBody] AssetValuationRecalculateRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.RecalculateAssetValuationAsync(assetId, request, ActorEmployeeId, Actor, ct), ValuationNotFound, ValuationConflict);
    }

    [HttpPost("register/{assetId:long}/valuation/method")]
    public async Task<IActionResult> SetAssetValuationMethod(long assetId, [FromBody] AssetValuationMethodRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SetAssetValuationMethodAsync(assetId, request, ActorEmployeeId, Actor, ct), ValuationNotFound, ValuationConflict);
    }

    [HttpGet("valuation/recalculation")]
    public Task<IActionResult> ValuationRecalcPreview([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetValuationRecalcPreviewAsync(organizationId.Value, ct), "valuation recalculation preview");
    }

    [HttpPost("valuation/recalculation")]
    public async Task<IActionResult> RunValuationRecalc([FromBody] AssetValuationRecalcRunRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.RunValuationRecalcAsync(request, ActorEmployeeId, Actor, ct), ValuationNotFound, ValuationConflict);
    }

    // ---------------------------------------------------------------- 447: consistency rules
    [HttpGet("valuation/consistency/rules")]
    public Task<IActionResult> ConsistencyRules([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListConsistencyRulesAsync(organizationId.Value, ct), "consistency rules");
    }

    [HttpGet("valuation/consistency/rules/{ruleId:long}")]
    public Task<IActionResult> ConsistencyRule(long ruleId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetConsistencyRuleAsync(o, ruleId, ct), "Consistency rule not found.", "consistency rule");

    [HttpGet("valuation/consistency/rules/{ruleId:long}/preview")]
    public Task<IActionResult> ConsistencyRulePreview(long ruleId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.PreviewConsistencyRuleAsync(o, ruleId, ct), "Consistency rule not found.", "consistency preview");

    [HttpGet("valuation/consistency/operands")]
    public Task<IActionResult> ConsistencyOperands([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetConsistencyOperandsAsync(organizationId.Value, ct), "consistency operands");
    }

    [HttpPost("valuation/consistency/rules")]
    public async Task<IActionResult> SaveConsistencyRule([FromBody] AssetConsistencyRuleSaveRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveConsistencyRuleAsync(request, Actor, ct), ConsistencyNotFound, ConsistencyConflict);
    }

    [HttpPost("valuation/consistency/rules/{ruleId:long}/action")]
    public async Task<IActionResult> ConsistencyRuleAction(long ruleId, [FromBody] AssetConsistencyRuleActionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Action)) return BadRequest(new { error = "action is required." });
        return ResultWritten(await service.ConsistencyRuleActionAsync(ruleId, request, ActorEmployeeId, Actor, ct), ConsistencyNotFound, ConsistencyConflict);
    }

    [HttpGet("register/consistency/findings")]
    public Task<IActionResult> ConsistencyFindings([FromQuery] long? organizationId, [FromQuery] string? status, [FromQuery] string? severity,
        [FromQuery] long? assetId, [FromQuery] string? search, [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListConsistencyFindingsAsync(organizationId.Value, status, severity, assetId, search,
            pageNumber ?? 1, pageSize ?? 25, ct), "consistency findings");
    }

    [HttpPost("register/consistency/findings/{findingId:long}/action")]
    public async Task<IActionResult> ConsistencyFindingAction(long findingId, [FromBody] AssetConsistencyFindingActionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Action)) return BadRequest(new { error = "action is required." });
        return ResultWritten(await service.ConsistencyFindingActionAsync(findingId, request, ActorEmployeeId, Actor, ct), ConsistencyNotFound, ConsistencyConflict);
    }

    [HttpPost("register/consistency/run")]
    public async Task<IActionResult> RunConsistency([FromBody] AssetConsistencyRunRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.RunConsistencyAsync(request, Actor, ct), ConsistencyNotFound, ConsistencyConflict);
    }

    // ---------------------------------------------------------------- 448: asset privacy
    [HttpGet("register/{assetId:long}/privacy")]
    public Task<IActionResult> AssetPrivacy(long assetId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetPrivacyAssetAsync(o, assetId, ct), "Asset not found.", "asset privacy");

    [HttpGet("privacy/assets")]
    public Task<IActionResult> PrivacyAssets([FromQuery] long? organizationId, [FromQuery] string? status, [FromQuery] string? search,
        [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListPrivacyAssetsAsync(organizationId.Value, status, search, pageNumber ?? 1, pageSize ?? 25, ct), "privacy assets");
    }

    [HttpGet("privacy/assets/{assetId:long}")]
    public Task<IActionResult> PrivacyAsset(long assetId, [FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetPrivacyAssetAsync(o, assetId, ct), "Asset not found.", "privacy asset");

    [HttpGet("privacy/exceptions")]
    public Task<IActionResult> PrivacyExceptions([FromQuery] long? organizationId, [FromQuery] string? status,
        [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListPrivacyExceptionsAsync(organizationId.Value, status, pageNumber ?? 1, pageSize ?? 25, ct), "privacy exceptions");
    }

    [HttpGet("privacy/reviews")]
    public Task<IActionResult> PrivacyReviews([FromQuery] long? organizationId, [FromQuery] string? status, [FromQuery] string? kind,
        [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListPrivacyReviewsAsync(organizationId.Value, status, kind, pageNumber ?? 1, pageSize ?? 25, ct), "privacy reviews");
    }

    [HttpGet("privacy/requirements")]
    public Task<IActionResult> PrivacyRequirements([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetPrivacyRequirementsAsync(organizationId.Value, ct), "privacy requirements");
    }

    [HttpPost("privacy/requirements")]
    public async Task<IActionResult> SavePrivacySetting([FromBody] AssetPrivacySettingRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SavePrivacySettingAsync(request, Actor, ct), PrivacyNotFound, PrivacyConflict);
    }

    [HttpPost("privacy/exceptions")]
    public async Task<IActionResult> RequestPrivacyException([FromBody] AssetPrivacyExceptionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.AssetId <= 0) return BadRequest(new { error = "assetId is required." });
        return ResultWritten(await service.RequestPrivacyExceptionAsync(request, ActorEmployeeId, Actor, ct), PrivacyNotFound, PrivacyConflict);
    }

    [HttpPost("privacy/exceptions/{exceptionId:long}/action")]
    public async Task<IActionResult> PrivacyExceptionAction(long exceptionId, [FromBody] AssetPrivacyExceptionActionRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Action)) return BadRequest(new { error = "action is required." });
        return ResultWritten(await service.PrivacyExceptionActionAsync(exceptionId, request, ActorEmployeeId, Actor, ct), PrivacyNotFound, PrivacyConflict);
    }

    [HttpPost("privacy/reviews/{reviewId:long}/complete")]
    public async Task<IActionResult> CompletePrivacyReview(long reviewId, [FromBody] AssetPrivacyReviewCompleteRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.Outcome)) return BadRequest(new { error = "outcome is required." });
        return ResultWritten(await service.CompletePrivacyReviewAsync(reviewId, request, ActorEmployeeId, Actor, ct), PrivacyNotFound, PrivacyConflict);
    }

    [HttpPost("privacy/run")]
    public async Task<IActionResult> RunPrivacy([FromBody] AssetPrivacyRunRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.RunPrivacyAsync(request, Actor, ct), PrivacyNotFound, PrivacyConflict);
    }

    // ---------------------------------------------------------------- 450: asset governance KPIs
    [HttpGet("governance")]
    public Task<IActionResult> Governance([FromQuery] long? organizationId, [FromQuery] long? snapshotId, [FromQuery] int? trendDays,
        CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetGovernanceAsync(o, snapshotId, trendDays ?? 90, ct), "Snapshot not found.", "governance");

    [HttpGet("governance/items")]
    public Task<IActionResult> GovernanceItems([FromQuery] long? organizationId, [FromQuery] long? snapshotId, [FromQuery] string? kpiCode,
        [FromQuery] string? outcome, [FromQuery] string? search, [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (snapshotId is null or <= 0 || string.IsNullOrWhiteSpace(kpiCode))
            return Task.FromResult<IActionResult>(BadRequest(new { error = "snapshotId and kpiCode are required." }));
        return ReadOrNotFound(organizationId, o => service.ListGovernanceItemsAsync(o, snapshotId.Value, kpiCode!, outcome, search,
            pageNumber ?? 1, pageSize ?? 25, ct), "Snapshot or KPI not found.", "governance items");
    }

    [HttpGet("governance/snapshots")]
    public Task<IActionResult> GovernanceSnapshots([FromQuery] long? organizationId, [FromQuery] int? pageNumber, [FromQuery] int? pageSize,
        CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListGovernanceSnapshotsAsync(organizationId.Value, pageNumber ?? 1, pageSize ?? 25, ct), "governance snapshots");
    }

    [HttpGet("governance/settings")]
    public Task<IActionResult> GovernanceSettings([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.GetGovernanceSettingsAsync(organizationId.Value, ct), "governance settings");
    }

    [HttpPost("governance/settings")]
    public async Task<IActionResult> SaveGovernanceSetting([FromBody] AssetGovernanceSettingRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.KpiCode)) return BadRequest(new { error = "kpiCode is required." });
        return ResultWritten(await service.SaveGovernanceSettingAsync(request, Actor, ct), GovernanceNotFound, GovernanceConflict);
    }

    [HttpPost("governance/settings/overall")]
    public async Task<IActionResult> SaveGovernanceOrgSetting([FromBody] AssetGovernanceOrgSettingRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveGovernanceOrgSettingAsync(request, Actor, ct), GovernanceNotFound, GovernanceConflict);
    }

    [HttpPost("governance/relationship-rules")]
    public async Task<IActionResult> SaveGovernanceRelationshipRule([FromBody] AssetGovernanceRelationshipRuleRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveGovernanceRelationshipRuleAsync(request, Actor, ct), GovernanceNotFound, GovernanceConflict);
    }

    [HttpPost("governance/snapshot")]
    public async Task<IActionResult> TakeGovernanceSnapshot([FromBody] AssetGovernanceSnapshotRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.TakeGovernanceSnapshotAsync(request, Actor, ct), GovernanceNotFound, GovernanceConflict);
    }

    // 450: 53080 (organization), 53081 (KPI), 53083 (snapshot), 53084 (asset type), 53085 (relationship type),
    //      53086 (relationship requirement) -> 404; 53088 (requirement exists) -> 409; others -> 400.
    private static readonly int[] GovernanceNotFound = { 53080, 53081, 53083, 53084, 53085, 53086 };
    private static readonly int[] GovernanceConflict = { 53088 };

    // ---------------------------------------------------------------- 452: report catalogue and exports
    private const string CallerReportAreasHeader = "X-PM-Caller-Report-Areas";
    private const string CallerReportApproveHeader = "X-PM-Caller-Report-Approve";

    private string? ReportAreas => Request.Headers[CallerReportAreasHeader].ToString() is { Length: > 0 } areas ? areas : null;

    private bool ReportApprove => Request.Headers[CallerReportApproveHeader].ToString() == "1";

    [HttpGet("reports")]
    public Task<IActionResult> Reports([FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetReportCatalogueAsync(o, ReportAreas, ReportApprove, ct), "Organization not found.",
            "report catalogue");

    [HttpGet("reports/exports")]
    public Task<IActionResult> ReportExports([FromQuery] long? organizationId, [FromQuery] string? reportCode, [FromQuery] int? pageNumber,
        [FromQuery] int? pageSize, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.ListReportExportsAsync(o, ReportAreas, reportCode, pageNumber ?? 1, pageSize ?? 25, ct),
            "Organization not found.", "report exports");

    [HttpGet("reports/{code}/run")]
    public async Task<IActionResult> RunReport(string code, [FromQuery] long? organizationId, [FromQuery] string? search,
        [FromQuery] string? status, [FromQuery] int? assetTypeId, [FromQuery] DateTime? dateFrom, [FromQuery] DateTime? dateTo,
        [FromQuery] int? days, [FromQuery] int? pageNumber, [FromQuery] int? pageSize, CancellationToken ct)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        var request = new AssetReportRunRequest(organizationId.Value, code, search, status, assetTypeId, dateFrom, dateTo, days);
        return ReportResult(await service.RunReportAsync(request, ReportAreas, ReportApprove, pageNumber ?? 1, pageSize ?? 25, ct));
    }

    [HttpPost("reports/{code}/export")]
    public async Task<IActionResult> ExportReport(string code, [FromBody] AssetReportRunRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ReportResult(await service.ExportReportAsync(request with { ReportCode = code }, ReportAreas, ReportApprove, Actor,
            ActorEmployeeId, ct));
    }

    [HttpGet("reports/schedules")]
    public Task<IActionResult> ReportSchedules([FromQuery] long? organizationId, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.GetReportSchedulesAsync(o, ReportAreas, ct), "Organization not found.", "report schedules");

    [HttpPost("reports/schedules")]
    public async Task<IActionResult> SaveReportSchedule([FromBody] AssetReportScheduleRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ResultWritten(await service.SaveReportScheduleAsync(request, ReportAreas, Actor, ActorEmployeeId, ct),
            ReportScheduleNotFound, ReportScheduleConflict);
    }

    [HttpPost("reports/schedules/{id:long}/run")]
    public async Task<IActionResult> RunReportSchedule(long id, [FromBody] AssetReportOrganizationRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ReportResult(await service.RunReportScheduleNowAsync(request.OrganizationId, id, ReportAreas, Actor, ct));
    }

    [HttpGet("reports/deliveries")]
    public Task<IActionResult> ReportDeliveries([FromQuery] long? organizationId, [FromQuery] long? scheduleId, [FromQuery] int? pageNumber,
        [FromQuery] int? pageSize, CancellationToken ct) =>
        ReadOrNotFound(organizationId, o => service.ListReportDeliveriesAsync(o, ReportAreas, scheduleId, pageNumber ?? 1, pageSize ?? 25, ct),
            "Organization not found.", "report deliveries");

    [HttpGet("reports/deliveries/mine")]
    public Task<IActionResult> MyReportDeliveries([FromQuery] long? organizationId, [FromQuery] int? pageNumber, [FromQuery] int? pageSize,
        CancellationToken ct)
    {
        if (organizationId is null or <= 0)
            return Task.FromResult<IActionResult>(BadRequest(new { error = "organizationId is required." }));
        return ReadAsync(() => service.ListMyReportDeliveriesAsync(organizationId.Value, ActorEmployeeId, pageNumber ?? 1, pageSize ?? 25, ct),
            "my report deliveries");
    }

    [HttpGet("reports/deliveries/{id:long}/recipients")]
    public async Task<IActionResult> ReportDeliveryRecipients(long id, [FromQuery] long? organizationId, CancellationToken ct)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        return ReportResult(await service.ListReportDeliveryRecipientsAsync(organizationId.Value, id, ReportAreas, ct));
    }

    [HttpPost("reports/deliveries/recipients/{id:long}/download")]
    public async Task<IActionResult> DownloadReportDelivery(long id, [FromBody] AssetReportOrganizationRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return ReportResult(await service.DownloadReportDeliveryAsync(request.OrganizationId, id, ActorEmployeeId, ReportAreas, ReportApprove,
            Actor, ct));
    }

    [HttpPost("reports/settings")]
    public async Task<IActionResult> SaveReportSetting([FromBody] AssetReportSettingRequest request, CancellationToken ct)
    {
        if (request is null || request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(request.ReportCode)) return BadRequest(new { error = "reportCode is required." });
        return ResultWritten(await service.SaveReportSettingAsync(request, ReportAreas, Actor, ct), ReportNotFound, Array.Empty<int>());
    }

    // 452: 53100 (organization), 53101 (report) -> 404; 53103 (screen not permitted), 53105 (export policy) -> 403;
    //      53102 (not available), 53104 (disabled) -> 409; 53106 / 53107 / 53108 / 53109 (filters, size, settings) -> 400.
    private static readonly int[] ReportNotFound = { 53100, 53101 };

    // 453: 53120 (organization), 53121 (schedule), 53122 (report cannot be scheduled) -> 404; 53128 (changed by someone
    //      else) -> 409; 53123 / 53124 / 53125 -> 400. Runs, deliveries and downloads go through ReportResult.
    private static readonly int[] ReportScheduleNotFound = { 53120, 53121, 53122 };
    private static readonly int[] ReportScheduleConflict = { 53128 };

    private IActionResult ReportResult(AssetReportResult r)
    {
        if (r.Success) return Ok(new { data = r.Data });
        var body = new { success = false, error = r.Error, errorNumber = r.ErrorNumber };
        return r.ErrorNumber switch
        {
            53100 or 53101 or 53120 or 53121 or 53126 => NotFound(body),
            53103 or 53105 or 53123 or 53129 => StatusCode(403, body),
            53102 or 53104 or 53127 or 53128 => Conflict(body),
            _ => BadRequest(body)
        };
    }

    // 448: 53050 (organization), 53051 (asset), 53052 (requirement), 53054 (asset type), 53056 (exception), 53064 (review)
    //      -> 404; 53060 (live exception exists), 53063 / 53069 (changed by someone else) -> 409; others -> 400.
    private static readonly int[] PrivacyNotFound = { 53050, 53051, 53052, 53054, 53056, 53064 };
    private static readonly int[] PrivacyConflict = { 53060, 53063, 53069 };

    // 447: 53010 (organization), 53011 (rule), 53030 (finding) -> 404; 53013 / 53036 (changed by someone else),
    //      53019 (a Draft exists) -> 409; others -> 400.
    private static readonly int[] ConsistencyNotFound = { 53010, 53011, 53030 };
    private static readonly int[] ConsistencyConflict = { 53013, 53019, 53036 };

    // 446: 53000 (asset), 53007 (organization) -> 404; 53005 (affected assets changed since the preview),
    //      53006 (a run is in progress) -> 409; others (no Active configuration, override not enabled, reason) -> 400.
    private static readonly int[] ValuationNotFound = { 53000, 53007 };
    private static readonly int[] ValuationConflict = { 53005, 53006 };

    // 441: 54730 (organization), 54731 (service) -> 404; 54732 (stale), 54747 (retirement pending / none) -> 409.
    private static readonly int[] ServiceNotFound = { 54730, 54731 };
    private static readonly int[] ServiceConflict = { 54732, 54747 };

    // 440: 54701 (organization), 54709 (relationship) -> 404; 54710 (stale), 54712 (pending change) -> 409.
    private static readonly int[] RelationshipNotFound = { 54701, 54709 };
    private static readonly int[] RelationshipConflict = { 54710, 54712 };

    // 438: 54650 / 54651 / 54655 -> 404; 54658 (stale) -> 409.
    // 439: 54670 (occurrence), 54686 (disposition), 54688 (review), 54692 (organization) -> 404;
    //      54680 (stale), 54685 (a request is already pending) -> 409.
    private static readonly int[] ActivityNotFound = { 54650, 54651, 54655, 54670, 54686, 54688, 54692 };
    private static readonly int[] ActivityConflict = { 54658, 54680, 54685 };

    // 437: 54610 / 54611 / 54625 / 54630 -> 404; 54622 (active profile exists), 54623 (stale) -> 409.
    private static readonly int[] NotificationNotFound = { 54610, 54611, 54625, 54630 };
    private static readonly int[] NotificationConflict = { 54622, 54623 };

    // 436: 54570 / 54571 / 54574 / 54588 -> 404; 54572 (open renewal), 54576 (stale), 54522 / 54525 (version in progress / stale)
    // and 53520 -> 409.
    private static readonly int[] RenewalNotFound = { 54570, 54571, 54574, 54588 };
    private static readonly int[] RenewalConflict = { 54572, 54576, 54522, 54525, 53520 };

    // 435: 54550 / 54552 / 54557 / 54558 / 54564 -> 404; 54561 (asset already covered for the type) -> 409.
    private static readonly int[] CoverageNotFound = { 54550, 54552, 54557, 54558, 54564 };
    private static readonly int[] CoverageConflict = { 54561 };

    // 434: 54510 / 54511 / 54519 / 54540 / 54544 -> 404; 54518 / 54525 / 54548 (stale), 54522 (version in progress)
    // and 53520 (illegal status move) -> 409.
    private static readonly int[] ContractNotFound = { 54510, 54511, 54519, 54540, 54544 };
    private static readonly int[] ContractConflict = { 54518, 54525, 54548, 54522, 53520 };

    // 432: 54410 / 54411 -> 404; 54412 (stale) -> 409.
    private static readonly int[] ExceptionNotFound = { 54410, 54411 };
    private static readonly int[] ExceptionConflict = { 54412 };

    // 431: 54357 -> 404; 54358 (stale) -> 409.
    private static readonly int[] AttestationNotFound = { 54357 };
    private static readonly int[] AttestationConflict = { 54358 };

    // 429: 54970 / 54971 / 54981 -> 404; 54972 / 54973 / 54986 / 54987 (stale or competing change) and 53520 -> 409.
    private static readonly int[] LifecycleNotFound = { 54970, 54971, 54981 };
    private static readonly int[] LifecycleConflict = { 54972, 54973, 54986, 54987, 53520 };
    // 430: 54320 / 54321 / 54335 -> 404; 54322 / 54340 (stale) and 54334 (already covered / pending) -> 409.
    private static readonly int[] TechNotFound = { 54320, 54321, 54335 };
    private static readonly int[] TechConflict = { 54322, 54334, 54340 };

    /// <summary>Lifecycle (429) and technology (430) writes: the listed
    /// numbers map to 404 / 409, any other refusal to 400 with the
    /// procedure's message.</summary>
    private IActionResult ResultWritten(AssetLifecycleResult r, int[] notFound, int[] conflict)
    {
        var body = new { success = r.Success, result = r.Result, id = r.ChangeId, error = r.Error, errorNumber = r.ErrorNumber };
        if (r.Success) return Ok(body);
        if (r.ErrorNumber is { } n && notFound.Contains(n)) return NotFound(body);
        if (r.ErrorNumber is { } c && conflict.Contains(c)) return Conflict(body);
        return BadRequest(body);
    }

    // ---------------------------------------------------------------- helpers
    /// <summary>GET helper for reads that return null when the procedure
    /// reports "not found" (426).</summary>
    private async Task<IActionResult> ReadOrNotFound(long? organizationId, Func<long, Task<object?>> read, string notFound, string what)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var data = await read(organizationId.Value);
            return data is null ? NotFound(new { error = notFound }) : Ok(new { data });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "AssetConfig {What} read failed", what);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    private async Task<IActionResult> ReadAsync(Func<Task<object>> read, string what)
    {
        try { return Ok(new { data = await read() }); }
        catch (Exception ex)
        {
            logger.LogError(ex, "AssetConfig {What} read failed", what);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    /// <summary>54202 / 54251 / 54270 / 54276 / 54279 / 54280 / 54285 / 54288 / 54291 /
    /// 54800 / 54801 / 54807 / 54850 / 54851 / 54857 / 54866 / 54910 / 54911 / 54917 / 54926 /
    /// 54350 / 54352 -> 404;
    /// 54205 / 54253 / 54284 / 54805 / 54855 / 54915 / 54353 (stale version) and 53520 (illegal
    /// status move) -> 409; any other refusal -> 400 with the procedure's
    /// message, which is written for the end user.</summary>
    private IActionResult Written(AssetConfigWriteResult result)
    {
        if (result.Success) return Ok(new { success = true, id = result.Id });
        var body = new { success = false, error = result.Error, errorNumber = result.ErrorNumber };
        return result.ErrorNumber switch
        {
            54202 or 54251 => NotFound(body),                  // 54251: valuation configuration (422)
            54270 or 54276 or 54279 => NotFound(body),         // 423: list / value / organization
            54280 or 54285 or 54288 or 54291 => NotFound(body), // 424: category / subcategory / type / organization
            54800 or 54801 or 54807 => NotFound(body),         // 425: organization / make / model
            54850 or 54851 or 54857 or 54866 => NotFound(body), // 426: organization / product / release / compatibility
            54910 or 54911 or 54917 or 54926 => NotFound(body), // 427: organization / product / release / compatibility
            54350 or 54352 => NotFound(body),                  // 431: organization / attestation profile
            54410 => NotFound(body),                           // 432: organization
            54205 or 54253 or 54284 or 54805 or 54855 or 54915 or 54353 or 54426 or 53520 => Conflict(body),
            _ => BadRequest(body)
        };
    }
}
