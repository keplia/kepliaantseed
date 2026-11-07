# antseed-fleet

Satu perintah untuk menjalankan banyak instance Antseed gateway independen di satu VPS, masing-masing dengan domain sendiri via Cloudflare Tunnel.

```bash
sudo bash install.sh
```

Script akan menanyakan **token Cloudflare**, **domain**, menampilkan **rekomendasi jumlah instance** sesuai RAM VPS, lalu meminta **berapa yang mau dibuat**.

## Isi repository

| File | Fungsi |
|---|---|
| `install.sh` | Installer interaktif (token, domain, rekomendasi, jumlah) |
| `antseed-fleet` | CLI manajemen (`list`, `status`, `link`, `logs`, `remove`, …) |
| `get.sh` | Pintu masuk satu perintah `curl \| sudo bash` |
| `README.md` | Panduan lengkap |

## Install

```bash
git clone <repo> && cd antseed-fleet
sudo bash install.sh
```

atau tanpa clone:

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/get.sh | sudo bash
```

Non-interaktif:

```bash
sudo bash install.sh --token 'cf_...' --domain example.com --count 2 --yes
```

## Token Cloudflare

Buat di <https://dash.cloudflare.com/profile/api-tokens> → **Create Token** → **Create Custom Token**:

| Scope | Resource | Level |
|---|---|---|
| Account | Cloudflare Tunnel | Edit |
| Account | Account Settings | Read |
| Zone | DNS | Edit |
| Zone | Zone | Read |

Token hanya dipakai saat create dan tidak disimpan ke disk.

## Rekomendasi kapasitas

900 MiB per instance (buyer ±500 + gateway ±300), 1 GiB untuk OS:

| RAM VPS | Instance |
|---|---|
| 2 GB | 1 |
| 4 GB | 3 |
| 8 GB | 7 |
| 16 GB | 15 |
| 32 GB | 33 |

## Isi paket

- `antseed-fleet.tar.gz` — arsip lengkap (install.sh, antseed-fleet, get.sh, README.md) untuk backup.

## Kelola

```bash
antseed-fleet list
antseed-fleet status
antseed-fleet link antseed1
antseed-fleet logs antseed1 -f
antseed-fleet remove antseed1
```
