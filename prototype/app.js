/*
  tekir prototype — screens, state, navigation, event delegation.
  no framework, no build step. relies on globals from icons.js, data.js and map.js
  (loaded first, see index.html) — not wrapped in an IIFE on purpose, so map.js can
  call back into state/selectCat/closeSheet/esc/icon defined here.
*/
'use strict';

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

/* ============================================================ app state */
var state = {
  session:{ loggedIn:false, user:null },
  locationGranted: null,          // null = not asked yet, true/false after the permission screen
  notificationsEnabled: true,
  demoOffline: false,             // prototype-only demo lever, see screen-settings
  screenStack:[],
  currentScreen:'splash',
  selectedCatId:null,
  selectedBadgeId:null,
  sheetOpen:false,
  discoverTab:'nearby',           // nearby | help | following — docs/product/discovery.md
  mapHelpFilter:false,
  pendingAction:null,             // {type, payload} to resume once login succeeds
  loginContext:'',
  draftUpdate:null,
  draftHelp:null,
  draftCat:null,
  detailPhotoIndex:0,
  _detailPhotoCat:null,
  notifPermAsked:false,
  retryDemoShown:false,           // one-time simulated submit failure, demonstrates the error/retry state
  newCatSeq:1,
  _loginForm:null,
  _splashTimer:null
};

function currentUser(){ return state.session.loggedIn ? state.session.user : null; }
function isLoggedIn(){ return !!state.session.loggedIn; }
function isFollowing(cat){ var u = currentUser(); return !!u && u.follows.indexOf(cat.id) !== -1; }

/* ============================================================ router */
function screenEl(id){ return document.getElementById('screen-'+id); }

/* inactive screens are only opacity/pointer-events hidden (so the slide transition can animate),
   which leaves their buttons keyboard-focusable and screen-reader-visible. `inert` removes a
   screen from focus and the accessibility tree entirely while it's off-stage. */
function activateScreen(id){
  $all('.screen').forEach(function(s){ s.classList.remove('is-active'); s.inert = true; });
  var el = screenEl(id);
  el.classList.add('is-active');
  el.inert = false;
  return el;
}

function navigate(id, opts){
  opts = opts || {};
  if(opts.root){ state.screenStack = []; }
  else if(state.currentScreen && state.currentScreen !== id){ state.screenStack.push(state.currentScreen); }
  state.currentScreen = id;
  var el = activateScreen(id);
  renderScreen(id);
  var body = el.querySelector('.screen-body, .screen-scroll-flat');
  if(body) body.scrollTop = 0;
  updateNavActiveState();
}
function replaceScreen(id){
  state.currentScreen = id;
  activateScreen(id);
  renderScreen(id);
  updateNavActiveState();
}
function goBack(){
  var prev = state.screenStack.pop();
  if(!prev){ navigate('map', {root:true}); return; }
  state.currentScreen = prev;
  activateScreen(prev);
  renderScreen(prev);
  updateNavActiveState();
}
function updateNavActiveState(){
  $all('.nav-item[data-tab]').forEach(function(b){
    b.classList.toggle('is-active', b.getAttribute('data-tab') === state.currentScreen);
  });
}

/* ============================================================ auth */
/* every write action (update, needs-help, add cat, follow) gates here at the moment the
   user expresses intent — before any form is shown — per docs/product/trust.md: posting,
   adding media/cats and following all require a phone-verified authenticated account. */
function requireLogin(context, pendingAction){
  state.loginContext = context;
  state.pendingAction = pendingAction;
  openAuthSheet();
}
function openAuthSheet(){
  var modal = $('#authSheet');
  modal.innerHTML =
    '<div class="modal-card">' +
      '<div class="login-hero__icon" style="margin:0 auto;">'+icon('phone',{size:22})+'</div>' +
      '<div class="modal-card__title" style="text-align:center;">'+esc(state.loginContext || 'Bu işlem için giriş yapman gerekiyor')+'</div>' +
      '<div class="modal-card__actions">' +
        '<button class="btn btn-secondary" data-action="close-auth-sheet">Vazgeç</button>' +
        '<button class="btn btn-primary" data-action="go-login-screen">Giriş yap</button>' +
      '</div>' +
    '</div>';
  modal.classList.add('is-open');
  modal.inert = false;
}
function closeAuthSheet(){ var m=$('#authSheet'); if(m){ m.classList.remove('is-open'); m.inert = true; } }

function resumePendingAction(pending){
  if(!pending){ goBack(); return; }
  if(pending.type === 'start-add-cat'){ state.draftCat = null; navigate('add-loc', {root:true}); }
  else if(pending.type === 'start-add-update'){ openAddUpdate(pending.payload.catId); }
  else if(pending.type === 'start-add-help'){ openHelp(pending.payload.catId); }
  else if(pending.type === 'quick-seen'){ goBack(); quickSeen(pending.payload.catId); }
  else if(pending.type === 'toggle-follow'){ goBack(); toggleFollow(pending.payload.catId); }
  else { goBack(); }
}

/* ============================================================ render dispatch */
function renderScreen(id){
  if(id==='splash') renderSplash();
  else if(id==='perm') renderPerm();
  else if(id==='map') renderMap();
  else if(id==='detail') renderDetail();
  else if(id==='history') renderHistory();
  else if(id==='add-update') renderAddUpdate();
  else if(id==='help') renderHelp();
  else if(id==='add-loc') renderAddLoc();
  else if(id==='add-detail') renderAddDetail();
  else if(id==='discover') renderDiscover();
  else if(id==='profile') renderProfile();
  else if(id==='badges') renderBadges();
  else if(id==='badge-detail') renderBadgeDetail();
  else if(id==='settings') renderSettings();
  else if(id==='login') renderLogin();
}

