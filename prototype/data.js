/*
  tekir prototype — mock clock, seed data and pure derivation helpers.
  no dom access here: everything below is either data or a pure function,
  so app.js / map.js can rely on it without ordering surprises.
  loaded after icons.js, before map.js and app.js (see index.html).
*/
'use strict';

/* ============================================================ mock clock */
/* seed timestamps are computed against the real load time; CLOCK_OFFSET is a
   demo-only lever (window.tekirDemo.advance in app.js) that fast-forwards
   "now" so the 72h alert expiry and freshness decay can be shown live. */
var CLOCK_OFFSET = 0;
var MIN = 60 * 1000, HOUR = 60 * MIN, DAY = 24 * HOUR;
function now(){ return Date.now() + CLOCK_OFFSET; }
function minutesAgo(n){ return Date.now() - n * MIN; }
function hoursAgo(n){ return Date.now() - n * HOUR; }
function daysAgo(n){ return Date.now() - n * DAY; }

var ALERT_TTL = 72 * HOUR;          // docs/product/alerts.md — fixed, no resolve action
var UPDATE_EDIT_WINDOW = 10 * MIN;  // docs/product/updates.md — self-correct window
var VERY_STALE_AFTER = 365 * DAY;   // docs/product/cats.md — 12-month stronger message

function fmtTimeAgo(ts){
  var d = now() - ts;
  if(d < MIN) return 'az önce';
  if(d < HOUR) return Math.floor(d / MIN) + ' dk önce';
  if(d < DAY) return Math.floor(d / HOUR) + ' sa önce';
  if(d < 2 * DAY) return 'dün';
  if(d < 30 * DAY) return Math.floor(d / DAY) + ' gün önce';
  if(d < 365 * DAY) return Math.floor(d / (30 * DAY)) + ' ay önce';
  var y = Math.floor(d / (365 * DAY));
  return y + ' yıldan uzun süre önce';
}
function fmtRemaining(ms){
  if(ms <= 0) return '';
  if(ms < HOUR) return Math.max(1, Math.floor(ms / MIN)) + ' dk';
  return Math.floor(ms / HOUR) + ' sa';
}
function fmtDate(ts){
  var MONTHS = ['Ocak','Şubat','Mart','Nisan','Mayıs','Haziran','Temmuz','Ağustos','Eylül','Ekim','Kasım','Aralık'];
  var d = new Date(ts);
  return d.getDate() + ' ' + MONTHS[d.getMonth()] + ' ' + d.getFullYear();
}

/* ============================================================ vocabularies */
/* structured statuses — final mvp vocabulary (docs/product/updates.md).
   multi-select: an update carries one or more of these. behavioral notes
   ("oyuncu", "ürkek"...) belong in the free-text comment, not here. */
var STATUS_VOCAB = [
  { id:'seen',           label:'Görüldü',      icon:'eye' },
  { id:'fed',            label:'Mama verildi', icon:'bowl' },
  { id:'water_provided', label:'Su verildi',   icon:'droplet' }
];
function statusVocabOf(id){
  for(var i=0;i<STATUS_VOCAB.length;i++) if(STATUS_VOCAB[i].id===id) return STATUS_VOCAB[i];
  return null;
}

/* needs-help reasons — fixed mvp vocabulary (docs/product/alerts.md) */
var HELP_REASONS = [
  { id:'injured_sick',    label:'Yaralı veya hasta',   icon:'alertTriangle' },
  { id:'food_needed',     label:'Mama gerekiyor',      icon:'bowl' },
  { id:'water_needed',    label:'Su gerekiyor',        icon:'droplet' },
  { id:'unsafe_location', label:'Güvensiz bir yerde',  icon:'pin' },
  { id:'trapped',         label:'Mahsur kalmış',       icon:'close' }
];
function helpReasonOf(id){
  for(var i=0;i<HELP_REASONS.length;i++) if(HELP_REASONS[i].id===id) return HELP_REASONS[i];
  return null;
}

