# Board

_Otomatik üretildi: `./scripts/board.sh` — elle düzenleme._

## todo

| ID | Başlık | Aşama | Sahip | Bağımlılık |
|---|---|---|---|---|
| [T-014](tasks/T-014-host-integration.md) | Mac entegrasyonu — oturum + görüntü hattı, istatistik, uçtan uca akış | 1 | mac-host-dev | [T-010, T-011] |
| [T-015](tasks/T-015-client-integration.md) | Android entegrasyonu — oturum + görüntü, tam ekran, istatistik katmanı | 1 | android-client-dev | [T-012, T-013] |

## done

| ID | Başlık | Aşama | Sahip | Bağımlılık |
|---|---|---|---|---|
| [T-001](tasks/T-001-repo-bootstrap.md) | Repo iskeletini kur ve GitHub'a yayınla | 0 | orchestrator | [] |
| [T-002](tasks/T-002-toolchain-and-tablet-setup.md) | Geliştirme araçlarını ve tableti hazırla | 0 | user | [] |
| [T-003](tasks/T-003-android-input-probe.md) | Android girdi probu — kalem, klavye, trackpad olaylarını kaydet | 0 | android-client-dev | [T-002] |
| [T-004](tasks/T-004-mac-vdisplay-probe.md) | Mac sanal ekran probu — 2800×1840 sanal ekran oluştur ve yakala | 0 | mac-host-dev | [] |
| [T-005](tasks/T-005-mac-pen-sink-probe.md) | Mac kalem alıcı probu — sentetik tablet olayları enjekte et ve doğrula | 0 | mac-host-dev | [] |
| [T-006](tasks/T-006-signing-identity.md) | Sabit imza kimliği (Apple Development) ve .app paketleme betiği | 0 | orchestrator | [] |
| [T-007](tasks/T-007-protocol-v0.md) | Protokol v0 taslağı ve altın örnekler | 0 | orchestrator | [T-003, T-004, T-005] |
| [T-008](tasks/T-008-host-skeleton-codec.md) | Mac iskeleti ve protokol kodeki (MateBridgeCore) — fixture testleriyle | 1 | mac-host-dev | [T-007] |
| [T-009](tasks/T-009-client-skeleton-codec.md) | Android iskeleti ve protokol kodeki — fixture testleriyle | 1 | android-client-dev | [T-007] |
| [T-010](tasks/T-010-host-session-server.md) | Mac oturum sunucusu — Bonjour, kontrol bağlantısı, onay, heartbeat | 1 | mac-host-dev | [T-008] |
| [T-011](tasks/T-011-host-video-pipeline.md) | Mac görüntü hattı — sanal ekran, yakalama, HEVC kodlama, sınırlı kuyruk | 1 | mac-host-dev | [T-008] |
| [T-012](tasks/T-012-client-session.md) | Android oturum istemcisi — NSD keşif, bağlantı, onay bekleme, heartbeat, yeniden bağlanma | 1 | android-client-dev | [T-009] |
| [T-013](tasks/T-013-client-video-decode.md) | Android görüntü çözme — MediaCodec HEVC düşük gecikme, SurfaceView, sınırlı kuyruk | 1 | android-client-dev | [T-009] |
