// Pipeline di resize e strumentazione delle misure — gemello di
// functions/python/resize_core.py e functions/dotnet/ResizeCore.cs.
//
// Le scelte qui dentro non sono idiomatiche per caso: ognuna corrisponde a una
// decisione del log, e cambiarne una senza cambiarla anche negli altri due
// worker rompe la simmetria su cui poggia l'intero confronto.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"golang.org/x/image/draw"
)

// --- Parametri fissati dall'esperimento -------------------------------------

const (
	defaultWidth   = 800
	defaultQuality = 80

	// Pillow documenta la qualita' su scala 0-95, ImageSharp accetta 1-100 e
	// image/jpeg accetta 1-100: il tetto piu' basso e' il minimo comune
	// denominatore e vale per tutti e tre i worker, altrimenti lo stesso
	// quality=96 darebbe 200 su un backend e 400 su un altro (D8, D69).
	minQuality = 1
	maxQuality = 95

	minWidth = 1
	maxWidth = 10000
	minCount = 1
	maxCount = 10000
)

// --- Errori -----------------------------------------------------------------

// invalidParameterError segnala un parametro di query malformato o fuori
// intervallo: si traduce in 400.
type invalidParameterError struct{ msg string }

func (e *invalidParameterError) Error() string { return e.msg }

func invalidParameter(format string, args ...any) error {
	return &invalidParameterError{msg: fmt.Sprintf(format, args...)}
}

// imageNotFoundError segnala un'immagine che non e' nel pacchetto di deploy:
// si traduce in 404.
type imageNotFoundError struct{ msg string }

func (e *imageNotFoundError) Error() string { return e.msg }

func imageNotFound(format string, args ...any) error {
	return &imageNotFoundError{msg: fmt.Sprintf(format, args...)}
}

// --- Caricamento delle immagini (app init) ----------------------------------

var images = map[string][]byte{}

// loadImages carica i file di test come byte JPEG grezzi, senza decodificarli.
//
// La decodifica resta dentro il percorso misurato di ogni richiesta (D3): e'
// li' che vive l'asimmetria tra libjpeg-turbo, ImageSharp e la stdlib Go, ed e'
// la cosa piu' interessante da confrontare.
//
// Va chiamata da main() prima di worker.Start: in Python l'import del modulo le
// carica in app init, e il punto del ciclo di vita in cui avviene il
// caricamento dev'essere lo stesso nei tre linguaggi, perche' la Metrica 4
// misura proprio la differenza fra quelle fasi.
func loadImages() {
	dir, err := imagesDir()
	if err != nil {
		// Deliberatamente non e' un errore fatale: un'istanza senza immagini
		// deve dirlo rispondendo 404, non andare in crash all'avvio. Il prezzo
		// e' che una copia dimenticata non fa fallire il deploy, ed e' per
		// questo che esiste il controllo post-deploy su /api/images (D35).
		return
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}

	loaded := map[string][]byte{}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		ext := strings.ToLower(filepath.Ext(name))
		if ext != ".jpg" && ext != ".jpeg" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			continue
		}
		loaded[name] = data
	}
	images = loaded
}

// imagesDir cerca la cartella delle immagini prima accanto alla directory di
// lavoro e poi accanto all'eseguibile.
//
// I due casi non sono ipotetici, sono i due modi in cui questo binario gira:
// in Azure `func pack` mette l'eseguibile nella RADICE del pacchetto, accanto a
// images/; in locale `func start` lo compila in bin/app, quindi accanto
// all'eseguibile non c'e' niente e la cartella sta una directory piu' su.
// Provarle entrambe evita di avere un worker che funziona solo in uno dei due
// posti — e un'istanza senza immagini e' silenziosa per costruzione (D35).
func imagesDir() (string, error) {
	if info, err := os.Stat("images"); err == nil && info.IsDir() {
		return "images", nil
	}
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	candidate := filepath.Join(filepath.Dir(exe), "images")
	if info, err := os.Stat(candidate); err == nil && info.IsDir() {
		return candidate, nil
	}
	return "", fmt.Errorf("cartella images non trovata")
}

