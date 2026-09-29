# Board

_Otomatik üretildi: `./scripts/board.sh` — elle düzenleme._

## todo

| ID | Başlık | Aşama | Sahip | Bağımlılık |
|---|---|---|---|---|
| [T-003](tasks/T-003-android-input-probe.md) | Android girdi probu — kalem, klavye, trackpad olaylarını kaydet | 0 | android-client-dev | [T-002] |
| [T-005](tasks/T-005-mac-pen-sink-probe.md) | Mac kalem alıcı probu — sentetik tablet olayları enjekte et ve doğrula | 0 | mac-host-dev | [] |
| [T-006](tasks/T-006-signing-identity.md) | Sabit imza kimliği (Apple Development) ve .app paketleme betiği | 0 | orchestrator | [] |
| [T-007](tasks/T-007-protocol-v0.md) | Protokol v0 taslağı ve altın örnekler | 0 | orchestrator | [T-003, T-004, T-005] |

## done

| ID | Başlık | Aşama | Sahip | Bağımlılık |
|---|---|---|---|---|
| [T-001](tasks/T-001-repo-bootstrap.md) | Repo iskeletini kur ve GitHub'a yayınla | 0 | orchestrator | [] |
| [T-002](tasks/T-002-toolchain-and-tablet-setup.md) | Geliştirme araçlarını ve tableti hazırla | 0 | user | [] |
| [T-004](tasks/T-004-mac-vdisplay-probe.md) | Mac sanal ekran probu — 2800×1840 sanal ekran oluştur ve yakala | 0 | mac-host-dev | [] |