/* ============================================================ shared bits */
function bottomNav(active){
  return '' +
  '<nav class="bottom-nav" aria-label="ana gezinme">' +
    navBtn('map','map','Harita',active) +
    navBtn('discover','compass','Keşfet',active) +
    '<button class="nav-item nav-fab" data-action="go-add-cat" aria-label="kedi ekle">' +
      '<span class="nav-fab__circle">'+icon('plus',{size:22})+'</span>' +
    '</button>' +
    navBtn('profile','user','Profil',active) +
  '</nav>';
}
function navBtn(id,iconName,label,active){
  return '<button class="nav-item'+(active===id?' is-active':'')+'" data-tab="'+id+'" data-action="go-tab" data-target="'+id+'">'+
    icon(iconName,{size:22})+'<span>'+label+'</span></button>';
}
function topbar(title, opts){
  opts = opts || {};
  var left = opts.close ? '<button class="btn-icon" data-action="'+(opts.closeAction||'back')+'" aria-label="kapat">'+icon('close',{size:18})+'</button>'
           : (opts.back ? '<button class="btn-icon" data-action="back" aria-label="geri">'+icon('chevronLeft',{size:20})+'</button>' : '<span style="width:44px;"></span>');
  var right = opts.right || '<span style="width:44px;"></span>';
  return '<div class="topbar align-left"><div class="row-gap">'+left+'</div><div class="topbar__title">'+esc(title)+'</div>'+right+'</div>';
}
function freshnessBadge(cat){
  var alert = activeAlert(cat);
  if(alert){
    var r = helpReasonOf(alert.helpReason);
    return '<span class="badge badge-help">'+icon('alertTriangle',{size:12})+(r?esc(r.label):'Yardım gerekiyor')+' · '+esc(fmtTimeAgo(alert.createdAt))+'</span>';
  }
  var meta = FRESHNESS_META[freshnessOf(cat)];
  return '<span class="badge '+meta.badgeCls+'"><span class="badge-dot"></span>'+esc(lastSeenText(cat))+'</span>';
}
function emptyState(title, body, iconName){
  return '<div class="state-block"><div class="state-block__icon">'+icon(iconName||'compass',{size:22})+'</div>' +
    '<div class="state-block__title">'+esc(title)+'</div><div class="state-block__body">'+esc(body)+'</div></div>';
}
function errorBlockHTML(){
  return '<div class="state-block is-error" style="padding:var(--space-4) 0;text-align:left;align-items:flex-start;">' +
      '<div class="row-gap"><div class="state-block__icon" style="width:36px;height:36px;">'+icon('alertTriangle',{size:16})+'</div>' +
      '<div><div class="state-block__title" style="font-size:var(--text-sm);">Gönderilemedi</div>' +
      '<div class="state-block__body" style="text-align:left;">'+(state.demoOffline ? 'Çevrimdışısın. Bağlantı gelince tekrar dene.' : 'Bağlantı sorunu oldu. Tekrar dener misin?')+'</div></div></div>' +
    '</div>';
}
/* shared "submit" simulator for update / help / add-cat: brief pending state, then either an
   always-fail while the offline demo toggle is on, a one-time simulated failure (so the review
   can see the error + retry state), or success. */
function simulateSubmit(cb){
  setTimeout(function(){
    if(state.demoOffline){ cb(false); return; }
    if(!state.retryDemoShown){ state.retryDemoShown = true; cb(false); return; }
    cb(true);
  }, 700);
}
function announceNewBadges(before, after){
  var newly = after.filter(function(a,i){ return a.earned && !before[i].earned; });
  if(!newly.length) return;
  setTimeout(function(){
    toast('Yeni rozet: ' + newly.map(function(b){ return b.def.name; }).join(', '), {icon:'award'});
  }, 1000);
}
function timelineItemHTML(u, showLine){
  var expired = isExpiredAlert(u);
  var label, iconName;
  if(u.kind === 'help'){
    var r = helpReasonOf(u.helpReason);
    label = (r ? r.label : 'Yardım gerekiyor') + (expired ? ' (süresi doldu)' : '');
    iconName = r ? r.icon : 'alertTriangle';
  } else {
    label = u.statuses.map(function(s){ var v = statusVocabOf(s); return v ? v.label : s; }).join(', ');
    var firstVocab = statusVocabOf(u.statuses[0]);
    iconName = firstVocab ? firstVocab.icon : 'edit';
  }
  return '<div class="timeline-item'+(u.kind==='help' && !expired ? ' is-help' : '')+'">' +
      '<div class="timeline-item__rail"><span class="timeline-item__dot"></span>'+(showLine?'<span class="timeline-item__line"></span>':'')+'</div>' +
      '<div class="timeline-item__body">' +
        '<div class="timeline-item__head"><span class="timeline-item__type">'+esc(label)+'</span><span class="timeline-item__time">'+esc(fmtTimeAgo(u.createdAt))+'</span></div>' +
        '<div class="text-faint" style="font-size:var(--text-2xs);margin-top:1px;">'+esc(u.authorName)+'</div>' +
        (u.comment ? '<div class="timeline-item__comment">"'+esc(u.comment)+'"</div>' : '') +
        (u.photo ? '<img class="timeline-item__photo" src="'+u.photo+'" alt="" onerror="onImgErr(this)">' : '') +
      '</div>' +
    '</div>';
}

/* ============================================================ SCREEN: splash */
function renderSplash(){
  var el = screenEl('splash');
  el.innerHTML =
    '<div class="splash-screen">' +
      '<div class="splash-screen__mark">'+icon('paw',{size:44})+'</div>' +
      '<div class="splash-screen__word">tekir</div>' +
      '<div class="splash-screen__tag">İstanbul\'un sokak kedilerini keşfet, onlara göz kulak ol.</div>' +
    '</div>';
  clearTimeout(state._splashTimer);
  state._splashTimer = setTimeout(function(){
    if(state.currentScreen !== 'splash') return;
    navigate(state.locationGranted === null ? 'perm' : 'map', { root:true });
  }, 1100);
}

/* ============================================================ SCREEN: location permission */
function renderPerm(){
  var el = screenEl('perm');
  el.innerHTML =
    '<div class="perm-screen">' +
      '<div class="perm-screen__body">' +
        '<div class="perm-screen__icon">'+icon('location',{size:32})+'</div>' +
        '<div class="perm-screen__title">Konumunu kullanabilir miyiz?</div>' +
        '<p>Yakınındaki kedileri gösterebilmemiz için konumuna ihtiyacımız var. İzin vermezsen haritayı Kadıköy merkezli görebilirsin.</p>' +
      '</div>' +
      '<div class="perm-screen__actions">' +
        '<button class="btn btn-primary btn-block" data-action="grant-location">Konuma izin ver</button>' +
        '<button class="btn btn-ghost btn-block" data-action="deny-location">Şimdi değil</button>' +
      '</div>' +
    '</div>';
}
function grantLocation(){
  if(navigator.geolocation){
    navigator.geolocation.getCurrentPosition(function(pos){
      USER_APPROX_LOCATION = { lat:pos.coords.latitude, lng:pos.coords.longitude };
      state.locationGranted = true;
      navigate('map', { root:true });
    }, function(){
      state.locationGranted = false;
      toast('Konum izni reddedildi', {icon:'alertTriangle'});
      navigate('map', { root:true });
    }, { timeout:6000 });
  } else {
    state.locationGranted = false;
    navigate('map', { root:true });
  }
}
function denyLocation(){ state.locationGranted = false; navigate('map', { root:true }); }
function toggleLocationPermission(){
  state.locationGranted = state.locationGranted === true ? false : true;
  toast(state.locationGranted ? 'Konum izni açıldı' : 'Konum izni kapatıldı', {icon:'location'});
  renderSettings();
  if(state.currentScreen === 'map') renderMapChrome();
}

