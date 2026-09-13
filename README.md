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
POST /api/resize?image=<nome>&count=<1-200>&width=<1-4000>&quality=<1-95>[&hash=1][&return=image]
```

Risposta JSON di default (dimensioni, byte, tempi). `return=image` restituisce il JPEG per la demo visiva e **non va mai usato durante i run di misura**.

**Gli intervalli sono identici nei tre worker, e identico è anche cosa conta come numero valido**: solo cifre ASCII, `^[0-9]+$` — niente segno, spazi, separatori di cifre o cifre non ASCII. I casi sono fissati in `shared/conformance/param_cases.json` e le tre suite di test li leggono da lì, perché tre parser idiomatici (`int()`, `int.TryParse`, `strconv.Atoi`) accettano tre insiemi diversi di stringhe e "stesso contratto" smetterebbe di essere vero.

I tetti di `count` e `width` sono dimensionati su ciò che l'esperimento usa (`count=80`, `width=800`), non sul massimo rappresentabile: su un endpoint anonimo il caso peggiore lo paga il free grant.
