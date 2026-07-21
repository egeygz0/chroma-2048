# Neon Merge 2048 v5.1 — Kurulum ve Rehber

## v5.1'de Yeni: Ayarlar Paneli ve Ses Kontrolü

Sağ altta ⚙ butonu; tıklayınca tam ekran ayarlar paneli açılır.

- **Ses kontrolü:** master seviye kaydırıcısı (0-100%) + MUTE ALL düğmesi, ayrıca **her ses için ayrı ON/OFF anahtarı** (Slide, Merge, Celebration, Shop purchase, Game over, Daily bonus). Kapatılan ses hiç çalmaz; MUTE ALL açıkken anahtarlar soluk görünür (etkisiz oldukları belli olsun).
- **Veri sıfırlama** artık burada (mağazadan taşındı): çift onaylı `RESET ALL DATA`.
- Tercih **sunucuda kalıcı** saklanır (`sfx`, `muted`), oturumlar arası taşınır ve veri sıfırlamada korunur (ses ayarı ilerleme değildir).
- Kaydırıcı bırakılınca tek istek gönderilir, sürüklerken istek seli olmaz.
- Panel açıkken hamleler kilitlidir ve panel altındaki butonlara tıklama sızmaz.

### Ses asset ID'leri

Dosyanın başındaki `SOUND_IDS` tablosuna ID'leri yapıştır, `0` bırakılan ses hiç oluşturulmaz:

| Anahtar | Ne zaman çalar |
|---|---|
| `move` | Kaydırma (birleştirme olmayan geçerli hamle) |
| `merge` | Birleştirme |
| `milestone` | Kutlama (2048 / 4096 / 8192) |
| `buy` | Mağazada satın alma |
| `gameOver` | Kaybetme |
| `daily` | Günlük ödül |

`SOUND_VOLUME` (varsayılan 0.5) %100 seviyedeki tavan şiddettir; kaydırıcı bunun yüzdesini uygular.

# Neon Merge 2048 v5

## v5'te Yeni: Monetizasyon, Görsel Efektler, Sel Koruması, UX

### Monetizasyon kurulumu (MarketplaceService)

