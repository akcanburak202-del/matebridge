# 0005 — Yalnızca test için bağımlılıklar

- **Durum:** kabul
- **Tarih:** 2026-09-29

## Bağlam
AGENTS.md her bağımlılık için karar kaydı istiyor. Android JVM birim testleri için bir test çatısı gerekiyor (T-003'te `junit:junit:4.13.2`). Swift tarafında XCTest/Swift Testing zaten araç zincirinde var.

## Karar
Yalnızca test kapsamındaki (`testImplementation` / `androidTestImplementation`) standart test çatıları kayıt gerektirmez: JUnit 4, `kotlin-test`. Swift'te XCTest ve Swift Testing. Uygulama APK'sına veya `.app` paketine giren her kütüphane için yine yeni karar kaydı gerekir. Mocking kütüphaneleri (MockK, Mockito vb.) bu istisnaya girmez.

## Sonuçlar
- Birim testleri için karar yükü yok, ürün bağımlılıkları hâlâ kontrol altında.
- Test çatısı sürümü proje içinde tek tutulur. İkinci bir test çatısı eklenirse bu kayıt güncellenir.
