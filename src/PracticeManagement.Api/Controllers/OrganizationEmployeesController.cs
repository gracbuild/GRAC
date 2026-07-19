// =====================================================================
// OrganizationEmployeesController (Api tier)
//
// Route: /api/practice/organizations/{organizationId}/employees
//
// Kept in its own file — the existing OrganizationsController owns the
// scope/allowed-orgs contract; this controller owns the employee lookup
// used by workflow modals (e.g. Task Center "New Task").
// =====================================================================
using System.Data;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Infrastructure;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/organizations")]
public sealed class OrganizationEmployeesController(
    IConfiguration configuration,
    ILogger<OrganizationEmployeesController> logger) : ControllerBase
{
    [HttpGet("{organizationId:long}/employees")]
    public async Task<IActionResult> Get(long organizationId, CancellationToken cancellationToken)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });

        var connString = SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connString))
            return StatusCode(StatusCodes.Status503ServiceUnavailable,
                new { error = "PracticeManagement connection string is not configured." });

        try
        {
            await using var connection = new SqlConnection(connString);
            await connection.OpenAsync(cancellationToken);

            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_organization_get_employees";
            var p = command.CreateParameter();
            p.ParameterName = "@organization_id";
            p.DbType = DbType.Int64;
            p.Value = organizationId;
            command.Parameters.Add(p);

            var list = new List<InstanceEmployeeOption>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                list.Add(new InstanceEmployeeOption(
                    EmployeeId:   Convert.ToInt64(reader["EmployeeId"]),
                    EmployeeCode: reader["EmployeeCode"]?.ToString() ?? "",
                    EmployeeName: reader["EmployeeName"]?.ToString() ?? "",
                    Email:        reader["Email"]       as string,
                    Designation:  reader["Designation"] as string,
                    Department:   reader["Department"]  as string));
            }
            return Ok(list);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrganizationEmployeesController.Get failed for org {OrgId}", organizationId);
            return StatusCode(StatusCodes.Status500InternalServerError, new { error = ex.Message });
        }
    }
}