/* ============================================================ SCREEN: map */
function renderMap(){
  var el = screenEl('map');
  if(el.dataset.built === '1'){ updateMapMarkersDom(); renderMapChrome(); return; }
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
        '<div class="chip-row" id="mapChipRow"></div>' +
      '</div>' +
      '<a class="map-attribution" href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">© OpenStreetMap contributors</a>' +
    '</div>' +
    '<div class="sheet-scrim" id="sheetScrim" data-action="close-sheet"></div>' +
    '<div class="sheet" id="catSheet"></div>' +
    bottomNav('map');

  setTimeout(function(){ var sk = $('#mapSkeleton', el); if(sk) sk.remove(); }, 550);

  initLeaflet();
  updateMapMarkersDom();
  renderMapChrome();
}
function renderMapChrome(){
  var row = $('#mapChipRow'); if(!row) return;
  row.innerHTML =
    '<button class="chip is-warm'+(state.mapHelpFilter?' is-on':'')+'" data-action="toggle-map-help-filter" aria-pressed="'+state.mapHelpFilter+'">'+icon('alertTriangle',{size:14})+' yardım gerekiyor</button>' +
    (state.locationGranted === false ? '<button class="chip" data-action="go-settings">'+icon('location',{size:14})+' konum kapalı</button>' : '');
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
  sheet.innerHTML = catPreviewHTML(cat);
  sheet.classList.add('is-open');
  sheet.inert = false;
}
function closeSheet(){
  state.sheetOpen = false;
  state.selectedCatId = null;
  var scrim = $('#sheetScrim'); if(scrim) scrim.classList.remove('is-open');
  var sheet = $('#catSheet'); if(sheet){ sheet.classList.remove('is-open'); sheet.inert = true; }
  updateMapMarkersDom();
}
function catPreviewHTML(cat){
  var dist = formatDistance(distanceMeters(USER_APPROX_LOCATION, cat.mapPos));
  return (
    '<div class="sheet-grabber"></div>' +
    '<div class="cat-preview">' +
      '<img class="cat-preview__photo" src="'+cat.photos[0]+'" alt="" onerror="onImgErr(this)">' +
      '<div class="cat-preview__body">' +
        '<span class="cat-preview__name">'+esc(catDisplayName(cat))+'</span>' +
        '<span class="cat-preview__loc">'+icon('pin',{size:13})+esc(cat.areaLabel)+' · '+dist+'</span>' +
        freshnessBadge(cat) +
        '<div class="cat-preview__facts">' +
          '<span class="fact">'+icon('droplet',{size:15})+esc(waterLine(cat))+'</span>' +
          '<span class="fact">'+icon('bowl',{size:15})+esc(foodLine(cat))+'</span>' +
        '</div>' +
      '</div>' +
    '</div>' +
    '<button class="btn btn-primary btn-block mt-4" data-action="open-detail" data-cat="'+cat.id+'">Detaya git '+icon('chevronRight',{size:16})+'</button>'
  );
}

/* ============================================================ SCREEN: cat detail */
function renderDetail(){
  var cat = findCat(state.selectedCatId) || CATS[0];
  if(state._detailPhotoCat !== cat.id){ state._detailPhotoCat = cat.id; state.detailPhotoIndex = 0; }
  var idx = Math.min(state.detailPhotoIndex||0, cat.photos.length - 1);
  var isRepeatCloseup = idx > 0 && cat.photos[idx] === cat.photos[0];
  var el = screenEl('detail');
  var alert = activeAlert(cat);
  var followed = isFollowing(cat);
  var recent = cat.updates.slice(0, 4);

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
          '<button class="btn-icon on-glass'+(followed?' filled':'')+'" data-action="toggle-follow" data-cat="'+cat.id+'" aria-label="'+(followed?'takibi bırak':'takip et')+'" aria-pressed="'+followed+'">'+icon('heart',{size:18, filled:followed})+'</button>' +
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
          '<div><div class="info-row__label">Son görülme</div><div class="info-row__value">'+esc(lastSeenText(cat))+(isVeryStale(cat)?' · uzun süredir güncelleme yok':'')+'</div></div>' +
        '</div>' +
        '<div class="info-row">' +
          '<div class="info-row__icon">'+icon('droplet',{size:18})+'</div>' +
          '<div><div class="info-row__label">Su ve mama</div><div class="info-row__value">'+esc(waterLine(cat))+' · '+esc(foodLine(cat))+'</div></div>' +
        '</div>' +
        '<div class="info-row'+(alert?' is-warm':'')+'">' +
          '<div class="info-row__icon">'+icon('alertTriangle',{size:18})+'</div>' +
          '<div><div class="info-row__label">Yardıma ihtiyacı var mı</div><div class="info-row__value">'+
            (alert ? 'Evet — '+esc(helpReasonOf(alert.helpReason).label)+' · '+esc(fmtTimeAgo(alert.createdAt))+' bildirildi.' : 'Şu anda aktif bir yardım bildirimi yok.') +
          '</div></div>' +
        '</div>' +

        '<div class="stack-sm mt-6">' +
          '<button class="btn btn-secondary btn-block" data-action="quick-seen" data-cat="'+cat.id+'">'+icon('eye',{size:16})+' Gördüm</button>' +
          '<button class="btn btn-primary btn-block" data-action="go-add-update" data-cat="'+cat.id+'">'+icon('edit',{size:17})+' Durum güncellemesi ekle</button>' +
        '</div>' +
        '<div class="help-callout mt-4">' +
          '<button class="btn btn-warm btn-block" data-action="go-help" data-cat="'+cat.id+'">'+icon('alertTriangle',{size:19})+' Yardıma ihtiyacı var</button>' +
        '</div>' +

        '<div class="spread mt-6 mb-2">' +
          '<h3 class="eyebrow">Son güncellemeler</h3>' +
          (cat.updates.length > 4 ? '<button style="background:none;border:none;font-size:var(--text-xs);font-weight:700;color:var(--color-primary-strong);cursor:pointer;padding:0;" data-action="go-history" data-cat="'+cat.id+'">Tümünü gör</button>' : '') +
        '</div>' +
        (recent.length
          ? '<div class="timeline">'+recent.map(function(u,i){ return timelineItemHTML(u, i<recent.length-1); }).join('')+'</div>'
          : emptyState('Henüz güncelleme yok', 'Bu kedi için ilk güncellemeyi sen paylaş.', 'edit')) +
      '</div>' +
    '</div>';
}

/* ============================================================ SCREEN: full update history */
function renderHistory(){
  var cat = findCat(state.selectedCatId) || CATS[0];
  var el = screenEl('history');
  el.innerHTML = topbar('Geçmiş', {back:true}) +
    '<div class="screen-body">' +
      '<div class="row-gap mb-4">' +
        '<img src="'+cat.photos[0]+'" alt="" style="width:36px;height:36px;border-radius:50%;object-fit:cover;" onerror="onImgErr(this)">' +
        '<span style="font-weight:700;">'+esc(catDisplayName(cat))+'</span>' +
      '</div>' +
      (cat.updates.length
        ? '<div class="timeline">'+cat.updates.map(function(u,i){ return timelineItemHTML(u, i<cat.updates.length-1); }).join('')+'</div>'
        : emptyState('Henüz güncelleme yok', 'Bu kedi için ilk güncellemeyi sen paylaş.', 'edit')) +
    '</div>';
}

