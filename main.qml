import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.qfield
import org.qgis
import Theme

/*
 * Create Layer
 * ------------
 * Plugin QField per creare nuovi layer GeoJSON direttamente sul campo ed
 * esportare/condividere i dati raccolti.
 *
 * I layer creati vengono salvati come file GeoJSON (EPSG:4326) nella
 * sottocartella "qfield_layers" del progetto corrente. Se il progetto è un
 * file .qgs, il layer viene registrato anche nel progetto stesso (con
 * backup automatico) e ricaricato con iface.reloadProject(): in questo modo
 * compare nella legenda (TOC) di QField ed è modificabile con gli strumenti
 * di digitalizzazione nativi.
 *
 * Per i progetti .qgz (compressi) — non modificabili dall'API QML — resta
 * disponibile la digitalizzazione integrata del plugin (GPS/centro mappa).
 */
Item {
  id: plugin

  property var mainWindow: iface.mainWindow()
  property var mapCanvas: iface.mapCanvas()
  property var positionSource: iface.findItemByObjectName('positionSource')

  // Nome della sottocartella del progetto dove vengono salvati i layer
  readonly property string layersDirName: 'qfield_layers'

  // Indice dei layer creati dal plugin:
  // [{name, file, geometry, fields, created, featureCount, layerId, inProject}]
  property var layerIndex: []

  // Percorso del progetto al momento dell'apertura del dialogo (le
  // funzioni JS non sono reattive: aggiornato a ogni click sul pulsante)
  property string currentProjectFile: ''

  // Stato della sessione di digitalizzazione (solo layer non nel progetto)
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

  function projectFilePath() {
    return (typeof qgisProject !== 'undefined' && qgisProject && qgisProject.fileName)
        ? qgisProject.fileName : ''
  }

  // Il progetto può essere modificato solo se è un .qgs non compresso
  function canEditProject() {
    const path = projectFilePath().toLowerCase()
    return path.length > 4 && path.indexOf('.qgs', path.length - 4) >= 0
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
      // Decodifica a blocchi: molto più veloce del ciclo per singolo byte
      // sui file di progetto di grandi dimensioni
      const view = new Uint8Array(content)
      const chunkSize = 8192
      const parts = []
      for (let i = 0; i < view.length; i += chunkSize)
        parts.push(String.fromCharCode.apply(null, view.subarray(i, Math.min(i + chunkSize, view.length))))
      const s = parts.join('')
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

  function xmlEscape(s) {
    return ('' + s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&apos;')
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

  // Campi in preparazione per il nuovo layer: [{name, type}]
  property var newFields: []

  function typeLabel(ftype) {
    if (ftype === 'number') return qsTr('Numero')
    if (ftype === 'date') return qsTr('Data')
    return qsTr('Testo')
  }

  function addNewField(name, ftype) {
    const fname = name.trim()
    if (fname === '') {
      toast(qsTr('Inserisci il nome del campo'))
      return false
    }
    for (let i = 0; i < newFields.length; i++) {
      if (newFields[i].name.toLowerCase() === fname.toLowerCase()) {
        toast(qsTr('Esiste già un campo "%1"').arg(fname))
        return false
      }
    }
    const fields = newFields.slice()
    fields.push({ 'name': fname, 'type': ftype })
    newFields = fields
    return true
  }

  function removeNewField(idx) {
    const fields = newFields.slice()
    fields.splice(idx, 1)
    newFields = fields
  }

  // Feature "di esempio" senza geometria: serve a definire i tipi dei campi
  // nel file GeoJSON (un layer vuoto non avrebbe altrimenti attributi).
  function templateFeature(fields) {
    const props = {}
    for (let i = 0; i < fields.length; i++) {
      if (fields[i].type === 'number')
        props[fields[i].name] = 0.1
      else if (fields[i].type === 'date')
        props[fields[i].name] = '2000-01-01'
      else
        props[fields[i].name] = ''
    }
    return { 'type': 'Feature', 'properties': props, 'geometry': null }
  }

  function createLayer(name, geomType, fields) {
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

    const inTocMode = canEditProject()
    // La riga di esempio (senza geometria) serve solo quando il layer viene
    // aperto dal provider OGR di QGIS: definisce i tipi dei campi
    const collection = {
      'type': 'FeatureCollection',
      'name': name.trim(),
      'crs': { 'type': 'name', 'properties': { 'name': 'urn:ogc:def:crs:OGC:1.3:CRS84' } },
      'features': (fields.length > 0 && inTocMode) ? [templateFeature(fields)] : []
    }
    if (!FileUtils.writeFileContent(layersDir() + '/' + file, JSON.stringify(collection))) {
      iface.logMessage('[createlayer] scrittura fallita: ' + layersDir() + '/' + file)
      toast(qsTr('Errore: impossibile scrivere il file del layer (cartella di sola lettura?)'))
      return false
    }

    const lyr = {
      'name': name.trim(),
      'file': file,
      'geometry': geomType,
      'fields': fields,
      'created': new Date().toISOString(),
      'featureCount': 0,
      'layerId': 'createlayer_' + slug + '_' + Date.now(),
      'inProject': false
    }

    // Se possibile, registra il layer nel progetto .qgs così da farlo
    // comparire nella legenda (TOC) di QField
    if (inTocMode) {
      if (addLayerToProject(lyr)) {
        lyr.inProject = true
        layerIndex.push(lyr)
        saveIndex()
        layerDialog.close()
        iface.reloadProject()
        toast(qsTr('Layer "%1" creato e aggiunto al progetto: usa gli strumenti di digitalizzazione di QField').arg(lyr.name))
        return true
      }
      // Niente TOC: la riga di esempio non serve nella modalità integrata
      collection.features = []
      FileUtils.writeFileContent(layersDir() + '/' + file, JSON.stringify(collection))
      toast(qsTr('Impossibile registrare il layer nel progetto: uso la modalità integrata'))
    }

    layerIndex.push(lyr)
    saveIndex()
    toast(qsTr('Layer "%1" creato (non in legenda: progetto non modificabile). Usa "Digitalizza"').arg(lyr.name))
    return true
  }

  function deleteLayer(idx) {
    const lyr = layerIndex[idx]
    if (activeLayerIdx === idx)
      stopDigitizing()
    if (lyr.inProject && canEditProject())
      removeLayerFromProject(lyr)
    platformUtilities.rmFile(layerPath(lyr))
    layerIndex.splice(idx, 1)
    saveIndex()
    if (lyr.inProject) {
      layerDialog.close()
      iface.reloadProject()
    }
    toast(qsTr('Layer "%1" eliminato').arg(lyr.name))
  }

  // ---------------------------------------------------------------------
  // Registrazione del layer nel file di progetto .qgs
  // ---------------------------------------------------------------------

  function layerSource(lyr) {
    // geometrytype forza il tipo di geometria anche su file vuoti
    return './' + layersDirName + '/' + lyr.file + '|geometrytype=' + lyr.geometry
  }

  function geometryAttr(geomType) {
    if (geomType === 'LineString')
      return 'Line'
    return geomType === 'Polygon' ? 'Polygon' : 'Point'
  }

  function addLayerToProject(lyr) {
    const path = projectFilePath()
    let xml = toStr(FileUtils.readFileContent(path))
    if (xml === '') {
      iface.logMessage('[createlayer] lettura progetto fallita o vuota: ' + path)
      return false
    }
    if (xml.indexOf('<layer-tree-group') < 0)
      return false
    if (xml.indexOf('</projectlayers>') < 0 && xml.indexOf('<projectlayers/>') < 0)
      return false

    // Backup del progetto prima di modificarlo
    FileUtils.writeFileContent(path + '.createlayer.bak', xml)

    const source = layerSource(lyr)

    const maplayer = '\n    <maplayer type="vector" geometry="' + geometryAttr(lyr.geometry)
        + '" autoRefreshEnabled="0" readOnly="0" refreshOnNotifyEnabled="0">\n'
        + '      <id>' + lyr.layerId + '</id>\n'
        + '      <datasource>' + xmlEscape(source) + '</datasource>\n'
        + '      <layername>' + xmlEscape(lyr.name) + '</layername>\n'
        + '      <provider encoding="UTF-8">ogr</provider>\n'
        + '    </maplayer>\n  '

    if (xml.indexOf('<projectlayers/>') >= 0) {
      xml = xml.replace('<projectlayers/>', '<projectlayers>' + maplayer + '</projectlayers>')
    } else {
      xml = xml.replace('</projectlayers>', maplayer + '</projectlayers>')
    }

    // Voce nella legenda: subito dopo l'apertura del gruppo radice
    const treeLayer = '\n    <layer-tree-layer id="' + lyr.layerId + '" name="' + xmlEscape(lyr.name)
        + '" source="' + xmlEscape(source)
        + '" providerKey="ogr" checked="Qt::Checked" expanded="1"/>'
    const groupStart = xml.indexOf('<layer-tree-group')
    if (groupStart < 0)
      return false
    let groupEnd = xml.indexOf('>', groupStart)
    if (groupEnd < 0)
      return false
    if (xml.charAt(groupEnd - 1) === '/') {
      // Gruppo radice vuoto e auto-chiuso: va riaperto
      xml = xml.slice(0, groupEnd - 1) + '>' + treeLayer + '\n  </layer-tree-group>' + xml.slice(groupEnd + 1)
    } else {
      xml = xml.slice(0, groupEnd + 1) + treeLayer + xml.slice(groupEnd + 1)
    }

    if (!FileUtils.writeFileContent(path, xml)) {
      iface.logMessage('[createlayer] scrittura progetto fallita: ' + path)
      return false
    }
    return true
  }

  function removeLayerFromProject(lyr) {
    const path = projectFilePath()
    let xml = toStr(FileUtils.readFileContent(path))
    if (xml === '')
      return false

    FileUtils.writeFileContent(path + '.createlayer.bak', xml)

    // Rimuove la voce di legenda (inserita dal plugin, quindi auto-chiusa)
    const treeRe = new RegExp('\\s*<layer-tree-layer id="' + lyr.layerId + '"[^>]*/>')
    xml = xml.replace(treeRe, '')

    // Rimuove il blocco <maplayer> contenente l'id del layer
    const idTag = '<id>' + lyr.layerId + '</id>'
    const idPos = xml.indexOf(idTag)
    if (idPos >= 0) {
      const start = xml.lastIndexOf('<maplayer', idPos)
      const end = xml.indexOf('</maplayer>', idPos)
      if (start >= 0 && end >= 0)
        xml = xml.slice(0, start) + xml.slice(end + '</maplayer>'.length)
    }

    FileUtils.writeFileContent(path, xml)
    return true
  }

  // ---------------------------------------------------------------------
  // Creazione di un nuovo progetto .qgs
  // ---------------------------------------------------------------------

  // Progetto di partenza scaricabile quando nessun progetto è aperto
  // (FileUtils può scrivere solo dentro la cartella del progetto corrente)
  readonly property string starterProjectUrl: 'https://raw.githubusercontent.com/enzococca/createlayer/main/starter_project.qgs'

  function crsBlockWgs84() {
    return '<spatialrefsys nativeFormat="Wkt">\n'
        + '      <proj4>+proj=longlat +datum=WGS84 +no_defs</proj4>\n'
        + '      <srsid>3452</srsid>\n'
        + '      <srid>4326</srid>\n'
        + '      <authid>EPSG:4326</authid>\n'
        + '      <description>WGS 84</description>\n'
        + '      <projectionacronym>longlat</projectionacronym>\n'
        + '      <ellipsoidacronym>EPSG:7030</ellipsoidacronym>\n'
        + '      <geographicflag>true</geographicflag>\n'
        + '    </spatialrefsys>'
  }

  function projectTemplate(name, ext) {
    // Progetto minimale in EPSG:4326 con sfondo OpenStreetMap (XYZ)
    const osmSource = 'crs=EPSG:3857&format&type=xyz&url=https://tile.openstreetmap.org/%7Bz%7D/%7Bx%7D/%7By%7D.png&zmax=19&zmin=0'
    return '<!DOCTYPE qgis PUBLIC \'http://mrcc.com/qgis.dtd\' \'SYSTEM\'>\n'
        + '<qgis projectname="' + xmlEscape(name) + '" version="3.34.0-Prizren">\n'
        + '  <title>' + xmlEscape(name) + '</title>\n'
        + '  <projectCrs>\n'
        + '    ' + crsBlockWgs84() + '\n'
        + '  </projectCrs>\n'
        + '  <layer-tree-group>\n'
        + '    <layer-tree-layer id="osm_basemap" name="OpenStreetMap" source="' + xmlEscape(osmSource)
        + '" providerKey="wms" checked="Qt::Checked" expanded="1"/>\n'
        + '  </layer-tree-group>\n'
        + '  <mapcanvas annotationsVisible="1" name="theMapCanvas">\n'
        + '    <units>degrees</units>\n'
        + '    <extent>\n'
        + '      <xmin>' + ext.xmin + '</xmin>\n'
        + '      <ymin>' + ext.ymin + '</ymin>\n'
        + '      <xmax>' + ext.xmax + '</xmax>\n'
        + '      <ymax>' + ext.ymax + '</ymax>\n'
        + '    </extent>\n'
        + '    <rotation>0</rotation>\n'
        + '    <destinationsrs>\n'
        + '      ' + crsBlockWgs84() + '\n'
        + '    </destinationsrs>\n'
        + '  </mapcanvas>\n'
        + '  <projectlayers>\n'
        + '    <maplayer type="raster" autoRefreshEnabled="0">\n'
        + '      <id>osm_basemap</id>\n'
        + '      <datasource>' + xmlEscape(osmSource) + '</datasource>\n'
        + '      <layername>OpenStreetMap</layername>\n'
        + '      <provider>wms</provider>\n'
        + '    </maplayer>\n'
        + '  </projectlayers>\n'
        + '  <layerorder>\n'
        + '    <layer id="osm_basemap"/>\n'
        + '  </layerorder>\n'
        + '</qgis>\n'
  }

  function createProject(name) {
    if (name.trim() === '') {
      toast(qsTr('Inserisci un nome per il progetto'))
      return false
    }

    // Senza un progetto aperto QField non permette di scrivere file:
    // si scarica un progetto di partenza dal repository del plugin
    if (homePath() === '') {
      projectDialog.close()
      layerDialog.close()
      iface.importUrl(starterProjectUrl, name.trim(), true)
      toast(qsTr('Download del progetto di partenza in corso (serve connessione): verrà aperto automaticamente'))
      return true
    }

    // Con un progetto aperto, il nuovo .qgs viene creato nella sua cartella
    // (unica posizione scrivibile), in createlayer_projects/
    const base = homePath()
    platformUtilities.createDir(base, 'createlayer_projects')
    const projectsDir = base + '/createlayer_projects'

    let slug = slugify(name)
    let dirName = slug
    let counter = 2
    while (FileUtils.fileExists(projectsDir + '/' + dirName + '/' + dirName + '.qgs')) {
      dirName = slug + '_' + counter
      counter++
    }
    platformUtilities.createDir(projectsDir, dirName)

    // Estensione iniziale: GPS se disponibile, altrimenti vista corrente,
    // altrimenti mondo
    let cx = 0
    let cy = 0
    let hasCenter = false
    if (positionSource && positionSource.active
        && positionSource.positionInformation
        && positionSource.positionInformation.latitudeValid) {
      const wgs = GeometryUtils.reprojectPointToWgs84(
        positionSource.projectedPosition,
        positionSource.coordinateTransformer.destinationCrs)
      cx = wgs.x
      cy = wgs.y
      hasCenter = true
    } else if (homePath() !== '' && mapCanvas && mapCanvas.mapSettings) {
      const center = mapCanvas.mapSettings.screenToCoordinate(
        Qt.point(mapCanvas.width / 2, mapCanvas.height / 2))
      const wgs = GeometryUtils.reprojectPointToWgs84(center, mapCanvas.mapSettings.destinationCrs)
      if (isFinite(wgs.x) && isFinite(wgs.y) && (wgs.x !== 0 || wgs.y !== 0)) {
        cx = wgs.x
        cy = wgs.y
        hasCenter = true
      }
    }
    const d = 0.005
    const ext = hasCenter
        ? { 'xmin': cx - d, 'ymin': cy - d, 'xmax': cx + d, 'ymax': cy + d }
        : { 'xmin': -180, 'ymin': -60, 'xmax': 180, 'ymax': 75 }

    const projPath = projectsDir + '/' + dirName + '/' + dirName + '.qgs'
    if (!FileUtils.writeFileContent(projPath, projectTemplate(name.trim(), ext))
        || !FileUtils.fileExists(projPath)) {
      iface.logMessage('[createlayer] scrittura progetto fallita: ' + projPath)
      toast(qsTr('Errore: impossibile scrivere il file di progetto (cartella di sola lettura?)'))
      return false
    }

    projectDialog.close()
    layerDialog.close()
    if (!iface.loadFile(projPath, name.trim())) {
      iface.logMessage('[createlayer] apertura progetto fallita: ' + projPath)
      toast(qsTr('Progetto creato in %1 ma apertura automatica fallita: aprilo dai file locali di QField').arg(projPath))
      return true
    }
    toast(qsTr('Progetto "%1" creato e aperto: ora puoi creare layer che finiscono in legenda').arg(name.trim()))
    return true
  }

  // ---------------------------------------------------------------------
  // Digitalizzazione integrata (solo per layer non registrati nel progetto)
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
    if (!geom)
      return ''
    if (geom.type === 'Point') {
      return 'POINT (' + geom.coordinates[0] + ' ' + geom.coordinates[1] + ')'
    }
    if (geom.type === 'LineString') {
      return 'LINESTRING (' + geom.coordinates.map(c => c[0] + ' ' + c[1]).join(', ') + ')'
    }
    if (geom.type === 'Polygon') {
      return 'POLYGON ((' + geom.coordinates[0].map(c => c[0] + ' ' + c[1]).join(', ') + '))'
    }
    if (geom.type === 'MultiPoint') {
      return 'MULTIPOINT (' + geom.coordinates.map(c => '(' + c[0] + ' ' + c[1] + ')').join(', ') + ')'
    }
    if (geom.type === 'MultiLineString') {
      return 'MULTILINESTRING (' + geom.coordinates.map(
        line => '(' + line.map(c => c[0] + ' ' + c[1]).join(', ') + ')').join(', ') + ')'
    }
    if (geom.type === 'MultiPolygon') {
      return 'MULTIPOLYGON (' + geom.coordinates.map(
        poly => '((' + poly[0].map(c => c[0] + ' ' + c[1]).join(', ') + '))').join(', ') + ')'
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
    // Le feature possono avere campi aggiunti da QField: unione dei nomi
    const fieldNames = lyr.fields.map(f => f.name)
    for (let i = 0; i < collection.features.length; i++) {
      const props = collection.features[i].properties
      if (!props)
        continue
      for (const key in props) {
        if (fieldNames.indexOf(key) < 0)
          fieldNames.push(key)
      }
    }
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
      plugin.currentProjectFile = plugin.projectFilePath()
      plugin.loadIndex()
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
    title: qsTr('Create Layer')
    // implicitWidth/Height espliciti: evitano il binding loop del Dialog
    // Material (implicitWidth calcolata dal contenuto che dipende dalla
    // larghezza del dialogo stesso)
    implicitWidth: Math.min(mainWindow.width - 40, 500)
    implicitHeight: Math.min(mainWindow.height - 80, 640)
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

        RowLayout {
          Layout.fillWidth: true

          Label {
            Layout.fillWidth: true
            text: plugin.currentProjectFile === ''
                  ? qsTr('Nessun progetto aperto')
                  : qsTr('Progetto: %1').arg(FileUtils.fileName(plugin.currentProjectFile))
            elide: Text.ElideMiddle
            font.pointSize: Theme.tinyFont.pointSize
            color: Theme.secondaryTextColor
          }

          Button {
            text: qsTr('Nuovo progetto…')
            onClicked: projectDialog.open()
          }
        }

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

        Label {
          text: qsTr('Campi del layer')
          font.bold: true
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: 6

          TextField {
            id: fieldNameField
            Layout.fillWidth: true
            placeholderText: qsTr('Nome del campo')
          }

          ComboBox {
            id: fieldTypeCombo
            Layout.preferredWidth: 110
            model: [qsTr('Testo'), qsTr('Numero'), qsTr('Data')]
            property var fieldTypes: ['string', 'number', 'date']
          }

          Button {
            text: qsTr('Aggiungi')
            onClicked: {
              if (plugin.addNewField(fieldNameField.text,
                                     fieldTypeCombo.fieldTypes[fieldTypeCombo.currentIndex])) {
                fieldNameField.text = ''
              }
            }
          }
        }

        Label {
          visible: plugin.newFields.length === 0
          Layout.fillWidth: true
          text: qsTr('Nessun campo aggiunto: il layer verrà creato senza attributi.')
          wrapMode: Text.WordWrap
          font.pointSize: Theme.tinyFont.pointSize
          color: Theme.secondaryTextColor
        }

        Repeater {
          model: plugin.newFields

          delegate: RowLayout {
            required property var modelData
            required property int index

            Layout.fillWidth: true
            spacing: 6

            Label {
              Layout.fillWidth: true
              text: '• ' + modelData.name + ' — ' + plugin.typeLabel(modelData.type)
              elide: Text.ElideRight
            }

            Button {
              text: qsTr('Rimuovi')
              onClicked: plugin.removeNewField(index)
            }
          }
        }

        Label {
          visible: plugin.currentProjectFile !== ''
                   && plugin.currentProjectFile.toLowerCase().indexOf('.qgs', plugin.currentProjectFile.length - 4) < 0
          Layout.fillWidth: true
          text: qsTr('Attenzione: il progetto corrente non è un file .qgs, quindi i nuovi layer non potranno essere aggiunti alla legenda. Resta disponibile la digitalizzazione integrata del plugin, oppure crea un nuovo progetto con il pulsante qui sopra.')
          wrapMode: Text.WordWrap
          font.pointSize: Theme.tinyFont.pointSize
          color: Theme.warningColor
        }

        Label {
          visible: plugin.currentProjectFile === ''
          Layout.fillWidth: true
          text: qsTr('Nessun progetto aperto: con "Nuovo progetto…" verrà scaricato e aperto un progetto di partenza (serve connessione), oppure apri prima un progetto esistente.')
          wrapMode: Text.WordWrap
          font.pointSize: Theme.tinyFont.pointSize
          color: Theme.warningColor
        }

        Button {
          Layout.fillWidth: true
          text: qsTr('Crea layer')
          onClicked: {
            if (plugin.createLayer(nameField.text,
                                   geometryCombo.geometryTypes[geometryCombo.currentIndex],
                                   plugin.newFields)) {
              nameField.text = ''
              fieldNameField.text = ''
              plugin.newFields = []
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
                text: modelData.name + (modelData.inProject ? ' · ' + qsTr('in legenda') : '')
                font.bold: true
                elide: Text.ElideRight
              }

              Label {
                Layout.fillWidth: true
                text: plugin.geometryLabel(modelData.geometry)
                      + (modelData.inProject
                         ? ' · ' + qsTr('modifica con gli strumenti QField')
                         : ' · ' + qsTr('%1 geometrie').arg(modelData.featureCount))
                      + ' · ' + modelData.file
                font.pointSize: Theme.tinyFont.pointSize
                color: Theme.secondaryTextColor
                elide: Text.ElideRight
              }

              Flow {
                Layout.fillWidth: true
                spacing: 6

                Button {
                  visible: !modelData.inProject
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
  // Dialogo nuovo progetto
  // ---------------------------------------------------------------------

  Dialog {
    id: projectDialog
    parent: mainWindow.contentItem
    modal: true
    title: qsTr('Nuovo progetto')
    implicitWidth: Math.min(mainWindow.width - 40, 420)
    x: (mainWindow.width - width) / 2
    y: (mainWindow.height - height) / 2
    standardButtons: Dialog.Ok | Dialog.Cancel

    contentItem: ColumnLayout {
      spacing: 6

      TextField {
        id: projectNameField
        Layout.fillWidth: true
        placeholderText: qsTr('Nome del progetto (es. Rilievo luglio)')
      }

      Label {
        Layout.fillWidth: true
        text: plugin.currentProjectFile !== ''
              ? qsTr('Verrà creato un progetto .qgs con sfondo OpenStreetMap nella sottocartella createlayer_projects del progetto corrente, centrato sulla posizione GPS se attiva, e aperto subito. I layer creati al suo interno compariranno in legenda.')
              : qsTr('Nessun progetto aperto: verrà scaricato un progetto di partenza con sfondo OpenStreetMap (serve connessione) e aperto subito. I layer creati al suo interno compariranno in legenda.')
        wrapMode: Text.WordWrap
        font.pointSize: Theme.tinyFont.pointSize
        color: Theme.secondaryTextColor
      }
    }

    onAccepted: {
      if (plugin.createProject(projectNameField.text))
        projectNameField.text = ''
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
    implicitWidth: Math.min(mainWindow.width - 40, 420)
    x: (mainWindow.width - width) / 2
    y: (mainWindow.height - height) / 2
    standardButtons: Dialog.Yes | Dialog.No

    property int layerIdx: -1

    contentItem: Label {
      text: deleteDialog.layerIdx >= 0 && deleteDialog.layerIdx < plugin.layerIndex.length
            ? qsTr('Il layer "%1" verrà rimosso dal progetto e il file GeoJSON eliminato definitivamente.').arg(plugin.layerIndex[deleteDialog.layerIdx].name)
            : ''
      wrapMode: Text.WordWrap
    }

    onAccepted: {
      if (layerIdx >= 0)
        plugin.deleteLayer(layerIdx)
      layerIdx = -1
    }
  }

  // ---------------------------------------------------------------------
  // Dialogo attributi (digitalizzazione integrata)
  // ---------------------------------------------------------------------

  Dialog {
    id: attributeDialog
    parent: mainWindow.contentItem
    modal: true
    title: qsTr('Attributi')
    implicitWidth: Math.min(mainWindow.width - 40, 420)
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
  // Mirino al centro della mappa durante la digitalizzazione integrata
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
  // Pannello flottante di digitalizzazione integrata
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
