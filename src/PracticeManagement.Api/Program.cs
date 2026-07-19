using ControlManagement.Security;
using Microsoft.AspNetCore.HttpOverrides;
using PracticeManagement.Api.Infrastructure;
using PracticeManagement.Api.Services;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddConsole();
builder.Logging.AddDebug();

builder.Services.AddControllers();
builder.Services.AddCors(options =>
{
    options.AddPolicy("PracticeManagementWeb", policy =>
    {
        var origins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>()
            ?? ["http://localhost:5083", "https://localhost:7083"];
        policy.WithOrigins(origins).AllowAnyHeader().AllowAnyMethod();
    });
});
builder.Services.AddMemoryCache();
builder.Services.AddScoped<IPracticeRepositoryService, PracticeRepositoryService>();

// Workflow layer (Q13/Q14/Q15 / §12.1.3 / §12.1.6). Charter §5 file — one-time wire-up.
builder.Services.AddPracticePermissionService();
builder.Services.AddPracticeTaskService();
builder.Services.AddPracticeCustomGapService();
builder.Services.AddPracticeFeatureFlagService();
builder.Services.AddPracticeOrganizationAccessService();
builder.Services.AddPracticeInstanceWorkflow();
builder.Services.Configure<SecurityOptions>(builder.Configuration.GetSection(SecurityOptions.SectionName));
builder.Services.AddSingleton<EnvelopeCrypto>();
builder.Services.AddSingleton<SignedAccessTokenService>();
builder.Services.AddSingleton<PermissionPolicy>();
builder.Services.Configure<ForwardedHeadersOptions>(options =>
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto);

var app = builder.Build();
app.UseForwardedHeaders();
app.UseCors("PracticeManagementWeb");

if (!app.Environment.IsDevelopment())
{
    app.UseHsts();
    app.UseHttpsRedirection();
}

app.Use(async (context, next) =>
{
    context.Response.Headers.XContentTypeOptions = "nosniff";
    context.Response.Headers.XFrameOptions = "DENY";
    context.Response.Headers.CacheControl = "no-store";
    await next();
});

app.MapControllers();
app.MapGet("/", () => Results.Ok(new { status = "ready", module = "PracticeManagement" }));
app.Run();
