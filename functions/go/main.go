// HTTP trigger dell'endpoint di resize — implementazione Go.
//
// Contratto (identico nei tre linguaggi):
//
//	POST /api/resize?image=<nome>&count=<N>&width=<px>&quality=<1-95>[&hash=1][&return=image]
//
// La risposta di default e' JSON. `return=image` restituisce il JPEG per la
// demo visiva e non va mai usato durante i run di misura: aggiungerebbe alla
// latenza la banda di download dell'immagine, che e' esattamente il rumore che
// la forma `?image=` dell'endpoint serve a eliminare.
package main

import (
	"encoding/json"
	"errors"
	"log/slog"
	"math"
	"net/http"
	"runtime"

	"github.com/azure/azure-functions-golang-worker/sdk"
	"github.com/azure/azure-functions-golang-worker/worker"
)

const language = "go"

// Prefisso su cui si aggancia la query di Log Analytics. Un'unica riga di log
// con un payload JSON stabile, invece delle customDimensions: funziona allo
// stesso modo nei tre worker e non dipende da come ciascuno inoltra i campi
// strutturati. Il payload comincia a substring(Message, 15).
const metricsPrefix = "RESIZE_METRICS"

// runtimeVersion e' la versione del compilatore con cui questo binario e'
// stato costruito — l'equivalente di platform.python_version() e di
// RuntimeInformation.FrameworkDescription negli altri due worker.
var runtimeVersion = runtime.Version()

// metrics e' il payload emesso nel log e incluso nella risposta. L'ordine dei
// campi e' quello di Python e .NET: le tre risposte si leggono affiancate in
// slide, e un ordine diverso le renderebbe piu' difficili da confrontare.
type metrics struct {
	Language    string  `json:"language"`
	Image       string  `json:"image"`
	Count       int     `json:"count"`
	Width       int     `json:"width"`
	Height      int     `json:"height"`
	Quality     int     `json:"quality"`
	OutputBytes int     `json:"output_bytes"`
	TotalMs     float64 `json:"total_ms"`
}

// resizeResponse aggiunge alla misura i due campi che restano fuori dal log.
type resizeResponse struct {
	metrics
	Runtime string  `json:"runtime"`
	Sha256  *string `json:"sha256"`
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, errorResponse{Error: message})
}

type errorResponse struct {
	Error string `json:"error"`
}

type healthResponse struct {
	Language string   `json:"language"`
	Runtime  string   `json:"runtime"`
	Images   []string `json:"images"`
}

type imagesResponse struct {
	Images []catalogEntry `json:"images"`
}

func resizeHandler(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()

	p, err := parseParams(func(name string) string { return query.Get(name) })
	if err != nil {
		var notFound *imageNotFoundError
		if errors.As(err, &notFound) {
			writeError(w, http.StatusNotFound, err.Error())
			return
		}
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	result, err := runPipeline(p)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	measure := metrics{
		Language:    language,
		Image:       p.Image,
		Count:       p.Count,
		Width:       result.Width,
		Height:      result.Height,
		Quality:     p.Quality,
		OutputBytes: result.OutputBytes,
		TotalMs:     math.Round(result.TotalMs*1000) / 1000,
	}

	payload, err := json.Marshal(measure)
	if err == nil {
		// slog.InfoContext e non log.Printf: e' il modo documentato di
		// correlare una riga di log all'invocazione corrente, e il worker
		// inoltra il messaggio all'host intatto, quindi la riga arriva in
		// AppTraces nella stessa forma degli altri due worker.
		slog.InfoContext(r.Context(), metricsPrefix+" "+string(payload))
	}

	if p.ReturnImage {
		w.Header().Set("Content-Type", "image/jpeg")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(result.Payload)
		return
	}

	writeJSON(w, http.StatusOK, resizeResponse{
		metrics: measure,
		Runtime: runtimeVersion,
		Sha256:  result.Sha256,
	})
}

// healthHandler e' diagnostico: conferma quali immagini l'istanza ha caricato
// all'avvio.
//
// Non fa parte dell'esperimento — serve a scoprire dal browser che il pacchetto
// di deploy e' arrivato completo, senza dover leggere i log.
//
// NON e' la fonte dati del frontend: per quello c'e' /api/images. La
// sovrapposizione nel payload e' voluta, i due endpoint hanno consumatori e
// contratti diversi e devono poter evolvere separatamente (D34).
func healthHandler(w http.ResponseWriter, r *http.Request) {
	// Struct e non map: encoding/json ordina le chiavi di una map in ordine
	// alfabetico, e l'ordine dei campi fa parte di cio' che si guarda quando
	// le tre risposte si leggono affiancate. Con lo struct l'ordine e' quello
	// dichiarato, come in Python e .NET.
	writeJSON(w, http.StatusOK, healthResponse{
		Language: language,
		Runtime:  runtimeVersion,
		Images:   availableImages(),
	})
}

// imagesHandler e' l'elenco delle immagini selezionabili: contratto per il
// selettore della SWA.
//
// Esiste perche' il frontend possa popolarsi da solo invece di avere i nomi dei
// file cablati dentro: cambiando il pool con un redeploy, il selettore si
// aggiorna senza che nessuno lo tocchi. I nomi restituiti qui sono gli stessi
// che POST /api/resize accetta come ?image= (D34).
func imagesHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, imagesResponse{Images: imageCatalog()})
}

func main() {
	// Le immagini si caricano QUI, prima di worker.Start: e' la fase di app
	// init, la stessa in cui Python le carica importando il modulo. La Metrica
	// 4 misura la differenza fra app init e finestra fatturata, quindi il
	// punto in cui avviene il caricamento dev'essere lo stesso nei tre
	// linguaggi (D3).
	loadImages()

	app := sdk.FunctionApp()

	// I nomi registrati qui diventano il campo Name di AppRequests, su cui si
	// aggancia run-summary.kql: devono restare 'resize', 'health' e 'images'
	// esattamente come negli altri due worker.
	app.HTTP("resize", resizeHandler,
		sdk.WithMethods("POST"),
		sdk.WithAuth("anonymous"),
		sdk.WithRoute("resize"),
	)
	app.HTTP("health", healthHandler,
		sdk.WithMethods("GET"),
		sdk.WithAuth("anonymous"),
		sdk.WithRoute("health"),
	)
	app.HTTP("images", imagesHandler,
		sdk.WithMethods("GET"),
		sdk.WithAuth("anonymous"),
		sdk.WithRoute("images"),
	)

	worker.Start(app)
}
