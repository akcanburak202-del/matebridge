---
id: T-375
title: Host — PAD_SWIPE (0x18) çöz, Control+ok sistem kısayolu olarak enjekte et
status: review
phase: 7
owner: mac-host-dev
depends_on: []
decisions: [0043, 0008, 0009]
files:
  - host-mac/Sources/MateBridgeCore/ProtocolConstants.swift
  - host-mac/Sources/MateBridgeCore/Message.swift
  - host-mac/Sources/MateBridgeCore/Messages/
  - host-mac/Sources/MateBridgeCore/Input/
  - host-mac/Sources/MateBridgeHost/Input/CGEventPoster.swift
  - host-mac/Sources/MateBridgeHost/Input/InputController.swift
  - host-mac/Sources/MateBridgeHost/Input/InjectTest.swift
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-375-host-pad-swipe.md
---

## Amaç

Karar 0043: tablet touchpad'inde üç parmak kaydırma Mac'te Mission Control / masaüstü geçişi yapsın. Sözleşme: PROTOCOL.md §4 `0x18 PAD_SWIPE` (alanlar, host kuralları, eşleme tablosu). Fixture'lar: `pad_swipe_up`, `pad_swipe_left`.

## Kabul

1. `PAD_SWIPE` kodlama/çözme, fixture testleri (iki yön de bayt bayt). Bilinmeyen `direction` ve `fingers != 3` yok sayılır (hata değil).
2. Durum makinesi: açık SCROLL/PINCH önce zorla bitirilir; `leftOwner != nil` iken yok sayılır; önceki PAD_SWIPE'tan sonraki 250 ms içinde yok sayılır. Basış tek parça (Control+ok bas, ok bırak, Control bırak) aynı `handle` çağrısının eylemleri olarak çıkar; `heldKeys` ve release-all durumu değişmez. Kullanıcının basılı tuttuğu tuşlar ve değiştiriciler (ör. Ctrl→Command) bu olayın bayraklarına karışmaz ve sonrasında yeniden doğru bayraklarla devam eder. Testler bunları kapsar.
3. CGEvent: ok tuşu sanal kodları (`kVK_UpArrow` 0x7E, `kVK_DownArrow` 0x7D, `kVK_LeftArrow` 0x7B, `kVK_RightArrow` 0x7C). Bayraklar açıkça `maskControl` (+ ok tuşu için `maskSecondaryFn | maskNumericPad`, gerçek klavyenin ürettiği gibi). Control değiştirici tuşu (`kVK_Control` 0x3B) için ayrı bas/bırak olayları da gönderilir; sistem kısayolları bazen yalnız bayrağa değil değiştirici durumuna bakar. Hangisinin gerektiğini bu Mac'te doğrulama yolu: aşağıdaki "Cihaz" notu.
4. Log: `ev=pad_swipe dir=up|down|left|right` (info) ve yok sayıldığında nedeni (`ignored=rate|drag|fingers|dir`). LOGGING.md güncellenir.
5. `InjectTest` gibi var olan bir enjeksiyon aracına `pad_swipe` adımı eklenirse orkestratör sonra elle deneyebilir; zorunlu değil.
6. `./scripts/check.sh` geçer (Android tarafı T-376'da; fixture testi Android'de o zamana kadar kırmızı olabilir, Handoff'ta belirt). **Çalışan host uygulamasına dokunma, Mac'te pencere açma, gerçek olay enjekte etme yok** (tablet Mac'in tek ekranı; Mission Control'ü açmak kullanıcının ekranını değiştirir). Cihaz denemesini orkestratör yapar.

## Plan

1. Core: `Messages/PadSwipe.swift` (`PadSwipe`, `PadSwipeDirection` with `arrowKeyCode`), `Message.padSwipe`, `MessageType.padSwipe = 0x18`. Bilinmeyen `direction`/`fingers` decode olur (hata degil), makine yok sayar.
2. State machine (`InputStateMachine+PadSwipe.swift`): sira dir -> fingers -> drag (`leftOwner`) -> rate (250 ms, onceki *uygulanan* swipe'tan); uygulananda acik scroll/pinch zorla biter, tek `InjectAction.padSwipe(dir)` cikar; hicbir sey tutulmaz. Sonuclar `PadSwipeOutcome` olarak pipeline'dan log icin cekilir.
3. Planner: tek `apply` icinde Control down, ok down, ok up, Control up. Bayraklar acik: Control (+sol yan biti), ok icin `secondaryFn|numericPad`; kullanicinin tuttugu Command/Shift/Option karismaz, Control-up olayi kalan tutulanlarin bayragini tasir. Kullanici zaten Control tutuyorsa (Meta eslemesi) ek Control olayi yok. Kullanici ayni oku tutuyorsa swipe dusurulur. Kapi: `openGate`.
4. Host: `InputController` log (`pad_swipe dir=` / `ignored=`), `deliver` yonlendirmesi; `InjectTest --pad-swipe`.
5. Test: `PadSwipeTests.swift` + fixture sozlugu + model degismezleri.

## Handoff

- Commit: SHA_PLACEHOLDER (branch `task/T-375-host-pad-swipe`, main 2fc62354 uzerine).
- `./scripts/check.sh`: host-mac build + test GECER (1322 test, pad_swipe_up/left fixture'lari bayt bayt dahil). Kirmizi olan tek sey `gradle (client-android)`: `FixtureTest.everyFixtureFileHasATestCase` Android'de pad_swipe fixture'lari icin test case yok (beklenen, T-376). Baska Android hatasi yok.
- Dokunulan dosyalar: `Sources/MateBridgeCore/{ProtocolConstants,Message}.swift`, yeni `Messages/PadSwipe.swift`, `Input/{InputStateMachine,InputStateMachine+PadSwipe,InjectAction,InjectionPlanner,InputPipeline,KeyMap}.swift`, `Sources/MateBridgeHost/Input/{InputController,InjectTest}.swift`, `Tests/MateBridgeCoreTests/{FixtureTests,Input/PadSwipeTests,Input/InjectionPlannerTests,Input/InputTestSupport}.swift`, `docs/LOGGING.md`.
- Kapsam disi tek dokunus (zorunlu): `Sources/MateBridgeCore/Session/SessionMachine.swift` icindeki kapsamli `switch`'e `.padSwipe` eklendi (`.pen, .key, ..., .pinch, .padSwipe, ...` satirina bir kelime; aktif oturumda `deliver`, onaylanmamis oturumda yok sayilir). Kart `files:` listesinde yoktu ama olmadan derlenmez. `SessionServer.swift`'e dokunulmadi: `routeCursor`'daki imlec bildirimi swipe icin gerekmiyor (imleci oynatmaz).
- Varsayimlar: (1) Control sol Control (`kVK_Control 0x3B`) + sol yan biti (0x1) olarak basilir. (2) Ok olaylari `maskControl | maskSecondaryFn | maskNumericPad` tasir, Caps Lock bayragi yok. (3) Hiz siniri sadece *uygulanan* swipe'tan sayilir; yok sayilanlar (dir/fingers/drag/rate) sayaci ilerletmez. (4) Zaman geri giderse (now < onceki) hiz siniri kilitlenmez. (5) Planner'da kapi kapaliysa (izin/ekran yok/owed) swipe sessizce dusurulur; log `dir=` yine yazilir (makine karari). (6) Tek parca dizi planner'in golge durumuna girmez; yarim kalan teslimde mevcut `OwedRelease` (key/modifier slotlari) tekrar dener. (7) Test modeli (`MacEventModel`) "bayraklar tutulan degistiricilerle birebir" degismezi swipe ok/Control olaylari icin gevsetildi.
- Gercek donanimda dogrulanmasi gereken (orkestrator, tablet tek ekran): (a) sentetik Control+ok'un Mission Control / masaustu gecisini tetikleyip tetiklemedigi, `secondaryFn|numericPad` bayraklarinin gerekip gerekmedigi, ayri Control `flagsChanged` cifti gerekli mi (gerekmezse sadelestirilebilir); (b) Command tutarken swipe sonrasi Command'in yerinde kaldigi; (c) `InjectTest --pad-swipe up|down|left|right` elle denenebilir (UYARI: gercek olay enjekte eder, Mission Control acar); (d) log satiri `ev=pad_swipe dir=...`. Hicbiri bu kartta calistirilmadi (pencere/olay/calisan uygulama yok).

## Open questions

- Kart `files:` listesi eksikti: `SessionMachine.swift` (bir kelimelik switch durumu) gerekti, yukarida belirtildi. `Messages/` dizini yoktu (mesajlar `Messages.swift` icinde), yeni dosya `Messages/PadSwipe.swift` olarak acildi; `Messages.swift` degismedi.
- Kullanici sistem ayarlarinda Mission Control kisayollarini kapatmissa hareket hicbir sey yapmaz (karar 0043 sonuclari); host bunu algilamaz.
