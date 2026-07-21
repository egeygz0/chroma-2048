# Neon Merge 2048

Canlı renkli, light/dark temalı 2D 2048 Roblox oyunu (Luau). Tüm arayüz LocalScript tarafından runtime'da üretilir, Studio'da elle UI kurulumu gerekmez. Oyun mantığı **sunucu-otoriterdir** (istemci yalnızca hamle yönü gönderir); tur bitince skor coin'e çevrilir, coin'le upgrade alınır (Lucky Spawns, Head Start, Undo, Coin Rush, 5x5 tahta). Mobil swipe, kayma animasyonu, 2048 kutlaması ve global top 10 leaderboard vardır. Oyuncu verisi (coin, best, upgrade'ler, yarım kalan tur, tema) DataStore ile kalıcıdır: çıkıp giren kaldığı yerden devam eder.

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
