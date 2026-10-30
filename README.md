# Celestia Validator + Fibre Kontrol ve Telegram Uyarı Aracı

* Celestia Mainnet Beta ve Mocha (mocha-5) ağlarında Validator ve Fibre sunucusu çalıştıranlar için hazırlanmış, tek dosyalık bir kontrol ve uyarı aracıdır.
* İki işi birden yapar: `doctor` komutu ile kurulumunuzu baştan sona kontrol eder, arka planda ise her dakika node'unuzu izleyip bir sorun olduğunda Telegram'dan haber verir.
* celestia-app v10.5.0 / v10.5.0-mocha ve Fibre ile gerçek bir Mocha validator sunucusunda test edilmiştir.
* Kurulum sırasında veya sonrasında bir şey sormak isterseniz bana Telegram, Mail ve Discord yoluyla ulaşabilirsiniz. Ayrıca GitHub üzerinden de katkı sağlayabilirsiniz.

## Güvenlik

Bu araç bilerek çok sınırlı yapıldı:

- **Sadece okur.** Node ayarlarınızı değiştirmez, servisleri durdurmaz veya başlatmaz.
- **İşlem göndermez.** Zincire hiçbir tx yollamaz, cüzdan veya anahtar komutu çalıştırmaz.
- **Port açmaz.** Sadece sunucunun kendi içindeki `127.0.0.1:26657` RPC'sini okur ve Telegram'a mesaj yollar.
- **Yetkisiz kullanıcıyla çalışır.** Uyarı servisi root olarak değil, ayrı bir `celestiawatch` kullanıcısıyla çalışır. Bu kullanıcı `/root` ve `/home` klasörlerini göremez, yani anahtarlarınıza erişemez. CPU (%20) ve RAM (100 MB) kullanımı da sınırlandırılmıştır.
- **Telegram token'ı korunur.** Token sadece root ve celestiawatch kullanıcısının okuyabildiği bir dosyada tutulur.
- **Gizliliğinizi korur.** Telegram mesajlarında IP veya sunucu adı yer almaz, sadece sizin belirlediğiniz isim görünür. `doctor` raporunda IP adresiniz maskelenir (`65.109.*.*:7980` gibi), raporu gönül rahatlığıyla paylaşabilirsiniz.
- **Tamamen kaldırılabilir.** `sudo celestiawatch uninstall` her şeyi siler, node'unuza hiçbir şey olmaz.

## Neleri Kontrol Eder

| Kontrol | Uyarı ne zaman gelir |
|---|---|
| Node RPC | Yanıt vermezse |
| Senkron | catching_up: true olursa |
| Blok ilerlemesi | 3 dakika boyunca blok yüksekliği değişmezse |
| Kaçırılan blok | Bir kontrolde 5 veya daha fazla blok imzalanmazsa |
| Aktif set | Validator aktif setten düşerse (jail veya unbond) |
| Peer sayısı | 3'ün altına düşerse |
| celestia-appd / Fibre / Bridge servisi | Çalışmazsa |
| Fibre portu (7980) | Fibre çalışıyor ama port dinlenmiyorsa |
| Hassas portlar (9090, 26669, 26657, 26658, 1317) | Dışarıya açık olursa |
| Disk | %85'i geçerse |
| Saat (NTP) | Senkron değilse |

- Sorun çıktığında 🔴, düzeldiğinde 🟢 mesajı gelir. Devam eden sorunlar her saat hatırlatılır.
- Her sabah 09:00'dan sonra kısa bir durum özeti gelir (ayarlardan değiştirilebilir veya kapatılabilir).
- Fibre ve Bridge servisleri adları farklı olsa bile (`fibre`, `fibre-mocha5`, `celestia-bridge` gibi) kurulumda otomatik bulunur. Sadece etkin veya çalışan servisler izlenir, eski kurulumlardan kalan kullanılmayan servis dosyaları uyarı üretmez.

`doctor` komutu bunlara ek olarak şunları da kontrol eder:
- Sürümünüz ağdaki (mainnet veya mocha) en güncel sürüm mü?
- Zincire kayıtlı Fibre adresiniz (set-host) bu sunucuyu mu gösteriyor?
- bbr aktif mi?

## Örnek Çıktılar

### Telegram Durum Mesajı
```
[Nako-Mocha] 📊 Durum
Ağ: mocha-5 | Blok: 2157414 | Senkron: evet
Peer: 13 | Oy gücü: 21105026 (aktif sette) | app v10
celestia-appd: çalışıyor
fibre-mocha5: çalışıyor (7980 dinleniyor)
Disk /: %50
Hassas portlar: kapalı (sadece 127.0.0.1)
```

### Telegram Uyarı Mesajları
```
[Nako-Mocha] 🔴 Son kontrolde 30 bloktan 6 tanesi kaçırıldı.
[Nako-Mocha] 🟢 Düzeldi: Son kontrolde 30 bloktan 6 tanesi kaçırıldı.
```

