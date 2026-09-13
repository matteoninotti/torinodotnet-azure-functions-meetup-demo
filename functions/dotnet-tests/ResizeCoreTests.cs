using System.Globalization;
using System.Text.Json;

using SixLabors.ImageSharp;

using ResizeWorker;

namespace ResizeWorker.Tests;

/// <summary>
/// Test dell'implementazione .NET contro i casi di conformita' condivisi.
///
/// Gli stessi casi sono letti dai test Python (e lo saranno da quelli Go): e' il
/// meccanismo con cui si verifica che i tre linguaggi siano davvero d'accordo
/// sulla geometria dell'output, invece di assumerlo.
/// </summary>
public sealed class ResizeCoreTests
{
    // Le immagini si caricano una volta per assembly, come fa Program.cs in app
    // init. Senza questa chiamata il catalogo resterebbe vuoto e ogni test che
    // dipende dalle immagini si salterebbe, anche con la sincronizzazione fatta.
    static ResizeCoreTests() => ResizeCore.Initialize();

    private sealed record HeightCase(int SrcWidth, int SrcHeight, int DstWidth, int Expected, string Why);

    private static IEnumerable<HeightCase> LoadHeightCases()
    {
        string path = Path.Combine(AppContext.BaseDirectory, "height_cases.json");
        using JsonDocument document = JsonDocument.Parse(File.ReadAllText(path));
        foreach (JsonElement element in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            yield return new HeightCase(
                element.GetProperty("src_width").GetInt32(),
                element.GetProperty("src_height").GetInt32(),
                element.GetProperty("dst_width").GetInt32(),
                element.GetProperty("expected").GetInt32(),
                element.GetProperty("why").GetString() ?? string.Empty);
        }
    }

    public static TheoryData<int, int, int, int, string> HeightCases()
    {
        TheoryData<int, int, int, int, string> data = [];
        foreach (HeightCase item in LoadHeightCases())
        {
            data.Add(item.SrcWidth, item.SrcHeight, item.DstWidth, item.Expected, item.Why);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(HeightCases))]
    public void TargetHeightMatchesConformance(int srcWidth, int srcHeight, int dstWidth, int expected, string why)
    {
        Assert.Equal(expected, ResizeCore.TargetHeight(srcWidth, srcHeight, dstWidth));
        Assert.True(true, why);
    }

    [Fact]
    public void ConformanceFileIsNotEmpty()
    {
        // Se il link nel .csproj si rompesse, i test parametrizzati sopra
        // sparirebbero senza fallire: zero casi eseguiti e suite verde.
        Assert.Equal(12, LoadHeightCases().Count());
    }

    [Theory]
    [InlineData(0, 100)]
    [InlineData(100, 0)]
    [InlineData(-1, 100)]
    public void TargetHeightRejectsDegenerateSource(int srcWidth, int srcHeight)
    {
        Assert.Throws<InvalidParameterException>(() => ResizeCore.TargetHeight(srcWidth, srcHeight, 800));
    }

    // --- Parsing dei parametri: casi condivisi ------------------------------

    private sealed record ParamCase(string Raw, JsonElement Expected, string Why);

