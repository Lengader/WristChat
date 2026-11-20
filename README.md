# WristChat

Тест установки на iPhone и Apple Watch. Открой WristChat на часах, нажми «Проверить запуск» и убедись, что появилось «Работает на часах».

## Сборка с Windows

1. Загрузи проект в репозиторий GitHub. Workflow **Build test IPA** запускается при отправке в `main` или вручную через **Actions**.
2. В успешном запуске открой **Artifacts** и скачай **WristChat-unsigned**. Распакуй `WristChat-unsigned.ipa`.
3. Для тестовой установки понадобятся iPhone, подключённый по USB, и подпись для iPhone и часов. Экспериментальная ветка [iLoader Watch Companion](https://github.com/Rzbck/iloader-watch-companion) документирует этот способ установки с Windows.

Минимальные версии системы — iOS 18 и watchOS 11. Для сборки Apple Account не нужен. GitHub создаёт пакет без подписи, подпись добавляется при тестовой установке.
