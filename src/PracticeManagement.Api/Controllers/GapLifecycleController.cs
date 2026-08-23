// =====================================================================
// GapLifecycleController  (charter §5)  -- Gap Centre v1.0
//
// Route: /api/practice/gap-lifecycle/...
// Independent of the existing gap / custom-gap controllers per AES §3.
//
// Endpoints:
//   GET  states
//   GET  actions?fromStateCode=...
//   POST gaps/{id}/transition                    { actionCode, remark, ... }
//   GET  gaps/{id}/analysis
//   PUT  gaps/{id}/analysis                      { severity, impact, rca, ... }
//   GET  gaps/{id}/downstream?includeCancelled=  list task/exception/risk links
//   POST gaps/{id}/downstream                    add a link
//   POST downstream/{linkId}/cancel              soft-cancel a link
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/gap-lifecycle")]
public sealed class GapLifecycleController(
    IGapLifecycleService svc,
    ILogger<GapLifecycleController> logger) : ControllerBase
{
    // ---- header (bootstrap context for the Gap Detail page) ----

    [HttpGet("gaps/{customGapId:long}/header")]
    public async Task<IActionResult> Header(long customGapId, CancellationToken ct)
    {
        var h = await svc.GetHeaderAsync(customGapId, ct);
        return h is null ? NotFound() : Ok(h);
    }

    // ---- materialize (on demand for Implementation-tab gaps) ----
    // Idempotent: returns existing custom_gap_id if one already
    // materialized for this (practice_instance, org), else creates one.
    [HttpPost("materialize-from-instance")]
    public async Task<IActionResult> MaterializeFromInstance(
        [FromBody] GapMaterializeFromInstanceRequest request, CancellationToken ct)
    {
        try
        {
            if (request is null) return BadRequest(new { success = false, error = "request body is required." });
            var result = await svc.MaterializeFromInstanceAsync(request, ct);
            return result.Success ? Ok(result) : BadRequest(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "GapLifecycle.MaterializeFromInstance failed for {InstanceId}", request?.PracticeInstanceId);
            return BadRequest(new { success = false, error = ex.Message, inner = ex.InnerException?.Message });
        }
    }

    // ---- lookups ----

    [HttpGet("states")]
    public async Task<IActionResult> States(CancellationToken ct)
        => Ok(await svc.ListStatesAsync(ct));

    [HttpGet("actions")]
    public async Task<IActionResult> Actions([FromQuery] string fromStateCode, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(fromStateCode))
            return BadRequest(new { error = "fromStateCode is required." });
        return Ok(await svc.ListActionsFromAsync(fromStateCode, ct));
    }

    // ---- transition ----

    [HttpPost("gaps/{customGapId:long}/transition")]
    public async Task<IActionResult> Transition(long customGapId,
        [FromBody] GapLifecycleTransitionRequest request, CancellationToken ct)
    {
        try
        {
            if (request is null) return BadRequest(new { success = false, error = "request body is required." });
            var result = await svc.TransitionAsync(customGapId, request, ct);
            return result.Success ? Ok(result) : BadRequest(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "GapLifecycle.Transition failed for {GapId}", customGapId);
            return BadRequest(new { success = false, error = ex.Message, inner = ex.InnerException?.Message });
        }
    }

    // ---- analysis ----

    [HttpGet("gaps/{customGapId:long}/analysis")]
    public async Task<IActionResult> GetAnalysis(long customGapId, CancellationToken ct)
    {
        var a = await svc.GetAnalysisAsync(customGapId, ct);
        return a is null ? NotFound() : Ok(a);
    }

    [HttpPut("gaps/{customGapId:long}/analysis")]
    public async Task<IActionResult> SaveAnalysis(long customGapId,
        [FromBody] GapAnalysisSaveRequest request, CancellationToken ct)
    {
        try
        {
            if (request is null) return BadRequest(new { success = false, error = "request body is required." });
            var result = await svc.SaveAnalysisAsync(customGapId, request, ct);
            return result.Success ? Ok(result) : BadRequest(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "GapLifecycle.SaveAnalysis failed for {GapId}", customGapId);
            return BadRequest(new { success = false, error = ex.Message, inner = ex.InnerException?.Message });
        }
    }

    // ---- linked artefacts (new; feeds the Analysis-tab chip strip) ----
    [HttpGet("gaps/{customGapId:long}/linked-artefacts")]
    public async Task<IActionResult> ListLinkedArtefacts(long customGapId, CancellationToken ct)
        => Ok(await svc.ListLinkedArtefactsAsync(customGapId, ct));

    // ---- downstream links (retained for backward compat / historical data) ----

    [HttpGet("gaps/{customGapId:long}/downstream")]
    public async Task<IActionResult> ListDownstream(long customGapId,
        [FromQuery] bool includeCancelled = false, CancellationToken ct = default)
        => Ok(await svc.ListDownstreamAsync(customGapId, includeCancelled, ct));

    [HttpPost("gaps/{customGapId:long}/downstream")]
    public async Task<IActionResult> AddDownstream(long customGapId,
        [FromBody] GapDownstreamLinkAddRequest request, CancellationToken ct)
    {
        try
        {
            if (request is null) return BadRequest(new { success = false, error = "request body is required." });
            var id = await svc.AddDownstreamAsync(customGapId, request, ct);
            return Ok(new { success = id > 0, linkId = id });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "GapLifecycle.AddDownstream failed for {GapId}", customGapId);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }

    [HttpPost("downstream/{linkId:long}/cancel")]
    public async Task<IActionResult> CancelDownstream(long linkId,
        [FromBody] GapDownstreamLinkCancelRequest request, CancellationToken ct)
    {
        try
        {
            if (request is null) return BadRequest(new { success = false, error = "request body is required." });
            var ok = await svc.CancelDownstreamAsync(linkId, request, ct);
            return ok ? Ok(new { success = true, linkId }) : BadRequest(new { success = false, error = "Link not found or already cancelled." });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "GapLifecycle.CancelDownstream failed for {LinkId}", linkId);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }
}