/* ============================================================ SCREEN: add update (seen / fed / water_provided) */
function openAddUpdate(catId){
  if(!isLoggedIn()){ requireLogin('Güncelleme paylaşmak için giriş yap', { type:'start-add-update', payload:{ catId:catId } }); return; }
  state.selectedCatId = catId;
  state.draftUpdate = { catId:catId, statuses:[], comment:'', photo:null, submitting:false, error:false };
  navigate('add-update');
}
function renderAddUpdate(){
  var el = screenEl('add-update');
  var d = state.draftUpdate;
  var cat = findCat(d.catId);
  var canSubmit = d.statuses.length > 0;

  el.innerHTML =
    topbar('Güncelleme ekle', { close:true }) +
    '<div class="screen-body">' +
      '<div class="row-gap mb-4"><img src="'+cat.photos[0]+'" alt="" style="width:28px;height:28px;border-radius:50%;object-fit:cover;" onerror="onImgErr(this)"><span class="text-muted" style="font-weight:600;">'+esc(catDisplayName(cat))+'</span></div>' +

      '<div class="field-label mb-2">Ne oldu? (en az bir tanesini seç)</div>' +
      '<div class="status-grid mb-4">' +
        STATUS_VOCAB.map(function(v){
          var on = d.statuses.indexOf(v.id) !== -1;
          return '<button class="status-option'+(on?' is-on':'')+'" data-action="toggle-status" data-status="'+v.id+'">' +
            '<span class="status-option__radio is-check"></span>'+icon(v.icon,{size:18})+'<span class="status-option__label">'+esc(v.label)+'</span></button>';
        }).join('') +
      '</div>' +

      '<div class="field mb-4">' +
        '<span class="field-label">Yorum (opsiyonel)</span>' +
        '<textarea class="textarea" placeholder="Örn. kase boştu, biraz su bıraktım, çok oyuncuydu…" data-action="draft-comment">'+esc(d.comment)+'</textarea>' +
      '</div>' +

      '<div class="field mb-4">' +
        '<span class="field-label">Fotoğraf (opsiyonel)</span>' +
        '<label class="photo-well" style="height:120px;">' +
          (d.photo ? '<img src="'+d.photo+'" alt="">' : (icon('camera',{size:24}) + '<span>Fotoğraf ekle</span>')) +
          '<input type="file" accept="image/*" data-action="draft-photo" aria-label="fotoğraf ekle">' +
        '</label>' +
      '</div>' +

      (d.error ? errorBlockHTML() : '') +

      '<button class="btn btn-primary btn-block mt-2" data-action="submit-update"'+((!canSubmit || d.submitting)?' aria-disabled="true"':'')+'>' +
        (d.submitting ? '<span class="spinner"></span>' : (d.error ? 'Tekrar dene' : 'Gönder')) +
      '</button>' +
      (!canSubmit ? '<p class="text-faint mt-2" style="font-size:var(--text-xs);text-align:center;">En az bir durum seçmelisin. Sadece yorum yeterli değil.</p>' : '') +
    '</div>';
}
function submitUpdate(){
  var d = state.draftUpdate; if(!d || d.submitting || !d.statuses.length) return;
  d.submitting = true; d.error = false; renderAddUpdate();
  simulateSubmit(function(ok){
    d.submitting = false;
    if(!ok){ d.error = true; renderAddUpdate(); return; }
    var cat = findCat(d.catId);
    var user = currentUser();
    var before = badgeProgress(user.id);
    cat.updates.unshift(upd({ kind:'update', statuses:d.statuses.slice(), comment:d.comment.trim(), photo:d.photo, createdAt:now(), authorId:user.id, authorName:user.displayName }));
    state.draftUpdate = null;
    toast('Güncelleme paylaşıldı', {icon:'check'});
    announceNewBadges(before, badgeProgress(user.id));
    replaceScreen('detail');
  });
}
/* "seen" is a one-tap action per docs/product/updates.md — no form, no photo, no comment */
function quickSeen(catId){
  if(!isLoggedIn()){ requireLogin('Görüldü bildirmek için giriş yap', { type:'quick-seen', payload:{ catId:catId } }); return; }
  var cat = findCat(catId);
  var user = currentUser();
  var before = badgeProgress(user.id);
  cat.updates.unshift(upd({ kind:'update', statuses:['seen'], comment:'', photo:null, createdAt:now(), authorId:user.id, authorName:user.displayName }));
  toast('Görüldü olarak işaretlendi', {icon:'eye'});
  announceNewBadges(before, badgeProgress(user.id));
  if(state.currentScreen === 'detail') renderDetail();
}

/* ============================================================ SCREEN: needs-help report */
function openHelp(catId){
  if(!isLoggedIn()){ requireLogin('Yardım bildirimi oluşturmak için giriş yap', { type:'start-add-help', payload:{ catId:catId } }); return; }
  state.selectedCatId = catId;
  state.draftHelp = { catId:catId, reason:null, comment:'', submitting:false, error:false };
  navigate('help');
}
function renderHelp(){
  var el = screenEl('help');
  var d = state.draftHelp;
  var cat = findCat(d.catId);

  el.innerHTML =
    topbar('Yardım bildir', { close:true }) +
    '<div class="screen-body">' +
      '<div class="row-gap mb-4"><img src="'+cat.photos[0]+'" alt="" style="width:28px;height:28px;border-radius:50%;object-fit:cover;" onerror="onImgErr(this)"><span class="text-muted" style="font-weight:600;">'+esc(catDisplayName(cat))+'</span></div>' +
      '<p class="text-muted mb-4" style="font-size:var(--text-sm);line-height:1.5;">Takip edenlere bildirim gider. Bildirim 72 saat sonra kendiliğinden kalkar.</p>' +

      '<div class="field-label mb-2">Durum ne?</div>' +
      '<div class="status-grid mb-4">' +
        HELP_REASONS.map(function(r){
          var on = d.reason === r.id;
          return '<button class="status-option is-warm'+(on?' is-on':'')+'" data-action="set-help-reason" data-reason="'+r.id+'">' +
            '<span class="status-option__radio"></span>'+icon(r.icon,{size:18})+'<span class="status-option__label">'+esc(r.label)+'</span></button>';
        }).join('') +
      '</div>' +

      '<div class="field mb-4">' +
        '<span class="field-label">Yorum (opsiyonel)</span>' +
        '<textarea class="textarea" placeholder="Örn. sağ arka ayağını basamıyor…" data-action="draft-help-comment">'+esc(d.comment)+'</textarea>' +
      '</div>' +

      (d.error ? errorBlockHTML() : '') +

      '<button class="btn btn-warm btn-block mt-2" data-action="submit-help"'+((!d.reason || d.submitting)?' aria-disabled="true"':'')+'>' +
        (d.submitting ? '<span class="spinner"></span>' : (d.error ? 'Tekrar dene' : 'Yardım bildirimini gönder')) +
      '</button>' +
    '</div>';
}
function submitHelp(){
  var d = state.draftHelp; if(!d || d.submitting || !d.reason) return;
  d.submitting = true; d.error = false; renderHelp();
  simulateSubmit(function(ok){
    d.submitting = false;
    if(!ok){ d.error = true; renderHelp(); return; }
    var cat = findCat(d.catId);
    var user = currentUser();
    cat.updates.unshift(upd({ kind:'help', helpReason:d.reason, comment:d.comment.trim(), photo:null, createdAt:now(), authorId:user.id, authorName:user.displayName }));
    state.draftHelp = null;
    toast('Yardım bildirimi paylaşıldı', {icon:'alertTriangle'});
    replaceScreen('detail');
  });
}

