# Forgot password -- reset by email link (migration 529, 2026-11-10)

Request: the login page had no "Forgot password?" link. The 2026-11-03 login restyle left it out because there was no reset flow behind it. Decided with sir: an emailed, one-time, expiring reset link.

## Flow

1. Login page -> **Forgot password?** (under the password field) -> `Login/ForgotPassword`.
2. The visitor enters their User ID / Email ID. Web -> API `secure/password-reset-request`.
   - The API finds the active employee with the sign-in predicate (`ResolveIdentityAsync`: active employee, active record status, employee code **or** email).
   - If the account has an email and its organization is not **SSO Only** (466), the API generates a 32-byte random token and `sp_password_reset_request` stores only its SHA-256.
   - The raw token goes back to the Web tier once, over the encrypted bootstrap channel.
3. The Web tier emails `<Email:LoginUrl>/ResetPassword?token=...` through `PracticeEmailService.SendPasswordResetAsync`.
4. The page always shows the same text: "If an active account matches, a reset link has been sent ...". That holds for unknown accounts, accounts with no email, SSO Only organizations and the hourly limit, so the page cannot be used to find out which accounts exist. The reason is written to the API log only.
5. The link opens `Login/ResetPassword`. `secure/password-reset-validate` (`sp_password_reset_validate`) checks that the token is Open, not expired, and that the employee is still Active.
   - If so, the page shows the account and the New / Confirm password fields.
   - If not, it shows "invalid or expired" with a **Request a new link** button.
6. Save -> `secure/password-reset-complete` -> `sp_password_reset_complete`. In one transaction it:
   - marks the token Used and closes the employee's other open tokens;
   - sets the password through `sp_org_user_set_password` (208), which also clears `force_password_change`.
7. Web redirects to the login page with `?reset=done`, which shows "Your password has been reset. Sign in with your new password." The reset never creates a session by itself.

## Rules

- Same password rules as Change Password: `UserProvisioning:MinimumPasswordLength`, and the password must not be the default password.
- A token works once, for `PasswordReset:TokenMinutes` (Api, default 30, clamped 5-1440). A new request supersedes the employee's open tokens, so only the newest link works.
- At most `PasswordReset:MaxPerHour` (Api, default 5) requests per employee per hour. Beyond that nothing is sent, and the page shows the same text.
- All four Login POSTs (sign-in, change password, forgot, reset) share the existing `login` rate limit of 5 per minute per IP.
- The configured ReviewLogin admin (appsettings, not a database user) has no database password, so it cannot be reset this way.

## Configuration

| Where | Key | Notes |
|---|---|---|
| Web | `Email:SmtpHost`, `Email:FromAddress` (+ `SmtpPort`, `EnableSsl`, `Username`, `Password`, `FromName`, `ReplyTo`) | Required. If these are blank, Forgot password says "Password reset by email is not set up yet. Contact your administrator." |
| Web | `Email:LoginUrl` | The absolute login URL, e.g. `https://host/PracticeManagement/Login`. The link is `<LoginUrl>/ResetPassword`. **Required outside Development:** building the link from the request Host header would let a forged Host send a victim a link to another server. In Development, if it is blank, the request host is used. The administrator credentials email uses the same key. |
| Web | `Email:PasswordResetSubject` | Default "Reset your GRAC password". |
| Api | `PasswordReset:TokenMinutes`, `PasswordReset:MaxPerHour` | Defaults 30 and 5. |

## API contract (bootstrap token, like `secure/authenticate`)

| Endpoint | Data in | Result |
|---|---|---|
| `POST secure/password-reset-request` | `{ loginId, requestedIp }` | Success + Data `{ Token, Email, EmployeeName, ExpiresInMinutes }` when a link was issued.<br>Success with no Data when nothing was issued.<br>Success false, Field `unavailable`, when 529 is missing or the DB is unreachable. |
| `POST secure/password-reset-validate` | `{ token }` | Success + Data `{ Email, EmployeeName }`, or Success false. |
| `POST secure/password-reset-complete` | `{ token, newPassword }` | Success true when the password was changed.<br>Success false, Field `invalid`, when the link is invalid or expired (THROW 55983 / 52322). |

## Database (529)

- **Table `grac_practice.password_reset_token`:** `reset_token_id`, `employee_id` (FK), `token_hash` (unique), `status` (Open / Used / Superseded), `requested_dt`, `expires_dt`, `requested_ip`, `used_dt`.
- **`sp_password_reset_request @employee_id, @token_hash, @expiry_minutes, @requested_ip, @max_per_hour`:** returns `Issued`, `Reason` (issued / limit / inactive).
- **`sp_password_reset_validate @token_hash`:** returns one row, or none.
- **`sp_password_reset_complete @token_hash, @password_hash`:** THROW 55983 when the link is not usable; 55984 when the hash is missing.
- Errors 55981-55984. Rollback: `529_password_reset_by_email_rollback.sql`.

## Files

| Layer | File |
|---|---|
| DB | `database/529_password_reset_by_email.sql` (+ rollback) |
| Api | `Services/PracticeAuthenticationService.cs`: `RequestPasswordResetAsync`, `ValidatePasswordResetAsync`, `CompletePasswordResetAsync`, records `PasswordResetIssue` / `PasswordResetRequestOutcome` / `PasswordResetTarget`, enum `PasswordResetCompletion`, `ProcedureMissingAsync` |
| Api | `Controllers/PracticeRepositoryController.cs`: three endpoints, plus entity types in `Supported` |
| Api | `appsettings.json`: `PasswordReset` |
| Web | `Controllers/LoginController.cs`: `ForgotPassword` GET/POST, `ResetPassword` GET/POST, `ResetLinkBase`, the `?reset=done` notice on Index |
| Web | `Services/PracticeLoginService.cs`, `Services/SecurePracticeClient.cs`: the three calls |
| Web | `Services/PracticeEmailService.cs`: `SendPasswordResetAsync`. The SMTP send is now one private `SendAsync` shared with the credentials email, whose behaviour is unchanged. |
| Web | `Models/PasswordResetViewModels.cs`; `Views/Login/ForgotPassword.cshtml`, `ResetPassword.cshtml` (new, same card as Change Password); `Index.cshtml` (link + notice) |
| Web | `wwwroot/css/login.css`: `.forgot-row`, `.login-back`, `.login-notice`, `a.btn-signin` (the existing `.forgot-link` style is reused) |
| Web | `appsettings.json`: `Email:PasswordResetSubject` |

## Deploy

1. Run `529_password_reset_by_email.sql` and confirm 4 PASS rows.
2. Set SMTP and `Email:LoginUrl` in the server's Web appsettings. Do not copy the repo appsettings over the server's.
3. Deploy the Api and restart it.
4. Publish Web (the views are compiled into the DLL) and copy `login.css`.
