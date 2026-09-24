// Un worker = un piano Flex Consumption + una function app.
//
// Sono separati per forza, non per scelta: su Flex vale una sola app per
// piano, quindi i tre linguaggi richiedono tre piani distinti. Questo modulo
// e' il pezzo che si istanzia tre volte.

@description('Nome del linguaggio, usato solo per comporre i nomi delle risorse.')
param language string

@description('Runtime stack. Valori ammessi da Flex: dotnet-isolated, python, java, node, powerShell, go, custom. Go non compare nella tabella dei language stack supportati perche\' e\' in public preview, ma il valore ARM esiste ed e\' esposto da az functionapp list-flexconsumption-runtimes (D85).')
param runtimeName string

@description('Versione del runtime stack. Per "custom" vale 1.0, non e\' la versione del linguaggio.')
param runtimeVersion string

param location string
param namePrefix string
param storageAccountName string
param deploymentContainerName string
param applicationInsightsConnectionString string

@description('Memoria per istanza. Fissata a 2048 dal progetto: e\' 1 vCPU intera.')
@allowed([512, 2048, 4096])
param instanceMemoryMB int

@description('Richieste HTTP concorrenti per istanza. Il progetto la vuole a 1.')
param perInstanceConcurrency int

@description('Tetto di scale-out. Non garantisce di arrivarci: la quota regionale di core puo\' fermare prima.')
// Il minimo della piattaforma e' 1 ("the lowest maximum instance count value is
// 1", [event-driven scaling](https://learn.microsoft.com/en-us/azure/azure-functions/event-driven-scaling#limit-scale-out)).
// 40 e' un pavimento del template, non della piattaforma: sotto quel valore la
// Metrica 3 non misurerebbe lo scale-out. Il tetto basso fuori dalle finestre di
// misura si imposta da CLI, non da qui (load/README.md, "Protocollo di ogni run").
@minValue(40)
@maxValue(1000)
param maximumInstanceCount int

@description('Origini ammesse dal CORS. Serve al frontend, che sta su un\'altra origine (D12).')
param allowedOrigins array

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: '${namePrefix}-plan-${language}'
  location: location
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    // Flex e' solo Linux: reserved=true e' quello che lo dichiara.
    reserved: true
  }
}

resource app 'Microsoft.Web/sites@2024-04-01' = {
  name: '${namePrefix}-${language}'
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      // HTTP/2 spento su TUTTI e tre i worker, non solo su Go. Per Go e'
      // richiesto durante la public preview (D31): il passo compare solo nella
      // quickstart CLI e non tra le "Known limitations" della reference, quindi
      // e' facile non trovarlo. Metterlo qui invece che in un `az resource
      // update` post-deploy e' lo stesso ragionamento di D39: dichiarato nel
      // Bicep, una re-provisioning lo RI-imposta invece di riportarlo al
      // default. E vale per tutti e tre perche' il protocollo di trasporto
      // farebbe parte di cio' che si confronta: due worker su HTTP/2 e uno su
      // HTTP/1.1 non sarebbero confrontabili.
      http20Enabled: false
      // Il frontend sta su *.azurestaticapps.net e chiama *.azurewebsites.net:
      // per il browser sono due origini diverse, e senza Access-Control-Allow-Origin
      // la risposta arriva ma non e' leggibile da JavaScript (D12).
      //
      // Nota su cosa NON e': qui il CORS non e' un confine di sicurezza. Gli
      // endpoint sono anonimi e pubblici, e un `curl` non chiede il permesso a
      // nessuno — il CORS vincola solo il codice che gira dentro una pagina.
      // Dichiararlo nel Bicep invece che con un comando post-deploy e' lo stesso
      // ragionamento di D39: una re-provisioning lo RI-imposta.
      cors: {
        allowedOrigins: allowedOrigins
        supportCredentials: false
      }
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsightsConnectionString
        }
      ]
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          // Valori ammessi dall'API: SystemAssignedIdentity,
          // UserAssignedIdentity, StorageAccountConnectionString. La managed
          // identity sarebbe piu' pulita, ma aggiunge un role assignment e la
          // sua propagazione, che sa far fallire il primo deploy in modo
          // intermittente. A venti giorni dal talk vince la via con meno
          // parti in movimento.
          authentication: {
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'AzureWebJobsStorage'
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: instanceMemoryMB
        maximumInstanceCount: maximumInstanceCount
        // Il pezzo che rende inutile il comando CLI post-deploy: dichiarata
        // qui, una re-provisioning la RI-IMPOSTA invece di riportarla al
        // default (16 a 2048 MB per tutti i runtime tranne Python).
        triggers: {
          http: {
            perInstanceConcurrency: perInstanceConcurrency
          }
        }
      }
      runtime: {
        name: runtimeName
        version: runtimeVersion
      }
    }
  }
}

// Pubblicazione con utente e password spenta, sul sito SCM e su FTPS. La
// pipeline deploya con un token ottenuto via OIDC e non passa da nessuna delle
// due ([Disable basic
// authentication](https://learn.microsoft.com/en-us/azure/app-service/configure-basic-auth-disable)).
// Dichiarate nel Bicep per lo stesso motivo di D39: una re-provisioning le
// RI-imposta invece di lasciarle com'erano.
resource scmBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: app
  name: 'scm'
  properties: {
    allow: false
  }
}

resource ftpBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: app
  name: 'ftp'
  properties: {
    allow: false
  }
}

output appName string = app.name
output defaultHostName string = app.properties.defaultHostName
output principalId string = app.identity.principalId
