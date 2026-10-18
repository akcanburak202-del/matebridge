---
id: T-352
title: İstemci — giriş ekranı ve ayar paneli için sade (minimalist) yeniden tasarım
status: todo
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

## Handoff

## Open questions
