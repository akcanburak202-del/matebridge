---
id: T-140
title: Deney — dokunmadan 120 Hz için "animasyon oyu" (açılış parametresiyle, varsayılan kapalı)
status: todo
phase: 5
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/RefreshVote.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/RefreshVoteTest.kt
  - backlog/tasks/T-140-refresh-vote-experiment.md
---

## Amaç

Huawei AGPService (FrameRateManager) paketimizi `60120` stratejisine koyuyor: dokunma ya da animasyon oyu yokken panel 60 Hz, `sfFps 120` olsa bile (docs/NOTES.md 2026-10-02 ~21:30). Kullanıcı oyunda (klavye/gamepad, ekrana dokunmadan) 120 Hz istiyor. Tek uygulama-erişimli aday: normal animasyonların gönderdiği "animasyon oyu" (`android.view.DynamicRefreshRateHelper`, hwEmui.jar, AGP işlem 107, izinsiz; 0,5–3 s'de sönüyor). Bu kart **yalnız deney**: akış hızlıyken bu oyu canlı tutmanın paneli boşta 120'de tutup tutmadığını cihazda ölçmek için açılış parametreli bir anahtar. Kullanıcı deneye onay verdi (2026-10-02).

## Kapsam dışı

- Kalıcı ayar, panel/arayüz seçeneği, protokol değişikliği, host değişikliği.
- Varsayılan davranış değişikliği: parametre verilmezse kod yolu hiç çalışmaz (View eklenmez, animatör yok, yansıma yok).
- Boşta vsync uyanmasını durdurma, log azaltma (Faz 1, ayrı kart).

## Kabul kriterleri

- [ ] Açılış parametresi `--ei rvote N`: `0` kapalı (varsayılan), `1` animasyon yolu, `2` yansıma yolu, `3` ikisi birden.
  - **Animasyon yolu (1):** pencere içinde, SurfaceView'ların üstünde 1×1 px View. Gerçekten çizilsin diye `alpha=0` ya da `INVISIBLE` olmasın: neredeyse saydam renk (ör. `0x01000000`), köşede, dokunma almaz (tıklanamaz, odaklanamaz, dokunma olayını tüketmez). Oy açıkken her karede `invalidate()` çağıran sonsuz `ValueAnimator` (`repeatCount=INFINITE`). Oy kapanınca animatör durur, View yerinde kalabilir ama çizilmez.
  - **Yansıma yolu (2):** `android.view.DynamicRefreshRateHelper.getInstance()` + `setRefreshRate(String keyId, DynamicRefreshRateHelper$FrameRange(120,120,120,priority))`. Ctor `(int,int,int,int)` ya da `(int,int,int,int,boolean)`, hangisi varsa. Oy açıkken < 500 ms aralıkla yinelenir. Kapanırken eşdeğer "bırak" çağrısı varsa çağrılır (bulunamazsa yalnız yineleme durur). Sınıf ya da metot yoksa, ya da hiddenapi reddederse bir kez `rvote_reflect_failed err=<sınıf adı>` loglanır, sonra yol kendini kapatır. Çökme olmaz.
- [ ] **Kapı:** `--ei rvote_min_fps F` (varsayılan 70; `0` = akış sürdükçe hep açık). Oy yalnız oturum akarken ve son ~1 s'de alınan video karesi ≥ F iken açık. Altına düşünce ~1 s histerezisle kapanır. Arka plan, bağlantı kopması, oturum sonu → anında kapalı, animatör/zamanlayıcı kalmaz.
- [ ] Kapı mantığı saf bir sınıfta (`RefreshVote` ya da benzeri; saat enjekte edilebilir), JVM birim testleriyle: eşik, histerezis, oturum sonu kapanışı, `F=0`.
- [ ] Log (`MB/render`, `docs/LOGGING.md` biçimi): açılışta `rvote_config mode= min_fps=`, durum değişiminde `rvote state=on|off reason=fps|session|background`, yansıma sonucu bir kez `rvote_reflect ok=1 ctor=4|5` ya da `rvote_reflect_failed`. Saniyede bir log yok.
- [ ] Girdi yolu etkilenmez: View dokunma/kalem/hover olaylarını almaz. Mevcut girdi testleri geçer.
- [ ] `./scripts/check.sh` geçiyor.

## Ölçüm (orkestratör, cihazda; ajan yapmaz)

Panel hızı: `/sys/class/graphics/fb0/lcd_fps_scence` (`current_fps`) ve `AGPService ... JudgeFinalLcdFps ... animFps`. Başarı ölçütü: oyun modunda, dokunmasız anlarda panel 120. Ayrıca istemci ana iş parçacığı CPU maliyeti ölçülür (animasyon yolu her karede görünüm çizer).

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
