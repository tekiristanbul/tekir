/*
  tekir prototype — leaflet map, markers, clusters and the static fallback.
  split out of app.js so the screen/render logic stays readable.
  references `state`, `selectCat` and helpers defined in app.js — those are
  resolved at call time, well after every script has loaded.
*/
'use strict';

/* ============================================================ main map */
var leafletMap = null, leafletMarkers = {}, leafletCluster = null, leafletFailed = false;

/* marker diameter tracks zoom so photos stay readable without crowding */
function markerSizeForZoom(zoom){
  if(zoom >= 18) return 56;
  if(zoom >= 17) return 48;
  return 40;
}

function markerHTML(cat, selected, size){
  var alert = activeAlert(cat);
  var fresh = FRESHNESS_META[freshnessOf(cat)].markerCls;
  var px = size || 40;
  var sizeStyle = ' style="width:'+px+'px;height:'+px+'px;"';
  return '<div class="marker '+fresh+(selected?' is-selected':'')+(alert?' needs-help':'')+'"'+sizeStyle+
    ' data-action="select-marker" data-cat="'+cat.id+'" tabindex="0" aria-label="'+esc(catDisplayName(cat))+'">'+
    '<img src="'+cat.photos[0]+'" alt="" onerror="onImgErr(this)">'+
    (alert ? '<span class="marker-badge">'+icon('alertTriangle',{size:9})+'</span>' : '')+
    '</div>';
}

function clusterCats(){ return CATS.filter(function(c){ return c.inCluster; }); }

function initLeaflet(){
  var el = document.getElementById('leafletMap');
  if(!el || leafletMap) return;
  if(typeof L === 'undefined'){ leafletFailed = true; activateMapFallback(); return; }
  try{
    leafletMap = L.map('leafletMap', {
      zoomControl:false, attributionControl:false, zoomSnap:1,
      minZoom:MAP_MIN_ZOOM, maxBounds:ISTANBUL_BOUNDS, maxBoundsViscosity:0.8
    }).setView([USER_APPROX_LOCATION.lat, USER_APPROX_LOCATION.lng], 15.7);
    var tiles = L.tileLayer(BASEMAP_TILE_URL, { maxZoom:19, attribution:BASEMAP_ATTRIBUTION });
    tiles.on('tileerror', function(){ if(!leafletFailed){ leafletFailed = true; activateMapFallback(); } });
    tiles.addTo(leafletMap);
    leafletMap.on('click', function(){ closeSheet(); });
    leafletMap.on('zoomend', function(){ updateMapMarkersDom(); });
    CATS.forEach(addLeafletMarker);
    addLeafletCluster();
    updateMapMarkersDom();
  }catch(e){
    leafletFailed = true;
    activateMapFallback();
  }
}

function addLeafletMarker(cat){
  if(!leafletMap) return;
  var divIcon = L.divIcon({ className:'', html:markerHTML(cat, cat.id===state.selectedCatId), iconSize:[40,40], iconAnchor:[20,20] });
  var m = L.marker([cat.mapPos.lat, cat.mapPos.lng], { icon:divIcon, keyboard:false });
  m.on('click', function(e){ if(e.originalEvent) e.originalEvent.stopPropagation(); selectCat(cat.id); });
  leafletMarkers[cat.id] = m;
}

function addLeafletCluster(){
  var count = clusterCats().length;
  var html = '<div class="marker-cluster" role="button" tabindex="0" aria-label="bölgedeki diğer kediler, yakınlaştırmak için dokun">'+icon('pin',{size:14})+'<span>+'+count+'</span></div>';
  var divIcon = L.divIcon({ className:'', html:html, iconSize:[46,42], iconAnchor:[23,21] });
  leafletCluster = L.marker([CLUSTER_LATLNG.lat, CLUSTER_LATLNG.lng], { icon:divIcon, keyboard:false }).addTo(leafletMap);
  // the cluster actually zooms in — updateMapMarkersDom() runs on the resulting
  // 'zoomend' event and swaps the cluster for the real cats it represents
  leafletCluster.on('click', function(e){
    if(e.originalEvent) e.originalEvent.stopPropagation();
    leafletMap.setView([CLUSTER_LATLNG.lat, CLUSTER_LATLNG.lng], CLUSTER_ZOOM_THRESHOLD, { animate:true });
  });
}

