# rtr-subs

Неофициальное дополнение для **Podkop 0.7.24** на OpenWrt (не связано с проектом Podkop).

Что делает одна команда установки:

1. **Добавляет в Podkop поддержку подписок:** тип конфигурации «Подписка», ссылка, выбор HWID (автоматический / свой / не отправлять), User-Agent, интервал автообновления. Ноды берутся из подписки, самую быструю выбирает URLTest, список нод виден на Dashboard.
2. **Ставит ядро `sing-box` из `podkop-net/podkop-engine`:** поддержка REALITY, совместимая с современными Xray-серверами. Без него ноды провайдеров с `minClientVer` выдают ошибку `reality verification failed`.
3. **Обновляет русские строки интерфейса LuCI.**

## Требования

- OpenWrt с пакетным менеджером `opkg` или `apk`
- Установленный **Podkop 0.7.24**
- Доступ по SSH с правами `root`

## Установка

### Вариант 1. Напрямую с GitHub (рекомендуется)

Подключитесь к роутеру по SSH и выполните:

```sh
wget -O /tmp/install.sh https://raw.githubusercontent.com/FoolTrigger/sub-podkop/main/install.sh https://raw.githubusercontent.com/FoolTrigger/sub-podkop/main/install.sh && sh /tmp/install.sh
