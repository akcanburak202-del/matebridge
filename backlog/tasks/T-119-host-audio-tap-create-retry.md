---
id: T-119
title: Host — ses tap'i oluşturulamazsa (oturum devri yarışı) kalıcı vazgeçme; kısa gecikmeyle yeniden dene
status: in-progress
phase: 5
owner: mac-host-dev
depends_on: []
decisions: [0011]
files:
  - host-mac/Sources/MateBridgeHost/Audio/
  - host-mac/Sources/MateBridgeCore/Audio/
  - host-mac/Tests/MateBridgeCoreTests/
  - backlog/tasks/T-119-host-audio-tap-create-retry.md
---

## Amaç

Cihazda görüldü (2026-10-02 ~10:20). APK kurulumundan sonra tablet 0,4 s içinde iki kontrol bağlantısı açtı ve oturum devri (takeover) oldu:

```
audio_stopped stream_id=3 reason=session_end
session_superseded conn=8
session_started conn=11
audio_capture_stopped stream_id=3
(1,1 s sonra) audio_unavailable reason=tap_create status=0 stream_id=4
```

- `AudioHardwareCreateProcessTap` `noErr` döndürdü ama `tapID` `kAudioObjectUnknown` kaldı. Büyük olasılıkla önceki tap/aggregate henüz sökülürken yeni tap istendi.
- `SystemAudioTap.build` içindeki `fail` bu isteği kalıcı bırakıyor ("never rebuilt by a later pass").
- Sonuç: oturum boyunca ses tablete gitmedi. Mac'in kendi hoparlöründen çaldı, kullanıcı fark etti. Ancak yeni bir oturum düzeltti.

## Kapsam dışı

- Tablet tarafının çift bağlantı açması (ayrı konu; Açık sorular'a not edilebilir).
- Ses biçimi/yakalama mimarisi.

## Kabul kriterleri

- [ ] `tap_create` / `aggregate_create` geçici hataları (status hata ya da `noErr` + bilinmeyen ID) sınırlı yeniden denemeye girer: örneğin 3–5 deneme, artan gecikme (100 ms → ~1 s). İstek o arada iptal edildiyse (oturum bitti, `desired` değişti) deneme yapılmaz. Kalıcı hatalar (`no_output_device`, desteklenmeyen biçim) bugünkü gibi hemen vazgeçer; Plan'da sınıflandırma yazılır.
- [ ] Yeniden kurulumdan önce önceki çalışmanın sökümü tamamlanmış olur (aynı kuyrukta sıralı). Yarışın kaynağı Plan'da açıklanır.
- [ ] Log: her deneme için `ev=audio_retry reason= attempt= delay_ms=`. Son başarısızlıkta bugünkü `audio_unavailable` satırı.
- [ ] Mevcut `AudioStreamer` yeniden kurma politikasıyla (`retryDue`) çakışmaz; mümkünse o politika yeniden kullanılır.
- [ ] Deneme/sınıflandırma mantığı Core'da, birim testli: geçici hata → başarılı deneme; iptal edilen istek; kalıcı hata.
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi (hızlı yeniden bağlanma) orkestratörde.

## Plan

**Yarışın kaynağı.** Bizim tarafta sıra zaten doğru: `SystemAudioTap.reconcile` tek seri kuyrukta önce eski çalışmayı söküyor (`AudioDeviceStop` → `DestroyIOProcID` → `DestroyAggregateDevice` → `DestroyProcessTap`, log `audio_capture_stopped stream_id=3`), sonra yeni çalışmayı kuruyor. `build` içindeki `fail` de `.failed` olayından önce kendi yarım kurulumunu söküyor. Bu çağrılar coreaudiod'a senkron IPC olarak gidiyor. Ama daemon tarafında tap'in ve özel aggregate'in kaldırılması (IO durdurma, mute'un geri alınması) çağrı döndükten sonra da sürüyor gibi görünüyor. Hemen ardından gelen `AudioHardwareCreateProcessTap` `noErr` döndürüp nesne vermiyor. Bu bir hipotez; cihazda doğrulanacak. İstemcinin süreç içinden "söküm bitti" diye bekleyebileceği belgelenmiş bir sinyal yok. Bu yüzden çözüm, kısa ve artan gecikmeyle yeniden denemek.

