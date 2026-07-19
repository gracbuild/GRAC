// =====================================================================
// OrganizationsController  (charter §7 cross-cut)
//
// Route: /api/practice/organizations/...
//
// The Web tier proxies "which organizations can this user see?" here.
// GLOBAL scope (GRAC Admin) → every Active organization; otherwise the
// user's primary org + user_organization_map entries.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/organizations")]
public sealed class OrganizationsController(IOrganizationAccessService accessService) : ControllerBase
{
    /// <summary>
    /// GET /api/practice/organizations/allowed?isGlobalScope=true|false
    ///                                      &amp;email=...&amp;employeeCode=...&amp;primaryOrganizationId=...
    /// Response: { data: [ { organizationId, organizationCode, organizationName } ] }
    /// </summary>
    [HttpGet("allowed")]
    public async Task<IActionResult> Allowed(
        [FromQuery] bool isGlobalScope,
        [FromQuery] string? email,
        [FromQuery] string? employeeCode,
        [FromQuery] long? primaryOrganizationId,
        CancellationToken cancellationToken)
    {
        var rows = await accessService.ListAllowedAsync(
            new AllowedOrganizationQuery(isGlobalScope, email, employeeCode, primaryOrganizationId),
            cancellationToken);

        return Ok(new
        {
            data = rows.Select(r => new
            {
                organizationId   = r.OrganizationId,
                organizationCode = r.OrganizationCode,
                organizationName = r.OrganizationName
            })
        });
    }
}
