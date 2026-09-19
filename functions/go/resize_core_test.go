// Test dell'implementazione Go contro i casi di conformita' condivisi.
//
// Gli stessi casi sono letti dai test Python e .NET: e' il meccanismo con cui
// si verifica che i tre linguaggi siano davvero d'accordo sulla geometria
// dell'output, invece di assumerlo.
//
// I test stanno nella stessa cartella del worker e non in una sorella come per
// .NET: in Go i file _test.go non entrano mai nel binario prodotto da
// `go build`, quindi il vincolo che in .NET obbligava a separarli (il globbing
// di MSBuild) qui semplicemente non esiste.
package main

import (
	"bytes"
	"encoding/json"
	"image/jpeg"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

type heightCase struct {
	SrcWidth  int    `json:"src_width"`
	SrcHeight int    `json:"src_height"`
	DstWidth  int    `json:"dst_width"`
	Expected  int    `json:"expected"`
	Why       string `json:"why"`
}

func loadHeightCases(t *testing.T) []heightCase {
	t.Helper()
	path := filepath.Join("..", "..", "shared", "conformance", "height_cases.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("non riesco a leggere i casi condivisi: %v", err)
	}
	var parsed struct {
		Cases []heightCase `json:"cases"`
	}
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("JSON dei casi condivisi malformato: %v", err)
	}
	return parsed.Cases
}

func TestTargetHeightMatchesConformance(t *testing.T) {
	cases := loadHeightCases(t)
	// Se il percorso relativo si rompesse, i casi sparirebbero senza che
	// nessun test fallisca: zero casi eseguiti e suite verde.
	if len(cases) != 12 {
		t.Fatalf("attesi 12 casi di conformita', trovati %d", len(cases))
	}
	for _, c := range cases {
		got, err := targetHeight(c.SrcWidth, c.SrcHeight, c.DstWidth)
		if err != nil {
			t.Errorf("%dx%d -> %d: errore inatteso %v", c.SrcWidth, c.SrcHeight, c.DstWidth, err)
			continue
		}
		if got != c.Expected {
			t.Errorf("%dx%d -> %d: atteso %d, ottenuto %d (%s)",
				c.SrcWidth, c.SrcHeight, c.DstWidth, c.Expected, got, c.Why)
		}
	}
}

func TestTargetHeightRejectsDegenerateSource(t *testing.T) {
	for _, c := range []struct{ w, h int }{{0, 100}, {100, 0}, {-1, 100}} {
		if _, err := targetHeight(c.w, c.h, 800); err == nil {
			t.Errorf("%dx%d: attesa una sorgente rifiutata, nessun errore", c.w, c.h)
		}
	}
}

// --- Parsing dei parametri: casi condivisi -----------------------------------

type paramSpec struct {
	Parameter string `json:"parameter"`
	Min       int    `json:"min"`
	Max       int    `json:"max"`
	Default   int    `json:"default"`
	Cases     []struct {
		Raw      string          `json:"raw"`
		Expected json.RawMessage `json:"expected"`
		Why      string          `json:"why"`
	} `json:"cases"`
}

func loadParamCases(t *testing.T) paramSpec {
	t.Helper()
	path := filepath.Join("..", "..", "shared", "conformance", "param_cases.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("non riesco a leggere i casi condivisi: %v", err)
	}
	var spec paramSpec
	if err := json.Unmarshal(data, &spec); err != nil {
		t.Fatalf("JSON dei casi condivisi malformato: %v", err)
	}
	return spec
}

