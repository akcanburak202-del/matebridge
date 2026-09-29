# MateBridge protokolü

**Durum:** Taslak yok. Aşama 0 sonunda T-007 ile yazılacak. Sahibi: orkestratör.

Bu dosya Swift ve Kotlin tarafının tek ortak sözleşmesidir. Her mesaj tipi için:

- tip kodu, alanlar, bayt düzeni (endianness), boyut sınırı
- hangi kanal (kontrol/girdi TCP, video TCP/UDP)
- `protocol/fixtures/<mesaj_adi>.hex` altın örneği. Her iki tarafın birim testleri bu dosyalarla encode/decode doğrular.

`./scripts/check.sh`, fixture dizinindeki her dosyanın burada anılıp anılmadığını kontrol eder.
