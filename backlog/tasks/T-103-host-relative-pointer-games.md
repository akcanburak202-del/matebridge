---
id: T-103
title: Mac — göreli fare (touchpad/fare) oyunlarda görünmez duvara takılıyor; gerçek imleç konumundan başla, ham delta gönder
status: todo
phase: 5
owner: mac-host-dev
depends_on: [T-034]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Input/
  - host-mac/Sources/MateBridgeHost/Input/
  - host-mac/Tests/
  - backlog/tasks/T-103-host-relative-pointer-games.md
---

## Amaç

Kullanıcı bulgusu (2026-10-01): Steam'deki The Witcher 2'de fare imleci görünmez bir sınıra takılıyor. Menüde de, karakteri kontrol ederken de "duvarları" geçemiyor. Bazen ikinci bir fare imleci görünüyor.

Orkestratör teşhisi (kod okuması):
- `InjectionPlanner` (`MateBridgeCore/Input/InjectionPlanner.swift` ~205–220) göreli hareketi (`POINTER_REL`) kendi tuttuğu `cursor` (son enjekte edilen konum) üzerinden hesaplıyor.
- `Geometry.moved` hedefi ekrana kırpıyor. `mouseEventDeltaX/Y` **kırpılmış** fark olarak yazılıyor (`CGEventPoster.swift` ~190).
- Oyunlar imleci kendileri ışınlıyor (`CGWarpMouseCursorPosition`) ya da imleci ayırıp (`CGAssociateMouseAndMouseCursorPosition(false)`) yalnızca delta okuyor. Host'un modeli gerçek imleçten kopuyor.
- Model ekran kenarına ulaşınca o yöndeki delta 0 oluyor: görünmez duvar.
- Her olayda imleç modelin konumuna konuyor, oyun ise merkeze çekiyor: ikinci imleç ya da titreme.
- Gerçek fare kenarda da delta bildirir.

## Kabul kriterleri

- [ ] Göreli harekette başlangıç noktası **gerçek imleç konumu**dur: her olayda `CGEvent(source: nil)?.location` ile ya da eşdeğer ucuz bir sorguyla okunur. Sorgu başarısızsa son bilinen konum kullanılır. Sorgu, olay yolunda maliyeti ölçülerek yapılır.
- [ ] `mouseEventDeltaX/Y`, istemciden gelen **ham** göreli değerdir (hız çarpanı sonrası, kırpılmamış). Kesirli kısım biriktirilerek tam sayıya çevrilir. Konum hâlâ ekrana kırpılır.
- [ ] Gerçek imleç sanal ekran dışındaysa (başka ekran) davranış Plan'da açıklanır; mevcut ekran sınırı kuralı korunur.
- [ ] Mutlak girdiler (kalem, dokunmatik `POINTER_ABS`) değişmez.
- [ ] Sürükleme (`dragged`), tıklama konumu (`mouseButton` gerçek imleç konumunda), çift tıklama sayacı tutarlı kalır. Girdi takılı kalmaz.
- [ ] Testler:
  - sahte "imleç ışınlandı" senaryosu (dış imleç merkeze dönüyor) → delta korunur, duvar yok;
  - kenarda ısrarlı hareket → delta sıfır değil, konum kırpık;
  - kesirli delta birikimi.
- [ ] `./scripts/check.sh` geçiyor. Gerçek olay gönderilmez (cihaz testi orkestratörde, kullanıcıyla Witcher 2 ve normal masaüstü kullanımı).

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff

