/* cats istanbul — hi-fi clickable prototype. no framework, no build step. */
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
    id:'portakal', name:'Portakal', traits:['sarman','kısa tüylü','dost canlısı'],
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
    id:'zeytin', name:'Zeytin', traits:['kızıl','kısa tüylü'],
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
    id:'sultan', name:'Sultan', traits:['tekir','kısa tüylü','sakin'],
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
    id:'balat-beyaz', name:null, traits:['beyaz-kızıl','uzun tüylü'],
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
    id:'yavru', name:'Yavru', traits:['tekir','kısa tüylü','ürkek'],
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
    id:'kaplan', name:'Kaplan', traits:['tekir','kısa tüylü'],
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
  }
];
var DUPLICATE_DEMO_CAT_ID = 'portakal'; // add-cat location picker starts near this cat, to demo the duplicate check

function findCat(id){ for(var i=0;i<CATS.length;i++) if(CATS[i].id===id) return CATS[i]; return null; }
function catDisplayName(cat){ return cat.name || (cat.traits[0].charAt(0).toUpperCase()+cat.traits[0].slice(1)+' kedi'); }
function statusVocabOf(id){ for(var i=0;i<STATUS_VOCAB.length;i++) if(STATUS_VOCAB[i].id===id) return STATUS_VOCAB[i]; return null; }

