# Azure Functions: confronto tra linguaggi

Materiale della demo per il talk **TorinoDotNet del 30 settembre 2026 @ Toolbox**: stesso endpoint HTTP di image resizing implementato in **Python, .NET e Go**, deployato su **Azure Functions Flex Consumption**, misurato con k6 e Application Insights per confrontare **performance e costi**.

## Dove sta cosa

| Percorso | Contenuto |
|---|---|
| `functions/python/` · `functions/dotnet/` · `functions/go/` | Le tre implementazioni dell'endpoint. Stesso contratto, stesse dimensioni di output, stessi parametri di libreria. |
| `shared/conformance/` | Casi di test condivisi che le tre implementazioni devono superare in modo identico. È il modo in cui la simmetria viene *verificata* invece che sperata. |
| `infra/` | Bicep: piani, function app, storage, Application Insights, Static Web App. Nessun Container Apps Environment: servirebbe solo se il generatore di carico finisse in un ACA Job, ed è ancora da decidere (D59). |
| `load/` | Script k6 e risultati dei run. |
| `frontend/` | Static Web App per la demo visiva: manda la stessa richiesta ai tre worker e mostra i risultati affiancati. |
| `.github/workflows/` | Pipeline di build e deploy (manuale, `workflow_dispatch`). |

## Documenti

- **`instructions.md`** — la specifica: architettura sperimentale, metodologia di misurazione, modello di billing, gotchas, limitazioni dichiarate.
- **`TODO.md`** — lo stato dei lavori, per fase.
- **`CLAUDE.md`** — guardrail operativi.
- **Decision log** — fuori dal repo, nel vault. È la fonte di verità su ogni decisione presa (`D#`).

## Il contratto dell'endpoint

```
POST /api/resize?image=<nome>&count=<1-500>&width=<1-4000>&quality=<1-95>[&hash=1][&return=image]
```

Risposta JSON di default (dimensioni, byte, tempi). `return=image` restituisce il JPEG per la demo visiva e **non va mai usato durante i run di misura**.

**Gli intervalli sono identici nei tre worker, e identico è anche cosa conta come numero valido**: solo cifre ASCII, `^[0-9]+$` — niente segno, spazi, separatori di cifre o cifre non ASCII. I casi sono fissati in `shared/conformance/param_cases.json` e le tre suite di test li leggono da lì, perché tre parser idiomatici (`int()`, `int.TryParse`, `strconv.Atoi`) accettano tre insiemi diversi di stringhe e "stesso contratto" smetterebbe di essere vero.

I tetti di `count` e `width` sono dimensionati su ciò che l'esperimento usa (`count=80`, `width=800`), non sul massimo rappresentabile: su un endpoint anonimo il caso peggiore lo paga il free grant.

## Lanciare i test in locale

⚠️ **Su un clone appena fatto le tre suite falliscono, ed è voluto.** Le immagini di test non stanno nel repo: restano in locale e si iniettano nel pacchetto a deploy-time. Senza di esse i test che dipendono dalle immagini **falliscono invece di auto-saltarsi**, perché sono quelli che verificano la conformità fra i tre linguaggi — geometria dell'output, parametri dell'encoder, tetti dei parametri — e una suite che si auto-salta resta verde senza aver verificato niente.

Il messaggio di fallimento dice già quale comando lanciare. Prima dei test, quindi:

```bash
./scripts/sync-images.sh all
```

Copia le immagini dalla sorgente unica `functions/images/` nelle tre cartelle di destinazione. Se anche la sorgente è vuota — è il caso di un clone nuovo — lo script si ferma dicendolo: i file veri vanno messi lì a mano, oppure li scarica la pipeline da un container privato dello stesso storage account.

Poi, una suite per linguaggio. Python vuole prima le dipendenze di sviluppo (Pillow più `pytest`), in un ambiente virtuale su Python 3.12 — la stessa minore dichiarata nel Bicep, perché Pillow non è la stessa build su due minori diverse:

```bash
pip install -r functions/python/requirements-dev.txt
```

```bash
pytest functions/python -q
```

```bash
cd functions/go && go test ./...
```

```bash
dotnet test functions/dotnet-tests/ResizeWorker.Tests.csproj -c Release --nologo
```

In CI non serve farci caso: `sync-images.sh` gira prima degli step di test, sempre.