func TestParseIntMatchesConformance(t *testing.T) {
	spec := loadParamCases(t)
	// Stesso guardrail di TestTargetHeightMatchesConformance: se il percorso
	// relativo si rompesse, i casi sparirebbero senza che nessun test fallisca.
	if len(spec.Cases) != 16 {
		t.Fatalf("attesi 16 casi di parsing, trovati %d", len(spec.Cases))
	}
	// I limiti scritti nel file devono essere quelli davvero applicati: se
	// qualcuno alzasse maxCount nel codice e non nel file, i casi passerebbero
	// pur non descrivendo piu' il contratto vero.
	if spec.Min != minCount || spec.Max != maxCount || spec.Default != 1 {
		t.Fatalf("i limiti del file (%d..%d, default %d) non sono quelli del worker (%d..%d, default 1)",
			spec.Min, spec.Max, spec.Default, minCount, maxCount)
	}

	for _, c := range spec.Cases {
		got, err := parseInt(c.Raw, spec.Parameter, spec.Default, spec.Min, spec.Max)

		var want string
		if jsonErr := json.Unmarshal(c.Expected, &want); jsonErr == nil {
			switch want {
			case "invalid":
				if _, ok := err.(*invalidParameterError); !ok {
					t.Errorf("%q: atteso invalidParameterError, ottenuto %v (%v) — %s", c.Raw, got, err, c.Why)
				}
			case "default":
				if err != nil || got != spec.Default {
					t.Errorf("%q: atteso il default %d, ottenuto %v (%v) — %s", c.Raw, spec.Default, got, err, c.Why)
				}
			default:
				t.Fatalf("%q: esito atteso sconosciuto %q", c.Raw, want)
			}
			continue
		}

		var expected int
		if jsonErr := json.Unmarshal(c.Expected, &expected); jsonErr != nil {
			t.Fatalf("%q: esito atteso illeggibile: %v", c.Raw, jsonErr)
		}
		if err != nil || got != expected {
			t.Errorf("%q: atteso %d, ottenuto %v (%v) — %s", c.Raw, expected, got, err, c.Why)
		}
	}
}

// --- Parsing dei parametri --------------------------------------------------

func query(pairs map[string]string) func(string) string {
	return func(name string) string { return pairs[name] }
}

func TestParseParamsRequiresImage(t *testing.T) {
	if _, err := parseParams(query(map[string]string{})); err == nil {
		t.Fatal("attesa richiesta senza 'image' rifiutata")
	} else if _, ok := err.(*invalidParameterError); !ok {
		t.Fatalf("atteso invalidParameterError, ottenuto %T", err)
	}
}

func TestParseParamsUnknownImageIsNotFound(t *testing.T) {
	_, err := parseParams(query(map[string]string{"image": "non-esiste.jpg"}))
	if _, ok := err.(*imageNotFoundError); !ok {
		t.Fatalf("atteso imageNotFoundError, ottenuto %T (%v)", err, err)
	}
}

// requireImage restituisce la prima immagine disponibile, o salta il test.
//
// A differenza di .NET qui lo skip esiste ed e' idiomatico (t.Skip), quindi si
// usa: e' anche il comportamento dei test Python.
func requireImage(t *testing.T) string {
	t.Helper()
	names := availableImages()
	if len(names) == 0 {
		t.Skip("nessuna immagine di test in functions/go/images/: lanciare ./scripts/sync-images.sh go")
	}
	return names[0]
}

// requireNamedImage restituisce i byte di un'immagine PRECISA, per i test che
// hanno bisogno di dimensioni note, o salta il test.
func requireNamedImage(t *testing.T, name string) []byte {
	t.Helper()
	payload, ok := sourceBytes(name)
	if !ok {
		t.Skipf("%s non e' in functions/go/images/: lanciare ./scripts/sync-images.sh go", name)
	}
	return payload
}

func TestParseParamsRejectsOutOfRange(t *testing.T) {
	image := requireImage(t)
	for _, c := range []struct{ field, value string }{
		{"count", "0"},
		{"count", "abc"},
		{"width", "0"},
		{"quality", "0"},
		// Pillow documenta la scala 0-95: 96 e' fuori dal minimo comune
		// denominatore anche se image/jpeg lo accetterebbe (D69).
		{"quality", "96"},
	} {
		_, err := parseParams(query(map[string]string{"image": image, c.field: c.value}))
		if _, ok := err.(*invalidParameterError); !ok {
			t.Errorf("%s=%s: atteso invalidParameterError, ottenuto %T (%v)", c.field, c.value, err, err)
		}
	}
}

