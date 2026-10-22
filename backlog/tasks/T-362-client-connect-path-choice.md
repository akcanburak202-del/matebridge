---
id: T-362
title: İstemci — bağlantı ekranı "Yerel ağ | Tailscale" + veri tasarrufu, Bağlan/Durdur, açılışta bağlanma yok
status: review
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

Saf mantık `session/ConnectPath.kt` (birim testli): `ConnectPath` (LOCAL/TAILSCALE) + `ConnectChoice(path, saver)`, `ConnectPlanner.plan(choice, tailscaleAddr)` -> `Local | Tailscale(ep, saver) | NeedAddress`, `ConnectGate` (engaged: Bağlan'la açılır, Durdur/Bağlantıyı kes ile kapanır, süreç başında kapalı; `waitingOnStart`), `ConnectButton.label(engaged, ui)` (Durdur yalnız bağlanma sürerken), `WifiMemory.mayRemember(origin, ep, pinned)` (Tailscale/elle/100.64.0.0/10 adresleri asla `lastWifiEndpoint` olmaz), `TailscaleMigration` (eski `last_endpoint` -> Tailscale adresi ya da silinir). `Settings`: yeni anahtarlar `connect_path`, `connect_saver` (USER_KEYS'e girer, "Varsayılanlara dön" sıfırlar), `tailscaleEndpoint()` = bugünkü `remote_endpoint` anahtarı, `migrateManualEndpoint()` bir kez.

MainActivity: `engaged` bayrağı. `onStart`: engaged ise bugünkü başlangıç (plana göre), değilse `userDisconnected = true` bekleme (hiç bağlanma/bulma/WoL yok). `userDisconnect` (Bağlantıyı kes + Durdur) engaged'i kapatır. "Bağlan": plana göre `startTailscale(ep, saver)` (saver: remoteSession=true, 0038 profili; değil: normal oturum, yalnız `pinnedSession`) ya da yerel `applyTransport`. Otomatik davranışları kapatan `remoteSession` kontrolleri `pinnedSession` (remote || Tailscale tam kalite) olur. Elle adres alanı ve düğmeleri giriş ekranından kalkar; Tailscale adres alanı (tek, `remote_endpoint`) Tailscale seçiliyken "Tailscale adresi" satırı ile açılır. Giriş ekranında segment + Switch (SettingsViews'teki biçim) kodla eklenir. Log `connect_path`, `connect_stop`; LOGGING.md.

## Handoff

Commit: 09533075 (kod) + kart güncellemesi (dal `task/T-362-client-connect-path-choice`). `./scripts/check.sh --only android` geçti (tam `check.sh` değil: yalnız istemci dokunuldu).

Dosyalar: `session/ConnectPath.kt` (yeni, saf mantık), `session/Settings.kt` (`connect_path`/`connect_saver`, `tailscaleEndpoint()`, `migrateManualEndpoint()`), `session/TrustUiText.kt` (`ConnectOrigin.TAILSCALE`), `settings/ConnectChoiceViews.kt` (yeni, segment + Switch), `MainActivity.kt`, `res/layout/activity_main.xml`, `res/values/strings.xml`, `docs/LOGGING.md`, test `session/ConnectPathTest.kt`.