/* removes the leaflet instance (if any) and resets every module-level
   reference tied to it, so a fresh #leafletMap dom node can be initialized
   safely afterwards. safe to call when no instance exists (no-op). */
function teardownLeafletMap(){
  if(leafletMap){
    try{ leafletMap.remove(); }catch(e){ /* already gone — nothing to clean up */ }
  }
  leafletMap = null;
  leafletMarkers = {};
  leafletCluster = null;
  leafletFailed = false;
}

/* single entry point for entering fallback mode, used both by the synchronous
   init failure path (leaflet missing / threw) and the async tileerror path.
   always re-renders fallback markers so we never render onto an empty grid. */
function activateMapFallback(){
  var fb = document.getElementById('mapFallback');
  var lm = document.getElementById('leafletMap');
  if(fb){ fb.hidden = false; }
  if(lm){ lm.style.display = 'none'; }
  renderFallbackMarkers();
}

/* dispatches whichever marker renderer matches the current map mode */
function updateMapMarkersDom(){
  if(leafletMap && !leafletFailed){ renderLeafletMarkers(); return; }
  renderFallbackMarkers();
}

function renderLeafletMarkers(){
  var zoom = leafletMap.getZoom();
  var zoomedIntoCluster = zoom >= CLUSTER_ZOOM_THRESHOLD;
  var size = markerSizeForZoom(zoom);
  CATS.forEach(function(cat){
    var m = leafletMarkers[cat.id];
    if(!m) return;
    var sel = cat.id === state.selectedCatId;
    var effSize = sel ? size + 16 : size;
    m.setIcon(L.divIcon({ className:'', html:markerHTML(cat, sel, effSize), iconSize:[effSize,effSize], iconAnchor:[effSize/2,effSize/2] }));
    var passesFilter = !state.mapHelpFilter || !!activeAlert(cat);
    var visible = passesFilter && (!cat.inCluster || zoomedIntoCluster);
    var has = leafletMap.hasLayer(m);
    if(visible && !has) m.addTo(leafletMap);
    if(!visible && has) leafletMap.removeLayer(m);
  });
  if(leafletCluster){
    var showCluster = !zoomedIntoCluster && !state.mapHelpFilter;
    var hasC = leafletMap.hasLayer(leafletCluster);
    if(showCluster && !hasC) leafletCluster.addTo(leafletMap);
    if(!showCluster && hasC) leafletMap.removeLayer(leafletCluster);
  }
}

function renderFallbackMarkers(){
  var wrap = document.getElementById('mapMarkers'); if(!wrap) return;
  var visibleCats = CATS.filter(function(c){ return !state.mapHelpFilter || !!activeAlert(c); });
  var html = visibleCats.map(function(cat){
    var sel = cat.id === state.selectedCatId;
    return '<div style="position:absolute;top:'+cat.fallbackPos.top+';left:'+cat.fallbackPos.left+';transform:translate(-50%,-50%);">'+markerHTML(cat, sel)+'</div>';
  }).join('');
  wrap.innerHTML = html;
}

/* ============================================================ add-cat location picker map */
var locMap = null, locMapFailed = false;

function teardownLocationMap(){
  if(locMap){
    try{ locMap.remove(); }catch(e){ /* already gone — nothing to clean up */ }
  }
  locMap = null;
  locMapFailed = false;
}

function initLocationMap(){
  var el = document.getElementById('locationMap'); if(!el || locMap) return;
  if(typeof L === 'undefined'){ locMapFailed = true; var fb=document.getElementById('locFallback'); if(fb) fb.hidden=false; return; }
  try{
    locMap = L.map('locationMap', { zoomControl:false, attributionControl:false, dragging:true })
      .setView([state.draftCat.lat, state.draftCat.lng], 17);
    L.control.attribution({ prefix:false, position:'bottomright' }).addTo(locMap);
    L.tileLayer(BASEMAP_TILE_URL, { maxZoom:19, attribution:BASEMAP_ATTRIBUTION }).addTo(locMap);
    locMap.on('moveend', function(){ var c = locMap.getCenter(); state.draftCat.lat = c.lat; state.draftCat.lng = c.lng; });
  }catch(e){ locMapFailed = true; var fb2=document.getElementById('locFallback'); if(fb2) fb2.hidden=false; }
}
