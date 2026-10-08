---
id: T-318
title: Tablet — perf_lever dev knobu (T-316 kaldıraç araştırması): sustained / ADPF / KEY_FRAME_RATE / game
status: done
phase: 7
owner: android-client-dev
depends_on: [T-316]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/debug/AndroidManifest.xml
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-318-perf-lever-knob.md
---

## Amaç

T-316 tablosu: dokunmasız DDR 749/1104 MHz, GPU 239, çözme p50 15,4 ms; dokunuşla DDR 1536, GPU 442, çözme 11,4 ms. Uygulamanın kök gerektirmeden DDR/çözücü saatini yükseltebileceği bir kaldıraç aranıyor. Tek bir geliştirici knobu: `--es perf_lever none|sustained|adpf|fps120|fpsunset|game|gpukeep|all` (`--ez dev true` ile; varsayılan `none`).

## Plan

Araştırma (API 31, kök yok, yeni bağımlılık yok):

| Aday | API | Durum / HarmonyOS 4.x, Kirin |
|---|---|---|
| Sürdürülebilir performans | `PowerManager.isSustainedPerformanceModeSupported()` + `Window.setSustainedPerformanceMode(true)` (API 24) | AOSP: OEM `isSustainedPerformanceModeSupported` ile ilan etmeli, aksi halde etkisiz. Amacı termal kısılmayı önlemek (sabit, düşük/orta saat); DDR'ı yükseltme garantisi yok. Cihaz bulgusu: Power HAL AIDL yok, bu yüzden büyük olasılıkla `supported=0`. Knob `sustained`. |
| ADPF | `PerformanceHintManager.createHintSession(tids, targetNs)` + `reportActualWorkDuration` (API 31) | Güç HAL'ine gider; HarmonyOS 4.x'te (AOSP tabanlı çalışma zamanı) desteği belgelenmemiş, Power HAL AIDL olmadığı için `null` oturum beklenir. API 31'de `setThreads` yok (API 34), iş parçacığı kümesi değişince oturum yeniden yaratılır. Knob `adpf`: tid'ler UI + o kuşağın çözücü giriş/çıkış iş parçacığı, hedef = bir kare periyodu, rapor = kare başına çözme gecikmesi. Dakikada bir rapor sayısı loglanır. |
| `KEY_FRAME_RATE` | MediaFormat | Şimdiki davranış: akış fps'i. `KEY_OPERATING_RATE` zaten `Short.MAX_VALUE` (T-222), AOSP: frame rate yalnızca operating rate yokken ve priority 0 iken çalışma noktasını belirler, yani etkisi beklenmez; yine de A/B için `fps120` (anahtar 120) ve `fpsunset` (anahtar yok). `KEY_PRIORITY` zaten 0 (gerçek zamanlı). |
| Vendor MediaCodec anahtarları (HiSilicon `vendor.hisi-*`) | MediaCodec parametreleri | Herkese açık belge yok; var olan `logVendorParameters` (T-168) listesi dışında anahtar tahmin edilmedi. Eklenmedi. |
| `android:appCategory="game"` / GameManager | manifest, `GameManager` (API 31) | `GameManager.getGameMode()` API 31'de uygulama için salt okunur (kullanıcının seçtiği modu döner; `setGameState` API 33 ve oyun durumu bildirir); uygulama modu değiştiremez. `appCategory=game` yalnız OS'in uygulamayı oyun diye tanımasını sağlar (Huawei oyun asistanı/kaynak ayırma buna bakabilir; belgelenmemiş). Manifest özniteliği çalışma zamanında değişmez: yalnız `src/debug/AndroidManifest.xml`'de (debug derleme) var, `daily` ve `main` değişmedi; knob `game` yalnızca derlemenin kategorisini (`applicationInfo.category`) ve `GameManager` modunu loglar. Orchestrator debug ile daily'yi karşılaştırır. Ölçümden sonra geri alınmalı (benimsenmezse). |
| Huawei HMS / PerfGenius | HMS SDK | Yeni bağımlılık ve karar kaydı gerekir; yalnız tarif, eklenmedi. |