/* map freshness tiers — semantic thresholds from docs/product/map.md */
var FRESHNESS_META = {
  today:         { markerCls:'freshness-today',  badgeCls:'badge-today' },
  this_week:     { markerCls:'freshness-week',   badgeCls:'badge-week' },
  this_month:    { markerCls:'freshness-month',  badgeCls:'badge-month' },
  long_not_seen: { markerCls:'freshness-long',   badgeCls:'badge-long' }
};

/* ============================================================ photos */
/* real street cat photographs from wikimedia commons — credits and licenses
   in README.md. hot-linked on purpose: the prototype has no build step. */
var PHOTOS = {
  kabatas:    'https://upload.wikimedia.org/wikipedia/commons/thumb/f/f9/Cat_near_Kabata%C5%9F_in_Istanbul%2C_20260605_1734_1298.jpg/960px-Cat_near_Kabata%C5%9F_in_Istanbul%2C_20260605_1734_1298.jpg',
  kadikoy:    'https://upload.wikimedia.org/wikipedia/commons/thumb/7/70/Cats%2C_Kadikoey%2C_Istanbul_%28P1100168%29.jpg/960px-Cats%2C_Kadikoey%2C_Istanbul_%28P1100168%29.jpg',
  sultanahmet:'https://upload.wikimedia.org/wikipedia/commons/thumb/3/35/Istanbul_-_cat_of_Sultanahmet.jpg/960px-Istanbul_-_cat_of_Sultanahmet.jpg',
  oldistanbul:'https://upload.wikimedia.org/wikipedia/commons/thumb/1/15/Old_Istanbul_Cat.jpg/960px-Old_Istanbul_Cat.jpg',
  fatih:      'https://upload.wikimedia.org/wikipedia/commons/thumb/2/2a/Cat%2C_Istanbul_%28P1180136%29.jpg/960px-Cat%2C_Istanbul_%28P1180136%29.jpg',
  brickwall:  'https://upload.wikimedia.org/wikipedia/commons/thumb/9/94/Turkey_%28Istanbul%29_Street_cat_%2821956691179%29.jpg/960px-Turkey_%28Istanbul%29_Street_cat_%2821956691179%29.jpg',
  carpet:     'https://upload.wikimedia.org/wikipedia/commons/a/a5/Cat_on_Turkish_Carpets_Grand_Bazaar_Istanbul_2026.jpg',
  utilitybox: 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/04/Cat_sleeping_on_utility_box_Sishane_Istanbul_2024.jpg/960px-Cat_sleeping_on_utility_box_Sishane_Istanbul_2024.jpg',
  curious:    'https://upload.wikimedia.org/wikipedia/commons/thumb/8/87/Curious_street_cat_in_Istanbul_-_T%C3%BCrkiye%2C_2023.jpg/960px-Curious_street_cat_in_Istanbul_-_T%C3%BCrkiye%2C_2023.jpg',
  street2023: 'https://upload.wikimedia.org/wikipedia/commons/thumb/2/28/Street_cat_in_Istanbul_-_T%C3%BCrkiye%2C_2023.jpg/960px-Street_cat_in_Istanbul_-_T%C3%BCrkiye%2C_2023.jpg'
};
var FALLBACK_IMG = 'data:image/svg+xml;utf8,' + encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">' +
  '<rect width="100" height="100" fill="#F1DCD2"/>' +
  '<path d="M50 60c-12 0-20 8-20 16 0 4 3 7 7 7 5 0 7-3 13-3s8 3 13 3c4 0 7-3 7-7 0-8-8-16-20-16Z" fill="#A44732"/>' +
  '<circle cx="34" cy="38" r="7" fill="#A44732"/><circle cx="50" cy="30" r="7.5" fill="#A44732"/><circle cx="66" cy="38" r="7" fill="#A44732"/>' +
  '<circle cx="24" cy="54" r="6" fill="#A44732"/><circle cx="76" cy="54" r="6" fill="#A44732"/></svg>');
window.onImgErr = function(img){ img.onerror = null; img.src = FALLBACK_IMG; };

