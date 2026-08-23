namespace PracticeManagement.Api.Models;

// Identity returned by grac_practice sign-in, serialized into
// PracticeRepositoryResult.Data by the secure/authenticate endpoint and
// mapped back to PracticeManagement.Web's PracticeLoginResult on the far
// side. Field names must stay in step with that record — the Web tier
// deserializes this JSON case-insensitively.
public sealed record AuthenticatedUser(
    long EmployeeId,
    string EmployeeCode,
    string EmployeeName,
    string Email,
    long OrganizationId,
    string OrganizationCode,
    string OrganizationName,
    long? RoleId,
    string RoleName,
    string DataScope,
    IReadOnlyList<string> Permissions,
    IReadOnlyList<long> AllowedOrganizationIds,
    bool MustChangePassword);
