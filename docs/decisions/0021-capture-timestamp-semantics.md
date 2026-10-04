# 0021 — `capture_time_us`'in anlamı ve gecikme sayıları

- **Durum:** ilke olarak kabul (2026-10-03); A/B seçimi T-170 verisiyle
- **Tarih:** 2026-10-03

## Bağlam
Kaynak: dış mimari incelemesi 2026-10-03 (HEAD a30c769), H05, LM4 ve M04 (geç girdi sınırı). Doğrulama:
- `docs/reviews/2026-10-03/verify-C-host-video.md` (LM4, LM4-D);
- `verify-E-measurement.md` (H05, W4, ek 3);
- `verify-G-input.md` (ek 2).

İki taslak (C ve E) aynı konuyu ele aldığı için tek kararda birleştirildi (`coverage-audit.md` §4.3).

Gerçekler:
- **Teldeki damga PTS.** `VIDEO_FRAME.capture_time_us`, ScreenCaptureKit'in PTS'si (`HEVCEncoder.swift:553`). Host'un iz başlangıcı ise SCK geri çağrısı: `FrameTrace.origin`, `LatencyTrace.swift:64-69`.
- **PTS 6,6 ms ileride.** PTS geri çağrıdan yaklaşık 6,6 ms **sonra** (`pts_vs_deliv = +6,6 ms`, NOTES.md:401). Bu yüzden tabletin `latency_us` değeri gerçek yakalama→çözme süresini ~6,6 ms **eksik** gösteriyor. Bu konu T-072'de açık soru olarak kaldı.
- **Damga başka yerlerde de kullanılıyor.** Tablet pacer'ı (`AdaptivePacer.kt:8-9`) ve ses/görüntü eşlemesi (PROTOCOL §6, AUDIO `capture_time_us`) bugünkü damgaya dayanıyor. Damgayı değiştirmek bedava değil.
- **Belgeler yanlış.** PROTOCOL §0x22 `latency_avg_us` ve §6 formülü "→ ekranda gösterim" diyor (PROTOCOL.md:456, :573), ama kod çözücü çıktısını ölçüyor. Pacing, SurfaceFlinger ve panel bu sayıya dahil değil.
- **Geç girdi sınırı da yanlış yazılmış.** PROTOCOL §4 "Kabul edilen davranış" (PROTOCOL.md:300), geç vuruşun üst sınırını istemci kuyruğu (1 sn) olarak veriyor. Oysa çekirdek tamponundaki girdinin yaş sınırı yok. Gerçek sınır, host'un 5 sn'lik sessizlik kapanışı (G ek 2).

## Seçenekler
- **(A) Tel değişmez (önerilen; T-170 verisinde `pts_vs_deliv` p99−p1 < 1 ms çıkarsa).**
  - Tablet sayıları "capture-stamp→…" diye adlandırılır.
  - Analiz, host'un logladığı ileri kaymayı ekler.
  - Fixture değişmez.
- **(B) `VIDEO_FRAME`'in `data` alanından sonra `origin_offset_us: i32` eklenir** (origin − capture_time_us, ≤ 0; §2 sona alan eklemeye izin veriyor).
  - Tablet origin→decode süresini de raporlar.
  - **Tel değişikliği:** PROTOCOL §0x41, yeni golden vektör (`video_frame_origin`), iki fixture testi ve host ile istemci için iki takip kartı gerekir.
  - Ancak kayma oynaksa değerli olur.

## Karar
Önerilen: **(A)**, şu koşulla: T-170'in birleştirilmiş izleri kaymanın sabit olduğunu göstermeli (p99−p1 < 1 ms). Aksi hâlde (B) yeniden önerilir.

Seçenekten bağımsız olarak hemen yapılacak metin düzeltmeleri:
- §0x22 ve §6'da "ekranda gösterim" yerine "çözücü çıktısı" yazılır.
- §4 geç girdi sınırı "host 5 sn sessizlik kapanışı" olarak düzeltilir.
- LOGGING.md'ye iki not eklenir: `latency_us` SCK kaymasını içermez; macOS `unacked_bytes` aslında bir `sbbytes` tahminidir.

**Kullanıcı 2026-10-03'te ilke olarak onayladı:** A/B, T-170 verisiyle seçilir ve sonuç kullanıcıya gösterilir; gecikme bütçeleri optik ölçümden (T-174) sonra konur. A/B seçimi veriye bağlı ve orkestratör önerir. Kullanıcıya sorulanlar:
1. Seçeneğin T-170 verisine göre seçilmesini ve o zamana kadar yalnızca metnin düzeltilmesini kabul ediyor musun?
2. **Gecikme bütçeleri (manifest §5 soru 14):** bütçelerin incelemenin önerdiği 45/70 ms ile şimdi değil, optik ölçümden (T-174) sonra belirlenmesine katılıyor musun? Bütçe kararı ertelendi ve henüz numarası yok.

## Veri (2026-10-04, T-172)

Kaynak: host `ev=latency` satırları, `pts_vs_deliv_ms_p1_50_99` (T-170), `~/Library/Logs/MateBridge/host*.log` 2026-10-03 akşam – 2026-10-04 öğlen, 8.157 pencere (10 sn), USB, Günlük/Oyun modları, 60 ve 120 Hz.

- **Pencere içi yayılım (p99 − p1):** p50 5,5 ms, p90 14,8 ms, p99 16,6 ms, en çok 21,6 ms. Yalnız pencerelerin %20'sinde < 1 ms.
- **Pencere p50'si iki kümede:** ~7–8 ms ve ~14–15 ms (yaklaşık bir ve iki 120 Hz periyodu). Sanal ekranın 60/120 Hz olmasıyla açıkça ayrışmıyor.
- **Sonuç:** kayma sabit değil; kararın kuralına göre (p99 − p1 < 1 ms koşulu tutmuyor) **(B) yeniden önerilir**. Kullanıcı seçimi bekleniyor.
- Metin düzeltmeleri (§0x22, §6, §4, LOGGING) seçenekten bağımsız olarak yapıldı.

## Sonuçlar
- **Kazanılan:** host ve tablet sayıları aynı başlangıçtan ölçülüyormuş gibi karşılaştırılmaz. Belgeler kodun gerçekten ölçtüğünü söyler. T-072'nin açık sorusu kapanır.
- **Kaybedilen:** (A)'da kayma tablet ekranında görünmez, analizde eklenir.
- **Kapıladığı kart:** T-172 (karar kaydı ve metin düzeltmesi). Veri T-170'den gelir. Kullanıcıya görünen etiket değişiklikleri T-168'de yapılır.
- **PROTOCOL.md:**
  - (A) seçilirse yalnızca metin değişir: §0x22, §6, §4 "Kabul edilen davranış". `gen.py --check` yeşil kalır.
  - (B) seçilirse §0x41 ve fixture'lar da değişir.
- **Tekrar düşünülür:** optik giriş→foton ölçümü (T-174) farklı bir kayma gösterirse, ya da bir macOS sürümü SCK PTS davranışını değiştirirse.
