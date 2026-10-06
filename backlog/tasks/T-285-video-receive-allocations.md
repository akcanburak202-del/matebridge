---
id: T-285
title: İstemci — video alma yolunda kare başına ayırmaları azalt (oyunda GC %14, 7 000 fault/s)
status: done
phase: 6
owner: android-client-dev
depends_on: [T-282]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/security/Records.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/Codec.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/security/
  - client-android/app/src/test/kotlin/dev/matebridge/client/protocol/
  - backlog/tasks/T-285-video-receive-allocations.md
---

## Amaç

T-282 ölçümü (`docs/research/2026-10-07-perf-profile.md` §Sıcak noktalar 2): her video kaydı açılırken üç tam boy ayırma var:
- `RecordOpener` → `scratch.copyOf(n)`;
- `RecordDecoder.next` → `plain.copyOfRange(1, n)`;
- `Codec.decodePayload` → `Reader.bytes(size)`.

Oyun 60'ta (2800×1840, 100–300 KB/kare) `HeapTaskDaemon` tek çekirdeğin %14'ü, `mb-video` %13 (bunun %29'u memcpy), 7 000 minor fault/s. **Protokol ve tel biçimi değişmez.** Fixture testleri aynen geçmeli.

## Kabul

1. Bir video kaydı için tam boy ayırma sayısı **en fazla 1**: `VideoFrame.data` olarak kuyruğa giden dizi. Şifre çözme kalıcı `scratch`'e yapılır. Tür baytı ve yük, kopya almadan ofset ve uzunlukla çözülür (`decodePayload`'a dilim alan bir yol). `VideoFrame` ve `Bytes` API'si değişmez. Kuyruğa giden dizinin ömrü tüketiciye ait olduğu için havuz bu kartta **yok**.
2. Kontrol bağlantısındaki küçük mesajlar aynı yolu kullanabilir ama davranışları değişmez. Hata yolları da aynı kalır: kimlik doğrulama hatası, `INVALID_VALUE`, sınır aşımı.
3. `scratch` aynı `RecordOpener` içinde yeniden kullanıldığı için çözülen veri bir sonraki `open` çağrısından önce kopyalanmış ya da tüketilmiş olmalı. Bunu kanıtlayan test: art arda iki farklı kare, ilk karenin verisi bozulmamış.
4. Ayırma sayısını ölçen birim testi ya da kıyaslama (`test/.../bench` deseni). Örneğin 1 000 kayıt çözümünde ayrılan büyük dizi sayısı ≤ 1 000.
5. Güvenlik kodu: birleştirme öncesi `./scripts/codex-review.sh main task/T-285-video-receive-allocations` (orkestratör).
6. Cihaz ölçümü (orkestratör, Oyun 60): hedef `HeapTaskDaemon` ≤ %5, minor fault/s ≤ 2 000, `mb-video` ≤ %10. `latency_ms` ve `decode_ms` değişmemeli.

## Plan

Gerçek durum: `RecordDecoder.next` zaten `openPlain` kullanıyor (`scratch.copyOf` yalnızca `open/openAt` yolunda, üretimde çağıran yok). Yani video yolunda kalan tam boy ayırmalar ikiydi: `plain.copyOfRange(1, n)` ve `Reader.bytes(size)`.
1. `Reader` ofset/uzunluk alır (`ByteBuffer.wrap(bytes, off, len)`: kopyasız görünüm, `remaining()` dilimin sonundan sayar).
2. `Codec.decodePayload(type, buf, offset, length)` aşırı yüklemesi; eski imza buna yönlenir. Dilim yalnızca çağrı sırasında okunur, mesajın tuttuğu her bayt kopyalanır (`Bytes(r.bytes(..))`), bu yüzden `scratch` yeniden kullanımı güvenli.
3. `RecordDecoder.next` dilimi yerinde çözer. Tel biçimi, hata türleri (`SHORT_PAYLOAD`, `INVALID_VALUE`, `AUTH_FAILED`, `OVERSIZE`) ve `VideoFrame`/`Bytes` API'si değişmez.
4. Testler: art arda kareler (bozulma yok), dilim = tam dizi, sınır dışı baytlar yük sayılmaz, JVM thread-başına ayırma sayacıyla 1 000 kayıtta bayt sınırı.

## Handoff

- Commit: `git log task/T-285-video-receive-allocations` (tek T-285 commit'i).
- Dosyalar: `client-android/.../protocol/Codec.kt`, `.../security/Records.kt`, yeni testler `.../protocol/DecodeSliceTest.kt` ve `.../security/RecordReceiveAllocTest.kt`, bu kart.
- Sonuç: video kaydı başına tam boy ayırma 2 -> 1 (`VideoFrame.data`). Ölçüm (JVM, 20 KB kare, 1 000 kayıt): kayıt başına 41 232 bayt (2.06x) -> 21 268 bayt (1.06x). Test eşiği 1.5x; eski kodla başarısız olduğu doğrulandı.
- Varsayım: karttaki "üç ayırma" sayımındaki `scratch.copyOf(n)` video yolunda zaten yoktu (`openAt` yalnızca testlerde kullanılıyor); dokunmadım. Havuz yok (kart gereği). `Reader` `internal`, yeni parametreler varsayılanlı, diğer çağıranlar etkilenmez.
- `./scripts/check.sh`: bkz. son mesaj (OK). Fixture testleri değişmeden geçti.
- Test EDİLMEDİ (orkestratör): madde 5 codex review; madde 6 cihaz ölçümü (Oyun 60: `HeapTaskDaemon` <= %5, minor fault/s <= 2 000, `mb-video` <= %10, `latency_ms`/`decode_ms` değişmemeli). Tablet ve Mac UI'ya dokunulmadı. Hedef tutmazsa kalan büyük ayırma `VideoFrame.data`; sonraki adım tüketici tarafı havuzu (ayrı kart).
- Tablette kontrol: Oyun/Günlük modunda video normal (bozuk kare, artefakt, keyframe isteği artışı yok), Wi-Fi ve USB'de; Oyun 60'ta yukarıdaki üç metrik.

### Cihaz ölçümü (orkestratör, 2026-10-06 ~23:28, Oyun 60, Wi-Fi)

Hedefler tutmadı. Kod doğru ve `copyOfRange` profilden kalktı, ama ayırmanın asıl kaynağı Conscrypt'in içinde:

| | önce | sonra | hedef |
|---|---:|---:|---:|
| `HeapTaskDaemon` | %14,0 | %12,8 | ≤ %5 |
| minor fault/s | 7 042 | 5 066 | ≤ 2 000 |
| `mb-video` | %13,0 | %15,0 | ≤ %10 |
| `latency_ms` ort. / `decode_ms` ort. | 22,3 / 11,8 | 20,9 / 12,3 | değişmesin |

- `mb-video` profili (`openPlain` %43):
  - `Cipher.init` her kayıtta sağlayıcıyı yeniden seçiyor ve yeni bir SPI nesnesi oluşturuyor (`chooseProvider` → `tryCombinations` → `Provider$Service.newInstance`): iş parçacığının %11'i;
  - Conscrypt AEAD şifre çözme, girdiyi kendi tamponuna kopyalıyor (`updateInternal` %12,5, `expand`);
  - `doFinalInternal` %19.
- Sonraki adım: T-292.

## Open questions
