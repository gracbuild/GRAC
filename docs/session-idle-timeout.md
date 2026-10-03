# Session idle timeout and redirect to login

**Config:** `Security:TokenLifetimeMinutes` (Web `appsettings.json`, default **30**)
**Server:** `Web/Program.cs` (session options + idle-timeout middleware),
`Web/Security/PracticeSessionIdentity.cs` (`BackgroundRequestHeader`),
`Web/Controllers/PracticeManagementGatewayController.cs` (`InvokeAsync`)
**Browser:** `Web/wwwroot/js/site.js`, `Web/Views/Shared/_Layout.cshtml`
**Database / API:** no change. The API still validates the same signed token
the same way. Only the Web tier now re-issues it.

## The problem

Users were thrown out while actively working. There were three timers, and they
did not agree:

| Timer | Setting | Behaviour before |
| --- | --- | --- |
| Access token (Web → API) | `Security:TokenLifetimeMinutes` = 30 | Issued **once** at sign-in (`LoginController`) and never renewed, so it expired a fixed 30 min after login. |
| ASP.NET session | `IdleTimeout` = 30 (hard-coded) | Sliding, but the sidebar notification poll (`_Layout.cshtml`, every 5 min) kept it alive forever. |
| Request freshness | `Security:RequestValidityMinutes` = 5 | Per request (anti-replay). Not a sign-in timeout, and unchanged. |

So exactly 30 minutes after login, every API call failed. The API answered 401,
`SecurePracticeClient` turned that into "rejected the authorization token…",
and the gateway returned it as a **502**. The session still looked valid, so
the user got an error message on the page instead of the login page.

## The behaviour now

- **Timeout = 30 minutes of inactivity** (`Security:TokenLifetimeMinutes`). The session's
  `IdleTimeout` reads the same key, so the two cannot drift apart.
- Every request **the user makes** re-issues the token (same subject, same
  roles), so it expires 30 min after the last activity.
- Requests the page makes by itself carry `X-PM-Background: 1` and do
  **not** renew the token. Today that is only the notification poll. Give
  any future auto-refresh or poll the same header, or an idle tab will
  never time out.
- When the token has expired, the middleware clears the session. From then on,
  every existing `IsSignedIn()` guard treats the caller as signed out:
  - page requests → `PracticeController.RedirectToLogin()` → `/Login?returnUrl=<page>`
  - JSON endpoints → `401 { "Session expired…" }`

## Going to the login page

`site.js`, on every layout page (the login pages set no `pmLoginUrl`, so it
does nothing there):

1. **Any same-origin `fetch` answered 401** sends the browser to
   `pmLoginUrl?returnUrl=<current page>`. This is one global handler, so screens
   that only showed "Session expired" now redirect too.
2. **Idle timer.** After `pmSessionTimeoutMinutes` (+5 s grace) without a
   non-background request, the page reloads and the server redirects it to the
   login page. If another tab kept the sign-in alive, the reload simply
   stays on the page.

After signing in again, `LoginController` returns the user to `returnUrl`.

`PracticeManagementGatewayController.InvokeAsync` now maps
`UnauthorizedAccessException` (no token in the session) to **401** instead of
502, for the same reason.

## Changing the timeout

Set `Security:TokenLifetimeMinutes` in the **Web** `appsettings`. The session
and the browser timer both follow it. The API's copy of the key is not used for
this (the API only validates tokens).
