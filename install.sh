#!/bin/bash

echo "====================================="
echo " TriAngels TG Bridge Installer "
echo "====================================="

read -p "Введите домен или IP VPS: " VPS_HOST
read -p "Введите секрет MTProxy: " MT_SECRET

echo ""
echo "Генерируем Docker контейнер MTProxy..."

docker run -d \
  --name triangels-mtproxy \
  --restart=always \
  -p 443:443 \
  -e SECRET=$MT_SECRET \
  -e TAG=triangels \
  telegrammessenger/proxy

echo ""
echo "Готово."
echo "Ссылка для подключения:"
echo "tg://proxy?server=$VPS_HOST&port=443&secret=$MT_SECRET"
