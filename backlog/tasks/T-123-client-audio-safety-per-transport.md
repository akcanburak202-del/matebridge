---
id: T-123
title: Tablet — ses güvenlik payı bağlantı türüne göre (USB / Wi-Fi ayrı hatırlansın, Wi-Fi tabanı yüksek); geçişte pay hemen uyarlansın
status: review
phase: 5
owner: android-client-dev
depends_on: [T-118]
decisions: [0011, 0012]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-123-client-audio-safety-per-transport.md
---

## Amaç

NOTES 2026-10-02 ~11:35: keyframe fırtınası bittikten sonra USB'de ses temiz. 14 dakikada en büyük varış boşluğu 33 ms, 1 alt taşma.

Wi-Fi'de ise saf ağ titreşimi var:
- varış boşlukları 41–50 ms, `owd` 39–65 ms;
- RTT p50 15–37, p95 en çok 126 ms.

`SafetyMemory` tek değer saklıyor (API başına: `aaudio` / `track`). USB'de öğrenilen 20–30 ms Wi-Fi'ye geçince yetmiyor ve kullanıcı 1–2 dakikada 5 kesinti duydu. Tersi de sorun: Wi-Fi'de büyüyen pay USB'ye dönünce gecikme olarak kalıyor (T-118 küçülmesi 100 s sürüyor).

Kullanıcı kararı "Dengeli" (T-118) geçerli. Bu kart onu bağlantı türüne göre ayırır.

## Kapsam dışı

- Wi-Fi titreşiminin kendisi (ağ ayarları, QoS): ayrı konu.
- Görüntü tarafı.

## Kabul kriterleri

- [x] `SafetyMemory` anahtarı `api + transport` olur (`aaudio/usb`, `aaudio/wifi`, `track/usb`, `track/wifi`). Eski tek anahtarlı kayıt USB değeri olarak taşınır (göç), Wi-Fi varsayılandan başlar.
- [x] Wi-Fi başlangıç tabanı ve hatırlama tavanı USB'den yüksektir. Öneri: AAudio Wi-Fi başlangıç 40 ms, hatırlama tavanı 50, oturum içi tavan 60–70 ms. Plan'da ölçüme dayalı gerekçe: Wi-Fi `owd` p95/max ve RTT dağılımı. Küçülme hızı T-118 ile aynı. Wi-Fi'de pay öğrenilen değerin altına inmez mi, inerse ne kadar, Plan'da yazılır.
- [ ] Oturum ortasında bağlantı değişince (Otomatik mod USB ↔ Wi-Fi, `transport_migrate` / yeni oturum) ses çıkışı yeniden açılmadan pay o bağlantının hatırlanan değerine geçer. Artış hemen olur (kısa bir dolum gerekiyorsa yumuşak); azalış normal küçülme yoluyla olur. *(Kısmi: göç bugün ses akışını yeniden açıyor; yeni akış yeni bağlantının değeriyle başlıyor. Canlı yol `setTransport` hazır ama bağlı değil. Bkz. Açık sorular.)*
- [x] Log: `ev=safety_start ... transport=usb|wifi`. Geçişte `ev=safety_transport from= to= used=`.
- [x] Birim testleri:
  - (a) göç: eski 30 → usb 30, wifi varsayılan;
  - (b) Wi-Fi'de büyüyen pay USB kaydını etkilemez;
  - (c) geçişte pay doğru değere gider;
  - (d) T-118 testleri geçer.
- [x] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

## Plan

**Mevcut akış (kod okundu):** Otomatik modda göç (`transport_migrate`) ses akışını zaten kapatıp açıyor. `RetireControl` → `onSessionEnd` → `AudioPlayout.endSession` çalışan `Stream`'i durduruyor. `PromoteCandidate` → `onConnectionGen` → `beginSession` yeni bağlantıyı silahlandırıyor. Host'un yeni `AUDIO_CONFIG`'i yeni bir `Stream` (yeni `PlayoutCore`, yeni çıkış) açıyor. Dolayısıyla pratikte bağlantı değişimi = yeni akış. Akışı göçte canlı tutmak (T-095 kapısı) bu kartın kapsamı dışında (Açık sorular). Pay iki yoldan doğru değere gider:
1. Yeni akış, açıldığı bağlantının hatırlanan değeriyle başlar (asıl yol).
2. Aynı akışta bağlantı değişirse (`AudioPlayout.setTransport`) çıkış yeniden açılmadan geçilir: artış hemen, azalış normal küçülmeyle.

