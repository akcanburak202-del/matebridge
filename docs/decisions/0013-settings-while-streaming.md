# 0013 — Akış sırasında ayarlar paneli: kısayol + Mac menüsü, sağ yan panel, host ayarları tabletten

- **Durum:** kabul
- **Tarih:** 2026-10-01

## Bağlam
Kullanıcı isteği (T-102): ayarlara bağlıyken de ulaşılabilsin. Bugün ayarlar yalnızca bağlantı panelinde; panel akış başlayınca gizleniyor. Kullanıcı 2026-10-01'de şu seçenekleri seçti:
- açma yolu: klavye kısayolu **ve** Mac menü çubuğu;
- görünüm: sağ yan panel;
- host ayarları (bit hızı vb.) tabletteki panelden;
- mod seçimi (ikinci ekran/ana ekran/yansıtma) sonra, ayrı kartta.

## Karar
1. **Kısayol: Ctrl+Shift+6.** Mevcut tablet kısayollarıyla (Ctrl+Shift+Esc/7/8/9/0) aynı ailede, Mac'e gitmez.
   - Ctrl+Shift+S seçilmedi: karar 0008'de Ctrl → Command olduğu için Mac'teki Cmd+Shift+S ("Farklı Kaydet") ile çakışır.
   - Ctrl+Shift+Space seçilmedi: Android klavye düzeni değiştirmeye ayrılmış olabilir.
   - Panel açıkken Esc, aynı kısayol, panel dışına (videoya) dokunma ya da kapat düğmesi paneli kapatır.
2. **Mac menüsü:** host menüsüne "Tablette ayarları aç" eklenir. Yeni mesaj `0x08 SETTINGS_OPEN` (H→C) tablete paneli açtırır. Menü çubuğu sanal ekranda da göründüğü için kalemle/dokunarak tabletten de tıklanabilir; klavye takılı değilken de panele ulaşılır. Host bunu yalnızca istemci `HELLO.capabilities` bit9 `SETTINGS_PANEL` bildirirse gönderir.
3. **Görünüm:** sağda yarı saydam yan panel. Video ve ses arkada sürer.
   - Panel açılırken istemci `RELEASE_ALL(USER)` gönderir. Panel açıkken girdi Mac'e gitmez: pointer capture bırakılır, klavye panele gider.
   - Kapanınca girdi kaldığı yerden devam eder.
4. **İçerik** (bağlantı panelindeki ayarlarla aynı kaynak; mantık iki kez yazılmaz):
   - **Bağlantı:** Otomatik/USB/Wi-Fi (gerekirse yeniden bağlanır), "Bağlantıyı kes".
   - **Görüntü:** mod (Netlik/Akıcı/Performans) ve bit hızı (Otomatik / 15 / 30 / 60 / 100 Mbps). İkisi de `STREAM_PREFS` ile gider. Değişince host yeniden yapılandırır (kısa video kesintisi).
   - **Ses:** aç/kapa ve çıkış (Düşük gecikme/Uyumlu); anında uygulanır.
   - **Girdi:** imleç hızı, "parmak dokunmasını kapat", kalem izi/noktası; anında uygulanır.
   - **Diğer:** pano paylaşımı, istatistik katmanı; anında uygulanır.
5. **Host ayarları tabletten:** `STREAM_PREFS`'in eski `reserved u32` alanı `bitrate_kbps` olur. `0` host varsayılanı demektir, bu yüzden eski istemcilerle uyumludur.
   - Öncelik: host env > kullanıcı > mod varsayılanı.
   - Host bu tercihi cihaz başına hatırlar (T-049).
   - Çözünürlük/ölçek mod üzerinden zaten tablette (`scale_permille`).
   - Codec seçeneği konmaz: HEVC varsayılan, H.264 yalnızca deney (`MATEBRIDGE_CODEC`).
6. **Sonraya kalanlar:** Ctrl↔Cmd takası / gerçek Control tuşu (karar 0008 Faz 4 notu), mod seçimi (ikinci ekran/ana ekran/yansıtma, PLAN aşama 4), codec seçimi.

## Sonuçlar
- Protokol: `STREAM_PREFS.bitrate_kbps`, `0x08 SETTINGS_OPEN`, HELLO bit9. Fixture'lar: `stream_prefs_bitrate`, `settings_open`.
- Kartlar:
  - T-104: kod çözücüler, iki taraf;
  - T-105: tablet yan paneli;
  - T-106: host bit hızı tercihi ve menü komutu.
- Tekrar düşünülür: kullanıcı kısayolu ya da paneli kullanışsız bulursa, ya da HarmonyOS Ctrl+Shift+6'yı yutarsa.