/* ============================================================ SCREEN: add cat — location */
function renderAddLoc(){
  var el = screenEl('add-loc');
  if(!state.draftCat){
    var seed = findCat(DUPLICATE_DEMO_CAT_ID);
    state.draftCat = { lat:seed.mapPos.lat, lng:seed.mapPos.lng, geoError:'', photo:null, name:'', saving:false };
  }
  var d = state.draftCat;
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
function confirmLocation(){
  var d = state.draftCat;
  var nearby = (locMapFailed || typeof L === 'undefined')
    ? [findCat(DUPLICATE_DEMO_CAT_ID)]
    : CATS.filter(function(c){ return distanceMeters(c.mapPos, {lat:d.lat,lng:d.lng}) < DUPLICATE_CHECK_RADIUS_M; });
  if(nearby.length){ openDuplicateModal(nearby); return; }
  navigate('add-detail');
}
/* per docs/product/cats.md and trust.md, adding a cat is never blocked by a duplicate match —
   this modal offers a shortcut to the existing cat, but "yine de ekle" always continues. */
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
          '<img class="dup-candidate__photo" src="'+cat.photos[0]+'" alt="" onerror="onImgErr(this)">' +
          '<div class="dup-candidate__body"><div class="dup-candidate__name">'+esc(catDisplayName(cat))+'</div>' +
          '<div class="dup-candidate__meta">'+esc(cat.areaLabel)+' · '+dist+'</div></div>' +
          icon('chevronRight',{size:16}) +
        '</button>';
      }).join('') +
    '</div>' +
    '<button class="btn btn-secondary btn-block" data-action="dup-no">Hayır, farklı bir kedi — yine de ekle</button>' +
  '</div>';
  modal.classList.add('is-open');
  modal.inert = false;
}
function closeDuplicateModal(){ var m=$('#dupModal'); if(m){ m.classList.remove('is-open'); m.inert = true; } }

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
      (d.error ? errorBlockHTML() : '') +
      '<button class="btn btn-primary btn-block" data-action="save-cat"'+(d.saving?' aria-disabled="true"':'')+'>' +
        (d.saving ? '<span class="spinner"></span>' : (d.error ? 'Tekrar dene' : 'Kaydet')) +
      '</button>' +
    '</div>';
}
function saveCat(){
  var d = state.draftCat; if(!d || d.saving) return;
  if(!d.photo){ toast('Kaydetmeden önce bir fotoğraf ekle', {icon:'alertTriangle'}); return; }
  d.saving = true; d.error = false; renderAddDetail();
  simulateSubmit(function(ok){
    d.saving = false;
    if(!ok){ d.error = true; renderAddDetail(); return; }
    var user = currentUser();
    var id = 'yeni-kedi-'+(state.newCatSeq++);
    var newCat = {
      id:id, name: d.name.trim() || null,
      photos:[d.photo], mapPos:{lat:d.lat, lng:d.lng}, fallbackPos:{top:'50%',left:'50%'},
      areaLabel:'Kadıköy çevresi', desc:'',
      createdAt: now(), createdBy: user.id,
      updates:[ upd({ kind:'update', statuses:['seen'], comment:'Yeni kedi olarak eklendi.', photo:d.photo, createdAt:now(), authorId:user.id, authorName:user.displayName }) ]
    };
    CATS.push(newCat);
    state.draftCat = null;
    state.selectedCatId = newCat.id;
    toast('Kedi eklendi', {icon:'check'});
    screenEl('map').dataset.built = '';
    navigate('map', { root:true });
    openSheet(newCat.id);
  });
}

/* ============================================================ SCREEN: discover */
function renderDiscover(){
  var el = screenEl('discover');
  var list = CATS.map(function(c){ return { cat:c, distance: distanceMeters(USER_APPROX_LOCATION, c.mapPos) }; });
  if(state.discoverTab === 'help'){
    list = list.filter(function(r){ return !!activeAlert(r.cat); });
  } else if(state.discoverTab === 'following'){
    var user = currentUser();
    list = user ? list.filter(function(r){ return user.follows.indexOf(r.cat.id) !== -1; }) : [];
  }
  list.sort(function(a,b){ return a.distance - b.distance; });
  var guestOnFollowing = !isLoggedIn() && state.discoverTab === 'following';

  el.innerHTML =
    topbar('Keşfet', {}) +
    '<div class="screen-body">' +
      '<div class="segmented mb-3">' +
        '<button class="'+(state.discoverTab==='nearby'?'is-on':'')+'" data-action="discover-tab" data-tab="nearby">Yakınımda</button>' +
        '<button class="'+(state.discoverTab==='help'?'is-on':'')+'" data-action="discover-tab" data-tab="help">Yardım gerekiyor</button>' +
        '<button class="'+(state.discoverTab==='following'?'is-on':'')+'" data-action="discover-tab" data-tab="following">Takip ettiklerim</button>' +
      '</div>' +
      (guestOnFollowing
        ? emptyState('Giriş yapmadın', 'Takip ettiğin kedileri görmek için giriş yap.', 'heart') +
          '<div style="text-align:center;"><button class="btn btn-primary mt-2" data-action="go-login-generic">Giriş yap</button></div>'
        : (list.length
            ? '<div>'+list.map(function(r,i){
                var c = r.cat;
                return (i>0?'<div class="list-divider"></div>':'') +
                '<div class="cat-card" data-action="open-detail" data-cat="'+c.id+'">' +
                  '<img class="cat-card__photo" src="'+c.photos[0]+'" alt="" onerror="onImgErr(this)">' +
                  '<div class="cat-card__body"><div class="cat-card__name">'+esc(catDisplayName(c))+'</div><div class="cat-card__meta">'+esc(c.areaLabel)+'</div></div>' +
                  '<div class="cat-card__aside">'+freshnessBadge(c)+'<span class="cat-card__distance">'+formatDistance(r.distance)+'</span></div>' +
                '</div>';
              }).join('')+'</div>'
            : emptyState(
                state.discoverTab==='help' ? 'Şu an yardım bekleyen kedi yok' : (state.discoverTab==='following' ? 'Henüz takip ettiğin kedi yok' : 'Yakında kedi bulunamadı'),
                state.discoverTab==='help' ? 'Aktif bir yardım bildirimi olduğunda burada görünecek.' : (state.discoverTab==='following' ? 'Bir kedinin detayından takip et, burada listelensin.' : 'Daha sonra tekrar dene.'),
                state.discoverTab==='help' ? 'alertTriangle' : (state.discoverTab==='following' ? 'heart' : 'compass')
              ))
      ) +
    '</div>' +
    bottomNav('discover');
}

