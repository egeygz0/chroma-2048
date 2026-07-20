# Chroma 2048

Canlı renkli, light/dark temalı 2D 2048 Roblox oyunu (Luau). Tüm arayüz LocalScript tarafından runtime'da üretilir, Studio'da elle UI kurulumu gerekmez. Oyuncu verisi (skor, en iyi skor, yarım kalan tahta, tema tercihi) DataStore ile kalıcı kaydedilir: oyuncu çıkıp girince kaldığı yerden devam eder.

## Dosyalar

| Dosya | Nereye |
|---|---|
| `extracted/MainGame.client.lua` | StarterPlayer → StarterPlayerScripts → LocalScript |
| `extracted/Server.server.lua` | ServerScriptService → Script |
| `extracted/KURULUM.md` | Kurulum ve teknik rehber |

## Kurulum (yeni PC)

1. Repoyu klonla: `git clone https://github.com/egeygz0/chroma-2048.git`
2. Roblox Studio'da yeri aç, iki betiği yukarıdaki tabloya göre yapıştır (ikisini **birlikte** güncelle; sunucu betiği olmadan kayıt çalışmaz).
3. Kayıt için: File → Publish to Roblox, sonra Game Settings → Security → "Enable Studio Access to API Services" aç.

Ayrıntılar için `extracted/KURULUM.md` dosyasına bak.