    private static JsonDocument LoadParamSpec() =>
        JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "param_cases.json")));

    public static TheoryData<string, string, string> ParamCases()
    {
        TheoryData<string, string, string> data = [];
        using JsonDocument document = LoadParamSpec();
        foreach (JsonElement element in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            // L'esito atteso viaggia come stringa JSON grezza: e' un intero
            // oppure "invalid"/"default", e TheoryData vuole tipi stabili.
            data.Add(
                element.GetProperty("raw").GetString() ?? string.Empty,
                element.GetProperty("expected").GetRawText(),
                element.GetProperty("why").GetString() ?? string.Empty);
        }

        return data;
    }

    [Fact]
    public void ParamConformanceFileIsNotEmpty()
    {
        // Stesso guardrail di ConformanceFileIsNotEmpty: se il link nel .csproj
        // si rompesse, il test parametrizzato sotto sparirebbe senza fallire.
        using JsonDocument document = LoadParamSpec();
        Assert.Equal(16, document.RootElement.GetProperty("cases").GetArrayLength());
    }

    [Fact]
    public void ParamConformanceLimitsMatchTheWorker()
    {
        // I limiti scritti nel file devono essere quelli davvero applicati: se
        // qualcuno alzasse MaxCount nel codice e non nel file, i casi
        // continuerebbero a passare pur non descrivendo piu' il contratto vero.
        using JsonDocument document = LoadParamSpec();
        Assert.Equal(ResizeCore.MinCount, document.RootElement.GetProperty("min").GetInt32());
        Assert.Equal(ResizeCore.MaxCount, document.RootElement.GetProperty("max").GetInt32());
        Assert.Equal(1, document.RootElement.GetProperty("default").GetInt32());
    }

    [Theory]
    [MemberData(nameof(ParamCases))]
    public void ParseIntMatchesConformance(string raw, string expectedRaw, string why)
    {
        const int fallback = 1;
        int Call() => ResizeCore.ParseInt(raw, "count", fallback, ResizeCore.MinCount, ResizeCore.MaxCount);

        switch (expectedRaw)
        {
            case "\"invalid\"":
                Assert.Throws<InvalidParameterException>(() => Call());
                break;
            case "\"default\"":
                Assert.Equal(fallback, Call());
                break;
            default:
                Assert.Equal(int.Parse(expectedRaw, CultureInfo.InvariantCulture), Call());
                break;
        }

        Assert.True(true, why);
    }

    // --- Parsing dei parametri ----------------------------------------------

    private static Func<string, string?> Query(params (string Name, string Value)[] values)
    {
        Dictionary<string, string> map = values.ToDictionary(item => item.Name, item => item.Value);
        return name => map.TryGetValue(name, out string? value) ? value : null;
    }

    [Fact]
    public void ParseParamsRequiresImage()
    {
        Assert.Throws<InvalidParameterException>(() => ResizeCore.ParseParams(Query()));
    }

    [Fact]
    public void ParseParamsUnknownImageIsNotFound()
    {
        Assert.Throws<ImageNotFoundException>(
            () => ResizeCore.ParseParams(Query(("image", "non-esiste.jpg"))));
    }

    [Theory]
    [InlineData("count", "0")]
    [InlineData("count", "abc")]
    [InlineData("width", "0")]
    [InlineData("quality", "0")]
    // Pillow documenta la scala 0-95: 96 e' fuori dal minimo comune
    // denominatore anche se ImageSharp lo accetterebbe (D69).
    [InlineData("quality", "96")]
    public void ParseParamsRejectsOutOfRange(string field, string value)
    {
        // Serve un'immagine valida perche' il controllo su image viene prima.
        Assert.Throws<InvalidParameterException>(
            () => ResizeCore.ParseParams(Query(("image", RequireImage()), (field, value))));
    }

    // --- Pipeline (richiede le immagini di test) ----------------------------

    /// <summary>
    /// I test Python si auto-saltano quando mancano le immagini; qui falliscono
    /// con un messaggio che dice cosa lanciare. Non e' una divergenza dal
    /// contratto — riguarda la suite, non la pipeline misurata — ed e' la scelta
    /// piu' sicura: xunit 2.x non ha uno skip dinamico senza pacchetti in piu',
    /// e una suite che si auto-salta in silenzio resta verde senza aver
    /// verificato niente. In CI le immagini ci sono sempre, perche'
    /// sync-images.sh gira prima del build.
    /// </summary>
    private static string RequireImage()
    {
        IReadOnlyList<string> available = ResizeCore.AvailableImages();
        Assert.True(
            available.Count > 0,
            "nessuna immagine di test in functions/dotnet/images/: lanciare ./scripts/sync-images.sh dotnet");

        return available[0];
    }

    /// <summary>
    /// Byte di una immagine PRECISA, per i test che hanno bisogno di dimensioni
    /// note. Stessa politica di RequireImage: in CI le immagini ci sono sempre,
    /// e un fallimento parlante e' meglio di uno skip silenzioso.
    /// </summary>
    private static byte[] RequireNamedImage(string name)
    {
        byte[]? payload = ResizeCore.SourceBytes(name);
        Assert.True(
            payload is not null,
            $"'{name}' non e' in functions/dotnet/images/: lanciare ./scripts/sync-images.sh dotnet");

        return payload!;
    }

    [Fact]
    public void PipelineIsDeterministicWithinDotnet()
    {
        // E' quanto l'esperimento promette: determinismo INTERNO a ciascun
        // linguaggio. Non promette che i tre producano lo stesso file.
        Params parameters = ResizeCore.ParseParams(Query(("image", RequireImage()), ("hash", "1")));
        PipelineResult first = ResizeCore.RunPipeline(parameters);
        PipelineResult second = ResizeCore.RunPipeline(parameters);

        Assert.Equal(first.Sha256, second.Sha256);
        Assert.Equal(first.OutputBytes, second.OutputBytes);
    }

    [Fact]
    public void PipelineCountDoesNotChangeTheOutput()
    {
        // count=N e' una manopola sul tempo, non sul risultato.
        string image = RequireImage();
        PipelineResult once = ResizeCore.RunPipeline(
            ResizeCore.ParseParams(Query(("image", image), ("hash", "1"))));
        PipelineResult thrice = ResizeCore.RunPipeline(
            ResizeCore.ParseParams(Query(("image", image), ("count", "3"), ("hash", "1"))));

        Assert.Equal(once.Sha256, thrice.Sha256);
        Assert.Equal(once.Height, thrice.Height);
    }

    [Fact]
    public void PipelineHashIsOffByDefault()
    {
        Params parameters = ResizeCore.ParseParams(Query(("image", RequireImage())));
        Assert.Null(ResizeCore.RunPipeline(parameters).Sha256);
    }

    [Fact]
    public void PipelineHeightFollowsTheSharedFormula()
    {
        // Verifica che la formula condivisa sia quella davvero usata dalla
        // pipeline, non solo quella testata in isolamento: un resize che
        // ignorasse TargetHeight passerebbe comunque i casi di conformita'.
        //
        // Perche' serve un'immagine di dimensioni NOTE e non una qualunque:
        // `Height > 0` — l'asserzione di prima — era vera per qualunque resize,
        // compreso uno che avesse ignorato del tutto l'altezza calcolata. Il
        // commento prometteva un controllo che l'asserzione non faceva.
        const string Image = "npm-install-7-years.jpg";
        byte[] source = RequireNamedImage(Image);

        // Le dimensioni si leggono dal file con il decoder QUI nel test, non
        // dal codice sotto test: altrimenti si confronterebbe la pipeline con
        // se stessa.
        ImageInfo info = SixLabors.ImageSharp.Image.Identify(source);
        Assert.Equal(1322, info.Width);
        Assert.Equal(1140, info.Height);

        int expectedHeight = ResizeCore.TargetHeight(info.Width, info.Height, 640);
        Assert.Equal(552, expectedHeight);

        PipelineResult result = ResizeCore.RunPipeline(
            ResizeCore.ParseParams(Query(("image", Image), ("width", "640"))));

        Assert.Equal(640, result.Width);
        Assert.Equal(expectedHeight, result.Height);
        Assert.True(result.OutputBytes > 0);

        // E il JPEG prodotto deve avere davvero quelle dimensioni. Height nel
        // risultato e' il valore che la pipeline ha CALCOLATO: confrontarlo con
        // la formula sarebbe una tautologia. I pixel veri no.
        ImageInfo produced = SixLabors.ImageSharp.Image.Identify(result.Payload);
        Assert.Equal(640, produced.Width);
        Assert.Equal(expectedHeight, produced.Height);
    }

    // --- Parametri dell'encoder (D8) ----------------------------------------

    /// <summary>
    /// Legge dal JPEG prodotto il marker SOF e i fattori di campionamento della
    /// componente Y — cioe' le due cose che D8 fissa e che nessun test
    /// verificava.
    ///
    /// <para>Si leggono dai byte e non dalla configurazione dell'encoder: la
    /// configurazione dice cosa abbiamo chiesto, i byte dicono cosa e' uscito.
    /// Per ImageSharp la differenza non e' teorica — senza <c>ColorType</c> e
    /// <c>Interleaved</c> espliciti l'encoder eredita entrambi DALL'IMMAGINE DI
    /// INPUT (D66), quindi cambiare un'immagine di test cambierebbe il formato
    /// dell'output senza toccare una riga di codice.</para>
    ///
    /// <para>Struttura di un segmento SOF: lunghezza (2 byte), precisione (1),
    /// altezza (2), larghezza (2), numero di componenti (1), poi per ogni
    /// componente id (1), fattori di campionamento impacchettati in un byte (1)
    /// e tabella di quantizzazione (1). Per la Y, <c>0x22</c> significa h=2 v=2,
    /// cioe' 4:2:0.</para>
    /// </summary>
    private static (byte Sof, byte LumaSampling) ReadJpegEncoding(byte[] jpeg)
    {
        Assert.Equal(0xFF, jpeg[0]);
        Assert.Equal(0xD8, jpeg[1]); // SOI

        int i = 2;
        while (i + 3 < jpeg.Length)
        {
            Assert.Equal(0xFF, jpeg[i]); // ogni segmento comincia con FF
            byte marker = jpeg[i + 1];
            int length = (jpeg[i + 2] << 8) | jpeg[i + 3];

            // SOF0 = baseline, SOF1 = extended sequential, SOF2 = progressive.
            // Gli altri FF Cx sono DHT (C4), RSTn, DAC (CC): non sono SOF.
            if (marker is 0xC0 or 0xC1 or 0xC2)
            {
                // + 2 (lunghezza) + 1 (precisione) + 4 (altezza, larghezza)
                // + 1 (numero componenti) + 1 (id della prima componente)
                byte lumaSampling = jpeg[i + 2 + 2 + 1 + 4 + 1 + 1];
                return (marker, lumaSampling);
            }

            i += 2 + length;
        }

        Assert.Fail("nessun marker SOF trovato nel JPEG prodotto");
        return (0, 0);
    }

    [Fact]
    public void PipelineOutputIsBaseline420()
    {
        // I tre worker devono produrre lo STESSO formato di JPEG, perche' il
        // minimo comune denominatore lo impone la stdlib Go, che sa fare solo
        // "4:2:0 baseline" (D8). Fino a ora era verificato a mano; il README
        // pero' promette che la simmetria e' verificata invece che sperata.
        PipelineResult result = ResizeCore.RunPipeline(
            ResizeCore.ParseParams(Query(("image", RequireImage()))));

        (byte sof, byte lumaSampling) = ReadJpegEncoding(result.Payload);

        Assert.Equal(0xC0, sof);          // SOF0: baseline, non progressive (C2)
        Assert.Equal(0x22, lumaSampling); // h=2 v=2: 4:2:0
    }

    [Fact]
    public void PipelineOutputHonoursTheQualityParameter()
    {
        // La qualita' non si legge dai marker senza reimplementare le tabelle di
        // quantizzazione, ma un effetto osservabile ce l'ha: a parita' di
        // immagine, qualita' piu' bassa deve produrre meno byte. Serve a
        // intercettare un encoder che ignorasse il parametro.
        string image = RequireImage();
        int small = ResizeCore.RunPipeline(
            ResizeCore.ParseParams(Query(("image", image), ("quality", "20")))).OutputBytes;
        int large = ResizeCore.RunPipeline(
            ResizeCore.ParseParams(Query(("image", image), ("quality", "95")))).OutputBytes;

        Assert.True(small < large, $"qualita' 20 ha prodotto {small} byte, qualita' 95 ne ha prodotti {large}");
    }

    // --- Catalogo per il selettore del frontend -----------------------------

    [Fact]
    public void ImageCatalogIsConsistentWithAvailableImages()
    {
        // I nomi del catalogo devono essere esattamente quelli accettati da
        // ?image=: se divergessero, il selettore della SWA offrirebbe scelte
        // che l'endpoint di resize rifiuta con 404.
        Assert.Equal(
            ResizeCore.AvailableImages(),
            ResizeCore.ImageCatalog().Select(entry => entry.Name).ToList());
    }

    [Fact]
    public void ImageCatalogReportsRealByteSizes()
    {
        RequireImage();
        Assert.All(ResizeCore.ImageCatalog(), entry => Assert.True(entry.Bytes > 0));
    }

    /// <summary>
    /// I byte serviti alla demo devono essere gli stessi che il catalogo conta.
    /// Se divergessero, la pagina mostrerebbe come "originale" qualcosa di
    /// diverso da cio' che la pipeline ha davvero ricevuto in ingresso, e il
    /// confronto prima/dopo direbbe una cosa falsa.
    /// </summary>
    [Fact]
    public void SourceBytesMatchesTheCatalogSize()
    {
        RequireImage();
        foreach (ImageCatalogEntry entry in ResizeCore.ImageCatalog())
        {
            byte[]? payload = ResizeCore.SourceBytes(entry.Name);
            Assert.NotNull(payload);
            Assert.Equal(entry.Bytes, payload!.Length);
            // Un JPEG comincia sempre con il marker SOI: conferma che stiamo
            // servendo il file grezzo e non una ricodifica.
            Assert.Equal(0xFF, payload[0]);
            Assert.Equal(0xD8, payload[1]);
        }
    }

    [Fact]
    public void SourceBytesUnknownImageIsNull()
    {
        Assert.Null(ResizeCore.SourceBytes("non-esiste.jpg"));
    }
}