/* ============================================================ app state */
var state = {
  session:{ loggedIn:false, phone:null },
  screenStack:[],
  currentScreen:'map',
  selectedCatId:null,
  sheetOpen:false,
  discoverTab:'nearby',
  discoverHelpFilter:false,
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
function markerHTML(cat, selected){
  var help = cat.needsHelp.active;
  return '<div class="marker'+(selected?' is-selected':'')+(help?' needs-help':'')+'" data-action="select-marker" data-cat="'+cat.id+'" role="button" tabindex="0" aria-label="'+esc(catDisplayName(cat))+' konumu">'+
    '<img src="'+cat.photo+'" alt="" onerror="onImgErr(this)">' +
    (help ? '<span class="marker-badge">'+icon('alertTriangle',{size:9})+'</span>' : '') +
  '</div>';
}

/* ============================================================ SCREEN: map */
var leafletMap = null, leafletMarkers = {}, leafletFailed = false;

function renderMap(){
  var el = screenEl('map');
  if(el.dataset.built === '1'){ updateMapMarkersDom(); return; }
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
          '<button class="chip'+(state.discoverHelpFilter?' is-on is-warm':'')+'" data-action="toggle-map-help-filter">'+icon('alertTriangle',{size:14})+' yardım gerekiyor</button>' +
        '</div>' +
      '</div>' +
      '<button class="fab" data-action="go-add-cat" aria-label="yeni kedi ekle" style="position:absolute;right:'+'20px;bottom:104px;">'+icon('plus',{size:24})+'</button>' +
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

function initLeaflet(){
  if(leafletMap || leafletFailed) return;
  if(typeof L === 'undefined'){ leafletFailed = true; showMapFallback(); return; }
  try{
    leafletMap = L.map('leafletMap', { zoomControl:false, attributionControl:false }).setView([40.9822,29.0288], 15.7);
    var tiles = L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom:19 });
    tiles.on('tileerror', function(){ if(!leafletFailed){ leafletFailed = true; showMapFallback(); } });
    tiles.addTo(leafletMap);
    L.control.zoom({ position:'bottomright' }).addTo(leafletMap);
    leafletMap.on('click', function(){ closeSheet(); });
    CATS.forEach(addLeafletMarker);
    addLeafletCluster();
  }catch(e){ leafletFailed = true; showMapFallback(); }
}
function addLeafletMarker(cat){
  var divIcon = L.divIcon({ className:'', html:markerHTML(cat, cat.id===state.selectedCatId), iconSize:[40,40], iconAnchor:[20,20] });
  var m = L.marker([cat.mapPos.lat, cat.mapPos.lng], { icon:divIcon, keyboard:false, alt:catDisplayName(cat) }).addTo(leafletMap);
  m.on('click', function(e){ if(e.originalEvent) e.originalEvent.stopPropagation(); selectCat(cat.id); });
  leafletMarkers[cat.id] = m;
}
function addLeafletCluster(){
  var html = '<div class="marker-cluster" data-action="cluster-tap" role="button" tabindex="0" aria-label="bölgedeki diğer kediler">'+icon('pin',{size:14})+'<span>+4</span></div>';
  var divIcon = L.divIcon({ className:'', html:html, iconSize:[46,42], iconAnchor:[23,21] });
  var m = L.marker([40.9865,29.0312], { icon:divIcon, keyboard:false }).addTo(leafletMap);
  m.on('click', function(e){ if(e.originalEvent) e.originalEvent.stopPropagation(); toast('Bu bölgede 4 kedi daha var, yakınlaştırarak görebilirsin.', {icon:'compass'}); });
}
function showMapFallback(){
  var fb = $('#mapFallback'); var lm = $('#leafletMap');
  if(fb){ fb.hidden = false; }
  if(lm){ lm.style.display = 'none'; }
}
function updateMapMarkersDom(){
  if(leafletMap && !leafletFailed){
    CATS.forEach(function(cat){
      var m = leafletMarkers[cat.id]; if(!m) return;
      var sel = cat.id === state.selectedCatId;
      m.setIcon(L.divIcon({ className:'', html:markerHTML(cat, sel), iconSize: sel?[56,56]:[40,40], iconAnchor: sel?[28,28]:[20,20] }));
    });
    return;
  }
  var wrap = $('#mapMarkers'); if(!wrap) return;
  var html = CATS.map(function(cat){
    var sel = cat.id === state.selectedCatId;
    return '<div style="position:absolute;top:'+cat.fallbackPos.top+';left:'+cat.fallbackPos.left+';transform:translate(-50%,-50%);">'+markerHTML(cat, sel)+'</div>';
  }).join('') +
  '<div style="position:absolute;top:30%;left:80%;transform:translate(-50%,-50%);"><div class="marker-cluster" data-action="cluster-tap">'+icon('pin',{size:14})+'<span>+4</span></div></div>';
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
  var el = screenEl('detail');
  el.innerHTML =
    '<div class="screen-scroll-flat">' +
      '<div class="hero-photo">' +
        '<img src="'+cat.photo+'" alt="'+esc(catDisplayName(cat))+'" onerror="onImgErr(this)">' +
        '<div class="hero-photo__scrim"></div>' +
        '<div class="hero-photo__topbar">' +
          '<button class="btn-icon on-glass" data-action="back" aria-label="geri">'+icon('chevronLeft',{size:19})+'</button>' +
          '<button class="btn-icon on-glass'+(cat.followed?' filled':'')+'" data-action="toggle-follow" data-cat="'+cat.id+'" aria-label="'+(cat.followed?'takibi bırak':'takip et')+'" aria-pressed="'+cat.followed+'">'+icon('heart',{size:18, filled:cat.followed})+'</button>' +
        '</div>' +
        '<div class="hero-photo__caption">' +
          '<div class="hero-photo__name">'+esc(catDisplayName(cat))+'</div>' +
          '<div class="hero-photo__loc">'+icon('pin',{size:13})+esc(cat.areaLabel)+'</div>' +
        '</div>' +
        '<div class="hero-dots">'+cat.photos.map(function(_,i){ return '<span class="'+(i===0?'is-on':'')+'"></span>'; }).join('')+'</div>' +
      '</div>' +
      '<div class="screen-body mt-4">' +
        '<div class="chip-row mb-4">'+cat.traits.map(function(t){ return '<span class="chip">'+esc(t)+'</span>'; }).join('')+'</div>' +

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
          '<div class="action-row">' +
            '<button class="btn btn-secondary" data-action="toggle-follow" data-cat="'+cat.id+'">'+icon('heart',{size:16, filled:cat.followed})+' '+(cat.followed?'Takip ediliyor':'Takip et')+'</button>' +
            '<button class="btn btn-warm" data-action="go-add-update" data-cat="'+cat.id+'" data-type="help">'+icon('alertTriangle',{size:16})+' Yardıma ihtiyacı var</button>' +
          '</div>' +
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
    state.draftCat = { lat:seed.mapPos.lat, lng:seed.mapPos.lng, geoError:'', photo:null, traits:[], name:'', saving:false };
  }
  var d = state.draftCat;
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
function initLocationMap(){
  var el = $('#locationMap'); if(!el || locMap) { if(locMap) locMap.invalidateSize(); return; }
  if(typeof L === 'undefined'){ locMapFailed = true; var fb=$('#locFallback'); if(fb) fb.hidden=false; return; }
  try{
    locMap = L.map('locationMap', { zoomControl:false, attributionControl:false, dragging:true })
      .setView([state.draftCat.lat, state.draftCat.lng], 17);
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom:19 }).addTo(locMap);
    locMap.on('moveend', function(){ var c = locMap.getCenter(); state.draftCat.lat = c.lat; state.draftCat.lng = c.lng; });
  }catch(e){ locMapFailed = true; var fb2=$('#locFallback'); if(fb2) fb2.hidden=false; }
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
  navigator.geolocation.getCurrentPosition(function(){
    d.geoError = '';
    toast('Konumun bulundu', {icon:'location'});
    renderAddLoc();
  }, function(){
    d.geoError = 'Konum izni reddedildi. Haritadan elle seçebilirsin.';
    renderAddLoc();
  }, { timeout:6000 });
}
function confirmLocation(){
  var d = state.draftCat;
  var near = locMapFailed || typeof L === 'undefined' ? findCat(DUPLICATE_DEMO_CAT_ID)
    : CATS.filter(function(c){ return distanceMeters(c.mapPos, {lat:d.lat,lng:d.lng}) < 80; })[0];
  if(near){ openDuplicateModal(near); return; }
  navigate('add-detail');
}
function openDuplicateModal(cat){
  var modal = $('#dupModal');
  modal.innerHTML = '<div class="modal-card">' +
    '<div class="modal-card__title">Bu bölgede zaten kayıtlı bir kedi var: '+esc(catDisplayName(cat))+'. Gördüğün kedi bu mu?</div>' +
    '<div class="modal-card__actions">' +
      '<button class="btn btn-secondary" data-action="dup-no">Hayır, farklı kedi</button>' +
      '<button class="btn btn-primary" data-action="dup-yes" data-cat="'+cat.id+'">Evet, bu o</button>' +
    '</div></div>';
  modal.classList.add('is-open');
}
function closeDuplicateModal(){ var m=$('#dupModal'); if(m) m.classList.remove('is-open'); }

