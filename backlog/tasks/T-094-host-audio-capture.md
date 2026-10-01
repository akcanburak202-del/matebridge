---
id: T-094
title: Mac — sistem sesi yakalama (Core Audio process tap, mutedWhenTapped) ve kontrol bağlantısından AUDIO_FRAME gönderimi
status: review
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

- [x] `SystemAudioTap` (tek tip/dosya, `MateBridgeHost/Audio/`). Tap, aggregate ve IOProc ömrünü yönetir. Ayrı bir seri kuyrukta başlar ve durur. Başlatma bloke olursa (izin istemi) oturum, video ve girdi etkilenmez.
  - Durdurma sırası: `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`.
  - Varsayılan çıkış cihazı değişirse (`kAudioHardwarePropertyDefaultOutputDevice` dinleyicisi) ya da cihaz ölürse (`kAudioDevicePropertyDeviceIsAlive`), tap ve aggregate yeniden kurulur.
  - Uyku/uyanmada da yeniden kurulur.
- [x] IOProc içinde tahsis ve kilit yok (gerçek zamanlı iş parçacığı):
  - Float32 → s16le dönüşümü kırpma ile yapılır.
  - 10 ms'lik (480 kare) paketler önceden ayrılmış bir halka tampona yazılır. Halka sınırlı: en çok 100 ms; taşarsa en eski atılır, `sample_index` ilerler.
  - `capture_time_us` = `inInputTime.mHostTime` → host monoton µs (`VIDEO_FRAME` ile aynı saat).
  - Gönderici iş parçacığı halkadan okuyup `AUDIO_FRAME` gönderir.
- [x] Oturum kuralları PROTOCOL §4'teki gibi:
  - Başlama koşulu: ACCEPTED, şifreli oturum, HELLO bit8, `AUDIO_PREFS.enabled = 1` (her `enabled` değişiminde).
  - Başlarken yeni `stream_id` ile `AUDIO_CONFIG(STARTED)`.
  - `enabled = 0`, BYE, kontrol kopması ya da oturum sonunda **hemen** durdurma. Video grace süresi beklenmez. Bağlantı açıksa `AUDIO_CONFIG(STOPPED)`.
  - Kontrol bağlantısında ses gönderimi girdi işlemeyi bekletmez.
- [x] Ses izni reddedilirse ya da yakalama başarısız olursa: `ev=audio_unavailable reason=…` bir kez loglanır, ses gönderilmez, oturum normal devam eder.
- [x] `Info.plist`'e `NSAudioCaptureUsageDescription` eklenir. Türkçe metin: "MateBridge, Mac'in sesini tabletinizde çalmak için sistem sesini kaydeder."
- [x] Log, saniyede bir, yalnızca ses akarken: `component=audio ev=stats packets=… dropped=… ring_ms_max=… callback_ms_p50_95=… rms_dbfs=…`. Seviye yalnızca sayısal; içerik asla loglanmaz.
- [x] Deney düğmesi `MATEBRIDGE_AUDIO=off` sesi tamamen kapatır.
- [x] Saf parçalar `MateBridgeCore/Audio/` içinde ve testli: Float32→s16 dönüşümü, halka tampon (taşma, `sample_index`), paketleme, başlat/durdur karar makinesi.
- [x] `./scripts/check.sh` geçiyor.
- [x] Gerçek tap çalıştırılmaz ve izin istemi tetiklenmez (cihaz testi orkestratörde). Testlerde Core Audio sahte bir protokol arkasında olur.

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

- **Commit:** `9c5e870` (uygulama), `38ea3b4` (inceleme düzeltmeleri), `6a69438` (ikinci inceleme düzeltmeleri), plan `c706137`. Dal `task/T-094-host-audio`, `task/T-093-audio-codecs` üstünde.
- **check.sh:** ALL OK (host-mac build+test, probes, gradle, fixtures, crypto vectors). Yeni testler: `AudioCaptureTests`, `AudioStreamPolicyTests`, `AudioStreamerTests` (`AudioOutboxTests` dahil 57 test; gerçek Core Audio yok, sahte backend + sahte sink).
- **Dosyalar:**
  - Yeni Core: `Sources/MateBridgeCore/Audio/` `PCMConvert`, `AudioPacketRing` (SPSC, `Synchronization.Atomic`, yuva sahipliği: iki taraf aynı yuvaya asla aynı anda dokunmaz), `AudioPacketizer`, `TapBufferLayout`, `AudioStreamPolicy`, `AudioStats`, `AudioStreamer` (+ `AudioControlInbox`, `AudioCaptureBackend`, `AudioSink`, `AudioKnob`), `AudioOutbox`.
  - Yeni Host: `Sources/MateBridgeHost/Audio/SystemAudioTap.swift` (tap/aggregate/IOProc, tek istenen durum + uzlaştırma, dinleyiciler), `Audio/HostAudio.swift` (fabrika: host saati + `component=audio` log).
  - Değişen: `Session/SessionServer.swift` (`audioPrefs` handler, `sendAudio`, `AudioSink` uyumu, ses için kuyruk ve bayt sınırı), `Session/HostClock.swift` (`us(fromHostTicks:)`), `MateBridgeApp/main.swift` (kablolama, kapanışta durdurma), `Resources/Info.plist` (`NSAudioCaptureUsageDescription`).