// Il tetto di `count` arriva davvero fino al punto d'ingresso.
//
// I casi condivisi esercitano parseInt passandogli i limiti PRESI DAL FILE
// (spec.Min, spec.Max), quindi verificano che file e codice dichiarino lo stesso
// numero — non che quel numero sia poi quello che l'endpoint applica.
// Dimostrato in Python: cablando il tetto sbagliato dentro parse_params l'intera
// suite restava verde (D104). Qui si chiama parseParams e non parseInt, e si usa
// maxCount e non spec.Max.
func TestParseParamsAppliesTheCountCeiling(t *testing.T) {
	image := requireImage(t)

	p, err := parseParams(query(map[string]string{"image": image, "count": strconv.Itoa(maxCount)}))
	if err != nil {
		t.Fatalf("count=%d: atteso accettato, ottenuto %v", maxCount, err)
	}
	if p.Count != maxCount {
		t.Errorf("count=%d: atteso %d, ottenuto %d", maxCount, maxCount, p.Count)
	}

	_, err = parseParams(query(map[string]string{"image": image, "count": strconv.Itoa(maxCount + 1)}))
	if _, ok := err.(*invalidParameterError); !ok {
		t.Errorf("count=%d: atteso invalidParameterError, ottenuto %T (%v)", maxCount+1, err, err)
	}
}

// --- Pipeline (richiede le immagini di test) --------------------------------

func TestPipelineIsDeterministicWithinGo(t *testing.T) {
	// E' quanto l'esperimento promette: determinismo INTERNO a ciascun
	// linguaggio. Non promette che i tre producano lo stesso file.
	image := requireImage(t)
	p, err := parseParams(query(map[string]string{"image": image, "hash": "1"}))
	if err != nil {
		t.Fatalf("parsing fallito: %v", err)
	}
	first, err := runPipeline(p)
	if err != nil {
		t.Fatalf("prima esecuzione fallita: %v", err)
	}
	second, err := runPipeline(p)
	if err != nil {
		t.Fatalf("seconda esecuzione fallita: %v", err)
	}
	if *first.Sha256 != *second.Sha256 {
		t.Errorf("output non deterministico: %s != %s", *first.Sha256, *second.Sha256)
	}
	if first.OutputBytes != second.OutputBytes {
		t.Errorf("dimensioni diverse: %d != %d", first.OutputBytes, second.OutputBytes)
	}
}

func TestPipelineCountDoesNotChangeTheOutput(t *testing.T) {
	// count=N e' una manopola sul tempo, non sul risultato.
	image := requireImage(t)
	once, err := parseParams(query(map[string]string{"image": image, "hash": "1"}))
	if err != nil {
		t.Fatalf("parsing fallito: %v", err)
	}
	thrice, err := parseParams(query(map[string]string{"image": image, "count": "3", "hash": "1"}))
	if err != nil {
		t.Fatalf("parsing fallito: %v", err)
	}
	a, err := runPipeline(once)
	if err != nil {
		t.Fatalf("count=1 fallito: %v", err)
	}
	b, err := runPipeline(thrice)
	if err != nil {
		t.Fatalf("count=3 fallito: %v", err)
	}
	if *a.Sha256 != *b.Sha256 {
		t.Errorf("count ha cambiato l'output: %s != %s", *a.Sha256, *b.Sha256)
	}
	if a.Height != b.Height {
		t.Errorf("count ha cambiato l'altezza: %d != %d", a.Height, b.Height)
	}
}

func TestPipelineHashIsOffByDefault(t *testing.T) {
	image := requireImage(t)
	p, err := parseParams(query(map[string]string{"image": image}))
	if err != nil {
		t.Fatalf("parsing fallito: %v", err)
	}
	result, err := runPipeline(p)
	if err != nil {
		t.Fatalf("pipeline fallita: %v", err)
	}
	if result.Sha256 != nil {
		t.Errorf("hash calcolato senza che fosse richiesto: %s", *result.Sha256)
	}
}

