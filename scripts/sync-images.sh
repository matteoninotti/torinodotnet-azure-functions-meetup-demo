#!/usr/bin/env bash
#
# Copia le immagini di test dalla sorgente unica (functions/images/) nella
# cartella di un worker, da dove il pacchetto di deploy le raccogliera'.
#
# Serve perche' il pacchetto di deploy e' la sola cartella che contiene
# host.json: functions/images/ ne resta fuori per costruzione (D35).
#
# Non e' solo un cp. Fallisce rumorosamente in due casi che altrimenti
# passerebbero silenziosi fino a produzione:
#
#   - sorgente vuota  -> l'app si avvierebbe lo stesso, rispondendo 404 su
#                        ogni richiesta, senza che il deploy fallisca (D35)
#   - file non JPEG   -> eserciterebbe il decoder sbagliato, falsando il
#                        confronto SIMD che e' il cuore dell'esperimento
#                        (D3). E' gia' successo una volta con un PNG
#                        rinominato .jpg (D34)
#
# Uso: ./scripts/sync-images.sh python|dotnet|go|all
#
# Bash 3.2 compatibile (e' quello di macOS): niente array associativi,
# niente mapfile. Nessuna dipendenza esterna: gira in CI prima che le
# dipendenze del progetto siano installate.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/functions/images"
ALL_WORKERS="python dotnet go"

usage() {
    echo "Uso: $(basename "$0") python|dotnet|go|all" >&2
    exit 2
}

# I file immagine della sorgente, esclusi i README. Stampa un percorso per
# riga; nessun output se non ce n'e' nessuno.
list_source_images() {
    find "$SOURCE_DIR" -maxdepth 1 -type f ! -name 'README.md' ! -name '.*' | sort
}

# JPEG inizia con FF D8 FF. Il controllo e' sui byte, non sull'estensione:
# e' esattamente l'errore che vogliamo intercettare.
is_jpeg() {
    local magic
    magic="$(head -c 3 "$1" | od -An -tx1 | tr -d ' \n')"
    [ "$magic" = "ffd8ff" ]
}

describe_format() {
    local described
    described="$(file -b "$1" 2>/dev/null || echo "formato sconosciuto")"
    echo "$described"
}

validate_source() {
    if [ ! -d "$SOURCE_DIR" ]; then
        echo "ERRORE: la sorgente non esiste: $SOURCE_DIR" >&2
        echo "        Vedi functions/images/README.md per cosa va messo li' dentro." >&2
        exit 1
    fi

    if [ -z "$(list_source_images)" ]; then
        echo "ERRORE: la sorgente non contiene nessuna immagine: $SOURCE_DIR" >&2
        echo "        Senza immagini l'app si avvia lo stesso e risponde 404 su" >&2
        echo "        ogni richiesta, senza che il deploy fallisca. Meglio" >&2
        echo "        fermarsi qui." >&2
        exit 1
    fi

    local invalid=0
    while IFS= read -r image; do
        if ! is_jpeg "$image"; then
            echo "ERRORE: $(basename "$image") non e' un JPEG." >&2
            echo "        Contenuto reale: $(describe_format "$image")" >&2
            invalid=1
        fi
    done <<EOF
$(list_source_images)
EOF

    if [ "$invalid" -ne 0 ]; then
        echo "        Un file non-JPEG esercita il decoder sbagliato e falsa il" >&2
        echo "        confronto tra i tre linguaggi (D3/D34). Convertirlo davvero," >&2
        echo "        non rinominarlo." >&2
        exit 1
    fi
}

sync_worker() {
    local worker="$1"
    local dest="$REPO_ROOT/functions/$worker/images"
    local worker_dir="$REPO_ROOT/functions/$worker"

    if [ ! -d "$worker_dir" ]; then
        echo "· $worker: worker non ancora creato, salto"
        return 0
    fi

    mkdir -p "$dest"

    # Prima si svuota, poi si copia: senza questo, togliere un'immagine dalla
    # sorgente la lascerebbe viva nella destinazione — la stessa divergenza
    # che la sorgente unica doveva impedire, solo al contrario.
    while IFS= read -r stale; do
        [ -n "$stale" ] && rm -f "$stale" 2>/dev/null || true
    done <<EOF
$(find "$dest" -maxdepth 1 -type f ! -name 'README.md' 2>/dev/null | sort)
EOF

    local copied=0
    while IFS= read -r image; do
        cp "$image" "$dest/"
        printf '    %-28s %8d byte\n' "$(basename "$image")" "$(wc -c < "$image" | tr -d ' ')"
        copied=$((copied + 1))
    done <<EOF
$(list_source_images)
EOF

    # Si verifica il risultato invece di fidarsi dei comandi: se la
    # cancellazione fallisce (permessi, filesystem in sola lettura), i comandi
    # possono uscire con successo lasciando comunque un file orfano nella
    # destinazione. E' successo davvero durante lo sviluppo di questo script,
    # ed e' proprio il fallimento silenzioso che qui non deve passare.
    local expected actual
    expected="$(list_source_images | xargs -n1 basename 2>/dev/null | sort)"
    actual="$(find "$dest" -maxdepth 1 -type f ! -name 'README.md' 2>/dev/null | xargs -n1 basename 2>/dev/null | sort)"

    if [ "$expected" != "$actual" ]; then
        echo "ERRORE: functions/$worker/images/ non rispecchia la sorgente." >&2
        echo "        Attese:  $(echo "$expected" | tr '\n' ' ')" >&2
        echo "        Trovate: $(echo "$actual" | tr '\n' ' ')" >&2
        echo "        Un file di troppo nella destinazione viene comunque" >&2
        echo "        deployato e resta selezionabile via ?image=." >&2
        exit 1
    fi

    echo "· $worker: $copied immagini in functions/$worker/images/"
}

[ $# -eq 1 ] || usage

case "$1" in
    python|dotnet|go) TARGETS="$1" ;;
    all)              TARGETS="$ALL_WORKERS" ;;
    *)                usage ;;
esac

validate_source

echo "Sorgente: functions/images/"
for worker in $TARGETS; do
    sync_worker "$worker"
done
