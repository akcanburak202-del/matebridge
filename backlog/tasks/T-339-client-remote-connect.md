---
id: T-339
title: İstemci — 0038 protokol kodu, "Uzaktan bağlan" düğmesi, uzak profil ve keyframe yineleme geri çekilmesi
status: todo
phase: 7
owner: android-client-dev
depends_on: [T-336]
decisions: [0038, 0030, 0036, 0035]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/main/res/
  - client-android/app/src/test/
  - backlog/tasks/T-339-client-remote-connect.md
---

## Amaç

Karar 0038 §1, §2, §6, §7 ve ekleri; PROTOCOL.md yeni kurallarının istemci tarafı. Dal tabanı: `task/0038-remote-integration` (main değil).

## Kapsam

1. **Protokol kodu (Kotlin):** STREAM_PREFS bağlantı grubu (16 bayt yazma kuralı, 15 bayt hata), AUDIO_PREFS `codec`, AUDIO_CONFIG `format = 2` sabiti, AUDIO_FRAME 1–1024 sınırı, HELLO bit14 sabiti (**bu kartta bildirilmez**; AAC çözücüsü T-341). Yeni fixture'ların hepsi için testler.
2. **"Uzaktan bağlan":** bağlantı ekranında ayrı düğme. Uzak adres ayrı saklanır (IPv4 ya da DNS adı, sondaki nokta atılır, isteğe bağlı `:port`, varsayılan 47001; IPv6 yok). İlk kullanımda sorulur, düzenlenebilir. Uygulama açılışında uzak adrese kendiliğinden bağlanılmaz; uzak oturum koparsa aynı adrese normal geri çekilmeyle yeniden bağlanılır.
3. **Uzak profil (yalnız bu düğmeyle kurulan oturum):** STREAM_PREFS `link = 1`, `fps = 15`, `display_* = 1400×920`, SDR, `chroma = 0`, uzak bit hızı (0,5 / 1 / 2 Mbps, varsayılan 1, ayrı hatırlanır). Yerel imleç açık. Uzak ses ayarı ayrı, varsayılan **kapalı** (açılınca bu kartta PCM istenir; T-341 AAC'ye çevirir). `FILES_INFO` OFF. WoL yok. Mod seçimi ve Ctrl+Shift+7 etkisiz; panel "Uzak (Tasarruf)" gösterir; kullanıcının normal mod/ayarları değişmez.
4. **Zamanlamalar (uzak oturum):** PING 500 ms (girdi tutuluyorken ya da son girdiden 2 sn içinde) / 2 sn (boşta); PONG zaman aşımı 10 sn; STATS 5 sn; yerel imleç zaman aşımı 5 sn.
5. **Ağ değişimi:** uzak oturumda otomatik USB/Wi-Fi geçişi ve ağ geri çağrıları oturumu düşürmez ya da başka yola geçirmez (etkin ağ VPN ya da mobil veri olabilir).
6. **Reddedilen uzak eşleşme:** uzak oturumda REJECTED → "Yeni eşleşme yalnız ev ağında ya da USB ile yapılabilir." Giriş ekranında kalır, yeniden denemez.
7. **Tüm oturumlar:** keyframe beklerken STARTUP yinelemesi 500 ms → iki katına, en çok 4 sn; keyframe gelince sıfırlanır (`FrameQueue`/`MainActivity` `KEYFRAME_RETRY_MS`).

## Güvenlik kuralı (AGENTS.md)

PING seyreltme takılı girdi yaratmamalı: herhangi bir tuş/düğme/kalem/açık hareket varken PING 500 ms'de kalır; ilk girdi olayı hızlı aralığa hemen döner. Birim testiyle doğrula.

## Kabul

- Birim testleri: STREAM_PREFS uzak 16 bayt = `stream_prefs_remote`; normal oturum baytları değişmez; PING aralık seçimi; STARTUP geri çekilme dizisi 500/1000/2000/4000/4000; adres ayrıştırma; uzak ses varsayılan kapalı.
- `./scripts/check.sh` Kotlin kısmı geçer (Swift kısmı T-337'ye kadar fixture kapsamında düşebilir; handoff'ta yaz).
- Cihaz testi orkestratörde.

## Plan

## Handoff

## Open questions
