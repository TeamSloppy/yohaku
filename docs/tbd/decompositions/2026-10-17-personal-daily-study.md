# Yohaku: записи → материалы → персональное занятие

Дата: 17 октября 2026. Статус: план согласован, этапы 1–2 реализованы и проверены в изолированной worktree. Базовая ветка: `main`. Ревизия плана: 2.

## Goal

Пользователь сохраняет запись после урока → Yohaku предлагает полезные учебные материалы с источниками → пользователь принимает подходящие → проходит короткое персональное занятие на экране «Сегодня» → результаты влияют на следующие повторения. Затем тот же цикл пополняется автоматическим анализом выбранных записей.

## Boundary

В первый выпуск входят Markdown, текстовые объекты canvas и рукописные страницы/выделенные области через текущую визуальную модель; карточки, пропуски в предложениях и короткое самостоятельное применение; занятия на 3/10/20 минут; сохранение прогресса; очередь автоматического анализа выбранных источников; обработка при запуске и доступное ОС фоновое выполнение.

Начальные значения: японский как изучаемый язык и русский для объяснений, как в существующей генерации; 10 минут по умолчанию; максимум 1/3/5 новых учебных элементов для 3/10/20 минут. Это настройки продукта, а не обещание точной длительности.

Предложения ИИ принимаются после просмотра. Существующая библиотека и ручная практика остаются полноценными путями обучения. В эту итерацию не входят собственный OCR, серверное расписание, самостоятельный курс для новичка, граф знаний и автоматическая оценка свободного ответа как единственная истина. Здесь планируются изменения и их проверки; исходный код, сборки, тесты, коммиты и публикация PR в рамках подготовки плана не выполняются.

## Context

**Current state:**

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
| 3 | Выбранная страница/область canvas проходит тот же цикл с текстом и изображением. Проверяются возможности модели и разборчивость. | `SourceContext`, `CanvasRenderer`, редактор | 2 | 350–550 / planned |
| 4 | Долговечные pending/accepted/rejected/stale, дедупликация, источники, идемпотентное принятие через журнал. Связанные объяснения и упражнения сохраняются с материалом. | новый `StudyMaterialStore`, предпросмотр, writer | 2, 3 | 450–600 / planned |
| 5 | «Сегодня» с локальным подбором, временем, причинами выбора и пустыми состояниями; подборку можно открыть в существующей ручной практике. Результат этого этапа — полезная дневная подборка; собственная возобновляемая сессия идёт следующим этапом. | новый `DailyLessonPlanner`, `TodayView`, навигация | 4 | 400–600 / planned |
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
