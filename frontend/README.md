# Frontend (Azure Static Web App)

Il frontend è **fisso**: non cambia tra i linguaggi, cambia solo il backend che chiama. Mostra l'immagine prima e dopo il resize usando `&return=image`.

Metriche e percentili **non** passano da qui: li producono il generatore di carico e Application Insights. Questa pagina serve a far vedere che la cosa funziona davvero, non a misurarla.

## Da decidere (TODO.md, Fase 6)

- Se deve puntare a **tutti e tre i backend** con un selettore di linguaggio, o a uno solo.
- Con quale tecnologia — HTML + JS senza framework sarebbe coerente con "meno parti in movimento".

## CORS

La pagina sta su `…azurestaticapps.net` e chiama `…azurewebsites.net`: per il browser sono due origini diverse, e senza l'header `Access-Control-Allow-Origin` dalla function la risposta arriva ma non è leggibile. Si risolve mettendo l'origine della SWA nell'allowlist CORS di ciascuna function app (D12) — non serve nessun proxy.

Da verificare **dal browser**, non dalla configurazione: è il tipo di cosa che sembra a posto finché non la si prova.
