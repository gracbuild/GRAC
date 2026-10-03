// =====================================================================
// CallerIdentityHandler  (migration 415 -- View Data Scope)
//
// Stamps the signed-in employee (from the SESSION) onto EVERY call the
// Web tier makes to the Practice Management API through the
// "PracticeManagementApi" HttpClient, as X-PM-Caller-Employee-Id --
// overwriting anything already on the request, so the value can only
// ever come from the session, never from the browser.
//
// Several proxies already stamped it themselves (Workflow, Practice
// Obligation, Repository Change, Management Dashboard); they set the
// same session value, so nothing changes for them. The proxies that did
// not (Risk Centre, Task Board, Gap Register, Exceptions, Audit) now
// carry it too, which is what lets the API apply the reader's role View
// Data Scope to every read (Api: CallerViewScope / ViewScopeSession).
// A sign-in without an employee record (the bootstrap admin) sends no
// header and is unrestricted, as before.
// =====================================================================
namespace PracticeManagement.Web.Security;

public sealed class CallerIdentityHandler(IHttpContextAccessor httpContextAccessor) : DelegatingHandler
{
    public const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        request.Headers.Remove(CallerEmployeeHeader);
        var session = httpContextAccessor.HttpContext?.Session;
        var raw = session?.GetString(PracticeSessionIdentity.EmployeeIdKey);
        if (long.TryParse(raw, out var employeeId) && employeeId > 0)
            request.Headers.TryAddWithoutValidation(CallerEmployeeHeader, employeeId.ToString());
        return base.SendAsync(request, cancellationToken);
    }
}
