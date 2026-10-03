// =====================================================================
// CallerViewScope  (migration 415 -- View Data Scope)
//
// Who is READING in the current request, carried for the length of the
// request (AsyncLocal) so every database connection the request opens
// can apply that reader's role View Data Scope (ViewScopeSession).
//
// Set in exactly two places:
//   * the request middleware in Program.cs -- every GET, from the
//     X-PM-Caller-Employee-Id header the Web tier stamps from the SESSION
//     on every call (CallerIdentityHandler, Web); the browser cannot
//     set it;
//   * PracticeRepositoryController's secure/query -- the gateway's
//     encrypted, signed envelope carries callerEmployeeId.
// Writes (POST / PUT / DELETE other than secure/query) never set it, so
// internal cross-record logic in write procedures (syncs, roll-ups,
// duplicate checks) keeps seeing every row; the scope governs what a
// user can VIEW, not the Edit / Delete model.
// =====================================================================
namespace PracticeManagement.Api.Infrastructure;

public static class CallerViewScope
{
    private static readonly AsyncLocal<long?> Reader = new();

    /// <summary>The employee whose View Data Scope applies to reads in
    /// this request; null = no scope (system work, writes, bootstrap admin
    /// without an employee record).</summary>
    public static long? ReadingEmployeeId => Reader.Value;

    public static void BeginRead(long? employeeId) =>
        Reader.Value = employeeId is > 0 ? employeeId : null;

    public static void Clear() => Reader.Value = null;

    /// <summary>Middleware hook: a GET is a read; its reader is the
    /// session-stamped caller header.</summary>
    public static void BeginForRequest(HttpRequest request)
    {
        if (!HttpMethods.IsGet(request.Method) && !HttpMethods.IsHead(request.Method))
        {
            Clear();
            return;
        }
        BeginRead(long.TryParse(request.Headers["X-PM-Caller-Employee-Id"].ToString(), out var id) ? id : null);
    }
}
