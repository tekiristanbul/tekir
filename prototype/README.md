# cats istanbul — hi-fi prototip

issue #5 kapsamında, `docs/design/wireframes.html`'deki ekran ve akışların lokalde gezilebilir, görsel olarak
tamamlanmış bir versiyonu. figma değil — build step veya framework yok, doğrudan `index.html` açılarak ya da
basit bir static server ile çalışır.

## çalıştırma

```
cd prototype
python3 -m http.server 8000
```

sonra `http://localhost:8000` adresini aç. `index.html`'i çift tıklayarak (file://) açmak da çalışır; harita için
internet bağlantısı gerekir, yoksa harita alanı desende bir fallback görünüme düşer, marker'lar yine görünür kalır.

## dosyalar

- `index.html` — uygulama kabuğu, 9 ekran
- `styles.css` — design token'lar (renk, tipografi, spacing, radius, elevation) + tekrar kullanılabilir component class'ları
- `icons.js` — paylaşılan svg ikon seti, hem uygulama hem design-system.html tarafından kullanılır
- `app.js` — ekran render'ları, state, navigasyon, leaflet harita entegrasyonu
- `design-system.html` — ekranlardan bağımsız component/token kataloğu, aynı `styles.css`'i kullanır

## kedi fotoğrafları

Tamamı wikimedia commons üzerinden, cc lisanslı, gerçek sokak kedisi fotoğrafları:

| kullanım | dosya | fotoğrafçı | lisans |
|---|---|---|---|
| Portakal | [Cat near Kabataş in Istanbul](https://commons.wikimedia.org/wiki/File:Cat_near_Kabata%C5%9F_in_Istanbul,_20260605_1734_1298.jpg) | Jakub Hałun | CC BY 4.0 |
| Zeytin | [Cats, Kadikoey, Istanbul](https://commons.wikimedia.org/wiki/File:Cats,_Kadikoey,_Istanbul_(P1100168).jpg) | Matti Blume | CC BY-SA |
| Sultan | [Istanbul - cat of Sultanahmet](https://commons.wikimedia.org/wiki/File:Istanbul_-_cat_of_Sultanahmet.jpg) | Jorge Franganillo | CC BY 4.0 |
| (isimsiz, beyaz-kızıl) | [Old Istanbul Cat](https://commons.wikimedia.org/wiki/File:Old_Istanbul_Cat.jpg) | Amak-i Hayal | CC BY-SA 4.0 |
| Yavru | [Cat, Istanbul (P1180136)](https://commons.wikimedia.org/wiki/File:Cat,_Istanbul_(P1180136).jpg) | Matti Blume | CC BY-SA |
| Kaplan | [Turkey (Istanbul) Street cat](https://commons.wikimedia.org/wiki/File:Turkey_(Istanbul)_Street_cat_(21956691179).jpg) | Flickr / f_snarfel | CC BY 2.0 |

görsel yüklenemezse (`onerror`) tüm `<img>`'ler bir pati ikonlu, marka renginde bir fallback'e düşer — boş gri
placeholder yok.

## harita

leaflet + openstreetmap, cdn üzerinden (`unpkg.com/leaflet`). merkez: kadıköy/moda, sokak seviyesi zoom.
leaflet cdn'den yüklenemezse ya da tile istekleri başarısız olursa, uygulama otomatik olarak aynı kedi
marker'larını grid desenli statik bir fallback zemin üzerinde absolute pozisyonlarla gösterir — harita boş kalmaz.

## kapsam dışı bırakılan / uyarlanan noktalar

- `docs/product/trust.md`'deki karara göre: metin-only durum güncellemesi ve takip etme girişsiz yapılabilir;
  yalnızca fotoğraf/medya eklemek ve yeni kedi eklemek giriş + telefon doğrulama gerektirir.
- `docs/product/alerts.md`'ye göre: "yardım gerekiyor" bildirimi oluşturmak fotoğraf eklenmese bile her zaman
  giriş gerektirir (alert'lerin takipçilere gittiği için daha yüksek bir güven eşiği var).
- wireframe'deki "medya olmadan devam et" aksiyonu kaldırıldı — yukarıdaki kurala göre metin-only update zaten
  giriş istemiyor, o kısayola gerek kalmadı. yerine genel bir "vazgeç" var.
- durum güncellemesi eklerken ilk gönderim denemesi, hata + "tekrar dene" state'ini göstermek için bilinçli
  olarak bir kere başarısız olacak şekilde simüle edildi; sonraki denemeler normal çalışır.
- "kedi ekle: konum" ekranı, kayıtlı bir kedinin (Portakal) yakınında başlıyor — bu, "burada zaten kayıtlı bir
  kedi var mı" modalını ilk denemede görebilmek için bilinçli bir demo kararı.
