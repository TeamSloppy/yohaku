# Yohaku: записи → материалы → персональное занятие

Дата: 17 октября 2026. Статус: план согласован, этапы 1–5 реализованы и проверены в изолированной worktree. Базовая ветка: `main`. Ревизия плана: 2.

## Goal

Пользователь сохраняет запись после урока → Yohaku предлагает полезные учебные материалы с источниками → пользователь принимает подходящие → проходит короткое персональное занятие на экране «Сегодня» → результаты влияют на следующие повторения. Затем тот же цикл пополняется автоматическим анализом выбранных записей.

## Boundary

В первый выпуск входят Markdown, текстовые объекты canvas и рукописные страницы/выделенные области через текущую визуальную модель; карточки, пропуски в предложениях и короткое самостоятельное применение; занятия на 3/10/20 минут; сохранение прогресса; очередь автоматического анализа выбранных источников; обработка при запуске и доступное ОС фоновое выполнение.

Начальные значения: японский как изучаемый язык и русский для объяснений, как в существующей генерации; 10 минут по умолчанию; максимум 1/3/5 новых учебных элементов для 3/10/20 минут. Это настройки продукта, а не обещание точной длительности.

Предложения ИИ принимаются после просмотра. Существующая библиотека и ручная практика остаются полноценными путями обучения. В эту итерацию не входят собственный OCR, серверное расписание, самостоятельный курс для новичка, граф знаний и автоматическая оценка свободного ответа как единственная истина. Здесь планируются изменения и их проверки; исходный код, сборки, тесты, коммиты и публикация PR в рамках подготовки плана не выполняются.

## Context

**Current state:**

Исходный срез до реализации; результаты выполненных этапов зафиксированы в конце документа.

- `App/FlashcardStore.swift:192` открывает `.workspace/flashcards.json` внутри текущего vault; существующие карточки уже имеют provenance, оценки и интервалы повторения. Метод сохранения около строки 315 использует detached-запись снимка без координации и проверки ревизий: старый снимок может завершить запись позднее нового.
- `App/FlashcardsView.swift:635` содержит генерацию по теме и предпросмотр; `Packages/StudyIntelligence/Sources/StudyIntelligence/AgentSession.swift:45` — текущую генерацию. Её отмена не должна полагаться только на `AgentSession.cancel()`: этот путь не регистрирует собственную задачу в отменяемом handle.
- `App/WorkspaceModel.swift:110` переключает vault, около строки 226 обновляет документы. Новые асинхронные операции должны проверять принадлежность исходному vault и запуску.
- `DocumentContent.contentRevision` исключает изменения чата. UUID и семантическая ревизия подходят для идентичности материала; путь нужен для навигации. У внешнего Markdown без metadata идентификатор зависит от пути: произвольное внешнее переименование не гарантирует сохранения идентичности.
- `CanvasRenderer.image` уже собирает штрихи, изображения и текстовые объекты в ограниченное изображение. Выделение canvas передаёт `SourceContext` через `DocumentEditor` в помощника. Бесконечный canvas требует явной области.
- Сетевой адаптер поддерживает типизированный ответ, но всё равно нуждается в проверке данных. `SmolLanguageModel` принимает изображения и строковые ответы, отвергает произвольный `Generable`: ему требуется строковый JSON с проверкой схемы.
- `StudyCompanion` уже отвечает за напоминания. Фоновая генерация требует отдельного исполнителя и проверки жизненного цикла; обычная Swift Task не обеспечивает фоновое время ОС.

**Expected state:**

В редакторе доступно «Подготовить занятие из записи», в навигации — «Сегодня». После первого ручного цикла пользователь может включить автоматическую подготовку для выбранных записей и папок. Готовое занятие работает без ожидания модели и без сети. Неподтверждённые предложения видны отдельно от активного повторения.

**Design:**

Все названия новых типов ниже — предлагаемые. `WorkspaceModel` владеет `StudyPipeline`, `StudyMaterialStore` и состоянием «Сегодня»; генерация находится в `StudyIntelligence`, экран и связывание — в `App`. Небольшие чистые модели и планировщик размещаются рядом с существующей логикой практики, без нового отдельного framework.

1. **Источник.** `StudySourceSnapshot` содержит vaultID, documentID, contentRevision, путь, страницу/область и ограниченный текст/изображение успешно сохранённой записи. Из Markdown убирается служебный frontmatter; большие записи делятся на блоки с устойчивыми ссылками на исходные фрагменты. Для canvas извлекаются реальные текстовые объекты и снимок выбранной страницы/области. Текст внутри изображений считается данными, а не инструкциями модели. Неразборчивую рукопись пользователь проверяет по изображению; самостоятельную оценку уверенности модели нельзя считать доказательством качества.
2. **Материалы.** `MaterialGenerationService` возвращает до пяти кандидатов на блок: слово/выражение с чтением, переводом и примером; краткое объяснение конструкции; пропуск или задание на собственную фразу с опорными пунктами. Форматы ограничены схемой. Один запрос создаёт связанный набор, без запроса модели на каждом шаге урока. Цитата источника, исправление и придуманный пример различаются явно. Ссылки на фрагменты проверяются приложением; пустые поля, неизвестные ссылки и некорректный cloze отклоняются. Схема не доказывает правильность перевода — остаётся предпросмотр.
3. **Совместимость модели.** Типизированный результат используется там, где поддерживается; для Smol — строка JSON и тот же валидатор. Неподдерживаемые изображения дают понятное состояние с выбором подходящей модели пользователем. Смена провайдера не происходит автоматически. Чат и pipeline не занимают локальный MLX одновременно; интерактивный запрос приоритетнее очереди подготовки.
4. **Очередь и отбор.** Ключ анализа включает vault, UUID, contentRevision, страницу/область, версию pipeline и конфигурацию провайдера без секретов. Состояния задания: queued/running/paused/failed/completed; предложения: pending/accepted/rejected/stale. Сравнение нормализованного слова/чтения и типа упражнения подавляет точные дубли в источнике и библиотеке; близкие варианты показываются для решения пользователя. Отклонение запоминается. При завершении генерации и принятии кандидата повторно проверяется ревизия источника: поздний ответ на старую версию отвергается либо сохраняется как stale. Изменение источника устаревает pending-кандидатов, но не удаляет принятые материалы. Уже принятые материалы хранят исходный фрагмент, даже если документ удалён.
5. **Запись и восстановление.** Сохранить формат `flashcards.json`; новые данные положить в versioned `.workspace/study-state.json`. В карточки добавить только совместимые optional-поля materialID и идентификатора применённой операции. Один сериализованный writer координирует чтение/запись файлов через `NSFileCoordinator` и проверяет ожидаемые ревизии. Принятие и оценка проходят через небольшой durable journal: записать pending-операцию → идемпотентно изменить карточку → подтвердить прогресс. Новая операция этой карточки начинается после подтверждения предыдущей; при запуске pending восстанавливаются до новых действий. Простого поля «последний ID» недостаточно при конфликтующих устройствах: внешнее изменение сначала перечитывается и сверяется, неоднозначный конфликт сохраняет обе версии и блокирует зависимые изменения до явного восстановления. Автоматическое распределённое слияние прогресса не обещается. Неподдерживаемая новая schemaVersion открывается без перезаписи: все зависимые команды принятия, оценки и pipeline приостанавливаются, чтобы косвенная запись не обошла защиту.
6. **Персональный подбор.** Локальный `DailyLessonPlanner` сначала выбирает уже наступившие повторения с учётом ошибок и сложности, затем новые принятые элементы в пределах времени и лимита. Будущие повторения не подтягиваются ради заполнения занятия. Каждый шаг объясняет выбор: «ошибка в прошлый раз», «пора повторить», «из вчерашней записи». Для короткого занятия — повторение и один новый элемент; для обычного и длинного — также применение, если для него есть принятый материал. Если материала мало, занятие короче; пустое состояние предлагает выбрать запись или открыть библиотеку.
7. **Сессия.** До старта можно изменить время и пересобрать подборку. После старта сохраняется неизменный snapshot содержимого, порядка, источников и прогресса. Один незаконченный урок продолжается после перезапуска и перехода даты; завершение учитывается в день завершения. Новый день определяется календарём и часовым поясом пользователя, повторный вход не создаёт дубликат. Пропущенные дни не создают очередь долгов. Удалённая карточка пропускается с объяснением, её ID не восстанавливается из snapshot. Сохранение попытки с уникальным operationID предшествует переходу к следующему шагу; повтор callback не повторяет оценку.
8. **Практика.** Узнавание, воспроизведение и cloze переиспользуют существующие шкалу оценок и расписание карточек. Свободная фраза получает опорные пункты и самооценку; необязательный ИИ-комментарий вызывается отдельно и не меняет прогресс без действия пользователя. Для одного учебного элемента итог занятия формирует одну оценку расписания, чтобы несколько его упражнений не увеличивали интервал несколько раз. Итог показывает пройденное, трудности и назначенные повторения.
9. **Автоматизация.** Сначала явный выбор записи, затем opt-in для выбранных документов/папок. Настройки объясняют отправку содержания выбранному провайдеру; переход на другой удалённый endpoint требует нового подтверждения scope передачи. После сохранения, внешнего изменения и открытия приложения добавляются только изменённые источники. Нельзя загружать весь iCloud vault ради обхода. Недоступные файлы ждут загрузки или явного выбора; для бесконечных canvas автоматически обрабатываются только ранее выбранные области. Начальные бюджеты: одна активная генерация, не более трёх блоков за проход, до пяти кандидатов на блок; после пяти повторных неудач — явный retry. Изображения временные и ограниченные; незавершённый снимок либо сохранён ограниченно, либо пересоздаётся только при совпадении ревизии.
10. **Фон.** Основной путь — обработка доступной очереди при открытом приложении и возобновление при возврате. `BGProcessingTask` исполняет ту же ограниченную очередь при разрешении ОС; `BGAppRefreshTask` при необходимости только обновляет лёгкое состояние «Сегодня». Истечение времени отменяет owned Task, сохраняет checkpoint и освобождает модель. При смене vault старый worker останавливается, а поздние ответы отвергаются по vault/run epoch. Напоминание открывает «Сегодня» и не заявляет о готовности нового материала, если подготовка не завершена. Catalyst получает foreground/resume-путь и только поддержанные платформой фоновые API.

