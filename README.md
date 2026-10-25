# Veil — мессенджер, устойчивый к блокировкам

Прототип v0.1. macOS-клиент (SwiftUI) + relay-нода (Python). Сквозное
шифрование на каждом устройстве; relay-серверы видят только зашифрованные
конверты и не могут прочитать переписку. Проект экспериментальный: не
используйте его для связи, от которой зависит чья-то безопасность, пока
не будет независимого аудита.

```
┌────────────┐   HTTPS/WebSocket (выглядит как обычный веб-сайт)
│  Alice Mac │ ──────────────┐
│  (Veil.app)│               ▼
└────────────┘        ┌──────────────┐        ┌───────────────────┐
                      │  Relay-нода  │◄───────│  Bob Windows      │
                      │ (veil_relay) │  WS push│  (python-клиент)  │
                      │  только E2E- │        └───────────────────┘
                      │  шифротекст  │
                      └──────────────┘
```

Клиенты межплатформенные: macOS (SwiftUI) и Windows/Linux (python+tkinter)
говорят на одном протоколе и понимают резервные копии личностей друг друга.

## Почему это устойчиво к блокировкам

- **Нет центрального сервера.** Любой человек может поднять relay-ноду
  за пару минут на дешёвом VPS; клиент работает с любым числом relay.
- **Трафик — обычный HTTPS/WebSocket.** REST-эндпоинты и WS на 443-м
  порту не отличаются на уровне DPI от веб-приложения; корневая страница
  relay — нейтральный «блог» (`--decoy-file`, чтобы заменить своим сайтом).
- **Префикс путей.** API можно спрятать под `/blog/wp-content/...`
  (`--path-prefix`) и замаскировать под существующий сайт.
- **Cloudflare перед relay.** Caddy берёт бесплатный TLS-сертификат, а
  Cloudflare (оранжевое облако) скрывает IP сервера: блокировка relay
  означает блокировку всего Cloudflare.
- **Несколько relay одновременно.** Клиент опрашивает все включённые
  relay с джиттером; сообщения уходят на relay получателя из приглашения.
- **Подписанные запросы вместо логинов.** Ни аккаунтов, ни телефонов,
  ни SMS — только Ed25519-ключи, сгенерированные на устройстве.

## Криптография (v1)

| Назначение | Алгоритм |
|---|---|
| Идентичность / подписи | Ed25519 |
| Выработка общего ключа | X25519 static-static ECDH |
| Выведение ключей направлений | HKDF-SHA256, salt `VEIL-SALT-V1`, info `VEIL-CTX-V1:<lo>:<hi>` |
| Шифрование сообщений | ChaCha20-Poly1305, случайный nonce 96 бит |
| Подпись конверта | Ed25519 над `raw(X25519-пуб sender) ‖ шифротекст` |
| Аутентификация запросов к relay | Ed25519 над `<purpose>:<user>:<ts>:<nonce>` (окно ±120 с, анти-replay) |

Формат конверта: `nonce(12) ‖ ciphertext ‖ tag(16)`, base64. Внутри —
JSON `{i, t, ts, r}`: id для дедупликации, текст, время, relay-адреса
отправителя. Ключи направлений: стороны сортируются по sign-ключу,
сторона с меньшим шифтует первыми 32 байтами HKDF, другая — вторыми;
«самопереписка» (Избранное) использует первый ключ для обоих направлений.

**Ограничения v1 (честно):** нет forward secrecy (компрометация ключа
раскрывает сохранённые конверты), нет групповых чатов, relay видит
метаданные (кто с кем и когда, но не содержимое и не IP получателей),
клиент не прошёл аудит. План развития — в конце файла.

## Состав репозитория

```
relay/veil_relay.py         relay-нода: один файл, aiohttp + SQLite
relay/requirements.txt      aiohttp, cryptography
relay/deploy/install.sh     установка на Debian/Ubuntu VPS + systemd
relay/deploy/veil-relay.service        юнит с hardening
relay/deploy/Caddyfile                HTTPS через Caddy (Let's Encrypt)
macos/Veil/Sources/        SwiftUI-приложение (без внешних зависимостей)
macos/build.sh             сборка Veil.app без Xcode-проекта
windows/veil_core.py       ядро Windows/Linux-клиента: криптография+транспорт
windows/veil_client.py     tkinter-GUI (русский интерфейс)
windows/run_windows.bat    запуск на Windows в один двойной щелчок
tests/relay_integration.py интеграционный тест relay (19 проверок)
tests/e2e_two_clients.py   сквозной тест: 2 клиента через живой relay
tests/windows_client_e2e.py e2e python-клиента: потоки, WS, swift-конверты (20)
tests/interop/             тест совместимости Swift ↔ Python криптографии
```

