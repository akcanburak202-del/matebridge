# Optimizasyon araştırması (T-298), 2026-10-08

Üç salt okuma ajanının tam özetleri (dosya:satır ve kaynak bağlantılarıyla):
- `docs/reviews/2026-10-08/agents/opt-a-host.md`: Mac yakalama → soket. HA1–HA13.
- `docs/reviews/2026-10-08/agents/opt-b-client.md`: tablet soket → ekran, CPU ve enerji. CB1–CB10.
- `docs/reviews/2026-10-08/agents/opt-c-e2e.md`: uçtan uca gecikme zinciri, ağ, rakipler. EN1–EN12.

Sadeleştirme bulgularıyla birleştirilmiş sıralama, partiler ve kullanıcı kararları: `docs/reviews/2026-10-08/simplification.md`.

## Hemen yapılabilir (en yüksek getiri/risk)

1. **CB1:** günlük APK debug derleme. Release benzeri bir derleme tahminen tek çekirdeğin %5–10'unu kazandırır. Karar gerekiyor.
2. **HA1 + HA2:** Keskin renk Metal geçişi; günlük kullanımın %87'si bu modda.
   - Geçiş bugün `hold`/`gate_wait` içinde görünmez kalıyor (~3 ms).
   - Tek dispatch'e birleştirilirse tahminen −1–1,5 ms.
3. **CB2:** codec boşken çıkış iş parçacığı park eder.
   - 10 fps'te tahminen −480 uyanma/s, ~%3 çekirdek.
   - Gecikme A/B'si zorunlu: T-286 `event` kolunda +1,5 ms görülmüştü.
4. **EN1, EN2/HA3, EN4, EN5:** dört kör segmentten ikisini kapatan yalnız log değişiklikleri, artı ısı ve pil telemetrisi.

## Ölçüm önce

CB4 (60 fps çözme süresi ve DVFS), CB5 (SurfaceFlinger birleştirme), CB6 (enerji), EN8 (DSCP), EN9 (kare boyutu tavanı), HA4 (LTR kurtarma), EN3 (tamponsuz dokunma), CB7 (QUICKACK), EN10 (USB 3), EN7 (optik, kullanıcıyla).

## Değmeyecekler (kanıtlı)

- **Host:** çıkış kopyaları kare başına 10–20 µs; iş parçacığı geçişleri `queue` 0,03 ms; SCK `queueDepth`; soket zaten ayarlı (NODELAY, LOWAT, tek kayıt uçuşta).
- **İstemci:** alma ve şifre çözme tabanda (`SO_RCVLOWAT` < %1).
- **Daha önce denenip kapanmış:** SurfaceControl, GL sunum yolu, ADPF.
- **Kullanıcı reddetti (10-06):** UDP+FEC; aux karesini ana kareden sonra kodlamak.
