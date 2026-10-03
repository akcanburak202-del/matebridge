---
id: T-207
title: Clear the "asked to pair" mark on a Mac's endpoints once that Mac is trusted, so AUTO returns to USB
status: review
phase: 6
owner: android-client-dev
depends_on: [T-151]
decisions: [0018]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/AutoTransport.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/TrustUiText.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - backlog/tasks/T-207-client-clear-usb-asked-after-trust.md
---

## Amaç

Cihaz oturumu 2026-10-04 (docs/NOTES.md, 4. adım): Mac'te "Onaylı cihazları unut" sonrası hem USB (`127.0.0.1:47001`) hem Wi-Fi uç noktası PAIRING cevabı verdi. T-151, otomatik bağlantıda PAIRING isteyen adresi kullanıcı başlatana kadar atlıyor (`pair_auto_skip`, AUTO'da `transport_pick reason=usb_lost` olarak görünüyor). Kullanıcı eşleşmeyi Wi-Fi üzerinden tamamladı ve aynı Mac'e artık güveniliyor, ama USB adresindeki işaret kalmadı: AUTO kablo takılıyken Wi-Fi'de kaldı. Ancak "Bağlantıyı kes" + "Bağlan" ile USB'ye döndü.

## Bağlam

- İşaret, sahte bir uç noktanın tableti eşleşme istemine kilitlemesini önlüyor (0018 son madde); bu güvence korunmalı.
- Güven onayı (`pair_trust_confirmed`) ya da güvenilen anahtarla PAIRED bir oturum, o `host_id` için artık eşleşmenin gerekmediğini kanıtlar. O anda, aynı Mac'e ait olduğu bilinen uç noktaların (USB tüneli ve keşfedilen/hatırlanan Wi-Fi adresi) işareti temizlenebilir; bilinmeyen başka adreslerin işareti kalır.
- `transport_pick reason=usb_lost` bu durumda yanıltıcı; ayrı bir neden (`usb_asked`) zaten var (T-151 LOGGING) — doğru neden yazılmalı.

## Kapsam dışı

- Host değişikliği, protokol değişikliği.

## Kabul kriterleri

- [x] [JVM] Senaryo: USB ve Wi-Fi uç noktaları PAIRING ister → kullanıcı Wi-Fi'de eşleşir ve güvenir → AUTO, kablo takılıyken USB'ye geçer (USB yoklaması ve geçişi yeniden denenir), kullanıcı eylemi gerekmez.
- [x] [JVM] Güvenilmeyen/başka `host_id`'li bir uç noktanın işareti güven onayıyla temizlenmez (0018 kilitlenme güvencesi).
- [x] [JVM] PAIRING isteyen USB için seçilen neden `usb_lost` değil `usb_asked` olarak loglanır.
- [ ] [device] "Onaylı cihazları unut" → Wi-Fi'de yeniden eşleş → birkaç saniye içinde `transport_migrate ok=1 to=usb`.

## Plan

