// =====================================================================
// ResolveWorkspaceController
//
// Route: /api/practice/workflow/resolve/...
//
// Nested under the workflow route so the Web tier's WorkflowController
// catch-all proxy forwards these paths unchanged, with its session guard
// and its organizationId check already applied.
//
// Sub-routes:
//   GET  /resolve/instances                  owner-scoped instance list
//   GET  /resolve/instances/{id}             workspace header
//   GET  /resolve/instances/{id}/obligations subscribed obligations
//   POST /resolve/obligations                adopt / edit / un-adopt
//   GET  /resolve/instances/{id}/dependencies dependency cards
//   POST /resolve/dependencies               resolve one dependency
//   POST /resolve/frequency                  execution / assurance cadence
//   POST /resolve/profile                    practice type, criticality,
//                                            business function, owner (222)
//   POST /resolve/retire                     retire the instance     (222)
//   GET  /resolve/instances/{id}/dependency-types  declared categories (222)
//   POST /resolve/dependency-types           declare / undeclare      (222)
//
// CALLER IDENTITY
// ---------------
// Who is asking decides which instances come back, so it is read from
// headers the Web proxy stamps from the session -- never from the query
// string or the body. A browser can send these header names, but the
// proxy overwrites them before the request leaves the Web tier, so the
// values that arrive here are the session's.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/workflow/resolve")]
public sealed class ResolveWorkspaceController(
    IResolveWorkspaceService resolveService,
    ILogger<ResolveWorkspaceController> logger) : ControllerBase
{
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";
    private const string CallerAdminHeader    = "X-PM-Caller-Is-Admin";

    private long? CallerEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private bool CallerIsAdmin =>
        Request.Headers[CallerAdminHeader].ToString() is "1" or "true" or "True";

    private string Actor =>
        CallerEmployeeId is { } id ? $"employee:{id}" : "system";

    // ============================================================
    // Instance list
    // ============================================================
    [HttpGet("instances")]
    public async Task<IActionResult> ListInstances(
        [FromQuery] long    organizationId,
        [FromQuery] string? search,
        [FromQuery] int     pageNumber = 1,
        [FromQuery] int     pageSize   = 25,
        // 287. Opt-in. Ownership scoping is applied independently in the
        // procedure, so this widens WHICH statuses come back, never
        // WHOSE rows.
        [FromQuery] bool    includeRetired = false,
        // 287. Drill-down from Practices / Organization Requirements,
        // which is what the Practice Instances grid offered and this list
        // did not. Ownership scoping in the procedure is unchanged and
        // applies on top, so narrowing to one practice can never widen
        // whose instances a caller sees.
        [FromQuery] long?   practiceId = null,
        [FromQuery] long?   organizationRequirementId = null,
        // 315. Operationalize's Owner / Status filters. Both null = no
        // opinion; the procedure applies the same ownership scoping to
        // ownerEmployeeId as it always has, so this can narrow a caller's
        // own rows but never reach into someone else's.
        [FromQuery] long?   ownerEmployeeId = null,
        [FromQuery] string? status = null,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await resolveService.ListInstancesAsync(new ResolveInstanceQuery(
            OrganizationId:   organizationId,
            CallerEmployeeId: CallerEmployeeId,
            IsAdmin:          CallerIsAdmin,
            Search:           search,
            PageNumber:       pageNumber,
            PageSize:         pageSize,
            IncludeRetired:   includeRetired,
            PracticeId:       practiceId,
            OrganizationRequirementId: organizationRequirementId,
            OwnerEmployeeId:  ownerEmployeeId,
            ImplementationStatus: status), cancellationToken);

        if (!result.Success)
        {
            logger.LogWarning("Resolve instance list failed for organization {OrganizationId}: {Error}",
                organizationId, result.Error);
            return StatusCode(StatusCodes.Status500InternalServerError, new { error = result.Error });
        }

        // isAdmin rides along so the screen can say "showing all instances"
        // versus "showing yours" instead of leaving the user guessing why
        // a colleague's row is or is not there.
        //
        // totalRows/page/pageSize added with migration 290. The grid
        // paged in the procedure long before it had a pager, so it asked
        // for one 200-row page and anything past that was unreachable;
        // returning the total is what lets the UI page properly. Added
        // alongside the existing keys rather than reshaping the payload,
        // so nothing that already reads "data" or "isAdmin" changes.
        // 315. Owners / Statuses ride along with the page, same reasoning
        // as isAdmin above: one round trip fills both the grid and the
        // two new filter dropdowns, and an older UI that never reads
        // these two keys is unaffected by their presence.
        return Ok(new
        {
            data      = result.Rows,
            isAdmin   = CallerIsAdmin,
            totalRows = result.TotalRows,
            page      = pageNumber,
            pageSize  = pageSize,
            owners    = result.Owners,
            statuses  = result.Statuses
        });
    }

    // ============================================================
    // Workspace
    // ============================================================
    [HttpGet("instances/{practiceInstanceId:long}")]
    public async Task<IActionResult> GetInstance(
        long practiceInstanceId,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken = default)
    {
        var result = await resolveService.GetInstanceAsync(
            practiceInstanceId, organizationId, CallerEmployeeId, CallerIsAdmin, cancellationToken);

        // The workspace is reachable by URL, so this endpoint is the gate:
        // the obligation and dependency endpoints below are only ever
        // reached for an instance this one has already opened.
        // isAdmin rides along for the same reason the list endpoint sends
        // it: the workspace has to know whether to offer the Owner field,
        // which migration 222 restricts to an admin caller. The server
        // still refuses a non-admin owner change (52673) -- this only
        // decides whether the control is shown.
        return result.Success
            ? Ok(new { data = result.Instance, isAdmin = CallerIsAdmin })
            : NotFound(new { error = result.Error ?? "Practice instance not found." });
    }

    [HttpGet("instances/{practiceInstanceId:long}/obligations")]
    public async Task<IActionResult> ListObligations(
        long practiceInstanceId,
        [FromQuery] bool includeUnsubscribed = false,
        CancellationToken cancellationToken = default)
    {
        var result = await resolveService.ListObligationsAsync(
            practiceInstanceId, includeUnsubscribed, cancellationToken);

        return result.Success
            ? Ok(new { data = result.Obligations })
            : StatusCode(StatusCodes.Status500InternalServerError, new { error = result.Error });
    }

    [HttpPost("obligations")]
    public async Task<IActionResult> AdoptObligations(
        [FromBody] ResolveObligationAdoptRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await resolveService.AdoptObligationsAsync(
            body with { Actor = Actor }, cancellationToken);

        if (!result.Success) return BadRequest(new { error = result.Error });

        return Ok(new
        {
            data                  = result.Outcomes,
            adoptedCount          = result.AdoptedCount,
            removedCount          = result.RemovedCount,
            unmappedEvidenceTypes = result.UnmappedEvidenceTypes
        });
    }

    [HttpGet("instances/{practiceInstanceId:long}/dependencies")]
    public async Task<IActionResult> ListDependencies(
        long practiceInstanceId,
        CancellationToken cancellationToken = default)
    {
        var result = await resolveService.ListDependenciesAsync(practiceInstanceId, cancellationToken);

        return result.Success
            ? Ok(new { data = result.Categories, resolutions = result.Resolutions })
            : StatusCode(StatusCodes.Status500InternalServerError, new { error = result.Error });
    }

    /// <summary>
    /// Resolves one or more objects against a dependency category. Adding
    /// does not remove: sending A and B leaves an existing C alone, because
    /// "one more" and "only these" are different intentions and the payload
    /// cannot tell them apart. Removal is the endpoint below.
    /// </summary>
    [HttpPost("dependencies")]
    public async Task<IActionResult> SaveDependency(
        [FromBody] ResolveDependencySaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await resolveService.SaveDependencyAsync(
            body with { Actor = Actor }, cancellationToken);

        return result.Success
            ? Ok(new { success = true, message = result.Message })
            : BadRequest(new { error = result.Error });
    }

    /// <summary>
    // The POST /resolve/frequency endpoint and its SaveFrequency handler
    // were retired: the instance no longer has a cadence of its own,
    // per-obligation frequency (Execution and Assurance types only)
    // carries it. The procedure sp_resolve_instance_frequency_save is
    // dropped in migration 235. The Calendar page's assurance-schedule
    // generator still reads pi.assurance_frequency_id directly, which is
    // why the columns and the Configure default remain.

    // ============================================================
    // Instance profile, retirement and dependency categories
    // (migration 222 -- Practice Instance form slimming, stage 2)
    // ============================================================

    /// <summary>
    /// Practice Type, Criticality, Business Function and -- for an admin
    /// caller only -- the Owner. Every value is optional; an absent one
    /// leaves the stored value alone.
    /// </summary>
    [HttpPost("profile")]
    public async Task<IActionResult> SaveProfile(
        [FromBody] ResolveProfileSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await resolveService.SaveProfileAsync(
            body with { Actor = Actor }, CallerEmployeeId, CallerIsAdmin, cancellationToken);

        return result.Success
            ? Ok(new { success = true, message = result.Message })
            : BadRequest(new { error = result.Error });
    }

    /// <summary>
    /// Retires the instance -- status Inactive, never a delete. Migration
    /// 139 reserved this act for the Practice Instances screen; it lives
    /// here now so that screen can eventually go.
    /// </summary>
    [HttpPost("retire")]
    public async Task<IActionResult> RetireInstance(
        [FromBody] ResolveInstanceRetireRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await resolveService.RetireInstanceAsync(
            body with { Actor = Actor }, CallerEmployeeId, CallerIsAdmin, cancellationToken);

        return result.Success
            ? Ok(new { success = true, message = result.Message })
            : BadRequest(new { error = result.Error });
    }

    /// <summary>
    /// Bring a retired instance back (287). The inverse of retire, with
    /// the same ownership rules -- whoever could retire it can restore
    /// it. Without this, retiring was a one-way door with no view of
    /// what had gone through it.
    /// </summary>
    [HttpPost("restore")]
    public async Task<IActionResult> RestoreInstance(
        [FromBody] ResolveInstanceRestoreRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await resolveService.RestoreInstanceAsync(
            body with { Actor = Actor }, CallerEmployeeId, CallerIsAdmin, cancellationToken);

        return result.Success
            ? Ok(new { success = true, message = result.Message })
            : BadRequest(new { error = result.Error });
    }

    [HttpGet("instances/{practiceInstanceId:long}/dependency-types")]
    public async Task<IActionResult> ListDependencyTypes(
        long practiceInstanceId,
        CancellationToken cancellationToken = default)
    {
        var result = await resolveService.ListDependencyTypesAsync(practiceInstanceId, cancellationToken);

        return result.Success
            ? Ok(new { data = result.Rows })
            : StatusCode(StatusCodes.Status500InternalServerError, new { error = result.Error });
    }

    /// <summary>
    /// dependencyTypeIds is the complete desired set, not a delta. A
    /// category that still holds resolved objects is kept and reported in
    /// `blocked` rather than undeclared -- the objects have to be removed
    /// on the dependency card first.
    /// </summary>
    [HttpPost("dependency-types")]
    public async Task<IActionResult> SaveDependencyTypes(
        [FromBody] ResolveDependencyTypeSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await resolveService.SaveDependencyTypesAsync(
            body with { Actor = Actor }, CallerEmployeeId, CallerIsAdmin, cancellationToken);

        return result.Success
            ? Ok(new
              {
                  success      = true,
                  message      = result.Message,
                  addedCount   = result.AddedCount,
                  removedCount = result.RemovedCount,
                  blocked      = result.Blocked
              })
            : BadRequest(new { error = result.Error });
    }

    // ============================================================
    // Organisation-defined obligations (migration 227)
    // ============================================================

    /// <summary>
    /// The rule fields for one obligation type, mirrored from Control
    /// Management's own table for that type. The add form builds its
    /// inputs from these. An unknown type returns an empty list, not an
    /// error — that type simply has no rule fields.
    /// </summary>
    [HttpGet("obligation-types")]
    public async Task<IActionResult> ListObligationTypes(CancellationToken cancellationToken = default)
    {
        var result = await resolveService.ListObligationTypesAsync(cancellationToken);

        return result.Success
            ? Ok(new { data = result.Types })
            : StatusCode(StatusCodes.Status500InternalServerError, new { error = result.Error });
    }

    [HttpGet("obligation-types/{typeCode}/fields")]
    public async Task<IActionResult> ListObligationTypeFields(
        string typeCode,
        CancellationToken cancellationToken = default)
    {
        var result = await resolveService.ListObligationTypeFieldsAsync(typeCode, cancellationToken);

        return result.Success
            ? Ok(new { data = result.Fields })
            : StatusCode(StatusCodes.Status500InternalServerError, new { error = result.Error });
    }

    /// <summary>
    /// Trigger modes and the event type tree — the vocabularies the
    /// mirrored Assurance panel needs (migration 230). Empty lists mean
    /// Control Management 033 is not applied here; the form degrades to
    /// the inferred rules.
    /// </summary>
    [HttpGet("obligation-vocabulary")]
    public async Task<IActionResult> GetObligationVocabulary(CancellationToken cancellationToken = default)
    {
        var result = await resolveService.GetObligationVocabularyAsync(cancellationToken);

        return result.Success
            ? Ok(new { triggerModes = result.TriggerModes, eventTypes = result.EventTypes })
            : StatusCode(StatusCodes.Status500InternalServerError, new { error = result.Error });
    }

    /// <summary>
    /// Which fields apply for which value of the type's driver column —
    /// the Assurance trigger, for instance. Empty means no rule was
    /// learned and the form should show everything.
    /// </summary>
    [HttpGet("obligation-types/{typeCode}/field-rules")]
    public async Task<IActionResult> ListObligationFieldRules(
        string typeCode,
        CancellationToken cancellationToken = default)
    {
        var result = await resolveService.ListObligationFieldRulesAsync(typeCode, cancellationToken);

        return result.Success
            ? Ok(new { data = result.Rules, driverValues = result.DriverValues })
            : StatusCode(StatusCodes.Status500InternalServerError, new { error = result.Error });
    }

    /// <summary>
    /// Adds, edits or removes an obligation the organisation defined
    /// itself on this instance. Published obligations are not reachable
    /// here — the procedure only touches rows with obligation_id NULL.
    /// </summary>
    [HttpPost("local-obligation")]
    public async Task<IActionResult> SaveLocalObligation(
        [FromBody] ResolveLocalObligationSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await resolveService.SaveLocalObligationAsync(
            body with { Actor = Actor }, CallerEmployeeId, CallerIsAdmin, cancellationToken);

        // The id goes out on BOTH paths. On failure it is what lets the
        // form retry against the row already written instead of adding a
        // second obligation.
        return result.Success
            ? Ok(new { success = true, message = result.Message,
                       practiceInstanceObligationId = result.SavedId })
            : BadRequest(new { error = result.Error,
                       practiceInstanceObligationId = result.SavedId });
    }

    // ============================================================
    // Evidence
    // ============================================================
    [HttpGet("instances/{practiceInstanceId:long}/evidence")]
    public async Task<IActionResult> ListEvidence(
        long practiceInstanceId,
        [FromQuery] long? obligationId,
        CancellationToken cancellationToken = default)
    {
        var result = await resolveService.ListEvidenceAsync(practiceInstanceId, obligationId, cancellationToken);

        return result.Success
            ? Ok(new { data = result.Evidence })
            : StatusCode(StatusCodes.Status500InternalServerError, new { error = result.Error });
    }

    [HttpPost("evidence")]
    public async Task<IActionResult> SaveEvidence(
        [FromBody] ResolveEvidenceSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await resolveService.SaveEvidenceAsync(
            body with { Actor = Actor }, cancellationToken);

        return result.Success
            ? Ok(new { success = true, message = result.Message })
            : BadRequest(new { error = result.Error });
    }

    [HttpPost("dependencies/remove")]
    public async Task<IActionResult> RemoveDependency(
        [FromBody] ResolveDependencyRemoveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await resolveService.RemoveDependencyAsync(
            body with { Actor = Actor }, cancellationToken);

        return result.Success
            ? Ok(new { success = true, message = result.Message })
            : BadRequest(new { error = result.Error });
    }

    /// <summary>
    /// Migration 238. The Operationalize page's dependency table saves each
    /// row here: whatever is in <c>objects</c> becomes the desired set for
    /// this category on this instance, absent rows are retired.
    /// </summary>
    [HttpPost("dependency-category")]
    public async Task<IActionResult> SyncDependencyCategory(
        [FromBody] ResolveDependencyCategorySyncRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await resolveService.SyncDependencyCategoryAsync(
            body with { Actor = Actor }, CallerEmployeeId, CallerIsAdmin, cancellationToken);

        return result.Success
            ? Ok(new { success = true, message = result.Message })
            : BadRequest(new { error = result.Error });
    }
}