Kaynaklar:
- PerformanceHintManager (API 31): https://developer.android.com/reference/android/os/PerformanceHintManager
- Sustained performance (OEM ilanı): https://source.android.com/docs/core/power/performance
- GameManager (getGameMode API 31, setGameState API 33, `appCategory`/`isGame`): https://developer.android.com/reference/android/app/GameManager
- MediaFormat KEY_FRAME_RATE / KEY_OPERATING_RATE / KEY_PRIORITY: https://developer.android.com/reference/android/media/MediaFormat
- HarmonyOS NEXT'in AOSP'yi bıraktığı, 4.x'te bu API'lerin belgelenmemiş olduğu: arama sonucunda bu API'ler için Huawei belgesi bulunamadı (kanıt yokluğu; varsayım).

Uygulama: `video/PerfLever.kt` (saf mantık: `PerfArm`, `FrameRateKeyMode`, `PerfLever` + `PerfBackend` arayüzü), `video/AndroidPerfBackend.kt` (Android çağrıları), `VideoRenderer` (`frameRateKey`, `perfSink`), `DevKnobs.perfLever`, MainActivity `perfStart`/`perfStop`.
Yaşam döngüsü: `perfStart` installConfig'te (codec yaratılmadan önce) ve surfaceCreated'da (akış varken); `perfStop` surfaceDestroyed, `releaseRenderer` (onStop, onDestroy, oturum bitişi) içinde. Her ikisi de idempotent. Tüm platform çağrıları try/catch içinde: hata = `supported=0`/`applied=0` ve log, istisna yok.

## Handoff