/* ============================================================ SCREEN: add cat — details */
function renderAddDetail(){
  var el = screenEl('add-detail');
  var d = state.draftCat || { photo:null, traits:[], name:'', saving:false };
  var TRAIT_OPTIONS = ['sarman','tekir','siyah-beyaz','kızıl','uzun tüylü','kısa tüylü','dost canlısı','çekingen'];
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
      '<div class="field-label mb-2">Fiziksel özellikler</div>' +
      '<div class="chip-row mb-4">' +
        TRAIT_OPTIONS.map(function(t){ return '<button class="chip'+(d.traits.indexOf(t)>-1?' is-on':'')+'" data-action="toggle-trait" data-trait="'+t+'">'+esc(t)+'</button>'; }).join('') +
      '</div>' +
      '<div class="field mb-6">' +
        '<span class="field-label">İsim (opsiyonel)</span>' +
        '<input class="input" type="text" placeholder="Henüz adı yoksa boş bırakabilirsin" value="'+esc(d.name)+'" data-action="cat-name">' +
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
      id:id, name: d.name.trim() || null, traits: d.traits.length ? d.traits : ['sokak kedisi'],
      photo:d.photo, photos:[d.photo],
      mapPos:{lat:d.lat, lng:d.lng}, fallbackPos:{top:'50%',left:'50%'},
      areaLabel:'Kadıköy çevresi',
      lastSeenShort:'az önce', lastSeenFull:'az önce eklendi', freshness:'fresh',
      condition:'Yeni eklendi.', water:'Bilinmiyor', food:'Bilinmiyor',
      needsHelp:{active:false, sinceText:''}, followed:false,
      updates:[{ type:'sighting', comment:'Yeni kedi olarak eklendi.', photo:d.photo, timeText:'az önce' }]
    };
    CATS.push(newCat);
    if(leafletMap && !leafletFailed) addLeafletMarker(newCat);
    state.draftCat = null;
    state.selectedCatId = newCat.id;
    toast('Kedi eklendi', {icon:'check'});
    screenEl('map').dataset.built = '';
    navigate('map', { root:true });
    openSheet(newCat.id);
  }, 700);
}

