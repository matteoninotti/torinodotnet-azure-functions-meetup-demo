// Un worker = un piano Flex Consumption + una function app.
//
// Sono separati per forza, non per scelta: su Flex vale una sola app per
// piano, quindi i tre linguaggi richiedono tre piani distinti. Questo modulo
// e' il pezzo che si istanzia tre volte.

@description('Nome del linguaggio, usato solo per comporre i nomi delle risorse.')
param language string

@description('Runtime stack. Valori ammessi da Flex: dotnet-isolated, python, java, node, powerShell, custom.')
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
@minValue(40)
@maxValue(1000)
param maximumInstanceCount int

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

output appName string = app.name
output defaultHostName string = app.properties.defaultHostName
output principalId string = app.identity.principalId
