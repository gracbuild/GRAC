using System.Net;
using System.Net.Mail;

namespace PracticeManagement.Web.Services;

/// <summary>
/// Best-effort SMTP wrapper used by the organisation-setup flow. Rule 6
/// requires that credential email delivery must never block org creation.
/// Every send is wrapped in a try/catch — failures are logged with a
/// correlation id and surfaced to the caller as a boolean so the caller
/// can decide whether to flip <c>email_credentials_sent</c>.
///
/// SMTP configuration is read from the <c>Email:*</c> keys in
/// appsettings.json to mirror how the parent GRAC platform is configured.
/// If those keys are missing (development/UAT boxes without SMTP), the
/// service logs a warning and returns false rather than throwing so
/// callers do not need to know whether email is configured.
/// </summary>
public interface IPracticeEmailService
{
    bool IsConfigured { get; }

    Task<PracticeEmailResult> SendAdminCredentialsAsync(
        string toEmail,
        string toName,
        string organizationName,
        string loginUrl,
        string oneTimePassword,
        CancellationToken cancellationToken);
}

public sealed record PracticeEmailResult(bool Delivered, string? CorrelationId, string? FailureReason);

public sealed class PracticeEmailService(IConfiguration configuration, ILogger<PracticeEmailService> logger) : IPracticeEmailService
{
    public bool IsConfigured =>
        !string.IsNullOrWhiteSpace(configuration["Email:SmtpHost"])
        && !string.IsNullOrWhiteSpace(configuration["Email:FromAddress"]);

    public async Task<PracticeEmailResult> SendAdminCredentialsAsync(
        string toEmail,
        string toName,
        string organizationName,
        string loginUrl,
        string oneTimePassword,
        CancellationToken cancellationToken)
    {
        var correlationId = Guid.NewGuid().ToString("N");

        if (!IsConfigured)
        {
            logger.LogWarning(
                "PracticeEmailService is not configured. Skipping credential email for {Email} in organisation {Organisation}. CorrelationId={CorrelationId}",
                toEmail, organizationName, correlationId);
            return new PracticeEmailResult(false, correlationId, "Email:SmtpHost or Email:FromAddress is not configured.");
        }

        if (string.IsNullOrWhiteSpace(toEmail))
        {
            logger.LogWarning("PracticeEmailService called without a recipient. CorrelationId={CorrelationId}", correlationId);
            return new PracticeEmailResult(false, correlationId, "Recipient email is missing.");
        }

        try
        {
            var host = configuration["Email:SmtpHost"]!;
            var port = configuration.GetValue("Email:SmtpPort", 587);
            var enableSsl = configuration.GetValue("Email:EnableSsl", true);
            var username = configuration["Email:Username"];
            var password = configuration["Email:Password"];
            var fromAddress = configuration["Email:FromAddress"]!;
            var fromName = configuration["Email:FromName"] ?? "GRAC PracticeManagement";
            var replyTo = configuration["Email:ReplyTo"];
            var subjectTemplate = configuration["Email:CredentialsSubject"]
                ?? "Your GRAC Organisation Administrator account is ready";

            using var client = new SmtpClient(host, port)
            {
                EnableSsl = enableSsl,
                DeliveryMethod = SmtpDeliveryMethod.Network,
                Timeout = configuration.GetValue("Email:TimeoutMs", 20000)
            };
            if (!string.IsNullOrWhiteSpace(username))
            {
                client.UseDefaultCredentials = false;
                client.Credentials = new NetworkCredential(username, password ?? string.Empty);
            }

            using var message = new MailMessage
            {
                From = new MailAddress(fromAddress, fromName),
                Subject = subjectTemplate.Replace("{organization}", organizationName),
                IsBodyHtml = true,
                Body = BuildBody(toName, organizationName, loginUrl, oneTimePassword, toEmail)
            };
            message.To.Add(new MailAddress(toEmail, string.IsNullOrWhiteSpace(toName) ? toEmail : toName));
            if (!string.IsNullOrWhiteSpace(replyTo)) message.ReplyToList.Add(new MailAddress(replyTo));
            message.Headers.Add("X-Grac-Correlation", correlationId);

            await client.SendMailAsync(message, cancellationToken);

            logger.LogInformation(
                "PracticeEmailService delivered credentials to {Email} for organisation {Organisation}. CorrelationId={CorrelationId}",
                toEmail, organizationName, correlationId);
            return new PracticeEmailResult(true, correlationId, null);
        }
        catch (Exception ex)
        {
            // Rule 6 — never let email failures bubble up to the caller.
            logger.LogError(ex,
                "PracticeEmailService failed to deliver credentials to {Email} for organisation {Organisation}. CorrelationId={CorrelationId}",
                toEmail, organizationName, correlationId);
            return new PracticeEmailResult(false, correlationId, ex.Message);
        }
    }

    private static string BuildBody(string toName, string organizationName, string loginUrl, string oneTimePassword, string toEmail)
    {
        var greeting = string.IsNullOrWhiteSpace(toName) ? "Hello," : $"Hello {System.Net.WebUtility.HtmlEncode(toName)},";
        var org = System.Net.WebUtility.HtmlEncode(organizationName);
        var login = System.Net.WebUtility.HtmlEncode(loginUrl);
        var otp = System.Net.WebUtility.HtmlEncode(oneTimePassword);
        var email = System.Net.WebUtility.HtmlEncode(toEmail);
        return $"""
            <p>{greeting}</p>
            <p>A GRAC PracticeManagement workspace has been provisioned for <strong>{org}</strong>.</p>
            <p>You have been designated the Organisation GRAC Administrator. Please sign in and change your password on first use.</p>
            <ul>
              <li>Sign-in URL: <a href="{login}">{login}</a></li>
              <li>User ID: <code>{email}</code></li>
              <li>Temporary password: <code>{otp}</code></li>
            </ul>
            <p>For security this password must be changed on your first sign-in.</p>
            <p>— GRAC PracticeManagement</p>
            """;
    }
}
