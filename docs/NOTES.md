# Bulgular defteri

Donanım ve platform bulguları buraya **tarihli** olarak eklenir (en yeni en altta). Sohbette kalan bulgu ajanlar için yoktur.

## 2026-09-29 — Başlangıç

- Mac: Mac mini, Apple M6, macOS 27.0.1 (26A434), Xcode 27.0, Swift 6.4. Şu an 1920×1080 bir harici monitör bağlı.
- `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplayMode`, `CGVirtualDisplaySettings` sınıfları macOS 27.0.1'de mevcut (`/System/Library/Frameworks/CoreDisplay.framework` yüklenerek). Henüz ekran oluşturma denenmedi → T-004.
- Tablet: Huawei MatePad Pro 12.2 (2025), HarmonyOS 4.3, 2800×1840 tandem OLED (PaperMatte), 144 Hz, M-Pencil 3. nesil (16.384 basınç seviyesi, üretici verisi). Android API seviyesi → T-002.
- Referans: [LukeLogix/android-display](https://github.com/LukeLogix/android-display) (Apache-2.0) — CGVirtualDisplay + VideoToolbox H.264 + UDP + tablet olayı enjeksiyonu örnekleri.