/* ============================================================ demo users */
/* two login paths (see doLogin in app.js):
   - the documented demo number 555 111 22 33 → "Deniz", a seeded account with
     history, follows and partial badge progress (feeder deliberately at 4/5 so
     one fed update earns a badge live during the founder review).
   - any other number → a brand-new account with zero history, which is how
     every empty state (badges, followed cats, contributions) is demonstrated. */
var DEMO_PHONE_DIGITS = '5551112233';
var DEMO_USER = {
  id:'deniz', displayName:'Deniz', avatar:PHOTOS.curious,
  phone:'+90 555 111 22 33',
  follows:['sultan','portakal']
};
function freshUser(phone){
  return { id:'user-'+Date.now(), displayName:'Yeni Üye', avatar:null, phone:phone, follows:[] };
}

/* ============================================================ seed cats */
/* update shape:
   { id, kind:'update'|'help', statuses:['seen'|'fed'|'water_provided',...],
     helpReason:'injured_sick'|..., comment, photo, createdAt, authorId, authorName }
   everything shown about a cat (freshness, active alert, water/food lines,
   last-seen) is DERIVED from this history — never stored on the cat. */
var _seq = 1;
function upd(o){ o.id = 'u'+(_seq++); o.comment = o.comment||''; o.photo = o.photo||null; return o; }