func TestPipelineHeightFollowsTheSharedFormula(t *testing.T) {
	// Verifica che la formula condivisa sia quella davvero usata dalla
	// pipeline, non solo quella testata in isolamento: un resize che
	// ignorasse targetHeight passerebbe comunque i casi di conformita'.
	//
	// Perche' serve un'immagine di dimensioni NOTE e non una qualunque:
	// `Height > 0` — l'asserzione di prima — era vera per qualunque resize,
	// compreso uno che avesse ignorato del tutto l'altezza calcolata. Il
	// commento prometteva un controllo che l'asserzione non faceva.
	const name = "npm-install-7-years.jpg"
	source := requireNamedImage(t, name)

	// Le dimensioni si leggono dal file con il decoder QUI nel test, non dal
	// codice sotto test: altrimenti si confronterebbe la pipeline con se stessa.
	config, err := jpeg.DecodeConfig(bytes.NewReader(source))
	if err != nil {
		t.Fatalf("non riesco a leggere l'header di %s: %v", name, err)
	}
	if config.Width != 1322 || config.Height != 1140 {
		t.Fatalf("%s non ha le dimensioni attese: %dx%d invece di 1322x1140", name, config.Width, config.Height)
	}

	expectedHeight, err := targetHeight(config.Width, config.Height, 640)
	if err != nil {
		t.Fatalf("formula fallita: %v", err)
	}
	if expectedHeight != 552 {
		t.Fatalf("la formula condivisa su 1322x1140 -> 640 deve dare 552, ha dato %d", expectedHeight)
	}

	p, err := parseParams(query(map[string]string{"image": name, "width": "640"}))
	if err != nil {
		t.Fatalf("parsing fallito: %v", err)
	}
	result, err := runPipeline(p)
	if err != nil {
		t.Fatalf("pipeline fallita: %v", err)
	}
	if result.Width != 640 || result.Height != expectedHeight {
		t.Errorf("attese 640x%d, ottenute %dx%d", expectedHeight, result.Width, result.Height)
	}
	if result.OutputBytes <= 0 {
		t.Errorf("risultato degenere: bytes=%d", result.OutputBytes)
	}

	// E il JPEG prodotto deve avere davvero quelle dimensioni. Height nel
	// risultato e' il valore che la pipeline ha CALCOLATO: confrontarlo con la
	// formula sarebbe una tautologia. I pixel veri no.
	produced, err := jpeg.DecodeConfig(bytes.NewReader(result.Payload))
	if err != nil {
		t.Fatalf("il payload prodotto non e' un JPEG leggibile: %v", err)
	}
	if produced.Width != 640 || produced.Height != expectedHeight {
		t.Errorf("il JPEG prodotto e' %dx%d, attese 640x%d", produced.Width, produced.Height, expectedHeight)
	}
}

// --- Parametri dell'encoder (D8) ---------------------------------------------

// readJpegEncoding legge dal JPEG prodotto il marker SOF e i fattori di
// campionamento della componente Y — cioe' le due cose che D8 fissa e che
// nessun test verificava.
//
// Si leggono dai byte e non dalla configurazione dell'encoder: la
// configurazione dice cosa abbiamo chiesto, i byte dicono cosa e' uscito. In Go
// non c'e' niente da chiedere — image/jpeg scrive sempre 4:2:0 baseline — ed e'
// proprio per questo che il test serve: e' il worker che DEFINISCE il minimo
// comune denominatore, quindi e' qui che si verifica che il denominatore sia
// ancora quello.
//
// Struttura di un segmento SOF: lunghezza (2 byte), precisione (1), altezza
// (2), larghezza (2), numero di componenti (1), poi per ogni componente id (1),
// fattori di campionamento impacchettati in un byte (1) e tabella di
// quantizzazione (1). Per la Y, 0x22 significa h=2 v=2, cioe' 4:2:0.
func readJpegEncoding(t *testing.T, data []byte) (byte, byte) {
	t.Helper()
	if len(data) < 4 || data[0] != 0xFF || data[1] != 0xD8 {
		t.Fatalf("il payload non comincia con il marker SOI")
	}
	for i := 2; i+3 < len(data); {
		if data[i] != 0xFF {
			t.Fatalf("segmento malformato all'offset %d", i)
		}
		marker := data[i+1]
		length := int(data[i+2])<<8 | int(data[i+3])
		// SOF0 = baseline, SOF1 = extended sequential, SOF2 = progressive.
		// Gli altri FF Cx sono DHT (C4), RSTn, DAC (CC): non sono SOF.
		if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
			// + 2 (lunghezza) + 1 (precisione) + 4 (altezza, larghezza)
			// + 1 (numero componenti) + 1 (id della prima componente)
			return marker, data[i+2+2+1+4+1+1]
		}
		i += 2 + length
	}
	t.Fatalf("nessun marker SOF trovato nel JPEG prodotto")
	return 0, 0
}