1. **Kimlik etiketi (dosya listesi dışı, minimal):** `SessionUi.kt` içine opak `HostTag` (16 bayt host_id, içerik eşitliği, `toString()` değer göstermez, sıfır kimlik = null). `SessionUi.PairingNeedsUser` ve `SessionUi.Connected` birer `hostTag: HostTag? = null` alanı alır. `SessionMachine.Event.PairingNeedsUser` ack'in host_id'sini taşır (`FirstAck`, `SessionController.kt`, tek satır: `ack.hostId`). Makine `Connected`'a etiketi yalnızca oturumun host'u **doğrulanmışken** koyar (ilk mühürlü kayıt görüldü: PAIRED'de güvenilen anahtarla türetilmiş kayıt, eşleşmede yerel "Güven" + host'un mühürlü ACCEPTED'ı). Düz (şifresiz) ilk ack'teki `Connected` etiketsiz kalır.
2. **`PairPick` (TrustUiText.kt):** `asked` artık uç nokta → PAIRING cevabının iddia ettiği `HostTag`. Etiketli bir `Connected` (oturum başına bir kez, etiket değişince) o etiketle işaretlenmiş uç noktaların işaretini kaldırır; başka/bilinmeyen etiketliler işaretli kalır (0018). Kaldırılanlar `takeCleared()` ile alınır.
3. **`AutoTransport.kt`:** `AutoUsbPolicy.onUsbUnblocked(now)` (sayaçlar sıfır, hemen denenebilir); `fallbackReason(ui)`: `PairingNeedsUser` → `usb_asked`, diğerleri `usb_lost`.
4. **`MainActivity.kt`:** `render` → temizlenen uç noktalar `ev=pair_asked_cleared count= usb=` (adres/isim yok); USB temizlendiyse AUTO'da `onUsbUnblocked` + hemen `autoStep`. `fallBackToWifi` nedeni `fallbackReason`'dan.
5. **Testler:** `PairTrustFlowTest` (gerçek kripto: USB ve Wi-Fi PAIRING → Wi-Fi'de eşleş + güven → `Connected` etiketli; aynı etiket → USB işareti kalkar, policy MIGRATE; sahte/başka host_id işaretli kalır), `TrustUiTest` (PairPick), `AutoTransportTest` (`usb_asked`, `onUsbUnblocked`).

## Handoff

- **Commit:** `c764866` (uygulama + testler), plan `bfe0706`; bu Handoff ayrı commit. `./scripts/check.sh: ALL OK`.
- **Dokunulan dosyalar:**
  - Kartta: `C/MainActivity.kt` (`onAskedCleared`: `ev=pair_asked_cleared` + AUTO'da USB hemen yeniden; `fallBackToWifi` nedeni `AutoUsbPolicy.fallbackReason`), `C/session/AutoTransport.kt` (`onUsbUnblocked`, `fallbackReason`, `REASON_USB_ASKED/LOST`), `C/session/TrustUiText.kt` (`PairPick`: `asked` uç nokta → iddia edilen `HostTag`; kanıtlı `Connected` ile temizleme, `takeCleared()`; `TrustUiText.askedClearedFields`), testler `AutoTransportTest` (+2), `TrustUiTest` (+4), `PairTrustFlowTest` (+3, 3 beklenti `hostTag` ile güncellendi).
  - **Kart dışı (minimal, neden: UI katmanında host_id yoktu; 0018 ayrımı ve "başka host_id'li işaret kalır" kriteri ancak kimlikle yapılabilir):** `C/session/SessionUi.kt` (opak `HostTag`; `PairingNeedsUser.hostTag`, `Connected.hostTag`, ikisi de varsayılan `null`), `C/session/SessionMachine.kt` (`Event.PairingNeedsUser.hostId`; `provenHostTag()` → `Connected`), `C/session/SessionController.kt` (`FirstAck`: PAIRING cevabının `ack.hostId`'si olaya; tek ifade). `Handshake.kt`, protokol, host dokunulmadı.
- **Varsayımlar:**
  - **"Mac'e güvenildi" kanıtı:** `Connected.hostTag` yalnızca oturum yerel olarak güvenilir **ve** bu bağlantıda mühürlü bir host kaydı görülmüşken dolu: eşleşmede yerel "Güven" + Mac'in mühürlü ACCEPTED'ı (`where=live` iki sıra da), PAIRED'de güvenilen anahtarla türetilmiş ilk kayıttan sonra (şifresiz ilk ack'teki `Connected` etiketsiz; ilk kare güncellemesiyle etiket gelir). Yani kartın iki kanıtı da (güven onayı, güvenilen anahtarla PAIRED oturum) sayılıyor, ama yalnızca Mac kendini doğruladıktan sonra.
  - **Hangi işaret kalkar:** PAIRING cevabında **iddia edilen** host_id'si kanıtlanan host_id ile aynı olan uç noktalar (USB tüneli, keşfedilen/hatırlanan Wi-Fi adresi). Başka ya da bilinmeyen (sıfır) host_id'li olanlar işaretli kalır. Temizleme oturum başına bir kez (kare güncellemeleri tekrar temizlemez; arada `Connected` dışı bir durum gerekir).
  - **0018 kalan risk (bilerek):** iddia doğrulanmamış; gerçek Mac'in host_id'sini kopyalayan bir uç, kanıtlı her oturumda bir otomatik deneme daha alır. AUTO'da bu bir taşıma adayıdır: eşleşemez (T-150, salt okunur depo), istem açamaz (aday PAIRING → `migration ... reason=key`, UI yok), HARD_FAIL geri çekilmesiyle sınırlı; Wi-Fi oturumu bozulmaz (T-205). Tableti istemde kilitleyemez.
  - **AUTO:** USB temizlenince `onUsbUnblocked` geri çekilmeyi sıfırlar ve `autoStep` hemen (post) çalışır: oturum kabul edildiyse MIGRATE, bağlı değilse PROBE (alışıldığı gibi; uçuşta deneme ya da kablo takılı değilse hiçbir şey).
  - Yeni log: `ev=pair_asked_cleared count=<n> usb=0|1` (adres, host_id, isim yok); `transport_pick reason=usb_asked` artık AUTO'nun USB'deki PAIRING cevabından sonraki Wi-Fi'ye dönüşünde de (önce yalnız ilk seçimde). `KEY_MISMATCH` dönüşü `usb_lost` kalır.
- **Test edilmeyenler / cihazda doğrulanacaklar (tablete hiçbir şey kurulmadı):**
  1. AUTO, kablo takılı, eşleşmiş tablet: Mac menüsünden "Onaylı cihazları unut" → tablette `pairing_needs_user re_pair=1` (USB) → `transport_pick mode=auto chosen=wifi reason=usb_asked` (artık `usb_lost` değil) → Wi-Fi'de Eşleş → Mac'te İzin ver → tablette Güven → `pair_trust_confirmed` → `pair_asked_cleared count=1 usb=1` → birkaç saniye içinde `migration_proved` + `transport_migrate ok=1 to=usb` ("Bağlantıyı kes"/"Bağlan" gerekmeden). Aynısı ters sırayla (önce Güven, sonra İzin ver).
  2. Normal sessiz yeniden bağlanma (PAIRED) değişmedi: `pair_asked_cleared` görünmez (işaretli uç yokken log yok), akış/USB geçişi eskisi gibi.
  3. `adb logcat -s 'MB:*'`: kod, anahtar, jeton, host_id ya da Mac adı yok (yeni satır yalnız `count=`/`usb=`).
  4. (İsteğe bağlı, T-157) 127.0.0.1:47001'de başka host_id'li bir sahte uç: Wi-Fi'de güvenden sonra USB işaretli kalır, AUTO Wi-Fi'de kalır, istem açılmaz.
- **Açık sorular:**
  - **docs/LOGGING.md (orkestratör):** `pair_asked_cleared count= usb=` ekle; `transport_pick reason=usb_asked` artık AUTO'daki USB→Wi-Fi dönüşünde de kullanılıyor.
  - Kart dışı üç dosya (yukarıda, nedeniyle) — `files:` listesine eklenmesi orkestratörün onayına.
  - İsteğe bağlı sertleştirme (yapılmadı, kapsam dışı): taşıma adayı USB'de PAIRING cevabı verirse (`reason=key`) uç noktayı yeniden işaretlemek; o zaman host_id'yi kopyalayan bir sahte uç kanıtlı oturum başına tam bir deneme alır, geri çekilmeli tekrarlar da kalkar.
