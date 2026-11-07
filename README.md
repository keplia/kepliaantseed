# antseed-fleet

Jalankan banyak instance Antseed gateway independen di satu VPS, masing-masing dengan domain sendiri via Cloudflare Tunnel.

## ⚡ Install tercepat — satu perintah

Di VPS (Ubuntu/Debian, root):

```bash
curl -fsSL https://raw.githubusercontent.com/keplia/kepliaantseed/main/get.sh | sudo bash
```

Script akan menuntun 4 langkah:

1. **Token Cloudflare** — ditempel, tidak ditampilkan di layar.
2. **Domain** — semua domain (zone) di akun kamu dideteksi otomatis, tinggal pilih nomornya.
3. **Nama** — misalnya `api` → hasilnya `api1.domainmu.com`, `api2.domainmu.com`, dst.
4. **Jumlah** — script mendeteksi spek VPS (CPU, RAM total/tersedia, disk) dan menampilkan tabel rekomendasi yang **menandai baris spek VPS kamu**, plus berapa instance yang masih bisa dibuat **saat ini**. Tinggal masukkan angka (Enter = rekomendasi).

Contoh tampilan:

```
    #    DOMAIN                             STATUS
    1    aitesh.tech                        active
    2    seaku.dev                          active

  Which domain [2]: 2
  Name for the instances (letters, digits, dash) [api]: api
    Domain         seaku.dev
    Name           api
    1st host       https://api1.seaku.dev
    then           https://api2.seaku.dev, https://api3.seaku.dev, ...
```

```
    RAM VPS   BUDGET           FITS      MARK
    2 GB      900 MiB          1
    4 GB      900 MiB          3
    8 GB      900 MiB          7
    16 GB     900 MiB          17        <- this VPS
    32 GB     900 MiB          35
    now       free RAM         11        <- can be created right now
```

Instance yang sudah ada ikut dihitung: nomor nama dilanjutkan otomatis (`api7`, `api8`, …) dan memori yang sedang terpakai diperhitungkan.

Butuh terminal interaktif (script membaca jawaban dari `/dev/tty`). Kalau tidak ada terminal sama sekali, script berhenti dengan pesan jelas dan memberi perintah yang harus dipakai — tidak pernah lanjut diam-diam tanpa token.

Non-interaktif (cloud-init / CI):

```bash
curl -fsSL https://raw.githubusercontent.com/keplia/kepliaantseed/main/get.sh \
  | sudo bash -s -- --token 'cf_...' --domain seaku.dev --name api --count 2 --yes
```

Atau clone lalu jalankan:

```bash
git clone https://github.com/keplia/kepliaantseed && cd kepliaantseed
sudo bash install.sh
```

## Isi repository

| File | Fungsi |
|---|---|
| `install.sh` | Installer interaktif (token, pilih domain, nama, rekomendasi jumlah) |
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

Account Resources: akun kamu · Zone Resources: **All zones from an account** (supaya semua domain bisa dipilih).
Token hanya dipakai saat create dan tidak disimpan ke disk — boleh di-revoke setelah selesai.

## Rekomendasi kapasitas

900 MiB per instance (buyer ±500 MiB + gateway ±300 MiB), 1 GiB disisakan untuk OS:

| RAM VPS | Instance |
|---|---|
| 1 GB | 1 |
| 2 GB | 1 |
| 3 GB | 2 |
| 4 GB | 3 |
| 6 GB | 5 |
| 8 GB | 7 |
| 12 GB | 12 |
| 16 GB | 17 |
| 24 GB | 26 |
| 32 GB | 35 |
| 48 GB | 53 |
| 64 GB | 71 |

Bisa diubah lewat `ANTSEED_MEM_PER_INSTANCE_MIB` (budget per instance) dan `ANTSEED_MEM_RESERVE_MIB` (cadangan untuk OS). Disk juga dicek (±400 MiB per instance).

## Tambah instance lagi

Jalankan perintah yang sama — ia mendeteksi instance yang sudah ada dan melanjutkan penomoran:

```bash
sudo bash /opt/antseed-fleet/install.sh
```

Untuk menaruh instance baru di domain lain, cukup pilih domain yang berbeda saat diminta.

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
- Setiap instance memakai subdomain sendiri (`api1.…`, `api2.…`). Satu CNAME per instance di Cloudflare.
- Instance installer (`antseed-gateway`/`antseed-buyer`, port 8377/8379) tidak pernah disentuh.
- Port dialokasikan otomatis (8381 ke atas), semua listen di `127.0.0.1` di belakang tunnel.
- Backup: `/var/lib/antseedN/.antseed/` (wallet) dan `/etc/antseedN/gateway.env` (tunnel token).
- `remove` sengaja menyimpan data supaya dana wallet tidak hilang.