**1. Bağlantı türü sese ulaşır.** `SessionListener.onConnectionGen(gen, transport)`. İki çağrı yerinde (`OpenControl`, `PromoteCandidate`) uç nokta biliniyor: `ConnectMode.transportOf(a.endpoint)`. `MainActivity` → `audio.beginSession(gen, transport)`. Uygulamada tek uygulayıcı `MainActivity` (testlerde yok). `onMigrationResult` UI iş parçacığında ve yeni akış açıldıktan sonra gelebildiği için ona dayanılmaz.

**2. `SafetyMemory` anahtarı `api/transport`.** Anahtarlar: `aaudio/usb`, `aaudio/wifi`, `track/usb`, `track/wifi`.
- Göç: `x/usb` yoksa eski tek anahtar `x` USB değeri olarak okunur. İlk değişen kayıt `x/usb`'ye yazılır; eski anahtar silinmez, `x/usb` varken okunmaz.
- Wi-Fi eski kayıttan etkilenmez, varsayılandan başlar.
- `SharedPrefsSafetyStore`: tercih anahtarı `safety_ms_` + anahtar, `/` → `_`. Eski `safety_ms_aaudio` aynen kalır.

**3. Bağlantı profili** (`SafetyMemory.profile(api, transport)`: başlangıç/küçülme tabanı, hatırlama tavanı, oturum içi tavan):

| | başlangıç = taban | hatırlama tavanı | oturum içi tavan |
|---|---|---|---|
| USB AAudio | 20 | 30 | 40 (T-118, değişmez) |
| USB AudioTrack | 5 | 30 | 40 (T-118, değişmez) |
| Wi-Fi (iki API) | 40 | 50 | 70 |

Ölçüme dayalı gerekçe (NOTES 2026-10-02 ~11:35, Wi-Fi):
- Varış boşlukları 41–50 ms, `owd` 39–65 ms, RTT p50 15–37 / p95 en çok 126 ms.
- Boşluk sırasında tampon "pay + bir paketin testere payı" kadar ses tutmalı. 40 ms pay, 10 ms paketle 50 ms'lik boşluğu (gözlenen bant üst ucu) karşılar. USB'nin 20–30'u bu bandın altında kaldı ve 1–2 dk'da 5 alt taşma oldu.
- Hatırlama tavanı 50: bir Wi-Fi oturumu sık takılıp tavana gitse bile sonraki oturum en çok 50'den başlar. 50, gözlenen boşluk bandının üstü; daha fazlası her Wi-Fi oturumuna kalıcı gecikme olur.
- Oturum içi tavan 70: gözlenen en büyük `owd` (65 ms) artı pay. Kötü bir Wi-Fi anında ardışık alt taşmalar (+5) 70'e kadar çıkabilir.
- RTT p95 126 ms'lik nadir sıçramalar için 120+ ms tampon gerekir. "Dengeli" karara (T-118) göre bunlar kısa, yumuşatılmış kesinti olarak kabul edilir.
- AudioTrack için Wi-Fi'de ayrı taban yok: ağ titreşimi API'den bağımsız. NOTES ~10:40'ta 5 ms taban "Uyumlu"da çok daha kötü duyuldu.

Küçülme hızı T-118 ile aynı (1 ms / 5 temiz pencere). Wi-Fi'de pay öğrenilen değerin altına iner, ama Wi-Fi tabanının (40) altına inmez. Örnekler: oturumda 60'a çıkan pay 100 s temiz çalmada 40'a döner; hatırlanan 50 ile başlayan oturum 50 s temizde 40'a iner.

