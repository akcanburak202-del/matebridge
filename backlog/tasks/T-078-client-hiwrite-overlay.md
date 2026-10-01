---
id: T-078
title: Tablet — açılışta ekranın üst ortasında kalem algılanmıyor (Huawei HiWrite katmanı, adres metin kutusu)
status: in-progress
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

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
