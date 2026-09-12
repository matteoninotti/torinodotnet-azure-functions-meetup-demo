using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json.Serialization;

using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Formats.Jpeg;
using SixLabors.ImageSharp.PixelFormats;
using SixLabors.ImageSharp.Processing;

namespace ResizeWorker;

/// <summary>
/// Pipeline di resize e strumentazione delle misure — gemello di
/// functions/python/resize_core.py.
///
/// Le scelte qui dentro non sono idiomatiche per caso: ognuna corrisponde a una
/// decisione del log, e cambiarne una senza cambiarla anche in Python e Go
/// rompe la simmetria su cui poggia l'intero confronto.
/// </summary>
public static class ResizeCore
{
    // --- Parametri fissati dall'esperimento ---------------------------------

    public const int DefaultWidth = 800;
    public const int DefaultQuality = 80;

    // Pillow documenta la qualita' su scala 0-95, ImageSharp accetta 1-100:
    // il tetto piu' basso e' il minimo comune denominatore e vale per tutti e
    // tre i worker, altrimenti lo stesso quality=96 darebbe 200 su un backend
    // e 400 su un altro (D8, D69).
    public const int MinQuality = 1;
    public const int MaxQuality = 95;

    public const int MinWidth = 1;
    public const int MaxWidth = 10_000;
    public const int MinCount = 1;
    public const int MaxCount = 10_000;

    private static readonly string[] ImageSuffixes = [".jpg", ".jpeg"];

    private static IReadOnlyDictionary<string, byte[]> images =
        new Dictionary<string, byte[]>();

    // --- Caricamento delle immagini (app init) ------------------------------

    /// <summary>
    /// Carica i file di test come byte JPEG grezzi, senza decodificarli.
    ///
    /// La decodifica resta dentro il percorso misurato di ogni richiesta (D3):
    /// e' li' che vive l'asimmetria tra libjpeg-turbo, ImageSharp e la stdlib
    /// Go, ed e' la cosa piu' interessante da confrontare.
    ///
    /// Va chiamata da Program.cs prima di avviare l'host: vedi il commento li'
    /// sul perche' non e' uno static initializer.
    /// </summary>
    public static void Initialize()
    {
        string directory = Path.Combine(AppContext.BaseDirectory, "images");
        if (!Directory.Exists(directory))
        {
            // Deliberatamente non e' un errore: un'istanza senza immagini deve
            // dirlo rispondendo 404, non andare in crash all'avvio. Il prezzo
            // e' che una copia dimenticata non fa fallire il deploy, ed e' per
            // questo che esiste il controllo post-deploy su /api/images (D35).
            images = new Dictionary<string, byte[]>();
            return;
        }

        Dictionary<string, byte[]> loaded = [];
        foreach (string path in Directory.EnumerateFiles(directory).OrderBy(p => p, StringComparer.Ordinal))
        {
            string name = Path.GetFileName(path);
            if (ImageSuffixes.Contains(Path.GetExtension(name).ToLowerInvariant()))
            {
                loaded[name] = File.ReadAllBytes(path);
            }
        }

        images = loaded;
    }

    public static IReadOnlyList<string> AvailableImages() =>
        [.. images.Keys.OrderBy(name => name, StringComparer.Ordinal)];

    /// <summary>
    /// Elenco delle immagini selezionabili, per il selettore del frontend.
    ///
    /// Deliberatamente NON include le dimensioni in pixel: ricavarle vorrebbe
    /// dire aprire l'header di ogni file all'avvio, cioe' toccare il decoder
    /// fuori dal percorso misurato (D3). Il numero di byte invece e' gratis.
    /// </summary>
    public static IReadOnlyList<ImageCatalogEntry> ImageCatalog() =>
        [.. AvailableImages().Select(name => new ImageCatalogEntry(name, images[name].Length))];

    // --- Geometria ----------------------------------------------------------

    /// <summary>
    /// Altezza proporzionale, in aritmetica intera.
    ///
    /// Deliberatamente NON usa Math.Round: l'arrotondamento di libreria non e'
    /// la stessa operazione nei tre linguaggi (Python e C# arrotondano 0.5 al
    /// pari, Go per eccesso in valore assoluto), e su un caso limite darebbero
    /// altezze diverse. Questa espressione e' half-up esatto e ricalca carattere
    /// per carattere quella di Python e Go, inclusa la divisione intera di
    /// srcWidth (D7).
    ///
    /// I casi attesi sono fissati in shared/conformance/height_cases.json, che i
    /// test dei tre linguaggi leggono per verificare di essere d'accordo.
    /// </summary>
    public static int TargetHeight(int srcWidth, int srcHeight, int dstWidth)
    {
        if (srcWidth <= 0 || srcHeight <= 0)
        {
            throw new InvalidParameterException("dimensioni sorgente non valide");
        }

        // long e non int: il prodotto puo' superare il range di int su sorgenti
        // grandi, e in Python il problema non esiste perche' gli interi non
        // hanno limite. Un overflow silenzioso darebbe un'altezza sbagliata
        // senza nessun segnale.
        long height = ((long)srcHeight * dstWidth + srcWidth / 2) / srcWidth;
        return (int)Math.Max(1, height);
    }

    // --- Validazione dei parametri ------------------------------------------

    private static int ParseInt(string? raw, string name, int fallback, int lo, int hi)
    {
        if (string.IsNullOrEmpty(raw))
        {
            return fallback;
        }

        if (!int.TryParse(raw, out int value))
        {
            throw new InvalidParameterException($"{name} deve essere un intero, ricevuto '{raw}'");
        }

        if (value < lo || value > hi)
        {
            throw new InvalidParameterException($"{name} deve stare tra {lo} e {hi}, ricevuto {value}");
        }

        return value;
    }

