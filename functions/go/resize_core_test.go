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
	"encoding/json"
	"os"
	"path/filepath"
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
	image := requireImage(t)
	p, err := parseParams(query(map[string]string{"image": image, "width": "640"}))
	if err != nil {
		t.Fatalf("parsing fallito: %v", err)
	}
	result, err := runPipeline(p)
	if err != nil {
		t.Fatalf("pipeline fallita: %v", err)
	}
	if result.Width != 640 {
		t.Errorf("larghezza attesa 640, ottenuta %d", result.Width)
	}
	if result.Height <= 0 || result.OutputBytes <= 0 {
		t.Errorf("risultato degenere: height=%d bytes=%d", result.Height, result.OutputBytes)
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

// TestMain carica le immagini una volta per l'intero pacchetto di test, come fa
// main() in app init. Senza, il catalogo resterebbe vuoto e ogni test che
// dipende dalle immagini si salterebbe anche con la sincronizzazione fatta.
func TestMain(m *testing.M) {
	loadImages()
	os.Exit(m.Run())
}
