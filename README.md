# Create Layer — Plugin QField

Plugin per **QField** (≥ 3.2) che permette di **creare nuovi layer direttamente
sul campo**, digitalizzare geometrie ed **esportare/condividere** i dati
raccolti, senza dover tornare in QGIS desktop.

## Funzionalità

- **Creazione progetto sul campo**: dal pulsante **Nuovo progetto…** il
  plugin genera un progetto **`.qgs`** pronto all'uso (sfondo OpenStreetMap,
  CRS EPSG:4326, centrato sulla posizione GPS se attiva) nella cartella dati
  di QField (`createlayer_projects/`) e lo apre subito. Funziona anche senza
  alcun progetto aperto. I layer creati al suo interno compaiono in legenda.
- **Creazione layer sul campo**: nome, tipo di geometria (punto, linea,
  poligono) e campi attributo personalizzati (`string`, `number`, `date`).
  I layer sono salvati come **GeoJSON (EPSG:4326)** nella sottocartella
  `qfield_layers/` del progetto corrente.
- **Layer nella legenda (TOC)**: se il progetto aperto è un file **`.qgs`**,
  il nuovo layer viene registrato automaticamente nel progetto (con **backup
  automatico** in `<progetto>.qgs.createlayer.bak`) e il progetto viene
  ricaricato: il layer compare subito nella legenda di QField e si
  digitalizza con gli **strumenti nativi di QField** (form attributi, GPS,
  snapping, ecc.).
- **Digitalizzazione integrata** (per i progetti `.qgz`, non modificabili
  dal plugin):
  - punti/vertici acquisiti dalla **posizione GPS** o dal **centro mappa**
    (mirino a schermo);
  - per linee e poligoni: aggiunta progressiva dei vertici, annullamento
    dell'ultimo vertice, chiusura della geometria;
  - compilazione degli attributi a ogni geometria salvata.
- **Esportazione**:
  - **Esporta**: salva il singolo GeoJSON in una posizione scelta dall'utente
    (dialogo di sistema, Android/iOS);
  - **Condividi**: invia il GeoJSON tramite le app di condivisione del
    dispositivo (email, Telegram, Drive, ecc.);
  - **CSV**: genera ed esporta una tabella CSV con geometria WKT e attributi;
  - **Esporta tutti**: comprime l'intera cartella `qfield_layers/` e la
    condivide come archivio.

## Installazione

### Da URL (consigliato)

In QField: **Impostazioni → Plugin → Installa plugin da URL** e incolla:

```
https://github.com/enzococca/createlayer/raw/main/createlayer.zip
```

### Da ZIP

1. Scarica [`createlayer.zip`](https://github.com/enzococca/createlayer/raw/main/createlayer.zip)
   (oppure generalo con `python package.py`).
2. Copia lo ZIP sul dispositivo, quindi in QField:
   **Impostazioni → Plugin → Installa plugin da ZIP**.
3. Abilita il plugin nell'elenco. Comparirà un pulsante rotondo nella toolbar
   dei plugin (in basso a destra della mappa).

## Utilizzo

1. Tocca il pulsante del plugin nella toolbar. Puoi partire da un progetto
   già aperto oppure crearne uno nuovo con **Nuovo progetto…** (viene
   generato un `.qgs` con sfondo OpenStreetMap e aperto subito).
2. **Nuovo layer**: inserisci nome, tipo di geometria e (opzionale) i campi
   nel formato `nome:string, altezza:number, data:date`, poi premi
   **Crea layer**.
3. **Progetti `.qgs`**: il layer viene aggiunto alla legenda e il progetto
   ricaricato. Selezionalo nella legenda e digitalizza con gli strumenti
   normali di QField (pulsante **+**). Se il layer ha dei campi, contiene
   una **riga di esempio senza geometria** che ne definisce i tipi: puoi
   eliminarla in QGIS quando vuoi.
4. **Progetti `.qgz`** (legenda non modificabile): seleziona il layer e
   premi **Digitalizza**. Usa **+ GPS** (posizione corrente) o **+ Centro**
   (mirino al centro mappa) per aggiungere punti o vertici; per
   linee/poligoni premi **Concludi** per chiudere la geometria. A ogni
   geometria viene richiesta la compilazione degli attributi.
5. **Esporta/Condividi/CSV**: dai pulsanti accanto a ciascun layer, oppure
   **Esporta tutti** per l'archivio compresso dell'intera cartella.

## Dove finiscono i dati

```
<cartella progetto>/
└── qfield_layers/
    ├── index.json               # indice dei layer creati dal plugin
    ├── alberi_abbattuti.geojson
    ├── alberi_abbattuti.csv     # generato al momento dell'export CSV
    └── ...
```

I GeoJSON sono in EPSG:4326 e si aprono direttamente in QGIS desktop
(trascinandoli nel progetto).

## Limitazioni note

- L'aggiunta automatica alla legenda funziona solo con progetti **`.qgs`**
  (XML non compresso): i `.qgz` non sono modificabili dall'API QML di
  QField, quindi per quei progetti si usa la digitalizzazione integrata del
  plugin. Suggerimento: in QGIS desktop salva il progetto come `.qgs`.
- Il plugin modifica il file `.qgs` sul dispositivo; prima di ogni modifica
  viene creato un backup `<progetto>.qgs.createlayer.bak`. Con progetti
  **QFieldCloud** la modifica locale del progetto può essere sovrascritta o
  creare conflitti alla sincronizzazione: usala consapevolmente.
- La digitalizzazione integrata produce geometrie semplici
  (Point/LineString/Polygon, senza anelli interni né multi-parti); con gli
  strumenti nativi di QField non ci sono queste limitazioni.
- Serve un progetto aperto: i file vengono salvati nella cartella del
  progetto corrente.

## Struttura del repository

```
createlayer/
├── main.qml          # logica e interfaccia del plugin
├── metadata.txt      # metadati (nome, versione, autore)
├── icon.svg          # icona della toolbar
├── package.py        # genera createlayer.zip
├── createlayer.zip   # pacchetto installabile
└── README.md
```

## Riferimenti

- Documentazione plugin QField: <https://docs.qfield.org/reference/plugins/>
- API e snippet: <https://api.qfield.org/>

## Licenza

Vedi [LICENSE](LICENSE).
