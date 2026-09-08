# Infrastruttura (Bicep)

Strumento scelto: **Bicep** (D20). Nativo Azure, nessuno state file da custodire in un repo pubblico, e il teardown è "cancella il resource group".

Da costruire (TODO.md, Fase 2):

- Resource group unico, **Italy North**.
- Uno storage account e **un piano Flex Consumption per ciascuna delle tre function app** — su Flex vale il vincolo *una sola app per piano*.
- Instance size **2.048 MB** su tutte e tre.
- Application Insights + Log Analytics, con il **sampling disattivato** (D14).
- Static Web App, con la sua origine in allowlist CORS sulle function app (D12).
- Container Apps Environment per il job k6 dei run finali.

## Attenzione: la concorrenza a 1 non si imposta qui

La **HTTP trigger concurrency** non è una proprietà di `host.json` né, al momento, qualcosa che si scrive comodamente in Bicep: va impostata via Azure CLI ([Set HTTP concurrency limits](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-how-to#set-http-concurrency-limits)).

E **va impostata esplicitamente su tutte e tre le app** (D22). A 2.048 MB il default documentato è **16**, tranne per le app Python dove è **1** ([Concurrency in Azure Functions § HTTP trigger concurrency](https://learn.microsoft.com/en-us/azure/azure-functions/functions-concurrency)). Lasciare i default significherebbe confrontare Python a concorrenza 1 contro .NET e Go a concorrenza 16: numeri privi di significato.

Serve quindi uno script di post-provisioning che la forzi a 1 ovunque, e una verifica che sia davvero applicata prima del primo run buono.