var CATS = [
  {
    id:'portakal', name:'Portakal',
    photos:[PHOTOS.kabatas, PHOTOS.curious],
    mapPos:{lat:40.9797,lng:29.0256}, fallbackPos:{top:'40%',left:'26%'},
    areaLabel:'Moda Sahili, Kadıköy',
    desc:'Turuncu tekir, sol kulağında küçük bir çentik var. Sahil banklarının çevresinde dolaşıyor.',
    createdAt: daysAgo(140), createdBy:'elif',
    updates:[
      upd({ kind:'help', helpReason:'injured_sick', comment:'Sağ arka ayağını basamıyor, topallıyor. Sahildeki büfenin yanında.', createdAt: minutesAgo(25), authorId:'elif', authorName:'Elif' }),
      upd({ kind:'update', statuses:['seen'], comment:'', createdAt: hoursAgo(5), authorId:'mert', authorName:'Mert' }),
      upd({ kind:'update', statuses:['seen'], comment:'Bankın altında uyuyordu.', createdAt: daysAgo(10), authorId:'deniz', authorName:'Deniz' }),
      upd({ kind:'update', statuses:['fed'], comment:'', createdAt: daysAgo(18), authorId:'ayse', authorName:'Ayşe' })
    ]
  },
  {
    id:'sultan', name:'Sultan',
    photos:[PHOTOS.sultanahmet, PHOTOS.kadikoy, PHOTOS.street2023],
    mapPos:{lat:40.9793,lng:29.0287}, fallbackPos:{top:'56%',left:'70%'},
    areaLabel:'Moda Çay Bahçesi, Kadıköy',
    desc:'Uzun tüylü, beyaz göğüslü. Çay bahçesinin müdavimi, insanlara alışkın.',
    createdAt: daysAgo(300), createdBy:'ayse',
    updates:[
      upd({ kind:'update', statuses:['seen','water_provided'], comment:'Kase boştu, doldurdum. Her zamanki masasında.', createdAt: minutesAgo(6), authorId:'deniz', authorName:'Deniz' }),
      upd({ kind:'update', statuses:['seen'], comment:'Masaların üstünde geziyordu, keyfi yerinde.', createdAt: hoursAgo(7), authorId:'can', authorName:'Can' }),
      upd({ kind:'update', statuses:['fed'], comment:'', createdAt: daysAgo(12), authorId:'deniz', authorName:'Deniz' }),
      upd({ kind:'update', statuses:['seen'], comment:'', photo:PHOTOS.kadikoy, createdAt: daysAgo(21), authorId:'zehra', authorName:'Zehra' })
    ]
  },
  {
    id:'zeytin', name:'Zeytin',
    photos:[PHOTOS.kadikoy],
    mapPos:{lat:40.9889,lng:29.0331}, fallbackPos:{top:'22%',left:'62%'},
    areaLabel:'Yeldeğirmeni, Kadıköy',
    desc:'Siyah-beyaz, burnunda siyah leke. Fırının önünde bekler.',
    createdAt: daysAgo(200), createdBy:'mert',
    updates:[
      upd({ kind:'update', statuses:['seen','fed'], comment:'Fırının önündeydi, çok oyuncuydu. Kuru mama verdim.', createdAt: daysAgo(3), authorId:'deniz', authorName:'Deniz' }),
      upd({ kind:'update', statuses:['seen'], comment:'', createdAt: daysAgo(6), authorId:'elif', authorName:'Elif' })
    ]
  },
  {
    id:'balat-beyaz', name:null,
    photos:[PHOTOS.oldistanbul],
    mapPos:{lat:40.9857,lng:29.0276}, fallbackPos:{top:'30%',left:'46%'},
    areaLabel:'Caferağa, Kadıköy',
    desc:'Beyaz, gözlerinin çevresi gri. Genelde pencere pervazlarında görülüyor.',
    createdAt: daysAgo(90), createdBy:'can',
    updates:[
      upd({ kind:'update', statuses:['seen'], comment:'Üçüncü kattaki pervazda güneşleniyordu.', createdAt: daysAgo(5), authorId:'can', authorName:'Can' })
    ]
  },
  {
    id:'boncuk', name:'Boncuk', inCluster:true,
    photos:[PHOTOS.utilitybox],
    mapPos:{lat:40.9868,lng:29.0309}, fallbackPos:{top:'22%',left:'84%'},
    areaLabel:'Yeldeğirmeni, Kadıköy',
    desc:'Gri tekir, kuyruğu kısa. Elektrik kutusunun üstünde uyumayı seviyor.',
    createdAt: daysAgo(160), createdBy:'zehra',
    updates:[
      upd({ kind:'update', statuses:['seen'], comment:'İyi görünüyordu, mama kabı doluydu.', createdAt: daysAgo(2), authorId:'mert', authorName:'Mert' }),
      /* expired needs-help: 5 days old, well past the 72h ttl — stays in
         history without emphasis (docs/product/alerts.md) */
      upd({ kind:'help', helpReason:'food_needed', comment:'Birkaç gündür mama kabı hep boş, zayıflamış görünüyor.', createdAt: daysAgo(5), authorId:'zehra', authorName:'Zehra' }),
      upd({ kind:'update', statuses:['fed'], comment:'', createdAt: daysAgo(8), authorId:'deniz', authorName:'Deniz' })
    ]
  },
  {
    id:'kaplan', name:'Kaplan',
    photos:[PHOTOS.brickwall],
    mapPos:{lat:40.9812,lng:29.0344}, fallbackPos:{top:'78%',left:'60%'},
    areaLabel:'Osmanağa, Kadıköy',
    desc:'İri, çizgili tekir. Duvarların üstünden mahalleyi izler.',
    createdAt: daysAgo(250), createdBy:'elif',
    updates:[
      upd({ kind:'update', statuses:['seen'], comment:'', createdAt: daysAgo(12), authorId:'ayse', authorName:'Ayşe' }),
      upd({ kind:'update', statuses:['fed'], comment:'', createdAt: daysAgo(20), authorId:'deniz', authorName:'Deniz' })
    ]
  },
  {
    id:'duman', name:'Duman', inCluster:true,
    photos:[PHOTOS.fatih],
    mapPos:{lat:40.9863,lng:29.0316}, fallbackPos:{top:'30%',left:'80%'},
    areaLabel:'Yeldeğirmeni, Kadıköy',
    desc:'Gri, sarı gözlü. Bodrum kat pencerelerinden bakmayı seviyor.',
    createdAt: daysAgo(180), createdBy:'mert',
    updates:[
      upd({ kind:'update', statuses:['seen'], comment:'Bodrum kat penceresinden izliyordu.', createdAt: daysAgo(25), authorId:'deniz', authorName:'Deniz' })
    ]
  },
  {
    id:'sarman', name:'Sarman',
    photos:[PHOTOS.carpet],
    mapPos:{lat:40.9838,lng:29.0305}, fallbackPos:{top:'68%',left:'38%'},
    areaLabel:'Osmanağa, Kadıköy',
    desc:'Sarı, tombul. Halıcının önündeki minderde yatar.',
    createdAt: daysAgo(400), createdBy:'ayse',
    updates:[
      upd({ kind:'update', statuses:['seen','fed'], comment:'', createdAt: daysAgo(45), authorId:'ayse', authorName:'Ayşe' })
    ]
  },
  {
    id:'golge', name:'Gölge',
    photos:[PHOTOS.street2023],
    mapPos:{lat:40.9852,lng:29.0338}, fallbackPos:{top:'44%',left:'78%'},
    areaLabel:'Rasimpaşa, Kadıköy',
    desc:'Siyah, yeşil gözlü. Eskiden marketin arka sokağında görülürdü.',
    /* 14 months without an update → long_not_seen with the stronger
       12-month detail-level message (docs/product/cats.md) */
    createdAt: daysAgo(560), createdBy:'can',
    updates:[
      upd({ kind:'update', statuses:['seen'], comment:'', createdAt: daysAgo(425), authorId:'can', authorName:'Can' })
    ]
  },
  {
    id:'fistik', name:'Fıstık',
    photos:[PHOTOS.curious],
    mapPos:{lat:40.9776,lng:29.0301}, fallbackPos:{top:'82%',left:'34%'},
    areaLabel:'Moda Burnu, Kadıköy',
    desc:'Ufak tefek, üç renkli. Parkın alt tarafındaki kayalıklarda.',
    /* zero updates ever → empty timeline + long_not_seen */
    createdAt: daysAgo(60), createdBy:'zehra',
    updates:[]
  },
  {
    id:'minnos', name:'Minnoş', inCluster:true,
    photos:[PHOTOS.sultanahmet],
    mapPos:{lat:40.9862,lng:29.0308}, fallbackPos:{top:'26%',left:'76%'},
    areaLabel:'Yeldeğirmeni, Kadıköy',
    desc:'Beyaz-sarı, çok sokulgan. Kafelerin önünde dolaşıyor.',
    createdAt: daysAgo(120), createdBy:'elif',
    updates:[
      upd({ kind:'update', statuses:['seen'], comment:'', createdAt: hoursAgo(1), authorId:'elif', authorName:'Elif' })
    ]
  },
  {
    id:'pamuk', name:'Pamuk', inCluster:true,
    photos:[PHOTOS.brickwall],
    mapPos:{lat:40.9868,lng:29.0315}, fallbackPos:{top:'20%',left:'88%'},
    areaLabel:'Yeldeğirmeni, Kadıköy',
    desc:'Beyaz, mavi gözlü. Duvar diplerinde güneşlenir.',
    createdAt: daysAgo(110), createdBy:'mert',
    updates:[
      upd({ kind:'update', statuses:['water_provided'], comment:'', createdAt: hoursAgo(3), authorId:'zehra', authorName:'Zehra' })
    ]
  }
];