/* ============================================================ SCREEN: profile */
function renderProfile(){
  var el = screenEl('profile');
  el.innerHTML = topbar('Profil', {}) + '<div class="screen-body">' + (isLoggedIn() ? profileBodyHTML() : profileGuestHTML()) + '</div>' + bottomNav('profile');
}
function profileGuestHTML(){
  return '<div class="state-block" style="padding:var(--space-8) 0;">' +
    '<div class="state-block__icon">'+icon('user',{size:22})+'</div>' +
    '<div class="state-block__title">Giriş yapmadın</div>' +
    '<div class="state-block__body">Katkı geçmişini ve rozetlerini görmek, kedi eklemek ve güncelleme paylaşmak için giriş yapman gerekir. Haritayı ve kedi detaylarını girişsiz gezebilirsin.</div>' +
    '<button class="btn btn-primary mt-2" data-action="go-login-generic">Giriş yap</button>' +
  '</div>';
}
function profileBodyHTML(){
  var user = currentUser();
  var totals = contributionTotals(user.id);
  var badges = badgeProgress(user.id);
  var earned = badges.filter(function(b){ return b.earned; });
  var contribs = userContributions(user.id).slice(0, 8);
  return (
    '<div class="profile-hero">' +
      '<img class="profile-hero__avatar" src="'+(user.avatar || FALLBACK_IMG)+'" alt="" onerror="onImgErr(this)">' +
      '<div>' +
        '<div class="profile-hero__name">'+esc(user.displayName)+'</div>' +
        '<div class="profile-hero__phone">'+esc(user.phone)+'</div>' +
      '</div>' +
    '</div>' +

    '<div class="stat-row mb-6">' +
      '<div class="stat-tile"><div class="stat-tile__num">'+totals.updates+'</div><div class="stat-tile__label">güncelleme</div></div>' +
      '<div class="stat-tile"><div class="stat-tile__num">'+totals.helps+'</div><div class="stat-tile__label">yardım bildirimi</div></div>' +
      '<div class="stat-tile"><div class="stat-tile__num">'+totals.catsAdded+'</div><div class="stat-tile__label">eklenen kedi</div></div>' +
      '<div class="stat-tile"><div class="stat-tile__num">'+totals.distinctCats+'</div><div class="stat-tile__label">kediye katkı</div></div>' +
    '</div>' +

    '<div class="spread mb-2">' +
      '<h3 class="eyebrow">Rozetler</h3>' +
      '<button style="background:none;border:none;font-size:var(--text-xs);font-weight:700;color:var(--color-primary-strong);cursor:pointer;padding:0;" data-action="go-badges">Tümünü gör</button>' +
    '</div>' +
    (earned.length
      ? '<div class="badge-strip mb-6">'+badges.map(badgeTileHTML).join('')+'</div>'
      : '<p class="text-muted mb-6" style="font-size:var(--text-sm);">Henüz rozet kazanmadın. İlk katkını paylaş, buradan takip et.</p>') +

    '<h3 class="eyebrow mb-2">Son katkılar</h3>' +
    (contribs.length ? contribs.map(contribRowHTML).join('') : emptyState('Henüz katkın yok', 'Bir kediyi gördüğünde "Gördüm" ile başla.', 'edit')) +

    '<button class="btn btn-secondary btn-block mt-6" data-action="go-settings">'+icon('sliders',{size:16})+' Ayarlar</button>'
  );
}
function badgeTileHTML(b){
  return '<button class="badge-tile'+(b.earned?'':' is-locked')+'" data-action="open-badge" data-badge="'+b.def.id+'">' +
    '<div class="badge-tile__icon">'+icon(b.def.icon,{size:26})+'</div>' +
    '<div class="badge-tile__label">'+esc(b.def.name)+'</div>' +
  '</button>';
}
function contributionIcon(c){
  if(c.type === 'cat_added') return 'pin';
  if(c.type === 'help') return 'alertTriangle';
  var v = statusVocabOf(c.update.statuses[0]);
  return v ? v.icon : 'edit';
}
function contributionLabel(c){
  if(c.type === 'cat_added') return 'yeni kedi eklendi';
  if(c.type === 'help'){
    var r = helpReasonOf(c.update.helpReason);
    return 'yardım bildirimi' + (r ? ' · '+r.label.toLowerCase() : '');
  }
  return c.update.statuses.map(function(s){ var v = statusVocabOf(s); return v ? v.label.toLowerCase() : s; }).join(', ');
}
function contribRowHTML(c){
  var cat = findCat(c.catId);
  return '<div class="contrib-row" data-action="open-detail" data-cat="'+cat.id+'" style="cursor:pointer;">' +
    '<div class="contrib-row__icon">'+icon(contributionIcon(c),{size:15})+'</div>' +
    '<div class="contrib-row__body"><span class="contrib-row__cat">'+esc(catDisplayName(cat))+'</span> — '+esc(contributionLabel(c))+'</div>' +
    '<span class="contrib-row__time">'+esc(fmtTimeAgo(c.at))+'</span>' +
  '</div>';
}

/* ============================================================ SCREEN: badges */
function renderBadges(){
  var el = screenEl('badges');
  var user = currentUser();
  var badges = user ? badgeProgress(user.id) : BADGE_DEFS.map(function(def){ return { def:def, value:0, earned:false, earnedAt:null }; });
  var earnedCount = badges.filter(function(b){ return b.earned; }).length;
  el.innerHTML = topbar('Rozetler', { back:true }) +
    '<div class="screen-body">' +
      (earnedCount === 0
        ? '<p class="text-muted mb-4" style="font-size:var(--text-sm);">Henüz hiç rozet kazanmadın. Aşağıdaki katkılarla ilk rozetini kazanabilirsin.</p>'
        : '<p class="text-muted mb-4" style="font-size:var(--text-sm);">'+earnedCount+' / '+badges.length+' rozet kazanıldı.</p>') +
      '<div>'+badges.map(badgeRowHTML).join('')+'</div>' +
    '</div>';
}
function badgeRowHTML(b){
  var pct = Math.round((b.value / b.def.target) * 100);
  return '<button class="badge-row'+(b.earned?'':' is-locked')+'" data-action="open-badge" data-badge="'+b.def.id+'">' +
    '<div class="badge-row__icon">'+icon(b.def.icon,{size:20})+'</div>' +
    '<div class="badge-row__body">' +
      '<div class="badge-row__name">'+esc(b.def.name)+'</div>' +
      '<div class="badge-row__progress">'+(b.earned ? 'Kazanıldı' : b.value+' / '+b.def.target)+'</div>' +
      (!b.earned ? '<div class="progress-bar"><div class="progress-bar__fill" style="width:'+pct+'%;"></div></div>' : '') +
    '</div>' +
    icon('chevronRight',{size:16}) +
  '</button>';
}

/* ============================================================ SCREEN: badge detail */
function renderBadgeDetail(){
  var el = screenEl('badge-detail');
  var def = BADGE_DEFS.filter(function(d){ return d.id === state.selectedBadgeId; })[0] || BADGE_DEFS[0];
  var user = currentUser();
  var b = user ? badgeProgress(user.id).filter(function(x){ return x.def.id === def.id; })[0] : { def:def, value:0, earned:false, earnedAt:null };
  el.innerHTML = topbar('Rozet', { back:true }) +
    '<div class="screen-body">' +
      '<div class="badge-detail-hero'+(b.earned?'':' is-locked')+'">' +
        '<div class="badge-detail-hero__icon">'+icon(def.icon,{size:44})+'</div>' +
        '<h2>'+esc(def.name)+'</h2>' +
        (b.earned ? '<span class="badge-detail-hero__earned">'+esc(fmtDate(b.earnedAt))+' tarihinde kazanıldı</span>' : '<span class="text-muted" style="font-size:var(--text-sm);">'+b.value+' / '+def.target+'</span>') +
      '</div>' +
      (!b.earned ? '<div class="progress-bar mb-4"><div class="progress-bar__fill" style="width:'+Math.round((b.value/def.target)*100)+'%;"></div></div>' : '') +
      '<div class="info-row"><div class="info-row__icon">'+icon('award',{size:18})+'</div><div><div class="info-row__label">Nasıl kazanılır</div><div class="info-row__value">'+esc(def.condition)+'</div></div></div>' +
      '<p class="text-muted mt-4" style="font-size:var(--text-sm);line-height:1.5;">'+esc(def.descr)+'</p>' +
    '</div>';
}

