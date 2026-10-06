---
id: T-287
title: İstemci — uzun sessizlikte AAudio akışını duraklat (ses yokken 200 uyanma/s, %2)
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-282]
decisions: [0011]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/cpp/mbaudio.cpp
  - client-android/app/src/test/kotlin/dev/matebridge/client/audio/
  - backlog/tasks/T-287-audio-idle-pause.md
---

## Amaç

T-282 ölçümü (`docs/research/2026-10-07-perf-profile.md` §Sıcak noktalar 4): ses yokken `mb-audio` 200 uyanma/s ve %2,2 tek çekirdek; AAudio MMAP her 5 ms'de sessizlik yazıyor. Host T-279'dan beri 500 ms sessizlikten sonra paket göndermiyor. Günün çoğunda ses yok. Protokol değişmez.

## Kabul

1. İstemci `state=idle` (paket gelmiyor) **en az 10 sn** sürünce çıkış akışını duraklatır (`requestPause` ya da `requestStop`; hangisinin Huawei MMAP'ta temiz olduğunu dene, yaz). `mb-audio` döngüsü duraklamada bloklanır, dönmez.
2. İlk ses paketi gelince akış yeniden başlar. İlk paketin çalınma gecikmesi ölçülür ve loglanır (`ev=resume start_ms=…`). Hedef: duraklamasız ilk sese göre ≤ +50 ms. Rampa (`AudioRamp`) tıkırtıyı önler.
3. Duraklama ve devam döngüsü alt taşma ya da `idle_gaps` sayaçlarını yanlış artırmaz. Oturum kapanışı, arka plana geçiş ve `stream_id` değişimi duraklamış akışta da doğru çalışır.
4. Gerçek zamanlı geri çağırmada ayırma, kilit, log yok.
5. Cihaz (orkestratör, kullanıcı 1 dk): sessizken `mb-audio` uyanma ≤ 10/s. Kullanıcı sesli video başlatır, ilk ses gecikmesi logdan okunur. Kullanıcı "ilk ses kesik/geç" demezse kabul.

## Plan

## Handoff

## Open questions
