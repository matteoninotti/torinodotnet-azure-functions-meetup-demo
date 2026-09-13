# Frontend (Azure Static Web App)

Pubblicato su **https://lemon-beach-0a298dc0f.5.azurestaticapps.net**

Il frontend è **fisso**: non cambia tra i linguaggi, cambia solo il backend che chiama. Manda la stessa richiesta a tutti e tre i worker e mostra i tre risultati affiancati (D88).

HTML + JS senza framework, tre file e nessuno step di build: la SWA serve file statici e la pagina fa quattro `fetch` in croce.

Metriche e percentili **non** passano da qui: li producono il generatore di carico e Application Insights. Questa pagina serve a far vedere che la cosa funziona davvero, non a misurarla — ed è per questo che il tempo mostrato sulle card è il `total_ms` riportato dalla function e non un cronometro del browser.

## Come funziona

- Il menu delle immagini si popola da `GET /api/images` (D34), interrogando **tutti e tre** i backend e offrendo solo i nomi presenti su tutti: un elenco divergente è un pacchetto di deploy partito senza le immagini, e va visto subito invece che scoprirlo con un 404 al primo resize.
- Ogni esecuzione manda **due** richieste per backend: una senza `return` per le misure in JSON, una con `return=image&count=1` per il JPEG da mostrare. Due e non una perché il contratto risponde o l'uno o l'altro; `count=1` sull'immagine perché `count` è una manopola sul tempo e non sul risultato.

## Deploy

```
./scripts/deploy-frontend.sh
```

Locale e non dalla pipeline, di proposito (D94): collegare la SWA al repo farebbe deployare a ogni push, e nel resto del progetto il deploy è `workflow_dispatch` perché un deploy involontario nel mezzo di un run di misura invalida la misura.

## Regione

La SWA sta in **East US 2**, non in Italy North con i worker: `Microsoft.Web/staticSites` non esiste in Italy North, e West Europe — la più vicina fra quelle ammesse — è rifiutata da questa sottoscrizione (D93). Non tocca le misure, ma la latenza che si vede nella demo dal vivo non è quella delle slide.

## CORS

La pagina sta su `…azurestaticapps.net` e chiama `…azurewebsites.net`: per il browser sono due origini diverse, e senza l'header `Access-Control-Allow-Origin` dalla function la risposta arriva ma non è leggibile. È dichiarato nel Bicep (D12, D93), con l'origine letta dalla risorsa SWA stessa invece che scritta a mano.

⚠️ Per rileggerlo serve **`az functionapp cors show`**: `az resource show` sul sito restituisce `siteConfig.cors` a `null` anche quando il CORS c'è ed è funzionante (D93).

Verificato **dal browser**, non dalla configurazione: è il tipo di cosa che sembra a posto finché non la si prova.

## Cosa non mostra

L'**immagine sorgente**. Nessun endpoint la restituisce, e aggiungerlo significherebbe cambiare la forma del contratto su tutti e tre i worker: decisione aperta (D95). Al suo posto la card riporta il peso di partenza accanto a quello di arrivo.
