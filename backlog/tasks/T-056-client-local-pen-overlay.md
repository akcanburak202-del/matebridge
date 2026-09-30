---
id: T-056
title: Tablet — yerel kalem göstergesi (imleç noktası + kısa sönümlenen iz) ile algılanan gecikmeyi azalt
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-052]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/overlay/
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/Settings.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-056-client-local-pen-overlay.md
---

## Amaç

PLAN Aşama 2/5: "Kalem gecikmesi … gerekirse tablette yerel imleç/hover noktası", "kalem için tahmini ink". Uçtan uca gecikme (kalem → Mac → kodlama → ağ → çözme → sunum) Performans modunda ~25–35 ms; kalem ucu ile çizgi arasında görünür boşluk bırakır. Tablet kalemin gerçek konumunu anında biliyor: bunu video üstünde yerel olarak göstermek algılanan gecikmeyi kapatır. Yeni bağımlılık yok (androidx.input tahmincisi karar gerektirir; bu kartta yok).

## Kabul kriterleri

- [ ] Video yüzeyinin üstünde saydam bir katman (ayrı `View` ya da `SurfaceView` Z-sıralı; donanım hızlandırmalı `Canvas`); kalem örnekleri (mevcut `PenTracker` akışından, unbuffered dispatch dahil) çizim iş parçacığında değil UI'da en az gecikmeyle işlenir; katman `postInvalidateOnAnimation` ile vsync'te çizilir.
- [ ] **Hover:** kalem menzildeyken küçük bir nokta (ör. 6 dp halka) kalemin konumunda. **Temas:** son ~40 ms'lik örneklerden kısa bir iz (çizgi), zamanla sönümlenir (ör. 60–80 ms'de kaybolur) — Mac'ten gelen gerçek çizgi o arada yetişir. Kalınlık basınçla orantılı, renk nötr yarı saydam (gerçek fırça rengini bilemeyiz).
- [ ] Silgi modunda (karar 0006) iz çizilmez, yalnızca halka.
- [ ] Ayar: bağlantı panelinde "Kalem izi: açık/kapalı" ve "Kalem noktası: açık/kapalı" (`Settings`, varsayılan: nokta açık, iz açık). İz süresi sabiti tek yerde.
- [ ] Performans: katman çizimi kare başına < 1 ms; video sunumunu ve T-052 zamanlamasını etkilemez (katman ayrı; video yüzeyi yeniden çizilmez).
- [ ] Koordinatlar: mevcut görünüm alanı/letterbox dönüşümüyle (T-050 `VideoLayout`) — iz video üstündeki doğru yere çizilir.
- [ ] Saf mantık (iz tamponu, sönümleme, zaman penceresi) birim testli. `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Host. Tahmin (ileriye çizim) — ileride, karar gerekebilir. Cihaz testi orkestratör + kullanıcı (kalemle).

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
