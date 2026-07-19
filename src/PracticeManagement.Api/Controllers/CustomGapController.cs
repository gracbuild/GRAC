// =====================================================================
// CustomGapController
//
// Route: /api/practice/gaps/custom/...
// Delegates to ICustomGapService.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/gaps/custom")]
public sealed class CustomGapController(
    ICustomGapService customGapService,
    ILogger<CustomGapController> logger) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> List(
        [FromQuery] long? organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] string? priority,
        [FromQuery] long? ownerEmployeeId,
        [FromQuery] string? search,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        var q = new CustomGapListQuery(
            OrganizationId:   organizationId,
            StatusCode:       statusCode,
            Priority:         priority,
            OwnerEmployeeId:  ownerEmployeeId,
            Search:           search,
            Page:             page,
            PageSize:         pageSize);
        var result = await customGapService.ListAsync(q, cancellationToken);
        return Ok(result);
    }

    [HttpPost]
    public async Task<IActionResult> Open([FromBody] CustomGapOpenRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await customGapService.OpenAsync(body, cancellationToken);
        return result.Success
            ? StatusCode(StatusCodes.Status201Created, new { customGapId = result.CustomGapId })
            : BadRequest(new { error = result.Error });
    }

    [HttpPost("{id:long}/close")]
    public async Task<IActionResult> Close(long id, [FromBody] CustomGapCloseRequest? body, CancellationToken cancellationToken)
    {
        var request = (body ?? new CustomGapCloseRequest(id, null, null)) with { CustomGapId = id };
        var result  = await customGapService.CloseAsync(request, cancellationToken);
        return result.Success
            ? Ok(new { customGapId = result.CustomGapId })
            : BadRequest(new { error = result.Error });
    }
}
