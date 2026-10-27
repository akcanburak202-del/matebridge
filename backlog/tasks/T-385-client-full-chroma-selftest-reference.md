---
id: T-385
title: İstemci — tam renk öz testi GPU ham okumasını gömülü sabit referansla karşılaştırsın (MTK CPU okuması güvenilmez)
status: todo
phase: 7
owner: android-client-dev
depends_on: [T-384]
decisions: [0034]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/FullChromaSelfTest.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/FullChromaSelfTestClip.kt
  - client-android/app/src/main/cpp/mbfullchroma.cpp
  - client-android/app/src/test/
  - backlog/tasks/T-385-client-full-chroma-selftest-reference.md
---

## Amaç

T-384 (Handoff'taki tablo): Xiaomi/MTK'de `__samplerExternal2DY2YEXT` ham GPU okuması bit-tam, ama öz test GPU'yu MTK'nin satıcı tamponunun (`ahb_fmt=0x7f000010`) **CPU okumasıyla** karşılaştırıyor; o CPU okuması anlamsız → `raw_samples_differ` → "Tam renk (Bu cihazda yok)". Öz test, GPU okumasını gömülü klibin bilinen Y/Cb/Cr değerleriyle karşılaştırmalı (T-384 öneri a: üretimdeki aynı tamponu sınar).

## Kabul

1. Gömülü 256×144 klibin bit-tam çözülmüş Y (256×144), Cb, Cr (128×72) düzlemleri sabit olarak gömülür (HEVC çözümü standartta bit-tamdır). Üretim yöntemi Plan'da: ör. Mac'te `ffmpeg` yoksa T-384 probe'unun yazılım çözücü (`c2.android.hevc.decoder`) çıktısı; boyut makul tutulur (ör. sıkıştırılmış/base64, ya da yalnız düzlemlerin bir özeti + örnekleme değil, **tam** karşılaştırma tercih). Değerler `FullChromaSelfTestClip`'in yanında, klip değişirse birlikte değişeceği açıkça yazılır.
2. Öz test: GPU ham okuması (Y tam çözünürlük, Cb/Cr yarı) bu referansla karşılaştırılır; `exact=1` yalnız tüm örnekler eşitse. CPU `Image` okuması artık karar vermez (isteğe bağlı bilgi olarak loglanabilir: `cpu_mis=`). İkinci çözücü kontrolü ve diğer kurallar (Inconclusive/Fail ayrımı, build anahtarı) değişmez. Okuyucu biçimi, üretim yoluna yakın olması için Plan'da gerekçelendirilir (CPU_READ gerekmiyorsa PRIVATE + GPU_SAMPLED).
3. Log satırı `full_chroma_selftest_detail raw_compare ...` alanları korunur (+ `ref=embedded`). LOGGING.md değişikliği gerekirse Open questions'a yaz (dosya listesinde yok).
4. Birim testi: referans düzlem boyutları/bütünlüğü (ör. sabit bir özet), karşılaştırma mantığı saf kısımlarda.
5. Cihaz: bu kartta ajan cihaza kurmaz; orkestratör Xiaomi ve MatePad'de test eder (MatePad'de de geçmeli — orada GPU=CPU=referans bekleniyor).
6. `./scripts/check.sh` geçer.

## Plan

## Handoff

## Open questions
