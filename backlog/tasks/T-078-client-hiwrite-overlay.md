---
id: T-078
title: Tablet — açılışta ekranın üst ortasında kalem algılanmıyor (Huawei HiWrite katmanı, adres metin kutusu)
status: review
phase: 5
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/res/layout/activity_main.xml
  - client-android/app/src/test/
  - backlog/tasks/T-078-client-hiwrite-overlay.md
---

## Amaç

Kullanıcı (2026-10-01 ~14:00): Akıcı moda geçip uygulama yeniden başlayınca ekranın üst-orta bölgesinde kalem algılanmadı; bir süre sonra düzeldi. Orkestratör, uygulama açıldıktan ~1,5 sn sonra `dumpsys window windows`: en üstte **`com.huawei.hiwrite`** penceresi, `ty=2032`, `fl=NOT_FOCUSABLE NOT_TOUCH_MODAL` (dokunulabilir), **`mFrame=[989,276][1805,558]`** (816×282 px, üst orta), `isVisible=true`. HiWrite, Huawei'nin kalemle metin alanına el yazısı özelliği; bağlantı panelindeki `endpointField` (`EditText`, manuel adres) açılışta panel görünürken onu tetikliyor, panel `GONE` olduktan sonra katman bir süre kalıp o bölgedeki kalem olaylarını yutuyor.

## Kabul kriterleri

- [ ] Akış başlarken/sürerken hiçbir düzenlenebilir metin alanı odakta ya da görünür değil: `endpointField` varsayılan olarak gizli/devre dışı (ör. "Manuel adres" düğmesiyle açılır), panel gizlenirken `clearFocus()`, IME gizle, alan `GONE` + `isEnabled=false`. Kullanıcı manuel adres girişi hâlâ yapılabilir.
- [ ] Mümkünse el yazısı katmanını açıkça kapat: API 33+ `View.setAutoHandwritingEnabled(false)` (seviye kontrolü ile), ve Huawei'nin bilinen bir bayrağı/ipucu varsa (araştır, kanıtla) uygula; yoksa yazma.
- [ ] Akış sırasında HiWrite katmanı çıkarsa bile yakalanabilmesi için: tespit edilemiyorsa *Açık sorular*a yaz (orkestratör `dumpsys` ile doğrular).
- [ ] Mevcut bağlantı akışları (USB, Wi-Fi, keşif, manuel adres) çalışır. `./scripts/check.sh` geçiyor.

## Plan

1. `activity_main.xml`: `endpoint` varsayılan `visibility=gone`, `enabled=false`; "Bağlan"ın altına "Manuel adres" düğmesi (`endpoint_toggle`, metin layout'ta literal — `strings.xml` dosya listesinde değil).
2. `MainActivity`: `showManualEntry()` (görünür + etkin + odak + IME göster) / `hideManualEntry()` (`clearFocus()`, IME gizle, `GONE`, `isEnabled=false`). Düğme ikisi arasında geçiş yapar.
3. `hideManualEntry()` çağrı noktaları: akış başlayınca panel `GONE` olurken (`render`), `onStart` (her açılışta gizli başla), `onConnectClicked` (yazılan adresle bağlanınca), IME "Done" → bağlan.
4. "Bağlan" davranışı değişmez: alan gizliyken de içindeki (önceden doldurulmuş son adres) metni okur.
5. API 33+: `endpointField.setAutoHandwritingEnabled(false)` (SDK kontrolü ile; cihaz API 31 olduğundan orada etkisiz, belgelenir).
6. Huawei'ye özel HiWrite bayrağı: kanıtlı bir genel API/ipucu bulunamazsa yazılmaz, *Açık sorular*a not edilir.
7. Saf mantık yok denecek kadar az (görünürlük geçişi); yeni sınıf dosya listesi dışında kalacağı için JVM testi eklenmez, `check.sh` ile doğrulanır.

## Handoff

- **Commit:** `26433e9` (plan: `8e46e82`), branch `task/T-078-client-hiwrite`.
- **Dokunulan dosyalar:** `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt`, `client-android/app/src/main/res/layout/activity_main.xml`, bu kart.
- **Ne yapıldı:**
  - `endpoint` (EditText) layout'ta varsayılan `gone` + `enabled=false`. Yeni "Manuel adres" düğmesi (`endpoint_toggle`, "Bağlan"ın altında) alanı açar/kapar; açınca odak + IME gösterilir.
  - `hideManualEntry()`: `clearFocus()`, `hideSoftInputFromWindow`, `GONE`, `isEnabled=false`. Çağrıldığı yerler: `onCreate` (kurulum), `onStart` (her açılış), `onConnectClicked` (bağlanmadan önce), `render()` içinde akış başlayıp panel `GONE` olmadan hemen önce.
  - IME "Done" → `onConnectClicked()` (yazılan adresle bağlanır ve alanı kapatır).
  - API 33+: `setAutoHandwritingEnabled(false)` (SDK kontrolü ile). Tablet API 31 olduğundan orada etkisiz.
- **Varsayımlar:**
  - "Bağlan" davranışı değişmedi: alan gizliyken de içindeki metni (açılışta son kaydedilen adresle dolu) okur; boşsa `currentEndpoint`. Yani eskiden gizli olmayan alanla yapılan "son adrese tekrar bağlan" akışı aynen çalışır.
  - HiWrite katmanını tetikleyen şey düzenlenebilir, odaklanabilir/görünür `EditText`. Uygulamada başka `EditText` yok.
  - "Manuel adres" metni layout'ta literal (`strings.xml` dosya listesinde değil).
  - Saf mantık eklenmedi (yalnızca görünürlük geçişi); yeni sınıf dosya listesi dışında kalacağı için JVM testi yok.
- **check.sh:** ALL OK.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  1. Uygulamayı soğuk başlat (Akıcı moda geçip yeniden başlatma senaryosu dahil); ~1,5 sn ve ~5 sn sonra `adb shell dumpsys window windows | grep -i -A3 hiwrite`: `com.huawei.hiwrite` penceresi **olmamalı** (ya da `isVisible=false`).
  2. Akış sırasında ekranın üst-ortasında (≈ x 989–1805, y 276–558) kalemle çiz: Mac'te kesintisiz gelmeli.
  3. Panelde metin kutusu görünmüyor olmalı; "Manuel adres"e bas → alan + klavye açılır, `IP:port` yaz, Done veya "Bağlan" → bağlanır, alan kapanır, akış başlayınca kalem üst-ortada çalışır (bu yolda da `dumpsys` kontrolü).
  4. USB ile bağlan, Wi-Fi ile bağlan (keşif/otomatik bağlantı) ve "Bağlan" (alan kapalıyken son adres) akışları eskisi gibi çalışır.
  5. "Manuel adres"e iki kez bas → alan ve klavye kapanır.
- **Açık sorular:**
  - Huawei'ye özel HiWrite'ı kapatan genel/belgelenmiş bir bayrak veya ipucu bulunamadı (çevrimdışı; kanıtlanamadığı için yazılmadı). `setAutoHandwritingEnabled` API 33 ve tablet API 31.
  - HiWrite penceresi başka bir nedenle (ör. hiç EditText yokken) akış sırasında çıkarsa uygulamadan tespit edilemez (başka uygulamanın sistem penceresi, `ty=2032`); orkestratör `dumpsys window windows` ile doğrulamalı. Çıkarsa olası sonraki adım: kart dışı araştırma (HiWrite ayarı kullanıcı tarafında kapatılabilir: Ayarlar → Erişilebilirlik/Kalem → "El yazısı girişi").
