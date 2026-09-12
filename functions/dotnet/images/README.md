# Immagini di test — cartella di destinazione

**Non mettere file qui a mano.** Questa cartella viene popolata da:

```
./scripts/sync-images.sh dotnet
```

che copia da `functions/images/`, la sorgente unica (vedi il README lì per il perché e per i vincoli sui file). Va lanciato **prima di `dotnet publish` o di `func start`** in locale, ed è lo stesso comando che userà la pipeline CI prima del deploy.

Un file messo qui a mano viene cancellato alla prima sincronizzazione: la destinazione rispecchia la sorgente, non il contrario.

I file veri non sono mai committati: sono ignorati da git e vivono solo in locale.

## Perché questa cartella esiste, se la sorgente è altrove

Il pacchetto di deploy di questo worker è l'output di `dotnet publish`, e `functions/images/` ne resta fuori per costruzione. Le immagini vanno copiate qui dentro **prima** del publish, ed è il `.csproj` — con l'`ItemGroup` su `images/**` — a farle finire nell'output: senza quella riga la copia avverrebbe e l'istanza si avvierebbe comunque con zero immagini.

## Come accorgersene se la copia non è avvenuta

`ResizeCore.Initialize()` non fallisce se la cartella è vuota o assente: lascia il catalogo vuoto e l'app parte lo stesso. I sintomi sono:

- `GET /api/images` → `{"images": []}`
- `GET /api/health` → `"images": []`
- `POST /api/resize?image=<qualunque>` → `404`
- in locale, i test che richiedono le immagini falliscono dicendo quale comando lanciare

È voluto — un'istanza senza immagini deve dirlo chiaramente invece di andare in crash all'avvio — ma significa che **una copia dimenticata non si manifesta come errore di deploy**. Controllare `GET /api/images` dopo ogni deploy è il modo più veloce per accorgersene.
