// =====================================================================
// EventScopeController
//
// Route: /api/practice/workflow/scope/...
//
// Nested under the existing workflow route so the Web tier's
// WorkflowController proxy forwards these paths one-to-one with no
// routing change, while the C# type stays a separate reviewable file.
//
// Sub-routes:
//   GET  /scope/mappings                  Mapping workspace (mapped + unmapped)
//   GET  /scope/coverage                  Coverage per role / asset category
//   POST /scope/raise                     Generic scoped raise
//   POST /scope/raise/people              Onboard / offboard
//   POST /scope/raise/asset               Commission / decommission
//   GET  /scope/inbox                     Event checklist inbox
//   GET  /scope/instances/{id}            Popup detail (header + items)
//   GET  /scope/trace                     Resolution trace / gap queue
//
// Migration 331 added PROFILE as a third value of scopeDimension on
// /scope/obligation-mappings (GET and POST) and /scope/obligation-
// coverage, with a profileId alongside scopeRoleId / scopeAssetCategoryId.
// Profile CRUD lives in EventProfileController under
// /scope/profiles/... -- the mapping endpoints stay here so there is one
// write path to event_obligation_applicability, not two.
//
// Submission is intentionally absent: the existing
// POST /event-instance-items and POST /event-instances/{id}/complete on
// WorkflowController already do it, and duplicating them here would give
// the UI two ways to write the same row.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/workflow/scope")]
public sealed class EventScopeController(
    IEventScopeService eventScopeService,
    ILogger<EventScopeController> logger) : ControllerBase
{
    // ============================================================
    // Mapping workspace
    // ============================================================
    [HttpGet("mappings")]
    public async Task<IActionResult> ListMappings(
        [FromQuery] long    organizationId,
        [FromQuery] long?   eventDefinitionId,
        [FromQuery] string? scopeDimension,
        [FromQuery] long?   scopeRoleId,
        [FromQuery] int?    scopeAssetCategoryId,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (!EventScopeDimensions.IsValid(scopeDimension))
            return BadRequest(new { error = "scopeDimension must be ORG_ROLE, ASSET_CATEGORY or omitted." });
        if (scopeDimension == EventScopeDimensions.OrgRole && scopeRoleId is null or <= 0)
            return BadRequest(new { error = "scopeRoleId is required when scopeDimension is ORG_ROLE." });
        if (scopeDimension == EventScopeDimensions.AssetCategory && scopeAssetCategoryId is null or <= 0)
            return BadRequest(new { error = "scopeAssetCategoryId is required when scopeDimension is ASSET_CATEGORY." });

        var q = new EventScopeMappingQuery(
            organizationId, eventDefinitionId, scopeDimension, scopeRoleId, scopeAssetCategoryId);
        return Ok(await eventScopeService.ListScopeMappingsAsync(q, cancellationToken));
    }

    [HttpGet("coverage")]
    public async Task<IActionResult> ListCoverage(
        [FromQuery] long   organizationId,
        [FromQuery] string scopeDimension,
        [FromQuery] long?  eventDefinitionId,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (scopeDimension is not (EventScopeDimensions.OrgRole or EventScopeDimensions.AssetCategory))
            return BadRequest(new { error = "scopeDimension must be ORG_ROLE or ASSET_CATEGORY." });

        var q = new EventScopeCoverageQuery(organizationId, scopeDimension, eventDefinitionId);
        return Ok(await eventScopeService.ListScopeCoverageAsync(q, cancellationToken));
    }

    // ============================================================
    // Obligation-based mapping (migrations 127/128)
    //
    // This is what the Scoped Checklist Mapping screen uses. The
    // checklist routes above stay for organizations that author their
    // own checklists.
    // ============================================================
    [HttpGet("obligation-mappings")]
    public async Task<IActionResult> ListObligationMappings(
        [FromQuery] long    organizationId,
        [FromQuery] string  scopeDimension,
        [FromQuery] long?   eventTypeId,
        [FromQuery] string? eventTypeCode,
        [FromQuery] long?   scopeRoleId,
        [FromQuery] int?    scopeAssetCategoryId,
        [FromQuery] bool    includeUnsubscribed = false,
        [FromQuery] long?   profileId = null,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (!EventScopeDimensions.IsConcrete(scopeDimension))
            return BadRequest(new { error = "scopeDimension must be ORG_ROLE, ASSET_CATEGORY or PROFILE." });

        // The scope value is optional here (migration 137). Which obligations
        // reach the organization depends on the organization, the event and the
        // subscribed releases; the scope value only decides which are ticked.
        // Omitting it returns the list with everything Unmapped, which is what
        // a record still being added actually has -- including a profile the
        // admin is still filling in. Saving a decision still requires it --
        // see SaveObligationApplicability.

        var q = new EventObligationMappingQuery(
            organizationId, eventTypeId, eventTypeCode, scopeDimension,
            scopeRoleId, scopeAssetCategoryId, includeUnsubscribed, profileId);
        return Ok(await eventScopeService.ListObligationMappingsAsync(q, cancellationToken));
    }

    [HttpPost("obligation-mappings")]
    public async Task<IActionResult> SaveObligationApplicability(
        [FromBody] EventObligationApplicabilitySaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await eventScopeService.SaveObligationApplicabilityAsync(body, cancellationToken);
        return result.Success
            ? Ok(new { applicabilityId = result.ApplicabilityId })
            : BadRequest(new { error = result.Error });
    }

    [HttpGet("obligation-coverage")]
    public async Task<IActionResult> ListObligationCoverage(
        [FromQuery] long   organizationId,
        [FromQuery] string scopeDimension,
        [FromQuery] long?  eventTypeId,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (!EventScopeDimensions.IsConcrete(scopeDimension))
            return BadRequest(new { error = "scopeDimension must be ORG_ROLE, ASSET_CATEGORY or PROFILE." });

        return Ok(await eventScopeService.ListObligationCoverageAsync(
            organizationId, scopeDimension, eventTypeId, cancellationToken));
    }

    // ============================================================
    // Checklists tab + View Mapped Profiles reverse lookup (migration 344)
    //
    // A "checklist" here is an obligation+event combination -- what EXISTS,
    // not what one role/asset-category/profile decided (that is the
    // obligation-mappings endpoints above). Nested under /scope/ like every
    // other route in this controller, so the Web tier's catch-all proxy
    // reaches it with no routing change.
    // ============================================================
    [HttpGet("checklists")]
    public async Task<IActionResult> ListEventDrivenChecklists(
        [FromQuery] long   organizationId,
        [FromQuery] long?  eventTypeId,
        [FromQuery] string? search,
        [FromQuery] int    pageNumber = 1,
        [FromQuery] int    pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var q = new EventDrivenChecklistQuery(organizationId, eventTypeId, search, pageNumber, pageSize);
        return Ok(await eventScopeService.ListEventDrivenChecklistsAsync(q, cancellationToken));
    }

    [HttpGet("checklist-mapped-profiles")]
    public async Task<IActionResult> ListChecklistMappedProfiles(
        [FromQuery] long   organizationId,
        [FromQuery] long   eventTypeId,
        [FromQuery] long?  obligationId,
        [FromQuery] long?  localPracticeObligationId,
        [FromQuery] long?  localInstanceObligationId,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0 || eventTypeId <= 0)
            return BadRequest(new { error = "organizationId and eventTypeId are required." });

        var identityCount = (obligationId is > 0 ? 1 : 0)
                           + (localPracticeObligationId is > 0 ? 1 : 0)
                           + (localInstanceObligationId is > 0 ? 1 : 0);
        if (identityCount != 1)
            return BadRequest(new { error = "Name exactly one of obligationId, localPracticeObligationId or localInstanceObligationId." });

        var q = new EventChecklistMappedProfilesQuery(
            organizationId, eventTypeId, obligationId, localPracticeObligationId, localInstanceObligationId);
        return Ok(await eventScopeService.ListChecklistMappedProfilesAsync(q, cancellationToken));
    }

    // ============================================================
    // Custom questions per scope + event (migration 136)
    //
    // These sit next to the obligation list in the Role Master and Asset
    // Category forms. The obligation routes above are unchanged -- both
    // forms call them for the inherited half.
    //
    // PROFILE IS DELIBERATELY NOT ACCEPTED HERE, AND IT IS NOT AN
    // OVERSIGHT. Custom questions are stored as grac_practice.checklist
    // rows keyed by scope_role_id / scope_asset_category_id and served
    // through the CHECKLIST raise path (124), which is a different engine
    // from the obligation path profiles extend. Supporting them per
    // profile means profile_id on checklist and event_checklist_mapping
    // plus a PROFILE branch in sp_event_instance_raise_scoped -- a change
    // to the checklist engine, not to this scoping layer. Until that is
    // done the Profile screen hides the questions panel rather than
    // offering a control that would save nothing.
    // ============================================================
    [HttpGet("questions")]
    public async Task<IActionResult> ListScopeQuestions(
        [FromQuery] long   organizationId,
        [FromQuery] string scopeDimension,
        [FromQuery] string eventTypeCode,
        [FromQuery] long?  scopeRoleId,
        [FromQuery] int?   scopeAssetCategoryId,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (scopeDimension is not (EventScopeDimensions.OrgRole or EventScopeDimensions.AssetCategory))
            return BadRequest(new { error = "scopeDimension must be ORG_ROLE or ASSET_CATEGORY." });
        if (string.IsNullOrWhiteSpace(eventTypeCode))
            return BadRequest(new { error = "eventTypeCode is required." });
        if (scopeDimension == EventScopeDimensions.OrgRole && scopeRoleId is null or <= 0)
            return BadRequest(new { error = "scopeRoleId is required when scopeDimension is ORG_ROLE." });
        if (scopeDimension == EventScopeDimensions.AssetCategory && scopeAssetCategoryId is null or <= 0)
            return BadRequest(new { error = "scopeAssetCategoryId is required when scopeDimension is ASSET_CATEGORY." });

        var q = new ScopeQuestionQuery(organizationId, scopeDimension, scopeRoleId, scopeAssetCategoryId, eventTypeCode);
        return Ok(await eventScopeService.ListScopeQuestionsAsync(q, cancellationToken));
    }

    [HttpPost("questions")]
    public async Task<IActionResult> SaveScopeQuestion(
        [FromBody] ScopeQuestionSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await eventScopeService.SaveScopeQuestionAsync(body, cancellationToken);
        return result.Success
            ? Ok(new { checklistItemId = result.ChecklistItemId })
            : BadRequest(new { error = result.Error });
    }

    // POST rather than DELETE: the underlying procedure soft-deletes, and the
    // Web tier's proxy only forwards GET and POST.
    [HttpPost("questions/delete")]
    public async Task<IActionResult> DeleteScopeQuestion(
        [FromBody] ScopeQuestionDeleteRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await eventScopeService.DeleteScopeQuestionAsync(body, cancellationToken);
        return result.Success
            ? Ok(new { checklistItemId = result.ChecklistItemId })
            : BadRequest(new { error = result.Error });
    }

    // ============================================================
    // Raise
    //
    // A successful raise that produced zero instances is 200, not 201 and
    // not an error: the event happened, nothing was mapped for that role
    // or category. The response carries raisedCount so the caller can show
    // "no checklist configured" instead of a misleading success toast.
    // ============================================================
    [HttpPost("raise")]
    public async Task<IActionResult> Raise(
        [FromBody] EventScopedRaiseRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await eventScopeService.RaiseScopedAsync(body, cancellationToken);
        if (!result.Success) return BadRequest(new { error = result.Error });

        return result.RaisedCount > 0
            ? StatusCode(StatusCodes.Status201Created, new { raisedCount = result.RaisedCount })
            : Ok(new { raisedCount = 0, message = "No checklist is mapped for this subject's scope." });
    }

    [HttpPost("raise/people")]
    public async Task<IActionResult> RaisePeople(
        [FromBody] PeopleLifecycleRaiseRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await eventScopeService.RaisePeopleLifecycleAsync(body, cancellationToken);
        if (!result.Success) return BadRequest(new { error = result.Error });

        logger.LogInformation(
            "People lifecycle {Action} raised {Count} checklist instance(s) for employee {EmployeeId}",
            body.LifecycleAction, result.RaisedCount, body.EmployeeId);

        return result.RaisedCount > 0
            ? StatusCode(StatusCodes.Status201Created, new { raisedCount = result.RaisedCount })
            : Ok(new { raisedCount = 0, message = "No checklist is mapped for this employee's role." });
    }

    [HttpPost("raise/asset")]
    public async Task<IActionResult> RaiseAsset(
        [FromBody] AssetLifecycleRaiseRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await eventScopeService.RaiseAssetLifecycleAsync(body, cancellationToken);
        if (!result.Success) return BadRequest(new { error = result.Error });

        logger.LogInformation(
            "Asset lifecycle {Action} raised {Count} checklist instance(s) for asset {AssetId}",
            body.LifecycleAction, result.RaisedCount, body.AssetId);

        return result.RaisedCount > 0
            ? StatusCode(StatusCodes.Status201Created, new { raisedCount = result.RaisedCount })
            : Ok(new { raisedCount = 0, message = "No checklist is mapped for this asset's category." });
    }

    // ============================================================
    // Inbox / detail / trace
    // ============================================================
    [HttpGet("inbox")]
    public async Task<IActionResult> Inbox(
        [FromQuery] long    organizationId,
        [FromQuery] long?   ownerEmployeeId,
        [FromQuery] string? subjectEntity,
        [FromQuery] string? statusFilter,
        [FromQuery] bool    overdueOnly = false,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (subjectEntity is not null && !EventSubjectEntities.IsValid(subjectEntity))
            return BadRequest(new { error = "subjectEntity must be EMPLOYEE or ASSET." });

        var q = new EventChecklistInboxQuery(
            organizationId, ownerEmployeeId, subjectEntity, statusFilter, overdueOnly);
        return Ok(await eventScopeService.ListInboxAsync(q, cancellationToken));
    }

    [HttpGet("instances/{eventInstanceId:long}")]
    public async Task<IActionResult> InstanceDetail(
        long eventInstanceId,
        [FromQuery] long organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await eventScopeService.GetInstanceDetailAsync(
            organizationId, eventInstanceId, cancellationToken);

        return result.Header is null ? NotFound() : Ok(result);
    }

    // Obligation line items live in their own table, so they need their own
    // write path. The checklist equivalent stays on WorkflowController's
    // POST /event-instance-items -- one endpoint per store, no id ambiguity.
    [HttpPost("instance-obligations")]
    public async Task<IActionResult> SaveObligationResult(
        [FromBody] EventInstanceObligationSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var (success, error) = await eventScopeService.SaveObligationResultAsync(body, cancellationToken);
        return success
            ? Ok(new { eventInstanceObligationId = body.EventInstanceObligationId })
            : BadRequest(new { error });
    }

    [HttpGet("trace")]
    public async Task<IActionResult> Trace(
        [FromQuery] long    organizationId,
        [FromQuery] string? subjectEntity,
        [FromQuery] long?   subjectRecordId,
        [FromQuery] long?   eventInstanceId,
        [FromQuery] bool    gapsOnly = false,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (subjectEntity is not null && !EventSubjectEntities.IsValid(subjectEntity))
            return BadRequest(new { error = "subjectEntity must be EMPLOYEE or ASSET." });

        var q = new EventResolutionTraceQuery(
            organizationId, subjectEntity, subjectRecordId, eventInstanceId, gapsOnly);
        return Ok(await eventScopeService.ListResolutionTraceAsync(q, cancellationToken));
    }
}
