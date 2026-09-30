---
id: T-035
title: Tablet — imleç hızı (daha yavaş varsayılan + canlı ayar kısayolu), Android'e dönüş kısayolu
status: done
phase: 3
owner: android-client-dev
depends_on: [T-033, T-034]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/Settings.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-035-client-pointer-speed-exit.md
---

## Amaç

Faz 3 cihaz testi (kullanıcı, 2026-09-30): klavye, touchpad ve fare çalışıyor, ama (1) touchpad **ve** Bluetooth fare ile imleç "biraz fazla hızlı, fazla hassas"; (2) MateBridge'den Android'e **dönemiyor**. T-033'ten önce klavyedeki Esc Android'e BACK olarak gidip uygulamadan çıkarıyordu; artık Esc Mac'e gidiyor (doğru), touchpad/fare de pointer capture altında Android imlecini kullanamıyor. Yerel bir çıkış yolu gerekiyor.

## Kabul kriterleri

- [ ] **Daha yavaş varsayılanlar:** touchpad `SCREEN_SPAN` 1,2 → **0,8**, `GAIN_MAX` 2,6 → **1,8** (`GAIN_MIN` 0,8 → **0,6**); fare kazancı 1,0 → **0,6**. (Başlangıç noktası; kullanıcı canlı ayarla düzeltecek.)
- [ ] **Hız çarpanları kalıcı ayar:** `Settings`'te touchpad ve fare için ayrı hız çarpanı (varsayılan 1,0; aralık 0,25–3,0), `RelPointerTracker`'a uygulanır. Kaydırma hızı etkilenmez.
- [ ] **Canlı ayar kısayolları** (oturum girdi kabul ederken, yalnızca fiziksel klavye; T-033'teki Ctrl+Shift+F3 ile aynı yerel kısayol mekanizması — F tuşunun DOWN/UP'u Mac'e gitmez, yinelenen DOWN'lar yerel kalır):
  - `Ctrl+Shift+F1`: imleç hızı ×0,85; `Ctrl+Shift+F2`: ×1,15. Son kullanılan cihaz türünün (touchpad ya da fare) çarpanını değiştirir; hiç kullanılmadıysa touchpad'inkini. Kısa bir Toast: "Touchpad hızı: 0,85" gibi. Kalıcı olarak kaydedilir.
