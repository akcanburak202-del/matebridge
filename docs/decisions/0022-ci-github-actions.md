# 0022 — Birleştirme kapısı olarak GitHub Actions CI

- **Durum:** kabul (2026-10-03)
- **Tarih:** 2026-10-03

## Bağlam
Kaynak: dış mimari incelemesi 2026-10-03 (HEAD a30c769), M07 ve P4. Doğrulama: `docs/reviews/2026-10-03/verify-H-hygiene.md` (P4, M07, CI-1, ek 1–2).

Bugünkü tek kapı, sahibin Mac'inde elle çalıştırılan `./scripts/check.sh`. Bir birleştirme için çalıştırıldığı hiçbir yere kaydedilmiyor. `.github/workflows/` dizini yok. CI bilerek ertelendi (T-001 satır 20, PLAN.md:48 "atılan / ertelenen"), ama "derlenecek kod olunca" yazılacak kart hiç açılmadı. Bugün bu kod var: host Core testleri ve istemci JVM testleri.

Ek sorunlar:
- **`check.sh` pratikte yalnızca Mac'te çalışıyor ve bölünemiyor.** Android Studio JBR ile SDK yolları sabit yazılmış (`check.sh:24-26`), CryptoKit betiğini çalıştırıyor (`:39-42`) ve bütün probe'ları derliyor (`:16`, `:27`).
- **`gen.py` her çağrıda yazıyor.** `--check` verilmeyen her çağrı golden vektörleri yeniden yazıyor (`protocol/fixtures/gen.py:460-476`). `--help` ya da bir yazım hatası bile buna yeter.
- **Kapsam sınırı.** Bu kararın kapıladığı yeni testler (H02/M02/M03 deterministik testleri) CI'da da koşar. Donanım yolları ise CI'da çalışamaz.

Depo **public** (docs/WORKFLOW.md:54). GitHub'ın barındırdığı macOS ve Linux makinelerinin dakikaları public depolarda ücretsiz, yani maliyet sorunu yok.

## Seçenekler
- **(a) Yalnızca yerel `check.sh` kalsın.** Bağımlılık yok, ama kapı kayıtsız ve tekrarlanamaz.
- **(b) GitHub'ın barındırdığı makinelerde, bileşenlere bölünmüş `check.sh` (önerilen).** Ücretsiz, her commit'te görünür ve sahibin Mac'ini meşgul etmez. Barındırılan macOS ve Xcode sürümü Mac mini'den (macOS 27) farklı olabilir.
- **(c) Mac mini'de kendi kendine barındırılan runner.** Gerçek donanıma en yakın seçenek. Ama günlük kullanılan makinede dış kod çalıştırır; public depoda bu güvenlik riski demek. Bakım da gerektirir.

## Karar
Seçilen: **(b)**. `main` ve `task/*` dallarına her push'ta iki iş çalışır:
- **macOS:** `check.sh --only host` ve `--only protocol`. Bu, `swift build` + `swift test`, kripto vektör farkı ve fixture denetimini kapsar.
- **Linux:** `check.sh --only android` ve `--only protocol`. Android tarafı `assembleDebug testDebugUnitTest` çalıştırır; JDK, SDK, NDK ve CMake sdkmanager ile kurulur.

Kurallar:
- Probe'lar CI'a dahil değil.
- Yalnızca birinci taraf `actions/*` ve `actions/setup-java` kullanılır. Üçüncü taraf Android action'ı kullanılmaz. Bu karar, AGENTS.md'nin bağımlılık kuralı için gereken kayıttır.
- CI ilk hafta yalnızca bilgi verir; zamanlamaya duyarlı testlerin oynaklığı (ör. KeychainAsyncTests) burada görülür. Sonra birleştirme için zorunlu olur.
- Yerel `check.sh` teslimden önceki asıl kapı olarak kalır.
- `gen.py` yalnızca açık bir `--write` ile yazar ve bilinmeyen argümanda hata verir.

**CI'ın kapsamadığı yollar** (yeşil CI bunları doğrulamaz; aygıt testlerinde kalır):
- ScreenCaptureKit ile yakalama ve VideoToolbox ile kodlama;
- `CGVirtualDisplay` (sanal ekran);
- MediaCodec ile çözme ve AAudio ile ses çalma;
- TCC izinleri (Ekran Kaydı, Erişilebilirlik) ve CGEvent gönderimi (kalem, klavye, fare);
- probe'lar (`probes/*`; yalnızca yerel `check.sh` derler);
- cihaz üstü ve instrumentation testleri, emülatör.

Uygulama (T-149): `.github/workflows/check.yml`. `changes` işi yalnızca git ile yol filtresi uygular. macOS işi `host-mac/**`, `protocol/**`, `.github/workflows/**`, `scripts/check.sh` ya da `docs/PROTOCOL.md` değişince çalışır. Linux işi her push'ta çalışır. CryptoKit vektör farkı yalnızca macOS'ta çalışır; Linux `--only protocol` bunu açık bir `SKIP (needs macOS)` satırıyla atlar.

**Kullanıcı 2026-10-03'te onayladı:** ilk hafta yalnız bilgi, sonra zorunlu. Sorulan (manifest §5 soru 4): GitHub Actions kullanılsın mı? Depo public olduğu için makine dakikaları ücretsiz. İlk hafta yalnızca bilgi versin, sonra zorunlu olsun mu?

## Sonuçlar
- **Kazanılan:**
  - Her commit için tekrarlanabilir ve görünür bir kapı.
  - Eski fixture'lar ve kripto vektör kayması birleştirmeden önce yakalanır.
  - Sahibin Mac'i boşta kalır.
- **Kaybedilen:**
  - İş başına birkaç dakika bekleme (hedef: önbellekle iş başına 15 dk'nın altı).
  - Barındırılan ortamdaki sürüm farkları ara sıra uyarlama gerektirebilir.
- **Kapıladığı kart:** T-149 (`.github/workflows/check.yml`, `check.sh --only`, güvenli `gen.py` CLI'ı, WORKFLOW.md'ye bir satır).
- **Mevcut kararlar:** değişmez. PLAN.md:48'deki "CI ertelendi" notu güncellenir.
- **PROTOCOL.md:** değişmez.
- **Tekrar düşünülür:**
  - Depo private olursa (o zaman macOS dakikaları ücretli olur);
  - barındırılan macOS host'u derleyemezse;
  - cihaz üstü test otomasyonu (instrumentation) istenirse.
