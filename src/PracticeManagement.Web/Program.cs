using ControlManagement.Security;
using Microsoft.AspNetCore.HttpOverrides;
using PracticeManagement.Web.Security;
using PracticeManagement.Web.Services;
using System.Threading.RateLimiting;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddControllersWithViews();
builder.Services.AddAntiforgery(options => options.HeaderName = "X-CSRF-TOKEN");
builder.Services.AddHttpClient<SecurePracticeClient>();
// View Data Scope (migration 415): every proxy call to the Practice
// Management API carries the signed-in employee from the session, so the
// API can apply the reader's role View Data Scope on every read.
builder.Services.AddHttpContextAccessor();
builder.Services.AddTransient<CallerIdentityHandler>();
builder.Services.AddHttpClient("PracticeManagementApi").AddHttpMessageHandler<CallerIdentityHandler>();
builder.Services.AddScoped<PracticeLoginService>();
builder.Services.AddScoped<PracticeMenuService>();
builder.Services.AddSingleton<IPracticeEmailService, PracticeEmailService>();
builder.Services.Configure<SecurityOptions>(builder.Configuration.GetSection(SecurityOptions.SectionName));
builder.Services.AddSingleton<EnvelopeCrypto>();
builder.Services.AddSingleton<SignedAccessTokenService>();
builder.Services.AddSingleton<PermissionPolicy>();
builder.Services.AddSingleton<PasswordHasher>();
builder.Services.AddSingleton<NavigationContextProtector>();
builder.Services.AddRateLimiter(options =>
{
    options.AddPolicy("login", context => RateLimitPartition.GetFixedWindowLimiter(
        context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
        _ => new FixedWindowRateLimiterOptions { PermitLimit = 5, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 }));
});
builder.Services.Configure<ForwardedHeadersOptions>(options =>
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto);
builder.Services.AddSession(options =>
{
    options.Cookie.Name = ".PracticeManagement.Session";
    options.Cookie.HttpOnly = true;
    options.Cookie.IsEssential = true;
    options.Cookie.SameSite = SameSiteMode.Strict;
    options.Cookie.SecurePolicy = builder.Environment.IsDevelopment() ? CookieSecurePolicy.SameAsRequest : CookieSecurePolicy.Always;
    // One idle-timeout value for the whole sign-in: the session and the
    // access token (renewed per request below) both come from
    // Security:TokenLifetimeMinutes, so they can never disagree.
    options.IdleTimeout = TimeSpan.FromMinutes(builder.Configuration.GetValue("Security:TokenLifetimeMinutes", 30));
});

var app = builder.Build();
app.UseForwardedHeaders();
var pathBase = app.Configuration["Hosting:PathBase"];
if (!string.IsNullOrWhiteSpace(pathBase)) app.UsePathBase(pathBase);

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Home/Error");
    app.UseHsts();
    app.UseHttpsRedirection();
}

app.Use(async (context, next) =>
{
    context.Response.Headers.XContentTypeOptions = "nosniff";
    context.Response.Headers.XFrameOptions = "DENY";
    context.Response.Headers["Referrer-Policy"] = "strict-origin-when-cross-origin";
    context.Response.Headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()";
    // frame-src / object-src allow blob: so the Document module can
    // preview PDFs client-side (see document-uploads.js / my-acknowledgements.js).
    // Without this exception the browser shows
    // "This content is blocked. Contact the site owner to fix the issue."
    context.Response.Headers["Content-Security-Policy"] =
        "default-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; script-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; frame-src 'self' blob:; object-src 'self' blob:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'";
    await next();
});

app.UseStaticFiles();
app.UseRouting();
app.UseSession();

// Idle timeout. The access token is signed with a fixed expiry
// (Security:TokenLifetimeMinutes) and used to be issued once, at sign-in,
// and never again -- so every user was cut off exactly that many minutes
// after logging in, however actively they were working, while the 5-minute
// notification poll kept the ASP.NET session itself alive indefinitely.
//
// Now: every request the USER makes re-issues the token with the same
// subject and roles, so it expires TokenLifetimeMinutes after the last
// activity (sliding). Background requests (X-PM-Background) do not renew
// it. Once the token has expired the session is cleared here, so every
// existing IsSignedIn() check sees a signed-out caller: pages redirect to
// /Login?returnUrl=..., JSON endpoints answer 401 "Session expired", and
// site.js sends the browser to the login page on that 401.
app.Use(async (context, next) =>
{
    var session = context.Session;
    var subject = session.GetString(PracticeSessionIdentity.UserKey);
    if (subject is not null)
    {
        var tokenService = context.RequestServices.GetRequiredService<SignedAccessTokenService>();
        var token = session.GetString(PracticeSessionIdentity.TokenKey);
        if (string.IsNullOrWhiteSpace(token) || !tokenService.TryValidate(token, out _))
        {
            session.Clear();
        }
        else if (!context.Request.Headers.ContainsKey(PracticeSessionIdentity.BackgroundRequestHeader))
        {
            var roles = (session.GetString(PracticeSessionIdentity.RolesKey) ?? "")
                .Split(',', StringSplitOptions.RemoveEmptyEntries);
            session.SetString(PracticeSessionIdentity.TokenKey, tokenService.Issue(subject, roles));
        }
    }
    await next();
});
app.UseRateLimiter();
app.UseAuthorization();

// Practice Management explicit routes are registered FIRST so URL
// generation for controller=Practice, action=Index or controller=Login
// never accidentally picks the OrganizationManagement route below
// (whose defaults would otherwise satisfy the requested values and
// emit /OrganizationManagement/... URLs on a Practice Management host).
app.MapControllerRoute(
    name: "practice-management-login",
    pattern: "Login/{action=Index}",
    defaults: new { controller = "Login" });

// areaKey may not be the literal action name "Index" (change request
// 2026-09-27). Without the constraint /Practice/Index bound
// areaKey = "Index" here -- this route is registered before "default" --
// and ShowArea("Index") answered 404. With it, /Practice/Index falls
// through to the default route (controller=Practice, action=Index, no
// areaKey) and opens Home, the same page as /Practice. Every real area
// URL (/Practice/<area>, /Practice/Index/<area>) is unaffected.
app.MapControllerRoute(
    name: "practice-management-home",
    pattern: "Practice/{areaKey:regex(^(?!index$).+$)?}",
    defaults: new { controller = "Practice", action = "Index" });

app.MapControllerRoute(
    name: "organization-management-login",
    pattern: "OrganizationManagement/Login/{action=Index}",
    defaults: new { controller = "Login" });

app.MapControllerRoute(
    name: "organization-management",
    pattern: "OrganizationManagement/{areaKey?}",
    defaults: new { controller = "Practice", action = "Index", moduleKey = "OrganizationManagement" });

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=Login}/{action=Index}/{areaKey?}");

app.Run();