- **Varsayımlar / tasarım kararları:**
  - `AUDIO_PREFS`'i `SessionMachine` hâlâ `[]` döndürüyor (dosya kart kapsamı dışında). Mesaj önce makineye verilir (heartbeat), sonra `SessionServer` yalnızca aktif oturumun şifreli kontrol bağlantısından geldiyse `handlers.audioPrefs`'e iletir. Bkz. Open questions.
  - `AUDIO_CONFIG(STARTED)` IOProc gerçekten başlayınca (`AudioDeviceStart` sonrası) gönderilir; izin istemi açıkken hiçbir şey gönderilmez. Başlamadan durdurulursa STARTED/STOPPED gitmez.
  - Kesinti (varsayılan çıkış değişti, çıkış cihazı ya da aggregate öldü, aggregate örnekleme hızı ya da tap biçimi değişti, uyanma) = akış çalışıyorsa önce `AUDIO_CONFIG(STOPPED, N)`, sonra eski yakalama durdurulur ve **yeni `stream_id`** ile yeniden kurulur. Kesintiden sonraki kurulum başarısız olursa 2 kez, 1 sn arayla yeniden denenir (`audio_rebuild_retry`), sonra `audio_unavailable`. Dinleyiciler kurulum anındaki değerle karşılaştırır; değişmeyen bildirim yeniden kurmaz. Akış içi `sample_index` sıçraması yalnızca HAL `mSampleTime` atlaması için kullanılır.
  - `stream_id` host genelinde artar (1'den, 0 atlanır); oturum başına sıfırlanmaz.
  - Başarısızlıkta `audio_unavailable` oturum başına bir kez loglanır; `enabled` 0→1 yeniden dener. `MATEBRIDGE_AUDIO=off` → `audio_unavailable reason=disabled_by_env` (süreç başına bir kez).
  - Halka: 16 yuva × 480 kare; gönderici en çok 10 paket (100 ms) geriden okur, eskiyi atar. **Yuva sahipliği** (Codex P1): tüketici kopyalamadan önce indeksi sahiplenir (`reading`), üretici yuvaya yazmadan önce indeksi duyurur (`writing`); ikisi de sıralı tutarlı yazma + karşı tarafı okuma (Dekker). Çakışmada üretici o (en yeni) paketi atar (`takeProducerDrops`, `sample_index` boşluğu) ve sonraki pakette yuvayı yeniden dener; tüketici yeniden kullanılan (eski) indeksi bırakır. IOProc kilitsiz ve tahsissiz kalır. Üretici atmaları stats `dropped` içinde.
  - Gönderici `AudioStreamer` kuyruğunda 5 ms zamanlayıcı. Mühürleme oturum kuyruğunda (~µs/paket).
  - `SessionServer.sendAudio` → `AudioOutbox` (Core, testli; kilit altında): sıra korunur (STARTED karelerinden önce, STOPPED sonra), en çok 10 `AUDIO_FRAME` bekler ve **yenisi en eskisinin yerini alır** (en yeni kazanır). Oturum kuyruğu ne kadar meşgul olursa olsun en çok bir boşaltma geçişi kuyrukta. Boşaltmada mühürlemeden önce yakalanalı 100 ms'den eski kare (duraklama sonrası bayat) atılır; yazılmamış bayt + bu kare > 10 × 1969 B (100 ms, ≈19,2 KiB, çerçeveleme dahil) ise atılır. `AUDIO_CONFIG` asla atılmaz; ses yüzünden bağlantı 256 KiB sınırına düşmez.
  - Stats: `dropped` host'taki bütün kayıplar (halka, üretici, sunucu), `wire_dropped` bunun sunucu payı.
  - `AudioStreamer` oturum olaylarını ve `AUDIO_PREFS`'i birleştirir (`AudioControlInbox`): son istenen durum + en çok bir bekleyen uzlaştırma geçişi. Bir `AUDIO_PREFS` seli oturum sonunu ya da kapatmayı geciktiremez. Arada bir kapatma birleştirildiyse son açmadan önce uygulanır (kapat/aç başarısız yakalamayı yine yeniden dener).
  - `SystemAudioTap` istekleri birleştirir (Codex P2): tek istenen durum (son `start`, `stop` sonrası hiçbiri) + en çok bir bekleyen uzlaştırma geçişi. İzin istemi kuyruğu bloke ederken gelen istekler birikmez. `AudioDeviceStart`'tan hemen önce istenen durum yeniden denetlenir; artık istenmiyorsa başlatmadan söker (`audio_capture_cancelled`, Mac hiç susmaz). Başarısız yakalama istenen durumdan silinir (sonraki geçiş onu yeniden kurmaz).
  - Kesinti dinleyicileri engelleyici `AudioDeviceCreateIOProcIDWithBlock`'tan **önce** kurulur; istem açıkken olan değişiklik sonrasında işlenir. `AudioDeviceStart`'tan hemen önce kurulum yeniden doğrulanır: varsayılan çıkış (kimlik + UID), çıkış canlı mı, tap biçimi, aggregate hızı, tampon düzeni. Değiştiyse yarım kurulum sökülür ve yeniden kurulur (`audio_setup_changed`, en çok 3 deneme, sonra `failed reason=setup_changed_<neden>`).
  - IOProc bloğu dispatch kuyruğu olmadan (`nil`) HAL'in gerçek zamanlı G/Ç iş parçacığında çalışır.
  - **Açılıştaki sızıntı taraması kaldırıldı** (kartın "Açılışta adıyla sızmış tap'ler temizlenir" maddesinden bilinçli sapma). Tap'imiz private: yalnızca bu süreç görür ve süreçle birlikte gider. Başka süreçlerin tap'lerinde `kAudioTapPropertyDescription` sahipliği belgesiz; yanlış `takeRetainedValue` açılışta çökertebilirdi.
  - Stats satırı kartın alanlarına ek olarak `wire_dropped=` taşır. `callback_ms_p50_95` paket başına "son yayından beri en uzun geri çağrı" değerlerinden hesaplanır.
  - Tap tamponu seçimi: aggregate giriş akışlarından sonuncusu stereo ise o, değilse son iki mono (`TapBufferLayout`). Tap biçimi 48 kHz/2 kanal/Float32 değilse `audio_unavailable reason=tap_format_<hz>hz_<n>ch`.
- **Test EDİLMEYEN (orkestratör, cihazda/izinle):**
  1. İlk oturumda izin istemi: oturum, video ve girdi istem açıkken akmaya devam ediyor mu? İzin verince `audio_capture_started` + `audio_started`, tablette ses (T-095 gerekir) ve Mac hoparlörü susuyor mu?
  2. İzin **reddedilince** ne oluyor: `AudioDeviceCreateIOProcIDWithBlock` hata mı döndürüyor (→ `audio_unavailable reason=ioproc_create`), yoksa başarılı olup sessizlik mi veriyor? İkincisiyse `rms_dbfs=-120` akar ve Mac susturulmuş olabilir; ayrı bir izin denetimi gerekebilir.
  3. `enabled=0`, BYE, Wi-Fi kopması, tabletten çıkış ve host Quit/`kill -9` sonrası Mac sesi hemen geri geliyor mu? (`.mutedWhenTapped` + private tap.)
  4. Varsayılan çıkışı değiştirme (HDMI ↔ hoparlör/kulaklık), USB ses kartı çıkarma, uyku/uyanma, Audio MIDI Setup'ta örnekleme hızı değiştirme → `audio_rebuild` (`format_changed` dahil), tablete `STOPPED` sonra yeni `stream_id` ile sürüyor mu? Uyanmada `audio_rebuild_retry` görülüyor mu, sonunda kuruluyor mu? `audio_listener_refused` (tap biçimi dinleyicisi desteklenmiyorsa) logu çıkıyor mu? Girişi olan bir ses kartında `TapBufferLayout` doğru tamponu seçiyor mu (`audio_capture_started layout=…`)?
  5. Çıkış cihazı 44,1 kHz'deyse tap biçimi 48 kHz mi kalıyor? Kalmıyorsa ses kapanır (`tap_format_44100hz_2ch`), yeniden örnekleme ayrı iş olur.
  6. `audio stats`: `callback_ms_p50_95`, `ring_ms_max`, `dropped`/`wire_dropped` Wi-Fi'de makul mü; 240 kare tampon kabul ediliyor mu (`audio_buffer_size_refused` yok, `buffer_frames=240`).
  7. `AUDIO_FRAME.capture_time_us` ile video `capture_time_us` aynı saat mi (A/V senkronu, T-095 ile).
  8. İzin istemi açıkken tablette ses aç/kapat birkaç kez: istem kapanınca yalnızca son durum uygulanıyor mu; kapalıysa Mac hiç susmuyor mu (`audio_capture_cancelled`)?
  9. IOProc HAL G/Ç iş parçacığında (`nil` kuyruk): `callback_ms_p50_95` küçük ve aksama yok mu; `AudioDeviceStop` sökme sırasında takılma yok mu?
  10. İzin istemi açıkken varsayılan çıkışı değiştir, sonra izin ver: `audio_setup_changed reason=default_output_changed` ve yeni çıkışla başlıyor mu?
  11. Wi-Fi'de kısa bir takılmadan sonra ses bayat değil güncel mi geliyor (`wire_dropped` artar, gecikme birikmez)? Normal akışta `wire_dropped=0` mı (100 ms bayatlık sınırı, IO gecikmesiyle çakışmamalı)?
- **Open questions:**
  - `SessionMachine.handleCommon` (`MateBridgeCore/Session/`, kapsam dışı) `.audioPrefs` için `isActive ? [.deliver] : []` döndürse yönlendirme makinede olurdu; şimdilik `SessionServer` aktif bağlantı kimliğiyle süzüyor. Orkestratör isterse küçük bir takip işi.
  - İzin durumunu önceden sorgulayan public API bulunamadı (yalnızca özel TCC). Reddedilme davranışı cihazda görülmeli (madde 2).

