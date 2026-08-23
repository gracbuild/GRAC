// =====================================================================
// DocumentAcknowledgementController  (charter §5)
//
// Route: /api/practice/document-acknowledgements/...
// Independent of every other controller per charter §5 non-negotiable.
//
// Endpoints:
//   GET  pending?organizationId=&page=&pageSize=
//   POST /                                        (create batch; JSON body)
//   GET  /?organizationId=&page=&pageSize=        (list batches)
//   GET  {id}/documents                           (docs inside a batch)
//   GET  {id}/documents/{documentId}/users        (users tied to a doc in a batch)
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/document-acknowledgements")]
public sealed class DocumentAcknowledgementController(
    IDocumentAcknowledgementService ack,
    ILogger<DocumentAcknowledgementController> logger) : ControllerBase
{
    [HttpGet("pending")]
    public async Task<IActionResult> Pending(
        [FromQuery] long organizationId,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 50,
        CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await ack.ListPendingAsync(organizationId, page, pageSize, ct));
    }

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] DocumentAckCreateRequest request, CancellationToken ct)
    {
        try
        {
            if (request is null) return BadRequest(new { success = false, error = "request body is required." });
            var result = await ack.CreateAsync(request, ct);
            return result.Success ? Ok(result) : BadRequest(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "DocumentAcknowledgement.Create failed");
            return BadRequest(new { success = false, error = ex.Message, inner = ex.InnerException?.Message });
        }
    }

    [HttpGet]
    public async Task<IActionResult> List(
        [FromQuery] long organizationId,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await ack.ListBatchesAsync(organizationId, page, pageSize, ct));
    }

    [HttpGet("{acknowledgementId:long}/documents")]
    public async Task<IActionResult> BatchDocuments(long acknowledgementId, CancellationToken ct)
        => Ok(await ack.ListBatchDocumentsAsync(acknowledgementId, ct));

    [HttpGet("{acknowledgementId:long}/documents/{documentId:long}/users")]
    public async Task<IActionResult> DocumentUsers(long acknowledgementId, long documentId, CancellationToken ct)
        => Ok(await ack.ListDocumentUsersAsync(acknowledgementId, documentId, ct));

    // ==================== USER SIDE (Phase 3) ========================
    //
    // The employeeId identifying "me" is passed as a query string param.
    // The Web tier is responsible for filling it in from the session --
    // this Api layer does not read cookies. A malicious caller could pass
    // any employeeId, which is fine because the WEB tier is the only
    // reachable public entry point and it overrides the value from the
    // session before proxying (see Web DocumentAcknowledgementController).

    [HttpGet("my/batches")]
    public async Task<IActionResult> MyBatches(
        [FromQuery] long employeeId,
        [FromQuery] bool includeCompleted = false,
        [FromQuery] bool isAdmin          = false,
        [FromQuery] long? organizationId  = null,
        CancellationToken ct = default)
    {
        if (!isAdmin && employeeId <= 0)
            return BadRequest(new { error = "employeeId is required (or set isAdmin=true with organizationId)." });
        if (isAdmin && (organizationId is null || organizationId <= 0))
            return BadRequest(new { error = "organizationId is required when isAdmin=true." });
        return Ok(await ack.ListUserBatchesAsync(employeeId, includeCompleted, isAdmin, organizationId, ct));
    }

    [HttpGet("my/batches/{acknowledgementId:long}/documents")]
    public async Task<IActionResult> MyBatchDocuments(
        long acknowledgementId,
        [FromQuery] long employeeId,
        [FromQuery] bool isAdmin = false,
        CancellationToken ct = default)
    {
        if (!isAdmin && employeeId <= 0)
            return BadRequest(new { error = "employeeId is required (or set isAdmin=true)." });
        return Ok(await ack.ListUserDocumentsAsync(acknowledgementId, employeeId, isAdmin, ct));
    }

    [HttpPost("my/acknowledge")]
    public async Task<IActionResult> MyAcknowledge(
        [FromQuery] long employeeId,
        [FromBody]  DocumentAckUserAckRequest request,
        CancellationToken ct)
    {
        try
        {
            if (employeeId <= 0) return BadRequest(new { success = false, error = "employeeId is required." });
            if (request is null) return BadRequest(new { success = false, error = "request body is required." });
            var result = await ack.AcknowledgeAsync(employeeId, request, ct);
            return result.Success ? Ok(result) : BadRequest(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "DocumentAcknowledgement.MyAcknowledge failed");
            return BadRequest(new { success = false, error = ex.Message, inner = ex.InnerException?.Message });
        }
    }
}