/* ============================================================ SCREEN: settings */
function renderSettings(){
  var el = screenEl('settings');
  el.innerHTML = topbar('Ayarlar', { back:true }) +
    '<div class="screen-body">' +
      '<h3 class="eyebrow mb-2">İzinler</h3>' +
      '<div class="info-row" style="align-items:center;">' +
        '<div class="info-row__icon">'+icon('location',{size:18})+'</div>' +
        '<div style="flex:1;"><div class="info-row__label">Konum</div><div class="info-row__value">'+(state.locationGranted===true?'Açık':(state.locationGranted===false?'Kapalı':'Sorulmadı'))+'</div></div>' +
        '<button class="toggle-pill'+(state.locationGranted===true?' is-on':'')+'" data-action="toggle-location-permission"><span class="toggle-pill__dot"></span>'+(state.locationGranted===true?'Açık':'İzin ver')+'</button>' +
      '</div>' +
      '<div class="info-row" style="align-items:center;">' +
        '<div class="info-row__icon">'+icon('bell',{size:18})+'</div>' +
        '<div style="flex:1;"><div class="info-row__label">Bildirimler</div><div class="info-row__value">Takip ettiğin kedilerde aktif yardım bildirimi olduğunda</div></div>' +
        '<button class="toggle-pill'+(state.notificationsEnabled?' is-on':'')+'" data-action="toggle-notifications"><span class="toggle-pill__dot"></span>'+(state.notificationsEnabled?'Açık':'Kapalı')+'</button>' +
      '</div>' +

      '<h3 class="eyebrow mt-6 mb-2">Hesap</h3>' +
      (isLoggedIn()
        ? '<div class="info-row"><div class="info-row__icon">'+icon('phone',{size:18})+'</div><div><div class="info-row__label">Doğrulanmış numara</div><div class="info-row__value">'+esc(currentUser().phone)+'</div></div></div>' +
          '<button class="btn btn-secondary btn-block mt-4" data-action="logout">'+icon('logout',{size:16})+' Çıkış yap</button>'
        : '<p class="text-muted mb-2" style="font-size:var(--text-sm);">Giriş yapmadın.</p>' +
          '<button class="btn btn-primary btn-block" data-action="go-login-generic">Giriş yap</button>') +

      '<h3 class="eyebrow mt-6 mb-2">Prototip demo</h3>' +
      '<div class="info-row" style="align-items:center;">' +
        '<div class="info-row__icon">'+icon('info',{size:18})+'</div>' +
        '<div style="flex:1;"><div class="info-row__label">Çevrimdışı durumu göster</div><div class="info-row__value">Gönderimler başarısız olur, üst banner görünür</div></div>' +
        '<button class="toggle-pill'+(state.demoOffline?' is-on':'')+'" data-action="toggle-demo-offline"><span class="toggle-pill__dot"></span>'+(state.demoOffline?'Açık':'Kapalı')+'</button>' +
      '</div>' +
    '</div>';
}
function toggleNotifications(){ state.notificationsEnabled = !state.notificationsEnabled; renderSettings(); }
function toggleDemoOffline(){ state.demoOffline = !state.demoOffline; updateOfflineBanner(); renderSettings(); }

/* ============================================================ offline banner */
function updateOfflineBanner(){
  var el = $('#offlineBanner'); if(!el) return;
  var offline = state.demoOffline || !navigator.onLine;
  el.hidden = !offline;
  if(offline) el.innerHTML = icon('alertTriangle',{size:14}) + '<span>Çevrimdışısın — gönderimler başarısız olabilir</span>';
}
window.addEventListener('online', updateOfflineBanner);
window.addEventListener('offline', updateOfflineBanner);

/* ============================================================ follow */
function toggleFollow(catId){
  if(!isLoggedIn()){ requireLogin('Bir kediyi takip etmek için giriş yap', { type:'toggle-follow', payload:{ catId:catId } }); return; }
  var user = currentUser();
  var idx = user.follows.indexOf(catId);
  var nowFollowing;
  if(idx === -1){ user.follows.push(catId); nowFollowing = true; }
  else { user.follows.splice(idx, 1); nowFollowing = false; }
  toast(nowFollowing ? 'Takip ediyorsun' : 'Takipten çıkıldı', {icon:'heart'});
  renderScreen(state.currentScreen);
  if(nowFollowing && !state.notifPermAsked){
    state.notifPermAsked = true;
    setTimeout(openNotifPermModal, 500);
  }
}

/* ============================================================ notification permission modal */
/* per docs/product/notifications.md: permission is asked only after the user follows a cat,
   never at first launch. */
function openNotifPermModal(){
  var modal = $('#notifPermModal');
  modal.innerHTML = '<div class="modal-card">' +
    '<div class="login-hero__icon" style="margin:0 auto;">'+icon('bell',{size:22})+'</div>' +
    '<div class="modal-card__title" style="text-align:center;">Bu kedi için bildirim almak ister misin?</div>' +
    '<p class="text-muted" style="font-size:var(--text-sm);text-align:center;">Sadece aktif bir yardım bildirimi olduğunda haber veririz. Sık bildirim göndermeyiz.</p>' +
    '<div class="modal-card__actions">' +
      '<button class="btn btn-secondary" data-action="deny-notif-perm">Şimdi değil</button>' +
      '<button class="btn btn-primary" data-action="allow-notif-perm">İzin ver</button>' +
    '</div>' +
  '</div>';
  modal.classList.add('is-open');
  modal.inert = false;
}
function closeNotifPermModal(){ var m=$('#notifPermModal'); if(m){ m.classList.remove('is-open'); m.inert = true; } }

