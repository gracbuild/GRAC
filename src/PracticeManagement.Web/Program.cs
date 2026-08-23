using ControlManagement.Security;
using Microsoft.AspNetCore.HttpOverrides;
using PracticeManagement.Web.Security;
using PracticeManagement.Web.Services;
using System.Threading.RateLimiting;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddControllersWithViews();
builder.Services.AddAntiforgery(options => options.HeaderName = "X-CSRF-TOKEN");
builder.Services.AddHttpClient<SecurePracticeClient>();
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
    options.IdleTimeout = TimeSpan.FromMinutes(30);
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

app.MapControllerRoute(
    name: "practice-management-home",
    pattern: "Practice/{areaKey?}",
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
