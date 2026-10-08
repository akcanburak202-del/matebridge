---
id: T-323
title: Host — "girdi enjekte edildi → ilk değişen kare" süresi (EN2/HA3), SCK dirty rect ile; yalnız log
status: review
phase: 7
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/ScreenCapture.swift
  - host-mac/Sources/MateBridgeHost/Input/
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Tests/MateBridgeCoreTests/
  - backlog/tasks/T-323-host-inject-to-frame.md
---

## Amaç

T-298 `docs/reviews/2026-10-08/agents/opt-c-e2e.md` EN2 ve `opt-a-host.md` HA3. Gecikme zincirinde "CGEvent gönderildi → uygulama çizdi → WindowServer → SCK geri çağrısı" segmenti kör, ve muhtemelen host'taki en büyük kalem.

## Kabul

1. Her basma kenarında (tuş basma, düğme basma, kalem teması başlangıcı) host monoton saatiyle damga alınır.
2. Damgadan sonraki ilk `complete` SCK geri çağrısında, boş olmayan dirty rect varsa gecikme ölçülür. İkinci aşama (varsa): enjeksiyon noktasını içeren ilk dirty rect.
3. Yeni olay `video ev=inject_to_frame n= p50_ms= p95_ms= max_ms=` 10 sn'de bir, yalnız örnek varken yazılır. Koordinat ya da içerik yok.
4. Ölçüm, ekran başka nedenle de değişiyorsa yanlış eşleşebilir. Bunun için "son 500 ms durağan pencere" koşulu ya da ayrı bir `noisy` sayacı (yaklaşık bir ölçü olduğu Handoff'ta belirtilir).
5. Saf eşleştirme mantığı Core'da test edilir. Host yolu derleme ve cihazla doğrulanır.
6. Önerilen LOGGING metni Handoff'a.

## Plan

Core: `InjectToFrameMatcher` (saf eşleştirme) + `InjectToFrameMeter` (kilitli, 10 sn rapor) + `MacEvent.isPressEdge`. Host: `InjectToFrameProbe` (Input/), InputController `flush` içinde post edilen basma kenarında damga, ScreenCapture `complete` karede dirty-rect varlığıyla besler. Log `video ev=inject_to_frame`.

## Handoff

- Commit: `git log task/T-323-inject-to-frame -1` (T-323: inject-to-frame latency log).
- Dosyalar: `Core/Video/InjectToFrame.swift` (yeni), `Tests/.../InjectToFrameTests.swift` (yeni, 9 test), `Host/Input/InjectToFrameProbe.swift` (yeni), `Host/Input/InputController.swift` (2 küçük ekleme: flush'ta damga, sessionStarted'da oturum no), `Host/Video/ScreenCapture.swift` (1 blok), bu kart.
- Davranış: basma kenarı = keyDown/modifierDown (autorepeat hariç), fare düğmesi down, kalem down; CGEvent post'undan hemen sonra host saatiyle damgalanır (post başarısızsa damga yok). Örnek = ilk `complete` + boş olmayan dirty-rect karesinin SCK callback varış zamanı - damga. Dirty-rect listesi ekte yoksa "kirli" sayılır. Durağanlık: damgadan önceki 500 ms'de kirli kare varsa ölçülmez, `noisy` sayılır; 1 sn'de kare gelmezse `timeout`. Bekleyen ölçüm varken gelen ikinci basma aynı kareyle cevaplanır (ayrı örnek yok).
- İkinci aşama (enjeksiyon noktasını içeren dirty rect) YAPILMADI: dirtyRects koordinat uzayı (piksel/nokta, Y yönü) cihazda doğrulanmadan eşlemek yanlış sonuç verirdi. Gerekirse ayrı kart.
- 10 sn raporu: `StreamCoordinator` `files:` dışında olduğu için log probe içinden yazılır; ScreenCapture her `complete` karede ve basma sonrası tetikler. Yalnız örnek varken yazılır; oturum bitince son pencere yazılmayabilir.
- Yaklaşıklık: durağanlıktan hemen sonra gelen alakasız bir ekran değişimi yanlış eşleşebilir; `noisy` azaltır, tam elemez.
- check.sh: ALL OK (1034 test).
- Cihazla doğrulanacak: (1) log satırı çıkıyor mu (host yeniden başlatılıp tabletten tuş/kalem basılınca), (2) `dirtyRects` ekte geliyor mu (gelmiyorsa her kare kirli sayılır, noisy artar), (3) değerler makul mü.
- Önerilen LOGGING metni: `- V video ev=inject_to_frame n=<n> p50_ms=<f> p95_ms=<f> max_ms=<f> noisy=<n> timeout=<n>` (T-323): 10 sn'de bir, yalnız örnek varken. Örnek = bir basma kenarının (tuş/düğme/kalem teması) host'ta post edilmesinden sonra ilk değişen (boş olmayan dirty rect) `complete` SCK karesinin callback'ine kadar geçen süre. `noisy` = ekran son 500 ms içinde zaten değiştiği için ölçülmeyen basmalar, `timeout` = 1 sn içinde kare gelmeyen basmalar. Koordinat/içerik yok. Yaklaşık bir ölçüdür.

## Open questions
