// =====================================================================
// SubscriptionRequestController  (migration 511)
//
// Route: /api/practice/subscription-requests/...
//   GET  /?status=&search=     every organization's requests (Pending first)
//   POST /{id}/decision        approve / reject one Pending request
//
// Organization Management -> Subscription Requests. The same queue Control
// Management's Subscription Requests screen works (068): both modules call
// sp_repository_subscription_request_list / _decide.
//
// The Web tier (SubscriptionRequestController there) decides who may call
// this: the subscription-requests menu grant (VIEW / APPROVE) AND a
// GLOBAL-scope sign-in, because a request belongs to another organization.
// It also sets Actor from the session; this controller never trusts a
// browser for it.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/subscription-requests")]
public sealed class SubscriptionRequestController(
    ISubscriptionRequestService requestService,
    ILogger<SubscriptionRequestController> logger) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> List(
        [FromQuery] long? requestId,
        [FromQuery] string? status = "Pending",
        [FromQuery] string? search = "",
        CancellationToken cancellationToken = default)
    {
        try
        {
            return Ok(new { data = await requestService.ListAsync(requestId, status, search, cancellationToken) });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "SubscriptionRequestController.List failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("{id:long}/decision")]
    public async Task<IActionResult> Decide(long id, [FromBody] SubscriptionRequestDecisionRequest body, CancellationToken cancellationToken)
    {
        if (body is null || string.IsNullOrWhiteSpace(body.Decision))
            return BadRequest(new { error = "decision is required (Approve or Reject)." });
        if (string.IsNullOrWhiteSpace(body.Actor))
            return BadRequest(new { error = "actor is required." });

        try
        {
            var result = await requestService.DecideAsync(id, body.Decision.Trim(), body.Remark, body.Actor.Trim(), cancellationToken);
            return result.Success ? Ok(result) : BadRequest(new { error = result.Message, requestId = id });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "SubscriptionRequestController.Decide failed for request {RequestId}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }
}