func TestPipelineOutputIsBaseline420(t *testing.T) {
	// I tre worker devono produrre lo STESSO formato di JPEG, e il minimo
	// comune denominatore lo impone questa stdlib, che sa fare solo "4:2:0
	// baseline" (D8). Fino a ora era verificato a mano; il README pero'
	// promette che la simmetria e' verificata invece che sperata.
	p, err := parseParams(query(map[string]string{"image": requireImage(t)}))
	if err != nil {
		t.Fatalf("parsing fallito: %v", err)
	}
	result, err := runPipeline(p)
	if err != nil {
		t.Fatalf("pipeline fallita: %v", err)
	}

	sof, luma := readJpegEncoding(t, result.Payload)
	if sof != 0xC0 {
		t.Errorf("atteso SOF0 (baseline, 0xC0), ottenuto 0x%02X", sof)
	}
	if luma != 0x22 {
		t.Errorf("atteso campionamento 4:2:0 sulla luma (0x22), ottenuto 0x%02X", luma)
	}
}

func TestPipelineOutputHonoursTheQualityParameter(t *testing.T) {
	// La qualita' non si legge dai marker senza reimplementare le tabelle di
	// quantizzazione, ma un effetto osservabile ce l'ha: a parita' di immagine,
	// qualita' piu' bassa deve produrre meno byte.
	image := requireImage(t)
	size := func(quality string) int {
		p, err := parseParams(query(map[string]string{"image": image, "quality": quality}))
		if err != nil {
			t.Fatalf("parsing fallito: %v", err)
		}
		result, err := runPipeline(p)
		if err != nil {
			t.Fatalf("pipeline fallita: %v", err)
		}
		return result.OutputBytes
	}
	small, large := size("20"), size("95")
	if small >= large {
		t.Errorf("qualita' 20 ha prodotto %d byte, qualita' 95 ne ha prodotti %d", small, large)
	}
}

// --- Catalogo per il selettore del frontend ---------------------------------

func TestImageCatalogIsConsistentWithAvailableImages(t *testing.T) {
	// I nomi del catalogo devono essere esattamente quelli accettati da
	// ?image=: se divergessero, il selettore della SWA offrirebbe scelte che
	// l'endpoint di resize rifiuta con 404.
	names := availableImages()
	catalog := imageCatalog()
	if len(names) != len(catalog) {
		t.Fatalf("catalogo e disponibili di lunghezza diversa: %d vs %d", len(catalog), len(names))
	}
	for i, entry := range catalog {
		if entry.Name != names[i] {
			t.Errorf("posizione %d: catalogo dice %q, disponibili dice %q", i, entry.Name, names[i])
		}
	}
}

func TestImageCatalogReportsRealByteSizes(t *testing.T) {
	requireImage(t)
	for _, entry := range imageCatalog() {
		if entry.Bytes <= 0 {
			t.Errorf("%s: dimensione non valida %d", entry.Name, entry.Bytes)
		}
	}
}

// I byte serviti alla demo devono essere gli stessi che il catalogo conta: se
// divergessero, la pagina mostrerebbe come "originale" qualcosa di diverso da
// cio' che la pipeline ha davvero ricevuto in ingresso.
func TestSourceBytesMatchesTheCatalogSize(t *testing.T) {
	requireImage(t)
	for _, entry := range imageCatalog() {
		payload, ok := sourceBytes(entry.Name)
		if !ok {
			t.Errorf("%s: sorgente non trovata", entry.Name)
			continue
		}
		if len(payload) != entry.Bytes {
			t.Errorf("%s: %d byte serviti, %d nel catalogo", entry.Name, len(payload), entry.Bytes)
		}
		// Un JPEG comincia sempre con il marker SOI: conferma che stiamo
		// servendo il file grezzo e non una ricodifica.
		if len(payload) < 2 || payload[0] != 0xFF || payload[1] != 0xD8 {
			t.Errorf("%s: non comincia con il marker SOI di un JPEG", entry.Name)
		}
	}
}

func TestSourceBytesUnknownImage(t *testing.T) {
	if _, ok := sourceBytes("non-esiste.jpg"); ok {
		t.Error("attesa un'immagine inesistente non trovata")
	}
}

// TestMain carica le immagini una volta per l'intero pacchetto di test, come fa
// main() in app init. Senza, il catalogo resterebbe vuoto e ogni test che
// dipende dalle immagini si salterebbe anche con la sincronizzazione fatta.
func TestMain(m *testing.M) {
	loadImages()
	os.Exit(m.Run())
}
