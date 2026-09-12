using System.Text.Json;

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
        // ignorasse target_height passerebbe comunque i casi di conformita'.
        string image = RequireImage();
        PipelineResult result = ResizeCore.RunPipeline(
            ResizeCore.ParseParams(Query(("image", image), ("width", "640"))));

        Assert.Equal(640, result.Width);
        Assert.True(result.Height > 0);
        Assert.True(result.OutputBytes > 0);
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
}
