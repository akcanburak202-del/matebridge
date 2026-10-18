---
id: T-352
title: İstemci — giriş ekranı ve ayar paneli için sade (minimalist) yeniden tasarım
status: done
phase: 7
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/res/
  - client-android/app/src/test/kotlin/dev/matebridge/client/settings/
  - backlog/tasks/T-352-client-minimal-ui.md
---

## Amaç

Kullanıcı (2026-10-17): giriş ekranı ve panel göze hoş görünmüyor; daha sade bir düzen ve tasarım istiyor. Yön (kullanıcıya önerildi, itiraz yok): koyu ve sade, tek vurgu rengi, az kutu ve çerçeve, boşluklu gruplu düzen; giriş ekranında tek belirgin "Bağlan", diğer seçenekler geri planda.

Mevcut panelin ekran görüntüsü (yan panel, akış sırasında): `/private/tmp/claude-501/-Users-burakakcan-Desktop-matebridge/20e9f1cb-a4c8-49e2-830f-cc0896d258de/scratchpad/panel.png` (Read ile bak; repoya kopyalama, Mac masaüstü içerir).

## Gözlenen sorunlar

- Yarı saydam panel arkasındaki masaüstü okunabilirliği bozuyor.
- Her seçenek kalın, dolgulu bir "hap" düğme. Satırlar sığmayınca alta kayıyor, sağda kesilen düğme var ("30 Mbps").
- Başlık tekrarı: bölüm "Bağlantı" ve altında yine "Bağlantı".
- "Bağlantıyı kes" ve "Bu Mac'i unut" seçeneklerle aynı ağırlıkta, tehlikeli eylemler ayrışmıyor.
- "Uygulanan: …" bilgi satırları seçeneklerle aynı görsel ağırlıkta.
- Uzun tek sütun liste, gruplama zayıf.

## Kapsam

