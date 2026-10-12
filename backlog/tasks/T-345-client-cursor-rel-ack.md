---
id: T-345
title: İstemci — CURSOR_STATE `rel_ack_count` ile tahmin (geri sıçrama yok)
status: review
phase: 7
owner: android-client-dev
depends_on: []
decisions: [0036]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/test/
  - backlog/tasks/T-345-client-cursor-rel-ack.md
---

## Amaç

Karar 0036 v3 eki; PROTOCOL.md §4 CURSOR_STATE "Onay grubu". Dal tabanı: `task/0036-cursor-ack-integration`.

## Kapsam

1. **Çözme:** `CURSOR_STATE` 22 bayt (grup yok) ya da ≥30 bayt (`rel_ack_count`). 23–29 bayt protokol hatası. Fixture testleri: `cursor_state_ack`, `invalid_cursor_state_ack_partial`.
2. **Numaralama ve tahmin:** istemci bu kontrol bağlantısında gönderdiği her `POINTER_REL`'i 1'den numaralar; düğme değişimli `dx = dy = 0` mesajlar dahil. Numara, mesajın gerçekten gönderim kuyruğuna/sokete yazılma sırasıdır. Atılan ya da gönderilemeyen mesaj numara almaz; numara ile host'un saydığı mesaj birebir eşleşmeli. `CursorPredictor` halkası her deltanın numarasını tutar.
   - Onaylı durum gelince numarası ≤ `rel_ack_count` olan delta durumun içinde sayılır, değilse üstüne eklenir. Saat farkı ve tek yön tahmini bu karar için kullanılmaz.
   - Yeniden bağlanmada (yeni kontrol bağlantısı) numara 1'den başlar, halka boşaltılır.
   - T-343 yerleşme süresi yalnız onaylanmayan ama host'un yok saydığı deltalar için yedek kalır.
   - Grup yoksa (eski host) bugünkü davranış bit bit aynı.
3. **Ölçüm:** `cursor_stats` `pred_err`/`hold_err` tanımı aynı kalır; ek bir sayaç `ack_n` (onaylı durum sayısı) eklenebilir (LOGGING.md'ye uygun).
4. **Değişmeyenler:** gönderilen mesajlar, girdi yolu, askıya alma kuralları.

## Kabul

- Birim testleri:
  - fixture'lar;
  - benzetim: RTT 40 ms, titreşim 40–100 ms, ev Wi-Fi'ı 15 ms + ara ara 60 ms sıçrama. Onaylı durumlarla çizilen imlecin geri sıçraması ≤ 1 pt, `pred_err` p95 ≈ 0.
  - onaysız (eski host) yolun çıktısı değişmemiş.
- `./scripts/check.sh` geçer. Swift fixture kapsamı T-344 birleşene kadar düşebilir; handoff'ta yaz.
- Cihaz testi orkestratörde.

## Plan

1. `CursorState.relAckCount: Long?` (null = grup yok); codec: 22 bayt -> null, >=30 -> u64, 23-29 -> SHORT_PAYLOAD (u64 okuması atar). Fixture testleri eklendi.
2. `CursorPredictor`: `onSent` her `POINTER_REL`'i (dx=dy=0 dahil, gen eşleşirse) elden teslim sırasıyla numaralar (`relSent`; yalnız `beginSession`/`endSession`'da sıfırlanır, katman aç/kapa ya da askıya alma sıfırlamaz). Halka her deltanın numarasını tutar. `Anchor.ackCount` taşır; `positionAt` ackli çapada "numara <= ack" ile eler (zaman tahmini yok), ack'siz çapada bugünkü kod. `pred_err` ölçümü ackli iki durum arasında kesin: önceki çapa + (önceki ack, yeni ack] aralığı.
3. Ackli çapada yerleşme (`settle`) yedeği kapalı: yalnız halkanın yaş sınırı (500 ms) geçerli; aksi halde RTT sıçramasında onaylanmamış ama yoldaki delta düşüp imleç geri sıçrardı.
4. `cursor_stats` sonuna `ack_n=<n>` yalnız n>0 ise eklenir (eski host satırı aynı).
5. Testler: `CursorPredictorAckTest` (benzetim RTT 40 ms + 40-100 ms titreşim; 15 ms Wi-Fi + 60 ms sıçrama; ack'siz yol; numaralama).

## Handoff

- Dal `task/T-345-client-cursor-rel-ack`, SHA: dalın tepe commit'i (`git log -1`).
- Dosyalar: `protocol/Messages.kt`, `protocol/Codec.kt`, `cursor/CursorPredictor.kt`, `cursor/CursorStats.kt`; testler `FixtureTest`, `CursorCodecTest` (eski "23 bayt fazlası tolere" testi yeni kurala göre değişti), yeni `CursorPredictorAckTest`.
- Varsayımlar: numara `InputOutbox.transmit` içinde `sink.send` başarılı olduktan sonra çağrılan gözlemci (`onSent`, UI thread) sırasıdır; birleştirilen (merge) `POINTER_REL`'ler tek mesajdır, tek numara alır; reddedilen mesaj gözlemciye gitmez. `beginSession(gen)` ilk girdiden önce çağrılmalı (T-276 sırası öyle); aksi halde o mesajlar numara almaz ve ack kayar. Sayaç yalnız `gen == armedGen` mesajlarını sayar. `rel_ack_count` >= 2^63 ise "hepsi içinde" sayılır.
- check.sh sonucu: Swift `FixtureTests` düşer (T-344 birleşene kadar beklenen: `cursor_state_ack` fixture'ı host tarafında henüz kapsanmıyor). Android'de benim testlerim geçer; `DecoderWaitTest` ve `OutputParkTest` (yoklama sayısı, zamanlama) taban commit 86dd5835'te de aynı şekilde düşüyor, `AacDecodeWorkerTest` aralıklı. Bunlara dokunulmadı.
- Tablette bakılacak (orkestratör): ack'li host ile uzak/Wi-Fi'da hızlı fare/izleme dörtgeni sırasında imleç geri sıçramıyor mu; `cursor_stats` satırında `ack_n>0` ve `pred_err_pt_p95` ~0; eski host ile `ack_n` yok, davranış değişmemiş; yeniden bağlanınca (yeni kontrol bağlantısı) imleç sıçramıyor.
- Test edilmedi: gerçek cihaz/host; gerçek `sink.send` sırası ile numaralama (yalnız birim benzetimi).

## Açık sorular
