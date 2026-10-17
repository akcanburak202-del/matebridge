---
id: T-350
title: İstemci — panelde "Performans artışı" anahtarı (T-319 fling boost, varsayılan kapalı)
status: done
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

1. `video/PerfBoost.kt`: `PerfBoostRules` (koşul sırası), `BoostAction`/`PulseScheduler`, `FlingBoost`, `PerfBoost` (yalnız koşullar tamamsa action ve zamanlayıcı oluşur).
2. `Settings.perfBoost` (varsayılan kapalı, USER_KEYS'te), `SettingsHost` + katalog: Görüntü bölümünde Toggle + açıklama; uzak oturumda gizli.
3. `MainActivity`: `syncPerfBoost()` render / onStop / uzak oturum / reset / anahtar değişiminde.
4. Testler: PerfBoostTest, SettingsCatalogTest.

## Handoff

- Dal task/T-350-perf-boost-toggle; commit SHA: son commit of the branch.
- Dosyalar: video/PerfBoost.kt (yeni), session/Settings.kt, settings/SettingsCatalog.kt, settings/SettingsViews.kt, MainActivity.kt, testler video/PerfBoostTest.kt + settings/SettingsCatalogTest.kt, docs/KNOBS.md, bu kart.
- Yerlesim: panelde (hem baglanti hem yan panel) "Goruntu" bolumunun sonunda, "Imlec"ten sonra: "Performans artisi: Acik/Kapali" dugmesi + altinda "Cozmeyi hizlandirir, pil tuketimi artabilir." Uzak oturumda ikisi de gizli.
- Mekanizma: yalniz T-319 FLING (abortAnimation + fling, 1 sn, kendi tek is parcacikli zamanlayicisi mb-boost). Dev dugmeleri, PerfLever, GpuKeep, iaware yok.
- Kosullar: ayar acik, render() akiyor (Connected + framesReceived>0 + renderer), started (onStop'ta durur), uzak oturum degil. Ayar degisince syncPerfBoost() aninda; yeniden baglanma yok. "Varsayilanlara don" kapatir (USER_KEYS).
- Kapaliyken: PerfBoost nesnesi yalniz bir alan; action/zamanlayici/thread ilk baslatmada olusur (test: offCreatesNothing).
- Gunluk: ev=perf_boost state=on reason=ok period_ms=1000 / state=off reason=setting|stream|background|remote|unsupported; pulse basina log yok.
- Varsayim: "on plan" = started (onStart..onStop), pencere odagi degil.
- check.sh: ilk tam kosuda android+protocol+kit OK; host asamasi eszamanli Gradle kosusuyla cakisti, --only host ayrica ALL OK.
- Tablette bakilacak: (1) Ayar kapaliyken logcat'te perf_boost yok, mb-boost thread yok. (2) Ac: akis surerken ev=perf_boost state=on reason=ok, DDR devfreq 1536 MHz, dec suresi ~15,6 -> ~12 ms (60 fps). (3) Kapat: state=off reason=setting, DDR duser, yeniden baglanma olmaz. (4) Arka plan: reason=background; Uzaktan baglan: dugme gorunmez. (5) Varsayilanlara don: kapanir.

## Open questions
