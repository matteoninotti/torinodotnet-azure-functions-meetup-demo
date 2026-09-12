module resizeworker

// 1.24.0 e' il minimo richiesto dalla documentazione del worker Go.
go 1.24.0

// Toolchain PINNATA, ed e' il pin piu' importante dei tre worker: in Go la
// libreria di image processing e' in parte la stdlib (`image/jpeg`), che viene
// spedita col compilatore. Cambiare versione di Go cambia il codec con cui si
// misura, esattamente come cambierebbe Pillow o ImageSharp. Un benchmark che
// gira su un compilatore diverso a ogni deploy non e' un benchmark.
toolchain go1.27.1

require (
	github.com/azure/azure-functions-golang-worker v0.7.0-preview
	golang.org/x/image v0.34.0
)

require (
	github.com/spf13/pflag v1.0.6 // indirect
	golang.org/x/net v0.50.0 // indirect
	golang.org/x/sys v0.41.0 // indirect
	golang.org/x/text v0.34.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260120221211-b8f7ae30c516 // indirect
	google.golang.org/grpc v1.80.0 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
)
