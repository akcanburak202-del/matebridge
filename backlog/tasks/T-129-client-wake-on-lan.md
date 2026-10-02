---
id: T-129
title: Tablet — Mac bulunamayınca Wake-on-LAN magic packet ile uyandır (TXT `wol`)
status: todo
phase: 4
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/
  - backlog/tasks/T-129-client-wake-on-lan.md
---

## Amaç

Kullanıcı kararı (2026-10-02): Mac uzun süre kullanılmayınca uyusun; kullanıcı tableti açınca Mac tabletten uyandırılsın. Mac mini Wi-Fi'de, `Wake On Wireless: Supported`, `womp 1`. Host Bonjour TXT'de `wol=` ile MAC adreslerini yayınlar (T-128; format `docs/PROTOCOL.md` §3 madde 1).

## Kabul kriterleri

- [ ] `MacDiscovery` çözümlenen hizmetin TXT `wol` değerini ayrıştırır (PROTOCOL.md formatı; geçersiz adresler atlanır, en çok 4) ve son görülen host IPv4 adresiyle birlikte kalıcı saklar (SharedPreferences; MAC'ler loglanmaz). TXT'de `wol` yoksa önceki saklanan değer silinmez (eski host / geçici durum), yeni değer gelince değiştirilir.
- [ ] **Ne zaman uyandırılır:** uygulama ön plandayken ve bağlı değilken (ilk açılış, ekran açılınca yeniden bağlanma, bağlantı kopması) saklanmış `wol` varsa ve Mac kısa sürede (ör. ~2 s, sabit) bulunamıyor / bağlantı kurulamıyorsa, uyandırma bölümü başlar: magic packet her 1 s'de bir, en çok ~20 s (sabitler), bağlantı kurulunca hemen durur. Bölüm bitip hâlâ bağlantı yoksa mevcut yeniden bağlanma mantığı sürer; yeni bölüm en erken 30 s sonra ya da kullanıcı elle isteyince. Arka planda hiç gönderilmez.
- [ ] **Paket:** 6 × `0xFF` + 16 × MAC (102 bayt), UDP port 9; hedefler: `255.255.255.255`, Wi-Fi ağının alt ağ yayın adresi (LinkProperties'ten) ve son görülen host IPv4 (unicast). Soket Wi-Fi ağına bağlanır (`Network.bindSocket`; USB/adb tünel varken de Wi-Fi'den gitmeli), `broadcast = true`. Wi-Fi yoksa sessizce atlanır (log). Her MAC için ayrı paket.
- [ ] **UI:** uyandırma bölümünde panelde "Mac uyandırılıyor…" durumu; panelde elle "Mac'i uyandır" düğmesi (saklanmış `wol` yoksa gizli ya da devre dışı). Metinler Türkçe, mevcut panel üslubunda.
- [ ] Log: `MB/session ev=wol_start reason=… macs=N targets=M`, `ev=wol_stop reason=connected|timeout|background sent=K`, gönderim hatası `ev=wol_send_failed` (oran sınırlı). MAC/IP adresleri loglanmaz.
- [ ] Saf mantık testli (JVM unit test): magic packet baytları, TXT `wol` ayrıştırma (geçerli/geçersiz/fazla adres), uyandırma bölümü zamanlayıcısı (başla, 1 s aralık, 20 s sınır, bağlanınca dur, 30 s bekleme, elle tetikleme).
- [ ] Mevcut bağlanma / keşif davranışı uyandırma olmadan değişmez; girdi bırakma (release-all) kurallarına dokunulmaz.
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Cihaz testi, APK kurulumu (orkestratör yapar). Protokol değişikliği yok (TXT anahtarı PROTOCOL.md'de tanımlı).

## Plan

(ajan doldurur)

## Handoff

(ajan doldurur)
