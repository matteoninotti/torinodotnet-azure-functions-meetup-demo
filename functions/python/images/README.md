# Immagini di test — cartella di destinazione

**Non mettere file qui a mano.** Questa cartella viene popolata da:

```
./scripts/sync-images.sh python
```

che copia da `functions/images/`, la sorgente unica (vedi il README lì per il perché e per i vincoli sui file). Va lanciato **prima di `func start`** in locale, ed è lo stesso comando che userà la pipeline CI prima del deploy.

Un file messo qui a mano viene cancellato alla prima sincronizzazione: la destinazione rispecchia la sorgente, non il contrario.

I file veri non sono mai committati: sono ignorati da git e vivono solo in locale (D33 — materiale protetto da copyright, repo pubblico).

## Perché questa cartella esiste, se la sorgente è altrove

Il pacchetto di deploy è la cartella che contiene `host.json`, e niente al di fuori di essa. `functions/images/` è fuori dal pacchetto per costruzione, quindi le immagini vanno copiate qui dentro prima del build, altrimenti l'istanza si avvia con zero immagini.

## Come accorgersene se la copia non è avvenuta

`resize_core._load_images()` non fallisce se la cartella è vuota: restituisce un dizionario vuoto e l'app parte lo stesso. I sintomi sono:

- `GET /api/images` → `{"images": []}`
- `GET /api/health` → `"images": []`
- `POST /api/resize?image=<qualunque>` → `404`
- in locale, 9 test si auto-saltano invece di fallire

È voluto — un'istanza senza immagini deve dirlo chiaramente invece di andare in crash all'avvio — ma significa che **una copia dimenticata non si manifesta come errore di deploy**. Controllare `GET /api/images` dopo ogni deploy è il modo più veloce per accorgersene.