### doctor Raporu
```
Node
  ✔ RPC yanıt veriyor (http://127.0.0.1:26657)
  - Ağ: mocha-5 | Blok: 2157449 | Peer: 13
  ✔ Senkron
  ✔ app_version 10 (Fibre destekli)
  ✔ Aktif sette, oy gücü 21105026

Servisler
  ✔ celestia-appd çalışıyor
  ✔ fibre-mocha5 çalışıyor

Sürümler
  - celestia-appd: 10.5.0-mocha
  - fibre: version: 10.5.0-mocha
  ✔ En güncel sürüm kullanılıyor (v10.5.0-mocha)

Fibre
  ✔ 7980 portu dinleniyor
  ✔ Zincirde kayıtlı Fibre adresi: 65.109.*.*:7980
  ✔ Kayıtlı adres bu sunucuyu gösteriyor

Güvenlik
  ✔ 9090 / 26669 / 26657 / 26658 / 1317 dışarı kapalı
  ✔ Saat senkron (NTP)
  ✔ bbr aktif

Disk
  ✔ / %50 dolu
```

## Kurulum

### 1. Telegram Botu Oluşturmak
- Telegram'da **@BotFather**'a yazın, `/newbot` komutuyla bir bot oluşturun ve verdiği **token**'ı kaydedin.
- Oluşturduğunuz bota mutlaka bir kez `/start` yazın. Yazmazsanız bot size mesaj gönderemez.
- **@userinfobot**'a yazın, size söylediği **Id** numarası sizin Chat ID'nizdir.

### 2. Aracı Kurmak
- Validator sunucunuzda çalıştırın. Token, Chat ID ve mesajlarda görünecek ismi soracak.
- İsim kısmına IP veya şehir yazmayın. Birden fazla sunucunuz varsa `Nako-Mainnet`, `Nako-Mocha` gibi ayırt edici isimler verin.
```
curl -s https://raw.githubusercontent.com/okannako/celestiawatchtr/refs/heads/main/celestiawatchtr.sh > celestiawatchtr.sh && chmod +x celestiawatchtr.sh && sudo ./celestiawatchtr.sh install
```

- Kurulum bitince Telegram'a bir deneme mesajı gelir.

### Güncellemek
- Aynı kurulum komutunu tekrar çalıştırın. Ayarlarınız korunur, soru sormadan sadece araç güncellenir.

## Kullanım

### Ayrıntılı Kontrol Raporu
```
sudo celestiawatch doctor
```

### Anlık Durum
```
celestiawatch status
```

### Telegram'a Deneme Mesajı
```
sudo celestiawatch test
```

### Ayarları Değiştirmek
- Eşik değerleri, mesajlardaki isim (`NODE_LABEL`), günlük rapor saati (`DAILY_REPORT_HOUR`, kapatmak için boş bırakın) gibi ayarlar bu dosyadadır. Kaydettikten sonra başka bir şey yapmanıza gerek yoktur.
```
sudo nano /etc/celestiawatch/config.env
```

### Uyarıları Denemek
- Node'unuza dokunmadan uyarı sistemini denemek için disk eşiğini geçici olarak düşürün. 1 dakika içinde 🔴 mesajı gelir.
```
sudo sed -i 's/^DISK_ALERT_PERCENT=.*/DISK_ALERT_PERCENT=10/' /etc/celestiawatch/config.env
```

- Eski haline getirin. 1 dakika içinde 🟢 Düzeldi mesajı gelir.
```
sudo sed -i 's/^DISK_ALERT_PERCENT=.*/DISK_ALERT_PERCENT=85/' /etc/celestiawatch/config.env
```

### Kayıtları Görmek
```
journalctl -u celestiawatch -f
```

### Kaldırmak
```
sudo celestiawatch uninstall
```

## Sorun Giderme

- **Telegram mesajı gelmiyor:** `journalctl -u celestiawatch -n 20 --no-pager` komutuyla kayıtlara bakın. Sebep orada yazar:
  - Token hatalı
  - Chat ID hatalı veya bota `/start` yazılmamış
  - İnternet/DNS sorunu
  
  Düzeltmek için `sudo nano /etc/celestiawatch/config.env` dosyasını düzenleyip `sudo celestiawatch test` ile tekrar deneyin.
- **Fibre bölümü raporda görünmüyor:** `doctor` raporu servis adını bulursa düzeltme komutunu da yazar. Bulamazsa config.env içinde `FIBRE_SERVICE="servis-adiniz"` satırını kendiniz düzenleyin.
- **"Zincirde Fibre adresi bulunamadı":** `celestia-appd tx valaddr set-host` adımı yapılmamış olabilir.

## Notlar

- Fibre portunun dışarıdan erişilebilir olup olmadığını sunucunun kendisi ölçemez. Bunu kendi bilgisayarınızdan deneyin:
  - Linux/Mac: `nc -vz SUNUCU_IP 7980`
  - Windows PowerShell: `Test-NetConnection SUNUCU_IP -Port 7980` (sonuç `TcpTestSucceeded : True` olmalı)
- Gereksinimler: Ubuntu 22.04 veya 24.04, `curl`, `jq`, `iproute2`. Eksik olanları kurulum kendisi yükler.