function findCat(id){
  for(var i=0;i<CATS.length;i++) if(CATS[i].id===id) return CATS[i];
  return null;
}
function catDisplayName(cat){ return cat.name || 'İsimsiz kedi'; }

/* ============================================================ map constants */
var CLUSTER_LATLNG = { lat:40.9865, lng:29.0312 };
var CLUSTER_ZOOM_THRESHOLD = 17;
var BASEMAP_TILE_URL = 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';
var BASEMAP_ATTRIBUTION = '&copy; <a href="https://carto.com/attributions" rel="noopener">CARTO</a>, &copy; <a href="https://www.openstreetmap.org/copyright" rel="noopener">OpenStreetMap</a>';
var ISTANBUL_BOUNDS = [[40.80,28.45],[41.25,29.55]];
var MAP_MIN_ZOOM = 11;
var DUPLICATE_DEMO_CAT_ID = 'portakal'; // add-cat picker starts here so the duplicate flow is reachable
var DUPLICATE_CHECK_RADIUS_M = 80;
// stand-in for the device location — same point the map opens centered on
var USER_APPROX_LOCATION = { lat:40.9822, lng:29.0288 };

function distanceMeters(a,b){
  var R=6371000, dLat=(b.lat-a.lat)*Math.PI/180, dLng=(b.lng-a.lng)*Math.PI/180;
  var la1=a.lat*Math.PI/180, la2=b.lat*Math.PI/180;
  var h = Math.sin(dLat/2)*Math.sin(dLat/2) + Math.cos(la1)*Math.cos(la2)*Math.sin(dLng/2)*Math.sin(dLng/2);
  return 2*R*Math.asin(Math.sqrt(h));
}
function formatDistance(meters){
  if(meters < 1000) return Math.max(10, Math.round(meters/10)*10) + ' m';
  return (meters/1000).toFixed(1).replace('.', ',') + ' km';
}

