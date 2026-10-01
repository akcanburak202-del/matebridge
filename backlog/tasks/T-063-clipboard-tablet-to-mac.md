---
id: T-063
title: Pano: tablet → Mac çalışmıyor
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-054, T-055]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/clipboard/
  - client-android/app/src/test/
  - backlog/tasks/T-063-clipboard-tablet-to-mac.md
---

## Amaç

Kullanıcı (2026-10-01 sabah): tablette kopyalanan metin Mac'e gelmiyor; Mac → tablet çalışıyor.

**Kök neden (orkestratör, kod okuma):** tablette başka bir uygulamada kopyalanan metin MateBridge odak kazanınca `ClipboardBridge.check(fromListener=false)` ile okunuyor ve `ClipboardSync.onLocalClip(text, sensitive, desc.timestamp)` çağrılıyor. `ClipDescription.getTimestamp()` **`SystemClock.elapsedRealtime()`** tabanında (açılıştan beri ms), ama `MainActivity` `onSessionAccepted(..., System.currentTimeMillis(), ...)` ile taban zamanı **duvar saatinde** veriyor. `timestampMs in 1..baselineMs` her zaman doğru → her kopya "oturumdan önce" sayılıp yok sayılıyor. Dinleyici yolu (zaman damgası 0) yalnızca MateBridge odaktayken çalışıyor; kullanıcı orada kopyalamıyor.

## Kabul kriterleri

- [ ] Taban zamanı ve kopya zaman damgası aynı saat tabanında (`elapsedRealtime`); `ClipboardSync` KDoc'u saat tabanını açıkça söyler.
- [ ] Test (`ClipboardSync` saf): oturum kabulünden sonra kopyalanan (daha büyük `elapsedRealtime` damgası) metin gönderilir; öncesindeki gönderilmez; damga 0 (bilinmiyor) davranışı değişmez.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

`MainActivity`'deki `onSessionAccepted` çağrısında `System.currentTimeMillis()` → `SystemClock.elapsedRealtime()`; test.

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
  - **BLOKE: kök neden doğrulanamadı, uygulanmadı.** AOSP `ClipDescription.getTimestamp()` KDoc'u (android-37 kaynağı, `~/Library/Android/sdk/sources/android-37.0/android/content/ClipDescription.java`; android14-release de aynı): "copied to global clipboard in the **System.currentTimeMillis()** time base" (0 = panoya kopyalanmadı). `setTimestamp` da aynı tabanı söyler. Yani `MainActivity`'deki `System.currentTimeMillis()` taban zamanı zaten doğru saat tabanı; `elapsedRealtime`'a geçirmek asıl hatayı yaratırdı (elapsed << duvar saati, her kopya tabandan "önce" sayılırdı değil, tersi: hepsi geçerdi ama oturum öncesi kopya da gönderilirdi).
  - Kalan hipotezler (hepsi doğrulanmadı; HarmonyOS 4.3'ün `DistributedPasteboardService` katmanı timestamp'i AOSP'den farklı doldurabilir): (1) timestamp elapsedRealtime tabanında HarmonyOS'ta; (2) timestamp farklı/eksik; (3) `check(false)` yalnızca `onWindowFocusChanged(true)` → `start()` ile çağrılıyor, kullanıcı başka uygulamada kopyalayıp MateBridge'e dönerken odak olayı/`primaryClip` okuması başarısız (SecurityException/null) olabilir; (4) `text == lastText` yankı filtresi (örn. Mac'ten gelen metin aynı kalıyor).
  - Önerilen sonraki adım: `readClip`'e debug seviyesinde `ts`, `System.currentTimeMillis()` ve `elapsedRealtime()` farkını (içerik değil) loglayan bir tanı sürümü, tablette tek kopya denemesi; sonuca göre düzeltme.

## Cihaz tanısı (2026-10-01 09:39, orkestratör)

Kullanıcı başka uygulamada kopyaladı, MateBridge'e döndü:
```
09:38:23 diag=focus_stop was=true            (sid=1801454648, oturum açık)
09:39:03 diag=focus_start already=false      (sid=0: oturum MateBridge arka plana gidince kapanmış, henüz kurulmamış)
09:39:03 diag=check src=focus clip=ok items=1 len=148 ts=1790836732655 now=1790836743207 baseline=1790836121934 accepted=false decision=not_accepted
```
**Kök neden:** odak dönüşündeki tek denetim, oturum yeniden kurulmadan çalışıyor (`not_accepted`); oturum kabul edilince `onSessionAccepted` taban zamanını "şimdi"ye çekiyor, kopya (ts 09:38:52) bundan önce kaldığı için bir daha hiç gönderilmiyor. Saat tabanı doğru (ts/now/baseline hepsi duvar saati).

## Kabul kriterleri (düzeltme)

- [ ] Taban zamanı **uygulama açılışında / ilk oturum kabulünde** bir kez konur (PROTOCOL §0x06: "Açılışta mevcut pano gönderilmez"); yeniden bağlanmada ileri alınmaz. Yinelenen filtresi (`lastText`) oturum başına sıfırlanmaya devam eder, ama oturumdan önce **gönderilmiş** son metin aynı oturumda tekrar gitmesin diye mevcut davranış korunur.
- [ ] Oturum kabul edilince (geçiş anında) uygulama odaktaysa pano bir kez denetlenir (`check(fromListener=false)`); böylece arka plandayken kopyalanıp dönülünce oturum kurulduktan sonra gönderilir.
- [ ] Testler (`ClipboardSync` saf): açılıştan önce kopya gönderilmez; oturum A → kopukluk sırasında kopya → oturum B kabulü → gönderilir; Mac'ten alınan metin yankılanmaz.
- [ ] Tanı logu `diag=check` debug seviyesine indirilir ya da kaldırılır (içeriksiz kalır); `focus_*` satırları kalkar.
- [ ] `./scripts/check.sh` geçiyor.
