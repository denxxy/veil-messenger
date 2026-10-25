#!/bin/sh
# Certbot deploy hook: копирует свежий сертификат для Veil relay
# (в каталог, читаемый пользователем veilrelay) и перезапускает сервис.
#
# Установка на сервере:
#   sudo cp certbot-deploy-hook.sh /etc/letsencrypt/renewal-hooks/deploy/veil-relay.sh
#   sudo chmod 755 /etc/letsencrypt/renewal-hooks/deploy/veil-relay.sh
#   sudo editor /etc/letsencrypt/renewal-hooks/deploy/veil-relay.sh   # поправить CERT_NAME
#   sudo /etc/letsencrypt/renewal-hooks/deploy/veil-relay.sh          # первичное копирование
#
# После этого certbot renew будет сам обновлять копию и перезапускать relay.

# Имя сертификата = папка в /etc/letsencrypt/live/ (см. `certbot certificates`)
CERT_NAME="zerogg.ru"
DATA_DIR="/var/lib/veil-relay"

LINEAGE="/etc/letsencrypt/live/$CERT_NAME"

if [ ! -r "$LINEAGE/privkey.pem" ]; then
    echo "veil-relay hook: нет сертификата $LINEAGE (проверьте CERT_NAME)" >&2
    exit 0
fi

changed=0
for f in fullchain.pem privkey.pem; do
    src="$LINEAGE/$f"
    dst="$DATA_DIR/$f"
    if ! cmp -s "$src" "$dst" 2>/dev/null; then
        install -o veilrelay -g veilrelay -m 0640 "$src" "$dst" && changed=1
    fi
done

if [ "$changed" = 1 ]; then
    systemctl restart veil-relay.service 2>/dev/null || true
    echo "veil-relay hook: сертификат обновлён, сервис перезапущен"
fi