- [ ] **Android'e dönüş:** `Ctrl+Shift+Esc` → uygulama arka plana gider (`moveTaskToBack(true)`), Esc'in DOWN/UP'u Mac'e gitmez. Arka plana geçiş mevcut `RELEASE_ALL(BACKGROUND)` yolundan geçer (Ctrl/Shift Mac'te basılı kalmaz). Pointer capture uygulama arka plandayken zaten bırakılır; bunu doğrula.
- [ ] Bağlantı panelindeki (oturum yokken görünen) yardım/metinde üç kısayol tek satırla listelenir (mevcut koddan eklenen kontrol gibi, layout dosyası gerekmeden).
- [ ] Birim testleri: çarpan sınırları ve kalıcılık, F1/F2'nin Mac'e gitmemesi ve yinelenen DOWN'ların yerel kalması, Ctrl+Shift+Esc'in yerel kalması, varsayılan sabitler. `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Tel biçimi değişmez. Tam ayar ekranı Faz 4.
- Cihaz testi orkestratörde.

## Plan

1. `PadTuning`: SCREEN_SPAN 0,8; GAIN_MIN 0,6; GAIN_MAX 1,8; MOUSE_GAIN 0,6.
2. `Settings`: `touchpadSpeed()/mouseSpeed()` (+setters, clamp 0,25-3,0, default 1,0, bozuk deger -> 1,0), `adjustSpeed(mouse, factor)`, Turkce etiket bicimleyici.
3. `RelPointerTracker`: `padSpeed`/`mouseSpeed` carpani yalnizca imlec hareketine (scroll degil); `lastWasMouse` (son kullanilan cihaz).
4. `KeyTracker`: `KeyDecision.local` (enum LocalAction: STATS, SPEED_DOWN, SPEED_UP, BACKGROUND); T-033 localOnly mekanizmasi Ctrl+Shift+F1/F2/F3/Esc icin genellestirilir. Esc'in BACK kontrolu yerel kontrolden sonraya alinir (Esc BACK koduyla da gelebilir).
   Not: mevcut `KEYCODE_F3 = 134` hatali (Android'de F3 = 133, 134 = F4); F1=131, F2=132, F3=133 olarak duzeltilir, testler guncellenir (scan kodu 59/60/61 de kabul).
5. `InputCapture`: hiz carpanlarini tracker'a iletir; `lastPointerIsMouse`.
6. `MainActivity`: local action isleme (hiz: Settings + Toast; BACKGROUND: moveTaskToBack(true) -> onPause -> RELEASE_ALL(BACKGROUND)); baslangicta ayarlari uygular; panele tek satir kisayol metni.
7. Testler: Settings siniri/kalicilik, F1/F2/Esc yerel + tekrar eden DOWN yerel, varsayilan sabitler, hiz carpaninin scroll'u etkilememesi.


## Handoff

- **Commit:** dalın son commit'i (`git log task/T-035-client-pointer-speed-exit`).
- **Dokunulan dosyalar:** input/KeyTracker.kt, InputCapture.kt, RelPointerTracker.kt; session/Settings.kt; MainActivity.kt; testler (KeyTrackerTest, RelPointerTrackerTest, RelPointerCaptureTest, SessionSupportTest); bu kart.
- **Varsayımlar:**
  - **Hata düzeltmesi:** mevcut `KEYCODE_F3 = 134` yanlıştı (Android: F1=131, F2=132, F3=133, 134=F4). 133'e düzeltildi, F1/F2 eklendi; tuşlar ayrıca Linux scan kodlarıyla (59/60/61) da eşleşir. Testler 134 -> 133 güncellendi.
  - Kaydırma hızı korunsun diye `SCROLL_GAIN` 1,0 -> 1,5 (SCREEN_SPAN 1,2 -> 0,8 kaydırmayı da yavaşlatacaktı).
  - Çarpan adımları 0,85 / 1,15; aralık 0,25-3,0; bozuk kayıt değeri 1,0.
  - "Son kullanılan cihaz" = son kare gelen cihaz (pad ya da fare); hiçbiri yoksa touchpad.
  - Ctrl+Shift+Esc, Esc'in BACK koduyla (scan 1) gelmesini de tanır; yalnız Esc Mac'e gitmeye devam eder.
  - Oturum yokken yalnızca F3 yerel; F1/F2/Esc Android'de kalır.
  - Panele kısayol metni kodla eklendi (addShortcutHint).
- **Test edilmeyenler / cihazda doğrulanacaklar:** Ctrl+Shift+F1/F2 ile Toast ve hızın canlı değişmesi (touchpad/fare ayrı); Ctrl+Shift+Esc ile uygulama arka plana gidiyor, Mac'te Ctrl/Shift takılı kalmıyor, pointer capture bırakılıyor (Android imleci geri geliyor), geri dönünce devam ediyor; yeni varsayılan hız hissi; Toast immersive modda görünüyor mu; kaydırma hızı eskisiyle aynı mı; Ctrl+Shift+F3 hâlâ çalışıyor mu.
- **Açık sorular:** Yok.

## Orkestratör notu (merge, 2026-09-30)

- Küçük, yerel kısayol + sabit değişikliği; orkestratör okudu, Codex turu yapılmadı. Ajan T-033'teki `KEYCODE_F3 = 134` hatasını buldu (134 = F4; F3 = 133) ve düzeltti. Kaydırma kazancı 1,5'e çıkarıldı (touchpad ölçeği küçüldüğü için kaydırma hızı aynı kalsın diye). Cihaz testi bir sonraki ortak testte.
