---
id: T-094
title: Mac — sistem sesi yakalama (Core Audio process tap, mutedWhenTapped) ve kontrol bağlantısından AUDIO_FRAME gönderimi
status: in-progress
phase: 5
owner: mac-host-dev
depends_on: [T-093]
decisions: [0011]
files:
  - host-mac/Sources/MateBridgeHost/Audio/
  - host-mac/Sources/MateBridgeCore/Audio/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Sources/MateBridgeApp/main.swift
  - host-mac/Resources/Info.plist
  - host-mac/Tests/
  - backlog/tasks/T-094-host-audio-capture.md
---

## Amaç

Karar 0011 ve PROTOCOL §4 `0x30–0x32` (T-093 ile kod çözücüler hazır). Oturum açıkken Mac sesi yalnızca tablette çalsın. Mac hoparlörü sussun; oturum bitince ya da host çökünce Mac sesi geri gelsin.

Yakalama denemesinden bilinenler (orkestratör, 2026-10-01; kaynak scratch `audio-spike/tap.swift`):
- `CATapDescription(stereoGlobalTapButExcludeProcesses: [kendi süreç nesnesi])` (`kAudioHardwarePropertyTranslatePIDToProcessObject`), `muteBehavior = .mutedWhenTapped`, `isPrivate = true`, ad `"MateBridge-audio"`.
- `AudioHardwareCreateProcessTap`.
- `AudioHardwareCreateAggregateDevice`: ana alt cihaz = varsayılan çıkış cihazının UID'si; `kAudioAggregateDeviceTapListKey` = `[uid, drift: true]`; `IsPrivate`; `TapAutoStart`.
- `kAudioDevicePropertyBufferFrameSize = 240`, ardından `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart`.
- Biçim 48 kHz, 2 kanal, Float32 iç içe (`kAudioTapPropertyFormat`).
- **TCC:** izin istemi `AudioDeviceCreateIOProcIDWithBlock` içinde çıkıyor ve çağrıyı **bloke ediyor** (istem açık kaldıkça). Ana iş parçacığında, video ya da girdi yolunda asla çağrılmaz.
- Genel (özel olmayan) tap, oluşturan süreç `kill -9` ile ölse bile kalıyor. `.mutedWhenTapped` ile okuyucu ölünce susturma biter. Yine de açılışta adıyla sızmış tap'ler temizlenir.

## Kabul kriterleri

- [ ] `SystemAudioTap` (tek tip/dosya, `MateBridgeHost/Audio/`). Tap, aggregate ve IOProc ömrünü yönetir. Ayrı bir seri kuyrukta başlar ve durur. Başlatma bloke olursa (izin istemi) oturum, video ve girdi etkilenmez.
  - Durdurma sırası: `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`.
  - Varsayılan çıkış cihazı değişirse (`kAudioHardwarePropertyDefaultOutputDevice` dinleyicisi) ya da cihaz ölürse (`kAudioDevicePropertyDeviceIsAlive`), tap ve aggregate yeniden kurulur.
  - Uyku/uyanmada da yeniden kurulur.
- [ ] IOProc içinde tahsis ve kilit yok (gerçek zamanlı iş parçacığı):
  - Float32 → s16le dönüşümü kırpma ile yapılır.
  - 10 ms'lik (480 kare) paketler önceden ayrılmış bir halka tampona yazılır. Halka sınırlı: en çok 100 ms; taşarsa en eski atılır, `sample_index` ilerler.
  - `capture_time_us` = `inInputTime.mHostTime` → host monoton µs (`VIDEO_FRAME` ile aynı saat).
  - Gönderici iş parçacığı halkadan okuyup `AUDIO_FRAME` gönderir.
- [ ] Oturum kuralları PROTOCOL §4'teki gibi:
  - Başlama koşulu: ACCEPTED, şifreli oturum, HELLO bit8, `AUDIO_PREFS.enabled = 1` (her `enabled` değişiminde).
  - Başlarken yeni `stream_id` ile `AUDIO_CONFIG(STARTED)`.
  - `enabled = 0`, BYE, kontrol kopması ya da oturum sonunda **hemen** durdurma. Video grace süresi beklenmez. Bağlantı açıksa `AUDIO_CONFIG(STOPPED)`.
  - Kontrol bağlantısında ses gönderimi girdi işlemeyi bekletmez.
- [ ] Ses izni reddedilirse ya da yakalama başarısız olursa: `ev=audio_unavailable reason=…` bir kez loglanır, ses gönderilmez, oturum normal devam eder.
- [ ] `Info.plist`'e `NSAudioCaptureUsageDescription` eklenir. Türkçe metin: "MateBridge, Mac'in sesini tabletinizde çalmak için sistem sesini kaydeder."
- [ ] Log, saniyede bir, yalnızca ses akarken: `component=audio ev=stats packets=… dropped=… ring_ms_max=… callback_ms_p50_95=… rms_dbfs=…`. Seviye yalnızca sayısal; içerik asla loglanmaz.
- [ ] Deney düğmesi `MATEBRIDGE_AUDIO=off` sesi tamamen kapatır.
- [ ] Saf parçalar `MateBridgeCore/Audio/` içinde ve testli: Float32→s16 dönüşümü, halka tampon (taşma, `sample_index`), paketleme, başlat/durdur karar makinesi.
- [ ] `./scripts/check.sh` geçiyor.
- [ ] Gerçek tap çalıştırılmaz ve izin istemi tetiklenmez (cihaz testi orkestratörde). Testlerde Core Audio sahte bir protokol arkasında olur.

