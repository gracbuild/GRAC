// =====================================================================
// ApiFileProxy  (migration 473)
//
// The two file-shaped hops of a Web -> Api proxy, written once:
//
//   BuildMultipartAsync  -- ReadFormAsync + rebuild. The pattern the Task
//       Centre, Exception Centre, Risk Centre and Document Upload proxies
//       each carry inline (see TaskController.UploadAttachment for why a
//       raw Request.Body stream is NOT forwarded: it races with
//       [ApiController]'s input-formatter probing and the Api receives a
//       truncated multipart body). Fields named in dropFields are not
//       forwarded -- identity comes from the session, never the browser.
//
//   ToFileResultAsync    -- a binary upstream response back to the browser
//       with its content type and file name. ForwardAsync-style string
//       copies corrupt binary content.
//
// Used by WorkflowController's Operationalize evidence-attachment routes.
// The older inline copies in the four controllers above are unchanged;
// they can move onto this when next touched.
// =====================================================================
using System.Net.Http.Headers;
using Microsoft.AspNetCore.Mvc;

namespace PracticeManagement.Web.Services;

public static class ApiFileProxy
{
    public static async Task<MultipartFormDataContent> BuildMultipartAsync(
        HttpRequest request, CancellationToken cancellationToken, params string[] dropFields)
    {
        var form = await request.ReadFormAsync(cancellationToken);
        var mp = new MultipartFormDataContent("----pmboundary-" + Guid.NewGuid().ToString("N"));

        foreach (var kv in form)
        {
            if (dropFields.Any(d => kv.Key.Equals(d, StringComparison.OrdinalIgnoreCase))) continue;
            foreach (var v in kv.Value)
                if (v is not null) mp.Add(new StringContent(v), kv.Key);
        }

        foreach (var file in form.Files)
        {
            if (file.Length == 0) continue;
            var sc = new StreamContent(file.OpenReadStream());
            // TryParse: a malformed browser content type must not turn an
            // upload into "Upstream API unreachable".
            if (!string.IsNullOrWhiteSpace(file.ContentType)
                && MediaTypeHeaderValue.TryParse(file.ContentType, out var mediaType))
                sc.Headers.ContentType = mediaType;
            mp.Add(sc, file.Name, file.FileName);
        }

        return mp;
    }

    public static async Task<FileContentResult> ToFileResultAsync(
        HttpResponseMessage response, string fallbackFileName, CancellationToken cancellationToken)
    {
        var bytes       = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        var contentType = response.Content.Headers.ContentType?.ToString() ?? "application/octet-stream";
        var fileName    = response.Content.Headers.ContentDisposition?.FileNameStar
                       ?? response.Content.Headers.ContentDisposition?.FileName?.Trim('"')
                       ?? fallbackFileName;

        return new FileContentResult(bytes, contentType) { FileDownloadName = fileName };
    }
}