/* ============================================================ SCREEN: login */
function renderLogin(){
  var el = screenEl('login');
  if(!state._loginForm) state._loginForm = { phone:'', codeSent:false, code:'', name:'', needsName:false, sending:false };
  var f = state._loginForm;

  if(f.needsName){
    el.innerHTML =
      topbar('Giriş yap', { close:true, closeAction:'cancel-login' }) +
      '<div class="screen-body">' +
        '<div class="login-hero">' +
          '<div class="login-hero__icon">'+icon('user',{size:24})+'</div>' +
          '<h2>Görünen adını seç</h2>' +
        '</div>' +
        '<div class="field mb-4">' +
          '<span class="field-label">Görünen isim</span>' +
          '<input class="input" type="text" placeholder="Örn. Ayşe, Mert…" value="'+esc(f.name)+'" data-action="login-name">' +
        '</div>' +
        '<p class="text-faint mb-4" style="font-size:var(--text-xs);line-height:1.5;">Bu isim, paylaştığın güncellemelerin ve profilinin yanında herkese açık şekilde görünür.</p>' +
        '<button class="btn btn-primary btn-block" data-action="submit-name"'+(f.sending?' aria-disabled="true"':'')+'>'+(f.sending?'<span class="spinner"></span>':'Kaydet ve devam et')+'</button>' +
        '<button class="btn btn-ghost btn-block mt-3" data-action="cancel-login">Vazgeç</button>' +
      '</div>';
    return;
  }

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
          '<input class="input" style="flex:1;" type="tel" inputmode="numeric" placeholder="5xx xxx xx xx" value="'+esc(f.phone)+'" data-action="login-phone"'+(f.codeSent?' disabled':'')+'>' +
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
      '<p class="text-faint mt-4" style="font-size:var(--text-xs);text-align:center;line-height:1.5;">Demo: 555 111 22 33 numarasıyla katkı geçmişi olan bir hesaba, başka bir numarayla yeni bir hesaba giriş yaparsın (adını sana soracağız). Her kod kabul edilir.</p>' +
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
    var digits = f.phone.replace(/\D/g,'');
    if(digits === DEMO_PHONE_DIGITS){
      f.sending = false;
      finishLogin(DEMO_USER);
      return;
    }
    // brand-new account: ask for a display name before finishing sign-in, instead of
    // defaulting to the generic "Yeni Üye" placeholder from freshUser()
    f.sending = false;
    f.needsName = true;
    renderLogin();
  }, 500);
}
function submitName(){
  var f = state._loginForm;
  if(!f.name || !f.name.trim()){ toast('Bir isim gir', {icon:'alertTriangle'}); return; }
  f.sending = true; renderLogin();
  setTimeout(function(){
    var user = freshUser('+90 '+f.phone);
    user.displayName = f.name.trim();
    finishLogin(user);
  }, 400);
}
function finishLogin(user){
  state.session.loggedIn = true;
  state.session.user = user;
  state._loginForm = null;
  var pending = state.pendingAction; state.pendingAction = null; state.loginContext = '';
  toast('Giriş yapıldı', {icon:'check'});
  resumePendingAction(pending);
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
      closeSheet(); state.selectedCatId = t.getAttribute('data-cat'); navigate('detail'); break;
    case 'go-history': state.selectedCatId = t.getAttribute('data-cat') || state.selectedCatId; navigate('history'); break;
    case 'hero-photo-prev':
      state.detailPhotoIndex = Math.max(0, (state.detailPhotoIndex||0) - 1); renderDetail(); break;
    case 'hero-photo-next': {
      var dcat = findCat(state.selectedCatId);
      state.detailPhotoIndex = Math.min(dcat.photos.length - 1, (state.detailPhotoIndex||0) + 1);
      renderDetail(); break;
    }
    case 'toggle-follow': toggleFollow(t.getAttribute('data-cat')); break;
    case 'quick-seen': quickSeen(t.getAttribute('data-cat')); break;
    case 'go-add-cat':
      if(!isLoggedIn()){ requireLogin('Kedi eklemek için giriş yap', { type:'start-add-cat' }); }
      else { state.draftCat = null; navigate('add-loc'); }
      break;
    case 'go-add-update': openAddUpdate(t.getAttribute('data-cat')); break;
    case 'toggle-status': {
      var sid = t.getAttribute('data-status');
      var si = state.draftUpdate.statuses.indexOf(sid);
      if(si === -1) state.draftUpdate.statuses.push(sid); else state.draftUpdate.statuses.splice(si, 1);
      renderAddUpdate(); break;
    }
    case 'submit-update': submitUpdate(); break;
    case 'go-help': openHelp(t.getAttribute('data-cat')); break;
    case 'set-help-reason': state.draftHelp.reason = t.getAttribute('data-reason'); renderHelp(); break;
    case 'submit-help': submitHelp(); break;
    case 'use-current-location': useCurrentLocation(); break;
    case 'confirm-location': confirmLocation(); break;
    case 'dup-yes': closeDuplicateModal(); state.draftCat = null; state.selectedCatId = t.getAttribute('data-cat'); navigate('detail', {root:true}); break;
    case 'dup-no': closeDuplicateModal(); navigate('add-detail'); break;
    case 'save-cat': saveCat(); break;
    case 'discover-tab': state.discoverTab = t.getAttribute('data-tab'); renderDiscover(); break;
    case 'toggle-map-help-filter':
      state.mapHelpFilter = !state.mapHelpFilter;
      renderMapChrome();
      updateMapMarkersDom();
      break;
    case 'go-badges': navigate('badges'); break;
    case 'open-badge': state.selectedBadgeId = t.getAttribute('data-badge'); navigate('badge-detail'); break;
    case 'go-settings': navigate('settings'); break;
    case 'toggle-location-permission': toggleLocationPermission(); break;
    case 'toggle-notifications': toggleNotifications(); break;
    case 'toggle-demo-offline': toggleDemoOffline(); break;
    case 'logout': state.session.loggedIn = false; state.session.user = null; toast('Çıkış yapıldı', {icon:'logout'}); navigate('profile', {root:true}); break;
    case 'go-login-generic': requireLogin('Hesabına giriş yap', null); break;
    case 'close-auth-sheet': closeAuthSheet(); state.pendingAction = null; state.loginContext = ''; break;
    case 'go-login-screen': closeAuthSheet(); navigate('login'); break;
    case 'send-code': sendCode(); break;
    case 'do-login': doLogin(); break;
    case 'submit-name': submitName(); break;
    case 'cancel-login': cancelLogin(); break;
    case 'allow-notif-perm': state.notificationsEnabled = true; closeNotifPermModal(); toast('Bildirimler açık', {icon:'bell'}); break;
    case 'deny-notif-perm': closeNotifPermModal(); break;
    case 'grant-location': grantLocation(); break;
    case 'deny-location': denyLocation(); break;
  }
});

document.addEventListener('input', function(e){
  var t = e.target.closest('[data-action]'); if(!t) return;
  var action = t.getAttribute('data-action');
  if(action === 'draft-comment') state.draftUpdate.comment = t.value;
  else if(action === 'draft-help-comment') state.draftHelp.comment = t.value;
  else if(action === 'login-phone') state._loginForm.phone = t.value;
  else if(action === 'login-code') state._loginForm.code = t.value;
  else if(action === 'login-name') state._loginForm.name = t.value;
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
  if(e.target.matches && e.target.matches('[data-action=login-phone], [data-action=login-code], [data-action=login-name]')){
    screenEl('login').classList.add('is-keyboard-open');
  }
});
document.addEventListener('focusout', function(e){
  if(e.target.matches && e.target.matches('[data-action=login-phone], [data-action=login-code], [data-action=login-name]')){
    screenEl('login').classList.remove('is-keyboard-open');
  }
});

/* ============================================================ boot */
document.addEventListener('DOMContentLoaded', function(){
  updateOfflineBanner();
  navigate('splash', { root:true });
});
