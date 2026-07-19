// =====================================================================
// FeatureFlagController  (charter §7 cross-cut, §12.1.6)
//
// Route: /api/practice/feature-flags/...
//
// The Api tier is the single owner of the DB — every feature-flag probe
// goes through here (via IFeatureFlagService which delegates to the
// shared SqlConnectionStringResolver). The Web tier proxies to this
// endpoint instead of opening its own SQL connection.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/feature-flags")]
public sealed class FeatureFlagController(IFeatureFlagService featureFlagService) : ControllerBase
{
    /// <summary>
    /// GET /api/practice/feature-flags/status?featureCode=screen.tasks&amp;organizationId=4
    /// Response: { enabled, organizationId, featureCode, reason }
    /// </summary>
    [HttpGet("status")]
    public async Task<IActionResult> Status(
        [FromQuery] string featureCode,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        var status = await featureFlagService.IsEnabledAsync(organizationId, featureCode, cancellationToken);
        return Ok(new
        {
            enabled        = status.Enabled,
            organizationId = status.OrganizationId,
            featureCode    = status.FeatureCode,
            reason         = status.Reason
        });
    }
}
