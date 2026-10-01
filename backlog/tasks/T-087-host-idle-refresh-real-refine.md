---
id: T-087
title: Mac — boşta tazeleme gerçek hatta kalite artırmıyor (222 baytlık atlama kareleri); düzelt ve ölç
status: done
phase: 5
owner: mac-host-dev
depends_on: [T-086]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Tests/
  - backlog/tasks/T-087-host-idle-refresh-real-refine.md
---

## Amaç

T-086 cihaz ölçümü (orkestratör, 2026-10-01 ~15:35, `MATEBRIDGE_IDLE_REFRESH_MS=300 MATEBRIDGE_IDLE_REFRESH_COUNT=6`):
- Tam ekran kayan metin 3 s oynatıldı, sonra durdu.
- Durağan bölümde host 6 tazeleme karesi gönderdi. Tablet hepsini gösterdi (`release`), ama **her biri 222 bayt** (atlama karesi gibi).
- `--sharpness-bench`'te aynı düğmelerle tazeleme kareleri 75–240 KB ve PSNR 42,5 → 46–47,6 dB.

Yani gerçek hatta (SCK tamponu `last` aynı `CVPixelBuffer`/IOSurface nesnesiyle yeniden kodlanıyor) VideoToolbox kaliteyi artırmıyor. Olası neden: aynı tampon nesnesi ya da değişmemiş IOSurface ile VT değişiklik görmüyor. Bench ise içeriği aynı ama farklı bir tampon veriyor olabilir. Önce nedeni kanıtla.

## Kabul kriterleri

- [x] Neden kanıtlanır. `--sharpness-bench`'e gerçek hattı taklit eden bir kip eklenir: tazelemede **aynı** `CVPixelBuffer` nesnesi mi yoksa içerik kopyası mı gönderildiği seçilebilir. İki kipin kare baytı ve PSNR sonucu Handoff'a yazılır.
- [~] (kısmi, bkz. Handoff ve Açık sorular) Düzeltme: boşta tazelemede (yalnız tazeleme yolunda; `IDLE_REFRESH_MS>0` iken), VT'nin gerçekten yeniden kodlamasını sağlayan en ucuz yöntem kullanılır. Örnekler: son tamponun içeriğini havuzdan alınan yeni bir tampona kopyalamak (vImage/`CVPixelBufferLockBaseAddress` + memcpy ya da Metal blit), kare başına QP seçeneği, ya da başka bir VT yolu. Kopya maliyeti ölçülür (2800×1840 420f ~7,7 MB).
- [x] Anahtar kare yeniden gönderimi (KEYFRAME_REQUEST) davranışı değişmez (anahtar kare zaten tam kodlanıyor).
- [x] Varsayılanlar (düğme kapalı) bugünkü davranışla aynı kalır.
- [x] `./scripts/check.sh` geçiyor.

## Plan

Ön bulgu (koddan): T-086 `--sharpness-bench` de tazelemede **aynı** `CVPixelBuffer` nesnesini veriyor
(`resubmitLast()` → `last.buffer` = son hareket karesinin tamponu). Yani "bench farklı tampon veriyor" varsayımı
koddan doğrulanmıyor; fark başka yerde olmalı. İlk deneme: `--motion-frames 240` ile (oturum ısınmış) tazeleme
kareleri bench'te de **222 bayt**, son hareket karesi zaten ~48 dB. 30 karelik varsayılan, açılış anahtar karesinin
bit borcuyla hareket karelerini aç bırakıyordu (42 dB); tazeleme kazancı bu ısınma yapıntısıydı.

1. **Kanıt (bench):**
   - `SharpnessBenchOptions`: `--refresh-buffer same|copy` (varsayılan same = gerçek hat), `--motion-frames` üst
     sınırı 1200'e. Bench, çıktıya kip ve ısınma bilgisini yazar.
   - `HEVCEncoder`: tazeleme yolunda isteğe bağlı içerik kopyası (havuzdan IOSurface'lı yeni tampon, düzlem başına
     memcpy; kopya süresi ölçülür ve loglanır).
   - Ölçüm matrisi: motion 30 / 240, same / copy → kare baytı + PSNR Handoff'a.