**Yer: politika (Core).** Yeniden deneme `AudioStreamPolicy` içinde, mevcut `scheduleRetry`/`retryDue` (token) mekanizmasıyla yapılır. Yeni zamanlayıcı ya da kuyruk eklenmez. Backend'in `fail` davranışı değişmez: o istek kalıcı olarak düşer. Her deneme, politikanın verdiği **yeni bir stream_id** ile yeni bir `startCapture` olur. Rebuild yeniden denemesi de bugün böyle çalışıyor. STARTED hiç gönderilmediği için tablete hiçbir şey gitmez. Sıralama: `.failed` gelmeden önce tap kuyruğunda söküm bitmiş olur, ardından `stopCapture(eski)` (no-op) gider. Yeni `start` aynı seri tap kuyruğunda sökümden sonra çalışır.

**Sınıflandırma (Core, `AudioCaptureFailure`):** neden metinleri sabit olarak Core'a taşınır, host bu sabitleri kullanır.
- Geçici: `tap_create`, `aggregate_create`. Hem hata status'u hem `noErr` + bilinmeyen ID bu sınıfa girer.
- Kalıcı: `no_output_device`, `no_output_uid`, `tap_format`, `tap_format_<hz>_<ch>` (desteklenmeyen biçim), `tap_layout`, `ioproc_create` (izin), `device_start`, `setup_changed_*`. Bunlar bugünkü gibi hemen `audio_unavailable` verir. İstisna: bir interruption sonrasındaki rebuild'de mevcut 2×1 s rebuild denemesi sürer.

**Politika değişikliği:**
- `transientRetryDelaysUs = [100, 250, 500, 1000] ms`: en çok 4 ek deneme, toplam yaklaşık 1,85 s.
- `captureFailed` (yalnızca başlarken, çalışırken değil) geçici bir hata alırsa ve deneme hakkı kalmışsa: `stopCapture` + `scheduleRetry(token, delay)` + `log audio_retry reason= attempt= delay_ms= status= stream_id=`. `failed`/`unavailableLogged` değişmez.
- Geçici denemeler bitince mevcut akış devam eder: rebuild hakkı varsa `audio_rebuild_retry`, yoksa `audio_unavailable` (bugünkü satır).
- Sayaç `captureStarted`, `stop` (oturum sonu, disable) ve `captureInterrupted` ile sıfırlanır.
- İptal: oturum biterse ya da disable gelirse `stop` → `.waitingRetry` iptal olur, zamanlayıcı eşleşme bulamaz (token). Böylece iptal edilen bir istek için deneme yapılmaz.

**Host (`SystemAudioTap`):** neden metinleri için Core sabitleri kullanılır, sınıf yorumu yarışı ve yeniden deneme politikasını anlatacak şekilde güncellenir. Davranış değişmez.

**Testler (Core):**
- Politika: geçici hata → `audio_retry` → `retryDue` → yeni start → başarı. Gecikme dizisi ve tükenince `audio_unavailable`. Bekleme sırasında disable ya da oturum sonu gelirse deneme yapılmaz. Kalıcı hata hemen vazgeçer. Interruption + geçici hata birleşimi.
- Streamer: geçici hata gecikmeden sonra yeniden başlar.
- Mevcut `aggregate_create`/`tap_create` kullanan testler yeni sınıflandırmaya göre güncellenir.

**LOGGING.md** kapsam dışı (dosyalar listesinde yok). Orkestratör `audio_retry` satırını ekleyecek.

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
