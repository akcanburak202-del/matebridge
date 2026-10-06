---
id: T-285
title: İstemci — video alma yolunda kare başına ayırmaları azalt (oyunda GC %14, 7 000 fault/s)
status: todo
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

## Handoff

## Open questions