## Быстрый старт

### Relay-нода

Локально (для экспериментов):

```bash
python3 -m venv .venv && .venv/bin/pip install -r relay/requirements.txt
.venv/bin/python relay/veil_relay.py
```

По умолчанию relay привязывается к `0.0.0.0:8080`, то есть **слушает и
внешний IP** машины. Проверить: `curl http://<внешний-IP>:8080/health`.
Если снаружи не открывается — проверьте фаервол (`ufw allow 8080/tcp`)
и security group у облачного провайдера.

На VPS (Debian/Ubuntu) — установка как systemd-сервис, слушает 0.0.0.0:8080:

```bash
sudo bash relay/deploy/install.sh
```

**Публичный доступ с TLS (рекомендуемый способ).** Relay умеет сам держать
HTTPS, сертификат возьмите у Let's Encrypt:

```bash
apt install certbot && certbot certonly --standalone -d relay.example.com
sudo VEIL_PORT=443 \
     VEIL_TLS_CERT=/etc/letsencrypt/live/relay.example.com/fullchain.pem \
     VEIL_TLS_KEY=/etc/letsencrypt/live/relay.example.com/privkey.pem \
     bash relay/deploy/install.sh
ufw allow 443/tcp
```

**Если 443 уже занят другим сервисом** — используйте порт **8443**
(де-факто стандартный «второй HTTPS», обычно не фильтруется — это всё
тот же TLS). Клиенты принимают адрес с портом как есть:
`https://relay.example.com:8443`.

```bash
# сертификат: если и 80-й порт занят, используйте DNS-challenge
# (plug-in для вашего DNS-провайдера) или webroot существующего сайта
certbot certonly --preferred-challenges dns -d relay.example.com
sudo VEIL_PORT=8443 \
     VEIL_TLS_CERT=/etc/letsencrypt/live/relay.example.com/fullchain.pem \
     VEIL_TLS_KEY=/etc/letsencrypt/live/relay.example.com/privkey.pem \
     bash relay/deploy/install.sh
ufw allow 8443/tcp
```

Другие варианты подключения к ноде, если 443 занят:

- **Порты Cloudflare (2053, 2087, 2096).** Если домен проксируется через
  Cloudflare, эти порты Cloudflare обслуживает с TLS так же, как 443:
  поднимите relay на `VEIL_PORT=2096` и откройте его в security group —
  блокировка такого relay означала бы блокировку всех TLS-портов CF.
- **Сабдомен через уже работающий реверс-прокси.** Если сервис, занявший
  443, — это nginx/Caddy, добавьте `relay.example.com { reverse_proxy
  127.0.0.1:8080 }` в его конфиг: relay получит TLS «бесплатно» на общем
  443-м порту (установите его с `VEIL_LOCAL=1`).
- **Голый HTTP 8080** — только для локальных экспериментов: ретранслируемое
  содержимое зашифровано E2E, но метаданные и сам факт использования Veil
  видны провайдеру сети.

**Уже есть домен и сертификат Let's Encrypt** (например, `zerogg.ru` с
конфигом в `/etc/letsencrypt/renewal/zerogg.ru.conf`)? Тогда новый
сертификат не нужен — используйте существующий на порту 8443:

```bash
# 1. Копируем сертификат туда, где его читает сервис-пользователь veilrelay,
#    и настраиваем автообновление при certbot renew (deploy-hook):
sudo cp relay/deploy/certbot-deploy-hook.sh /etc/letsencrypt/renewal-hooks/deploy/veil-relay.sh
sudo chmod 755 /etc/letsencrypt/renewal-hooks/deploy/veil-relay.sh
sudo sed -i 's/^CERT_NAME=.*/CERT_NAME="zerogg.ru"/' /etc/letsencrypt/renewal-hooks/deploy/veil-relay.sh
sudo /etc/letsencrypt/renewal-hooks/deploy/veil-relay.sh   # первичное копирование

# 2. Ставим relay с TLS на 8443, сертификат берём из скопированных файлов:
sudo VEIL_PORT=8443 \
     VEIL_TLS_CERT=/var/lib/veil-relay/fullchain.pem \
     VEIL_TLS_KEY=/var/lib/veil-relay/privkey.pem \
     bash relay/deploy/install.sh

# 3. Открываем порт и проверяем снаружи:
sudo ufw allow 8443/tcp
curl https://zerogg.ru:8443/health    # ожидается {"status": "ok"}
```