/* ============================================================ derivations */
function latestUpdate(cat){ return cat.updates.length ? cat.updates[0] : null; }
function latestUpdateAt(cat){ var u = latestUpdate(cat); return u ? u.createdAt : null; }

/* semantic freshness state (docs/product/map.md) */
function freshnessOf(cat){
  var ts = latestUpdateAt(cat);
  if(ts === null) return 'long_not_seen';
  var age = now() - ts;
  if(age < DAY) return 'today';
  if(age < 7*DAY) return 'this_week';
  if(age < 30*DAY) return 'this_month';
  return 'long_not_seen';
}
/* ≥12 months without any update → stronger detail-level message */
function isVeryStale(cat){
  var ts = latestUpdateAt(cat);
  if(ts === null) ts = cat.createdAt;
  return (now() - ts) >= VERY_STALE_AFTER;
}
function lastSeenText(cat){
  var ts = latestUpdateAt(cat);
  return ts === null ? 'Hiç güncelleme yok' : fmtTimeAgo(ts);
}

/* active needs-help alert: newest help update younger than 72h.
   there is no resolve action — the alert only expires (docs/product/alerts.md). */
function activeAlert(cat){
  for(var i=0;i<cat.updates.length;i++){
    var u = cat.updates[i];
    if(u.kind !== 'help') continue;
    return (now() - u.createdAt) < ALERT_TTL ? u : null; // newest help decides
  }
  return null;
}
function isExpiredAlert(u){ return u.kind === 'help' && (now() - u.createdAt) >= ALERT_TTL; }

/* care summary lines derived from recent history */
function careLine(cat, statusId, word){
  for(var i=0;i<cat.updates.length;i++){
    var u = cat.updates[i];
    if(u.kind !== 'update' || u.statuses.indexOf(statusId) === -1) continue;
    var age = now() - u.createdAt;
    if(age < DAY) return 'Bugün ' + word;
    if(age < 2*DAY) return 'Dün ' + word;
    return null;
  }
  return null;
}
function waterLine(cat){ return careLine(cat, 'water_provided', 'su verildi') || 'Bilinmiyor'; }
function foodLine(cat){ return careLine(cat, 'fed', 'mama verildi') || 'Bilinmiyor'; }

/* own-update correction window (docs/product/updates.md — exactly 10 minutes) */
function canDeleteUpdate(u, user){
  return !!user && u.authorId === user.id && (now() - u.createdAt) < UPDATE_EDIT_WINDOW;
}
function deleteWindowLeft(u){ return UPDATE_EDIT_WINDOW - (now() - u.createdAt); }

/* ============================================================ badges */
/* final mvp badge vocabulary and thresholds (docs/product/badges.md).
   progress is derived by scanning update history + created cats for the
   given user id, so seed data and live demo contributions stay consistent. */
