// Infrastruttura della demo: risorse condivise + un worker per linguaggio.
//
// Deploy a scope RESOURCE GROUP, non subscription: rg-torinodotnet-demo
// esiste gia' ed e' anche il meccanismo di teardown del progetto ("cancella
// il resource group"). Il Bicep ci si appoggia invece di ricrearlo.
//
//   az deployment group create \
//     --resource-group rg-torinodotnet-demo \
//     --template-file infra/main.bicep

targetScope = 'resourceGroup'

@description('Prefisso comune a tutte le risorse.')
param namePrefix string = 'torinodotnet'

@description('Regione. Deve supportare Flex Consumption: az functionapp list-flexconsumption-locations')
param location string = 'italynorth'

@description('Linguaggi da istanziare. In Fase 2 solo python; .NET e Go si aggiungono in Fase 4 e 5.')
param workers array = [
  {
    language: 'python'
    runtimeName: 'python'
    runtimeVersion: '3.12'
  }
]

// --- Parametri dell'esperimento ---------------------------------------------
// Non sono default ragionevoli: sono vincoli. Cambiarli invalida il confronto
// tra i tre linguaggi, quindi stanno scritti espliciti invece che ereditati.

@description('2048 MB = 1 vCPU intera. Scendere a 512 non fa risparmiare su workload CPU-bound.')
@allowed([512, 2048, 4096])
param instanceMemoryMB int = 2048

@description('Una richiesta per istanza: il parallelismo dev\'essere orizzontale, non interno.')
param perInstanceConcurrency int = 1

// Con concorrenza a 1 ogni istanza serve una richiesta alla volta, quindi
// questo numero E' il tetto delle richieste in volo, ed e' il tetto di quanti
// cold start simultanei la Metrica 3 puo' forzare. A 2.048 MB un'istanza vale
// 1 core, quindi 200 istanze = 200 core sui 250 della quota regionale (D42):
// i 50 di margine servono a impedire che un burst mal dimensionato saturi la
// quota della regione nel mezzo di un run (D46).
@description('Tetto di scale-out per il burst della Metrica 3. 200 su 250 core di quota, con margine.')
@minValue(40)
@maxValue(1000)
param maximumInstanceCount int = 200

var deploymentContainerName = 'deployment-packages'

// Container privato da cui la pipeline preleva le immagini di test prima del
// build. E' la risposta al "come arrivano in CI" (D40): la pipeline si
// autentica gia' su Azure via OIDC, quindi legge da qui senza nessun secret
// aggiuntivo, e i file non passano mai dal repo.
var testImagesContainerName = 'test-images'

// --- Risorse condivise ------------------------------------------------------
// Uno storage e una coppia Log Analytics/App Insights per tutti e tre i
// worker. Il vincolo "una app per piano" riguarda il piano, non queste:
// condividerle tiene il confronto piu' pulito, perche' la telemetria dei tre
// linguaggi finisce nello stesso posto e si interroga con una query sola.

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  // Massimo 24 caratteri, solo minuscole e cifre. uniqueString ne produce 13
  // e va tenuto intero (e' cio' che garantisce l'unicita' globale): a essere
  // troncato e' il prefisso, non lui. 2 + 9 + 13 = 24 esatti.
  name: 'st${take(namePrefix, 9)}${uniqueString(resourceGroup().id)}'
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentContainerName
}

resource testImagesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: testImagesContainerName
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-logs'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-insights'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    // Il sampling dell'host e' gia' spento in host.json. Qui si spegne anche
    // quello lato ingestion: un p95 calcolato su un campione non e' un p95.
    SamplingPercentage: 100
  }
}

// --- Un worker per linguaggio -----------------------------------------------

module worker 'worker.bicep' = [
  for w in workers: {
    name: 'worker-${w.language}'
    params: {
      language: w.language
      runtimeName: w.runtimeName
      runtimeVersion: w.runtimeVersion
      location: location
      namePrefix: namePrefix
      storageAccountName: storage.name
      deploymentContainerName: deploymentContainerName
      applicationInsightsConnectionString: applicationInsights.properties.ConnectionString
      instanceMemoryMB: instanceMemoryMB
      perInstanceConcurrency: perInstanceConcurrency
      maximumInstanceCount: maximumInstanceCount
    }
    dependsOn: [
      deploymentContainer
    ]
  }
]

output storageAccountName string = storage.name
output testImagesContainerName string = testImagesContainerName
output applicationInsightsName string = applicationInsights.name
output workerHostNames array = [for (w, i) in workers: worker[i].outputs.defaultHostName]