1. **Görsel dil** (`res/values` içinde renk, boyut ve stil kaynakları, tek yerden): koyu yüzey (#121212 benzeri, panel opak ya da çok az saydam), tek vurgu rengi, ikincil metin soluk gri, yazı ölçeği 3 seviye (başlık / etiket / ikincil). 8 dp ızgara boşlukları.
2. **Seçim kontrolleri:** dolgulu hap düğmeler yerine segmentli kontrol (ince çerçeveli, seçili segment vurgu dolgulu). Taşan seçenekler (bit hızı, oyun çözünürlüğü) satıra sığmıyorsa açılır liste ya da yatay kaydırma kullan; hiçbir düğme kesilmesin. Açık/Kapalı ayarlar Switch olsun (etiket solda, anahtar sağda).
3. **Düzen:** bölümler (Bağlantı, Görüntü, Girdi, Ses, Dosyalar…) tek başlık, altında az boşluklu satırlar; tekrar eden başlıkları kaldır. "Uygulanan: …" gibi bilgi satırları küçük ve soluk, ilgili kontrolün altında. Tehlikeli eylemler (Bağlantıyı kes, Bu Mac'i unut, Varsayılanlara dön) en altta ayrı, metin düğmesi biçiminde (Bu Mac'i unut kırmızımsı).
4. **Giriş ekranı:** ortada uygulama adı/simgesi, bulunan Mac adı ve durum metni, tek büyük "Bağlan" düğmesi. "Uzaktan bağlan", elle adres ve ayarlar ikincil (metin düğmeleri ya da altta bir "Ayarlar" açılımı). Eşleşme/güven akışı metinleri aynı kalır, yalnız görünüm değişir.
5. Ayar kataloğu (`SettingsCatalog`) ve davranış **değişmez**: aynı ayarlar, aynı anahtarlar, aynı varsayılanlar, aynı gizleme kuralları (uzak oturum vb.). Değişiklik görünüm katmanında (`SettingsViews`, layout, res). Katalog testleri geçmeli.
6. Klavye/gamepad ile gezinme ve odak (T-246 focus highlight kuralı: video yüzeyinde kapalı) bozulmamalı. Panel açıkken girdi davranışı aynı kalır.
7. Yeni bağımlılık yok (Material Components ekleme; düz Android view + drawable/state-list ile yap).

## Kabul

- `./scripts/check.sh` geçer. Görünüm için birim testi gerekmez; katalog/etiket testleri değişmeden geçer (değiştiyse gerekçesi Handoff'ta).
- Handoff'ta önce/sonra kısa bir açıklama (hangi kontrol ne oldu). Cihaz görüntüsü orkestratörde alınır.
- Not: kamera özelliği (ayrı kart) paralel olarak katalog'a bir "Kamera" seçeneği ekleyecek; senin işin genel görünüm, yeni bir öğe türü gerekmiyor (Choice ve Toggle yeterli).

## Plan

Renk, ölçü ve stil kaynakları `res/values` (colors, dimens, styles) + drawable seçiciler; `SettingsViews` görünüm katmanı yeniden yazılır (katalog dokunulmaz); `activity_main.xml` giriş ekranı sadeleşir; "Ayarlar" metin düğmesi ayar listesini açar/kapatır (MainActivity'de 3 satır).

## Handoff

Commit: `git log task/T-352-minimal-ui` (tek T-352 commit). Dosyalar: `res/values/{colors,dimens,styles}.xml`, `res/drawable/mb_*.xml`, `res/layout/activity_main.xml`, `settings/SettingsViews.kt`, `MainActivity.kt` (yalnız settings_toggle dinleyicisi), bu kart. `SettingsCatalog`, `SettingsButtonPalette` ve testler değişmedi.

Önce / sonra:
- Panel: yarı saydam (%85) -> opak #121212; tek vurgu mavi #2E7DFF; yazı 24/16/13 sp.
- Choice: dolgulu hap düğmeler + yatay kaydırma -> ince çerçeveli segmentli kontrol; satırda en çok 4 (uzun etiket veya 5+ seçenekte 3) segment, fazlası alt satıra sarılır, hiçbir şey kesilmez (etiket 2 satıra sarabilir). Bölüm başlığıyla aynı olan seçenek başlığı ("Bağlantı") kaldırıldı.
- Toggle: "başlık: açık" düğmesi -> etiket solda, Switch sağda (tüm satır dokunma alanı).
- Stepper: dolgulu "− +" düğmeleri -> sağda ince çerçeveli küçük "− değer +".
- Info ("Uygulanan: …", kısayollar, sürüm): 13 sp soluk gri, kontrolün altında.
- Eylemler (Bağlantıyı kes, Bu Mac'i unut [kırmızımsı], Varsayılanlara dön + ipucu): bölümlerden çıkarılıp en altta ayırıcı çizgi altında metin satırları.
- Giriş ekranı: simge + "MateBridge" + durum (soluk) + tek büyük "Bağlan"; Mac'i uyandır / Uzaktan bağlan / Uzak adres / Manuel adres / Ayarlar metin düğmeleri; ayar listesi "Ayarlar" ile açılır (varsayılan kapalı). Alanlar çerçeveli.
- Odak: kendi çizilen beyaz halka; defaultFocusHighlight kapalı (T-246).

Varsayımlar: Material yok, `android.widget.Switch` kullanıldı. Giriş simgesi `@mipmap/ic_launcher`. Güven (trust) düğmeleri hâlâ eski `styleSettingsButton` ile (kodla üretiliyor, kapsam dışı).

Tablette bakılacak: (1) giriş ekranı düzeni, "Ayarlar" aç/kapa; (2) yan panelde segment satırları (Oyun çözünürlüğü, Bit hızı) kesilmeden sığıyor mu, "Otomatik (60 Mbps)" okunuyor mu; (3) Switch satırları, uzak oturumda gizlenen satırlar; (4) klavye/gamepad odak halkası ve Tab gezinmesi, video yüzeyinde beyaz örtü yok; (5) Kapat, dışarı dokunma, Bu Mac'i unut iki adımlı onay çalışıyor mu. Cihazda hiçbir şey test edilmedi (görünüm birim testi yok).

## Open questions