## Plan

**Core (`MateBridgeCore/Audio/`, testli, Core Audio yok):**
1. `PCMConvert`: Float32 → s16le kırpmalı (`round(clamp(x,-1,1)×32767)`, NaN → 0), iç içe ve düzlemsel (planar) kaynak; kare başına karelerin toplam kare toplamı (RMS için).
2. `AudioPacketRing`: tek üretici/tek tüketici, kilitsiz (`Synchronization.Atomic`), önceden ayrılmış 16 yuva × 480 kare. Üretici asla beklemez, eskiyi ezer. Tüketici en çok 10 paket (100 ms) geriden okur, daha eskisini atar (`dropped`); kopyadan sonra yayın sayacını yeniden denetler (ezilmişse atar).
3. `AudioPacketizer` (IOProc tarafı, tahsis/kilit yok): geri çağrı karelerini 480'lik paketlere doğrudan halka yuvasına yazar; `sample_index` akıştaki kare sayısı; `mSampleTime` sıçramasında yarım paketi yayınlar ve indeksi boşluk kadar ilerletir; paket meta: ilk karenin host tick'i + kare ofseti, kare toplamı, geri çağrı süresi.
4. `TapBufferLayout`: aggregate giriş akış düzeninden (kanal/tampon) tap tamponunu seçer (sonuncu stereo ya da son iki mono).
5. `AudioStreamPolicy` (saf karar makinesi): oturum (ACCEPTED+şifreli, bit8), `AUDIO_PREFS.enabled`, `MATEBRIDGE_AUDIO=off`, yakalama olayları (`started/failed/interrupted`) → eylemler: yakalamayı başlat(token)/durdur, `AUDIO_CONFIG(STARTED/STOPPED)` gönder, `audio_unavailable` bir kez logla. Kesinti (cihaz değişimi, cihaz ölümü, uyku/uyanma) → durdur + yeni `stream_id` ile yeniden başlat.
6. `AudioStatsWindow`: saniyelik `ev=stats` alanları (packets, dropped, ring_ms_max, callback_ms_p50_95, rms_dbfs).
7. `AudioStreamer` (Core, kendi seri kuyruğu): politika + `AudioCaptureBackend` protokolü (sahte ile testli) + gönderici (5 ms zamanlayıcı halkayı boşaltır, `AUDIO_FRAME` üretir, `seq`/`stream_id`) + `AudioSink` protokolü (oturuma gönderim).

**Host:**
8. `MateBridgeHost/Audio/SystemAudioTap.swift`: `AudioCaptureBackend`. Tap (kendi süreci hariç, `.mutedWhenTapped`, private, ad `MateBridge-audio`), aggregate, 240 kare tampon, IOProc; hepsi ayrı seri kuyrukta (izin istemi orada bloke olur). Durdurma sırası kartta yazdığı gibi. Dinleyiciler: varsayılan çıkış cihazı, `DeviceIsAlive`, uyku/uyanma (`NSWorkspace` bildirimleri) → `interrupted`. Açılışta adıyla sızmış tap temizliği. `mHostTime` → µs `HostClock` ile aynı saat (`CMClockMakeHostTimeFromSystemUnits`).
9. `SessionServer`: `AUDIO_PREFS` makineye verildikten sonra (heartbeat) aktif, şifreli oturum bağlantısından geldiyse `audioPrefs` handler'ına iletilir (SessionMachine dosyası kart kapsamı dışında). `sendAudio(sessionID:)`: oturum güncelse mühürleyip gönderir; kontrol bağlantısının yazılmamış baytı ses sınırını (24 KiB) aşarsa `AUDIO_FRAME` atılır (bağlantı 256 KiB sınırına ses yüzünden düşmez), `AUDIO_CONFIG` hiç atılmaz.
10. `main.swift`: `AudioStreamer` + `SystemAudioTap` kablolama (oturum başladı/bitti, prefs, kapanışta durdurma). `Info.plist`: `NSAudioCaptureUsageDescription`.

**Test:** dönüşüm uçları, halka taşma/ezilme/`sample_index`, paketleme (240'lık geri çağrılar, boşluk, zaman ofseti), düzen seçimi, karar makinesi (bütün başlat/durdur yolları, bir kez log, kill switch, eski token), streamer (sahte backend + sahte sink: STARTED → kareler → STOPPED sırası, oturum sonunda STOPPED yok).

## Handoff

