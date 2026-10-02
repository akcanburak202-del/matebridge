---
id: T-141
title: Durgun ekranda istemciyi uyutmak (vsync döngüleri, boş iş) ve normal kullanımda log azaltmak
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-140]
decisions: []
files:
  - client-android/app/src/
  - backlog/tasks/T-141-idle-power.md
---

## Amaç

Faz 0 ölçümü (docs/NOTES.md 2026-10-02 ~21:30 ve ~22:45): Mac ekranı durgunken (saniyede 0 kare) istemci tek çekirdeğin ~%20'sini yiyor, toplam sistem ~%70–80/800. Ana iş parçacığı oturum boyunca her vsync'te uyanıyor (`MainActivity.vsyncCallback`, GL yolunda `GlPresenter.frameCallback`). Bir anlık ölçümde de `HeapTaskDaemon` (GC) ~%10, `RenderThread` ~%5, `mb-ctl-read` ~%4,7 görüldü. Ayrıca `MB/decoder` ve `MB/render` saniyede birer uzun istatistik satırı yazıyor (logd ~%3). Hedef: durgun ekranda pil ve CPU tasarrufu, akış kalitesi ve gecikmesi değişmeden. Kullanıcı Faz 1'i onayladı (2026-10-02).

## Kapsam dışı

- Protokol, host, girdi yolu değişikliği. Yenileme hızı (T-140 olumsuz), oyun modu çözünürlüğü (ayrı konuşulacak).
- Ses yolu davranışı (AAudio/jitter); yalnız ölçülür, değiştirilmez.

## Kabul kriterleri

- [ ] **Önce döküm:** kod okuyarak durgun ekranda (oturum açık, kare gelmiyor) periyodik çalışan her şeyin listesi: Choreographer geri çağrıları, `ui.post/postDelayed` tikleri, iş parçacığı döngüleri ve yoklamalar, her tikte bellek ayıran yerler (GC kaynağı), View geçersiz kılmaları (`RenderThread`: istatistik kaplaması, `statsView.text` vb.). Plan bölümüne tablo olarak: ne, sıklık, durgunken gerekli mi.
- [ ] **Vsync döngüleri boşta durur:** son karenin üzerinden ~250–500 ms (gerekçeli sabit) geçince `vsyncCallback` ve GL `frameCallback` artık yeniden kaydolmaz. İlk yeni kare geldiğinde anında yeniden başlar. Yeniden başlamada vsync saati, faz kilidi ve `DisplayRateDebouncer` doğru tohumlanır. Durgunluk sonrası ilk kare bekletilmez, geç sunulmaz ve yanlış yuvaya düşmez: ilk kare gelir gelmez çizilebilir olmalı (gerekirse vsync tahmini yerine hemen sunum). Panel hızı ölçümü durgunken son değeri korur. DISPLAY_RATE durgunluk yüzünden yanlış değer göndermez (ör. hiç vsync yok diye 0 ya da 60).
- [ ] **Boş iş azaltılır:** dökümde "durgunken gereksiz" çıkan periyodik işler ya durgunken durur ya da seyrekleşir. Tik başına bellek ayırma (string birleştirme, liste/dizi kopyası, boxing) sıcak yollarda kaldırılır, ama yalnız ölçülebilir olanlar. Ses ve girdi iş parçacıklarına dokunulmaz, girdi ve ses gecikmesi değişmez.
- [ ] **Log:** `MB/decoder ev=stats` ve `MB/render ev=stats/present` varsayılanda 10 s'de bir (pencere 10 s, değerler o pencerenin özeti; biçim aynı, `interval_ms` doğru). `--ez stats_1s true` açılış parametresi eski 1 s davranışını geri getirir (teşhis için). Kare akmıyorken (pencerede 0 kare) bu satırlar yazılmaz, yerine yalnız durum değişiminde `render ev=idle state=on|off` yazılır. Olay satırları (`display_rate`, `keyframe`, hatalar vb.) değişmez. `docs/LOGGING.md` gerekiyorsa güncellenir (dosya kartın `files:` listesinde değil: gerekiyorsa *Açık sorular*a yaz, orkestratör yapar).
- [ ] Host'a giden istatistik mesajları (`controller.trySend(StatsFormat...)`) ve bunlara bağlı host davranışı (ör. gecikme/bitrate uyarlaması) değişmez. Hâlâ 1 s'de bir gidiyorlarsa öyle kalır.
- [ ] JVM testleri: boşta durma/yeniden başlama kararı (saf sınıf, saat enjekte), yeniden başlamada ilk karenin hemen sunulabilir olması, log penceresi toplama (10 s ve 1 s).
- [ ] `./scripts/check.sh` geçiyor.

## Ölçüm (orkestratör, cihazda; ajan yapmaz)

Aynı koşulda önce ve sonra: durgun ekran 2 dk (istemci CPU, iş parçacığı dökümü, panel Hz), ardından hareketli içerik ve oyun (fps, `skip_pct`, `latency_us`, `shown_p95`, durgunluktan sonraki ilk karenin gecikmesi). Kullanıcı takılma hissetmemeli.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