Ne oldu:
- Giriş ekranı: "Yerel ağ | Tailscale" segmenti, Tailscale'de "Veri tasarrufu" Switch'i, tek büyük Bağlan/Durdur, "Mac'i uyandır" (yalnız Yerel ağ), "Tailscale adresi" (yalnız Tailscale) ve "Ayarlar". "Uzaktan bağlan", "Uzak adres", "Manuel adres" ve elle adres alanı kalktı.
- Açılışta bağlanma yok: `ConnectGate.engaged` (bellekte). `onStart` engaged değilse `userDisconnected=true` ile bekler (keşif, USB probe, WoL, otomatik yeniden bağlanma hepsi zaten bu bayrağa bağlı). Bağlan sonrası arka plana gidip dönmek eskisi gibi yeniden bağlanır. Durdur / Bağlantıyı kes / unutma `userDisconnect()` ile engaged'i kapatır. Süreç ölürse bekler.
- Yerel yol: `lastWifiEndpoint` yalnız `WifiMemory.mayRemember` izin verirse dolar (REMOTE/TAILSCALE/TYPED_ADDRESS origin, pinned oturum ve 100.64.0.0/10 ya da `.ts.net` adresi asla). `startWifi` ayrıca 100.x/ts.net adresi `SAVED_WIFI` olarak denemez. Bugünkü hata (5 sn'de bir 100.x) bu yüzden yapısal olarak biter.
- Tailscale + tasarruf açık: eski `startRemote` davranışı aynen (`ConnectOrigin.REMOTE`, `remoteSession`). Tailscale + tasarruf kapalı: `ConnectOrigin.TAILSCALE`, normal profil, `tailscaleFull` bayrağı; `pinnedSession = remoteSession || tailscaleFull` eski `remoteSession` otomatik-davranış korumalarının hepsine (AUTO göç, probe, fallback, keşif, rediscovery, WoL, pick prompt, "eşleşme reddedildi" metni) geçti. Profil/ses/imleç/dosya/kamera koşulları `remoteSession`'da kaldı.
- Seçim kalıcı (`connect_path`, `connect_saver`; USER_KEYS, "Varsayılanlara dön" sıfırlar, Tailscale adresi kalır). Seçim değişirse çalışan deneme Durdur'a eşdeğer durdurulur.
- Taşıma: açılışta `migrateManualEndpoint()`; eski `last_endpoint` 100.64.0.0/10 ise ve Tailscale adresi boşsa taşınır, aksi halde silinir; anahtar silindiği için bir kez. Log `manual_endpoint_migrated`.
- Loglar: `connect_path`, `connect_stop`, LOGGING.md.

Varsayımlar / sapmalar:
- Kart 4: "Tailscale adresi ayarlarda tek alan". Ayarlar listesi (SettingsCatalog) metin alanı türü içermiyor; yeni öğe türü eklememek için alan giriş ekranında, yalnız Tailscale seçiliyken "Tailscale adresi" düğmesiyle açılıyor (HiWrite kuralı korunur: kapalıyken gizli+devre dışı). Klavye Done = Bağlan. Akış içi yan panelde adres alanı yok.
- Durdur etiketi yalnız Aranıyor/Bağlanılıyor/Bağlantı yok (yeniden deneme) durumlarında; Hazır/Failed/eşleşme durumlarında "Bağlan" kalır (iptal-latch'i kaldıran eski Bağlan akışı korunsun diye). Basınca eski mantık çalışır.
- Bağlan'dan sonra uygulama içi aktarım modu (Otomatik/USB/Wi-Fi) değişirse engaged değilken yalnız kaydedilir, bağlanmaz.
- Adb ile test: uygulama artık açılınca bağlanmıyor; orkestratör Bağlan'a dokunmalı (ya da `adb shell input tap`). Başlatma extra'sı eklenmedi (kart "açılışta bağlanma yok" diyor).
- Birim testleri: yol -> plan eşlemesi, kalıcılık/reset, ConnectGate (taze süreç bekler, arka plan dönüşü yeniden bağlanır, Durdur sonrası bekler), Durdur etiketi, 100.x'in `lastWifiEndpoint` olmaması, taşıma (Settings üzerinden bir kez). `MainActivity` bağlama kodu (UI, ağ) birim testsiz.

Tablette bakılacak:
1. Taze açılış (kill + aç): "Hazır", hiçbir `transport`/`transport_pick`/`wol_*`/discovery logu yok; "Bağlan" ile bağlanıyor, loglarda `ev=connect_path path=local saver=0`.
2. Yerel ağ seçili, eski 100.x elle adres kayıtlıyken (taşıma sonrası): Bonjour adresine bağlanır, 100.x denenmez. Tailscale kapalıyken de bağlanır.
3. Tailscale + tasarruf açık: eski uzak oturum (15 fps, 1400x920, panel "Uzak (Tasarruf)"); kapalı: tam kalite normal oturum, `origin=tailscale`, WoL yok, ekranı kapatıp açınca ve kopunca aynı adrese yeniden bağlanır. Adres yokken Bağlan alanı açar ve uyarır.
4. Bağlanırken "Durdur": döngü, bulma ve WoL durur, ekran "Bağlan"a döner, "Bağlantı kesildi" metni; arka plana gidip dönünce yeniden bağlanmaz.
5. Bağlan sonrası uygulamayı arka plana al ve dön: yeniden bağlanır. Segment/Switch seçimi uygulama yeniden açılınca hatırlanıyor; "Varsayılanlara dön" Yerel ağ'a çeviriyor, adres kalıyor. Segment ve Switch odak halkası (klavye).

## Open questions
- Tailscale adresi alanı ayarlar listesinde değil giriş ekranında (yukarıdaki sapma). İstenirse ayrı bir kartla SettingsCatalog'a metin öğesi eklenir.