Приватные ключи в `/etc/letsencrypt` читает только root, а relay работает
от пользователя `veilrelay` — поэтому hook копирует файлы с владельцем
`veilrelay:veilrelay 0640` и при каждом `certbot renew` сам обновляет
копию и перезапускает relay (проверка: `sudo certbot renew --dry-run`).
Клиентам укажите relay как `https://zerogg.ru:8443`.

Если не хотите, чтобы relay отвечал на основном домене — используйте
поддомен `relay.zerogg.ru`: добавьте A-запись на IP сервера и, если
сертификат не wildcard, выпустите отдельный
(`certbot certonly --nginx -d relay.zerogg.ru`, режим зависит от того,
каким плагином получен основной), и укажите его имя в `CERT_NAME=`.

Альтернатива — реверс-прокси: `sudo VEIL_LOCAL=1 bash relay/deploy/install.sh`
привяжет relay к 127.0.0.1, а Caddy поставит HTTPS перед ним (`apt install
caddy`, файл `relay/deploy/Caddyfile`, замените домен на свой). Затем
(опционально, но рекомендуется) включите проксирование домена через
Cloudflare — IP сервера скроется, а трафик будет неотличим от обычных
сайтов за Cloudflare. Relay не пишет в логи идентификаторы пользователей
(`access_log=None`).

Полезные флаги relay: `--path-prefix /blog/wp-content` (замаскировать
API), `--retention-days 14`, `--tls-cert/--tls-key` (TLS без реверс-прокси),
`--trust-proxy` (за реверс-прокси), `--decoy-file page.html`.

### macOS-клиент

Требуется macOS 13+ и Command Line Tools (`xcode-select --install`):

```bash
bash macos/build.sh            # arm64 (на Intel: --universal)
open macos/Veil.app
```

При первом запуске: создайте личность → в разделе «Реле-серверы»
добавьте адрес relay (например, `https://relay.example.com`) → в «Мой
профиль» скопируйте код приглашения и передайте его собеседнику. Он
вставит код в «Добавить контакт» — и переписка заработает в обе стороны.

Данные и ключи хранятся в `~/Library/Application Support/Veil/store.json`
(права 0600). Резервная копия ключей — «Экспортировать личность».

### Windows-клиент (и Linux/macOS для отладки)

На Windows: установите [Python 3.8+](https://www.python.org/downloads/)
(галочка «Add python.exe to PATH»), скопируйте папку `windows/` и запустите
`run_windows.bat` — зависимости (`cryptography`, `websocket-client`)
поставятся сами. Логика использования та же: личность → relay → обмен
приглашениями. Файл личности совместим с macOS-экспортом (кнопка
«Импортировать…» в профиле принимает бэкап из Veil.app — и наоборот).
Подробности: `windows/README.md`.

### Тесты

```bash
.venv/bin/python tests/relay_integration.py    # relay: 19 проверок
.venv/bin/python tests/e2e_two_clients.py      # e2e через живой relay: 11
.venv/bin/python tests/windows_client_e2e.py   # python-клиент: 20 проверок
bash tests/interop/run.sh                      # Swift ↔ Python криптография
.venv/bin/python windows/veil_core.py --selftest  # ядро python-клиента: 12
macos/Veil.app/Contents/MacOS/Veil --selftest  # самопроверка Swift: 14
```

## Модель угроз

**Защищает от:** чтения сообщений оператором relay и перехватчика трафика
(E2E-шифрование); подмены отправителя (подпись конверта); чтения чужого
ящика (подписанные запросы); блокировки по IP/домену одного relay
(множество relay, Cloudflare-маскировка, префиксы путей); слежки через
регистрацию (нет аккаунтов и телефонных номеров).

**НЕ защищает от (v1):** компрометации устройства или файла ключей;
глобального анализа трафика, сопоставляющего время отправки и poll
(джиттер есть, но без cover traffic защита частичная); злонамеренного
relay, сканирующего публичные ключи спамом (rate-limit смягчает);
принудительной блокировки целых CDN; отсутствия forward secrecy.

## Дорожная карта

1. Forward secrecy: одноразовые prekey-пакеты (X3DH-подобная схема).
2. Групповые чаты (sender keys) и вложения (до 64 КБ уже влезает в конверт).
3. Cover traffic: ложные poll-запросы и паддинг конвертов.
4. Ключи в macOS Keychain; локальная блокировка приложения паролем.
5. Клиенты: Windows/Linux уже есть (python), дальше iOS/Android (протокол не
   привязан к Apple: CryptoKit и `cryptography` совместимы — подтверждено
   тестом `tests/interop` и расшифровкой swift-конвертов python-ядром).
6. Bootstrap списка relay через несколько каналов (DNS TXT, GH-pages и т.п.).
