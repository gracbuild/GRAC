// =====================================================================
// PracticeObligationController
//
// Route: /api/practice/practice-obligations
//
// The practice-level obligation (migration 307): authored once against a
// PRACTICE and applying to every Practice Instance of it.
//
//   GET  /practice-obligations?practiceId=&organizationId=   the definitions
//   POST /practice-obligations                               add / edit / retire
//   POST /practice-obligations/fan-out                       reconcile
//
// WHY A SEPARATE CONTROLLER FROM ResolveWorkspaceController
// ---------------------------------------------------------
// That one is nested under the workflow route because everything on it
// is scoped to ONE practice instance and the Web tier's catch-all proxy
// applies an instance-owner check on the way through. A practice-level
// obligation is not an instance's to own -- it is the practice's -- so it
// gets its own route rather than borrowing a guard that asks the wrong
// question.
//
// CALLER IDENTITY
// ---------------
// Read from the headers the Web proxy stamps from the session, never
// from the query string or the body -- the same discipline
// ResolveWorkspaceController applies. A browser can send these header
// names; the proxy overwrites them before the request leaves the Web
// tier, so what arrives here is the session's.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/practice-obligations")]
public sealed class PracticeObligationController(
    IPracticeObligationService obligationService,
    ILogger<PracticeObligationController> logger) : ControllerBase
{
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";

    private long? CallerEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private string Actor =>
        CallerEmployeeId is { } id ? $"employee:{id}" : "system";

    /// <summary>
    /// The practice-level obligations of one practice, with a count of
    /// how many instances currently carry each.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> List(
        [FromQuery] long practiceId,
        [FromQuery] long? organizationId,
        [FromQuery] bool includeRetired = false,
        CancellationToken cancellationToken = default)
    {
        if (practiceId <= 0) return BadRequest(new { error = "practiceId is required." });

        var result = await obligationService.ListAsync(
            practiceId, organizationId, includeRetired, cancellationToken);

        return result.Success
            ? Ok(new { data = result.Obligations })
            : StatusCode(StatusCodes.Status500InternalServerError, new { error = result.Error });
    }

    /// <summary>
    /// Adds, edits or retires one practice-level obligation. The
    /// procedure fans the change out to every active instance of the
    /// practice before it returns, so the counts on the response describe
    /// what actually happened rather than what was scheduled.
    /// </summary>
    [HttpPost]
    public async Task<IActionResult> Save(
        [FromBody] PracticeObligationSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await obligationService.SaveAsync(body with { Actor = Actor }, cancellationToken);

        // The id goes out on BOTH paths. On failure it is what lets the
        // form retry against the row already written instead of adding a
        // second obligation -- see migration 233.
        return result.Success
            ? Ok(new { success = true, message = result.Message,
                       practiceObligationId = result.PracticeObligationId,
                       copiesCreated = result.CopiesCreated,
                       copiesUpdated = result.CopiesUpdated,
                       copiesRetired = result.CopiesRetired,
                       evidenceSynced = result.EvidenceSynced })
            : BadRequest(new { error = result.Error,
                       practiceObligationId = result.PracticeObligationId });
    }

    /// <summary>
    /// Reconciles an instance (or a whole practice) against the
    /// practice's definitions. Idempotent, and safe to call on load —
    /// which is how an instance created after a definition existed picks
    /// its copies up without anyone pressing Save. Migration 304 set that
    /// precedent for evidence; this is the same argument for obligations.
    /// </summary>
    [HttpPost("fan-out")]
    public async Task<IActionResult> FanOut(
        [FromQuery] long? practiceId,
        [FromQuery] long? practiceObligationId,
        [FromQuery] long? practiceInstanceId,
        CancellationToken cancellationToken = default)
    {
        var result = await obligationService.FanOutAsync(
            practiceId, practiceObligationId, practiceInstanceId, Actor, cancellationToken);

        if (!result.Success)
        {
            logger.LogWarning("Practice obligation fan-out failed: {Error}", result.Error);
            return BadRequest(new { error = result.Error });
        }

        return Ok(new { success = true,
                        copiesCreated = result.CopiesCreated,
                        copiesUpdated = result.CopiesUpdated,
                        copiesRetired = result.CopiesRetired,
                        evidenceSynced = result.EvidenceSynced });
    }
}
