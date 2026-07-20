# Neon Merge 2048 v2 — Kurulum ve Rehber

## Kurulum

1. Roblox Studio'da yerini aç (Baseplate yeterli).
2. **StarterPlayer > StarterPlayerScripts** içine bir **LocalScript** ekle, içeriğini `MainGame.client.lua` ile tamamen değiştir.
3. **ServerScriptService** içine bir **Script** ekle, içeriğini `Server.server.lua` ile değiştir (kayıt sistemi burada; bu betik olmadan istemci `NM_GetData` beklerken takılır).
4. **Play** (F5).

## Kayıt Sistemi (Database) Nasıl Çalışır?

Roblox'ta "database" = **DataStoreService**. Kurulumu:

1. **File > Publish to Roblox** ile oyunu yayınla (yayınlanmamış yerlerde DataStore çalışmaz).
2. **Home > Game Settings > Security > "Enable Studio Access to API Services"** seçeneğini aç (Studio'da test ederken kayıt için şart).

Akış:

- Oyuncu girince sunucu kaydı yükler; istemci `NM_GetData` (RemoteFunction) ile çeker. Kayıtta yarım kalmış geçerli bir tahta varsa oyun **kaldığı yerden** devam eder; yoksa temiz başlar (en iyi skor her durumda korunur).
- İstemci her hamlede, restart'ta ve tema değişiminde durumunu `NM_Save` (RemoteEvent) ile gönderir. Sunucu gelen veriyi **doğrular** (tahta 4x4 ve tüm değerler 2'nin kuvveti, skor 4M tavanlı, tema yalnızca Light/Dark) ve bellekte tutar; en iyi skoru sunucu hesaplar.
- DataStore yazımı: her **30 saniyede bir** (veri değiştiyse), **çıkışta** ve **sunucu kapanışında zorla** (`UpdateAsync` + 3 deneme; oyuncu başına yazımlar arası en az 6 sn).
- İlk yükleme bitmeden istemci hiçbir kayıt göndermez (boş durumun eski kaydın üstüne yazma riski kapalı).

Kayıt anahtarı: `NeonMerge2048Save_v1` / `u_<UserId>`. Kayıt yapısını bozacak bir değişiklik yaparsan `_v2` yap ki eski kayıtlar yanlış yüklenmesin.

Kaydedilen alanlar: `board` (4x4 tahta veya nil), `score`, `best`, `theme`.

## Oynanış ve Kontroller

| Girdi | İşlev |
|---|---|
| W / Yukarı ok | Yukarı kaydır |
| S / Aşağı ok | Aşağı kaydır |
| A / Sol ok | Sola kaydır |
| D / Sağ ok | Sağa kaydır |
| 🌙 / ☀️ butonu | Light ↔ Dark tema (tercih kaydedilir) |
| Restart butonu | Oyun bittiğinde yeni oyun (best korunur) |

## Temalar

| | Light | Dark |
|---|---|---|
| Ekran arka planı | `#FFFFFF` | `#121212` |
| Oyun kutusu | `#FFFFFF` | `#2A2A2A` |
| Boş hücreler | `#E0E0E0` | `#EAE6DF` |

Tema geçişleri TweenService ile 0.35 sn'de yumuşak yapılır.

## Tile Paleti

2→`#FFD700`, 4→`#FF8C00`, 8→`#FF4500`, 16→`#FF1493`, 32→`#00E676`, 64→`#00E5FF`, 128→`#2979FF`, 256→`#AA00FF`, 512→`#F50057`, 1024→`#FFAB00`, 2048+→dinamik neon hue döngüsü (Heartbeat). Metin rengi parlaklığa göre otomatik seçilir (koyu gri / beyaz).

## Mimari Notlar

- **Tek dosya istemci**: UI (UICorner'lı board + hücreler + header + game-over katmanı), tema yöneticisi, oyun çekirdeği (4x4 matris, slide/merge/spawn), giriş (debounce'lu WASD + ok) ve animasyonlar (UIScale pop-in 0.8 → 1.05 → 1.0) tek LocalScript'te bölümlenmiş durumda.
- **Sunucu yalnızca kayıt otoritesi**: oyun mantığı istemcide çalışır (tek kişilik puzzle, rekabetçi ekonomi yok); sunucu gelen veriyi şema ve tavan kontrolünden geçirir. Global leaderboard eklenecekse skor üretimi sunucuya taşınmalı.
- İstemci ve sunucu betiği protokol üzerinden bağlıdır (`NM_GetData`, `NM_Save`); güncellerken **ikisini birlikte** değiştir.

## v2'de Yeni

- **Kalıcı kayıt (DataStore)**: skor, en iyi skor, yarım kalan tahta ve tema tercihi oturumlar arası taşınır; çıkıp giren oyuncu sıfırdan başlamaz.
- Header'a **SCORE / BEST** kutuları eklendi.
- Sunucu betiği eklendi: doğrulama, otomatik kayıt (30 sn), çıkış/kapanış kaydı.

## v1

- Programatik UI, light/dark tema, canlı tile paleti, pop-in animasyonları, WASD + ok kontrolleri, game-over + restart.
