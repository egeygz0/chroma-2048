# Neon Merge 2048 v3.2 — Kurulum ve Rehber

## v3.2'de Yeni: Zengin Leaderboard + Kayıt Sağlık Kontrolü

- **TOP 10 üç kolonlu:** PLAYER / SCORE / BLOCK (oyuncunun ulaştığı en yüksek tile, örn. 256/512). En yüksek tile `bestTile` alanıyla kayda işlenir.
- **Kendi sıralaman:** TOP 10 sekmesinin altında sabit bar: RANK (ilk 100 içindeysen #N, değilsen 100+), BEST, BLOCK.
- **DataStore sağlık kontrolü:** sunucu açılışında DataStore erişimi test edilir; erişilemiyorsa konsola büyük uyarı yazılır (kayıt sıfırlanıyor şikayetlerinin bir numaralı nedeni: oyun yayınlanmamış veya "Enable Studio Access to API Services" kapalı).

## v3.1'de Yeni: Temiz 2D Sahne + Modern UI Derinliği

- **3D karakter tamamen kapalı:** sunucuda `Players.CharacterAutoSpawn = false` + doğan karakter anında kaldırılır; istemcide kamera `Scriptable` kilitlenir. Oyun saf 2D ekran.
- **UI derinliği:** board, mağaza modalı, stat kutuları ve header butonlarına tema uyumlu ince `UIStroke` (Light `#D0D0D0`, Dark `#3A3A40`, kalınlık 1.5); tema geçişinde stroke da tween'lenir.
- **Coin ikonu:** HUD ve mağaza fiyat butonlarındaki emoji yerine altın daire + "$" ikonu (asset bağımsız).
- **Büyük header:** başlık 24pt, üst bar 54px, butonlar 44px yükseklik; sağ küme sırası UNDO / NEW / SHOP / TOP 10 / tema. SHOP ve TOP 10 modali kendi sekmesinde açar, açık sekmenin adı modalda ortada yazar; mağaza fiyatları pill butonlarda (alınabilir: mavi, değil: koyu gri).

## Kurulum

1. Roblox Studio'da yerini aç (Baseplate yeterli).
2. **StarterPlayer > StarterPlayerScripts** içine bir **LocalScript** ekle, içeriğini `MainGame.client.lua` ile tamamen değiştir.
3. **ServerScriptService** içine bir **Script** ekle, içeriğini `Server.server.lua` ile değiştir (oyun otoritesi ve kayıt burada; bu betik olmadan istemci `NM_GetData` beklerken takılır).
4. **Play** (F5).

## v3'te Yeni: SUNUCU-OTORİTER ÇEKİRDEK + COIN EKONOMİSİ

- **Oyun mantığı artık sunucuda simüle edilir.** İstemci yalnızca hamle yönü gönderir (`NM_Move`); slide/merge/spawn/skor/coin sunucuda işlenir. İstemci aynı simülasyonu görsel için lokal oynatır; spawn deterministiktir (`Random.new(seed + spawnIndex * 7919)`), iki taraf aynı seed ve sayaçla aynı sonucu üretir. Exploiter'ın skor/coin beyan etme yolu yoktur.
- **Coin sistemi:** tur bitince (game over veya elle yeni oyun) `coin = floor(skor/200) + en yüksek tile bonusu` (256:+10, 512:+25, 1024:+60, 2048:+150, 4096:+400), Coin Rush çarpanıyla ölçeklenir. Ödülü sunucu hesaplar.
- **Mağaza (SHOP butonu):** fiyatlar seviye başına ~2.5x katlanır:

| Upgrade | Maks | Fiyatlar | Etki |
|---|---|---|---|
| Lucky Spawns | 5 | 75/190/470/1200/3000 | 4 gelme şansı +%10/sv; sv4+ 8 şansı (%5/sv) |
| Head Start | 3 | 250/750/2250 | Her tur 8/16/32'lik hazır tile ile başlar |
| Undo | 3 | 150/450/1350 | Tur başına +1 geri alma hakkı |
| Coin Rush | 4 | 300/900/2700/8100 | Coin kazancı +%25/sv |
| 5x5 Board | 1 | 5000 | 5x5 tahta kilidi; mağazadan 4x4/5x5 geçişi (geçiş yeni tur başlatır) |

- **Undo:** UNDO butonu (hak varsa görünür), son hamleyi sunucudan geri alır (tek adım, spawn dahil).
- **Mobil destek:** dokunmatik swipe ile oynanır (`TouchSwipe`).
- **Kayma animasyonu:** tile'lar ghost kopyalarla hedefe kayar (0.09 sn), merge/spawn'da pop.
- **2048 kutlaması:** ilk 2048'de "2048!" ekranı, Continue ile devam / New Game.
- **Global leaderboard:** OrderedDataStore top 10 (SHOP > TOP 10 sekmesi, sunucuda 60 sn önbellek).
- **NEW butonu:** turu istediğin an bitirir; skorun coin'e çevrilir, yeni tur başlar.

## Protokol (v3)

| Remote | Tür | Yön | İş |
|---|---|---|---|
| `NM_GetData` | RemoteFunction | C→S | Giriş: tam durum (coins, best, tema, upgrade'ler, run) |
| `NM_Move` | RemoteEvent | C→S | Hamle yönü; sunucu simüle eder |
| `NM_Act` | RemoteFunction | C→S | `new` / `grid` / `undo` / `buy` / `theme` / `top` |
| `NM_Sync` | RemoteEvent | S→C | `over` (coin ödülü) / `win` / `resync` (uyumsuzlukta tam durum) |

`CORE SIM` bloğu iki dosyada birebir aynıdır; birinde değiştirirsen diğerinde de değiştir, yoksa görsel ile sunucu durumu ayrışır.

## Kayıt Sistemi (Database) Nasıl Çalışır?

Roblox'ta "database" = **DataStoreService**. Kurulumu:

1. **File > Publish to Roblox** ile oyunu yayınla (yayınlanmamış yerlerde DataStore çalışmaz).
2. **Home > Game Settings > Security > "Enable Studio Access to API Services"** seçeneğini aç (Studio'da test ederken kayıt için şart).

- Kayıt tamamen sunucudadır: her **30 saniyede bir** (değiştiyse), **çıkışta** ve **kapanışta zorla** (`UpdateAsync` + 3 deneme, oyuncu başına en az 6 sn aralık).
- Kayıt anahtarı: `NeonMerge2048Save_v1` / `u_<UserId>`, `schema=2`. v2 dönemi eski kayıtlar (düz board/score/best/theme) otomatik migrate edilir. Yapıyı bozacak değişiklikte `_v2`/`schema=3` yap.
- Kaydedilen: `coins`, `best`, `theme`, `up` (upgrade seviyeleri), `run` (board, score, seed, spawns, size, undoLeft, won, over). Yarım kalan tur girişte aynen devam eder.
- Leaderboard: OrderedDataStore `NeonMerge2048Top_v1`, değer = best; tur sonunda ve çıkışta best arttıysa yazılır.

## Oynanış ve Kontroller

| Girdi | İşlev |
|---|---|
| W/A/S/D veya ok tuşları | Kaydır |
| Swipe (mobil) | Kaydır |
| UNDO | Son hamleyi geri al (hak varsa) |
| NEW | Turu bitir (coin kazan), yeni tur |
| SHOP | Mağaza |
| TOP 10 | Global leaderboard |
| 🌙 / ☀️ | Light ↔ Dark tema (kaydedilir) |

## Temalar

| | Light | Dark |
|---|---|---|
| Ekran arka planı | `#FFFFFF` | `#121212` |
| Oyun kutusu | `#FFFFFF` | `#2A2A2A` |
| Boş hücreler | `#E0E0E0` | `#EAE6DF` |

## Tile Paleti

2→`#FFD700`, 4→`#FF8C00`, 8→`#FF4500`, 16→`#FF1493`, 32→`#00E676`, 64→`#00E5FF`, 128→`#2979FF`, 256→`#AA00FF`, 512→`#F50057`, 1024→`#FFAB00`, 2048+→dinamik neon hue döngüsü. Metin rengi parlaklığa göre otomatik.

## v2

- Kalıcı kayıt (DataStore), SCORE/BEST kutuları, sunucu doğrulamalı kayıt.

## v1

- Programatik UI, light/dark tema, canlı tile paleti, pop-in animasyonları, WASD + ok, game-over + restart.