2. **Neden belirlenince en ucuz düzeltme** (yalnız tazeleme yolu, `IDLE_REFRESH_MS>0` iken):
   - Kopya işe yarıyorsa: kopya varsayılan olur.
   - Yaramıyorsa (VT zaten kendi kalite tavanında): tazeleme karelerinde kaliteyi geçici yükselten bir VT yolu
     denenir (oturum özelliği `MaxAllowedFrameQP` / `Quality` / `PrioritizeEncodingSpeedOverQuality` geçici
     değiştirilip ilk gerçek yakalamada eski hâline döndürülür). Desteklenmeyen özellik (OSStatus) loglanır, düşülür.
   - Saf mantık (kip ayrıştırma, "güçlendirme ne zaman açılır/kapanır" durum makinesi) `MateBridgeCore`'da, testli.
3. Anahtar kare yeniden gönderimi ve düğme kapalı varsayılanlar değişmez. `./scripts/check.sh`, bench'ler, Handoff.

## Handoff

- **Commit:** `0111c83` (plan), `e13e491` (uygulama). Dal `task/T-087-idle-refresh-refine`, `main` e964297 üzerinde.
- **check.sh:** ALL OK (host-mac build + test, probe'lar, Android gradle, fikstürler). Yeni `IdleRefreshRefineTests` 8 test.
- **Dosyalar:**
  - Core: `MateBridgeCore/Video/EncoderKnobs.swift` (`IdleRefreshBuffer`, `IdleRefreshConfig.buffer/maxQP`, `logValue`
    `+copy`/`+qpN`, yeni `RefreshQPBoost` durum makinesi), `MateBridgeCore/Video/SharpnessBenchOptions.swift`
    (`--refresh-buffer same|copy`, `--resume-frames N`, `--motion-frames` varsayılan 30 → **240**, üst sınır 1200).
  - Host: `MateBridgeHost/Video/HEVCEncoder.swift` (tazeleme kopyası, tazeleme karesine QP tavanı),
    `MateBridgeHost/Video/SharpnessBench.swift` (kip seçimi, devam (resume) bölümü, `resume_mean` satırı).
  - Test: `Tests/MateBridgeCoreTests/Video/IdleRefreshRefineTests.swift`.

### Neden (kanıtlandı)

1. **Tampon nesnesi neden değil.** T-086 bench'i de gerçek hat gibi aynı `CVPixelBuffer`'ı yeniden gönderiyordu.
   Aynı ve kopya kipleri bayt ve PSNR olarak aynı sonucu veriyor (tablo A).
2. **Asıl neden: oturum ısınınca (settled) son hareket karesi zaten hız denetiminin (RC) QP tabanında kodlanıyor.**
   Aynı içerik aynı QP ile yeniden kodlanınca kodlanacak artık (residual) kalmıyor, VT tümü-atlama karesi üretiyor (222 B).
   T-086'nın 30 karelik bench'i açılış anahtar karesinin (~1,4 MB) bit borcu yüzünden hareket karelerini aç bırakıyordu
   (QP yüksek, 42 dB). 300 ms sonra borç ödenmiş oluyor, RC QP'yi düşürüyor ve tazeleme "iyileştiriyor" görünüyordu.
   240 karede (2 s, gerçek oturuma benzer) bench de **222 B** üretiyor. Tablet ölçümü bununla birebir aynı.
3. Taban QP bit hızına bağlı (fast profil, 6 px kaydırma, sabit son kare PSNR): 20 Mbps 40,8 dB · 60 Mbps 48,5 dB ·
   150 Mbps 56,6 dB. Hepsinde kare başı bayt bütçenin altında. Yani RC bütçe dolduğu için değil, hedef bit hızından türettiği
   tabanda duruyor.
4. **Fast profil (varsayılan, RealTime=false, LLRC yok) oturum sırasında yapılan hiçbir değişikliği uygulamıyor.**
   Denenen ve etkisiz olanlar (çıktı baytı bayt-bayt aynı, readback değeri ise değişmiş görünüyor):
   `MaxAllowedFrameQP` (8/10/15/20), `Quality` (0.9/1.0, Quality kipli oturumda da), `AverageBitRate`+`DataRateLimits`
   (150 Mbps), `PrioritizeEncodingSpeedOverQuality=false`, `CompleteFrames`+`PrepareToEncodeFrames` sonrası tekrar,
   kare süresi (`duration` 300/2000 ms), zorunlu anahtar kare + bu ayarlar (anahtar kare 1 812 729 B, her durumda aynı).
   `kVTEncodeFrameOptionKey_BaseFrameQP`: `SupportsBaseFrameQP` = -12900 (desteklenmiyor). `RealTime=true` (LLRC'siz)
   de değiştirmiyor. Aynı özellikler **oturum oluşturulurken** veriliyse etki ediyor (ör. `MaxAllowedFrameQP=10` →
   hareket ort. 51,4 dB, son 51,6 dB, ~aynı bayt). Yani tazeleme yolunda (yalnız tazeleme karelerine) fast profilde
   kaliteyi yükseltecek bir VT yolu bulunamadı.
5. **LLRC profili (`MATEBRIDGE_ENCODER=llrc`) oturum içi `MaxAllowedFrameQP` değişikliğini uyguluyor.** Tazeleme
   karelerine QP ≤ 10 tavanı gerçek iyileştirme veriyor (tablo B).

### Düzeltme (yalnız tazeleme yolu, düğmeyle; varsayılan değişmedi)

- `MATEBRIDGE_IDLE_REFRESH_BUFFER=same|copy` (varsayılan `same`). `copy`: son tampon havuzdan alınan IOSurface'lı
  yeni tampona memcpy ile kopyalanır (ek bilgiler `CVBufferPropagateAttachments` ile). Kilit dışında kopyalanır. Bu arada
  yeni bir yakalama geldiyse kopya atılır. **Etkisi yok** (kanıt kipi olarak duruyor). Kopya maliyeti (debug build,
  2800×1840 420f): ilk 2 kopya 2,4–3,1 ms (havuz kurulumu ve sayfa hataları), sonrası **0,73–0,82 ms**.
- `MATEBRIDGE_IDLE_REFRESH_QP=N` (1–51, varsayılan yok). Yalnız `.resubmit` tazeleme karelerinden önce
  `MaxAllowedFrameQP=N` konur. Başka herhangi bir kareden önce (gerçek yakalama, KEYFRAME_REQUEST/boşta anahtar kare
  yeniden gönderimi) 51'e geri alınır. VT NULL'u reddediyor; 51'in "tavan yok" ile aynı davrandığı ölçüldü:
  `QP=51` ile devam bölümü taban çizgisiyle aynı (51,14 dB / 18,9 KB). Karar ve özellik çağrısı tek kilit
  (`boostLock`) altında. Kilit `VTCompressionSessionEncodeFrame`'i kapsamıyor (kilitlenme riski yok). VT tavanı
  reddederse oturum boyunca kapatılır ve loglanır. Fast profilde açılışta
  `ev=idle_refresh_qp effective=0 reason=fast_profile_ignores_midstream_qp` (warning) yazılır.
  Saf mantık `RefreshQPBoost` (Core, testli).
- Anahtar kare yolu (`requestKeyframe`, `IDLE_REFRESH_KEY=1`) değişmedi. QP tavanı yalnız `.resubmit` karelerine uygulanıyor.
- Düğmeler kapalıyken davranış: `Input.refresh` bayrağı yalnız taşınıyor. Kopya ve QP kodu çalışmıyor
  (`qpBoostEnabled == false`, `buffer == .same`).

### Bench sonuçları (M6, debug build, 2800×1840@120, HEVC, 60 Mbps prefs, `IDLE_REFRESH_MS=300`)

**A. Aynı tampon / kopya** (`--refresh-buffer same|copy`, 6 tazeleme, 6 px kaydırma):

| motion kare | kip | motion_last PSNR / B | tazeleme n1…n6 B | static_end PSNR |
|---|---|---|---|---|
| 30 | same | 42,54 / 13 579 | 163 942, 244 217, 75 739, 27 281, 98 777, 141 958 | 47,38 |
| 30 | copy | 42,15 / 23 224 | 190 850, 254 731, 79 416, 28 583, 99 107, 143 844 | 47,35 |
| 240 | same | 48,46 / 672 | 1 854, 622, 533, 239, **222, 222** | 48,48 (+0,02) |
| 240 | copy | 48,50 / 773 | 930, 555, 480, 244, **222, 222** | 48,51 (+0,01) |

**B. QP tavanı** (3 tazeleme, 24 px kaydırma, `--resume-frames 240`):

| env | motion_last | tazeleme n1 / n2 / n3 (B, PSNR) | static_end | resume ort. PSNR / B (maks) |
|---|---|---|---|---|
| fast, düğmesiz | 47,14 dB | — | 47,14 | 47,28 / 35,0 KB (85,5 KB) |
| fast, `QP=10` | 47,14 | 7 519 / 4 699 / 1 981 B, 47,19 dB | 47,19 | 47,29 / 34,9 KB (85,7 KB) |
| llrc, düğmesiz | 51,07 | 3 122 / 2 377 / 2 358 B, 51,09 dB | 51,09 | 51,14 / 18,9 KB (39,5 KB) |
| llrc, `QP=10` | 51,07 | **329 147 / 22 538 / 12 916 B, 57,30 → 57,39 dB** | **57,39 (+6,3)** | 54,92 / 22,8 KB (46,6 KB) |

6 px kaydırmada llrc `QP=10`: 51,28 → 57,57 / 57,63 / 57,65 dB (308 KB, 20 KB, 12 KB). `QP=16` llrc'de etkisiz
(taban zaten ≤ 16).

Not: llrc'de tazelemeden sonra tavan kalkıyor (readback 51), ama RC'nin iç QP durumu aşağı çekilmiş kalıyor.
Devam eden 240 karede (ekran içeriği ~3 kez tamamen yenilendi) kalite +3,8 dB, ortalama bayt +%20, en büyük kare +%18
(hepsi 60 Mbps kare bütçesinin, 62,5 KB, altında). Bu yan etki gerçek akışta ölçülmeli.

### Varsayımlar

- Bench'te 240 karelik hareket "çalışan oturum" yerine geçiyor. Gerçek ekran içeriği saf öteleme değil;
  tabandaki PSNR değerleri içeriğe göre değişir. Ama 222 B tablet gözlemi bench'le birebir örtüşüyor.
- Fast profilde tazeleme, ancak son hareket kareleri bütçeyi aştığında (RC QP'yi yükselttiğinde) işe yarar.
  Ör. ağır içerik ya da açılıştan hemen sonra. Bench'teki 30 kare durumu bunun örneği.

### Test EDİLMEDİ (cihaz gerekli)

- Gerçek oturumda `MATEBRIDGE_ENCODER=llrc MATEBRIDGE_IDLE_REFRESH_MS=300 MATEBRIDGE_IDLE_REFRESH_QP=10`
  (≤ 60 fps önerilir; llrc 2800×1840'ta ~10 ms/kare). Beklenen: ilk tazeleme karesi ~300 KB, sonra onlarca KB.
  Tablette durağan yazı keskinleşmeli. Devam hareketinin ilk karelerinde kare büyüklüğü/gecikme artışı izlenmeli.
- 300 KB'lık tek tazeleme karesinin tablet pacer/kod çözücüde ve Wi-Fi'de gecikme ya da kare düşmesi yaratmadığı.
- `MATEBRIDGE_IDLE_REFRESH_BUFFER=copy`'nin gerçek SCK tamponuyla çalıştığı (bench'te çalışıyor; etkisi yok).
- Host yeniden başlatılmadı, `bundle-host.sh` çalıştırılmadı, gerçek girdi olayı gönderilmedi.

### Açık sorular (orkestratör kararı)

1. **Varsayılan fast profilde tazeleme yolu üzerinden gerçek iyileştirme mümkün değil** (VT oturum içi değişiklikleri
   yok sayıyor, BaseFrameQP desteklenmiyor). Kart kapsamı ("yalnız tazeleme yolu") içinde fast profil için düzeltme yok.
   Seçenekler (hepsi tazeleme dışını da etkiler, bu yüzden uygulamadım):
   a. Oturum oluşturulurken `MaxAllowedFrameQP` düğmesi (ör. `MATEBRIDGE_MAX_QP=10..12`). Bench: 6 px'te ort.
      46,4 → 51,4 dB, bayt +%5. 24 px'te `12` ile +3 dB, bayt +%15, ama bir koşuda 205/240 kare (VT "QP hedefi için
      kare düşürebilir" diyor). Ağır içerikte kare düşmesi riski var, cihazda ölçülmeli.
   b. Mevcut `MATEBRIDGE_QUALITY` (T-086): 0.5 ve 0.75 ile 240 karede ~53 dB, ~28 KB/kare. 1.0 kayıpsız.
   c. ≤ 60 fps'te `llrc` + `IDLE_REFRESH_QP` (bu kart; çalışıyor, tablo B).
   d. Bit hızı: 150 Mbps → 56,6 dB taban (kare başı ~35 KB).
2. `IDLE_REFRESH_KEY=1` 240 karede de kötü: 1,8 MB anahtar kare 44,4 dB (< 48,5 dB P-kare). Kaldırılması düşünülebilir.
3. T-086 Handoff'undaki tazeleme kazancı (+3,6 dB) ısınma yapıntısıydı. Bench varsayılanı artık 240 kare.
   Gerekirse `docs/NOTES.md`'ye bir satır eklenmeli (bu kartın `files:` listesinde değil, dokunmadım).

