---
id: T-035
title: Tablet — imleç hızı (daha yavaş varsayılan + canlı ayar kısayolu), Android'e dönüş kısayolu
status: todo
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

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