- Dal `task/T-318-perf-lever`; commit SHA: `git log task/T-318-perf-lever -1`. check.sh: ALL OK.
- Dosyalar: DevKnobs.kt, video/PerfLever.kt, video/AndroidPerfBackend.kt, video/VideoRenderer.kt, MainActivity.kt, src/debug/AndroidManifest.xml, PerfLeverTest.kt, DevKnobsTest.kt, bu kart.
- Gerçek kollar (yeni bağımlılık yok): `sustained` (Window/PowerManager API 24), `adpf` (PerformanceHintManager API 31), `fps120`, `fpsunset` (MediaFormat anahtarı; codec bir sonraki oluşturuluşta okur, installConfig codec'ten önce ayarlar), `all` = sustained + adpf + fps120, `game` (yalnız debug derlemede manifest kategorisi; knob sadece log).
- "API 31'de desteklenmiyor"/kullanılmadı: GameManager ile oyun modu ayarlamak (salt okunur), `setGameState` (API 33), `PerformanceHintManager.Session.setThreads` (API 34), vendor MediaCodec anahtarları (belgesiz), HMS PerfGenius (bağımlılık, karar gerekir). Cihaz bulgusu (orchestrator): Power HAL AIDL yok → `sustained`/`adpf` çoğu kez `supported=0` ya da `perf_hint_session result=null` beklenir; kod bunda güvenli.
- Loglar (tag `render`): `ev=perf_lever arm=… supported=0|1 applied=0|1 detail=…` (kol başına bir kez, akış başlangıcında), `ev=perf_hint_session result=created|null|err_… tids=N target_us=…`, `ev=perf_hint_reports count=N window_ms=…` (dakikada bir), `ev=perf_lever_off arm=… reports=N` (kapanış). `ev=profile knobs=` `perf_lever:<kol>` gösterir.
- Not: `game` kolu için `src/debug/AndroidManifest.xml`'e `android:appCategory="game"` konuldu (placeholder yerine debug kaynak setinin manifesti; `daily` ve `main` değişmedi). Ölçümden sonra benimsenmezse BU SATIR GERİ ALINMALI.
- Test edilmedi: cihazda hiçbir şey (adb kullanılmadı). Kare başına rapor çözme gecikmesidir (giriş kuyruğa → çıkış), UI vsync/yeniden çizim süresi değil.
- Tablette ölçülecek: her kolu `--ez dev true --es perf_lever <kol>` ile aynı hareket sahnesinde, dokunmasız, 45 sn: DDR/GPU saatleri (10 Hz), çözme p50, `cap_dec` p50, `skip_pct`, pil/ısı. Önce loglarda `supported`/`applied` ve `perf_hint_session result=`'a bak; `applied=0` ise ölçüme gerek yok. `game` için debug derlemeyi `none` ile ve daily'yi karşılaştır (debug APK `perf_lever=game` `applied=1` loglamalı). `fps120`/`fpsunset` için `ev=codec_start` biçim satırında `KEY_FRAME_RATE`'in değişip değişmediğini (T-168 format logu) doğrula. Tüm kollar `none` ile bir A/B çiftinde; kapanış: arka plana geçince `ev=perf_lever_off` görünmeli.
- Önerilen KNOBS satırı (23n): `--es perf_lever none/sustained/adpf/fps120/fpsunset/game/all` | varsayılan `none` | `…/session/DevKnobs.kt` (`perfLever`); `…/video/PerfLever.kt`; `VR` (`frameRateKey`, `perfSink`) | T-318, T-316 | yalnızca geliştirici | akış sürerken (ön planda) saat kaldıraçlarını dener, onStop/ayrılmada kapatır | T-318.

## Open questions

- `appCategory` için istenen "manifest placeholder" yerine debug kaynak setinin manifesti kullanıldı (aynı etki, daha az Gradle). İstenirse placeholder'a çevrilir.
- Çalışan kaldıraç yoksa knob + debug manifest satırı bir sonraki döngüde kaldırılmalı (orchestrator kararı).

## Ek: gpukeep kolu (orchestrator ölçümü, 2026-10-08)

Cihaz verisi: DDR sürücü değil; tek büyük kazanç GPU 442 MHz ile (dokunma güçlendirmesi, çözme p50 11,4 ms). `gpukeep` kolu: akış sürerken kendi iş parçacığında (`mb-gpukeep`), kendi EGL bağlamında, 256x256 pbuffer için kare periyodunda bir glClear + glFinish (görünmez, video yoluyla paylaşım yok). `video/GpuKeep.kt`. onStop/detach/perfStop ile durur. Maliyet logu: `ev=gpukeep frames=N window_ms=… busy_us_avg=…` 10 sn de bir; kapanışta `ev=perf_lever_off … gpukeep_frames=N`. Başlangıç: `ev=perf_lever arm=gpukeep supported=1 applied=0|1 detail=pbuffer_clear_finish|egl_failed period_us=…`. `all` gpukeep içermez. Yük çok küçük; GPU hâlâ 239 kalırsa `GpuKeep.SIZE` ve döngü içeriği büyütülür. Ölçülecek: GPU frekansı, çözme p50, CPU/enerji, busy_us_avg. Cihazda denenmedi.

### gpukeep yük knobları (orchestrator isteği)
`--ei gpukeep_px N` (varsayılan 256, 16..4096) ve `--ei gpukeep_draws K` (varsayılan 1, 1..64; yalnız `--ez dev true` ile). Kare başına N×N pbuffer üzerinde bir `glClear` + (K-1) tam boy ucuz fragment-shader dörtgeni (texture okuması yok). K=1 önceki davranışla aynı (yalnız clear). `ev=perf_lever arm=gpukeep … px= draws=` loglanır; `ev=profile knobs=` `gpukeep_px:`/`gpukeep_draws:` gösterir. Önerilen adımlar: 1024/4, 2048/8. `GpuKeepLoad` saf, kenetleme testli.

## Sonuç (orkestratör, 2026-10-08)

**Birleştirilmedi.** Hiçbir kol dokunmasız saatleri ya da çözme süresini değiştirmedi (bkz. `docs/research/2026-10-08-ddr-clock.md`). Kod `task/T-318-perf-lever` dalında, tarih kaydı olarak kalıyor; debug manifestindeki `appCategory="game"` satırı da `main`'e girmedi.
