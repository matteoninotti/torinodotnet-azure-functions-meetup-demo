using System.Runtime.InteropServices;
using System.Text.Json;

using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace ResizeWorker;

/// <summary>
/// HTTP trigger dell'endpoint di resize — implementazione .NET.
///
/// Contratto (identico nei tre linguaggi):
///
///     POST /api/resize?image=&lt;nome&gt;&amp;count=&lt;N&gt;&amp;width=&lt;px&gt;&amp;quality=&lt;1-95&gt;[&amp;hash=1][&amp;return=image]
///     GET  /api/source?image=&lt;nome&gt;
///
/// La risposta di default e' JSON. `return=image` restituisce il JPEG per la
/// demo visiva e non va mai usato durante i run di misura: aggiungerebbe alla
/// latenza la banda di download dell'immagine, che e' esattamente il rumore che
/// la forma `?image=` dell'endpoint serve a eliminare.
/// </summary>
public sealed class Functions(ILogger<Functions> logger)
{
    private const string Language = "dotnet";

    private static readonly string Runtime = RuntimeInformation.FrameworkDescription;

    // Prefisso su cui si aggancia la query di Log Analytics. Un'unica riga di
    // log con un payload JSON stabile, invece delle customDimensions: funziona
    // allo stesso modo nei tre worker e non dipende da come ciascuno inoltra i
    // campi strutturati. Il JSON viene estratto dalla query con una regex e non
    // a offset fisso (D87): su Go il messaggio non finisce dove finisce il
    // payload, e un offset avrebbe funzionato qui e fallito in silenzio la'.
    private const string MetricsPrefix = "RESIZE_METRICS";

    private static IActionResult Error(int status, string message) => new ContentResult
    {
        Content = JsonSerializer.Serialize(new Dictionary<string, object?> { ["error"] = message }),
        ContentType = "application/json",
        StatusCode = status,
    };

    private static string? Query(HttpRequest request, string name) =>
        request.Query.TryGetValue(name, out Microsoft.Extensions.Primitives.StringValues value)
            ? value.ToString()
            : null;

    [Function("resize")]
    public IActionResult Resize(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "resize")] HttpRequest request)
    {
        Params parameters;
        try
        {
            parameters = ResizeCore.ParseParams(name => Query(request, name));
        }
        catch (ImageNotFoundException exception)
        {
            return Error(404, exception.Message);
        }
        catch (InvalidParameterException exception)
        {
            return Error(400, exception.Message);
        }

        PipelineResult result = ResizeCore.RunPipeline(parameters);

        // Dictionary e non un record: l'ordine di inserimento e' l'ordine dei
        // campi nel JSON, e va tenuto uguale a quello di Python perche' le due
        // risposte si leggono affiancate in slide.
        Dictionary<string, object?> metrics = new()
        {
            ["language"] = Language,
            ["image"] = parameters.Image,
            ["count"] = parameters.Count,
            ["width"] = result.Width,
            ["height"] = result.Height,
            ["quality"] = parameters.Quality,
            ["output_bytes"] = result.OutputBytes,
            // NON arrotondato, in nessuno dei tre worker: Math.Round di C# e
            // round() di Python mandano 0.5 al pari, math.Round di Go arrotonda
            // per eccesso in valore assoluto, e sullo stesso valore i tre
            // emettevano cifre diverse. E' la stessa classe di asimmetria che
            // D7 evita per l'altezza, tolta allo stesso modo: non scegliendo un
            // arrotondamento, ma non arrotondando. Ad arrotondare ci pensa chi
            // legge.
            ["total_ms"] = result.TotalMs,
        };

        logger.LogInformation("{Prefix} {Payload}", MetricsPrefix, JsonSerializer.Serialize(metrics));

        if (parameters.ReturnImage)
        {
            return new FileContentResult(result.Payload, "image/jpeg");
        }

        Dictionary<string, object?> body = new(metrics)
        {
            ["runtime"] = Runtime,
            ["sha256"] = result.Sha256,
        };

        return new ContentResult
        {
            Content = JsonSerializer.Serialize(body),
            ContentType = "application/json",
            StatusCode = 200,
        };
    }

    /// <summary>
    /// Diagnostica: conferma quali immagini l'istanza ha caricato all'avvio.
    ///
    /// Non fa parte dell'esperimento — serve a scoprire dal browser che il
    /// pacchetto di deploy e' arrivato completo, senza dover leggere i log.
    ///
    /// NON e' la fonte dati del frontend: per quello c'e' /api/images. La
    /// sovrapposizione nel payload e' voluta, i due endpoint hanno consumatori e
    /// contratti diversi e devono poter evolvere separatamente (D34).
    /// </summary>
    [Function("health")]
    public IActionResult Health(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "health")] HttpRequest request)
    {
        Dictionary<string, object?> body = new()
        {
            ["language"] = Language,
            ["runtime"] = Runtime,
            ["images"] = ResizeCore.AvailableImages(),
        };

        return new ContentResult
        {
            Content = JsonSerializer.Serialize(body),
            ContentType = "application/json",
            StatusCode = 200,
        };
    }

    /// <summary>
    /// Byte originali di un'immagine del pool: la meta' "prima" della demo.
    ///
    /// Query string e non un segmento di path (<c>/api/images/{nome}</c>) per
    /// due motivi: e' la stessa forma <c>?image=</c> del resto del contratto, e
    /// non dipende da come ciascuno dei tre host risolve i template di route —
    /// che sul worker Go, in public preview, non e' verificabile prima del
    /// deploy.
    ///
    /// NON e' nel percorso misurato: restituisce byte gia' in memoria senza
    /// toccare il decoder (D3, D95).
    /// </summary>
    [Function("source")]
    public IActionResult Source(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "source")] HttpRequest request)
    {
        string name = Query(request, "image") ?? string.Empty;
        byte[]? payload = ResizeCore.SourceBytes(name);

        if (payload is null)
        {
            IReadOnlyList<string> available = ResizeCore.AvailableImages();
            string list = available.Count > 0 ? string.Join(", ", available) : "nessuna";
            return Error(404, $"immagine '{name}' non trovata. Disponibili: {list}");
        }

        return new FileContentResult(payload, "image/jpeg");
    }

    /// <summary>
    /// Elenco delle immagini selezionabili: contratto per il selettore della SWA.
    ///
    /// Esiste perche' il frontend possa popolarsi da solo invece di avere i nomi
    /// dei file cablati dentro: cambiando il pool con un redeploy, il selettore
    /// si aggiorna senza che nessuno lo tocchi. I nomi restituiti qui sono gli
    /// stessi che `POST /api/resize` accetta come `?image=` (D34).
    /// </summary>
    [Function("images")]
    public IActionResult Images(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "images")] HttpRequest request)
    {
        Dictionary<string, object?> body = new()
        {
            ["images"] = ResizeCore.ImageCatalog(),
        };

        return new ContentResult
        {
            Content = JsonSerializer.Serialize(body),
            ContentType = "application/json",
            StatusCode = 200,
        };
    }
}