Фоновое выполнение не гарантируется системой; это подтверждено [Apple, WWDC25](https://developer.apple.com/videos/play/wwdc2025/227/). План не зависит от запуска строго к заданному часу.

## Done when

- C1: Markdown и выбранная рукописная область дают ограниченный набор материалов с проверяемым источником и предпросмотром.
- C2: Принятие, отклонение и повторный анализ сохраняются; повтор принятия после сбоя создаёт одну карточку.
- C3: «Сегодня» учитывает due, ошибки, время и лимит новых материалов; каждому шагу соответствует причина выбора.
- C4: Перезапуск и смена даты сохраняют содержание и позицию начатого занятия; пропуски не создают долги.
- C5: Итоговая оценка учебного элемента применяется один раз и изменяет его расписание; применение доступно с самооценкой.
- C6: Изменённый/удалённый источник, неподдерживаемая модель, неверный ответ ИИ и пустой набор имеют понятные состояния.
- C7: Автоматизация соблюдает выбранные источники, согласие, лимиты и доступность iCloud-файлов; прерывание допускает продолжение.
- C8: Переключение vault и внешняя запись не смешивают данные и не перетирают конфликтующую версию.
- C9: Принятые материалы и начатое занятие доступны без сети и модели; старые карточки продолжают читаться.

## Implementation Steps

Изменения последовательно интегрируются в `main`. Для каждого этапа предусмотрены собственные проверки. Предлагаемый способ — самостоятельные видимые улучшения без временного флага: промежуточный результат пригоден к использованию. Альтернатива — скрывать весь цикл за общим флагом до финала; это добавляет состояние для проверки и отдельный этап удаления. Рекомендация: последовательное включение. Это выбор для согласования вместе с планом, до реализации.

Оценки ниже включают добавленные и удалённые строки кода и тестов, исключают документацию и генерируемый Xcode-проект. Цель ≤600, предел 1000 строк на PR; диапазоны — предварительная оценка, а не гарантия. Если этап не помещается, он делится до написания следующей части. PR в ходе реализации по умолчанию draft; их создание и отправка не входят в нынешний запрос на план.

| № | Законченный результат и границы | Основные места | Зависит от | Бюджет / статус |
|---|---|---|---|---|
| 1 | Последовательное сохранение карточек с проверкой ревизий и восстановлением конфликтов. Не меняет генерацию и UI занятия. | `FlashcardStore`, новый study writer | — | 400–600 / in-review |
| 2 | Явный разбор Markdown из редактора → проверка → существующий предпросмотр. Ограниченный источник, адаптер провайдера, owned cancellation и защита vault epoch. Пока без автообхода. | `DocumentEditor`, `WorkspaceModel`, `StudyIntelligence/MaterialGenerationService` | 1 | 450–600 / in-review |
| 3 | Выбранная страница/область canvas проходит тот же цикл с текстом и изображением. Проверяются возможности модели и разборчивость. | `SourceContext`, `CanvasRenderer`, редактор | 2 | 350–550 / in-review |
| 4 | Долговечные pending/accepted/rejected/stale, дедупликация, источники, идемпотентное принятие через журнал. Связанные объяснения и упражнения сохраняются с материалом. | новый `StudyMaterialStore`, предпросмотр, writer | 2, 3 | 4a433 + 4b779 / in-review |
| 5 | «Сегодня» с локальным подбором, временем, причинами выбора и пустыми состояниями; подборку можно открыть в существующей ручной практике. Результат этого этапа — полезная дневная подборка; собственная возобновляемая сессия идёт следующим этапом. | новый `DailyLessonPlanner`, `TodayView`, навигация | 4 | 435 / in-review |
| 6 | Занятие «Сегодня» с сохранённым snapshot, продолжением, карточками/cloze и однократной оценкой элемента. | новый lesson store, существующая практика, writer | 5 | 450–600 / planned |
| 7 | Самостоятельная фраза с опорными пунктами и самооценкой, необязательная обратная связь, итог урока. Не создаёт новый алгоритм SRS. | lesson UI, адаптер генерации | 6 | 350–550 / planned |
| 8 | Автоматический анализ выбранных источников при сохранении/возврате: настройки, согласие, долговечная очередь, ревизии и бюджеты. | новый `StudyPipeline`, `WorkspaceModel` | 4 | 450–600 / planned |
| 9 | Фоновый запуск той же очереди, expiration/resume, переход уведомления на «Сегодня», поддержка доступных API платформы. | `YohakuApp`, `StudyCompanion`, `project.yml` | 7, 8 | 350–550 / planned |

1. Реализовать и проверить PR1 как самостоятельное исправление сохранения; затем PR2–4 дают ручной путь от записи до принятых материалов.
2. Реализовать PR5–7: персональная подборка, возобновляемое занятие, самостоятельное применение. Полный ручной учебный цикл считается готовым после PR7.
3. Реализовать PR8–9: автоматическая подготовка пополняет предложения, а фоновый исполнитель использует уже проверенный pipeline.
4. После каждого этапа проверить реальный размер и зависимости оставшейся карты. Нет временных флагов или старой заменяемой реализации — отдельного этапа их удаления не требуется.

## Verifications

Проверки предлагаются как часть будущей реализации. В ходе подготовки плана выполнено только изучение исходников и независимое ревью плана; прохождение сборок, тестов, качество модели и работа iCloud не заявляются.

| Критерии | Проверка и ожидаемое доказательство |
|---|---|
| C1, C6 | Контрактные проверки генератора: корректный и повреждённый JSON, лимиты, ложная ссылка на источник, неподдерживаемая vision-модель. Реальный Markdown и область с почерком → предпросмотр → открытие источника. Качество языка проверяется отдельно от формата. |
| C2, C5, C8, C9 | Тесты writer/journal со сбоями между каждым шагом commit, повторными callback, двумя ожидающими записями, внешним изменением и старым JSON. После восстановления нет потери/дублирования карточки или повторной оценки. Неоднозначный конфликт блокирует запись и оставляет обе версии. Новая неподдерживаемая schemaVersion блокирует зависимые мутации и фоновый executor без изменения файла. |
| C3, C4 | Чистые тесты с фиксированными часами: due/будущие/ошибки, 3/10/20 минут, лимиты новых элементов, полночь, часовой пояс, пустые данные. Начатый snapshot не меняется. |
| C4, C5, C6, C9 | UI-сценарий: запись → генерация с фиксированным ответом → принятие → «Сегодня» → ответ → завершение процесса → продолжение → итог; также offline, удаление карточки/источника и недоступная модель. Явные accessibility identifiers. |
| C7, C8 | Контролируемый исполнитель: смена vault во время запроса, отмена, expiration, старый ответ, повторное событие сохранения, смена endpoint, iCloud placeholder. Изменение записи во время генерации не допускает принятия позднего ответа как актуального. Ни один ответ не записывается в другой vault; незавершённое задание возобновляется. |
| C1, C7, C8 | На физическом iPad: рукописные примеры, маленькая локальная модель, память/время, реальные фоновые запуски и iCloud на двух устройствах. Симуляция handler подтверждает только обработчик; Simulator не доказывает реальную синхронизацию или расписание ОС. |

Сборки: `StudyKit` и `StudyIntelligence`, затем XcodeGen и Yohaku для iOS Simulator и Mac Catalyst. Запускаются затронутые unit/UI-сценарии, а более широкие проверки — при обнаруженной связи с изменением. До окончания PR7 отдельно пройти один сквозной сценарий с реальным провайдером; до окончания PR9 — платформенные проверки. Нужный реальный провайдер, устройство или доступ к iCloud, если недоступны, фиксируются как ограничения покрытия.

## Break when

- Если PR превышает бюджет или требует массовой миграции/переноса всей библиотеки, разделить этап и пересмотреть карту до продолжения.
- Если текущий файловый формат не позволяет безопасное восстановление принятия/оценки, остановить зависимую часть и пересмотреть протокол записи. Нельзя считать атомарную запись одного файла транзакцией двух файлов.
- Если реальные модели не дают приемлемых материалов из выбранной рукописи, пересмотреть способ подготовки изображения/области и UX исправления; поддержка почерка остаётся незавершённым критерием до доказательства качества.
- Если обнаружен конфликт iCloud, сохранить версии, остановить зависимые записи и предложить явное восстановление. Нельзя обещать безусловное слияние прогресса между устройствами.
- Если для завершения сценария понадобятся сервер, новый OCR, другой провайдер или иной объём отправки данных, сначала пересмотреть план и соответствующий выбор пользователя.

## Decision log

- 2026-10-17: ручной цикл реализуется до автоматизации; обучение и черновики остаются внутри текущего vault; основой служат существующие карточки и провайдеры. План ожидает согласования. Качество модели и фоновое выполнение требуют отдельного runtime-доказательства.

- 2026-10-17: независимое ревью ревизии 1 — VALID, блокеров нет. В ревизии 2 приняты оба уточнения: повторная проверка источника после генерации/перед принятием и блокирование зависимых мутаций при новой schemaVersion. Структурная проверка финального документа выполняется после правок.

## Stage 1 execution

User approved revision 2 and isolated worktree implementation on 2026-10-17. Branch: codex/yohaku-study-persistence. Stage 1 implemented and reviewed; stages 2–9 planned. Existing full-plan audit accepted; stage boundary unchanged. No project memory skill is exposed; execution record lives in this approved decomposition document.

Goal: serialize complete flashcard mutations and coordinate CAS file writes, preserving conflicting local data with explicit recovery.
Boundary: App/FlashcardStore.swift; App/StudyFileWriter.swift; App/FlashcardsView.swift; Tests/FlashcardPersistenceTests.swift; Tests/FlashcardPracticeTests.swift. Existing array JSON remains compatible. No generation or Today changes.
Done when: concurrent mutations survive reopen; external revision mismatch preserves both versions and blocks further mutation until explicit recovery; read failure cannot overwrite unread data; vault switches cannot publish stale cards/error/callback; review failure cannot advance practice.
Implementation Steps: writer synchronous coordinated read/compare/write; store FIFO transactions deriving state after preceding commit; epoch checks and deferred publication; minimal library error/recovery action; targeted regression tests.
Verifications: approved targeted tests for concurrency, revision conflicts, read failures, explicit recovery, vault switch and legacy JSON; simulator target compilation/test. Physical two-device iCloud remains separate coverage.

| Owner | Deliverable | Write paths | Shared resources | Worker | State |
|---|---|---|---|---|---|
| root | plan/status | docs/tbd/decompositions/2026-10-17-personal-daily-study.md | none | root | accepted |
| persistence | stage 1 implementation and targeted tests | App/FlashcardStore.swift; App/StudyFileWriter.swift; App/FlashcardsView.swift; Tests/FlashcardPersistenceTests.swift; Tests/FlashcardPracticeTests.swift | simulator:6EF2D53F-C484-4AA3-9286-687C0550FA3D; derived-data:/tmp/yohaku-study-persistence-derived | /root/persistence_research | accepted |

### Assignment persistence

**Goal:** Implement stage 1 accepted boundary.
**Context:** Approved full plan revision 2; stage 1 research accepted. Worker gpt-6.1-sol high, fresh context originally. Native handle /root/persistence_research.
**Constraints:** Sole writer of listed source/test paths. No delegation, unrelated changes, commits/push, or later stages. Preserve legacy format and explicit conflict recovery. Targeted tests authorized by user approval of Verifications. Use actual isolated worktree only.
**Done when:** Return Status/Result/Evidence/Gaps with changed paths, test results and limits; no unqualified cloud claims.

## Stage 1 results

- Isolated worktree: /Users/vlad-prusakov/.codex/worktrees/yohaku-study-persistence/Workspace; branch codex/yohaku-study-persistence. No source modifications in primary checkout.
- FIFO complete mutations; coordinated raw-byte CAS; conflict copies and durable block; explicit saved-version recovery; malformed-read write protection; vault epoch guards; bulk acceptance closes only after success. Legacy JSON array preserved.
- Independent review found stale editor snapshots could reset committed review history. Corrected editable updates to preserve current scheduling/history; root inspected correction and its deterministic regression.
- Exact-source lightweight harness: 9/9 passed (log /tmp/yohaku-study-persistence-harness.log). Final harness uses XcodeDefault Swift and canonical path; earlier custom-toolchain cache collision was discarded, not counted as a source test result.
- iOS Simulator app build and targeted tests: 27/27 passed, 0 failed/skipped; iPhone 17 Pro iOS26.3.1; suites FlashcardPersistenceTests, FlashcardSchedulerTests, FlashcardPracticeTests. Log /tmp/yohaku-study-persistence-simulator.log.
- Mac Catalyst compilation passed; log /tmp/yohaku-study-persistence-catalyst.log. Root verified build success in the final log.
- Reviewable change: 537 added+removed lines including tests, plus 8 generated project registration lines. git diff --check passed.
- Physical two-device iCloud synchronization, Apple Pencil and full-suite results are not claimed. No commits, remote publication or merge in this stage.

- 2026-10-17: stage 1 implementation accepted after independent code review, P1 correction inspection, 27 Simulator tests and Mac Catalyst compilation. Stage remains in-review in the decomposition map because no remote PR/merge was requested or performed. Next slice: explicit Markdown source analysis and preview (PR2), after separate slice boundary.

## Stage 2 micro plan

User authorized continuing stage 2 on 2026-10-17. Stage 1 local boundary commit: f89ffdd; stage 2 branch codex/yohaku-markdown-study-materials, same isolated worktree. No remote publication or merge. Micro revision: 1; challenge round 1 VALID (markdown_plan_review), accepted; implementation authorized by user. Approved overall architecture/revision 2 remains in effect.

**Goal:** Saved Markdown → explicit bounded source/provider confirmation → source-grounded generated flashcards → existing preview → selected cards saved with provenance.
**Boundary:** One bounded excerpt, up to five cards; no canvas, persistent candidates, Today or background automation yet. Preserve topic generation and existing source-selection behavior. No implicit provider switching. Targets listed below; existing provider construction, running gate and model cleanup reused.
**Done when:** Saved snapshot contains vault epoch, document UUID/contentRevision/path/excerpt; save errors/conflicts/dirty state block generation. Strip opening closed frontmatter with BOM/CRLF handling; show bounded excerpt/truncation and selected provider before request. Typed response where supported and String JSON for Smol share strict field/count/source-quote validation. Preview distinguishes original quotation from generated example. Changes/deletion/move/vault switch/cancel invalidate late completion and acceptance. Re-read disk before generation completion and acceptance; final in-queue predicate checks current run/vault/session before flashcard commit. Accepted cards retain sourcePath/sourceExcerpt. Missing model, malformed response or persistence failure leaves actionable error and does not dismiss preview.
**Implementation Steps:**
1. Add bounded snapshot/response/validator/prompt in MaterialGenerationService; add source-generation AgentSession method sharing running/makeModel/cleanup.
2. Own cancelable Task/run/vault epoch in WorkspaceModel; snapshot from successful save + coordinated load, revalidate after suspensions; cancel on dismissal and vault transition.
3. Add Markdown toolbar entry; extend existing generator preview with source/provider confirmation and provenance display.
4. Narrow optional validity predicate in FlashcardStore batch add executes inside FIFO mutation before writer.write. Preserve stage 1 semantics.
5. Add deterministic fixture, focused source/cancel/vault/acceptance tests and UI flow; measure review diff against f89ffdd.
**Verifications:** Targeted source bounds/frontmatter/schema/quotes and unchanged topic parsing tests; stale source after preview, external rewrite/deletion/move, save failure/conflict, queued acceptance invalidation and vault A→B→A; UI fixture source action→confirmation→preview→accept→source provenance. XcodeGen, relevant app unit/UI suites, Simulator and Catalyst compilation using existing task-derived cache. No real external model request without explicit test fixture scope; linguistic quality not established by strict JSON validation.

Exact quotation establishes linkage, not correctness of translation. A final coordinated source read is not an atomic transaction across source and flashcard files; durable material bookkeeping remains stage 4. Persistent document UUID/revision storage is deferred to that stage; source snapshot still carries them during preview checks. Scope target ≤600 reviewable lines, cap1000; split before further work if required.

| Owner | Deliverable | Write paths | Shared resources | Worker | State |
|---|---|---|---|---|---|
| stage2-root | plan and evidence | docs/tbd/decompositions/2026-10-17-personal-daily-study.md | none | root | accepted |
| markdown | source generation and focused verification | Packages/StudyIntelligence/Sources/StudyIntelligence/MaterialGenerationService.swift; Packages/StudyIntelligence/Sources/StudyIntelligence/AgentSession.swift; App/WorkspaceModel.swift; App/DocumentEditor.swift; App/FlashcardsView.swift; App/FlashcardStore.swift; Tests/MarkdownStudyTests.swift; Tests/FlashcardPersistenceTests.swift; UITests/WorkspaceUITests.swift; Yohaku.xcodeproj/project.pbxproj | simulator:6EF2D53F-C484-4AA3-9286-687C0550FA3D; derived-data:/tmp/yohaku-study-persistence-derived | /root/markdown_research | accepted |

### Assignment markdown

**Goal:** Implement the stage 2 micro plan after independent challenge acceptance.
**Context:** Stage 1 baseline f89ffdd; approved full plan revision2; stage2 research complete. Worker gpt-6.1-sol high, originally fresh context. Stage2 branch and same isolated worktree.
**Constraints:** Sole writer of listed production/test/generated files; root owns plan. No delegation, unrelated refactor, commits/push, canvas or later stages. Approved plan authorizes targeted test additions/execution. Use xcodebuildmcp-cli skill for platform checks; reuse task-owned derived data and consistent XcodeDefault toolchain; never delete shared caches. Worktree unindexed, no CodeGraph reindex. Preserve source scope/provider confirmation, source and vault checks at async boundaries.
**Done when:** Status/Result/Evidence/Gaps with changed files, exact checks/logs, source vs runtime evidence and remaining limits. Acceptance guards and explicit preview are wired end-to-end.

### Assignment stage2-root

**Goal:** Maintain stage2 plan, accept implementation/review and report outcome.
**Context:** Approved overall plan revision2; baseline f89ffdd; root owns plan only.
**Constraints:** No production edits overlapping markdown worker; preserve primary checkout and user work; independent reviewers read-only.
**Done when:** Record exact implementation/review/test evidence and limits in plan; final report reflects verified state.

- Stage2 research and independent micro-plan audit accepted on 2026-10-17. Source worker /root/markdown_research implementing approved contract; no extra user approval required. Stage1 baseline preserved at local commit f89ffdd, no remote publication/merge.

- Stage2 implementation refinement (same micro boundary, accepted research): AgentSession registers its typed source-generation task; cancel/releaseMemory cancel and await it before cache release. This covers app lifecycle and model-settings callers without widening edits to YohakuApp. Both typed and String model responses pass the same strict raw JSON parser. Async acceptance errors require captured run/epoch guards. No architecture/slice scope change.
- Actual ENOSPC interrupted initial stage2 helper-file write before compilation; source patch preserved. Disk then recovered externally; no shared/task-cache deletions performed by root. Checks resume against final corrected candidate; initial CLI argument failures are not test results.

## Stage 2 verification checkpoint

- Implementation source complete; ~534 reviewable changed lines against f89ffdd at this checkpoint, excluding generated project/doc changes.
- Independent code review found four issues (computed property in Generable macro, lifecycle cancellation, typed raw-JSON validation, stale async acceptance errors). Corrections inspected independently: PASS. Root inspected registered-task cleanup and error guards.
- SwiftUI type-check complexity corrected by splitting the existing generator preview/controls into smaller views and removing a local cards-name shadow. Simulator app subsequently linked successfully.
- No stage2 passing test result yet: initial toolchain selection/CLI preflight failures and test-source compilation fixes are not counted as passing tests. Current run is being diagnosed/bounded after no observed runner startup; preserve xcresult. Catalyst check follows final test attempt.
- Model quality and real provider inference are outside this deterministic fixture verification. No external provider requests made during checks.

- Stage2 UI diagnosis corrected: buffered output after stopping first test process showed actual UI failures, not proof of no runner startup. Fresh UI-only run executed 1 failing test; confirmation succeeded but generated-card preview failed with a data-decoding error. New Generable DTOs synthesized Codable decoding for macro-added nonoptional _rawGeneratedContent. DTOs have no persistence consumers: fix uses strict seven-field JSON parsing and the library GeneratedContent conversion instead of synthesized Codable. Add literal valid-response regression. Initial failure remains recorded; only final passing reruns count for acceptance.


## Stage 2 results

- Branch codex/yohaku-markdown-study-materials in the same isolated worktree. Stage1 boundary preserved as local commit f89ffdd; stage2 source changes remain uncommitted. No remote PR/push/merge.
- Markdown editor command «Подготовить материалы» captures successfully saved source, strips opening frontmatter, shows exact bounded excerpt/provider and truncation before explicit request. Existing topic generation preserved.
- Same strict seven-string-field JSON/source-quote validator for typed and Smol String responses; Generable conversion excludes inappropriate synthesized Codable metadata. Equatable explicitly compares the seven transport fields. Selected cards persist original sourcePath/sourceExcerpt separately from generated example.
- Owned source task participates in cancellation/releaseMemory, holding shared model gate until cleanup. Saved source/run/vault/configuration checks after awaits and queued acceptance guard prevent stale results; old async errors cannot overwrite new preview context.
- Independent micro-plan review VALID; code review findings fixed and focused correction review PASS. Root inspected final parser/equality, lifecycle/acceptance guards and split SwiftUI preview wiring. Runtime regressions subsequently fixed and verified.
- Final Simulator unit run: 21/21 passed, 0 failed/skipped (31 Success test-case records including parameterized variants), invocationFinished success. Suites MarkdownStudyTests, FlashcardPersistenceTests and FlashcardGenerationTests. Log /tmp/yohaku-stage2-units.log; stream /tmp/yohaku-stage2-unit-events.json.
- Final Simulator UI fixture: 1/1 passed, 0 failed/skipped. Source confirmation → stripped excerpt/provider → quote/generated example → accept → return to library → selected cat card → stored source quotation. Log /tmp/yohaku-stage2-ui.log; stream /tmp/yohaku-stage2-ui-events.json. Device iPhone17 iOS26.3.1.
- Mac Catalyst compilation passed: /tmp/yohaku-stage2-catalyst.log. XcodeGen and git diff --check passed. Remaining build warning is existing UITextItemInteraction deprecation in MarkdownEditor.
- Reviewable stage2 diff: 550 added+removed code/test lines against f89ffdd, plus 4 generated project registration lines; docs excluded. Source files and tests within approved stage2 boundary.
- Earlier failed/interrupted checks are historical diagnostics only. Final counts above come from completed successful reruns on the corrected frozen production candidate. No real provider request, model language-quality evaluation, Apple Pencil or physical two-device iCloud proof is claimed.
- Next approved slice is stage3: bounded canvas page/region analysis using existing rendering and vision support. Stage2 complete; later stages remain planned.

## Stage 3 micro plan

User explicitly authorized canvas page/selection analysis in the same worktree. Stage2 baseline local commit c2895a9 (stage1 f89ffdd); branch codex/yohaku-canvas-study-materials. Micro revision1; independent challenge1 VALID (canvas_plan_review), accepted; implementation authorized. No remote publication/merge. No project memory skills exposed; this existing decomposition is the execution record.

**Goal:** Saved handwritten page or selected canvas area → image/provider confirmation → vision recognition → editable user-reviewed transcription → existing source-grounded cards → preview/acceptance retaining page/area and transcription origin.
**Boundary:** Current notebook page or explicit selected region; infinity requires a selection. No standalone OCR, queues, Today or automatic scanning. Preserve existing Ask and Markdown flows. Renderer remains unchanged. Persist only backward-compatible optional sourceRegion/sourceTextOrigin in cards/drafts, existing sourcePageID; durable UUID/revision bookkeeping remains stage4. Source navigation opens page and displays stored region, not automatic exact-area camera positioning.
**Done when:** Selection study path captures scope only (never reuses pre-save image). Flush ink, save, coordinated-load, render fresh frozen session, revalidate after render. Snapshot retains original document UUID/contentRevision/vault epoch/config/page/region. Finite region origins (including zero and negative infinity-canvas coordinates), finite positive dimensions and finite extents; clip notebook to page, reject missing infinity region and oversized world side (>8192); rendered sides1…2048 and bounded image bytes. Include typed object text only when complete rendered bounds inside crop; show original typed text separately. Confirm provider/image before recognition; validate declared vision support before construction/request, unknown local models cannot inherit remote defaults. Strict bounded {text:String,unclear:Bool} recognition response. Show uncertainty as model assessment, not confidence proof; user reviews/corrects and explicitly confirms bounded text before cards. Later text edits invalidate cards. All async boundaries and final queued acceptance retain source/run/vault/config guards. Cards label excerpts as confirmed transcription after reload; original Markdown quotations keep their label. Legacy files missing new optional fields decode.
**Implementation Steps:**
1. Extend runtime snapshot and strict recognition parser/confirmed-text projection; reuse seven-field card parser.
2. Add vision extraction under AgentSession owned-task cancellation/drain and shared running/model cleanup gate, with capability rejection before request.
3. Workspace prepares immutable saved page/region rendering and original bounded text; recognition/confirmation state feeds existing card generation and guarded acceptance.
4. Editor adds separate preparation page/area menu; PencilSurface selectionIncludesImage defaults true, study selection false emits scope only; Ask stays unchanged.
5. Existing source sheet shows image, original typed text, provider, editable recognition, uncertainty, explicit confirmation and existing card preview. Add compatible optional provenance fields and copy paths; saved source/editor/practice labels preserve origin and page/region.
6. Add deterministic unit/UI fixtures and regression tests, then independent code review and scoped Simulator/Catalyst checks. Keep ≤600 target; cap1000, re-slice rather than exceed.
**Verifications:** Notebook page and selected region; infinity with/without region; invalid NaN/origin/extents/page dimensions; clipping and contained-vs-partial text objects; frozen render matches saved content; save/conflict errors; unsupported vision causes zero provider calls; malformed/oversized/empty/uncertain recognition; correction changes card excerpt and invalidates old cards; cancellation/drain and source edit/delete/move/provider/vault changes; queued acceptance validity; legacy/provenance roundtrip. UI fixture page+area→image/provider→recognition→correction→confirm→cards→accept→stored page/transcription label. Existing Markdown regression and source generation tests remain green. XcodeGen and scoped tests using task derived /tmp/yohaku-study-persistence-derived, iPhone17 Simulator6F9BD654-279F-41A0-B328-C9C2020618C8; precreated/truncated -resultStreamPath and final summaries. Default Xcode toolchain (do not force TOOLCHAINS); sequential Catalyst generic/platform=macOS,variant=Mac Catalyst build.

Image recognition uses actual existing provider image transport with fixture-only test response; no real external inference/physical handwriting quality claim. App-authored content-addressed assets are the snapshot boundary: contentRevision does not independently hash hostile in-place asset mutation. Region/source origin fields are additive, no migration. Visible text/quote linkage does not prove translation or recognition correctness.

| Owner | Deliverable | Write paths | Shared resources | Worker | State |
|---|---|---|---|---|---|
| stage3-root | plan/evidence and acceptance | docs/tbd/decompositions/2026-10-17-personal-daily-study.md | none | root | accepted |
| canvas | stage3 source and focused tests | Packages/StudyIntelligence/Sources/StudyIntelligence/MaterialGenerationService.swift; Packages/StudyIntelligence/Sources/StudyIntelligence/AgentSession.swift; App/WorkspaceModel.swift; App/DocumentEditor.swift; Packages/StudyKit/Sources/StudyCanvas/PencilSurface.swift; App/FlashcardsView.swift; App/FlashcardStore.swift; App/FlashcardStudyView.swift; Tests/CanvasStudyTests.swift; Tests/FlashcardPersistenceTests.swift; UITests/WorkspaceUITests.swift; Yohaku.xcodeproj/project.pbxproj | simulator:6F9BD654-279F-41A0-B328-C9C2020618C8; derived-data:/tmp/yohaku-study-persistence-derived | /root/canvas_research | accepted |

### Assignment stage3-root

**Goal:** Maintain plan, accept implementation and independent review, report verified result.
**Context:** Approved overall rev2; stage3 micro1; same worktree; root owns document only.
**Constraints:** No source writes overlapping worker, preserve primary checkout; no remote PR or merge.
**Done when:** Record exact evidence/limits and acceptance of stage3 only.

### Assignment canvas

**Goal:** Implement approved stage3 contract after independent challenge accepted.
**Context:** Baseline c2895a9; worker gpt-6.1-sol high fresh context originally, research accepted; exact targets above.
**Constraints:** Sole writer of listed source/test/generated files; root owns plan. No delegation, unrelated refactors, commits/push or later stages. Approved plan and direct user instruction authorize targeted tests. Worktree CodeGraph unindexed; no indexing. Use xcodebuildmcp-cli skill, task-owned caches and default Xcode; no shared cache deletion or live-provider calls. Return discoveries rather than expanding target list.
**Done when:** Status/Result/Evidence/Gaps with exact files, checks/logs, code size and limits; page and selection workflows wired, image/transcription origin honest.

- Stage3 micro audit VALID, no blockers. Clarification accepted: finite origins may be zero/negative; dimensions must be positive, all extents finite. Root accepted research and user execution authority; canvas worker now owns implementation and scoped checks.


## Stage 3 results

- Same isolated worktree /Users/vlad-prusakov/.codex/worktrees/yohaku-study-persistence/Workspace; branch codex/yohaku-canvas-study-materials; baseline c2895a9 preserves reviewed stage2. Stage3 changes uncommitted, no remote publication or merge. Later stages remain planned.
- Notebook current-page and real selected-region actions added separately from Ask; infinity requires explicit finite scope. Study selection emits scope without rendering pre-save image. Flush/save/coordinated-load/frozen-session render with source revalidation; required in-scope images validated. Crop bounds, actual1…2048pixel image and8MiB PNG cap checked before request; only fully contained text objects included as separately labeled original text, with truncation disclosure.
- Declared vision support checked before model/request; owned recognition and card tasks share cancellation/draining and model cleanup. Image/provider confirmation → strict {text,unclear} recognition → editable reviewed transcription → explicit confirmation → existing seven-field cards. Uncertainty is labeled as model assessment. Full-size scrollable image sheet preserves editing context.
- Optional sourceRegion/sourceTextOrigin plus existing sourcePageID survive card↔draft↔save/reopen/practice. Confirmed transcription labels stay distinct from original Markdown quotations; legacy cards without new fields decode. Opening source navigates to the page and displays coordinates; exact-area camera navigation is not implemented.
- Independent micro-plan challenge VALID. Code review P2 uncertainty wording corrected. Runtime UI exposed stale-index crash when transcription edits/dismissal cleared global cards while SwiftUI retained a row; immutable card/quote values captured before ForEach fix it. Focused independent correction review PASS; root inspected final integration and logs.
- Focused unit checks completed successfully:26 methods /42 parameterized case records (Canvas12, Markdown19, persistence11). Saved real PencilKit stroke data/render bytes and crop correspondence, scope rejection, strict parsing/capability, correction, late-result/cancel/source/vault guards and provenance covered. Log /tmp/yohaku-stage3-unit-final2.log; events /tmp/yohaku-stage3-unit-final2-events.json. Subsequent production delta was view-only image/provider/immutable-row handling, exercised by finalUI/compilation.
- Final UI3/3 passed, zero failed/skipped: page image enlargement→recognition→meaningful correction→confirm→preview→edit invalidation→reconfirm/regenerate→accept/reopened label; actual region drag→fresh image→review/correct→preview→close→Ask regression; existing Markdown source flow. Log /tmp/yohaku-stage3-ui-final4.log and corresponding -events.json. Device iPhone17 iOS26.3.1. Tests handle lazy Form scrolling and keyboard onboarding; exact corrected text is asserted.
- Final Mac Catalyst compilation passed: /tmp/yohaku-stage3-catalyst.log. Simulator app compiled in successful targeted runs. XcodeGen and git diff --check passed. Only pre-existing MarkdownEditor UITextItemInteraction deprecation warnings observed.
- Final review size501 added+removed source/test lines against c2895a9, plus4 generated project registration lines; documentation excluded. Exactly approved source/test targets, no CanvasRenderer rewrite.
- Historical failed checks were resolved before acceptance: PNG pixel-vs-point test expectation; nested Testing macro assertion compile issue; lazy/offscreen UI navigation and keyboard/caret automation; actual stale-index crash. Only completed successful final runs above count as verification.
- Deterministic provider fixtures used; no real provider inference, physical handwriting/linguistic quality, physical Pencil input or two-device iCloud proof. App-authored content-addressed asset contract remains the source revision boundary; hostile in-place asset mutation is not independently hashed. Durable source UUID/revision bookkeeping and persistent candidate queue belong to stage4.
- Next approved slice: durable material candidates, acceptance/rejection/stale state, deduplication and source bookkeeping (stage4). Current stage complete and ready for review as a local diff.

## Stage 4 micro plan

User confirmed continuing stage4 in the same isolated worktree. Stage3 boundary commit e335d71. Overall architecture rev2 remains approved. Micro revision1, challenge1 VALID (materials_plan_review), accepted; implementation authorized. Stage4 exceeds initial450–600 estimate (whole scope850–1000), so follow approved re-slice rule: two sequential local review boundaries4a/4b, both delivered for this request; no new functional scope and no remote publication/merge.

| Slice | Result | Budget | Depends | Status |
|---|---|---|---|---|
| 4a | Typed durable state and coordinated idempotent import primitives, existing flows unchanged until integration | 450–600 target,1000 cap | e335d71 | accepted |
| 4b | Durable proposal inbox, generation/accept/reject/source freshness/recovery integration | 450–600 target,1000 cap | accepted4a | accepted |

**Goal:** Validated Markdown/canvas proposals survive closure/restart and can be reviewed/accepted/rejected without duplicate cards or lost decisions; stale/missing/conflicted sources block new acceptance.
**Boundary:** Stage4 only, no Today/lessons/jobs/background analysis. Preserve existing topic generation/manual practice and legacy flashcards JSON array. Plain Codable versioned .workspace/study-state.json holds records/intents, never Generable DTOs/model credentials/configuration/runtime epochs/rendered images. Source metadata retains vault/document UUID, semantic revision,path,page/region,quote/origin. App-managed moves update paths; external metadata-less Markdown rename can remain missing, no whole-vault identity scan/download.
**Done when:** Persist validated proposals before publishing successful generation; cancellation clears transient presentation, not durable records. Pending/accepted/rejected disposition stored separately from current/stale/missing freshness; history survives source changes. Exact all-five-field NFC/whitespace/case-normalized structured fingerprint dedupes library/proposals; rejected equivalents suppressed for same document/page/region across revisions. Source freshness uses DocumentContent.contentRevision (chat/applied-proposal changes excluded); fresh coordinated source validation including unresolved cloud conflicts required before a NEW acceptance. Saved inbox acceptance does not require live editor or old provider settings. Dirty/conflicted live sessions also block. Empty-card library still exposes proposals.
**Implementation Steps:**
1. 4a: add StudyMaterialState DTOs (schemaVersion explicitly decoded; candidates, source/fields, journal). Extend existing writer with typed state load/CAS/recover, per-target conflict markers/copies; reuse byte coordination helpers without broad persistence framework.
2. 4a: dedicated FlashcardStore FIFO import derives target(existing exact match or new stableUUID) and raw pre-import revision from committed cards, calls persistIntent callback while retaining FIFO ownership; callback must persist state directly under the owning material transaction, not re-enqueue into either store. Optional material/operation IDs preserve legacy decoding.
3. 4a: dependent writer coordinates study-state read with card-file write; verify supported state/version, committed raw state revision, no markers, current raw card revision immediately inside critical section. No-op existing link still checks CAS and preserves all card fields. No await within coordinated accessors.
4. 4a: recovery stabletarget exists→link/ack without overwrite; absent +unchanged pre-import revision→create intended card; absent +changed revision→block explicit ambiguity, never silently resurrect. Missing/malformed/newer state or dependency mismatch blocks import. Tests inject failures at intent/import/ack boundaries and preserve both conflicting versions.
5. Review/verify4a and preserve local boundary commit; continue4b in same worktree on dependent branch codex/yohaku-study-material-library.4a is not completion of functional stage4.
6. 4b: add observable StudyMaterialStore FIFO/epoch state owner using same writer instance as FlashcardStore. Open cards/state and replay pending intents before dependent actions. Intent write→idempotent card import→ack; durable intent is acceptance point, so replay completes historical accepted intent even if source later changed. Ordinary pending proposals still require fresh source.
7. 4b: ambiguity recovery offers explicit cancel-intent, retains proposal pending; a NEW acceptance must revalidate current source. State/card conflicts preserve copies with explicit saved-version recovery; unknown state versions never overwritten and block dependent material operations (unrelated manual cards/practice remain available).
8. 4b: integrate persisted generation results and UUID-keyed immutable preview/inbox accept/reject/status; library entry visible with zero cards, restart/resume source provenance and history. Add VaultStore.load(_:rejectConflicts:Bool=false) check inside coordinated read, keep default behavior. Refresh known source paths only; no missing source treated as empty/current and no provider/session identity requirement for saved-proposal acceptance.
**Verifications:** 4a focused tests legacy/normalization/different readings/examples/schema decoding; malformed/newer/missing state; dual-file CAS and conflict copies/recovery; intent failure leaves cards unchanged; crashes before/after card commit, edited target preserved, deleted target ambiguous, FIFO target planning and queued vault switch.4b tests restart/reject-regenerate/history/dedupe, partial acceptance+ack replay, source rewrite/delete/app-managed move/page removal/chat-only changes/unresolved versions, state dependency changing while queued, unknown version indirect-write protection; UI empty library→saved proposals after relaunch→accept/reject→card provenance, existing Markdown/canvas regressions. Default Xcode (no forced TOOLCHAINS), task-derived /tmp/yohaku-study-persistence-derived, iPhone17 sim6F9BD654-279F-41A0-B328-C9C2020618C8. Scoped unit/UI runs with precreated/truncated resultStreamPath, sequential Catalyst compile. No real provider requests or distributed iCloud merge/quality claims.

No unconditional source/state/cards distributed transaction is promised. A fresh source read precedes acceptance; state/card dependency is checked in coordinated write. Unobserved external rename and independently mutated content-addressed assets retain existing limitations. State support/revision must be rechecked at import, not only at open. Source/model content validation is not linguistic correctness proof.

4a exact paths: App/StudyMaterialState.swift (new); App/StudyFileWriter.swift; App/FlashcardStore.swift; Tests/StudyMaterialPersistenceTests.swift (new); limited Tests/FlashcardPersistenceTests.swift updates; generated Yohaku.xcodeproj/project.pbxproj.
4b future paths (not active write assignment): App/StudyMaterialStore.swift (new); App/WorkspaceModel.swift; App/FlashcardsView.swift; Packages/StudyKit/Sources/StudyCore/VaultStore.swift; Tests/StudyMaterialStoreTests.swift (new); focused existing source tests/UITests; generated project. Any essential extension returned to root before writes.

| Owner | Deliverable | Write paths | Shared resources | Worker | State |
|---|---|---|---|---|---|
| stage4-root | plan/evidence and integration acceptance | docs/tbd/decompositions/2026-10-17-personal-daily-study.md | none | root | accepted |
| material-core | 4a primitives and focused checks | App/StudyMaterialState.swift; App/StudyFileWriter.swift; App/FlashcardStore.swift; Tests/StudyMaterialPersistenceTests.swift; Tests/FlashcardPersistenceTests.swift; Yohaku.xcodeproj/project.pbxproj | simulator:6F9BD654-279F-41A0-B328-C9C2020618C8; derived-data:/tmp/yohaku-study-persistence-derived | /root/materials_research | accepted |

### Assignment stage4-root

**Goal:** Complete functional stage4 through sequential4a/4b, accept independent review and actual checks.
**Context:** User continuation, approved overallrev2, stage3 baselinee335d71; root owns doc only.
**Constraints:** Preserve primary checkout and worker source ownership; no remote publication/merge; no new project memory surface.
**Done when:** Record both local boundaries and verified full-stage behavior/limits; do not finish at infrastructure-only4a.

### Assignment material-core

**Goal:** Implement4a typed durable state/dependent import safely.
**Context:** Stage4micro1; accepted research; gpt-6.1-sol high originallyfresh; exact active targets above; branch codex/yohaku-study-material-persistence.
**Constraints:** No writes before independent challenge accepted; sole listed source/test owner, root owns plan; no delegation, later-stage changes, commits/push or broad refactor. Scoped test additions/runs authorized by plan+user. Worktree CodeGraph unindexed; no indexing. Use xcodebuildmcp-cli, default Xcode/task cache; no shared cache deletion.
**Done when:** Return Status/Result/Evidence/Gaps, exact code size/source/checks/logs; interfaces support4b without unsafe bypass or new framework. Source unchanged for final tests/review; no completion claim for whole stage4 yet.

- Stage4 micro1 audit VALID, no blockers. Add regression: rewrite source while acceptance waits behind card FIFO; source freshness must be rechecked in intent-persistence callback near durable commitment, not solely before queueing. Source read is still not a distributed transaction.4a implementation active;4b remains required for completion.


## Stage 4a acceptance and 4b ownership

4a accepted: independent materials_core_review PASS (no blockers), root inspected integrated import/writer/DTO diff. Scoped StudyMaterialPersistenceTests and FlashcardPersistenceTests:19 functions/23 case records passed,0failed/0skipped. Logs /tmp/yohaku-study-material-4a-tests.log; /tmp/yohaku-study-material-4a-results.jsonl. Reviewable433lines, generated8excluded; diff --check clean. Catalyst deferred to integrated4b. Full stage4 remains incomplete until4b verified.

| Owner | Deliverable | Write paths | Shared resources | Worker | State |
|---|---|---|---|---|---|
| material-library | 4b persistent proposal workflow and focused verification | App/StudyMaterialStore.swift; App/WorkspaceModel.swift; App/FlashcardsView.swift; App/FlashcardStore.swift; Packages/StudyKit/Sources/StudyCore/VaultStore.swift; Tests/StudyMaterialStoreTests.swift; Tests/StudyMaterialPersistenceTests.swift; Tests/MarkdownStudyTests.swift; Tests/CanvasStudyTests.swift; UITests/WorkspaceUITests.swift; Yohaku.xcodeproj/project.pbxproj | simulator:6F9BD654-279F-41A0-B328-C9C2020618C8; derived-data:/tmp/yohaku-study-persistence-derived | /root/materials_research | accepted |

### Assignment material-library

**Goal:** Complete functional stage4 with persistent generation/proposal library, safe accept/reject/source freshness and recovery.
**Context:** Approved overallrev2 and Stage4micro1 VALID; accepted4a; same worktree dependent branch codex/yohaku-study-material-library. Worker gpt-6.1-sol high, existing bounded source context. Shared StudyFileWriter, direct intent callback inside material transaction/card FIFO, typed DTOs/import APIs in4a. App/StudyMaterialState.swift sourceSuperseded makes transcription invalidation sticky.
**Constraints:** Sole writer of exact listed paths; root owns canonical plan. No delegation, commits/push, Today/jobs/background or broad refactors; return essential path additions before writes. Preserve source history, legacy/manual flows, no live provider requests/shared-cache deletion. Approved focused test additions/runs and final Catalyst via xcodebuildmcp-cli. New proposals saved before preview success, restart acceptance independent of live editor/config; source checked after cardFIFO wait, inside callback. After canvas confirmed transcription edit, old pending proposals must remain stale across close/reopen; normal close preserves valid proposals. Keep review size target600/cap1000; report early if exceeded.
**Done when:** Return Status/Result/Evidence/Gaps with exact paths/size/logs and limitations, source frozen for independent review. Scoped unit/UI restart/accept/reject/stale/recovery plus Markdown/canvas regressions and Catalyst pass; full4b acceptance remains root responsibility.

4a local boundary d6fbe06;4b active on codex/yohaku-study-material-library in the same isolated worktree. No push/remote PR.

4b implementation estimate750–900reviewable lines (store+UI+source guards+focused tests), exceeds600target but within1000cap; root accepts coherent workflow boundary, no optional scope.


## Stage 4 recovery addendum — micro revision2

start re-research: fault-injection test showed raw-byte ABA. Import followed by deletion can restore an existing flashcards.json exactly to its pre-import bytes, so raw revision equality cannot establish that the missing target was never created. Accepted4a journal remains intact; affected automatic missing-target replay criterion is invalidated. Other4b corrections/checks continue independently.

Research: FlashcardStore.importMaterial calls shared applyImport for ordinary new imports; recoverMaterialImport calls it for historical recovery. Missing-target branch currently allows creation on revision equality. Separate historical recovery flag permits conservative guard without DTO/storage expansion. Worker materials_research confirmed narrow feasibility; root selects conservative ambiguity for any previously existing card file. No tombstones/generation framework added.

**Goal:** Prevent automatic restoration of an app-deleted target after an add/delete raw-byte ABA, while preserving ordinary imports and safe replay of existing targets.
**Boundary:** Additional owned correction targets App/FlashcardStore.swift and Tests/StudyMaterialPersistenceTests.swift; no writer/DTO/schema change. Preserve card FIFO/CAS/dependency/version checks. Ordinary imports may create in existing libraries. Existing target replay preserves edits. No Today/background or remote actions. This narrows automatic recovery; explicit cancel-intent and fresh source-validated acceptance remain available. External removal of the entire card file after an initially absent-file intent cannot be distinguished by this raw-file contract; physical/two-device intervention is not claimed.
**Done when:** Historical missing target auto-creates only when expectedCardRevision==nil AND current revision==nil; historical target absent with nonnil prior revision is ambiguous even when raw bytes match. Initial imports remain unchanged. Integrated reopen preserves cancellation action; cancel leaves pending, subsequent explicit acceptance revalidates source. Already-created target links/acks without overwritten edits.
**Implementation Steps:**
1. Add private historical-recovery flag to applyImport; only recoverMaterialImport sets it; gate missing-target creation conservatively.
2. Add focused real-writer regressions: existing file add/delete returns exact prebytes→replay ambiguous; empty existing[] likewise ambiguous; absent file/absent target can resume; ordinary imports into existing library still pass; existing target edits survive.
3. Recheck corrected protocol independently with scoped source review; run affected core+store tests, UI recovery workflow and final Catalyst with4b.
**Verifications:** Direct4a regression measures actual byte equality for ABA then asserts ambiguity/no resurrection. Existing nil-file pre-cardcommit resume remains green. Existing target replay and full ordinary imports remain green. Integrated Workspace ambiguity survives automatic freshness refresh and exposes cancel. Same permitted scoped test tools/caches/Simulator; no broad fullsuite.

Stage4 plan challenge dispatch1 VALID; revision2 affected-rule challenge dispatch2 pending (cap2). User authorization for approved implementation/recovery remains; no requested outcome removed, conservative manual recovery uses existing UI. No affected core edits before audit acceptance and validated ownership transfer.


Revision2 focused challenge dispatch2 VALID, no blockers (materials_recovery_plan_review). Root accepts conservative rule; core correction ownership transferred to material-library worker: App/FlashcardStore.swift and Tests/StudyMaterialPersistenceTests.swift, in addition to previous4b paths. Assignment material-library now includes revision2 implementation/targeted regressions. Both originalreviewed interfaces preserved except private historical replay guard; no DTO/schema/writer change. No further plan challenge dispatches available for Stage4.

Initial4b independent source review materials_library_review found4blockers: duplicate normalized returnIDs, missing existinglibrary suppression, ambiguity flag cleared by blockedrefresh, reopened-scope transcription invalidation. Root accepted all; worker corrections authorized and inprogress. Globalpending exactdedupe clarified; rejectedhistory suppression remains sameScope. Root will inspect each correction and final evidence before acceptance.


4b correction review materials_core_review PASS againstd6fbe06: reviewed historical-only conservative replayguard; real byte-equal ABA regression; unique globalpending/returned IDs and existingplainlibrary suppression; ambiguity preserved through blockedrefresh/mutations; reopened/in-flight source-scope transcription supersession includingcrossscope reusedIDs; knownsource availability check avoids automatic iCloudhydration. Root inspected decisive diffs. No further sourcejudgment gaps; finalcheck evidence pending.

Earlier4b checks: firstunit failure was testadapter concreteactor dispatch selecting asyncdefaultfallback, corrected existentialforwarding. Second ambiguity fixture exposed raw-byte ABA and caused acceptedrevision2 (not merely changedtestprecondition). Intermediate46functionsPASS predatesfinalguard/globaldedupe and is not finalcandidate acceptance. Existing3sourceUI regressions passed; newrestart flow rejectaction needed lazyFormscroll inautomation. Finalunits/UI/Catalyst rerun oncorrectedcandidate.


## Stage 4 final verification

- Final reviewed candidate on codex/yohaku-study-material-library against4a d6fbe06; source frozen,779reviewable lines including newStore/tests+revision2, excludesdocs/generated. Independent correctionreviewPASS, rootinspected corresponding source/tests and final logs.
- Final focused Simulator units48functions/70caseevents,0failed/0skipped; invocationFinished confirmed. Log /tmp/yohaku-study-material-4b-unit-final.log; stream /tmp/yohaku-study-material-4b-unit-final-results.jsonl. Actual iPhone17 iOS26.3.1, Xcode26.6.1. Includes core/material persistence+existing Markdown/canvas regressions, rawbyteABA, source afterFIFO wait, dedupe, restart, edited/reopened/crossscope transcription supersession, ack replay/ambiguity, move/delete/page removal, manualcards with unsupported state.
- Final UI4/4 passed,0failed/0skipped; invocationFinished confirmed. Log /tmp/yohaku-study-material-4b-ui-final.log; stream /tmp/yohaku-study-material-4b-ui-final-results.jsonl. Markdown and canvas page/realregion regressions plus durable restart flow accept/reject/stale and explicit cancel→freshaccept recovery. Form lazyoffscreen controls scrolled beforequery. No productsource changes after finalunits.
- Final MacCatalyst compile PASS; log /tmp/yohaku-study-material-4b-catalyst.log. Root verified success in log; worker verified fresh Debug-maccatalyst app binary. Only existing MarkdownEditor UITextItemInteraction deprecations. No real external provider inference, physicalPencil/handwritingquality or two-deviceiCloud validation. Initially absentfile→external entirefile deletion retains documented raw-file boundary; no unconditional distributedatomicity claim. Stage5Today notimplemented yet.


Stage4 functional implementation accepted by root: durable proposal save/restart/accept/reject/freshness/history/exactdedupe/sourcebookkeeping and safe journal recovery complete, with scoped tests+UI+Catalyst and independent review. Root verified final diffscope and logs. Actual final4b size confirmed: tracked364 added+removed +newStore178 +newtests237 =779,8generated projectlines excluded. Within1000cap; exceeds600target for coherent completeworkflow and regressions. Full4a localcommitd6fbe06 retained;4b changes remain reviewable uncommitted in codex/yohaku-study-material-library, same /Users/vlad-prusakov/.codex/worktrees/yohaku-study-persistence/Workspace. No push/remote PR/merge performed; primarycheckout untouched by this stage. Next approved overall slice5: Today planner/screen, not started by currentstageworker.


## Stage 5 intake and research

User confirmed stage5 implementation on2026-10-17. Stage4 boundary363c896 preserved after reviewed unit/UI/Catalyst checks. Same isolated worktree; dependent localbranch codex/yohaku-today-study. No remote PR/push/merge. Re-entry: approved map remains valid; Stage5 is a local personal daily selection and working manual-practice entry, Stage6 owns durable lesson progress. No new provider/background scope.

| Owner | Deliverable | Write paths | Shared resources | Worker | State |
|---|---|---|---|---|---|
| stage5-root | plan/evidence and acceptance | docs/tbd/decompositions/2026-10-17-personal-daily-study.md | none | root | accepted |
| today-research | current code facts and bounded proposed contract | none | none | /root/today_stage5_research | accepted |

### Assignment stage5-root

**Goal:** Complete authorized Stage5 in same worktree with useful Today selection and existing manual practice, independent review and scoped evidence.
**Context:** User da after Stage4 delivery; approved overallrev2, Stage4 baseline363c896, branchcodex/yohaku-today-study. Currentphase research; Stage5 microplan notyet selected/audited.
**Constraints:** Rootowns doconly; preserve primarycheckout, no remote publication/merge. Sourcewriting delegated onlyafter current microgate/ownership.
**Done when:** Accept actual Stage5 behavior/checks, record limits and nextslice6; no resumedlesson persistence claim.

### Assignment today-research

**Goal:** Establish relevant code facts and propose bounded Stage5 microcontract.
**Context:** freshgpt-6.1-sol high; current Stage5 Research, baseline363c896; read current planner/practice/navigation owners and approved map.
**Constraints:** Readonly/no tests/builds/sourcewrites/commits/delegation/usercontact. No new Today jobs/provider requests/durable sessions. CodeGraphunindexed, no indexing. Exact source anchors, scoped output, no .memory writes.
**Done when:** Status/Result/Evidence/Gaps with current facts, proposed exacttargets/interfaces/checks/budget and unresolveddecisionchanginggaps; root selects final design.


## Stage 5 micro plan — revision1

Research accepted (today_stage5_research). FlashcardPracticeQueue.priority/exercise reusable; FlashcardStudyView.start currently resamples and caps20, so needs narrow supplied-exercises seam. Material import precedes acknowledgement, so materialID cards require matching accepted record/cardID and usable material-state; manual/legacy materialIDnil stay independent. No reliable source timestamps/application records; honest reason is sourcepath, not yesterday. Existing misleading Today library label split without changing open-flashcards/reminder routing. Currentdate Date() alone does not drive observation.

<!-- stage5-plan:start -->

## Goal

A useful local Today collection, bounded by chosen duration, with reasons and exact selected main round in existing practice.

## Boundary

Stage5 only; new App/DailyLessonPlanner.swift and App/TodayView.swift; narrow App/WorkspaceView.swift, App/WorkspaceModel.swift, App/FlashcardsView.swift, App/FlashcardStudyView.swift; new Tests/DailyLessonPlannerTests.swift; focused Tests/FlashcardPracticeTests.swift and UITests/WorkspaceUITests.swift; generated Yohaku.xcodeproj/project.pbxproj. Preserve scheduler, quiz/manual practice defaults, legacy storage and proposal decisions. No durable session/day-consumption state, jobs, provider calls, new exercise types or inferred source dates. Same worktree baseline363c896. Budget480–600target,1000cap; report before expansion.

## Done when

1. Default10min;3/10/20 choices allow at most6/20/40 main-round elements and1/3/5 unused(reviewCount0), approximately30sec each. Selection can be shorter. Copy explains estimates and extra mistake round.
2. Only dueAt<=now eligible. Reviewed due first, descending existing priority (recent difficulty/error/lateness), then dueAt ascending and UUID stable tie break. New candidates oldest createdAt thenUUID, withinlimit/remainingcapacity. No future fillers/randomness.
3. Material-linked cards require supported/conflict-free loaded state and matching accepted material/cardID; unresolved pending imports excluded. Ordinary manual/legacy cards remain usable when materialstate unavailable. Cardstore load/error/block state has actionable library/recovery path, no empty-success claim.
4. Each row gives a truthful primaryreason (lastRatingforgot→error lasttime; hard→difficult; otherdue→time toreview; unused→new) plus knownsourcepath ifavailable. No yesterday claim. Empty/short states offer library and source/document navigation.
5. Preview responds to storechanges, selectedduration, periodicclock, foreground, day/timezone/significant clock changes. Use explicit now/calendar for pureplanner tests; no persisted date identity. Start revalidates current eligibility of displayed IDs and preserves order; if eligibility changed, update preview/explain and require new Start, no silent replacements.
6. Existing practice accepts optional supplied exercises, no randomresampling/20truncate when supplied. It resolves current cards byID and filters deleted/ineligible inputs; manual nilselection path remains unchanged. Today launch uses cards mode/current source state; vault changes dismiss/discard Today launch. Existing mistake retry behavior/scheduler preserved.
7. Separate Today navigation works compact/iPad/Catalyst; existing library+open-flashcards/reminders remain reachable. Library segment formerToday relabeledRepeat. Pending proposals never autoaccepted. No durable lesson/resume promise in copy.

## Implementation Steps

1. Add pure value DailyLessonPlanner +duration/plan/item/reason types, reuse existing exercise/priority, deterministic eligibility/sorting/caps/daykey. Add narrow shared supplied-selection resolution helper only where needed; no newframework.
2. WorkspaceModel owns selectedduration in memory; TodayView composes native durationpicker, estimate/short/empty/status/list+source/reason and library/source actions, clock invalidation, captured selected launch and startguard. Reuse current style and SwiftUI ownership patterns; avoid multiple competing navigation booleans.
3. WorkspaceView wires Today and retained library across existing navigation variants, relabel library segment, keep deep-link/reminder path. Narrow optional exercises input in FlashcardStudyView; main round order/count exactly displayed and deletion never causes unrelated replacement.
4. Focused planner/practice tests and deterministic UI fixtures cover selection→exactpractice and empty/recovery/navigation/clock. XcodeGen, scoped Simulator units/UI, serialCatalyst, independent code review; fix in-scope regressions.

## Verifications

- Fixed clock planner: due boundary/future exclusion, recentvsold failure ordering, deterministic ties, duration capacities/newlimits, sparse/empty, duplicateIDs defensive handling; accepted/pending/missing records/conflictedunsupported state; manualcards independent; midnight/timezone daykeys. No model calls.
- Supplied practice helper/session: exactorder/count including>20, deleted/future cards excluded without substitution, manual nilselection selection behavior preserved. Starteligibility changed/vaultswitch guard inspected+targeted tests whereappstateexposes them.
- UI: Today→duration/reasons→exactfirst exercise/maincount; library/manual/quiz/reminders preserved; empty→library/source; time-dependent preview changes under controlled fixture/clock and foreground invalidation; compact runtime, regular/Catalyst wiring compilation. Use explicit IDs. Targeted tests additions/runs already authorized by approvedoverallVerifications+userimplementation request.
- xcodebuildmcp CLI(defaultXcode, no forcedTOOLCHAINS), taskderived /tmp/yohaku-study-persistence-derived, iPhone17 sim6F9BD654-279F-41A0-B328-C9C2020618C8. Precreate/truncate unique resultStreamPath, retain completed summaries+events. Sequential Catalyst generic/platform=macOS,variant=Mac Catalyst CODE_SIGNING_ALLOWED=NO. No whole-suite or liveexternalprovider/physicaliCloud claims.

<!-- stage5-plan:end -->

Stage5 challengecount0 before dispatch. Root owns canonicaldocument only; sourceowner below planned until audit acceptance.

| Owner | Deliverable | Write paths | Shared resources | Worker | State |
|---|---|---|---|---|---|
| today-implementation | Stage5 planner/screen/practice integration and scoped verification | App/DailyLessonPlanner.swift; App/TodayView.swift; App/WorkspaceView.swift; App/WorkspaceModel.swift; App/FlashcardsView.swift; App/FlashcardStudyView.swift; Tests/DailyLessonPlannerTests.swift; Tests/FlashcardPracticeTests.swift; UITests/WorkspaceUITests.swift; Yohaku.xcodeproj/project.pbxproj | simulator:6F9BD654-279F-41A0-B328-C9C2020618C8; derived-data:/tmp/yohaku-study-persistence-derived | /root/today_stage5_research | accepted |

### Assignment today-implementation

**Goal:** Implement and verify accepted Stage5 micro1 with useful Today and exact selected manualpractice.
**Context:** Userda authorizes Stage5, overallrev2 accepted, Stage4 baseline363c896, same branchcodex/yohaku-today-study. Worker originallyfreshgpt-6.1-sol high, research accepted. Stage5 micro1 challengepending; no sourcewrites beforegate.
**Constraints:** Sole writer exactlistedsource/test/generated paths, rootownsplan. No delegation, commits/push, newframework, persistence/resume/Todayjobs/providers, broadrefactors, sharedcachedeletion or liveinference. Return essentialpathadditions beforewrites. Read SwiftUIpatternrelevantrefs and xcodebuildmcp-cliskill beforeUI/build; scope tests permitted by userapprovedplan. CodeGraphunindexed/noindex. DefaultXcode/taskcache, serialsim/Catalyst.
**Done when:** Return Statusready|needs_research|needs_replanning|blocked; Result exactchangedpaths/size/behavior/limits; Evidence sourceanchors and actualchecks/logs/candidate; Gaps. Source/testfreeze for independentreview; rootacceptance separate.

Stage5 micro1 challenge dispatch1 VALID, no blockers (today_stage5_plan_review); rootaccepted. Research/authority/design settled; sourcewriting and scoped checks now authorized per Assignmenttoday-implementation. Rootdoconly, batchvalidation beforedispatch. Runtimefailure handling must remain actionable even if previous library alert was dismissed; no hidden blockedstart with no recoverypath.


Stage5 first code review (today_stage5_code_review) completed with one P1: Today root-change observer could rebuild old cards before openVault finished identifier/stores; same-URL reopening also lacked invalidation. Root accepted finding; worker correcting observable generation/readiness before first suspension, Start/preview/launch gates, and integrated paused-reopen regression. This is correction of accepted vault-guard criterion, not scope expansion. Other core areas had no blockers. New planner-test registration must be regenerated before final scoped runs; early build/unit invocations are not final evidence.

Initial dependency preparation fetched existing MLX submodule into task cache; progressing download completed without SDK/lockfile/cache policy changes. Initial Simulator build passed before final fixtures/correction. Final unit/UI/Catalyst evidence still pending.


Stage5 P1 correction inspected/accepted by root: WorkspaceModel dailyLessonContext/dailyLessonVaultReady reset synchronously before first openVault await, current-context guards through store opening/completion, only current completed vault enables Today. Today Start/readiness gate and context observer discard launch/preview, including sameURLreopen. Integrated paused-writer switch/reopen regression included; no writer/schema change. Root inspected diff and registered test identifiers.

Final app-source units14/14 passed,0failed/0skipped; result events14Success and invocationFinished verified by root. Suites DailyLessonPlannerTests5 +FlashcardPracticeTests9. Log /tmp/yohaku-stage5-unit-final.log; events /tmp/yohaku-stage5-unit-final-results.jsonl. Covers caps/newlimits/due/reasons/determinism/ackgate/dayzone/vault/supplied>20/currentIDresolve +existing practice behavior. Subsequent changes only UItest harness.

Initial UIbatch6cases:5passed (Today exactselection/duration, empty library/source/reminder navigation, recovery, existing quiz, existing reminders); clock/foregroundcase terminatedSIGTERM without assertion. InvocationFinished retained after stopping only task-owned stalled diagnose child; no sharedservice reset. App crash not established. New harness had mainactor Thread.sleep22s; changed only harness to asyncTask.sleep +asyncfulfillment, no productsourcechange. Exactclock/foreground +existingmanualswiperegression rerun inprogress; finalCatalyst pending. Currentreviewable435lines excludingdocs/generated, target600met.


Stage5 final Simulator evidence: root verified logs/events. Units14Success/invocationFinished as above. Seven distinct UI flows now successful across final runs: StudyReminderUITests/testReminderSettingsOpenFromEmptyLibrary; WorkspaceUITests/testQuizIncorrectChoiceReturnsInSecondRound, testTodayEmptyLibraryAndSourceNavigation, testTodayExactSelectionAndDuration, testTodayRecoveryActionReloadsCards (initial5success); testSwipeRatingsAndSecondRoundOfMistakes and testTodayClockAndForegroundRefresh (final2success). Final rerun2/2,0failed/0skipped, invocationFinished; /tmp/yohaku-stage5-ui-clock-manual.log and -results.jsonl. Original /tmp/yohaku-stage5-ui.log and -results.jsonl retain5Success/1Failure(SIGTERM), not claimed fullypassing. Only test harness wait changed toasync; app source unchanged, so other5UI evidence remains valid. Clock case verifies actual future→due periodic transition and return from background. Existing manual swipe/mistake, quiz and reminder paths remain working. Catalyst compile active; acceptance pending thatrequiredresult.


## Stage 5 results — accepted

Этап5 принят root после проверки diff, исправления P1, тестов и сборки. Та же worktree /Users/vlad-prusakov/.codex/worktrees/yohaku-study-persistence/Workspace; ветка codex/yohaku-today-study, база363c896. Изменения этапа5 оставлены незакоммиченными для просмотра; публикации/PR/merge нет, основной checkout не изменялся.

Отдельный экран «Сегодня»:3/10/20мин, по умолчанию10; оценка30сек/элемент, основной круг до6/20/40 элементов и до1/3/5 новых. Сначала наступившие повторения по существующему приоритету сложности/ошибок, затем новые в оставшемся объёме. Будущие карточки не добавляются для заполнения. Видны причины выбора и сохранённые пути источников; принятые материалы сохраняют доступность при изменённом/удалённом источнике. Непринятые/неподтверждённые импорты исключены, ручные карточки независимы от доступности study-state.

Запуск передаёт показанные элементы в существующую практику в том же порядке, без случайного пересбора/ограничения20. Перед стартом повторная проверка текущего содержания/доступности; при изменении предложение обновляется с объяснением. Ручная практика/quiz/напоминания сохранены; старый вход переименован «Библиотека», сегмент «Повторение». Предпросмотр обновляется по таймеру и при возвращении/смене дня/часового пояса. При смене vault до первого await сбрасываются поколение/готовность, предпросмотр и запуск; проверено повторное открытие того же пути.

Проверки:14/14 unit на iPhone17 iOS26.3.1 Simulator,7 разных UI-сценариев успешно пройдены (пять в исходном прогоне, два в окончательном повторном). Исходный SIGTERM тестового процесса сохранён в логах; после замены блокирующего ожидания теста на асинхронное сценарий времени/foreground прошёл. Код приложения после исправления P1 не менялся. Mac Catalyst build PASS /tmp/yohaku-stage5-catalyst.log; root проверил итоговый success, worker — свежий executable/debug payload. XcodeGen и diff --check PASS. Независимое ревью нашло один P1; root проверил исправление и регрессионный тест. Точный diff435 reviewable lines, документация/генерируемый проект исключены; цель600 соблюдена.

Ограничения: это локальная подборка и существующая ручная практика. Сохранение snapshot/позиции занятия, учёт дневного потребления новых элементов и однократная итоговая оценка относятся к этапу6. Новые типы применения/автоматизация/фон не добавлялись. Реальный провайдер, физическое устройство/iCloud, запуск Catalyst и фактическая смена системного часового пояса не проверялись; для дня/зоны есть тесты с фиксированными часами и программная обработка уведомлений. MLX C++17 и MarkdownEditor deprecation warnings не исправлялись как сторонние/существующие.

Следующий согласованный этап6 — возобновляемое занятие «Сегодня» с неизменным snapshot и сохранением прогресса. В рамках этапа5 не начат.
