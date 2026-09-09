# Immagini di test — sorgente unica

Questa è la **sola copia** delle immagini di test su cui lavorare. I file veri non sono qui dentro nel repo: sono ignorati da git e vivono solo in locale.

## Perché una cartella sola invece di tre

Le tre implementazioni devono ricevere **esattamente gli stessi byte**: è il presupposto di metà delle affermazioni dell'esperimento. Tenere tre copie separate in `functions/python/images/`, `functions/dotnet/images/` e `functions/go/images/` significherebbe che qualcuno, prima o poi, ne aggiorna una e non le altre — e il confronto diventerebbe silenziosamente falso, senza che nessun test se ne accorga.

Una sorgente sola, tre destinazioni popolate copiando: la divergenza diventa impossibile invece che improbabile.

## Perché servono comunque le tre cartelle di destinazione

Non si può usare _solo_ questa cartella. Il pacchetto di deploy di una function app è **la cartella che contiene `host.json`**, e niente al di fuori di essa: `func` definisce il progetto proprio così (se manca `host.json` risponde _"Required file 'host.json' not found in directory"_), `.funcignore` filtra i path relativi a quella cartella, e il log di deploy del probe Go diceva _"Creating archive for current directory..."_.

Quindi `functions/images/` è fuori dal pacchetto di ciascun worker per costruzione. Le immagini devono essere **copiate dentro** `functions/<linguaggio>/images/` prima del build.

## Il flusso

```
functions/images/            ← sorgente unica, solo locale, mai committata
        │
        │   ./scripts/sync-images.sh python|dotnet|go|all
        │
        ├──→ functions/python/images/
        ├──→ functions/dotnet/images/
        └──→ functions/go/images/
```

La copia non si fa a mano: la fa `scripts/sync-images.sh`, che è lo stesso comando usato in locale prima di `func start` e dalla pipeline CI prima del deploy. Non è solo un `cp` — **fallisce apposta** in tre casi che altrimenti passerebbero silenziosi:

1. **sorgente vuota** — l'app si avvierebbe lo stesso rispondendo `404` su tutto, senza che il deploy fallisca;
2. **file non JPEG** — controlla i magic byte, non l'estensione: un PNG rinominato eserciterebbe il decoder sbagliato falsando il confronto (è già successo, D34);
3. **destinazione che non rispecchia la sorgente** — verifica il risultato invece di fidarsi dei comandi, perché una cancellazione fallita lascerebbe un file orfano che verrebbe comunque deployato e resterebbe selezionabile via `?image=`.

La copia avviene **a deploy-time, non a runtime**: la function non scarica niente da rete all'avvio. Se lo facesse, aggiungerebbe una chiamata di rete proprio dentro la fase che le Metriche 2, 3 e 4 misurano (D33).

## Vincoli sui file

- **JPEG veri**, non file rinominati: il decoder JPEG è il punto dove vive l'asimmetria tra i tre linguaggi (D3). Un PNG con estensione `.jpg` esercita il decoder sbagliato e falsa la misura — è già successo una volta (D34).
- **Identiche in tutti e tre i deploy**, così l'offset che introducono sul peso del pacchetto è costante.
- **Pochi MB in totale**: influenzano il cold start.
- **Mode RGB**: un JPEG in scala di grigi o CMYK farebbe scattare una conversione in più, asimmetrica rispetto agli altri due linguaggi.