/* ============================================================ SCREEN: discover */
function renderDiscover(){
  var el = screenEl('discover');
  var list = CATS.slice();
  if(state.discoverTab === 'favorites') list = list.filter(function(c){ return c.followed; });
  if(state.discoverHelpFilter) list = list.filter(function(c){ return c.needsHelp.active; });

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
        '<div>' + list.map(function(c,i){
          return (i>0?'<div class="list-divider"></div>':'') +
          '<div class="cat-card" data-action="open-detail" data-cat="'+c.id+'">' +
            '<img class="cat-card__photo" src="'+c.photo+'" alt="" onerror="onImgErr(this)">' +
            '<div class="cat-card__body"><div class="cat-card__name">'+esc(catDisplayName(c))+'</div><div class="cat-card__meta">'+esc(c.traits.join(', '))+'</div></div>' +
            '<div class="cat-card__aside">' + freshnessBadge(c) + '</div>' +
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
  var followed = CATS.filter(function(c){ return c.followed; });
  el.innerHTML =
    topbar('Hesap', {}) +
    '<div class="screen-body">' +
      (state.session.loggedIn ?
        '<div class="stack-sm mb-4">' +
          '<div class="eyebrow">Giriş yapıldı</div>' +
          '<div class="text-muted" style="font-size:var(--text-sm);">'+esc(state.session.phone||'')+'</div>' +
        '</div>' +
        '<div class="eyebrow mb-2">Takip ettiklerin</div>' +
        (followed.length ?
          followed.map(function(c){ return '<div class="followed-row" data-action="open-detail" data-cat="'+c.id+'"><img src="'+c.photo+'" alt="" onerror="onImgErr(this)"><span style="font-weight:600;">'+esc(catDisplayName(c))+'</span></div>'; }).join('')
          : '<p class="text-muted" style="font-size:var(--text-sm);">Henüz kimseyi takip etmiyorsun.</p>') +
        '<button class="btn btn-secondary btn-block mt-6" data-action="logout">'+icon('logout',{size:16})+' Çıkış yap</button>'
        :
        '<div class="state-block" style="padding:var(--space-8) 0;">' +
          '<div class="state-block__icon">'+icon('user',{size:22})+'</div>' +
          '<div class="state-block__title">Giriş yapmadın</div>' +
          '<div class="state-block__body">Fotoğraf eklemek, yeni kedi eklemek ve yardım bildirimi oluşturmak için giriş yapman gerekir. Haritayı ve kedi detaylarını girişsiz gezebilirsin.</div>' +
          '<button class="btn btn-primary mt-2" data-action="go-login-generic">Giriş yap</button>' +
        '</div>'
      ) +
    '</div>' +
    bottomNav('account');
}

/* ============================================================ SCREEN: login */
function renderLogin(){
  var el = screenEl('login');
  if(!state._loginForm) state._loginForm = { phone:'', codeSent:false, code:'', sending:false };
  var f = state._loginForm;
  el.innerHTML =
    topbar('Giriş yap', { close:true, closeAction:'cancel-login' }) +
    '<div class="screen-body">' +
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
      state.selectedCatId = t.getAttribute('data-cat'); closeSheet(); navigate('detail'); break;
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
    case 'toggle-trait': {
      var trait = t.getAttribute('data-trait'); var d = state.draftCat;
      var idx = d.traits.indexOf(trait);
      if(idx>-1) d.traits.splice(idx,1); else d.traits.push(trait);
      renderAddDetail(); break;
    }
    case 'save-cat': saveCat(); break;
    case 'discover-tab': state.discoverTab = t.getAttribute('data-tab'); renderDiscover(); break;
    case 'toggle-discover-help-filter': state.discoverHelpFilter = !state.discoverHelpFilter; renderDiscover(); break;
    case 'toggle-map-help-filter': state.discoverHelpFilter = !state.discoverHelpFilter; toast('Harita filtresi keşfet ekranında da geçerli', {icon:'filter'}); break;
    case 'logout': state.session.loggedIn = false; state.session.phone = null; toast('Çıkış yapıldı', {icon:'logout'}); renderAccount(); break;
    case 'go-login-generic': requireLogin('Hesabına giriş yap', null); break;
    case 'send-code': sendCode(); break;
    case 'do-login': doLogin(); break;
    case 'cancel-login': cancelLogin(); break;
    case 'cluster-tap': toast('Bu bölgede 4 kedi daha var, yakınlaştırarak görebilirsin.', {icon:'compass'}); break;
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

/* ============================================================ boot */
document.addEventListener('DOMContentLoaded', function(){
  navigate('map', { root:true });
});
})();
