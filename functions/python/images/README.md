# Immagini di test

Qui vanno le **2–3 immagini JPEG** usate dall'esperimento, committate nel repo e caricate in memoria all'avvio dell'istanza.

Vincoli, da `instructions.md`:

- **Identiche nei tre deploy**, così l'offset che introducono sul peso del pacchetto è costante tra i tre linguaggi.
- **Pochi MB in totale**: influenzano il cold start, e più sono grandi più quell'offset pesa.
- Formato **JPEG**, colore (mode RGB): un JPEG in scala di grigi o CMYK farebbe scattare la conversione in `resize_core`, che è lavoro in più asimmetrico rispetto agli altri due linguaggi.

**Ancora da decidere** (TODO.md, Fase 1): risoluzione, numero, provenienza e licenza. Finché la cartella è vuota, l'endpoint risponde `404` a qualunque `image=` e i test della pipeline si auto-saltano.

La licenza va scelta con attenzione: il repo è pubblico e le immagini finiranno proiettate durante il talk.