var BADGE_DEFS = [
  { id:'first_sighting', name:'İlk Görüş', icon:'eye', target:1,
    condition:'İlk "Görüldü" güncellemeni paylaş.',
    descr:'Bir kediyi görüp haber verdin. Her şey görmekle başlar.' },
  { id:'feeder', name:'Mamacı', icon:'bowl', target:5,
    condition:'5 kez "Mama verildi" güncellemesi paylaş.',
    descr:'Mahallenin kedileri sayende aç kalmıyor.' },
  { id:'water_helper', name:'Sucu', icon:'droplet', target:5,
    condition:'5 kez "Su verildi" güncellemesi paylaş.',
    descr:'Temiz su, en az mama kadar önemli. Kaseleri boş bırakmadın.' },
  { id:'neighborhood_watcher', name:'Mahalle Bekçisi', icon:'pin', target:10,
    condition:'10 farklı kedi için "Görüldü" güncellemesi paylaş.',
    descr:'Mahallendeki kedilerin gözü kulağı oldun.' },
  { id:'cats_of_istanbul', name:'İstanbul\'un Kedileri', icon:'paw', target:25,
    condition:'Güncelleme, fotoğraf veya yeni kedi ekleyerek 25 farklı kediye katkıda bulun.',
    descr:'Şehrin kedileri seni tanıyor. Bu rozet, İstanbul\'a emeğin için.' }
];

function userContributions(userId){
  /* flat, newest-first list of everything the user did — feeds both the badge
     engine and the profile's "recent contributions" list */
  var out = [];
  CATS.forEach(function(cat){
    if(cat.createdBy === userId){
      out.push({ type:'cat_added', catId:cat.id, at:cat.createdAt });
    }
    cat.updates.forEach(function(u){
      if(u.authorId !== userId) return;
      out.push({ type:u.kind, catId:cat.id, update:u, at:u.createdAt });
    });
  });
  out.sort(function(a,b){ return b.at - a.at; });
  return out;
}

function badgeProgress(userId){
  var contribs = userContributions(userId);
  var counts = { seen:0, fed:0, water_provided:0 };
  var seenCats = {}, allCats = {};
  var firstSeenAt = null, thresholdAt = {};

  /* walk oldest→newest so "earned at" lands on the update that crossed the line */
  for(var i=contribs.length-1;i>=0;i--){
    var c = contribs[i];
    allCats[c.catId] = true;
    if(c.type === 'update' && c.update){
      c.update.statuses.forEach(function(s){
        counts[s] = (counts[s]||0) + 1;
        if(s === 'seen'){
          if(firstSeenAt === null) firstSeenAt = c.at;
          seenCats[c.catId] = true;
          if(Object.keys(seenCats).length === 10 && !thresholdAt.neighborhood_watcher) thresholdAt.neighborhood_watcher = c.at;
        }
        if(s === 'fed' && counts.fed === 5) thresholdAt.feeder = c.at;
        if(s === 'water_provided' && counts.water_provided === 5) thresholdAt.water_helper = c.at;
      });
    }
    if(Object.keys(allCats).length === 25 && !thresholdAt.cats_of_istanbul) thresholdAt.cats_of_istanbul = c.at;
  }

  var progress = {
    first_sighting:       { value: firstSeenAt ? 1 : 0, earnedAt: firstSeenAt },
    feeder:               { value: counts.fed,             earnedAt: thresholdAt.feeder || null },
    water_helper:         { value: counts.water_provided,  earnedAt: thresholdAt.water_helper || null },
    neighborhood_watcher: { value: Object.keys(seenCats).length, earnedAt: thresholdAt.neighborhood_watcher || null },
    cats_of_istanbul:     { value: Object.keys(allCats).length,  earnedAt: thresholdAt.cats_of_istanbul || null }
  };
  return BADGE_DEFS.map(function(def){
    var p = progress[def.id];
    return {
      def: def,
      value: Math.min(p.value, def.target),
      earned: p.value >= def.target,
      earnedAt: p.value >= def.target ? p.earnedAt : null
    };
  });
}

function contributionTotals(userId){
  var contribs = userContributions(userId);
  var updates = 0, helps = 0, catsAdded = 0, cats = {};
  contribs.forEach(function(c){
    cats[c.catId] = true;
    if(c.type === 'update') updates++;
    else if(c.type === 'help') helps++;
    else if(c.type === 'cat_added') catsAdded++;
  });
  return { updates:updates, helps:helps, catsAdded:catsAdded, distinctCats:Object.keys(cats).length };
}