Ürünleri [create.roblox.com](https://create.roblox.com) > Creations > oyunun > Monetization altında oluştur, sayısal ID'leri **iki dosyada birden** dosya başındaki sabitlere yapıştır. `0` bırakılan ürün mağazada görünmez, oyun normal çalışır.

| Sabit | Tür | Etkisi |
|---|---|---|
| `GAMEPASS_2X_COINS` | Gamepass | Tur sonu coin ödülü kalıcı 2 kat |
| `PRODUCT_COINS_1K` / `5K` / `15K` | Developer Product | Anında +1.000 / +5.000 / +15.000 coin |
| `PRODUCT_THEME_NEON` / `SUNSET` | Developer Product | Temayı Robux ile açar (coin alternatifi) |

- Gamepass sahipliği girişte önbelleklenir, oyun içi satın almada anında aktifleşir.
- `ProcessReceipt` makbuzları `PurchaseId` ile tekilleştirir (son 40 kayıtta tutulur); oturum hazır değilse veya kayıt yazılamazsa `NotProcessedYet` döner, satın alma kaybolmaz. Sunucuda tanımlı olmayan ürün ID'si de `NotProcessedYet` döner ki Robux karşılıksız yanmasın.
- Veri sıfırlama (`RESET ALL DATA`) Robux ile alınmış hakları korur: gamepass, makbuz geçmişi ve Robux'la açılmış temalar geri verilir; coin ile alınanlar sıfırlanır.

**Mağaza sekmeleri:** SHOP modalı TOP 10'daki gibi iki alt sekmeye ayrılır:

| Sekme | İçerik |
|---|---|
| COIN | Coin ile alınan yükseltmeler ve tahta boyutu seçimi |
| ROBUX | Coin paketleri, VIP 2x Coins pass'i (sahipse "OWNED"), Robux ile açılan temalar |

ROBUX sekmesinde tanımlı ürün yoksa (tüm ID'ler `0`) "No Robux items available yet" yazar.

### Diğer

- **Görsel efektler:** 512+ birleştirmede tahtaya 0.12 sn'lik sarsıntı; kilometre taşı ve günlük ödülde konfeti patlaması + tahta çerçevesinin parlaması.
- **NM_Act sel koruması:** oyuncu başına `SERVER_ACT_DEBOUNCE = 0.15` sn; sınır aşılırsa durum ve DataStore mantığına hiç girilmeden `{ ok = false, err = "too_fast" }` döner. Zaman damgaları `PlayerRemoving`'de temizlenir.
- **Autosave göstergesi:** sunucu kaydı başarıyla yazınca sağ altta 1.5 sn "💾 Saving..." belirip söner.
- **İlk oyun ipucu:** hiç skoru ve coini olmayan oyuncuya tahtanın üstünde yüzen ipucu; ilk geçerli hamlede kalıcı olarak kaybolur.

# Neon Merge 2048 v4

## v4'te Yeni

- **Günlük ödül:** günde bir kez alınır, art arda günlerde seri büyür (50 coin taban, gün başına +25, 7. günde tavan 200). Sunucu UTC gün numarasıyla doğrular, çift alım mümkün değil.
- **Kilometre taşları:** 2048'den sonra 4096, 8192... her yeni eşik bir kez kutlanır (önceden yalnızca 2048 vardı). Continue ile tur sürer.
- **Kozmetik temalar:** Neon (1500 coin) ve Sunset (2500 coin) mağazadan açılır; tema butonu açık temalar arasında döner. Light/Dark herkeste açık.
- **Veri sıfırlama:** SHOP'un altında çift onaylı `RESET ALL DATA`. Coin, best, upgrade ve tur sıfırlanır; oyuncu her iki leaderboard'dan da düşer.
- **Mobil/dar ekran düzeni:** header butonları ve başlık genişliğe göre küçülür, 330px altında TOP 10 kısalır. Ekran boyutu değişince otomatik yeniden hesaplanır.
- **Hamle paketleme:** ilk hamle anında gider, 0.2 sn penceresindeki arka arkaya hamleler tek pakette birleşir. Sunucuda token bucket hız sınırı (15/sn, 30 burst) ve paket başına en fazla 8 hamle.
- **Ses altyapısı:** dosyanın başındaki `SOUND_IDS` tablosuna asset ID yapıştırılınca ilgili ses çalar (`move`, `merge`, `buy`, `gameOver`, `milestone`, `daily`). `0` bırakılan ses çalmaz, hata vermez.

# Neon Merge 2048 v3.3

## v3.3'te Yeni: Veri Kaybı Koruması + Hızlı Açılış

- **Kritik düzeltme, DataStore hatasında veri kaybı:** Önceden `GetAsync` başarısız olursa (`502 / InternalServerError`) sunucu oyuncuyu sıfırdan başlamış sayıyor, sonra otomatik kayıt bu boş veriyi **gerçek kaydın üstüne yazıyordu**. Artık yükleme başarısızsa oturum "yüklendi" sayılmaz: o oyuncu için **hiçbir yazma yapılmaz**, arka planda kademeli aralıklarla (5/10/20/30 sn) tekrar denenir, erişim gelince kaldığı yerden devam eder.
- **Hızlı açılış:** yükleme denemeleri 1/2/3 sn yerine 0.2/1 sn ile başlar, sunucu bekleme süresi 15 sn'den 3 sn'ye indi (istemci zaten yeniden deniyor), Roblox'un varsayılan yükleme ekranı kaldırılır (3D dünya beklenmez).
- **Görünür yükleme durumu:** kayıt gelene kadar tahtanın üstünde "Loading..." katmanı; 4 saniyeyi geçerse "Save server unavailable / Retrying..." yazar. Oyuncu boş tahtaya bakıp donmuş sanmaz.

## v3.2'de Yeni: Zengin Leaderboard + Kayıt Sağlık Kontrolü

- **TOP 10 iki alt sekmeli:** SCORE (skor sıralaması, OrderedDataStore `NeonMerge2048Top_v1`) ve BLOCK (en yüksek blok sıralaması, `NeonMerge2048TopTile_v1`). Her sekme **yalnızca kendi metriğini** gösterir: PLAYER + SCORE ya da PLAYER + BLOCK. Liste sekme açık kaldıkça ~2.5 dakikada bir otomatik yenilenir (sunucu önbelleği de 150 sn).
- **Kendi sıralaman:** TOP 10'un altında sabit bar, iki alan: RANK (aktif sekmenin ilk 100'ünde isen #N, değilsen 100+) ve aktif sekmenin metriği (SCORE ya da BLOCK). En yüksek tile `bestTile` alanıyla kayda işlenir.
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
| Bigger Board | 2 | 5000 / 20000 | Sv1 5x5, Sv2 6x6 açar; mağazadan boyut seçilir (seçim yeni tur başlatır) |

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