func availableImages() []string {
	names := make([]string, 0, len(images))
	for name := range images {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

type catalogEntry struct {
	Name  string `json:"name"`
	Bytes int    `json:"bytes"`
}

// imageCatalog e' l'elenco delle immagini selezionabili, per il selettore del
// frontend.
//
// Deliberatamente NON include le dimensioni in pixel: ricavarle vorrebbe dire
// aprire l'header di ogni file all'avvio, cioe' toccare il decoder fuori dal
// percorso misurato (D3). Il numero di byte invece e' gratis.
func imageCatalog() []catalogEntry {
	names := availableImages()
	catalog := make([]catalogEntry, 0, len(names))
	for _, name := range names {
		catalog = append(catalog, catalogEntry{Name: name, Bytes: len(images[name])})
	}
	return catalog
}

// --- Geometria --------------------------------------------------------------

// targetHeight calcola l'altezza proporzionale in aritmetica intera.
//
// Deliberatamente NON usa math.Round: l'arrotondamento di libreria non e' la
// stessa operazione nei tre linguaggi (Python e C# arrotondano 0.5 al pari, Go
// per eccesso in valore assoluto), e su un caso limite darebbero altezze
// diverse. Questa espressione e' half-up esatto e ricalca carattere per
// carattere quella di Python e C#, inclusa la divisione intera di srcWidth (D7).
//
// I casi attesi sono fissati in shared/conformance/height_cases.json, che i
// test dei tre linguaggi leggono per verificare di essere d'accordo.
func targetHeight(srcWidth, srcHeight, dstWidth int) (int, error) {
	if srcWidth <= 0 || srcHeight <= 0 {
		return 0, invalidParameter("dimensioni sorgente non valide")
	}
	// int64 e non int: su una piattaforma a 32 bit il prodotto potrebbe
	// traboccare, e in Python il problema non esiste perche' gli interi non
	// hanno limite. Un overflow silenzioso darebbe un'altezza sbagliata senza
	// nessun segnale.
	height := (int64(srcHeight)*int64(dstWidth) + int64(srcWidth)/2) / int64(srcWidth)
	if height < 1 {
		height = 1
	}
	return int(height), nil
}

// --- Validazione dei parametri ----------------------------------------------

func parseInt(raw, name string, fallback, lo, hi int) (int, error) {
	if raw == "" {
		return fallback, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil {
		return 0, invalidParameter("%s deve essere un intero, ricevuto '%s'", name, raw)
	}
	if value < lo || value > hi {
		return 0, invalidParameter("%s deve stare tra %d e %d, ricevuto %d", name, lo, hi, value)
	}
	return value, nil
}

type params struct {
	Image       string
	Count       int
	Width       int
	Quality     int
	WantHash    bool
	ReturnImage bool
}

// parseParams legge i parametri dalla query string. get e' una funzione
// nome -> valore, come negli altri due worker.
func parseParams(get func(string) string) (params, error) {
	var p params

	name := get("image")
	if name == "" {
		return p, invalidParameter("parametro 'image' obbligatorio. Disponibili: %s", availableList())
	}
	if _, ok := images[name]; !ok {
		return p, imageNotFound("immagine '%s' non trovata. Disponibili: %s", name, availableList())
	}
	p.Image = name

	var err error
	if p.Count, err = parseInt(get("count"), "count", 1, minCount, maxCount); err != nil {
		return params{}, err
	}
	if p.Width, err = parseInt(get("width"), "width", defaultWidth, minWidth, maxWidth); err != nil {
		return params{}, err
	}
	if p.Quality, err = parseInt(get("quality"), "quality", defaultQuality, minQuality, maxQuality); err != nil {
		return params{}, err
	}
	p.WantHash = get("hash") == "1"
	p.ReturnImage = get("return") == "image"
	return p, nil
}

func availableList() string {
	names := availableImages()
	if len(names) == 0 {
		return "nessuna"
	}
	return strings.Join(names, ", ")
}

// --- Pipeline ---------------------------------------------------------------

type pipelineResult struct {
	Width       int
	Height      int
	OutputBytes int
	TotalMs     float64
	Payload     []byte
	Sha256      *string
}

// runPipeline esegue decode -> resize -> encode count volte sulla stessa
// immagine.
//
// Sempre la stessa immagine, mai a rotazione: ruotare introdurrebbe varianza
// nel carico a seconda di come cade N sul ciclo, che e' rumore gratuito in un
// esperimento il cui unico scopo e' confrontare durate (D4).
//
// Un solo cronometro attorno all'intera pipeline, non tre separati: la
// scomposizione decode/resize/encode e' stata scartata per tenere la
// strumentazione minima (D6, D25).
func runPipeline(p params) (pipelineResult, error) {
	raw := images[p.Image]
	var total time.Duration
	var payload []byte
	height := 0

	for i := 0; i < p.Count; i++ {
		started := time.Now()

		source, err := jpeg.Decode(bytes.NewReader(raw))
		if err != nil {
			return pipelineResult{}, fmt.Errorf("decodifica fallita: %w", err)
		}

		bounds := source.Bounds()
		height, err = targetHeight(bounds.Dx(), bounds.Dy(), p.Width)
		if err != nil {
			return pipelineResult{}, err
		}

		// RGBA come destinazione: il decoder restituisce di norma un
		// *image.YCbCr, e scalare direttamente li' dentro vorrebbe dire
		// interpolare nello spazio YCbCr sottocampionato invece che in RGB,
		// che non e' quello che fanno Pillow e ImageSharp (entrambi lavorano
		// su pixel RGB).
		destination := image.NewRGBA(image.Rect(0, 0, p.Width, height))

		// BiLinear e NON ApproxBiLinear: quest'ultimo campiona 4 pixel vicini
		// a prescindere dal fattore di riduzione e il suo costo "is
		// independent of the number of source pixels", quindi non fa lo stesso
		// lavoro degli altri due ne' in qualita' ne' in quantita' di calcolo.
		// Sarebbe un vantaggio artificiale regalato a Go (D9).
		draw.BiLinear.Scale(destination, destination.Bounds(), source, bounds, draw.Src, nil)

		var buffer bytes.Buffer
		// image/jpeg ha un solo parametro, Quality, e scrive sempre "JPEG
		// 4:2:0 baseline format". E' proprio questa mancanza di scelta a
		// determinare il minimo comune denominatore che Pillow e ImageSharp
		// devono farsi imporre (D8): qui non c'e' niente da configurare, ed e'
		// il punto.
		if err := jpeg.Encode(&buffer, destination, &jpeg.Options{Quality: p.Quality}); err != nil {
			return pipelineResult{}, fmt.Errorf("codifica fallita: %w", err)
		}

		total += time.Since(started)
		payload = buffer.Bytes()
	}

	// L'hash sta fuori dal cronometro ed e' spento di default: SHA-256 e'
	// accelerato in hardware su .NET e Go ma non in Python, quindi tenerlo
	// acceso durante le misure infilerebbe nel confronto una differenza di
	// velocita' che non c'entra nulla con l'image processing (D5).
	var digest *string
	if p.WantHash {
		sum := sha256.Sum256(payload)
		encoded := hex.EncodeToString(sum[:])
		digest = &encoded
	}

	return pipelineResult{
		Width:       p.Width,
		Height:      height,
		OutputBytes: len(payload),
		TotalMs:     float64(total.Nanoseconds()) / 1e6,
		Payload:     payload,
		Sha256:      digest,
	}, nil
}