**4. `DriftController`.**
- `resetSafety(initialMs, floorMs, maxMs = SAFETY_MAX_MS)`: oturum içi tavan değişken olur. Mutlak üst sınır `SAFETY_CEILING_MS = 100`.
- Yeni `retarget(initialMs, floorMs, maxMs)` (canlı geçiş için): taban ve tavan yeni bağlantınınkine geçer. Pay, yeni başlangıçtan düşükse **hemen** ona yükseltilir. Yüksekse aynen kalır ve normal küçülmeyle yeni tabana iner (yeni tavanın üstünde olsa bile ani düşüş olmaz).
- `onUnderrun` payı asla düşürmez (tavanın üstündeyken +5 yerine yerinde kalır).
- Hedef yükselince seviye PI ile dolar (≤ %0,5 perde, duyulmaz). 20 ms'lik artışta ilk saniyelerde bir alt taşma olursa mevcut +5/dolum yolu devreye girer. Ayrı bir dolum (rebuffer) yapılmaz, çünkü o duyulur bir boşluk olur.

**5. `AudioPlayout`.**
- `beginSession(gen, transport)`: önce eski akışı durdurur, sonra bağlantıyı kaydeder. Durdurulan akış yeni bağlantıyı hiç görmez.
- `Stream` bağlantısını oluşurken alır (`@Volatile`). `setTransport(t)` hem kayıtlı bağlantıyı hem çalışan akışınkini değiştirir.
- Yazıcı her istatistik saniyesinde akışın bağlantısını `safetyTransport` ile karşılaştırır; farklıysa canlı geçiş yapar: eski anahtarı `flush`, `retarget` ve log.
- `applySafety(api)` → `initial(api, transport)` + `resetSafety(..., maxMs)`.
- `onSafety`/`flush` anahtarı `api + transport`.

**6. Log.**
- `ev=safety_start stream_id= api= transport=usb|wifi stored= used= source= remember_max=`.
- `ev=safety_transport stream_id= api= from= to= used= stored= live=0|1`. Canlı geçişte `live=1`. Yeni akış önceki akıştan farklı bağlantıda açıldığında `live=0` (pratikteki göç yolu).

**7. Testler** (`SafetyMemoryTest`, `DriftControllerTest`, yeni `SafetyTransportTest`):
- (a) eski `aaudio`=30 → `aaudio/usb` 30, `aaudio/wifi` 40 (varsayılan); `track` göçü de;
- (b) Wi-Fi'de büyüyen pay (`onSafety`/`flush` wifi 50) USB kaydını değiştirmez; USB'den sonraki açılış hâlâ 30;
- (c) geçiş: USB 20'de çalarken Wi-Fi'ye `retarget` → 40 hemen; Wi-Fi 60'tan USB'ye → hemen düşmez, 5 pencerede −1, 20'de durur; Wi-Fi'de 70 tavanı, USB'de 40;
- (d) T-118 testleri: davranış aynı; çağrılar `Transport.USB` alır, saklanan anahtar beklentileri `aaudio/usb` olur.

## Handoff

- **Commit:** `c353d88` (uygulama), plan `1240bec`; bu handoff ayrı commit. Dal: `task/T-123-audio-safety-per-transport`.
- **Dokunulan dosyalar:**
  - `audio/SafetyMemory.kt`:
    - anahtar `api/transport` (`SafetyMemory.key`);
    - `Profile` (başlangıç/taban, hatırlama tavanı, oturum içi tavan) ve `profile(api, transport)`;
    - USB göçü (`api/usb` yoksa eski `api` okunur);
    - `WIFI_DEFAULT_MS=40`, `WIFI_REMEMBER_MAX_MS=50`, `WIFI_SESSION_MAX_MS=70`;
    - `initial`/`onSafety`/`flush` artık `transport` alıyor.
  - `audio/SharedPrefsSafetyStore.kt`: tercih anahtarı `safety_ms_<api>_<transport>`; eski `safety_ms_<api>` aynı biçimde okunuyor.
  - `audio/DriftController.kt`:
    - `resetSafety(..., maxMs)`: oturum içi tavan değişken, mutlak üst sınır `SAFETY_CEILING_MS=100`;
    - yeni `retarget()`: artış hemen, azalış küçülmeyle;
    - `onUnderrun` payı asla düşürmüyor.
  - `audio/AudioPlayout.kt`:
    - `beginSession(gen, transport)`, yeni `setTransport(t)`;
    - `Stream` bağlantısını taşıyor; istatistik saniyesinde `followTransport()`;
    - loglar: `safety_start ... transport=`, `safety_transport from= to= used= stored= live=0|1`.
  - `session/SessionController.kt`: `SessionListener.onConnectionGen(gen, transport)`; iki çağrı yeri uç noktadan `ConnectMode.transportOf`.
  - `MainActivity.kt`: `audio?.beginSession(gen, transport)`.
  - Testler:
    - `SafetyMemoryTest`: T-118 testleri, davranış aynı. Çağrılar `USB` alıyor, kayıt anahtarı `aaudio/usb`.
    - yeni `SafetyTransportTest` (13 test): (a) göç; (b) Wi-Fi büyümesi USB'yi etkilemiyor; (c) USB→Wi-Fi hemen artış, Wi-Fi→USB küçülmeyle iniş, tavanlar; ayrıca profiller ve Wi-Fi 70→40 küçülme hızı.
    - (d) `DriftControllerTest`, `UnderrunRefillTest` ve diğerleri değişmeden geçiyor.
  - `./scripts/check.sh`: ALL OK.
