---
id: T-379
title: Host — WIFI_ADAPT v2: yalnız bit hızı, doğrulanmış tıkanıklık kanıtı, IDR'sız (astra öneri 1)
status: todo
phase: 7
owner: mac-host-dev
depends_on: [T-378]
decisions: [0023]
files:
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - docs/KNOBS.md
  - tools/measure/
  - backlog/tasks/T-379-host-wifi-adapt-v2.md
---

## Amaç

`docs/reviews/2026-10-25/astra-wifi-game.md` öneri 1. Kontrol yasası: **0023 eki 2026-10-25** (sinyaller S/D/L/B, ağır/orta yanıt, taban 30 / acil 20, +2 Mbps/sn). Sabitler oradan alınır; ekten sapma gerekirse Open questions'a yazılır, kendiliğinden değiştirilmez.

## Kabul

1. `MATEBRIDGE_WIFI_ADAPT=1` v2 denetleyicisini kurar; v1 denetleyicisi ve ek gönderim kapısı (uçuştaki bayt bütçesi) kaldırılır. Anahtar kapalıyken davranış bugünküyle bayt bayt aynı (mevcut testler yeşil).
2. Açıkken değişen tek şey canlı kodlayıcı bit hızı: akış yeniden başlamaz, IDR istenmez, `config_id` değişmez, gönderim kapısı/kuyruk sınırları bit hızına bağlanmaz.
3. Saf (Pure Swift, zaman enjekte) denetleyici 0023 ekindeki yasayı uygular; S sinyali gönderici tarafından (yazım/kuyruk başı yaşı ve bayt ilerlemesi) beslenir, ilerleyen büyük keyframe yazımı stall sayılmaz.
4. İz tekrarları (`CongestionReplayTrace` örneği gibi, sayısal özet; ham log commitlenmez):
   - 2026-10-25 20:55:36–41 takılması: ikinci stall'dan sonra ≤ 1 sn içinde ×0,7 düşüş; olay sırasında tabanın altına inmez; temizlikten sonra tavana +2 Mbps/sn döner.
   - 2026-10-25 14:25–15:11 temiz oturum: düşüş ≤ 1/10 dk, tabana hiç inmez.
   - v1 çöküş biçimi (tek srtt sıçraması, tekrar eden srtt fazlası birikimsiz): düşüş yok.
5. Birim testleri: taze kanıt kuralı, en sık adım aralıkları, acil tabanın yalnız 30'da 2 sn ağır kanıttan sonra devreye girmesi, tavan değişimi (kullanıcı bit hızını düşürürse anında uyulur), bağlantı değişiminde taban sıfırlama, USB'de hiç kurulmaması.
6. Kayıt: `video ev=adapt` + saniyelik durum alanları `docs/LOGGING.md`'de; `docs/KNOBS.md` satır 48 v2'yi anlatır.
7. Cihaz (orkestratör, sonra): Oyun 60, anahtar açık; `sent_kbps` `bitrate_set`'i izliyor, takılma anında düşüş, temizlikte geri dönüş. Varsayılan açma ayrı ek ile.

## Plan

## Handoff

## Open questions
