/* tekir — hi-fi clickable prototype. no framework, no build step. */
(function(){
'use strict';

/* ============================================================ assets */
/* street cat photos — real photographs, sourced from wikimedia commons (see README.md for credits/licenses). */
var PHOTOS = {
  kabatas:    'https://upload.wikimedia.org/wikipedia/commons/thumb/f/f9/Cat_near_Kabata%C5%9F_in_Istanbul%2C_20260605_1734_1298.jpg/960px-Cat_near_Kabata%C5%9F_in_Istanbul%2C_20260605_1734_1298.jpg',
  kadikoy:    'https://upload.wikimedia.org/wikipedia/commons/thumb/7/70/Cats%2C_Kadikoey%2C_Istanbul_%28P1100168%29.jpg/960px-Cats%2C_Kadikoey%2C_Istanbul_%28P1100168%29.jpg',
  sultanahmet:'https://upload.wikimedia.org/wikipedia/commons/thumb/3/35/Istanbul_-_cat_of_Sultanahmet.jpg/960px-Istanbul_-_cat_of_Sultanahmet.jpg',
  oldistanbul:'https://upload.wikimedia.org/wikipedia/commons/thumb/1/15/Old_Istanbul_Cat.jpg/960px-Old_Istanbul_Cat.jpg',
  fatih:      'https://upload.wikimedia.org/wikipedia/commons/thumb/2/2a/Cat%2C_Istanbul_%28P1180136%29.jpg/960px-Cat%2C_Istanbul_%28P1180136%29.jpg',
  brickwall:  'https://upload.wikimedia.org/wikipedia/commons/thumb/9/94/Turkey_%28Istanbul%29_Street_cat_%2821956691179%29.jpg/960px-Turkey_%28Istanbul%29_Street_cat_%2821956691179%29.jpg'
};
var FALLBACK_IMG = 'data:image/svg+xml;utf8,' + encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">' +
  '<rect width="100" height="100" fill="#EEEAFA"/>' +
  '<path d="M50 60c-12 0-20 8-20 16 0 4 3 7 7 7 5 0 7-3 13-3s8 3 13 3c4 0 7-3 7-7 0-8-8-16-20-16Z" fill="#8C7AD1"/>' +
  '<circle cx="34" cy="38" r="7" fill="#8C7AD1"/><circle cx="50" cy="30" r="7.5" fill="#8C7AD1"/><circle cx="66" cy="38" r="7" fill="#8C7AD1"/>' +
  '<circle cx="24" cy="54" r="6" fill="#8C7AD1"/><circle cx="76" cy="54" r="6" fill="#8C7AD1"/></svg>');
window.onImgErr = function(img){ img.onerror = null; img.src = FALLBACK_IMG; };

/* ============================================================ status vocabulary (provisional — see docs/product/updates.md, issue #4) */
var STATUS_VOCAB = [
  { id:'sighting', label:'Burada görüldü', icon:'pin' },
  { id:'water',    label:'Su verildi',     icon:'droplet' },
  { id:'food',     label:'Mama verildi',   icon:'bowl' },
  { id:'ok',       label:'İyi görünüyor',  icon:'check' },
  { id:'hurt',     label:'Yaralı veya hasta görünüyor', icon:'alertTriangle' }
];

/* ============================================================ seed data — cats around kadıköy / moda */
var CATS = [
  {
    id:'portakal', name:'Portakal',
    photo:PHOTOS.kabatas, photos:[PHOTOS.kabatas, PHOTOS.kabatas],
    mapPos:{lat:40.9797,lng:29.0256}, fallbackPos:{top:'40%',left:'26%'},
    areaLabel:'Moda Sahili, Kadıköy',
    lastSeenShort:'25 dk önce', lastSeenFull:'bugün 14:20', freshness:'fresh',
    condition:'Arka bacağını yere basmıyor, yaklaşınca kaçmadı.',
    water:'Bilinmiyor', food:'Bugün mama verildi',
    needsHelp:{ active:true, sinceText:'25 dk önce' },
    followed:true,
    updates:[
      { type:'hurt', comment:'Arka bacağını topallıyor, yaklaşınca kaçmadı.', photo:PHOTOS.kabatas, timeText:'bugün 14:20' },
      { type:'food', comment:'', photo:null, timeText:'bugün 09:10' },
      { type:'sighting', comment:'Sahil kenarındaki bankın altında uyuyordu.', photo:null, timeText:'dün 21:40' }
    ]
  },
  {
    id:'zeytin', name:'Zeytin',
    photo:PHOTOS.kadikoy, photos:[PHOTOS.kadikoy],
    mapPos:{lat:40.9889,lng:29.0331}, fallbackPos:{top:'22%',left:'62%'},
    areaLabel:'Yeldeğirmeni, Kadıköy',
    lastSeenShort:'dün 18:05', lastSeenFull:'dün 18:05', freshness:'neutral',
    condition:'İyi görünüyor, genelde başka bir kediyle birlikte geziyor.',
    water:'Bilinmiyor', food:'Bilinmiyor',
    needsHelp:{ active:false, sinceText:'' },
    followed:false,
    updates:[
      { type:'ok', comment:'Duvar dibinde başka bir kediyle oynuyordu.', photo:PHOTOS.kadikoy, timeText:'dün 18:05' },
      { type:'sighting', comment:'', photo:null, timeText:'3 gün önce' }
    ]
  },
  {
    id:'sultan', name:'Sultan',
    photo:PHOTOS.sultanahmet, photos:[PHOTOS.sultanahmet],
    mapPos:{lat:40.9793,lng:29.0287}, fallbackPos:{top:'56%',left:'70%'},
    areaLabel:'Moda, çay bahçesi çevresi',
    lastSeenShort:'2 sa önce', lastSeenFull:'bugün 11:45', freshness:'fresh',
    condition:'İyi görünüyor, kafe müşterilerinden ilgi görüyor.',
    water:'Bugün su verildi', food:'Bilinmiyor',
    needsHelp:{ active:false, sinceText:'' },
    followed:true,
    updates:[
      { type:'water', comment:'Kase boştu, doldurduk.', photo:null, timeText:'bugün 11:45' },
      { type:'sighting', comment:'Masanın üstünde oturuyordu, çok sakin.', photo:PHOTOS.sultanahmet, timeText:'2 gün önce' }
    ]
  },
  {
    id:'balat-beyaz', name:null,
    photo:PHOTOS.oldistanbul, photos:[PHOTOS.oldistanbul],
    mapPos:{lat:40.9857,lng:29.0276}, fallbackPos:{top:'30%',left:'46%'},
    areaLabel:'Caferağa, Kadıköy',
    lastSeenShort:'3 sa önce', lastSeenFull:'bugün 12:40', freshness:'neutral',
    condition:'İyi görünüyor, genelde pencere pervazlarında görülüyor.',
    water:'Bilinmiyor', food:'Bilinmiyor',
    needsHelp:{ active:false, sinceText:'' },
    followed:false,
    updates:[
      { type:'sighting', comment:'Üçüncü kattaki pencere pervazında güneşleniyordu.', photo:null, timeText:'bugün 12:40' }
    ]
  },
  {
    id:'yavru', name:'Yavru',
    photo:PHOTOS.fatih, photos:[PHOTOS.fatih],
    mapPos:{lat:40.9838,lng:29.0305}, fallbackPos:{top:'68%',left:'38%'},
    areaLabel:'Osmanağa, Kadıköy',
    lastSeenShort:'8 sa önce', lastSeenFull:'bugün 08:30', freshness:'fresh',
    condition:'İyi görünüyor, yeni eklendi. Anne kedi görülmedi.',
    water:'Bilinmiyor', food:'Bilinmiyor',
    needsHelp:{ active:false, sinceText:'' },
    followed:true,
    updates:[
      { type:'sighting', comment:'Kafenin önünde tek başına dolaşıyordu, anne kedi görülmedi.', photo:PHOTOS.fatih, timeText:'bugün 08:30' }
    ]
  },
  {
    id:'kaplan', name:'Kaplan',
    photo:PHOTOS.brickwall, photos:[PHOTOS.brickwall],
    mapPos:{lat:40.9812,lng:29.0344}, fallbackPos:{top:'78%',left:'60%'},
    areaLabel:'Kadıköy, Damga Sokak',
    lastSeenShort:'4 gün önce', lastSeenFull:'4 gün önce, 19:15', freshness:'stale',
    condition:'Son güncellemeden bu yana haber yok.',
    water:'Bilinmiyor', food:'Bilinmiyor',
    needsHelp:{ active:false, sinceText:'' },
    followed:false,
    updates:[
      { type:'sighting', comment:'Sokak köpeklerinden kaçarken görüldü, sonra kayboldu.', photo:PHOTOS.brickwall, timeText:'4 gün önce' }
    ]
  },
  // the four cats below back the "+4" cluster marker near yeldeğirmeni — inCluster:true means
  // they stay hidden behind the cluster until the map is zoomed past CLUSTER_ZOOM_THRESHOLD
  // (see renderLeafletMarkers()), so tapping the cluster and zooming in actually reveals them.
  {
    id:'minnos', name:'Minnoş', inCluster:true,
    photo:PHOTOS.sultanahmet, photos:[PHOTOS.sultanahmet],
    mapPos:{lat:40.9862,lng:29.0308}, fallbackPos:{top:'26%',left:'76%'},
    areaLabel:'Yeldeğirmeni, Kadıköy',
    lastSeenShort:'1 sa önce', lastSeenFull:'bugün 13:10', freshness:'fresh',
    condition:'İyi görünüyor, apartman girişinde uyuyordu.',
    water:'Bilinmiyor', food:'Bilinmiyor',
    needsHelp:{ active:false, sinceText:'' },
    followed:false,
    updates:[{ type:'sighting', comment:'Apartman girişinde uyuyordu.', photo:null, timeText:'bugün 13:10' }]
  },
  {
    id:'boncuk', name:'Boncuk', inCluster:true,
    photo:PHOTOS.oldistanbul, photos:[PHOTOS.oldistanbul],
    mapPos:{lat:40.9868,lng:29.0309}, fallbackPos:{top:'22%',left:'84%'},
    areaLabel:'Yeldeğirmeni, Kadıköy',
    lastSeenShort:'dün 20:15', lastSeenFull:'dün 20:15', freshness:'neutral',
    condition:'İyi görünüyor, mahalledeki çoğu kişi tanıyor.',
    water:'Bilinmiyor', food:'Dün mama verildi',
    needsHelp:{ active:false, sinceText:'' },
    followed:false,
    updates:[{ type:'food', comment:'', photo:null, timeText:'dün 20:15' }]
  },
  {
    id:'duman', name:'Duman', inCluster:true,
    photo:PHOTOS.fatih, photos:[PHOTOS.fatih],
    mapPos:{lat:40.9863,lng:29.0316}, fallbackPos:{top:'30%',left:'80%'},
    areaLabel:'Yeldeğirmeni, Kadıköy',
    lastSeenShort:'5 gün önce', lastSeenFull:'5 gün önce', freshness:'stale',
    condition:'Son günlerde daha az görülüyor.',
    water:'Bilinmiyor', food:'Bilinmiyor',
    needsHelp:{ active:false, sinceText:'' },
    followed:false,
    updates:[{ type:'sighting', comment:'Bodrum kat penceresinden izliyordu.', photo:null, timeText:'5 gün önce' }]
  },
  {
    id:'pamuk', name:'Pamuk', inCluster:true,
    photo:PHOTOS.brickwall, photos:[PHOTOS.brickwall],
    mapPos:{lat:40.9868,lng:29.0315}, fallbackPos:{top:'20%',left:'88%'},
    areaLabel:'Yeldeğirmeni, Kadıköy',
    lastSeenShort:'3 sa önce', lastSeenFull:'bugün 11:00', freshness:'fresh',
    condition:'İyi görünüyor, kafeler civarında geziyor.',
    water:'Bugün su verildi', food:'Bilinmiyor',
    needsHelp:{ active:false, sinceText:'' },
    followed:false,
    updates:[{ type:'water', comment:'', photo:null, timeText:'bugün 11:00' }]
  }
];
var CLUSTER_LATLNG = { lat:40.9865, lng:29.0312 };
var CLUSTER_ZOOM_THRESHOLD = 17;

// calm, label-light basemap (carto positron) instead of the default osm-standard style, which
// renders shop/transit icons and road-shield numbers that make the map read as a navigation
// app rather than a map-first product. plain arrays (not L.latLngBounds/L.tileLayer) on
// purpose — these are read before we know leaflet's cdn script actually loaded.
var BASEMAP_TILE_URL = 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';
var BASEMAP_ATTRIBUTION = '&copy; <a href="https://carto.com/attributions" target="_blank" rel="noopener">CARTO</a>, &copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a> contributors';
// keeps the zoomed-out view from leaving istanbul's context (product review, "map" section)
var ISTANBUL_BOUNDS = [[40.80,28.45],[41.25,29.55]];
var MAP_MIN_ZOOM = 11;
var DUPLICATE_DEMO_CAT_ID = 'portakal'; // add-cat location picker starts near this cat, to demo the duplicate check

function findCat(id){ for(var i=0;i<CATS.length;i++) if(CATS[i].id===id) return CATS[i]; return null; }
function catDisplayName(cat){ return cat.name || 'İsimsiz kedi'; }
function statusVocabOf(id){ for(var i=0;i<STATUS_VOCAB.length;i++) if(STATUS_VOCAB[i].id===id) return STATUS_VOCAB[i]; return null; }

/* ============================================================ app state */
var state = {
  session:{ loggedIn:false, phone:null, contributionCount:{ updates:0, catsAdded:0 } },
  screenStack:[],
  currentScreen:'map',
  selectedCatId:null,
  sheetOpen:false,
  discoverTab:'nearby',
  discoverHelpFilter:false,
  mapHelpFilter:false,    // independent from discoverHelpFilter — the map's own "needs help" chip
  pendingAction:null,      // { type:'submit-update'|'start-add-cat', payload }
  draftUpdate:null,        // in-progress add-update form state
  draftCat:null,           // in-progress add-cat form state
  loginContext:'',
  mapLoaded:false,
  retryDemoShown:false,    // one-time simulated network error, see submitUpdate()
  newCatSeq:1
};

/* ============================================================ small utils */
function $(sel, root){ return (root||document).querySelector(sel); }
function $all(sel, root){ return Array.prototype.slice.call((root||document).querySelectorAll(sel)); }
function esc(s){ return (s||'').replace(/[&<>"]/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }

function toast(msg, opts){
  var el = $('#toast');
  el.innerHTML = (opts && opts.icon ? icon(opts.icon,{size:15}) : '') + '<span>'+esc(msg)+'</span>';
  el.classList.add('is-open');
  clearTimeout(toast._t);
  toast._t = setTimeout(function(){ el.classList.remove('is-open'); }, 2200);
}

/* ============================================================ router */
function screenEl(id){ return document.getElementById('screen-'+id); }

function navigate(id, opts){
  opts = opts || {};
  if(opts.root){ state.screenStack = []; }
  else if(state.currentScreen && state.currentScreen !== id){ state.screenStack.push(state.currentScreen); }
  state.currentScreen = id;
  $all('.screen').forEach(function(s){ s.classList.remove('is-active'); });
  var el = screenEl(id);
  el.classList.add('is-active');
  renderScreen(id);
  var body = el.querySelector('.screen-body, .screen-scroll-flat');
  if(body) body.scrollTop = 0;
  updateNavActiveState();
}
function replaceScreen(id){
  state.currentScreen = id;
  $all('.screen').forEach(function(s){ s.classList.remove('is-active'); });
  screenEl(id).classList.add('is-active');
  renderScreen(id);
  updateNavActiveState();
}
function goBack(){
  var prev = state.screenStack.pop();
  if(!prev){ navigate('map', {root:true}); return; }
  state.currentScreen = prev;
  $all('.screen').forEach(function(s){ s.classList.remove('is-active'); });
  screenEl(prev).classList.add('is-active');
  renderScreen(prev);
  updateNavActiveState();
}
function updateNavActiveState(){
  $all('.nav-item[data-tab]').forEach(function(b){
    b.classList.toggle('is-active', b.getAttribute('data-tab') === state.currentScreen);
  });
}

function requireLogin(context, pendingAction, fromScreen){
  state.loginContext = context;
  state.pendingAction = pendingAction;
  navigate('login');
}

/* ============================================================ render dispatch */
function renderScreen(id){
  if(id==='map') renderMap();
  else if(id==='detail') renderDetail();
  else if(id==='add-update') renderAddUpdate();
  else if(id==='add-loc') renderAddLoc();
  else if(id==='add-detail') renderAddDetail();
  else if(id==='discover') renderDiscover();
  else if(id==='notif') renderNotif();
  else if(id==='account') renderAccount();
  else if(id==='login') renderLogin();
}

/* ============================================================ shared bits */
function bottomNav(active){
  var unread = CATS.some(function(c){ return c.followed && c.needsHelp.active; });
  return '' +
  '<nav class="bottom-nav" aria-label="ana gezinme">' +
    navBtn('map','map','Harita',active) +
    navBtn('discover','compass','Keşfet',active) +
    '<button class="nav-item nav-fab" data-action="go-add-cat" aria-label="kedi ekle">' +
      '<span class="nav-fab__circle">'+icon('plus',{size:22})+'</span>' +
    '</button>' +
    navBtnBell(active, unread) +
    navBtn('account','user','Hesap',active) +
  '</nav>';
}
function navBtn(id,iconName,label,active){
  return '<button class="nav-item'+(active===id?' is-active':'')+'" data-tab="'+id+'" data-action="go-tab" data-target="'+id+'">'+
    icon(iconName,{size:22})+'<span>'+label+'</span></button>';
}
function navBtnBell(active, unread){
  return '<button class="nav-item'+(active==='notif'?' is-active':'')+'" data-tab="notif" data-action="go-tab" data-target="notif" style="position:relative;">'+
    icon('bell',{size:22}) + (unread?'<span class="badge-dot" style="position:absolute;top:4px;right:24%;background:var(--color-accent);"></span>':'') +
    '<span>Bildirimler</span></button>';
}
function topbar(title, opts){
  opts = opts || {};
  var left = opts.close ? '<button class="btn-icon" data-action="'+(opts.closeAction||'back')+'" aria-label="kapat">'+icon('close',{size:18})+'</button>'
           : (opts.back ? '<button class="btn-icon" data-action="back" aria-label="geri">'+icon('chevronLeft',{size:20})+'</button>' : '<span style="width:44px;"></span>');
  var right = opts.right || '<span style="width:44px;"></span>';
  return '<div class="topbar align-left"><div class="row-gap">'+left+'</div><div class="topbar__title">'+esc(title)+'</div>'+right+'</div>';
}
function freshnessBadge(cat){
  if(cat.needsHelp.active){
    return '<span class="badge badge-help">'+icon('alertTriangle',{size:12})+'yardım bildirimi · '+esc(cat.needsHelp.sinceText)+'</span>';
  }
  var cls = cat.freshness==='fresh' ? 'badge-fresh' : (cat.freshness==='stale' ? 'badge-stale' : 'badge-neutral');
  return '<span class="badge '+cls+'"><span class="badge-dot"></span>'+esc(cat.lastSeenShort)+'</span>';
}
var FRESHNESS_MARKER_CLASS = { fresh:'freshness-new', neutral:'freshness-normal', stale:'freshness-stale' };
// bigger markers as the user zooms in — at the default city-block zoom a 40px photo is fine,
// but left that size while zoomed in close it's too small to comfortably tap on a real phone.
// thresholds are integers because leaflet's default zoomSnap:1 only ever settles on whole
// zoom levels (17, 18, 19...) even though the initial view is set to a fractional 15.7
function markerSizeForZoom(zoom){
  if(zoom >= 18) return 56;
  if(zoom >= 17) return 48;
  return 40;
}
function markerHTML(cat, selected, size){
  var help = cat.needsHelp.active;
  var freshCls = FRESHNESS_MARKER_CLASS[cat.freshness] || 'freshness-normal';
  var effSize = size ? (selected ? size + 16 : size) : null;
  var sizeStyle = effSize ? ' style="width:'+effSize+'px;height:'+effSize+'px;"' : '';
  return '<div class="marker '+freshCls+(selected?' is-selected':'')+(help?' needs-help':'')+'"'+sizeStyle+' data-action="select-marker" data-cat="'+cat.id+'" role="button" tabindex="0" aria-label="'+esc(catDisplayName(cat))+' konumu">'+
    '<img src="'+cat.photo+'" alt="" onerror="onImgErr(this)">' +
    (help ? '<span class="marker-badge">'+icon('alertTriangle',{size:9})+'</span>' : '') +
  '</div>';
}

/* ============================================================ SCREEN: map */
var leafletMap = null, leafletMarkers = {}, leafletCluster = null, leafletFailed = false;

function renderMap(){
  var el = screenEl('map');
  if(el.dataset.built === '1'){ updateMapMarkersDom(); return; }
  teardownLeafletMap();
  el.dataset.built = '1';
  el.innerHTML =
    '<div class="map-screen">' +
      '<div id="leafletMap"></div>' +
      '<div class="map-fallback" id="mapFallback" hidden></div>' +
      '<div id="mapMarkers"></div>' +
      '<div id="mapSkeleton" class="skeleton" style="position:absolute;inset:0;z-index:15;"></div>' +
      '<div class="map-topbar">' +
        '<div class="search-field">'+icon('search',{size:17})+'<input type="text" placeholder="Mahalle veya sokak ara" aria-label="konum ara"></div>' +
        '<div class="chip-row">' +
          '<button class="chip is-warm'+(state.mapHelpFilter?' is-on':'')+'" data-action="toggle-map-help-filter" aria-pressed="'+state.mapHelpFilter+'">'+icon('alertTriangle',{size:14})+' yardım gerekiyor</button>' +
        '</div>' +
      '</div>' +
      '<button class="fab" data-action="go-add-cat" aria-label="yeni kedi ekle" style="position:absolute;right:'+'20px;bottom:104px;">'+icon('plus',{size:24})+'</button>' +
      '<a class="map-attribution" href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">© OpenStreetMap contributors</a>' +
    '</div>' +
    '<div class="sheet-scrim" id="sheetScrim" data-action="close-sheet"></div>' +
    '<div class="sheet" id="catSheet"></div>' +
    bottomNav('map');

  setTimeout(function(){
    var sk = $('#mapSkeleton', el); if(sk) sk.remove();
    state.mapLoaded = true;
  }, 550);

  initLeaflet();
  updateMapMarkersDom();
}

/* removes the current leaflet instance (if any) and resets every module-level
   reference tied to it, so a fresh #leafletMap dom node can be initialized
   safely afterwards. safe to call when no instance exists (no-op). */
function teardownLeafletMap(){
  if(leafletMap){
    try{ leafletMap.remove(); }catch(e){ /* dom node already gone — nothing to clean up */ }
  }
  leafletMap = null;
  leafletMarkers = {};
  leafletCluster = null;
  leafletFailed = false;
}

function initLeaflet(){
  if(leafletMap || leafletFailed) return;
  if(typeof L === 'undefined'){ leafletFailed = true; activateMapFallback(); return; }
  try{
    // attributionControl stays off here — the map's own .map-attribution element (in renderMap's
    // markup) carries the required credit instead, at a z-index above the bottom sheet, so it's
    // never fully hidden while leaflet's own bottomright control would be.
    leafletMap = L.map('leafletMap', {
      zoomControl:false, attributionControl:false,
      minZoom:MAP_MIN_ZOOM, maxBounds:ISTANBUL_BOUNDS, maxBoundsViscosity:0.8
    }).setView([40.9822,29.0288], 15.7);
    var tiles = L.tileLayer(BASEMAP_TILE_URL, { maxZoom:19, attribution:BASEMAP_ATTRIBUTION });
    tiles.on('tileerror', function(){ if(!leafletFailed){ leafletFailed = true; activateMapFallback(); } });
    tiles.addTo(leafletMap);
    L.control.zoom({ position:'bottomright' }).addTo(leafletMap);
    leafletMap.on('click', function(){ closeSheet(); });
    leafletMap.on('zoomend', updateMapMarkersDom);
    CATS.forEach(addLeafletMarker);
    addLeafletCluster();
  }catch(e){ leafletFailed = true; activateMapFallback(); }
}
function addLeafletMarker(cat){
  var divIcon = L.divIcon({ className:'', html:markerHTML(cat, cat.id===state.selectedCatId), iconSize:[40,40], iconAnchor:[20,20] });
  var m = L.marker([cat.mapPos.lat, cat.mapPos.lng], { icon:divIcon, keyboard:false, alt:catDisplayName(cat) }).addTo(leafletMap);
  m.on('click', function(e){ if(e.originalEvent) e.originalEvent.stopPropagation(); selectCat(cat.id); });
  leafletMarkers[cat.id] = m;
}
function addLeafletCluster(){
  var html = '<div class="marker-cluster" role="button" tabindex="0" aria-label="bölgedeki diğer kediler, yakınlaştırmak için dokun">'+icon('pin',{size:14})+'<span>+4</span></div>';
  var divIcon = L.divIcon({ className:'', html:html, iconSize:[46,42], iconAnchor:[23,21] });
  leafletCluster = L.marker([CLUSTER_LATLNG.lat, CLUSTER_LATLNG.lng], { icon:divIcon, keyboard:false }).addTo(leafletMap);
  // tapping the cluster actually zooms into it — updateMapMarkersDom() runs again on the
  // resulting 'zoomend' event and swaps the cluster for the 4 real cats it represents
  leafletCluster.on('click', function(e){
    if(e.originalEvent) e.originalEvent.stopPropagation();
    leafletMap.setView([CLUSTER_LATLNG.lat, CLUSTER_LATLNG.lng], CLUSTER_ZOOM_THRESHOLD, { animate:true });
  });
}

/* single entry point for entering fallback mode, used by both the synchronous
   init failure path (leaflet missing / threw) and the async tileerror path.
   always re-renders the fallback markers so they never render onto an empty grid. */
function activateMapFallback(){
  var fb = $('#mapFallback'); var lm = $('#leafletMap');
  if(fb){ fb.hidden = false; }
  if(lm){ lm.style.display = 'none'; }
  renderFallbackMarkers();
}

/* dispatches to whichever marker renderer matches the current map mode */
function updateMapMarkersDom(){
  if(leafletMap && !leafletFailed){ renderLeafletMarkers(); return; }
  renderFallbackMarkers();
}
function renderLeafletMarkers(){
  var zoom = leafletMap.getZoom();
  var zoomedIntoCluster = zoom >= CLUSTER_ZOOM_THRESHOLD;
  var baseSize = markerSizeForZoom(zoom);
  CATS.forEach(function(cat){
    var m = leafletMarkers[cat.id]; if(!m) return;
    var sel = cat.id === state.selectedCatId;
    var effSize = sel ? baseSize + 16 : baseSize;
    m.setIcon(L.divIcon({ className:'', html:markerHTML(cat, sel, baseSize), iconSize:[effSize,effSize], iconAnchor:[effSize/2,effSize/2] }));
    var passesHelpFilter = !state.mapHelpFilter || cat.needsHelp.active;
    var passesClusterGate = !cat.inCluster || zoomedIntoCluster;
    var visible = passesHelpFilter && passesClusterGate;
    var onMap = leafletMap.hasLayer(m);
    if(visible && !onMap) m.addTo(leafletMap);
    else if(!visible && onMap) leafletMap.removeLayer(m);
  });
  if(leafletCluster){
    var clusterVisible = !state.mapHelpFilter && !zoomedIntoCluster;
    var clusterOnMap = leafletMap.hasLayer(leafletCluster);
    if(clusterVisible && !clusterOnMap) leafletCluster.addTo(leafletMap);
    else if(!clusterVisible && clusterOnMap) leafletMap.removeLayer(leafletCluster);
  }
}
function renderFallbackMarkers(){
  // no real zoom control in fallback mode, so there's nothing to gate the cluster
  // cats behind — show every cat directly instead of promising a reveal it can't do
  var wrap = $('#mapMarkers'); if(!wrap) return;
  var visibleCats = CATS.filter(function(c){ return !state.mapHelpFilter || c.needsHelp.active; });
  var html = visibleCats.map(function(cat){
    var sel = cat.id === state.selectedCatId;
    return '<div style="position:absolute;top:'+cat.fallbackPos.top+';left:'+cat.fallbackPos.left+';transform:translate(-50%,-50%);">'+markerHTML(cat, sel)+'</div>';
  }).join('');
  wrap.innerHTML = html;
}

function selectCat(id){
  state.selectedCatId = id;
  updateMapMarkersDom();
  openSheet(id);
}
function openSheet(id){
  var cat = findCat(id); if(!cat) return;
  state.sheetOpen = true;
  $('#sheetScrim').classList.add('is-open');
  var sheet = $('#catSheet');
  sheet.innerHTML =
    '<div class="sheet-grabber"></div>' +
    '<div class="cat-preview">' +
      '<img class="cat-preview__photo" src="'+cat.photo+'" alt="" onerror="onImgErr(this)">' +
      '<div class="cat-preview__body">' +
        '<div class="spread"><span class="cat-preview__name">'+esc(catDisplayName(cat))+'</span></div>' +
        '<span class="cat-preview__loc">'+icon('pin',{size:13})+esc(cat.areaLabel)+'</span>' +
        freshnessBadge(cat) +
        '<div class="cat-preview__facts">' +
          '<span class="fact">'+icon('droplet',{size:15})+esc(cat.water)+'</span>' +
          '<span class="fact">'+icon('bowl',{size:15})+esc(cat.food)+'</span>' +
        '</div>' +
      '</div>' +
    '</div>' +
    '<p class="cat-preview__status">'+esc(cat.condition)+'</p>' +
    '<button class="btn btn-primary btn-block mt-4" data-action="open-detail" data-cat="'+cat.id+'">Detaya git '+icon('chevronRight',{size:16})+'</button>';
  sheet.classList.add('is-open');
}
function closeSheet(){
  state.sheetOpen = false;
  state.selectedCatId = null;
  var scrim = $('#sheetScrim'); if(scrim) scrim.classList.remove('is-open');
  var sheet = $('#catSheet'); if(sheet) sheet.classList.remove('is-open');
  updateMapMarkersDom();
}

/* ============================================================ SCREEN: cat detail */
function renderDetail(){
  var cat = findCat(state.selectedCatId) || CATS[0];
  if(state._detailPhotoCat !== cat.id){ state._detailPhotoCat = cat.id; state.detailPhotoIndex = 0; }
  var idx = Math.min(state.detailPhotoIndex || 0, cat.photos.length - 1);
  // when an update hasn't brought in a genuinely different photo yet, the 2nd dot shows a
  // closer crop of the same source photo instead of a fake "different" picture — still an
  // honest photo, and it demonstrates the slide mechanic instead of a no-op swipe
  var isRepeatCloseup = idx > 0 && cat.photos[idx] === cat.photos[0];
  var el = screenEl('detail');
  el.innerHTML =
    '<div class="screen-scroll-flat">' +
      '<div class="hero-photo">' +
        '<img src="'+cat.photos[idx]+'" alt="'+esc(catDisplayName(cat))+'"'+(isRepeatCloseup?' class="is-closeup"':'')+' onerror="onImgErr(this)">' +
        '<div class="hero-photo__scrim"></div>' +
        (cat.photos.length > 1 ? (
          '<button class="hero-photo__tap hero-photo__tap--prev" data-action="hero-photo-prev" aria-label="önceki fotoğraf"'+(idx===0?' aria-disabled="true"':'')+'></button>' +
          '<button class="hero-photo__tap hero-photo__tap--next" data-action="hero-photo-next" aria-label="sonraki fotoğraf"'+(idx===cat.photos.length-1?' aria-disabled="true"':'')+'></button>'
        ) : '') +
        '<div class="hero-photo__topbar">' +
          '<button class="btn-icon on-glass" data-action="back" aria-label="geri">'+icon('chevronLeft',{size:19})+'</button>' +
          '<button class="btn-icon on-glass'+(cat.followed?' filled':'')+'" data-action="toggle-follow" data-cat="'+cat.id+'" aria-label="'+(cat.followed?'takibi bırak':'takip et')+'" aria-pressed="'+cat.followed+'">'+icon('heart',{size:18, filled:cat.followed})+'</button>' +
        '</div>' +
        '<div class="hero-photo__caption">' +
          '<div class="hero-photo__name">'+esc(catDisplayName(cat))+'</div>' +
          '<div class="hero-photo__loc">'+icon('pin',{size:13})+esc(cat.areaLabel)+'</div>' +
        '</div>' +
        '<div class="hero-dots">'+cat.photos.map(function(_,i){ return '<span class="'+(i===idx?'is-on':'')+'"></span>'; }).join('')+'</div>' +
      '</div>' +
      '<div class="screen-body mt-4">' +
        '<div class="info-row">' +
          '<div class="info-row__icon">'+icon('clock',{size:18})+'</div>' +
          '<div><div class="info-row__label">Son görülme</div><div class="info-row__value">'+esc(cat.lastSeenFull)+'</div></div>' +
        '</div>' +
        '<div class="info-row">' +
          '<div class="info-row__icon">'+icon('compass',{size:18})+'</div>' +
          '<div><div class="info-row__label">Genel durum</div><div class="info-row__value">'+esc(cat.condition)+'</div></div>' +
        '</div>' +
        '<div class="info-row">' +
          '<div class="info-row__icon">'+icon('droplet',{size:18})+'</div>' +
          '<div><div class="info-row__label">Su ve yemek</div><div class="info-row__value">'+esc(cat.water)+' · '+esc(cat.food)+'</div></div>' +
        '</div>' +
        '<div class="info-row'+(cat.needsHelp.active?' is-warm':'')+'">' +
          '<div class="info-row__icon">'+icon('alertTriangle',{size:18})+'</div>' +
          '<div><div class="info-row__label">Yardıma ihtiyacı var mı</div><div class="info-row__value">'+
            (cat.needsHelp.active ? 'Evet — '+esc(cat.needsHelp.sinceText)+' bildirildi.' : 'Şu anda aktif bir yardım bildirimi yok.') +
          '</div></div>' +
        '</div>' +

        '<div class="stack-sm mt-6">' +
          '<button class="btn btn-primary btn-block" data-action="go-add-update" data-cat="'+cat.id+'" data-type="update">'+icon('edit',{size:17})+' Durum güncellemesi ekle</button>' +
          '<button class="btn btn-secondary btn-block" data-action="toggle-follow" data-cat="'+cat.id+'">'+icon('heart',{size:16, filled:cat.followed})+' '+(cat.followed?'Takip ediliyor':'Takip et')+'</button>' +
        '</div>' +
        // kept visually apart from the routine actions above (own row, divider, bolder icon)
        // so it doesn't blend in with everyday update actions — see the help-action review note
        '<div class="help-callout mt-4">' +
          '<button class="btn btn-warm btn-block" data-action="go-add-update" data-cat="'+cat.id+'" data-type="help">'+icon('alertTriangle',{size:19})+' Yardıma ihtiyacı var</button>' +
        '</div>' +

        '<h3 class="eyebrow mt-6 mb-2">Son güncellemeler</h3>' +
        '<div class="timeline">' +
          cat.updates.map(function(u, i){
            var v = statusVocabOf(u.type);
            return '<div class="timeline-item'+(u.type==='hurt'?' is-help':'')+'">' +
              '<div class="timeline-item__rail"><span class="timeline-item__dot"></span>'+(i<cat.updates.length-1?'<span class="timeline-item__line"></span>':'')+'</div>' +
              '<div class="timeline-item__body">' +
                '<div class="timeline-item__head"><span class="timeline-item__type">'+(v?esc(v.label):'Güncelleme')+'</span><span class="timeline-item__time">'+esc(u.timeText)+'</span></div>' +
                (u.comment?'<div class="timeline-item__comment">"'+esc(u.comment)+'"</div>':'') +
                (u.photo?'<img class="timeline-item__photo" src="'+u.photo+'" alt="" onerror="onImgErr(this)">':'') +
              '</div>' +
            '</div>';
          }).join('') +
        '</div>' +
      '</div>' +
    '</div>';
}

/* ============================================================ SCREEN: add update */
function renderAddUpdate(){
  var el = screenEl('add-update');
  var cat = findCat(state.draftUpdate ? state.draftUpdate.catId : state.selectedCatId);
  if(!state.draftUpdate || state.draftUpdate.catId !== cat.id){
    state.draftUpdate = { catId:cat.id, kind:'update', status:'sighting', comment:'', photo:null, submitting:false, error:false };
  }
  var d = state.draftUpdate;
  var needsLogin = (d.kind==='help') || !!d.photo;

  el.innerHTML =
    topbar('Güncelleme ekle', { close:true }) +
    '<div class="screen-body">' +
      '<div class="row-gap mb-4"><img src="'+cat.photo+'" alt="" style="width:28px;height:28px;border-radius:50%;object-fit:cover;" onerror="onImgErr(this)"><span class="text-muted" style="font-weight:600;">'+esc(catDisplayName(cat))+'</span></div>' +

      '<div class="field-label mb-2">Ne tür bir güncelleme?</div>' +
      '<div class="type-select mb-4">' +
        '<button class="type-card'+(d.kind==='update'?' is-on':'')+'" data-action="set-update-kind" data-kind="update">'+icon('edit',{size:18})+'<span class="type-card__label">Durum güncellemesi</span></button>' +
        '<button class="type-card is-warm'+(d.kind==='help'?' is-on':'')+'" data-action="set-update-kind" data-kind="help">'+icon('alertTriangle',{size:18})+'<span class="type-card__label">Yardım gerekiyor</span></button>' +
      '</div>' +

      (d.kind==='update' ?
        '<div class="field-label mb-2">Durumu seç</div><div class="status-grid mb-4">' +
        STATUS_VOCAB.map(function(v){
          return '<button class="status-option'+(d.status===v.id?' is-on':'')+'" data-action="set-status" data-status="'+v.id+'">' +
            '<span class="status-option__radio"></span>' + icon(v.icon,{size:18}) + '<span class="status-option__label">'+esc(v.label)+'</span></button>';
        }).join('') + '</div>'
        : '<p class="text-muted mb-4" style="font-size:var(--text-sm);line-height:1.5;">Takip edenlere bildirim gider. Yardım bildirimleri bir süre sonra otomatik olarak listeden kalkar.</p>'
      ) +

      '<div class="field mb-4">' +
        '<span class="field-label">Yorum (opsiyonel)</span>' +
        '<textarea class="textarea" placeholder="Örn. kase boştu, biraz su bıraktım…" data-action="draft-comment">'+esc(d.comment)+'</textarea>' +
      '</div>' +

      '<div class="field mb-4">' +
        '<span class="field-label">Fotoğraf (opsiyonel)</span>' +
        '<label class="photo-well" style="height:120px;">' +
          (d.photo ? '<img src="'+d.photo+'" alt="">' : (icon('camera',{size:24}) + '<span>Fotoğraf ekle</span>')) +
          '<input type="file" accept="image/*" data-action="draft-photo" aria-label="fotoğraf ekle">' +
        '</label>' +
      '</div>' +

      (needsLogin ? '<div class="login-context mb-4">'+icon('phone',{size:16})+'<span>'+(d.kind==='help' ? 'Yardım bildirimi oluşturmak için giriş yapman gerekiyor.' : 'Fotoğraf eklemek için giriş yapman gerekiyor.')+'</span></div>' : '') +

      (d.error ? '<div class="state-block is-error" style="padding:var(--space-4) 0;text-align:left;align-items:flex-start;">' +
          '<div class="row-gap"><div class="state-block__icon" style="width:36px;height:36px;">'+icon('alertTriangle',{size:16})+'</div>' +
          '<div><div class="state-block__title" style="font-size:var(--text-sm);">Gönderilemedi</div>' +
          '<div class="state-block__body" style="text-align:left;">Bağlantı sorunu oldu. Tekrar dener misin?</div></div></div>' +
        '</div>' : '') +

      '<button class="btn btn-primary btn-block mt-2" data-action="submit-update"'+(d.submitting?' aria-disabled="true"':'')+'>' +
        (d.submitting ? '<span class="spinner"></span>' : (d.error ? 'Tekrar dene' : (needsLogin ? 'Giriş yap ve gönder' : 'Gönder'))) +
      '</button>' +
    '</div>';
}

function submitUpdate(){
  var d = state.draftUpdate; if(!d || d.submitting) return;
  var cat = findCat(d.catId);
  var needsLogin = (d.kind==='help') || !!d.photo;

  if(needsLogin && !state.session.loggedIn){
    requireLogin(d.kind==='help' ? 'Yardım bildirimi oluşturmak için giriş yap' : 'Fotoğraf eklemek için giriş yap', { type:'submit-update' });
    return;
  }

  d.submitting = true; d.error = false; renderAddUpdate();

  setTimeout(function(){
    if(!state.retryDemoShown){
      state.retryDemoShown = true;
      d.submitting = false; d.error = true;
      renderAddUpdate();
      return;
    }
    var v = statusVocabOf(d.status);
    var entry = {
      type: d.kind==='help' ? 'hurt' : d.status,
      comment: d.comment.trim(),
      photo: d.photo,
      timeText: 'az önce'
    };
    cat.updates.unshift(entry);
    cat.lastSeenShort = 'az önce'; cat.lastSeenFull = 'az önce'; cat.freshness = 'fresh';
    if(d.kind==='help'){ cat.needsHelp = { active:true, sinceText:'az önce' }; cat.condition = entry.comment || cat.condition; }
    else if(d.status==='water'){ cat.water = 'Az önce su verildi'; }
    else if(d.status==='food'){ cat.food = 'Az önce mama verildi'; }
    else if(d.status==='ok'){ cat.condition = 'İyi görünüyor.'; }
    else if(d.status==='hurt'){ cat.condition = entry.comment || 'Yaralı ya da hasta görünebilir.'; }

    state.draftUpdate = null;
    state.session.contributionCount.updates++;
    toast('Güncelleme paylaşıldı', {icon:'check'});
    replaceScreen('detail');
  }, 700);
}

/* ============================================================ SCREEN: add cat — location */
var locMap = null, locMapFailed = false;

function renderAddLoc(){
  var el = screenEl('add-loc');
  if(!state.draftCat){
    var seed = findCat(DUPLICATE_DEMO_CAT_ID);
    state.draftCat = { lat:seed.mapPos.lat, lng:seed.mapPos.lng, geoError:'', photo:null, name:'', saving:false };
  }
  var d = state.draftCat;
  // this screen has no dataset.built cache (unlike the map screen) — it's rebuilt every time
  // renderAddLoc() runs, including from useCurrentLocation()'s callback, so the leaflet instance
  // bound to the old #locationMap node must be torn down before a new one replaces it.
  teardownLocationMap();
  el.innerHTML =
    topbar('Konumu seç', { close:true }) +
    '<div class="screen-body no-pad-x">' +
      '<div class="location-picker">' +
        '<div id="locationMap"></div>' +
        '<div class="map-fallback" id="locFallback" hidden></div>' +
        '<div class="location-picker__radius"></div>' +
        '<div class="location-picker__center">'+icon('pin',{size:30, class:'text-primary'})+'</div>' +
      '</div>' +
      '<div class="stack-sm mt-4" style="padding:0 var(--space-5);">' +
        '<button class="btn btn-secondary btn-block" data-action="use-current-location">'+icon('location',{size:17})+' Mevcut konumu kullan</button>' +
        (d.geoError ? '<div class="field-error">'+icon('alertTriangle',{size:14})+' '+esc(d.geoError)+'</div>' : '') +
        '<button class="btn btn-primary btn-block" data-action="confirm-location">Bu konumu kullan</button>' +
      '</div>' +
    '</div>' +
    '<div class="modal-scrim" id="dupModal"></div>';

  setTimeout(initLocationMap, 0);
}

/* mirrors teardownLeafletMap() for the add-cat location-picker map */
function teardownLocationMap(){
  if(locMap){
    try{ locMap.remove(); }catch(e){ /* dom node already gone — nothing to clean up */ }
  }
  locMap = null;
  locMapFailed = false;
}

function initLocationMap(){
  var el = $('#locationMap'); if(!el || locMap) return;
  if(typeof L === 'undefined'){ locMapFailed = true; var fb=$('#locFallback'); if(fb) fb.hidden=false; return; }
  try{
    locMap = L.map('locationMap', { zoomControl:false, attributionControl:false, dragging:true })
      .setView([state.draftCat.lat, state.draftCat.lng], 17);
    L.control.attribution({ prefix:false, position:'bottomright' }).addTo(locMap);
    L.tileLayer(BASEMAP_TILE_URL, { maxZoom:19, attribution:BASEMAP_ATTRIBUTION }).addTo(locMap);
    locMap.on('moveend', function(){ var c = locMap.getCenter(); state.draftCat.lat = c.lat; state.draftCat.lng = c.lng; });
  }catch(e){ locMapFailed = true; var fb2=$('#locFallback'); if(fb2) fb2.hidden=false; }
}
// stand-in for the user's device location — same point the map opens centered on
var USER_APPROX_LOCATION = { lat:40.9822, lng:29.0288 };
function formatDistance(meters){
  if(meters < 1000) return Math.max(10, Math.round(meters/10)*10) + ' m';
  return (meters/1000).toFixed(1).replace('.', ',') + ' km';
}
function distanceMeters(a,b){
  var R=6371000, dLat=(b.lat-a.lat)*Math.PI/180, dLng=(b.lng-a.lng)*Math.PI/180;
  var la1=a.lat*Math.PI/180, la2=b.lat*Math.PI/180;
  var h = Math.sin(dLat/2)*Math.sin(dLat/2) + Math.cos(la1)*Math.cos(la2)*Math.sin(dLng/2)*Math.sin(dLng/2);
  return 2*R*Math.asin(Math.sqrt(h));
}
function useCurrentLocation(){
  var d = state.draftCat;
  if(!navigator.geolocation){ d.geoError = 'Bu tarayıcıda konum servisi yok. Haritadan elle seç.'; renderAddLoc(); return; }
  navigator.geolocation.getCurrentPosition(function(position){
    d.geoError = '';
    d.lat = position.coords.latitude;
    d.lng = position.coords.longitude;
    toast('Konumun bulundu', {icon:'location'});
    renderAddLoc();
  }, function(){
    d.geoError = 'Konum izni reddedildi. Haritadan elle seçebilirsin.';
    renderAddLoc();
  }, { timeout:6000 });
}
var DUPLICATE_CHECK_RADIUS_M = 80;
function confirmLocation(){
  var d = state.draftCat;
  var nearby = (locMapFailed || typeof L === 'undefined')
    ? [findCat(DUPLICATE_DEMO_CAT_ID)]
    : CATS.filter(function(c){ return distanceMeters(c.mapPos, {lat:d.lat,lng:d.lng}) < DUPLICATE_CHECK_RADIUS_M; });
  if(nearby.length){ openDuplicateModal(nearby); return; }
  navigate('add-detail');
}
// shows a photo for every cat already registered near the picked spot — not just a name —
// so the user can visually recognize "is it this one?" instead of guessing from text alone.
// when more than one cat is nearby, all of them are offered as candidates.
function openDuplicateModal(cats){
  var d = state.draftCat;
  var modal = $('#dupModal');
  var title = cats.length === 1
    ? 'Bu bölgede zaten kayıtlı bir kedi var. Gördüğün kedi bu mu?'
    : 'Bu bölgede zaten kayıtlı '+cats.length+' kedi var. Gördüğün kedi bunlardan biri mi?';
  modal.innerHTML = '<div class="modal-card">' +
    '<div class="modal-card__title">'+title+'</div>' +
    '<div class="dup-candidates">' +
      cats.map(function(cat){
        var dist = formatDistance(distanceMeters(cat.mapPos, {lat:d.lat,lng:d.lng}));
        return '<button class="dup-candidate" data-action="dup-yes" data-cat="'+cat.id+'">' +
          '<img class="dup-candidate__photo" src="'+cat.photo+'" alt="" onerror="onImgErr(this)">' +
          '<div class="dup-candidate__body"><div class="dup-candidate__name">'+esc(catDisplayName(cat))+'</div>' +
          '<div class="dup-candidate__meta">'+esc(cat.areaLabel)+' · '+dist+'</div></div>' +
          icon('chevronRight',{size:16}) +
        '</button>';
      }).join('') +
    '</div>' +
    '<button class="btn btn-secondary btn-block" data-action="dup-no">Hayır, farklı bir kedi</button>' +
  '</div>';
  modal.classList.add('is-open');
}
function closeDuplicateModal(){ var m=$('#dupModal'); if(m) m.classList.remove('is-open'); }

/* ============================================================ SCREEN: add cat — details */
function renderAddDetail(){
  var el = screenEl('add-detail');
  var d = state.draftCat || { photo:null, name:'', saving:false };
  el.innerHTML =
    topbar('Kedi ekle', { back:true }) +
    '<div class="screen-body">' +
      '<div class="field mb-4">' +
        '<span class="field-label">Fotoğraf (zorunlu)</span>' +
        '<label class="photo-well" style="height:150px;">' +
          (d.photo ? '<img src="'+d.photo+'" alt="">' : (icon('camera',{size:26}) + '<span>Fotoğraf ekle</span>')) +
          '<span class="required-tag">zorunlu</span>' +
          '<input type="file" accept="image/*" data-action="cat-photo" aria-label="kedi fotoğrafı ekle">' +
        '</label>' +
      '</div>' +
      '<div class="field mb-6">' +
        '<span class="field-label">İsim (opsiyonel)</span>' +
        '<input class="input" type="text" placeholder="Örn. Boncuk, Minnoş…" value="'+esc(d.name)+'" data-action="cat-name">' +
      '</div>' +
      '<button class="btn btn-primary btn-block" data-action="save-cat"'+(d.saving?' aria-disabled="true"':'')+'>' +
        (d.saving ? '<span class="spinner"></span>' : 'Kaydet') +
      '</button>' +
    '</div>';
}
function saveCat(){
  var d = state.draftCat; if(!d || d.saving) return;
  if(!d.photo){ toast('Kaydetmeden önce bir fotoğraf ekle', {icon:'alertTriangle'}); return; }
  if(!state.session.loggedIn){
    requireLogin('Yeni kedi eklemek için giriş yap', { type:'save-cat' });
    return;
  }
  d.saving = true; renderAddDetail();
  setTimeout(function(){
    var id = 'yeni-kedi-'+(state.newCatSeq++);
    var newCat = {
      id:id, name: d.name.trim() || null,
      photo:d.photo, photos:[d.photo],
      mapPos:{lat:d.lat, lng:d.lng}, fallbackPos:{top:'50%',left:'50%'},
      areaLabel:'Kadıköy çevresi',
      lastSeenShort:'az önce', lastSeenFull:'az önce eklendi', freshness:'fresh',
      condition:'Yeni eklendi.', water:'Bilinmiyor', food:'Bilinmiyor',
      needsHelp:{active:false, sinceText:''}, followed:false,
      updates:[{ type:'sighting', comment:'Yeni kedi olarak eklendi.', photo:d.photo, timeText:'az önce' }]
    };
    CATS.push(newCat);
    state.draftCat = null;
    state.selectedCatId = newCat.id;
    state.session.contributionCount.catsAdded++;
    toast('Kedi eklendi', {icon:'check'});
    // forces renderMap() to tear down and reinitialize leaflet on a fresh dom node,
    // which re-adds every cat in CATS (including newCat) via initLeaflet()
    screenEl('map').dataset.built = '';
    navigate('map', { root:true });
    openSheet(newCat.id);
  }, 700);
}

/* ============================================================ SCREEN: discover */
function renderDiscover(){
  var el = screenEl('discover');
  var list = CATS.map(function(c){
    return { cat:c, distance: distanceMeters(USER_APPROX_LOCATION, c.mapPos) };
  });
  if(state.discoverTab === 'favorites') list = list.filter(function(r){ return r.cat.followed; });
  if(state.discoverHelpFilter) list = list.filter(function(r){ return r.cat.needsHelp.active; });
  if(state.discoverTab === 'nearby') list.sort(function(a,b){ return a.distance - b.distance; });

  el.innerHTML =
    topbar('Keşfet', {}) +
    '<div class="screen-body">' +
      '<div class="segmented mb-3">' +
        '<button class="'+(state.discoverTab==='nearby'?'is-on':'')+'" data-action="discover-tab" data-tab="nearby">Yakınımda</button>' +
        '<button class="'+(state.discoverTab==='favorites'?'is-on':'')+'" data-action="discover-tab" data-tab="favorites">Favoriler</button>' +
      '</div>' +
      '<div class="chip-row mb-2">' +
        '<button class="chip is-warm'+(state.discoverHelpFilter?' is-on':'')+'" data-action="toggle-discover-help-filter">'+icon('alertTriangle',{size:14})+' yardım gerekiyor</button>' +
      '</div>' +
      (list.length ?
        '<div>' + list.map(function(r,i){
          var c = r.cat;
          return (i>0?'<div class="list-divider"></div>':'') +
          '<div class="cat-card" data-action="open-detail" data-cat="'+c.id+'">' +
            '<img class="cat-card__photo" src="'+c.photo+'" alt="" onerror="onImgErr(this)">' +
            '<div class="cat-card__body"><div class="cat-card__name">'+esc(catDisplayName(c))+'</div><div class="cat-card__meta">'+esc(c.areaLabel)+'</div></div>' +
            '<div class="cat-card__aside">' + freshnessBadge(c) + '<span class="cat-card__distance">'+formatDistance(r.distance)+'</span></div>' +
          '</div>';
        }).join('') + '</div>'
        : emptyState(
            state.discoverTab==='favorites' ? 'Henüz favori kedin yok' : 'Yakında kedi bulunamadı',
            state.discoverTab==='favorites' ? 'Haritada beğendiğin bir kediyi takip et, burada listelensin.' : 'Filtreyi kaldırıp tekrar dene.',
            'compass'
          )
      ) +
    '</div>' +
    bottomNav('discover');
}
function emptyState(title, body, iconName){
  return '<div class="state-block"><div class="state-block__icon">'+icon(iconName||'compass',{size:22})+'</div>' +
    '<div class="state-block__title">'+esc(title)+'</div><div class="state-block__body">'+esc(body)+'</div></div>';
}

/* ============================================================ SCREEN: notifications */
function renderNotif(){
  var el = screenEl('notif');
  var items = [];
  CATS.forEach(function(c){
    if(!c.followed || !c.updates.length) return;
    var u = c.updates[0];
    var v = statusVocabOf(u.type);
    items.push({ cat:c, unread: c.freshness==='fresh', title: catDisplayName(c), desc: c.needsHelp.active ? 'Yardım bildirimi oluşturuldu' : (v?v.label:'Güncelleme'), time: u.timeText, help: c.needsHelp.active });
  });

  el.innerHTML =
    topbar('Bildirimler', {}) +
    '<div class="screen-body no-pad-x">' +
      (items.length ?
        '<div style="padding:0 var(--space-5);">' + items.map(function(n){
          return '<div class="notif-item'+(n.unread?' is-unread':'')+'" data-action="open-detail" data-cat="'+n.cat.id+'">' +
            '<img class="notif-item__photo" src="'+n.cat.photo+'" alt="" onerror="onImgErr(this)">' +
            '<div class="notif-item__body"><div class="notif-item__title">'+esc(n.title)+'</div>' +
              '<div class="notif-item__desc">'+ (n.help?'<span class="badge badge-help is-soft">'+icon('alertTriangle',{size:11})+' yardım</span> ':'') + esc(n.desc)+'</div></div>' +
            '<span class="notif-item__time">'+esc(n.time)+'</span>' +
          '</div>';
        }).join('') + '</div>'
        : emptyState('Henüz bildirim yok', 'Bir kediyi takip etmeye başladığında güncellemeleri burada göreceksin.', 'bell')
      ) +
    '</div>' +
    bottomNav('notif');
}

/* ============================================================ SCREEN: account */
function renderAccount(){
  var el = screenEl('account');
  el.innerHTML =
    topbar('Hesap', {}) +
    '<div class="screen-body">' +
      (state.session.loggedIn ? accountLoggedInBody() : accountGuestBody()) +
    '</div>' +
    bottomNav('account');
}
// followed-cats list intentionally isn't here anymore — it belongs to a discovery/library
// screen that's out of scope for this pass (see the review notes shared with the product owner)
function accountLoggedInBody(){
  var cc = state.session.contributionCount;
  return (
    '<div class="row-gap mb-6" style="align-items:flex-start;">' +
      '<div class="login-hero__icon" style="width:48px;height:48px;flex:none;">'+icon('user',{size:22})+'</div>' +
      '<div class="stack-sm" style="gap:6px;padding-top:3px;">' +
        '<div style="font-weight:700;font-size:var(--text-md);line-height:1.2;">'+esc(state.session.phone||'')+'</div>' +
        '<div class="row-gap" style="gap:4px;color:var(--color-primary-strong);font-size:var(--text-xs);font-weight:700;line-height:1;">'+icon('check',{size:13})+'<span>Telefon doğrulandı</span></div>' +
      '</div>' +
    '</div>' +

    '<h3 class="eyebrow mb-2">Katkı özeti · bu oturumda</h3>' +
    '<div class="info-row">' +
      '<div class="info-row__icon">'+icon('edit',{size:18})+'</div>' +
      '<div><div class="info-row__label">Güncelleme</div><div class="info-row__value">'+
        (cc.updates ? cc.updates+' güncelleme paylaştın' : 'Henüz güncelleme paylaşmadın') +
      '</div></div>' +
    '</div>' +
    '<div class="info-row">' +
      '<div class="info-row__icon">'+icon('pin',{size:18})+'</div>' +
      '<div><div class="info-row__label">Yeni kedi</div><div class="info-row__value">'+
        (cc.catsAdded ? cc.catsAdded+' kedi eklendin' : 'Henüz kedi eklemedin') +
      '</div></div>' +
    '</div>' +

    '<h3 class="eyebrow mt-6 mb-2">Ayarlar</h3>' +
    '<div class="info-row"><div class="info-row__icon">'+icon('bell',{size:18})+'</div><div><div class="info-row__label">Bildirimler</div><div class="info-row__value">Takip ettiğin kediler için açık</div></div></div>' +
    '<div class="info-row"><div class="info-row__icon">'+icon('compass',{size:18})+'</div><div><div class="info-row__label">Dil</div><div class="info-row__value">Türkçe</div></div></div>' +

    '<h3 class="eyebrow mt-6 mb-2">Güven ve hesap</h3>' +
    '<div class="info-row"><div class="info-row__icon">'+icon('phone',{size:18})+'</div><div><div class="info-row__label">Doğrulanmış numara</div><div class="info-row__value">'+esc(state.session.phone||'')+'</div></div></div>' +

    '<div class="future-note mt-6">'+icon('compass',{size:15})+
      '<span><b>Rozet sistemi</b> henüz ürün kararı aşamasında (issue #10) — kötüye kullanım riski netleşmeden eklenmeyecek.</span>' +
    '</div>' +

    '<button class="btn btn-secondary btn-block mt-6" data-action="logout">'+icon('logout',{size:16})+' Çıkış yap</button>'
  );
}
function accountGuestBody(){
  return (
    '<div class="state-block" style="padding:var(--space-8) 0;">' +
      '<div class="state-block__icon">'+icon('user',{size:22})+'</div>' +
      '<div class="state-block__title">Giriş yapmadın</div>' +
      '<div class="state-block__body">Fotoğraf eklemek, yeni kedi eklemek ve yardım bildirimi oluşturmak için giriş yapman gerekir. Haritayı ve kedi detaylarını girişsiz gezebilirsin.</div>' +
      '<button class="btn btn-primary mt-2" data-action="go-login-generic">Giriş yap</button>' +
    '</div>'
  );
}

/* ============================================================ SCREEN: login */
function renderLogin(){
  var el = screenEl('login');
  if(!state._loginForm) state._loginForm = { phone:'', codeSent:false, code:'', sending:false };
  var f = state._loginForm;
  el.innerHTML =
    topbar('Giriş yap', { close:true, closeAction:'cancel-login' }) +
    '<div class="screen-body">' +
      '<div class="login-hero">' +
        '<div class="login-hero__icon">'+icon('phone',{size:24})+'</div>' +
        '<h2>Telefon ile giriş yap</h2>' +
      '</div>' +
      (state.loginContext ? '<div class="login-context mb-4">'+icon('phone',{size:16})+'<span>'+esc(state.loginContext)+'</span></div>' : '') +
      '<div class="field mb-4">' +
        '<span class="field-label">Telefon numarası</span>' +
        '<div class="row-gap">' +
          '<span class="text-muted" style="font-weight:600;padding:0 4px;">+90</span>' +
          '<input class="input" style="flex:1;" type="tel" inputmode="numeric" placeholder="5xx xxx xx xx" value="'+esc(f.phone)+'" data-action="login-phone">' +
        '</div>' +
      '</div>' +
      (!f.codeSent ?
        '<button class="btn btn-primary btn-block" data-action="send-code"'+(f.sending?' aria-disabled="true"':'')+'>'+(f.sending?'<span class="spinner"></span>':'Kod gönder')+'</button>'
        :
        '<div class="field mb-4"><span class="field-label">Doğrulama kodu</span>' +
          '<input class="input code-boxes" type="text" inputmode="numeric" maxlength="6" placeholder="------" value="'+esc(f.code)+'" data-action="login-code">' +
        '</div>' +
        '<button class="btn btn-primary btn-block" data-action="do-login"'+(f.sending?' aria-disabled="true"':'')+'>'+(f.sending?'<span class="spinner"></span>':'Giriş yap')+'</button>'
      ) +
      '<button class="btn btn-ghost btn-block mt-3" data-action="cancel-login">Vazgeç</button>' +
    '</div>';
}
function sendCode(){
  var f = state._loginForm;
  if(!f.phone || f.phone.replace(/\D/g,'').length < 10){ toast('Geçerli bir telefon numarası gir', {icon:'alertTriangle'}); return; }
  f.sending = true; renderLogin();
  setTimeout(function(){ f.sending = false; f.codeSent = true; renderLogin(); }, 500);
}
function doLogin(){
  var f = state._loginForm;
  if(!f.code || f.code.length < 4){ toast('Kodu eksiksiz gir', {icon:'alertTriangle'}); return; }
  f.sending = true; renderLogin();
  setTimeout(function(){
    state.session.loggedIn = true;
    state.session.phone = '+90 '+f.phone;
    state._loginForm = null;
    var pending = state.pendingAction; state.pendingAction = null; state.loginContext = '';
    toast('Giriş yapıldı', {icon:'check'});
    if(pending && pending.type === 'submit-update'){ replaceScreen('add-update'); submitUpdate(); }
    else if(pending && pending.type === 'start-add-cat'){ navigate('add-loc'); }
    else { goBack(); }
  }, 500);
}
function cancelLogin(){
  state._loginForm = null; state.pendingAction = null; state.loginContext = '';
  goBack();
}

/* ============================================================ event delegation */
document.addEventListener('click', function(e){
  var t = e.target.closest('[data-action]');
  if(!t) return;
  var action = t.getAttribute('data-action');

  switch(action){
    case 'go-tab': navigate(t.getAttribute('data-target'), {root:true}); break;
    case 'back': goBack(); break;
    case 'select-marker': selectCat(t.getAttribute('data-cat')); break;
    case 'close-sheet': closeSheet(); break;
    case 'open-detail':
      // order matters: closeSheet() itself sets selectedCatId back to null (it's also used to
      // un-highlight the map marker when the sheet closes), so it has to run before this
      // assigns the cat we're actually navigating to, not after
      closeSheet(); state.selectedCatId = t.getAttribute('data-cat'); navigate('detail'); break;
    case 'hero-photo-prev':
      state.detailPhotoIndex = Math.max(0, (state.detailPhotoIndex||0) - 1); renderDetail(); break;
    case 'hero-photo-next': {
      var dcat = findCat(state.selectedCatId);
      state.detailPhotoIndex = Math.min(dcat.photos.length - 1, (state.detailPhotoIndex||0) + 1);
      renderDetail(); break;
    }
    case 'toggle-follow': {
      var cat = findCat(t.getAttribute('data-cat'));
      cat.followed = !cat.followed;
      toast(cat.followed ? 'Takip ediyorsun' : 'Takipten çıkıldı', {icon:'heart'});
      renderScreen(state.currentScreen);
      break;
    }
    case 'go-add-cat':
      if(!state.session.loggedIn){ requireLogin('Kedi eklemek için giriş yap', { type:'start-add-cat' }); }
      else { state.draftCat = null; navigate('add-loc'); }
      break;
    case 'go-add-update':
      state.selectedCatId = t.getAttribute('data-cat');
      state.draftUpdate = { catId:state.selectedCatId, kind:t.getAttribute('data-type')||'update', status:'sighting', comment:'', photo:null, submitting:false, error:false };
      navigate('add-update');
      break;
    case 'set-update-kind': state.draftUpdate.kind = t.getAttribute('data-kind'); renderAddUpdate(); break;
    case 'set-status': state.draftUpdate.status = t.getAttribute('data-status'); renderAddUpdate(); break;
    case 'submit-update': submitUpdate(); break;
    case 'use-current-location': useCurrentLocation(); break;
    case 'confirm-location': confirmLocation(); break;
    case 'dup-yes': closeDuplicateModal(); state.selectedCatId = t.getAttribute('data-cat'); navigate('detail', {root:true}); break;
    case 'dup-no': closeDuplicateModal(); navigate('add-detail'); break;
    case 'save-cat': saveCat(); break;
    case 'discover-tab': state.discoverTab = t.getAttribute('data-tab'); renderDiscover(); break;
    case 'toggle-discover-help-filter': state.discoverHelpFilter = !state.discoverHelpFilter; renderDiscover(); break;
    case 'toggle-map-help-filter':
      state.mapHelpFilter = !state.mapHelpFilter;
      t.classList.toggle('is-on', state.mapHelpFilter);
      t.setAttribute('aria-pressed', String(state.mapHelpFilter));
      updateMapMarkersDom();
      break;
    case 'logout': state.session.loggedIn = false; state.session.phone = null; toast('Çıkış yapıldı', {icon:'logout'}); renderAccount(); break;
    case 'go-login-generic': requireLogin('Hesabına giriş yap', null); break;
    case 'send-code': sendCode(); break;
    case 'do-login': doLogin(); break;
    case 'cancel-login': cancelLogin(); break;
  }
});

document.addEventListener('input', function(e){
  var t = e.target.closest('[data-action]'); if(!t) return;
  var action = t.getAttribute('data-action');
  if(action === 'draft-comment') state.draftUpdate.comment = t.value;
  else if(action === 'login-phone') state._loginForm.phone = t.value;
  else if(action === 'login-code') state._loginForm.code = t.value;
  else if(action === 'cat-name') state.draftCat.name = t.value;
});

document.addEventListener('change', function(e){
  var t = e.target.closest('[data-action]'); if(!t) return;
  var action = t.getAttribute('data-action');
  if((action === 'draft-photo' || action === 'cat-photo') && t.files && t.files[0]){
    var reader = new FileReader();
    reader.onload = function(ev){
      if(action === 'draft-photo'){ state.draftUpdate.photo = ev.target.result; renderAddUpdate(); }
      else { state.draftCat.photo = ev.target.result; renderAddDetail(); }
    };
    reader.readAsDataURL(t.files[0]);
  }
});

// simulated mobile-keyboard-open state for the login screen (see .login-hero in styles.css) —
// focusin/focusout bubble (unlike focus/blur) so a single delegated listener works here
document.addEventListener('focusin', function(e){
  if(e.target.matches && e.target.matches('[data-action=login-phone], [data-action=login-code]')){
    screenEl('login').classList.add('is-keyboard-open');
  }
});
document.addEventListener('focusout', function(e){
  if(e.target.matches && e.target.matches('[data-action=login-phone], [data-action=login-code]')){
    screenEl('login').classList.remove('is-keyboard-open');
  }
});

/* ============================================================ boot */
document.addEventListener('DOMContentLoaded', function(){
  navigate('map', { root:true });
});
})();
