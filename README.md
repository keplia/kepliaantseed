# antseed-fleet

Jalankan banyak instance Antseed gateway independen di satu VPS, masing-masing dengan domain sendiri via Cloudflare Tunnel.

## ⚡ Install tercepat — satu perintah

Di VPS (Ubuntu/Debian, root):

```bash
curl -fsSL https://raw.githubusercontent.com/keplia/kepliaantseed/main/get.sh | sudo bash
```

Itu saja. Script akan menanyakan:

1. **Cloudflare API token**
2. **domain** (zone, misalnya `seaku.dev`)
3. **rekomendasi jumlah instance** sesuai RAM VPS — lalu kamu **masukkan angkanya**

Hasilnya: `api2.seaku.dev`, `api3.seaku.dev`, `api4.seaku.dev`, … masing-masing dengan API key, wallet, console, dan tunnel sendiri. Kalau Antseed CLI belum ada, dipasang otomatis.

Butuh terminal interaktif (script membaca jawaban dari `/dev/tty`). Kalau tidak ada terminal sama sekali, script berhenti dengan pesan jelas dan memberi perintah yang harus dipakai — tidak pernah lanjut diam-diam tanpa token.

Tanpa interaksi (cloud-init / CI):

```bash
curl -fsSL https://raw.githubusercontent.com/keplia/kepliaantseed/main/get.sh \
  | sudo bash -s -- --token 'cf_...' --domain seaku.dev --count 2 --yes
```

Atau clone lalu jalankan:

```bash
git clone https://github.com/keplia/kepliaantseed && cd kepliaantseed
sudo bash install.sh
```

## Isi repository

| File | Fungsi |
|---|---|
| `install.sh` | Installer interaktif (token, domain, rekomendasi, jumlah) |
| `antseed-fleet` | CLI manajemen (`list`, `status`, `link`, `logs`, `remove`, …) |
| `get.sh` | Pintu masuk satu perintah `curl \| sudo bash` |
| `README.md` | Panduan lengkap |
| `antseed-fleet.tar.gz` | Paket backup (semua file di atas) |

## Token Cloudflare

Buat di <https://dash.cloudflare.com/profile/api-tokens> → **Create Token** → **Create Custom Token**:

| Scope | Resource | Level |
|---|---|---|
| Account | Cloudflare Tunnel | Edit |
| Account | Account Settings | Read |
| Zone | DNS | Edit |
| Zone | Zone | Read |

Account Resources: akun kamu · Zone Resources: zone kamu.
Token hanya dipakai saat create dan tidak disimpan ke disk — boleh di-revoke setelah selesai.

## Rekomendasi kapasitas

900 MiB per instance (buyer ±500 MiB + gateway ±300 MiB), 1 GiB disisakan untuk OS:

| RAM VPS | Instance |
|---|---|
| 2 GB | 1 |
| 4 GB | 3 |
| 8 GB | 7 |
| 16 GB | 15 |
| 32 GB | 33 |

Bisa diubah lewat `ANTSEED_MEM_PER_INSTANCE_MIB` dan `ANTSEED_MEM_RESERVE_MIB`.

## Tambah instance lagi

Jalankan perintah yang sama — ia mendeteksi instance yang sudah ada dan melanjutkan penomoran:

```bash
sudo bash /opt/antseed-fleet/install.sh
```

## Kelola

```bash
antseed-fleet list              # daftar instance, port, memori, host
antseed-fleet status            # health + tes API publik
antseed-fleet link antseed1     # link setup console (1x pakai)
antseed-fleet recover antseed1  # link recovery kalau console sudah diklaim
antseed-fleet keys antseed1 --label laptop
antseed-fleet logs antseed1 -f
antseed-fleet restart|start|stop [NAME]
antseed-fleet remove antseed1   # hapus service, data disimpan
antseed-fleet remove antseed1 --keys
antseed-fleet doctor
```

## Catatan

- Instance terisolasi penuh (API key, wallet, console, saldo terpisah). Model gratis jalan tanpa saldo.
- Instance installer (`antseed-gateway`/`antseed-buyer`, port 8377/8379) tidak pernah disentuh.
- Port dialokasikan otomatis (8381 ke atas), semua listen di `127.0.0.1` di belakang tunnel.
- Backup: `/var/lib/antseedN/.antseed/` (wallet) dan `/etc/antseedN/gateway.env` (tunnel token).
- `remove` sengaja menyimpan data supaya dana wallet tidak hilang.
