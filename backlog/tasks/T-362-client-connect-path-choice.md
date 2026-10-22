---
id: T-362
title: İstemci — bağlantı ekranı "Yerel ağ | Tailscale" + veri tasarrufu, Bağlan/Durdur, açılışta bağlanma yok
status: in_progress
phase: 7
owner: android-client-dev
depends_on: [T-352]
decisions: [0042, 0038]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/main/res/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - docs/LOGGING.md
  - backlog/tasks/T-362-client-connect-path-choice.md
---

## Amaç

Karar 0042'yi uygula: giriş ekranında "Yerel ağ | Tailscale" seçimi, Tailscale'de "Veri tasarrufu" anahtarı, Bağlan ↔ Durdur, açılışta kendiliğinden bağlanma yok. "Uzaktan bağlan", "Uzak adres", "Manuel adres" giriş ekranından kalkar.

Arka plan (2026-10-22 logları): yerel yolda `origin=saved_wifi host=100.77.121.48` (kullanıcının elle yazdığı Tailscale adresi), Bonjour `192.168.1.106` bulduğu halde 5 sn'de bir aynı 100.x denendi, boşuna WoL. Kod: `MainActivity.lastWifiEndpoint`, `startWifi()`, `onDiscovered`/`EndpointRediscovery`.

## Kabul

1. Giriş ekranı 0042 §1'deki gibi. Görsel dil T-352 (segmentli kontrol, Switch, metin düğmeleri); yeni bağımlılık yok.
2. **Yerel ağ:** USB + Bonjour, tam kalite. Yerel yol hiçbir koşulda Tailscale adresine ya da eski elle adrese bağlanmaz. `lastWifiEndpoint` yalnız Bonjour'dan (ya da USB'den) gelen bir adresle dolar; Tailscale yollarından asla.
3. **Tailscale + tasarruf açık** = bugünkü 0038 uzak oturumu (davranış aynen). **Tailscale + tasarruf kapalı** = Tailscale adresine normal oturum (kullanıcının mod/görüntü ayarları), WoL yok, kopunca aynı adrese yeniden bağlanır.
4. Tailscale adresi ayarlarda tek alan (bugünkü uzak adres alanı, `remote_endpoint` anahtarı, ayrıştırma `RemoteAddress`). Tailscale seçili, adres yokken "Bağlan" adresi sorar.
5. **Açılışta bağlanma yok:** `onStart`/`onResume`/ilk açılışta hiçbir bağlantı, bulma kaynaklı otomatik bağlanma ya da WoL denemesi yok. "Bağlan"dan sonra bugünkü otomatik davranışlar (taşıma seçimi, bulma, yeniden bağlanma, Mac uyanınca bağlanma, USB↔Wi-Fi geçişi) "Durdur" ya da "Bağlantıyı kes"e kadar sürer.
   - Bağlıyken uygulama arka plana gidip dönerse yeniden bağlanma bugünkü gibidir (kullanıcı durdurmadıysa).
   - Süreç öldürülüp yeniden açılırsa bekleme durumuna döner.
6. **Durdur:** bağlanma/yeniden bağlanma döngüsünü, bulma kaynaklı bağlanmayı ve WoL'u keser, ekran "Bağlan"a döner. Tutulan girdi yoksa da release-all kuralları değişmez (AGENTS.md).
7. Seçim (yol + tasarruf) kalıcı hatırlanır (yeni anahtarlar), "Varsayılanlara dön" bunu sıfırlar; Tailscale adresi bugünkü gibi korunur.
8. **Taşıma** (0042 §7): eski elle adres anahtarı varsa, Tailscale adresi boşken 100.64.0.0/10 içindeyse Tailscale adresine taşınır, değilse silinir. Bir kez çalışır, testli.
9. Log: `ev=connect_path path=local|tailscale saver=0|1` (Bağlan'da), `ev=connect_stop` (Durdur'da); LOGGING.md.
10. Testler: yol seçimi → bağlantı hedefi/profil eşlemesi (saf mantık, birim test), taşıma kuralı, "açılışta deneme yok" ve "Durdur sonrası deneme yok" durum makinesi testi (mümkün olan katmanda), yerel yolun 100.x'e asla gitmemesi.
11. Eşleşme/güven metinleri ve akışı değişmez. Uzak eşleşme reddi (0038 §5) aynen.

## Plan

## Handoff

## Open questions
