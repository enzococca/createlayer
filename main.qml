import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.qfield
import org.qgis
import Theme

/*
 * QField Layer Tools
 * ------------------
 * Plugin QField per creare nuovi layer GeoJSON direttamente sul campo,
 * digitalizzare geometrie (punti, linee, poligoni) tramite GPS o centro
 * mappa, ed esportare/condividere i dati raccolti.
 *
 * I layer creati vengono salvati come file GeoJSON (EPSG:4326) nella
 * sottocartella "qfield_layers" del progetto corrente, con un file
 * "index.json" che tiene traccia dei layer e dei relativi campi.
 */
Item {
  id: plugin

  property var mainWindow: iface.mainWindow()
  property var mapCanvas: iface.mapCanvas()
  property var positionSource: iface.findItemByObjectName('positionSource')

  // Nome della sottocartella del progetto dove vengono salvati i layer
  readonly property string layersDirName: 'qfield_layers'

  // Indice dei layer creati dal plugin: [{name, file, geometry, fields, created, featureCount}]
  property var layerIndex: []

  // Stato della sessione di digitalizzazione
  property int activeLayerIdx: -1
  property var activeCollection: null
  property var pendingVertices: []
  property var pendingGeometry: null

  Component.onCompleted: {
    iface.addItemToPluginsToolbar(pluginButton)
  }

  // ---------------------------------------------------------------------
  // Percorsi
  // ---------------------------------------------------------------------

  function homePath() {
    return (typeof qgisProject !== 'undefined' && qgisProject && qgisProject.homePath)
        ? qgisProject.homePath : ''
  }

  function layersDir() {
    return homePath() + '/' + layersDirName
  }

  function indexPath() {
    return layersDir() + '/index.json'
  }

  function layerPath(lyr) {
    return layersDir() + '/' + lyr.file
  }

  function toast(message) {
    mainWindow.displayToast(message)
  }

  // ---------------------------------------------------------------------
  // Utilità file (FileUtils restituisce QByteArray: decodifica robusta)
  // ---------------------------------------------------------------------

  function toStr(content) {
    if (content === null || content === undefined)
      return ''
    if (typeof content === 'string')
      return content
    try {
      const view = new Uint8Array(content)
      let s = ''
      for (let i = 0; i < view.length; i++)
        s += String.fromCharCode(view[i])
      try {
        // Riconversione UTF-8 dei caratteri multibyte
        return decodeURIComponent(escape(s))
      } catch (e) {
        return s
      }
    } catch (e) {
      return '' + content
    }
  }

  function readJsonFile(path, fallback) {
    if (!FileUtils.fileExists(path))
      return fallback
    try {
      return JSON.parse(toStr(FileUtils.readFileContent(path)))
    } catch (e) {
      return fallback
    }
  }

  // ---------------------------------------------------------------------
  // Gestione indice layer
  // ---------------------------------------------------------------------

  function loadIndex() {
    if (homePath() === '') {
      layerIndex = []
      return false
    }
    platformUtilities.createDir(homePath(), layersDirName)
    layerIndex = readJsonFile(indexPath(), [])
    return true
  }

  function saveIndex() {
    FileUtils.writeFileContent(indexPath(), JSON.stringify(layerIndex, null, 2))
    // Riassegnazione per forzare l'aggiornamento delle viste QML
    layerIndex = layerIndex.slice()
  }

  // ---------------------------------------------------------------------
  // Creazione layer
  // ---------------------------------------------------------------------

  function slugify(name) {
    let s = name.toLowerCase().replace(/[^a-z0-9_\-]+/g, '_').replace(/^_+|_+$/g, '')
    return s === '' ? 'layer' : s
  }

  function parseFields(spec) {
    // Formato: "nome:string, altezza:number, rilievo:date"
    const fields = []
    const parts = spec.split(',')
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i].trim()
      if (p === '')
        continue
      const bits = p.split(':')
      const fname = bits[0].trim()
      if (fname === '')
        continue
      let ftype = bits.length > 1 ? bits[1].trim().toLowerCase() : 'string'
      if (ftype !== 'string' && ftype !== 'number' && ftype !== 'date')
        ftype = 'string'
      fields.push({ name: fname, type: ftype })
    }
    return fields
  }

  function createLayer(name, geomType, fieldsSpec) {
    if (!loadIndex()) {
      toast(qsTr('Nessun progetto caricato: apri un progetto prima di creare layer'))
      return false
    }
    if (name.trim() === '') {
      toast(qsTr('Inserisci un nome per il layer'))
      return false
    }

    let slug = slugify(name)
    let file = slug + '.geojson'
    let counter = 2
    while (FileUtils.fileExists(layersDir() + '/' + file)) {
      file = slug + '_' + counter + '.geojson'
      counter++
    }

    const collection = {
      'type': 'FeatureCollection',
      'name': name.trim(),
      'crs': { 'type': 'name', 'properties': { 'name': 'urn:ogc:def:crs:OGC:1.3:CRS84' } },
      'features': []
    }
    FileUtils.writeFileContent(layersDir() + '/' + file, JSON.stringify(collection))

    layerIndex.push({
      'name': name.trim(),
      'file': file,
      'geometry': geomType,
      'fields': parseFields(fieldsSpec),
      'created': new Date().toISOString(),
      'featureCount': 0
    })
    saveIndex()
    toast(qsTr('Layer "%1" creato').arg(name.trim()))
    return true
  }

  function deleteLayer(idx) {
    const lyr = layerIndex[idx]
    if (activeLayerIdx === idx)
      stopDigitizing()
    platformUtilities.rmFile(layerPath(lyr))
    layerIndex.splice(idx, 1)
    saveIndex()
    toast(qsTr('Layer "%1" eliminato').arg(lyr.name))
  }

  // ---------------------------------------------------------------------
  // Digitalizzazione
  // ---------------------------------------------------------------------

  function geometryLabel(geomType) {
    if (geomType === 'Point') return qsTr('Punto')
    if (geomType === 'LineString') return qsTr('Linea')
    return qsTr('Poligono')
  }

  function startDigitizing(idx) {
    const lyr = layerIndex[idx]
    activeCollection = readJsonFile(layerPath(lyr), null)
    if (!activeCollection) {
      toast(qsTr('Impossibile leggere il file del layer'))
      return
    }
    activeLayerIdx = idx
    pendingVertices = []
    layerDialog.close()
    toast(qsTr('Digitalizzazione su "%1": aggiungi vertici con GPS o centro mappa').arg(lyr.name))
  }

  function stopDigitizing() {
    activeLayerIdx = -1
    activeCollection = null
    pendingVertices = []
    pendingGeometry = null
  }

  function addVertexFromGps() {
    if (!positionSource || !positionSource.active
        || !positionSource.positionInformation
        || !positionSource.positionInformation.latitudeValid) {
      toast(qsTr('Posizione GPS non disponibile: attiva il posizionamento'))
      return
    }
    const wgs = GeometryUtils.reprojectPointToWgs84(
      positionSource.projectedPosition,
      positionSource.coordinateTransformer.destinationCrs)
    pushVertex(wgs.x, wgs.y)
  }

  function addVertexFromCenter() {
    const center = mapCanvas.mapSettings.screenToCoordinate(
      Qt.point(mapCanvas.width / 2, mapCanvas.height / 2))
    const wgs = GeometryUtils.reprojectPointToWgs84(center, mapCanvas.mapSettings.destinationCrs)
    pushVertex(wgs.x, wgs.y)
  }

  function pushVertex(lon, lat) {
    if (activeLayerIdx < 0)
      return
    const lyr = layerIndex[activeLayerIdx]
    const vertex = [Math.round(lon * 1e7) / 1e7, Math.round(lat * 1e7) / 1e7]
    if (lyr.geometry === 'Point') {
      pendingGeometry = { 'type': 'Point', 'coordinates': vertex }
      openAttributeDialog()
    } else {
      const verts = pendingVertices.slice()
      verts.push(vertex)
      pendingVertices = verts
      toast(qsTr('Vertice %1 aggiunto').arg(pendingVertices.length))
    }
  }

  function undoVertex() {
    if (pendingVertices.length === 0)
      return
    const verts = pendingVertices.slice()
    verts.pop()
    pendingVertices = verts
    toast(qsTr('Ultimo vertice rimosso (%1 rimasti)').arg(pendingVertices.length))
  }

  function finishFeature() {
    if (activeLayerIdx < 0)
      return
    const lyr = layerIndex[activeLayerIdx]
    if (lyr.geometry === 'LineString') {
      if (pendingVertices.length < 2) {
        toast(qsTr('Servono almeno 2 vertici per una linea'))
        return
      }
      pendingGeometry = { 'type': 'LineString', 'coordinates': pendingVertices.slice() }
    } else if (lyr.geometry === 'Polygon') {
      if (pendingVertices.length < 3) {
        toast(qsTr('Servono almeno 3 vertici per un poligono'))
        return
      }
      const ring = pendingVertices.slice()
      ring.push(ring[0])
      pendingGeometry = { 'type': 'Polygon', 'coordinates': [ring] }
    }
    openAttributeDialog()
  }

  function openAttributeDialog() {
    attributeDialog.fieldValues = {}
    attributeDialog.open()
  }

  function commitFeature(properties) {
    if (activeLayerIdx < 0 || !pendingGeometry || !activeCollection)
      return
    const lyr = layerIndex[activeLayerIdx]
    activeCollection.features.push({
      'type': 'Feature',
      'properties': properties,
      'geometry': pendingGeometry
    })
    FileUtils.writeFileContent(layerPath(lyr), JSON.stringify(activeCollection))
    lyr.featureCount = activeCollection.features.length
    saveIndex()
    pendingGeometry = null
    pendingVertices = []
    toast(qsTr('Geometria salvata in "%1" (%2 totali)').arg(lyr.name).arg(lyr.featureCount))
  }

  // ---------------------------------------------------------------------
  // Esportazione
  // ---------------------------------------------------------------------

  function exportLayer(idx) {
    platformUtilities.exportDatasetTo(layerPath(layerIndex[idx]))
  }

  function shareLayer(idx) {
    platformUtilities.sendDatasetTo(layerPath(layerIndex[idx]))
  }

  function exportAll() {
    if (layerIndex.length === 0) {
      toast(qsTr('Nessun layer da esportare'))
      return
    }
    platformUtilities.sendCompressedFolderTo(layersDir())
  }

  function geomToWkt(geom) {
    if (geom.type === 'Point') {
      return 'POINT (' + geom.coordinates[0] + ' ' + geom.coordinates[1] + ')'
    }
    if (geom.type === 'LineString') {
      return 'LINESTRING (' + geom.coordinates.map(c => c[0] + ' ' + c[1]).join(', ') + ')'
    }
    if (geom.type === 'Polygon') {
      return 'POLYGON ((' + geom.coordinates[0].map(c => c[0] + ' ' + c[1]).join(', ') + '))'
    }
    return ''
  }

  function csvEscape(value) {
    if (value === null || value === undefined)
      return ''
    const s = '' + value
    if (s.indexOf('"') >= 0 || s.indexOf(',') >= 0 || s.indexOf('\n') >= 0)
      return '"' + s.replace(/"/g, '""') + '"'
    return s
  }

  function exportLayerCsv(idx) {
    const lyr = layerIndex[idx]
    const collection = readJsonFile(layerPath(lyr), null)
    if (!collection) {
      toast(qsTr('Impossibile leggere il file del layer'))
      return
    }
    const fieldNames = lyr.fields.map(f => f.name)
    let csv = 'fid,wkt_geometry'
    for (let i = 0; i < fieldNames.length; i++)
      csv += ',' + csvEscape(fieldNames[i])
    csv += '\n'
    for (let i = 0; i < collection.features.length; i++) {
      const feat = collection.features[i]
      csv += (i + 1) + ',' + csvEscape(geomToWkt(feat.geometry))
      for (let j = 0; j < fieldNames.length; j++) {
        const v = feat.properties ? feat.properties[fieldNames[j]] : null
        csv += ',' + csvEscape(v)
      }
      csv += '\n'
    }
    const csvPath = layersDir() + '/' + lyr.file.replace(/\.geojson$/, '.csv')
    FileUtils.writeFileContent(csvPath, csv)
    platformUtilities.exportDatasetTo(csvPath)
  }

  // ---------------------------------------------------------------------
  // Pulsante nella toolbar dei plugin
  // ---------------------------------------------------------------------

  QfToolButton {
    id: pluginButton
    bgcolor: Theme.darkGray
    iconSource: Qt.resolvedUrl('icon.svg')
    iconColor: Theme.mainColor
    round: true

    onClicked: {
      if (!plugin.loadIndex()) {
        plugin.toast(qsTr('Nessun progetto caricato: apri un progetto prima di usare il plugin'))
        return
      }
      layerDialog.open()
    }
  }

  // ---------------------------------------------------------------------
  // Dialogo principale: creazione ed elenco layer
  // ---------------------------------------------------------------------

  Dialog {
    id: layerDialog
    parent: mainWindow.contentItem
    modal: true
    title: qsTr('Layer Tools')
    width: Math.min(mainWindow.width - 40, 500)
    height: Math.min(mainWindow.height - 80, 640)
    x: (mainWindow.width - width) / 2
    y: (mainWindow.height - height) / 2
    standardButtons: Dialog.Close

    contentItem: Flickable {
      clip: true
      contentHeight: dialogContent.height
      ScrollBar.vertical: ScrollBar {}

      ColumnLayout {
        id: dialogContent
        width: parent.width
        spacing: 8

        Label {
          text: qsTr('Nuovo layer')
          font.bold: true
          font.pointSize: Theme.defaultFont.pointSize + 2
        }

        TextField {
          id: nameField
          Layout.fillWidth: true
          placeholderText: qsTr('Nome del layer (es. Alberi abbattuti)')
        }

        ComboBox {
          id: geometryCombo
          Layout.fillWidth: true
          model: [qsTr('Punto'), qsTr('Linea'), qsTr('Poligono')]
          property var geometryTypes: ['Point', 'LineString', 'Polygon']
        }

        TextField {
          id: fieldsField
          Layout.fillWidth: true
          placeholderText: qsTr('Campi: nome:string, altezza:number, data:date')
        }

        Label {
          Layout.fillWidth: true
          text: qsTr('Tipi supportati: string, number, date. Lasciare vuoto per un layer senza attributi.')
          wrapMode: Text.WordWrap
          font.pointSize: Theme.tinyFont.pointSize
          color: Theme.secondaryTextColor
        }

        Button {
          Layout.fillWidth: true
          text: qsTr('Crea layer')
          onClicked: {
            if (plugin.createLayer(nameField.text,
                                   geometryCombo.geometryTypes[geometryCombo.currentIndex],
                                   fieldsField.text)) {
              nameField.text = ''
              fieldsField.text = ''
            }
          }
        }

        Rectangle {
          Layout.fillWidth: true
          height: 1
          color: Theme.secondaryTextColor
          opacity: 0.4
        }

        RowLayout {
          Layout.fillWidth: true

          Label {
            Layout.fillWidth: true
            text: qsTr('Layer creati (%1)').arg(plugin.layerIndex.length)
            font.bold: true
            font.pointSize: Theme.defaultFont.pointSize + 2
          }

          Button {
            text: qsTr('Esporta tutti')
            enabled: plugin.layerIndex.length > 0
            onClicked: plugin.exportAll()
          }
        }

        Label {
          visible: plugin.layerIndex.length === 0
          Layout.fillWidth: true
          text: qsTr('Nessun layer creato finora. I layer vengono salvati come GeoJSON nella cartella "%1" del progetto.').arg(plugin.layersDirName)
          wrapMode: Text.WordWrap
          color: Theme.secondaryTextColor
        }

        Repeater {
          model: plugin.layerIndex

          delegate: Rectangle {
            required property var modelData
            required property int index

            Layout.fillWidth: true
            implicitHeight: layerRow.height + 16
            color: Theme.controlBackgroundAlternateColor
            radius: 6

            ColumnLayout {
              id: layerRow
              width: parent.width - 16
              anchors.centerIn: parent
              spacing: 4

              Label {
                Layout.fillWidth: true
                text: modelData.name
                font.bold: true
                elide: Text.ElideRight
              }

              Label {
                Layout.fillWidth: true
                text: plugin.geometryLabel(modelData.geometry)
                      + ' · ' + qsTr('%1 geometrie').arg(modelData.featureCount)
                      + ' · ' + modelData.file
                font.pointSize: Theme.tinyFont.pointSize
                color: Theme.secondaryTextColor
                elide: Text.ElideRight
              }

              Flow {
                Layout.fillWidth: true
                spacing: 6

                Button {
                  text: qsTr('Digitalizza')
                  onClicked: plugin.startDigitizing(index)
                }
                Button {
                  text: qsTr('Esporta')
                  onClicked: plugin.exportLayer(index)
                }
                Button {
                  text: qsTr('Condividi')
                  onClicked: plugin.shareLayer(index)
                }
                Button {
                  text: qsTr('CSV')
                  onClicked: plugin.exportLayerCsv(index)
                }
                Button {
                  text: qsTr('Elimina')
                  onClicked: {
                    deleteDialog.layerIdx = index
                    deleteDialog.open()
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------------
  // Conferma eliminazione
  // ---------------------------------------------------------------------

  Dialog {
    id: deleteDialog
    parent: mainWindow.contentItem
    modal: true
    title: qsTr('Eliminare il layer?')
    x: (mainWindow.width - width) / 2
    y: (mainWindow.height - height) / 2
    standardButtons: Dialog.Yes | Dialog.No

    property int layerIdx: -1

    Label {
      text: deleteDialog.layerIdx >= 0 && deleteDialog.layerIdx < plugin.layerIndex.length
            ? qsTr('Il layer "%1" e il relativo file GeoJSON verranno eliminati definitivamente.').arg(plugin.layerIndex[deleteDialog.layerIdx].name)
            : ''
      wrapMode: Text.WordWrap
      width: Math.min(mainWindow.width - 80, 400)
    }

    onAccepted: {
      if (layerIdx >= 0)
        plugin.deleteLayer(layerIdx)
      layerIdx = -1
    }
  }

  // ---------------------------------------------------------------------
  // Dialogo attributi (mostrato al salvataggio di ogni geometria)
  // ---------------------------------------------------------------------

  Dialog {
    id: attributeDialog
    parent: mainWindow.contentItem
    modal: true
    title: qsTr('Attributi')
    width: Math.min(mainWindow.width - 40, 420)
    x: (mainWindow.width - width) / 2
    y: (mainWindow.height - height) / 2
    standardButtons: Dialog.Save | Dialog.Cancel

    property var fieldValues: ({})

    property var activeFields: plugin.activeLayerIdx >= 0
                               ? plugin.layerIndex[plugin.activeLayerIdx].fields
                               : []

    contentItem: ColumnLayout {
      spacing: 6

      Label {
        visible: attributeDialog.activeFields.length === 0
        text: qsTr('Questo layer non ha campi: la geometria verrà salvata senza attributi.')
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
      }

      Repeater {
        id: fieldRepeater
        model: attributeDialog.activeFields

        delegate: ColumnLayout {
          required property var modelData

          Layout.fillWidth: true
          spacing: 2

          property alias fieldValue: valueField.text
          property string fieldName: modelData.name
          property string fieldType: modelData.type

          Label {
            text: modelData.name + ' (' + modelData.type + ')'
            font.pointSize: Theme.tinyFont.pointSize
            color: Theme.secondaryTextColor
          }

          TextField {
            id: valueField
            Layout.fillWidth: true
            inputMethodHints: modelData.type === 'number'
                              ? Qt.ImhFormattedNumbersOnly : Qt.ImhNone
            placeholderText: modelData.type === 'date' ? 'YYYY-MM-DD' : ''
          }
        }
      }
    }

    onAboutToShow: {
      // Ripulisce i valori inseriti in precedenza
      for (let i = 0; i < fieldRepeater.count; i++) {
        const item = fieldRepeater.itemAt(i)
        if (item)
          item.fieldValue = ''
      }
    }

    onAccepted: {
      const properties = {}
      for (let i = 0; i < fieldRepeater.count; i++) {
        const item = fieldRepeater.itemAt(i)
        if (!item)
          continue
        let value = item.fieldValue.trim()
        if (value === '') {
          properties[item.fieldName] = null
        } else if (item.fieldType === 'number') {
          const num = parseFloat(value.replace(',', '.'))
          properties[item.fieldName] = isNaN(num) ? null : num
        } else {
          properties[item.fieldName] = value
        }
      }
      plugin.commitFeature(properties)
    }

    onRejected: {
      plugin.pendingGeometry = null
    }
  }

  // ---------------------------------------------------------------------
  // Mirino al centro della mappa durante la digitalizzazione
  // ---------------------------------------------------------------------

  Item {
    id: crosshair
    parent: plugin.mapCanvas
    anchors.centerIn: parent
    visible: plugin.activeLayerIdx >= 0
    width: 40
    height: 40

    Rectangle {
      anchors.centerIn: parent
      width: 2
      height: parent.height
      color: Theme.mainColor
    }
    Rectangle {
      anchors.centerIn: parent
      width: parent.width
      height: 2
      color: Theme.mainColor
    }
    Rectangle {
      anchors.centerIn: parent
      width: 10
      height: 10
      radius: 5
      color: 'transparent'
      border.color: Theme.mainColor
      border.width: 2
    }
  }

  // ---------------------------------------------------------------------
  // Pannello flottante di digitalizzazione
  // ---------------------------------------------------------------------

  Rectangle {
    id: digitizePanel
    parent: plugin.mainWindow.contentItem
    visible: plugin.activeLayerIdx >= 0
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 110
    width: panelColumn.width + 24
    height: panelColumn.height + 20
    radius: 10
    color: Theme.darkGraySemiOpaque

    ColumnLayout {
      id: panelColumn
      anchors.centerIn: parent
      spacing: 6

      Label {
        Layout.alignment: Qt.AlignHCenter
        text: plugin.activeLayerIdx >= 0
              ? plugin.layerIndex[plugin.activeLayerIdx].name
                + (plugin.layerIndex[plugin.activeLayerIdx].geometry !== 'Point'
                   ? ' · ' + qsTr('%1 vertici').arg(plugin.pendingVertices.length)
                   : '')
              : ''
        color: 'white'
        font.bold: true
      }

      RowLayout {
        spacing: 8

        Button {
          text: qsTr('+ GPS')
          onClicked: plugin.addVertexFromGps()
        }
        Button {
          text: qsTr('+ Centro')
          onClicked: plugin.addVertexFromCenter()
        }
        Button {
          visible: plugin.activeLayerIdx >= 0
                   && plugin.layerIndex[plugin.activeLayerIdx].geometry !== 'Point'
          enabled: plugin.pendingVertices.length > 0
          text: qsTr('Annulla vertice')
          onClicked: plugin.undoVertex()
        }
        Button {
          visible: plugin.activeLayerIdx >= 0
                   && plugin.layerIndex[plugin.activeLayerIdx].geometry !== 'Point'
          text: qsTr('Concludi')
          onClicked: plugin.finishFeature()
        }
        Button {
          text: qsTr('Chiudi')
          onClicked: plugin.stopDigitizing()
        }
      }
    }
  }
}
