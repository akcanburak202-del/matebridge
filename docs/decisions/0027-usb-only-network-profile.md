# 0027 — Host'ta "Yalnız USB" ağ profili

- **Durum:** önerildi
- **Tarih:** 2026-10-03

## Bağlam
Kaynak: dış mimari incelemesi 2026-10-03 (HEAD a30c769), M05 (ağ kapsamı) ve D9. Doğrulama: `docs/reviews/2026-10-03/verify-A-security.md` (M05, D9, WI-5).

Host bütün arayüzleri dinliyor. `BsdTcpListener` varsayılan olarak `[::]`'a bağlanıyor ve `IPV6_V6ONLY=0` (`BsdTcpSocket.swift:72-141`). Üretim çağıranları da bu varsayılanı kullanıyor: kontrol `SessionServer.swift:1031`, video `:639`.

Bonjour her zaman yayında. Host'ta arayüz ya da "yalnız USB" ayarı yok.

Günlük kullanım çoğunlukla USB (`adb reverse`). USB oturumları zaten loopback'ten geliyor (`SessionServer.swift:1635-1640`). Bu durumda LAN'daki dinleme ve eşleşme yüzeyi gereksiz:
- Ağdaki herhangi bir cihaz Mac'te onay penceresi açtırabilir.
- Bekleyen bir onay penceresini değiştirebilir (A ek 6).
- Bilinen bir `device_id` ile sanal ekran kurdurabilir (A ek 1; T-152 bunu kapatıyor).

Önem: ev ağında Low. Sıralama H01 (0018) → dosya kapsamı (0028) → yalnız USB.

## Seçenekler
- **(a) Her zaman bütün arayüzler (bugün).** Basit, ama USB'de de LAN yüzeyi açık.
- **(b) Arayüz bazında seçim.** En esnek seçenek, ama tek kullanıcı için fazla karmaşık.
- **(c) İsteğe bağlı "Yalnız USB" modu (önerilen).** Bu modda:
  - kontrol ve video dinleyicileri yalnızca loopback'e (`127.0.0.1`/`::1`) bağlanır;
  - Bonjour yayını yapılmaz;
  - loopback olmayan eşler kabul anında reddedilir;
  - Wi-Fi yedek yolu ve uyandırma akışları (T-133/T-134) çalışmaz. İstemci mevcut USB ipucunu gösterir.

## Karar
Önerilen: **(c)**. Varsayılan "USB + Wi-Fi" olarak kalır. Mod menüden açılır ve kapanır. Değişince, canlı oturum yokken dinleyiciler temiz biçimde yeniden başlar. Tel değişmez. **Kullanıcı onayı bekliyor.**

Kullanıcının cevaplaması gereken (manifest §5 soru 6): "Yalnız USB" modu ister misin? Varsayılan USB + Wi-Fi kalır.

## Sonuçlar
- **Kazanılan:** yalnız USB kullanılırken LAN'dan dinleme, eşleşme isteği ve onay penceresi yüzeyi tamamen kapanır.
- **Kaybedilen:** bu modda Wi-Fi'ye geçiş ve ağdan uyandırma yok. Kullanıcı modu unutursa Wi-Fi'de bağlanamaz; menü durumu açıkça göstermeli.
- **Kapıladığı kart:** T-189 (host "Yalnız USB" profili). T-186'dan sonra gelir: `nw` dinleyicileri kaldırılınca yalnızca `bsd` dinleyicileri loopback'e bağlanır. T-192 (host ayar sıfırlama) bu tercihi de sıfırlar.
- **Mevcut kararlar:** değişmez. 0001'in "önce yerel ağ" ilkesi varsayılanda korunur.
- **PROTOCOL.md (yalnızca metin):** §3 adım 1'e (Keşif) bir not eklenir: "Yalnız USB" modunda Bonjour yayını olmayabilir ve istemci USB uç noktasını kullanır. Tel ve fixture değişmez.
- **Tekrar düşünülür:** birden fazla ağ ya da cihaz desteklenirse (arayüz seçimi), ya da Wi-Fi asıl yol olursa (0023).
