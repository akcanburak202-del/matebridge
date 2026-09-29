# 0003 — Klavye: karakter değil fiziksel tuş kodu

- **Durum:** kabul
- **Tarih:** 2026-09-29

## Bağlam
Kullanıcı Türkçe Q düzeni kullanıyor. Karakter göndermek; kısayolları (Cmd+Ş gibi), değiştirici tuşları, tuş tekrarını ve ölü tuşları bozar. Ayrıca iki taraf arasında düzen tutarsızlığı yaratır.

## Karar
Tablet her tuş için down/up olayında **fiziksel tuş kimliğini** (Android scan code, gerekirse keycode) gönderir. Mac bunu macOS virtual keycode'a çevirip `CGEvent` ile enjekte eder. Karakter üretimini Mac'te seçili giriş kaynağı ("Türkçe Q") yapar. Değiştirici eşlemesi (ör. Ctrl↔Cmd) ayarlanabilir bir tabloda tutulur.

## Sonuçlar
- Türkçe karakterler ve kısayollar macOS'un kendi davranışıyla çalışır.
- Eşleme tablosu `MateBridgeCore` içinde birim testle doğrulanır.
- Huawei klavyesinin gerçek scan code'ları T-003 (girdi probu) ile ölçülür. Tablo o veriyle doldurulur.
- Tuş tekrarı tablette değil, macOS'ta üretilir (tablet yalnızca down/up gönderir).
