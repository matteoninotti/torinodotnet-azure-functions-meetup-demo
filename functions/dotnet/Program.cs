using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.Hosting;

using ResizeWorker;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

// Nessuna integrazione diretta con Application Insights, ed e' una rimozione
// deliberata: il template ufficiale `func init --worker-runtime dotnet-isolated`
// genera i pacchetti OpenTelemetry e un host.json con "telemetryMode":
// "OpenTelemetry", che manda i log del worker direttamente ad Application
// Insights invece di passarli all'host. In quella modalita' host.json non
// governa piu' il sampling (D14) e la telemetria cambia forma: i tre worker
// non sarebbero piu' confrontabili con la stessa query. Restiamo sul default
// documentato, worker -> host -> Application Insights, che e' anche cio' che
// fanno Python e Go per costruzione.

// Le immagini si caricano QUI, prima di Run(), non in uno static initializer:
// un campo statico si inizializzerebbe pigramente alla prima richiesta, cioe'
// dentro la finestra fatturata, mentre in Python l'import del modulo le carica
// in app init. La Metrica 4 misura proprio quella differenza, quindi il punto
// in cui avviene il caricamento dev'essere lo stesso nei tre linguaggi (D3).
ResizeCore.Initialize();

builder.Build().Run();
