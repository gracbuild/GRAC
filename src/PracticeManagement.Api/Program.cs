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
// Sign-in moved out of the Web tier so the database is reached only through
// the API (secure/authenticate + secure/set-password). PasswordHasher is the
// linked Web source file — see the .csproj.
builder.Services.AddSingleton<PracticeManagement.Web.Security.PasswordHasher>();
builder.Services.AddScoped<IPracticeAuthenticationService, PracticeAuthenticationService>();

// Workflow layer (Q13/Q14/Q15 / §12.1.3 / §12.1.6). Charter §5 file — one-time wire-up.
builder.Services.AddPracticePermissionService();
builder.Services.AddPracticeTaskService();
builder.Services.AddPracticeCustomGapService();
builder.Services.AddPracticeWorkflowService();
// Role / asset-category scoped event assurance (migrations 123/124).
builder.Services.AddPracticeEventScopeService();
// Attribute-based Profiles for the same scoping -- Location / Department /
// Role and whatever else is seeded later (migrations 329-332).
builder.Services.AddPracticeEventProfileService();
// Practice view page + Configure (one instance per team) -- migration 139.
builder.Services.AddPracticeConfigureService();
// Resolve workspace: owner-scoped list + obligations/dependencies -- 140/141.
builder.Services.AddPracticeResolveWorkspace();
// Practice-level obligations: authored once against a practice, fanned out
// to every instance of it -- migration 307.
builder.Services.AddPracticeObligationService();
builder.Services.AddPracticeFeatureFlagService();
builder.Services.AddPracticeOrganizationAccessService();
builder.Services.AddPracticeInstanceWorkflow();
// Document Upload + Acknowledgement module (migrations 146-152 / charter §5).
// Two INDEPENDENT services: uploads (register + workflow) and
// acknowledgements (admin batches for user-acknowledgement tracking).
builder.Services.AddPracticeDocumentUploadService();
builder.Services.AddPracticeDocumentAcknowledgementService();
// Gap Centre v1.0 (migrations 156-158 / AES) -- lifecycle engine +
// analysis + downstream link surface. Additive; existing CustomGap
// service and controller remain untouched.
builder.Services.AddPracticeGapLifecycleService();
// Exception Centre (migrations 161-163) -- time-boxed acceptance of
// gaps. Independent module; auto-triggered from gap analysis when
// recommend_exception=1 and via manual requests later.
builder.Services.AddPracticeExceptionCentreService();
// Risk Centre (migrations 169-172) -- placeholder module for triaging
// risk candidates raised from gap analysis when business_risk_present='Y'.
// Full Risk Management module to follow.
builder.Services.AddPracticeRiskCentreService();
// Phase 2 Assurance Management -- Organization Portal (BRD Part 2).
// New, INDEPENDENT module. Does not touch existing assurance/workflow/task engines.
builder.Services.AddOrgAssuranceDefinitionService();
builder.Services.AddOrgAssuranceQuestionService();
// Phase 2 Audit Management -- audit/question-set adoption (277) and the
// setup-status roll-up behind the flow tab chips (278).
builder.Services.AddOrgAssuranceSetupService();
// Reusable cascading Practice Picker (282): framework -> source structure
// -> control -> practice. Read-only lookups.
builder.Services.AddPracticePickerService();
builder.Services.AddOrgAssurancePlanService();
builder.Services.AddOrgAssuranceExecutionService();
builder.Services.AddOrgAssuranceObservationService();
// Organization SLA Config (migrations 178/179/180). Independent module
// that adopts Control Management SLA masters into per-org configs with
// warning/escalation thresholds, notify roles, and process bindings.
builder.Services.AddOrgSlaConfigService();
// Gap Center is served by the pre-existing CustomGapService -- the
// parallel OrgAssuranceGapService was retired in migration 113 in
// favour of the unified custom_gap table. See
// AddPracticeCustomGapService() above (already registered).
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
