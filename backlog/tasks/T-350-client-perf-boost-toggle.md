---
id: T-350
title: İstemci — panelde "Performans artışı" anahtarı (T-319 fling boost, varsayılan kapalı)
status: todo
phase: 7
owner: android-client-dev
depends_on: [T-319]
decisions: [0039]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/main/res/
  - client-android/app/src/test/
  - docs/KNOBS.md
  - backlog/tasks/T-350-client-perf-boost-toggle.md
---

## Amaç

Karar 0039: T-319'un FLING yükseltmesi main'e kullanıcı ayarı olarak gelir. Kullanıcı açıp kapatarak kullanımdaki farkı hissedecek.

## Kapsam

1. Kaynak: `task/T-319-boost-arms` dalı (`video/Boost.kt`, `video/PerfLever.kt`, `MainActivity` / `VideoRenderer` bağlantıları). **Yalnız FLING mekanizmasını** al: görünmez `OverScroller.fling`, 1 sn periyot, kendi zamanlayıcısı. `PerfLever`'in diğer kolları, `GpuKeep`, `HuaweiBoost`, iaware kolları, `perf_lever`/`gpukeep_*`/`boost_period_ms` dev düğmeleri main'e **gelmez**. Dalı birleştirme, gerekeni sade bir biçimde yeniden yaz (birim testleriyle).
2. Ayar: `Settings`'e kalıcı bir boolean (`perf_boost`, varsayılan **false**). Normal panelin Görüntü (ya da en uygun) bölümüne bir Toggle: "Performans artışı: Açık/Kapalı", altında kısa açıklama: "Çözmeyi hızlandırır, pil tüketimi artabilir". `SettingsCatalog` ve onun testleri buna göre.
3. Çalışma koşulları: anahtar açık **ve** video akıyor **ve** uygulama ön planda **ve** oturum uzak oturum değil. Biri bozulunca runner durur (fling iptal, zamanlayıcı kapanır). Anahtar akış sırasında değişince yeniden bağlanmadan anında başlar/durur.
4. Kapalıyken sıfır iş: thread, executor, Choreographer geri çağrısı, görünüm yok. Bunu bir testle göster (runner hiç oluşmuyor).
5. Günlük: başlarken/dururken bir satır `ev=perf_boost on|off reason=...` (LOGGING.md biçimi; her pulse'ta log yok). `docs/KNOBS.md`'ye panel ayarı olarak kısa satır.
6. Tel biçimi ve host değişmez.

## Kabul

- Birim testleri: varsayılan kapalı; açık + koşullar → runner başlar; her koşul düşünce durur; anahtar kapatılınca durur; uzak oturumda başlamaz; kapalıyken scheduler'a hiç çağrı yok.
- `./scripts/check.sh` geçer. Cihaz testi orkestratörde (`ev=perf_boost`, DDR 1536 MHz `devfreq` ile).

## Plan

## Handoff

## Open questions
