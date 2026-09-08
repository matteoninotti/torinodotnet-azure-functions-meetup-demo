# Azure Functions: confronto tra linguaggi

Materiale della demo per il talk **TorinoDotNet del 30 settembre 2026 @ Toolbox**: stesso endpoint HTTP di image resizing implementato in **Python, .NET e Go**, deployato su **Azure Functions Flex Consumption**, misurato con k6 e Application Insights per confrontare **performance e costi**.

## Dove sta cosa

| Percorso | Contenuto |
|---|---|
| `functions/python/` · `functions/dotnet/` · `functions/go/` | Le tre implementazioni dell'endpoint. Stesso contratto, stesse dimensioni di output, stessi parametri di libreria. |
| `shared/conformance/` | Casi di test condivisi che le tre implementazioni devono superare in modo identico. È il modo in cui la simmetria viene *verificata* invece che sperata. |
| `infra/` | Bicep: piani, function app, storage, Application Insights, Static Web App, Container Apps Environment. |
| `load/` | Script k6 e risultati dei run. |
| `frontend/` | Static Web App per la demo visiva. |
| `.github/workflows/` | Pipeline di build e deploy (manuale, `workflow_dispatch`). |

## Documenti

- **`instructions.md`** — la specifica: architettura sperimentale, metodologia di misurazione, modello di billing, gotchas, limitazioni dichiarate.
- **`TODO.md`** — lo stato dei lavori, per fase.
- **`CLAUDE.md`** — guardrail operativi.
- **Decision log** — fuori dal repo, nel vault. È la fonte di verità su ogni decisione presa (`D#`).

## Il contratto dell'endpoint

```
POST /api/resize?image=<nome>&count=<N>&width=<px>&quality=<1-95>[&hash=1][&return=image]
```

Risposta JSON di default (dimensioni, byte, tempi). `return=image` restituisce il JPEG per la demo visiva e **non va mai usato durante i run di misura**.