- **Varsayımlar:**
  - Göç (`transport_migrate`) bugün ses akışını kapatıp yeni akış açıyor: `RetireControl` → `endSession`, sonra `beginSession` ve host'un yeni `AUDIO_CONFIG`'i. Yeni akış yeni bağlantının hatırlanan değeriyle başlıyor. Wi-Fi→USB'de bu azalış da hemen oluyor (çıkış zaten yeniden açılıyor, seviye sıfırdan doluyor). Log `safety_transport live=0`.
  - Akış kapanırken eski bağlantının değeri kendi anahtarına `flush` ediliyor.
  - `setTransport` (canlı geçiş, `live=1`) şu an hiçbir yerden çağrılmıyor; akış göçte canlı kalırsa kullanılacak yol (Açık sorular).
  - AudioTrack Wi-Fi'de AAudio ile aynı profili kullanıyor (40/50/70): ağ titreşimi API'den bağımsız.
  - Eski kayıt silinmiyor; `api/usb` yazıldıktan sonra okunmuyor.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  1. USB'de açılış: `ev=safety_start api=aaudio transport=usb stored=<eski değer> used=...`. Cihazdaki eski `safety_ms_aaudio` USB değeri olarak okunmalı.
  2. Wi-Fi'de (manuel Wi-Fi ya da Otomatik'te USB kablosu takılı değilken) açılış: `transport=wifi stored=- used=40 source=default remember_max=50`. Birkaç dakika müzikte alt taşma sayısı önceki 1–2 dk'da 5'ten belirgin az olmalı. `audio_ms` yaklaşık +20 ms artar (beklenen).
  3. Otomatik mod Wi-Fi → USB göçü (kablo tak): `ev=transport_migrate ok=1 to=usb`, ardından `ev=safety_start transport=usb` ve `ev=safety_transport from=wifi to=usb used=<usb değeri> live=0`. USB'de `safety_ms` USB değeriyle başlamalı (Wi-Fi'nin 40+'sı taşınmamalı).
  4. USB → Wi-Fi (kablo çek, Otomatik): `safety_transport from=usb to=wifi used=40 live=0`.
  5. Bir Wi-Fi oturumundan sonra tekrar USB oturumu açıldığında `stored=` hâlâ USB'nin değeri olmalı (Wi-Fi'de büyüyen pay USB'ye sızmamalı). İsteğe bağlı: `adb shell run-as dev.matebridge.client cat shared_prefs/matebridge_audio.xml` → `safety_ms_aaudio_usb` ve `safety_ms_aaudio_wifi` ayrı.
- **Açık sorular:**
  - Kart "ses çıkışı yeniden açılmadan" geçiş istiyor, ama mevcut T-095/T-096 tasarımında göç ses akışını durdurup yeniden açıyor (`endSession` + `beginSession` + yeni `AUDIO_CONFIG`). Akışı göçte canlı tutmak (`AudioStreamGate` yeniden silahlandırma, aynı `stream_id`, eski okuyucunun paketleri) bu kartın kapsamını aşan bir ses/oturum değişikliği. Canlı yol (`setTransport` → `retarget`) hazır ve test edildi; istenirse ayrı kartla bağlanabilir.
  - `docs/LOGGING.md`'ye `safety_start transport=` alanı ve yeni `ev=safety_transport` olayı eklenmeli (dosya kartın `files:` listesinde değil).