    /// <summary>
    /// Legge i parametri dalla query string. <paramref name="get"/> e' una
    /// funzione nome -> valore, come in Python.
    /// </summary>
    public static Params ParseParams(Func<string, string?> get)
    {
        string? image = get("image");
        if (string.IsNullOrEmpty(image))
        {
            throw new InvalidParameterException(
                $"parametro 'image' obbligatorio. Disponibili: {AvailableList()}");
        }

        if (!images.ContainsKey(image))
        {
            throw new ImageNotFoundException(
                $"immagine '{image}' non trovata. Disponibili: {AvailableList()}");
        }

        return new Params(
            Image: image,
            Count: ParseInt(get("count"), "count", 1, MinCount, MaxCount),
            Width: ParseInt(get("width"), "width", DefaultWidth, MinWidth, MaxWidth),
            Quality: ParseInt(get("quality"), "quality", DefaultQuality, MinQuality, MaxQuality),
            WantHash: get("hash") == "1",
            ReturnImage: get("return") == "image");
    }

    private static string AvailableList()
    {
        IReadOnlyList<string> available = AvailableImages();
        return available.Count == 0 ? "nessuna" : string.Join(", ", available);
    }

    // --- Pipeline -----------------------------------------------------------

    /// <summary>
    /// Esegue decode -> resize -> encode <c>count</c> volte sulla stessa
    /// immagine.
    ///
    /// Sempre la stessa immagine, mai a rotazione: ruotare introdurrebbe
    /// varianza nel carico a seconda di come cade N sul ciclo, che e' rumore
    /// gratuito in un esperimento il cui unico scopo e' confrontare durate (D4).
    ///
    /// Un solo cronometro attorno all'intera pipeline, non tre separati: la
    /// scomposizione decode/resize/encode e' stata scartata per tenere la
    /// strumentazione minima (D6, D25).
    /// </summary>
    public static PipelineResult RunPipeline(Params parameters)
    {
        byte[] raw = images[parameters.Image];
        long totalTicks = 0;
        byte[] payload = [];
        int height = 0;

        for (int i = 0; i < parameters.Count; i++)
        {
            long started = Stopwatch.GetTimestamp();

            using var source = SixLabors.ImageSharp.Image.Load<Rgb24>(new MemoryStream(raw, writable: false));
            height = TargetHeight(source.Width, source.Height, parameters.Width);

            source.Mutate(context => context.Resize(new ResizeOptions
            {
                Size = new Size(parameters.Width, height),

                // Il default e' ResizeMode.Crop: con l'altezza arrotondata di D7
                // ritaglierebbe invece di scalare, e l'output non sarebbe piu'
                // quello di Pillow. Stretch e' l'equivalente di resize((w, h)).
                Mode = ResizeMode.Stretch,

                // Il default e' KnownResamplers.Bicubic. Triangle e' il
                // bilineare, l'unico filtro presente in tutti e tre (D9).
                Sampler = KnownResamplers.Triangle,

                // Convertire in luce lineare prima del resize e tornare indietro
                // dopo e' lavoro in piu' che Pillow non fa. E' gia' il default,
                // ma un default non si vede leggendo il codice (D10).
                Compand = false,
            }));

            var buffer = new MemoryStream();
            source.Save(buffer, new JpegEncoder
            {
                Quality = parameters.Quality,

                // Senza questi due, ImageSharp eredita sottocampionamento e
                // modalita' di scansione DALL'IMMAGINE DI INPUT: cambiare
                // un'immagine di test cambierebbe il formato dell'output senza
                // toccare una riga di codice. 4:2:0 interleaved e' il minimo
                // comune denominatore imposto dalla stdlib Go (D8, D66).
                //
                // Il terzo pezzo, baseline contro progressive, qui non e' una
                // scelta: la 3.1.12 non ha una proprieta' Progressive, scrive
                // sempre baseline. E' la 4.x ad averla aggiunta.
                ColorType = JpegEncodingColor.YCbCrRatio420,
                Interleaved = true,
            });

            totalTicks += Stopwatch.GetTimestamp() - started;
            payload = buffer.ToArray();
        }

        // L'hash sta fuori dal cronometro ed e' spento di default: SHA-256 e'
        // accelerato in hardware su .NET e Go ma non in Python, quindi tenerlo
        // acceso durante le misure infilerebbe nel confronto una differenza di
        // velocita' che non c'entra nulla con l'image processing (D5).
        string? digest = parameters.WantHash
            ? Convert.ToHexStringLower(SHA256.HashData(payload))
            : null;

        double totalMs = totalTicks * 1000.0 / Stopwatch.Frequency;

        return new PipelineResult(
            Width: parameters.Width,
            Height: height,
            OutputBytes: payload.Length,
            TotalMs: totalMs,
            Payload: payload,
            Sha256: digest);
    }
}

/// <summary>Parametro di query malformato o fuori intervallo.</summary>
public sealed class InvalidParameterException(string message) : Exception(message);

/// <summary>L'immagine richiesta non e' nel pacchetto di deploy.</summary>
public sealed class ImageNotFoundException(string message) : Exception(message);

public sealed record Params(
    string Image,
    int Count,
    int Width,
    int Quality,
    bool WantHash,
    bool ReturnImage);

public sealed record PipelineResult(
    int Width,
    int Height,
    int OutputBytes,
    double TotalMs,
    byte[] Payload,
    string? Sha256);

public sealed record ImageCatalogEntry(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("bytes")] int Bytes);
