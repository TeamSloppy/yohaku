# Yohaku — рукописные знания, поиск и навигация

- Created: 2026-10-17
- Epic reference: запрос пользователя в текущем чате
- Trunk: `main`; исследованный исходный код: `1d93afe`
- Revision: 2; исправлены четыре блокирующих замечания независимого ревью.
- State: одобрено пользователем 2026-10-17; этапы 1/2/4/5/6/10 реализованы и включены в проверенную интеграцию с main по прямому поручению 2026-10-18. Автоматическое OCR-покрытие 7/8, граф, содержание и проверка качества реальной рукописи остаются впереди. Итоги интеграционных проверок приведены в конце.
- Size budgets: цель ≤600 добавленных + удалённых проверяемых строк на PR; 600–1000 требуют отдельного обоснования; >1000 — новая декомпозиция. Оценки ниже включают проверки, исключают документацию и генерируемые файлы.

<!-- canonical-plan:start -->
## Goal

Превратить рукописные тетради и бесконечные холсты Yohaku в доступную для навигации базу знаний: находить написанное по тексту пользователю и агенту, видеть, где находится материал, переходить к нему из содержания и настоящего графа связей. На iPad агент работает рядом с редактором. Поддерживаемые языки: японский, русский и английский; обработка локальная по умолчанию, выбранный AI-провайдер запускается только явным действием пользователя.

## Boundary

Включены `App`, `Packages/StudyKit` и `Packages/StudyIntelligence`: точные ссылки на источники, содержание, метки и темы, локальное распознавание и индекс, пользовательский поиск, инструменты агента, граф и размещение панели на iPad. Существующие Markdown, рукопись, страницы, вкладки и iCloud остаются источниками данных; незагруженные файлы не скачиваются фоновым обходом.

В эту работу не входят embeddings, векторная БД, обучение OCR, синхронизация SQLite через iCloud, распознавание формул и диаграмм как обязательная возможность, самостоятельные сетевые вызовы агента, а также соседний план `2026-10-17-personal-daily-study.md`. Общий адрес источника можно использовать в дальнейшем, без изменения того плана. План и карта одобрены пользователем; реализация выполняется локально по его последующим поручениям. Коммиты, публикация PR и merge требуют отдельного поручения.

## Done when

- C1: Ссылка из поиска, содержания, графа или ответа агента открывает нужную тетрадь, страницу и область холста; переход работает и в уже открытой вкладке, завершая активное рисование перед сменой позиции.
- C2: Кнопка «Содержание» работает у тетради и бесконечного холста без OCR: показывает страницы либо сохранённые пользователем области. После анализа добавляются распознанные фрагменты и подтверждённые заголовки/темы.
- C3: Локальное распознавание проверено на реальной рукописи JA/RU/EN. Для каждого фрагмента сохраняются текст, лексические токены, координаты, язык, доступная оценка уверенности, версия распознавателя и отпечаток исходника. Неподдерживаемый язык, ошибка и пустой результат различаются.
- C4: Поиск пользователя и агента использует один локальный индекс и возвращает фрагмент, источник, координаты и состояние покрытия; японский текст находится без пробелов. Существующий текстовый поиск сохраняется.
- C5: Открытие существующего vault, успешное сохранение, внешнее изменение, переименование, удаление, восстановление и смена vault согласуют индекс. Старое OCR-задание не возвращает удалённый или заменённый текст. Частично загруженные документы явно отмечены.
- C6: Исправленный текст, имена областей, метки и подтверждённые темы переживают перезапуск, удаление SQLite, смену распознавателя/сегментации и перенос vault. При неизменном исходнике правка восстанавливается по устойчивой авторской области; неоднозначная привязка или изменение рукописи требует проверки, сохраняя старую правку.
- C7: Граф локально и автоматически связывает две существующие тетради через наблюдаемый общий термин/тему и рёбра mentions к исходным областям, без провайдера и подтверждения каждого термина. Узлы document/page/region/observed-term/topic и рёбра имеют тип и raw/OCR provenance. Наблюдаемое OCR-слово отличается от предложенной смысловой темы и подтверждённой семантики; фильтр тем и граф используют одни данные.
- C8: На iPad, включая portrait и Split View, агент находится в боковой панели, редактор остаётся интерактивным; клавиатура и поворот не сбрасывают контекст. Поведение iPhone и macCatalyst проверяется отдельно.
- C9: Пользователь явно выбирает область/страницу и запускает анализ выбранным провайдером; до запуска виден отправляемый контекст. Локальный фон никогда не переключается на провайдера автоматически.

## Implementation Steps

Каждая строка — одна короткая ветка `codex/...` и один PR в `main`. После каждого merge проверяем фактический размер, результат и зависимости оставшихся строк. Диапазоны — предварительная оценка, а не разрешение на превышение 600 строк. Состояния первых двух этапов обновлены в ходе одобренной реализации; остальные остаются `planned`.

| # | PR / самостоятельный результат | Strategy | Размер, строк | Depends on | Status |
|---|---|---|---|---|---|
| 1 | Точная навигация к странице и области, включая переход из существующего контекстного источника | safe, завершённый переход | 300–450 | — | in-progress |
| 2 | Боковой агент на iPad при доступной ширине, с адаптивным размещением в узком окне | safe, завершённая замена размещения | 250–400 | — | in-progress |
| 3 | Содержание страниц и именованных областей с переносимыми закладками | safe, полезно без OCR | 450–600 | 1 | planned |
| 4 | Изолированный локальный индекс SQLite/FTS и многоязычная токенизация | safe, новый модуль без runtime-подключения | 450–600 | — | in-progress |
| 5 | Пользовательский поиск существующего текста через индекс с согласованием жизненного цикла vault | safe, завершённый поиск | 450–600 | 1, 4 | in-progress |
| 6 | Локальное распознавание выбранной области/страницы с результатом и поиском | safe, явное действие | 450–600 | 4, 5 | in-progress |
| 7 | Надёжная очередь и локальный backfill конечных страниц тетради | safe, infinity явно pending/unsupported | 400–550 | 6 | planned |
| 8 | Покрытие infinity: ограниченный tiling, дедупликация и стирания | safe, измеримое частичное покрытие | 450–600 | 7 | planned |
| 9 | Исправление распознанного текста, названий и меток с переносимым сохранением | safe, завершённое редактирование | 400–550 | 3, 6 | planned |
| 10 | Поиск и чтение распознанных источников агентом с точными ссылками | safe, завершённые инструменты | 300–450 | 1, 5, 6 | in-progress |
| 11 | Явный анализ выбранного источника выбранным AI-провайдером | safe, отдельный пользовательский запуск | 350–500 | 6, 9, 10 | planned |
| 12 | Содержание с распознанными фрагментами и подтверждёнными заголовками | safe, обогащение существующего содержания | 300–450 | 3, 8, 9 | planned |
| 13 | Локальный граф документов и наблюдаемых терминов/тем с источниками | safe, автоматический локальный baseline | 450–600 | 1, 3, 5, 7 | planned |
| 14 | Подтверждённая семантика тем в графе и общих фильтрах | safe, дополнение локального baseline | 350–500 | 9, 12, 13 | planned |

Детали границ:

1. `SourceContext`/новый адрес источника → одноразовый запрос перехода после монтажа поверхности → фокус на world-rect с подсветкой. Явная цель имеет приоритет над `lastInkBounds`, повторный рендер не повторяет переход. В scope — открытие ссылки текущего контекста; поиск и содержание добавляются своими PR. Cleanup: none.
2. `WorkspaceView` → устройство и доступный размер вместо порога 1200 → панель рядом с холстом. При узком iPad панель занимает адаптивную часть ширины, лишние колонки сворачиваются; она не превращается в modal и не отключает весь редактор. Без изменений логики моделей/провайдеров. Cleanup: none.
3. `DocumentEditor` → кнопка содержания, список страниц, создание/переименование/удаление закладки области → быстрый переход без распознавания. `VaultStore` добавляет новый path-backed knowledge sidecar для Markdown и canvas с проверкой ревизии; move/delete/restore сохраняют его переносимость и восстановление. Существующие Markdown records не используются как идентичность canvas. Без автоматической нарезки тем. Cleanup: none.
4. Новый изолированный компонент StudyCore → схема источников/фрагментов/токенов, транзакционная замена поколения, FTS-запрос и пагинация → единый проверяемый поисковый контракт. Нужен отдельный PR из-за самостоятельной SQL-схемы, миграций и многоязычного контракта; runtime пока не подключается. Без UI и фоновых обходов. Cleanup: none.
5. `VaultStore`, `DocumentSession`, `WorkspaceModel` → индексирование доступного Markdown и текстовых объектов, события актуализации, структурированные результаты → работающий пользовательский поиск со статусом покрытия. Пустой запрос сохраняет список документов; поиск имени сохраняется для незагруженных файлов. Без распознавания рукописи. Cleanup: none.
6. Новый локальный recognizer + ограниченный рендер источника + UI результата → распознавание выбранной области/конечной страницы, запись в локальную БД и появление в поиске. Сначала измеряем JA/RU/EN на iOS 26; при неприемлемом качестве не обещаем автоматическое распознавание этого языка и возвращаемся к выбору движка. Конечная страница рендерится целиком только в пределах пиксельного/ресурсного лимита; превышение явно ограничивает анализ. Без фонового провайдера и полного рендера infinity. Cleanup: none.
7. Commit сохранения/открытие vault → восстанавливаемая очередь конечных страниц с revision/generation guards → доступная сохранённая рукопись тетрадей догоняется после перезапуска, внешней правки и отмены. Проверять доступность каждого asset; читать и рендерить конечную страницу только с лимитом пикселей/памяти, при превышении показывать ограничение. Infinity в этом PR явно pending/unsupported для автоматического покрытия, его закладки и явный ограниченный анализ работают. Без infinity tiling. Cleanup: none.
8. Сохранённые bounds infinity → перекрывающиеся ограниченные tiles, включая отрицательные/далёкие координаты → полный обход доступного сохранённого ink с дедупликацией crossing strokes. Правки/стирания инвалидируют покрытие и удаляют устаревшие строки. Статус current допустим только после обработки всех доступных целевых tiles; пропущенные assets сохраняют частичное покрытие. Без полной гидратации iCloud. Cleanup: none.
9. UI фрагмента → правка текста/названия/меток → авторская область с устойчивым region anchor, геометрией и source fingerprint в переносимых данных. После смены движка/tiling и удаления OCR-кэша правка возвращается к той же неизменной области; неоднозначное соответствие сохраняется для review. Без привязки авторской правки только к временному OCR segment ID. Cleanup: none.
10. Обработка существующих notes tools в `AgentSession.swift` → общий запрос индекса, чтение фрагмента и `page_image(region:)` → агент получает тот же текст и покрытие, что пользователь, с лимитами, курсором и ссылками. Без скрытого распознавания или сетевого fallback. Cleanup: none.
11. UI выбора источника и `AgentSession` → явная команда анализа с возможностью отмены → предложенный текст/заголовки/темы с provenance выбранного провайдера. Пользователь подтверждает сохранение правок; ошибки не заменяют локальный результат. Это необязательное обогащение: локальный граф и темы не зависят от данного PR. Без автоматической отправки всего vault. Cleanup: none.
12. Содержание → список распознанных областей, сниппетов и подтверждённых названий рядом с закладками → полезная навигация по длинному холсту. Порядок страниц фиксированный, у infinity явно выбран пространственный порядок/группировка; нет фиктивного глобального порядка чтения. Cleanup: none.
13. Локальные лексические сегменты/повторяющиеся содержательные фразы → наблюдаемые термины/темы и рёбра mentions к областям → граф автоматически соединяет материалы из двух тетрадей через найденное общее содержание. Упоминание хранит исходный текст/OCR, offsets, source anchor и уверенность; нормализация/фильтр служебных слов детерминированы. Узлы document/page/region, contains/explicit-link, preview и переход остаются доступны. Не утверждать семантическую эквивалентность и не объединять омонимы без различения контекста; тип mentions виден пользователю. Ограниченный подграф и доступный список. Cleanup: none.
14. Темы пользователя и подтверждённые локальные предложения → confirmed-topic и общие фильтры поиска/содержания/графа → различима подтверждённая семантика поверх автоматического mentions. Предложения провайдера могут подключаться при наличии PR 11, но он не dependency; baseline полностью работает offline без него. Без embeddings и автоматического объявления совпавших терминов одной семантической темой. Cleanup: none.

Вариант интеграции для одобрения:

- **Рекомендуется постепенное включение завершённых возможностей:** PR 1–3 дают навигацию и iPad-панель, PR 5 — текстовый поиск, PR 6 — явный OCR, далее фон, агент и граф. Каждая возможность проверяема самостоятельно; временных toggle и удаления старой параллельной реализации нет.
- **Альтернатива — общий выключенный вход:** предлагаемый новый `knowledge-workspace-enabled` закрывает входы новых Search/Contents/Graph в `WorkspaceView`, а автоматический индексатор запускается только при включении. Это новая конвенция, существующая система toggle не установлена исследованием. Потребуются отдельные PR включения и удаления toggle; старый поиск работает до включения. Выигрыш — единый запуск, цена — отложенная польза и дополнительные состояния проверки. Для выбора этого варианта сначала уточняется механизм toggle и пересогласуется карта.

## Verifications

Это будущие проверки реализации. В ходе подготовки плана выполнялось чтение исходников; сборка, тесты и runtime-проверки не запускались. Точечные тесты и необходимые проверки входят в реализацию каждого PR.

| Критерий | Проверка и ожидаемое доказательство |
|---|---|
| C1 | Переход к двум разным областям уже открытого infinity, включая отрицательные/дальние координаты, и к другой странице тетради. Цель видна после layout; активный stroke сохранён; последующий refresh не возвращает к последнему штриху. |
| C2, C6 | Без OCR создать, переименовать и удалить закладку; перейти к ней после перезапуска, move и открытия копии vault. Проверить notebook с пустыми/одинаковыми названиями страниц. |
| C3 | Согласованный корпус реальных JA/RU/EN и смешанных строк с эталонной транскрипцией: CER, доля найденных контрольных запросов, ошибочные пустые ответы, время и пиковая память на целевом iPad. Принятый порог качества фиксируется до автоматического включения языка; API availability не считается доказательством качества. |
| C4 | Имена документов, Markdown, текстовые объекты, японские слова без пробелов, кириллица, регистр/пунктуация, цитаты и пустой запрос. Проверить совпадение выдачи UI/агента, сниппет, координаты, курсор и явное усечение. |
| C5, C6 | Сохранение во время OCR, move/delete/restore, move с последующим удалением SQLite, два canvas с одинаковым UUID в разных путях, внешняя offline-перестановка и авария manifest/index commit. Sidecar восстанавливается по пути и проверенному исходнику; неоднозначный orphan виден для relink. Две полные копии vault с одинаковым vault-id, но расходящимися правками, имеют независимые локальные индексы. |
| C5 | Между PR 7/8 infinity явно pending/unsupported для фонового покрытия; после PR 8 проверить частично доступный package с незагруженным drawing asset, большой infinity с crossing strokes на границах tiles. Охват измерим, дублей нет, фоновый обход не инициирует download, доступная часть остаётся доступна. |
| C6, C7 | Удалить SQLite, поменять recognizer/version/languages и tiling/сегментацию при неизменной рукописи: авторская правка восстанавливается через устойчивую область и source hash. При неоднозначности — review без потери правки. Проверить синхронизацию авторских метаданных и конфликт двух правок; обе версии сохранены. |
| C7 | Без провайдера и ручных подтверждений локально проиндексировать две тетради с общим содержательным термином: граф автоматически соединяет обе через observed-term/topic и mentions с raw/OCR evidence. Проверить отдельный вид confirmed-topic и suggested-theme, контексты омонимов, фильтр, preview и точный переход. Повторить с отключённым PR 11. |
| C8 | iPad portrait/landscape, Split View и узкое окно, открытая клавиатура, второй документ и активное рисование. Панель остаётся боковой, редактор доступен; отдельно smoke iPhone и macCatalyst. |
| C9 | Наблюдение сетевых вызовов: локальный анализ/фон не обращается к провайдеру; явный запуск отправляет только выбранный источник. Проверить отмену, отсутствие image capability, ошибку/лимит провайдера и подтверждение результата. |

Для каждого PR: релевантная сборка StudyKit/приложения, разрешённые точечные проверки затронутого контракта и source review. Проверка реального Pencil/iCloud и качества рукописи на iPad нужна отдельно от Simulator/компиляции. Новые проблемы не расширяют PR автоматически.

## Context

**Current state:**

- `VaultStore.search` просматривает имена путей, Markdown и текстовые canvas objects; drawing не распознаётся (`Packages/StudyKit/Sources/StudyCore/VaultStore.swift:280`). `notes.search` выдаёт до 40 путей; `notes.read`/`page_image` уже существуют (`Packages/StudyIntelligence/Sources/StudyIntelligence/AgentSession.swift:264`). OCR/SQLite/FTS в исследованном приложении и пакетах не обнаружены.
- `SourceContext` уже содержит path/pageID/region/text/image (`Packages/StudyKit/Sources/StudyCore/Documents.swift:83`), но `WorkspaceModel.open` передаёт страницу без области (`App/WorkspaceModel.swift:241`). Обновление `CanvasPosition` после создания поверхности игнорируется; стартовый фокус infinity идёт к `lastInkBounds` (`Packages/StudyKit/Sources/StudyCanvas/PencilSurface.swift:40`, `:92`, `:136`). Внутренний `focusOnWorldRect` можно использовать через безопасный одноразовый интерфейс (`:446`).
- Страницы имеют UUID, shard bounds и объекты (`Packages/StudyKit/Sources/StudyCore/Documents.swift:62`). `DocumentEditor` уже переключает страницы и завершает ink (`App/DocumentEditor.swift:167`, `:225`). 1024-unit shards — формат хранения, не смысловые OCR-области; crossing strokes выходят за границы shard (`Packages/StudyKit/Sources/StudyCanvas/PencilSurface.swift:330`). `CanvasRenderer` умеет рендерить world rectangle с пределом 2048px; рендер конечной страницы не покрывает infinity (`Packages/StudyKit/Sources/StudyCanvas/CanvasRenderer.swift:62`).
- Панель агента боковая только при ширине ≥1200, иначе sheet отключает редактор; compact size class может быть и на iPad (`App/WorkspaceView.swift:16`, `:112`, `:131`). `AgentPanel` уже выделен отдельно (`App/AgentPanel.swift:10`).
- Данные сохраняются через координацию файлов, immutable drawing assets и manifest последним (`README.md:112`; `VaultStore.swift:165`). Успешный save/conflict проходит через `DocumentSession.swift:92`. Существующие records вычисляются по hash(path) и читаются/пишутся для Markdown (`VaultStore.swift:74`, `:172`); canvas загружается из manifest. Move переносит такой record (`:241`, `:292`), но это не готовая стабильная идентичность canvas. External/vault lifecycle есть в `WorkspaceModel.swift:110`, `:378`, `:424`. Фоновый обход учитывает локальную доступность (`VaultStore.swift:89`).
- Deployment target — iOS 26 (`project.yml:7`). Представленный Apple `PKStrokeRecognizer` требует iOS 27 и не подходит для базовой реализации: [WWDC26](https://developer.apple.com/videos/play/wwdc2026/203/). Vision на iOS 26 — кандидат, его фактическое качество рукописи и сочетания языков ещё не измерены.

**Expected state:** Один адрес источника и один поисковый контракт обслуживают пользовательский поиск, агента, содержание и граф. Рукопись остаётся первичным источником; анализ имеет измеримое покрытие и может быть повторён. Авторские исправления и подтверждённые связи сохраняются отдельно от восстанавливаемого кэша.

**Design:**

1. **Идентичность и координаты.** Новая переносимая привязка для Markdown и canvas — нормализованный относительный path, а не только `DocumentContent.id`: два файла с одинаковым UUID по разным путям независимы. Sidecar `.workspace/knowledge/<hash(normalized-relative-path)>.json` содержит path, source UUID и проверяемый source fingerprint. В адресе также page UUID, устойчивая авторская область/world rect; локальный namespace — hash(canonical vault root) + vault ID, чтобы скопированный vault-id не смешивал расходящиеся vault. Глобальный реестр идентичности не вводится. Координаты OCR переводятся из crop в world coordinates с учётом origin/Y; регион не равен shard.
2. **Два вида хранения.** В `Application Support` SQLite в namespace канонического root и vault ID: sources, observations/regions, lexical tokens с offsets, FTS и производные рёбра. Автоматический OCR локальный, повторяемый на каждом устройстве. В новых knowledge sidecars — авторские закладки, устойчивые region anchors, правки, названия, метки/подтверждения. `VaultStore` сериализует coordinated read/write с revision check и сохранением конфликтующей версии; проверяет path/UUID/fingerprint. In-app move согласованно переносит sidecar и оставляет alias/recovery данные; delete/restore сохраняют восстанавливаемую привязку. Whole-vault copy сохраняет относительные привязки и получает независимый локальный индекс по новому root. Неоднозначный внешний offline move оставляет orphan metadata и видимый review/relink, без догадки или удаления. В `contentRevision` анализ не включается, поэтому нет цикла autosave/reindex.
3. **Два отпечатка и авторская область.** Source fingerprint описывает исходные ink/assets, страницу и world region; analysis-run fingerprint отдельно описывает recognizer/version/languages/tile config. Задание содержит оба и generation vault; перед commit проверяется актуальный source. SQLite одной транзакцией заменяет наблюдения, токены и производные рёбра поколения; startup reconciliation закрывает crash gap после manifest commit. Авторская правка адресуется устойчивым переносимым region anchor с геометрией и source hash, а не OCR segment ID или run fingerprint. После удаления кэша/смены движка/пересегментации неизменный source восстанавливает правку по этой области; неоднозначное сопоставление сохраняется для review. Изменение самой рукописи переводит правку в stale/review, не уничтожая её.
4. **Обход и покрытие.** PR 7 вводит восстанавливаемое расписание/backfill конечных страниц после commit и при открытии vault, с ограничением полного рендера страницы. До PR 8 автоматическое infinity coverage помечено pending/unsupported. PR 8 обрабатывает infinity по сохранённым bounds, включая отрицательные/далёкие области: перекрывающиеся crops с лимитами пикселей, памяти и очереди, объединение дублей по тексту/геометрии и соседству. Новая правка инвалидирует затронутое покрытие; стирание удаляет исчезнувшие наблюдения. Перед чтением проверяется каждый drawing asset, а не только package. Статусы pending/indexing/current/failed/unavailable/stale и частичный охват видны пользователю и агенту; есть повторный запуск/перестроение.
5. **Распознавание и поиск.** Baseline — Vision image OCR на iOS 26 после измерения корпуса JA/RU/EN; runtime проверяет supported languages. Пустой текст, неподдерживаемость, низкая уверенность и ошибка различаются. Лексические токены — слова/языковые сегменты с исходными offsets, не токены LLM. Для японского — языковая сегментация и проверка исходного текста/CJK substring fallback; обычной whitespace-разбивки и stock FTS недостаточно. Нормализация и правила запроса одинаковы в UI и tools. Индекс не обещает semantic search без отдельного решения.
6. **Знания и агент.** Локальный baseline автоматически извлекает наблюдаемые содержательные термины/фразы и строит observed-term/topic → region рёбра mentions с raw/OCR текстом, offsets и source anchor. Общий наблюдаемый термин соединяет тетради без провайдера и ручного подтверждения; это доказательство упоминания, не семантической эквивалентности. Наблюдаемые OCR-слова и предложенные смысловые темы различаются; служебные/слишком частые термины фильтруются, чтобы граф оставался читаемым. Это не обещание автоматического понимания смысла. Отдельные типы — contains, explicit-link, confirmed-topic и suggested-theme; provenance и тип видны. Подтверждённая тема добавляет семантику поверх локального mentions. Провайдер — необязательное обогащение. Graph UI показывает ограниченный подграф с раскрытием, preview и переходом; темы также доступны обычным фильтром. Tools возвращают structured hits, coverage, truncation/cursor и координаты; не скачивают скрыто assets и не расширяют область анализа. Явная команда провайдера использует выбранную область, проверяет image capability и сохраняет результат только как предложение до подтверждения.

### Decision log

- 2026-10-17: Пользователь одобрил revision 2, постепенную интеграцию и начало реализации; текущий этап ограничен точными переходами и боковой панелью iPad.

- 2026-10-17: Пользователь подтвердил JA/RU/EN и локальную обработку по умолчанию; выбранный AI-провайдер — только при явном запуске.
- 2026-10-17: SQLite и сырой OCR остаются локальным восстанавливаемым кэшем; авторские правки/закладки/подтверждения переносимы. Общая SQLite в iCloud исключена.
- 2026-10-17: Реальная точная навигация выделена первым PR: существующая передача position недостаточна для поиска, содержания и графа.
- 2026-10-17: Revision 2 закрывает четыре блокера ревью: автоматический локальный mentions-граф; новые path-backed sidecars и root+vault namespace; source/run fingerprints и устойчивые авторские области; отдельные PR finite scheduling и infinity coverage.
- 2026-10-17: Независимое заключительное ревью revision 2 — VALID; все четыре блокера закрыты. Структура плана проверена; одобрение пользователя ещё ожидается. Исходники, сборка, runtime и качество распознавания этим ревью не проверялись.
- 2026-10-17: Предложены 14 PR с постепенным включением законченных возможностей. Выбор integration strategy, весь план и декомпозиция ожидают одобрения пользователя. Качество OCR и реальные ресурсные бюджеты ещё не подтверждены runtime.

## Break when

- Vision на iOS 26 не даёт приемлемой рукописи JA/RU/EN либо недоступны необходимые языки → остановить автоматическое включение затронутых языков в PR 6–8, сравнить локальные альтернативы и пересогласовать движок/границы. Не подменять это автоматическим облачным запросом.
- Реальная оценка PR превышает 600 строк или ветка не укладывается в 1–2 рабочих дня → до дальнейшей реализации уточнить размер/границу; 600–1000 допускаются только после явного обоснования, >1000 требуют нового разреза.
- Нет устойчивой идентичности при копировании/conflict document или coordinated metadata write теряет вторую правку → остановить переносимые метаданные/зависимые темы, исследовать новый path-backed sidecar и конфликтный контракт, пересогласовать схему до миграции.
- Обход infinity превышает ресурсные бюджеты, теряет crossing strokes либо создаёт дубли → остановить фоновый backfill, пересмотреть tiling/dedup; явный ограниченный анализ остаётся доступен. До измерений не заявлять полное покрытие.
- Узкая конфигурация iPad не оставляет работоспособного редактора с боковой панелью → пересмотреть распределение ширины и сворачивание колонок; modal как замену требованию не вводить без решения пользователя.
- Нужны новые сетевые фоновые операции, embeddings, изменение формата первичного документа, новые обязательные OS/API или изменение соседнего daily-study плана → отдельное исследование и изменение одобренного scope.
<!-- canonical-plan:end -->


## Implementation checkpoint — 2026-10-17

Пользователь одобрил revision 2 и поручил сначала реализовать боковую панель iPad и точные переходы к областям. Текущая ветка: `codex/ipad-agent-regions-20261017`. Проверяем первые два результата локально; исходный untracked daily-study план не изменяем. Root отвечает за интеграцию, план и проверку на Simulator; исполнители не запускают общие сборки одновременно. Отдельные PR и их отправка в текущем этапе не создаются. Остальные этапы ещё не начаты.

| Owner | Deliverable | Write paths | Shared resources | Worker | State |
|---|---|---|---|---|---|
| root | Integration and verification | docs/tbd/decompositions/2026-10-17-handwriting-knowledge-search.md; App/en.lproj/Localizable.strings | none | root | running |
| navigation | Exact source-region navigation | App/WorkspaceModel.swift; App/DocumentEditor.swift; App/AgentPanel.swift; Packages/StudyKit/Sources/StudyCore/Documents.swift; Packages/StudyKit/Sources/StudyCanvas/PencilSurface.swift; Tests/EditorTests.swift; Tests/SourceNavigationTests.swift | none | /root/region_navigation_impl | accepted |
| ipad-panel | Interactive side agent panel | App/WorkspaceView.swift; UITests/AgentPanelUITests.swift | none | /root/ipad_panel_impl | cancelled |
| palette-fix | Keep side composer reachable with native palette | App/WorkspaceView.swift; App/DocumentEditor.swift; App/AgentPanel.swift; Packages/StudyKit/Sources/StudyCanvas/PencilSurface.swift; UITests/AgentPanelUITests.swift | none | /root/ipad_panel_impl | cancelled |
| ui-fixture | Correct UI window fixture and capture evidence | UITests/AgentPanelUITests.swift | none | /root/ui_fixture_fix | accepted |
| composer-layout | Place iPad input above bottom native palette | App/AgentPanel.swift; App/WorkspaceView.swift; App/DocumentEditor.swift; Packages/StudyKit/Sources/StudyCanvas/PencilSurface.swift | none | /root/composer_layout_fix | accepted |
| rotation-baseline | Minimal independent Simulator orientation probe | none | none | /root/orientation_probe | accepted |
| handwriting-engine | Bounded snapshot rendering and local Vision OCR | Packages/StudyKit/Sources/StudyCanvas/LocalHandwritingRecognition.swift; Tests/HandwritingRecognitionTests.swift | none | /root/handwriting_engine | accepted |
| knowledge-store | Store index lifecycle and atomic OCR commit | Packages/StudyKit/Sources/StudyCore/VaultStore.swift; Packages/StudyKit/Sources/StudyCore/KnowledgeVault.swift; Packages/StudyKit/Tests/StudyCoreTests/KnowledgeVaultTests.swift | none | /root/knowledge_store | accepted |
| knowledge-core-check | Frozen index/snapshot targeted checks | none | frozen-core-uq26cx6i; task-core-check-artifacts | /root/knowledge_core_check | accepted |
| knowledge-ui | Shared search UI and explicit OCR workflow | App/WorkspaceModel.swift; App/WorkspaceView.swift; App/DocumentEditor.swift; App/HandwritingRecognitionView.swift; Tests/KnowledgeWorkflowTests.swift; UITests/HandwritingSearchUITests.swift | none | /root/knowledge_ui | accepted |
| knowledge-agent | Shared tools and trusted persistent citations | Packages/StudyIntelligence/Sources/StudyIntelligence/AgentSession.swift; Packages/StudyIntelligence/Sources/StudyIntelligence/KnowledgeTools.swift; Packages/StudyKit/Sources/StudyCore/Documents.swift; Packages/StudyKit/Sources/StudyCanvas/CanvasRenderer+Knowledge.swift; App/AgentPanel.swift; Tests/KnowledgeAgentToolsTests.swift | none | /root/knowledge_agent | accepted |
| snapshot-identity | Bind snapshot fingerprint to file identity for citations | Packages/StudyKit/Sources/StudyCore/KnowledgeSnapshot.swift | none | /root/knowledge_store | accepted |
| agent-render-fix | Preserve object/ink layer order in safe image | Packages/StudyKit/Sources/StudyCanvas/LocalHandwritingRecognition.swift; Packages/StudyKit/Sources/StudyCanvas/CanvasRenderer+Knowledge.swift; Tests/KnowledgeAgentToolsTests.swift | none | /root/knowledge_agent | accepted |
| ui-proof | Friendly page labels and retained runtime PNG evidence | App/HandwritingRecognitionView.swift; UITests/HandwritingSearchUITests.swift | none | /root/knowledge_ui | accepted |
| knowledge-app-check | Generate project and targeted iPad verification | Yohaku.xcodeproj | task-yohaku-derived; task-ipad-B064; task-handwriting-validation | /root/knowledge_app_check | accepted |
| agent-compile-fix | Correct runtime initializer actor isolation | Packages/StudyIntelligence/Sources/StudyIntelligence/AgentSession.swift | none | /root/knowledge_agent | accepted |
| knowledge-index | Local multilingual SQLite index | Packages/StudyKit/Package.swift; Packages/StudyKit/Sources/StudyCore/KnowledgeIndex.swift; Packages/StudyKit/Sources/StudyCore/KnowledgeSearch.swift; Packages/StudyKit/Tests/StudyCoreTests/KnowledgeIndexTests.swift | none | /root/knowledge_index | accepted |
| knowledge-snapshot | No-hydration immutable saved source snapshot | Packages/StudyKit/Sources/StudyCore/VaultStore.swift; Packages/StudyKit/Sources/StudyCore/KnowledgeSnapshot.swift; Packages/StudyKit/Tests/StudyCoreTests/KnowledgeSnapshotTests.swift | none | /root/knowledge_snapshot | accepted |
| lower-composer | Dock composer below conversation | App/AgentPanel.swift; App/WorkspaceView.swift; UITests/AgentPanelUITests.swift | none | /root/lower_composer | accepted |
| lower-verification | Lower composer targeted UI verification | none | task-cache-yohaku; simulator-ipad-B064; simulator-phone-6EF2; task-validation-artifacts | /root/lower_verify | accepted |

### Assignment navigation

**Goal:** C1, exact source-region navigation preserving current ink and handling existing tabs and deferred surface layout.
**Context:** Implementation, revision 2 approved; use CodeGraph first, current branch shared with root. SourceContext already has page/region; focusOnWorldRect exists; current representable ignores subsequent position changes.
**Constraints:** Own only table paths; preserve unrelated work; no delegation or external actions; no commits; root owns builds/Simulator; targeted meaningful regression tests permitted; return any material design gap. Be concrete and concise; distinguish implementation from checks and limitations.
**Done when:** Agent source links navigate to exact finite/infinite region with single-use request, correct page, visible highlight, no stale default last-ink focus or stroke loss; tests cover deferred/repeated/distinct navigation and source opening; return Status/Result/Evidence/Gaps with ownership released.

### Assignment ipad-panel

**Goal:** C8, iPad agent appears beside an interactive editor across available widths, with stable context and keyboard behavior.
**Context:** Implementation, revision 2 approved; independent of navigation writer. WorkspaceView currently uses a 1200-point cutoff and disables narrow editors. Compact size class also includes iPad.
**Constraints:** Own only App/WorkspaceView.swift and UITests/AgentPanelUITests.swift; do not edit AgentPanel, WorkspaceModel, DocumentEditor, shared test files or source owned by navigation. No builds, simulator use, commits, delegation or unrelated refactors. Root owns shared verification resources. Be concrete and concise, report actual checks and limitations.
**Done when:** iPad portrait/landscape/narrow layout embeds trailing panel, removes modal/global editor disable for agent and preserves iPhone sheet/Catalyst behavior; UI regression checks prove simultaneous panel/editor interaction and reopening context; return Status/Result/Evidence/Gaps, releasing ownership.

Panel candidate: App/WorkspaceView.swift + UITests/AgentPanelUITests.swift returned by /root/ipad_panel_impl. Root inspected source diff: inline iPad, compact navigation continuity, preserved sidebar/secondary state, 2 UI regression scenarios. Runtime/build not yet performed; waiting for region-navigation writer before generation/build.

### Assignment verification

**Goal:** Verify C1/C8 integrated candidate against iPad Simulator, with source-unit tests and UI rotation/keyboard checks; compile compatibility where feasible.
**Context:** Both implementation workers returned and released source ownership. Explicit user implementation authorization includes targeted checks in approved plan. Project Yohaku.xcodeproj, scheme Yohaku; iPad Pro11 iOS26.3 B064AD62-17E9-4D70-9C7C-48BC21F1BEB2; task-owned derived data /tmp/yohaku-agent-regions-derived.
**Constraints:** Own generated project only, simulator/build cache/artifacts; no source fixes or test edits, no commits/delegation. Use XcodeBuildMCP CLI help-first and task caches; root owns source integration. Tests: YohakuTests/EditorTests, YohakuTests/SourceNavigationTests, YohakuUITests/AgentPanelUITests, parallel disabled. Report infrastructure failures separately. Be concrete and concise, cite logs/artifacts, distinguish compile from runtime proof.
**Done when:** Generate project, build, run targeted checks and report exact pass/fail/blocked evidence; collect screenshot/UI hierarchy of seeded app when useful, avoid actual user vault. Return Status/Result/Evidence/Gaps and release simulator/build resources before root manual checks.

Integrated candidate v1: source writers released; approximately344 navigation lines plus148 panel lines including targeted tests. Independent reviewer /root/navigation_panel_review; build/Simulator verification owned by /root/navigation_panel_verify. No source mutations while compiler/checks run.

Review v1: /root/navigation_panel_review found one P2: propagate cancelled model intent to deferred surface request while preserving completed highlight. Verification stopped beforecompile after sandbox cache denial; no tests ran. Escalated retry interrupted, verifier confirmed no task compiler processes remain. Author owns scoped fix+regression test; builds held until release.

Candidate v2: cancellation propagation fixed by author; new test cancellingDeferredNavigationDoesNotReplayOrClearCompletedHighlight. Root inspected nil clears pending only; completed highlight preserved. Scoped diff check passes. Source ownership released; verification may resume.

Candidate v2 compilation failed before tests: new catch in WorkspaceModel.open(SourceContext) assigns shadowed error binding (line287). Verifier confirmed no task compiler processes remain; author assigned self.error qualification. Root added 3 new English source-region strings, plutil lint OK. Next candidate v3 requires focused test rerun; no runtime pass claimed.

Candidate v3 source review: /root/navigation_panel_review PASS; P2 resolved by nil propagation/pending cancellation while retaining completed highlight. Root plutil localization lint OK; author fixed compile catch shadowing. Runtime evidence pending focused v3 run (EditorTests, SourceNavigationTests, LocalizationTests, AgentPanelUITests) under /tmp/yohaku-agent-regions-validation.

Candidate v3 actual verification: EditorTests25/25 and Localization1/1 pass; source-navigation test notebook argument fails center/highlight/no-replay (3 assertions); infinity argument and cancellation/ink/editor-integration tests pass. UI rotation+keyboard+draft pass, close/reopen test fails canvas.isHittable after enabling selection (drawing surface intentionally covered by selection interaction). No state-update warnings in captured stdout. Verifier reports all tests/compiler/app runners stopped; automatic diagnostics being interrupted, no new builds allowed during fixes. Navigation author owns finite-page layout fix/regression, panel author owns UI selection-mode roundtrip correction. Logs: /tmp/yohaku-agent-regions-validation/unit-v3-stdout.txt and ui-v3-stdout.txt.

Candidate v4: finite notebook contentSize now page dimensions times zoom; bounded focus respects native adjusted-inset scroll range, infinity fixed window unchanged. Regression retains full target visibility, edge target and valid-pan no replay. UI selection test now verifies interception and returns to drawing before canvas hittability assertion. Both authors released ownership; root inspected changes and diffcheck passes. Verifier may rerun same targeted set.

Candidate v4 source review PASS (/root/navigation_panel_review). Actual v4 unit stdout reports 32 tests in3 suites PASS after3.735sec; includes finite notebook fix, infinity, cancellation, ink preservation, editor integration and localization. UI tests still active; do not claim UI pass yet. Verifier /root/navigation_panel_verify owns live Simulator/compiler/cache, logs focused-ipad-v4.log under /tmp/yohaku-agent-regions-validation. Other sourcewriters returned; no source edits whilechecksrun.

V4 final runtime coverage before storage interruption:32unit tests PASS (3 suites), iPad UI close/reopen/selection PASS27.751sec; rotation UI incomplete due sustained free disk444–502MiB, no assertionfailure before interruption. V3 same-panel rotation+keyboard+draft hadPASS35.292sec. No state-update warnings. Verifier stopped only taskrun and released all processes. Root removed only this task's Intermediates.noindex/Index.noindex/SourcePackages/ModuleCache.noindex; retained Build/Products/Yohaku.app, both added test sources and stdout logs. Free space recovered6.03GiB. No further compilation planned; verifier resumes installed-app UI capture/phone smoke (no send/network), may use lightweight UI automation for complete rotation evidence. /tmp/yohaku-agent-regions-validation/unit-v4-stdout.txt and ui-v4-stdout.txt preserve actualresults.

### Assignment palette-fix

**Goal:** Fix observed C8 obstruction: native PKToolPicker bottom palette covers side-agent prompt, so tap opens UIColorPicker instead of focusing prompt.
**Context:** V4 manual Maestro bug evidence /tmp/yohaku-agent-regions-validation/ipad-prompt-tap-color-picker-obstruction.jpg, ipad-panel-hierarchy.json, ipad-obstruction-reproduction.txt. Palettewindow bounds88,1082..746,1190 intersects prompt560,1126..762,1164. All build/UI resources released; source authors returned. Existing PencilSurface.updateToolPickerInset observes real picker.frameObscured but applies clearance only to canvas. No globals/crude constant spacer.
**Constraints:** Single owner for table paths, no source edits outside scope, no builds/tests/Simulator/commits/delegation. Prefer actual picker occlusion propagated through SwiftUI preference/callback and pane geometry; keep canvas interactive, do not hide palette or force keyboard as workaround. Root owns docs, verify controls fresh build after source release. Be concrete and concise.
**Done when:** Composer stays above intersecting native palette, clears reservation when hidden/moved, keyboard and rotation remain stable, no stale occlusion after page/document removal; targeted UI regression covers palette-visible prompt access and source/diff evidence returned with ownership release.

Ownership transfer: C1 navigation source accepted with unit+review evidence; prior panel assignment superseded by palette-fix under the same author. Palette-fix is the sole active source owner; this does not cancel the requested panel outcome.

Candidate v5 palette obstruction fix returned: full-window PK frame in owning screen space; generation/handle/page-guarded async callback; per-editor preference tree to AgentPanel; stable UIKit outer-frame probe and intersecting bottom clearance. Root inspected implementation, scoped diffcheck passed. New UI regression testIPadPromptAvoidsVisibleDrawingPalette establishes observed bottom-dock geometry and tests prompt access/type. Verifier stopped only taskMaestrodriver/app before formaltests; source stable. Fresh build required because task caches had been cleared; no source changes during verification.

V6 source compiled and unit32PASS4.042sec. Final XCTest35total:33pass2fail0skip; UIclose/reopenPASS, rotationmain-windowpredicate(line100) andpalettegeometrypredicate(line83)fail, actualpaletteprompttap/type/keyboardpassed. IndependentreviewpalettepipelinePASS. Rootholdsproductsource; test author readonlyanalysis identifiesambiguousapp.windows.firstMatch (AX main andpalette siblingwindows) andverticalpaletteheight-as-thickness. Manualv6AXresearchblocked byMaestrostale-device andXcodeAXNoTranslationObject; no valid newgeometryclaim. AlltaskUI/compiler/driverprocessesstopped. Next: improveonlyUITestmain-windowselection/dockgeometryanddiagnosticframeassertions, thenrerunonlyUI3 (product/unitcodeunchanged).

### Assignment ui-fixture

**Goal:** Correct ambiguous window/dock selection in UI regression without changing app source or weakening prompt/draft assertions.
**Context:** Candidate v6 app compiled,32unitPASS; twoUIpredicatefailures use app.windows.firstMatch despite native palette auxiliarywindow. Prior writer interrupted after no filechanges04:30:56..04:43MSK; root inspected same136linefile and diffcheck clean, source ownership transferred.
**Constraints:** Own only UITests/AgentPanelUITests.swift; no builds/sim/commits/delegation, no appsource changes. Use qualifiedmainwindow containingopen-agent; safe bottomdocking thickness and diagnostics. Be concrete and concise, finish mechanical edits before optional additions.
**Done when:** ThreeiPad tests use unambiguousmainwindow, bottompalette notfield-overlap assertionretained and failureslogactualframes; add smallnoSendphonecase and tempPNG capturesif straightforward, return4fields releasingownership.

Candidate v7 changes ONLY UI fixture: qualified mainWindow containingopen-agent andcanvas; bottomdock usesminimumdimension; requires actualhorizontal/bottompalette andnon-overlapprompt, diagnosticmessagesincludeall4frames. Addedphone noSend modalcase and3tempPNGcapturepaths. Productsource remainsv5reviewPASS,v6unit32PASS. Newauthor /root/ui_fixture_fix released file, root inspected; next nativeUI-onlyrun3iPadmethods thenphone1method (no repeatunitneeded). ExternalAX/Maestroinspectionfailed anddriversstopped; no geometryinferencefromthoseattempts.

### Assignment composer-layout

**Goal:** C8: composer stays directly usable with native bottom PencilKit palette, no opaque overlay blocks typing.
**Context:** V7 exactframes prove reservationfailed: palette88,1082.5,658,107.5 overlaps prompt560,1126,202.5,38 inmain834x1210. Screenshotsrootvisuallyinspected. Rootselects top composer under header for iPadinline, phone/Catalystkeepbottom. Remove ineffective occlusioncallback/preference/probe implementation entirely; no appformat/source-navigationchange. Simulator.app opened to addressseparateunappliedorientationrequest.
**Constraints:** Ownonlytablepaths, no UItests/sourceCore/modelchanges, no build/sim/commits/delegation. KeepallacceptedC1/navigation/finitefix. Be concreteandconcise, finishboundedrefactor.
**Done when:** One shared composerView reused at top on iPadinline andbottomelsewhere; no unused occlusionAPI/state/types remain; diffcheck passes, sourcebehaviorandownershipreleasedforfreshcompile+UIregressions.

Candidate v8: rootrejectedfailedocclusionreservationafterv7image/rectproof. iPadinlinecomposer nowdirectlyunderheader; phone/Catalystdefaultbottom. Removedallintroducedocclusioncallback/preference/UIGeometryprobe state (4files); nativecanvasinset/sourceNav/finitefixretained. Soleauthor /root/composer_layout_fix released, root inspected anddiffcheckpasses. Simulator.app explicitlyopenedbefore nextrun forunappliedorientationrequest; actualrotationstillrequiresdimensions/imageproof. Fresh32unit+3iPadUIthen1phoneUInativechecks authorized; allsourcewritersreturned.

### Assignment rotation-baseline

**Goal:** Establish whether the same Simulator actually rotates a minimal independent SwiftUI app, distinguishing host failure from Yohaku regression.
**Context:** V8 formal32unitPASS and2iPadUIpass; onlyactualorientation remainsportrait834x1210. PhoneformalnoSendmodal1/1PASS. BuiltYohakuInfoall4supportedorientations; appsourcehasnoorientationlock. Rootvisuallyconfirmedv8topinputdoesnotintersectnativebottompalette. AllYohakurunners/drivers/appsreleased; independentdiagnosticprobe usesonlytasktmp resources, no repositorysource edits.
**Constraints:** Own only taskdiagnosticproject/cache resourcesunder/tmp andiPadB064runtime; noYohakuproductionchanges, nootherdevices/globalservices/commits/delegation. XcodeBuildMCPCLI, boundedminimalapp+UIrotationcheck. Beconcreteconcise; reportactualgeometryandimages, no inferredpass.
**Done when:** Plainapporientationresult/runtimeevidenceclassifiedandresourcesreleased; furtherYohakuUIworkdependsontheactualbaselineoutcome.

## Итог первых двух этапов — 2026-10-17

Реализованы боковая панель агента на iPad и точная навигация к источнику. Панель оставляет редактор интерактивным, сохраняет состояние файловой колонки и второго документа. После коррекции по просьбе пользователя поле вопроса находится под перепиской, над стандартной нижней палитрой PencilKit. На iPhone и Mac расположение поля осталось прежним.

Ссылки из чата передают страницу и мировую область канваса. Одноразовый запрос ждёт готовности поверхности и завершения штриха или загрузки, отменяет устаревший фокус, подбирает масштаб, загружает нужные области и показывает подсветку. Исправлена прокрутка обычной страницы после масштабирования. Формат тетрадей не изменён.

### Фактические проверки

- iPad Pro 11 M5, iOS 26.3: прошли 32 unit-теста в трёх наборах — EditorTests, SourceNavigationTests и LocalizationTests. Проверены обычные страницы, дальние и отрицательные координаты бесконечного канваса, повторные и отменённые запросы, удаление страницы, сохранение штриха, загрузка областей и интеграция редактора. Лог: `/tmp/yohaku-agent-regions-validation/unit-v8-stdout.txt`.
- На iPad прошли UI-сценарии открытия/закрытия с режимом выделения и ввода вопроса при видимой нижней палитре. Полный выбранный прогон: 35 тестов, 34 прошли, один тест поворота не прошёл, пропусков нет. Логи: `focused-ipad-v8.log` и `ui-v8-stdout.txt` в папке проверки.
- На iPhone 17 Pro с iOS 26.3 прошёл отдельный UI-тест модального открытия, ввода без отправки и возврата к тетради: 1/1, без ошибок и пропусков. Лог: `focused-phone-v8.log`.
- Поворот не подтвердился: окно Simulator осталось 834×1210. Независимое минимальное SwiftUI-приложение без Yohaku, PencilKit и агента воспроизвело тот же сбой. Его портретный и запрошенный альбомный снимки имеют размер 1668×2420; GeometryReader показывает 834×1158. Диагностические файлы: `/tmp/yohaku-agent-regions-validation/orientation-probe`. Тест поворота сохранён, ошибка не превращена в ложный успех.
- Независимое ревью финального кода, проверка diff и проверка английского файла локализации прошли. В сохранённых логах нет предупреждений об изменении состояния во время обновления представления.

Скриншот: `/tmp/yohaku-agent-regions-validation/agent-palette-before-input-BCC7CA46-D190-4AD9-A350-D858AE96EDDF.png`.

Ограничения: физический iPad/Apple Pencil, узкий Split View и Catalyst не проверялись. Для проверки поворота нужна среда, в которой он выполняется. Остальные этапы графа, индекса рукописей и содержания ещё не начаты. Первые две строки карты остаются `in-progress` до интеграции PR; коммиты, отправка PR и релиз не выполнялись.

Все исполнители, сборки, UI-тесты, сборщики логов, драйверы Maestro и диагностический процесс остановлены. Под давлением диска удалялись только кэши этой задачи; приложение и логи сохранены. Соседний исходный план personal-daily-study не менялся.

## Коррекция положения компоузера

Пользователь попросил опустить поле вопроса после просмотра итогового скриншота. Текущая авторизация — исправить расположение без изменения боковой панели, навигации или данных. Micro: переписка занимает верхнюю часть, единый компоузер располагается снизу; на iPad до фокуса резервируется место для стандартной нижней палитры, при фокусе отступ снимается. На телефоне и Catalyst резерв не добавляется. Применённая ранее схема координат палитры не возвращается: она не прошла проверку на этом Simulator.

### Assignment lower-composer

**Goal:** Поле вопроса ниже переписки и доступно при нижней палитре и при клавиатуре.
**Context:** Прямое указание пользователя, текущая ветка и исходники сохранены; компоузер сейчас помещён сверху через composerAtTop. Известная палитра занимает107.5точек, исходное нижнее поле пересекалось с ней. Изолированная обратимая UI-правка, отдельный аудит плана пропущен; изменения пройдут review и UI-регрессии.
**Constraints:** Только App/AgentPanel.swift, App/WorkspaceView.swift и существующий UI-файл. Сохранить остальные dirty-изменения. Без сборок, Simulator, коммитов, публикации или делегирования. Root управляет проверкой. Не возвращать ошибочный pipeline координат палитры. Be concrete and concise; distinguish actual checks and unrun tests.
**Done when:** Композиция header→conversation→composer; на iPad нижнее место для инструментов резервируется вне фокуса; при вводе поле над клавиатурой; UI-сценарий проверяет фактическое положение и ввод с палитрой. Исполнитель возвращает Status/Result/Evidence/Gaps и освобождает файлы.

Коррекция компоузера, кандидат lower-v1: всегда после переписки; флаг reservesDrawingToolsSpace включён только для inline iPad; резерв128pt до фокуса, при фокусе0. TextField использует FocusState. UI-тест проверяет положение ниже фактического agent-conversation и затем непересечение с нижней палитрой/реальный ввод. Root прочитал изменённые места, diffcheck пройден; исполнитель освободил файлы. Следующие проверки — два iPad UI-сценария и отдельный phone noSend; поворот с известным независимым сбоем не повторяется.

### Assignment lower-verification

**Goal:** Verify lower-v1 composer below conversation, palette access and keyboard input on iPad; preserve phone modal input.
**Context:** Source candidate accepted by root inspection, all writers stopped. Only two iPad UI methods and one phone method; existing warm cache. Prior orientation failure independently reproduced, excluded.
**Constraints:** Own task build/cache, iPad B064 and phone6EF2, task validation output only. No source/project edits, no unit/full suite, no rotations, no sends, no commits or delegation. Use XcodeBuildMCP CLI. Be concrete and concise, cite evidence and distinguish actual pass from unrun coverage.
**Done when:** Exact selected methods have actual results, copy pre-input PNG, report Status/Result/Evidence/Gaps and release all owned processes.

Коррекция lower-v1 принята по исходникам и фактическому iPad результату: два выбранных UI-теста прошли (2/2, 0 ошибок/пропусков), Simulator26.3.1 iPad Pro11M5. Проверены компоузер ниже переписки, непересечение с видимой нижней палитрой, реальный ввод с клавиатурой, закрытие/повторное открытие и режим выделения. Root визуально проверил PNG: `/tmp/yohaku-agent-regions-validation/lower-composer/ipad-palette-before-input.png`. Лог: `ipad-test.log` в той же папке.

Отдельный phone UI-тест не дошёл до запуска приложения: установка YohakuTests.xctest/mlx-swift_Cmlx.bundle/default.metallib завершилась `No space left on device`. Формальный итог1failed,0passed; это ошибка установки, поведение iPhone текущей коррекцией не проверено. Лог: `iphone-test.log`. Дополнительные прогоны и очистка чужих кэшей не выполнялись. Navigation/unit/rotation не повторялись, их исходники коррекцией не изменялись. Root review и git diff --check прошли. Коммиты/PR не создавались.


## Продолжение — локальные рукописи и поиск, 2026-10-17

Прямое поручение пользователя: продолжить локальным JA/RU/EN OCR, поиском пользователя и агента с точными переходами. Сохраняется одобрение revision2 и naturally-safe стратегия этапов4/5/6/10; нового провайдера, формата рукописи, графа или содержания нет. Отдельные PR/публикация не запрошены; локальные этапы проверяются последовательно, без merge как побочного действия. Автоматическая очередь7/8 требует реального корпуса и не включается этим продолжением. Предыдущая ветка/dirty-работа сохраняются.

<!-- local-search-contract:start -->
## Goal

Локально распознавать выбранную страницу или область на японском, русском и английском; сохранять результат в восстанавливаемом SQLite-индексе; находить текст пользователю и агенту и открывать точный исходный фрагмент.

## Boundary

App, StudyKit, StudyIntelligence и необходимые точечные проверки. Этапы утверждённой карты4/5/6/10. Сохранить iPad-панель/нижний компоузер, существующую точную навигацию, iCloud/autosave/conflict, поиск имени недоступного документа и пустой запрос как список документов. OCR явный, после завершения штриха и успешного сохранения; конечная страница или явно выбранная ограниченная область infinity. Язык выбирается явно: JA(+EN), RU(+EN), EN. Это предотвращает наблюдённую потерю кириллицы при JA-first смешанном запросе.

Исключены фоновые backfill/tiling7/8, граф/содержание/авторские метаданные, embeddings, скрытые download и provider fallback. SQLite локальная, удаляемая/восстанавливаемая, вне iCloud. Отсутствующий корпус не подменяется печатными тестами; автоматическое включение OCR до измерений не разрешено.

## Done when

- C10: UI и агент используют один индекс; hit содержит id, исходный текст/сниппет, path/page/world rect, raw/OCR provenance и fingerprint. Есть coverage, ограничение и cursor; японские подстроки, кириллица, регистр и существующий текстовый поиск работают.
- C11: Сохранение/external refresh/reopen/move/delete/vault switch согласуют индекс; старое задание или cursor не возвращает устаревшие/удалённые фрагменты. Имя недоступного документа остаётся доступным для поиска.
- C12: Явное OCR проверяет runtime язык, лимиты и доступность каждого файла; отличается empty/unsupported/unavailable/failed/recognized. Сохраняются tokens с UTF16 offsets, координаты, язык, confidence, engine/source/run fingerprints. Изменённый источник отклоняет commit.
- C13: Агент получает bounded structured search/read и regional image без скрытого распознавания; только выданные инструментом source IDs превращаются в сохраняемые кликабельные ссылки. Старые чаты декодируются.
- C14: При анализе не скачиваются отсутствующие assets, не вызывается missing-asset repair и не меняется primary contentRevision. Индекс различает свежий raw text и частичное/ещё не выполненное OCR.
- C15: Сборка и точечные core/store/tool/geometry/UI проверки пройдены либо точно указан инфраструктурный предел. Реальное качество JA/RU/EN и физический iCloud отдельно от API/синтетики.

## Implementation Steps

1. Этап4: новые Knowledge DTO/tokenizer/SQLite index, bound SQL, FTS+literal CJK/substring fallback, транзакционная замена и generation-bound pagination. Отдельный компонент без runtime wiring, целевой бюджет450–600строк; при превышении split SQL/storage и matching/token контрактов.
2. Этап5a: VaultStore raw locally available snapshot без repair/hydration, fingerprint и локальный namespace canonical root+vault id; lifecycle invalidate/reconcile после commit. Цель450–600строк; отдельный новый extension/reader, если объём превышен.
3. Этап5b: DocumentSession/WorkspaceModel/WorkspaceView подключают structured user search, pending/partial/error coverage, rebuild и exact-open; query/store operation guards. Цель400–600строк, законченный текстовый поиск.
4. Этап6: bounded captured snapshot renderer + cancellable Vision accurate rev3 recognizer; явный выбор языка; crop-to-world; сохранение только актуального результата; результат и повторный запуск в UI. Цель450–600строк recognizer/renderer и отдельный завершённый UI chunk до600 при необходимости.
5. Этап10: notes.search/read fragment/page_image region, source registry и persistent optional assistant citations; AgentPanel exact-open. Цель350–550строк; schema/runtime и chat-citation integration можно проверять отдельными chunks при превышении600.
6. Интегрированное source review и целевые проверки затронутых контрактов. Не повторять известный независимый сбой Simulator rotation/полный suite. Не создавать commit/PR как побочный эффект.

## Verifications

- C10/C11: core/store тесты временной БД/vault: JA без пробелов, Cyrillic/case/punctuation/quotes, имена/empty, Markdown/text objects, SQL/FTS syntax, pagination/change-cursor, rebuild, root namespace и duplicate document UUID. Save/external/move/delete и stale recognition rejected.
- C12/C14: missing/raw manifest/asset и unsafe bounds, source replacement во время OCR, bounded allocation, normalized-Y to world mapping с отрицательными координатами, cancelled/empty/error/unsupported outcomes. Native synthetic JA/RU/EN image проверяет API-путь, но не handwriting quality.
- C13: shared DTO query parity, tool bounds/cursor/read, issued reference parsing, Codable old/new messages, invalid references rejected; реальный UI tap найденного canvas hit использует существующий SourceContext navigation. Provider/network вызовы тестом не нужны.
- C15: targeted StudyKit build/test и приложение/iPad только по новым наборам. Disk1.8GiB: проверить до сборки, использовать task caches; не удалять чужие данные. Корпус реальной рукописи, CER/query recall и физический iPad/iCloud остаются явными пределами, пока нет данных.

## Context

**Current state:** VaultStore.search возвращает пути по именам/Markdown/objects, OCR/SQL отсутствуют. SourceContext и точные переходы готовы. CanvasRenderer читает live-session assets без availability guard; обычный load чинит отсутствующие references. Assistant context nil, tool-citations не сохраняются. SDK26.6/deploy26; новый PKStrokeRecognizer требует27.

**Expected state:** Один локальный индекс для пользовательского поиска и tools; наблюдения привязаны к неизменному сохранённому источнику; точные зарегистрированные ссылки переживают reload.

**Design:** KnowledgeIndex — синхронный non-Sendable SQLite connection, единственный владелец VaultStore actor; DTO Sendable/Codable. Source identity — normalized relative path, page UUID и region, не только document UUID. KnowledgeSearchRequest(query,limit default40 max100,cursor); KnowledgeSearchPage(hits,coverage,nextCursor,truncated). Cursor version+query digest+index generation+last stable key, limit+1. Hit включает provenance/sourceFingerprint и id; observation включает tokens UTF16 offsets/language/confidence/world rect/run fingerprint. Raw freshness и OCR coverage разделены.

VaultStore предоставляет searchKnowledge/readKnowledgeFragment/knowledgeSnapshot/commitRecognition/rebuildKnowledge; старый search compatibility сохраняется. Snapshot читает raw manifest и только нужные immutable assets после проверки каждого ubiquitous status до и внутри coordinated accessor, без обычного load/repair. Bytes/resource/rect ограничения проверяются до raster allocation. Source fingerprint исключает chat; commit повторно проверяет path/page/source с generation; lifecycle инвалидирует stale OCR. Недоступные source rows не отдают старый content, filename остаётся. Namespace hash(canonical root+vault id) в Application Support. Ошибка БД видна, старый поиск не пропадает из-за недоступного кэша.

Vision обрабатывает captured upright image локально вне main actor; runtime supported languages и requested language list проверяются. JA request[ja-JP,en-US], RU[ru-RU,en-US], EN[en-US]; native macOS synthetic probe подтвердил принятие и соответствующие строки, реальная рукопись/iOS пока нет. World x=crop.x+b.minX*width; y=crop.y+(1-b.maxY)*height. Отмена не коммитит. Запуск с editor finishInk+save, текущий unsaved не маркируется распознанным.

Tools выдают runtime source ref в bounded JSON. Assistant ссылается [[source_id]], registry разрешает только реально выданные IDs; optional citations сохраняются на ChatMessage, decode старых сообщений поддержан. AgentPanel показывает source кнопки через workspace.open(SourceContext); модель не может создать trusted target произвольной строкой пути. Search/read/image не запускают OCR.

## Break when

- Vision не поддерживает выбранный язык/runtime или реальная рукопись не проходит качество → явный результат, без автоматического enable/provider; смена engine требует re-research.
- Snapshot не может гарантировать raw references/per-asset availability либо source identity не отклоняет гонки → OCR commit блокируется до исправления.
- Allocation не ограничено → предложить меньшую область, не полный render infinity.
- Single chunk>600 → пересмотреть границу; >1000 → split до дальнейших изменений. Новый OS/provider/primary-format scope не добавлять.
- ENOSPC/SDK/runner блокируют проверку → сохранить код/доказательства и точно указать unverified; не удалять чужие caches.
<!-- local-search-contract:end -->

Review continuation-v1 VALID (/root/ocr_search_plan_review); implementation gate passed. Optional preservation: notes.read revision bookkeeping remains intact for existing write proposals. Root owns this document; research workers read-only and returned. Audit count for this continuation1, accepted; no second audit needed. All original scope decisions and authorizations retained; per-language selection refines observed API limits, no engine or product scope change.

### Assignment knowledge-index

**Goal:** Изолированный SQLite/FTS index+multilingual DTO/token contract по continuation-v1, без runtime подключения.
**Context:** Approved parent4, root gate passed, full continuation-v1 VALID. Индекс actor-owned sync connection, local rebuildable; raw/OCR coverage отдельно, cursor generation/query guard.
**Constraints:** Только перечисленные пути, никаких сборок/тестовых запусков/Simulator/commits/delegation. Создать необходимые тесты, не менять существующие unrelated tests. Согласовать API return, не писать VaultStore или snapshot. Be concrete and concise; cite actual checks and gaps.
**Done when:** DTO/index ready, bound SQL transactional replacement, JA/RU/EN matching, limit/cursor, targeted tests authored, diffcheck and ownership release returned4fields.

### Assignment knowledge-snapshot

**Goal:** Raw saved source+asset snapshot без missing repair/download, bounded и fingerprintvalidated.
**Context:** Approved parent5/6 dependency, gate passed, no runtime index wired. Existing load repairs missing refs and readAsset unguarded; add additive safe API.
**Constraints:** Только перечисленные пути. Без index/Package/App изменений, сборок/тестовых запусков/Simulator/commits/delegation. Root coordinates interfaces. Be concrete and concise; preserve all existing dirty changes.
**Done when:** knowledgeSnapshot/validate API reads original references, checks per-file availability under coordination, bounds byte/region/assets, fingerprint excludeschat, tests authored, scoped diffcheck, release returned4fields.

### Assignment handwriting-engine

**Goal:** Snapshot renderer+local Vision recognizer с JA/RU/EN choice, bounds/world mapping, outcomes/cancellation и тестами.
**Context:** Approved6/continuation-v1 VALID; snapshot API от отдельного исполнителя стабилен. UI/storecommit позже. Рендер capturedbytes, OCR вне main actor, без provider.
**Constraints:** Только перечисленные новые файлы, не менять CanvasRenderer/PencilSurface/App/Core/Package. Без запусков сборок/тестов/Simulator/commits/delegation. Be concrete and concise, тесты написаны не значит пройдены.
**Done when:** Бounded input+output API стабилен, actual SDK Vision/cancellation/runtime language validation, geometry/error/empty fixtures authored, diffcheck и release4fields.

Интерфейсы согласованы: snapshot.sourceFingerprint=rawcontent.contentRevision для совместимости raw/OCR; snapshot.fingerprint отдельно включает selection+capturedassets/status и защищает bitmap input. Index replaceRecognition scoped pageID/region, сохраняет другие страницы и disjoint regions, defaultpartial. Root принял уточнения как routine integration, originalscope не меняется.

Core candidates accepted for integration: index455lines+manifest, snapshot380lines; root inspected critical snapshot/DTO paths with CodeGraph, sourceFP and cropFP consistent. Frozen core harness `/var/folders/cp/2pym2k7n6z52p2j9vvxn3_cr0000gn/T/yohaku-handwriting-core-uq26cx6i` copied after both source releases; verifier reads this snapshot, concurrent lifecycle writer touches original only.

### Assignment knowledge-store

**Goal:** Actor-owned localindex lifecycle/search/rebuild/fragment and atomic validated OCR commit.
**Context:** Accepted index/snapshot APIs, approved5/6 continuation-v1; root copied immutablecorecandidate for independent verification, no compilerreads originalCore.
**Constraints:** Only listed original paths; preserve snapshot/prior dirtychanges. No App/agent/engine/indexDTO edits, build/test runs/sim/provider/commits/delegation. Follow sourcecommit not chatdraft; surface DB failures/fallback; Be concrete and concise.
**Done when:** Saved/external/reopen/move/delete staleguards and local namespace, shared APIs, meaningful lifecycle tests authored, source/diff/size and ownership released4fields.

### Assignment knowledge-core-check

**Goal:** Compile/run only two new frozen core suites, report actual errors.
**Context:** Frozen harnessuq26cx6i includes exact released Core and new KnowledgeIndexTests/KnowledgeSnapshotTests; rootcopiedSources, minimalPackage sameplatform/linksqlite.
**Constraints:** Only harness/cache/artifacts, nooriginaledits/delegation/fullsuite/Simulator/commits. XcodeBuildMCPCLI; useescalationforcacheifneeded, boundedpolls. Be concrete concise, distinguishcompilefailure/testfail/pass.
**Done when:** Actual targetedcheckresultanddiagnosticlog, no sourcefixes, allownedprocessesreleased4fields.

Engine candidate accepted for integration:360lines in2newfiles, API recognize(snapshot,language),render(snapshot),worldRect; no runtimepassyet. Store API stabilized searchKnowledge/readKnowledgeFragment/reconcileKnowledge/rebuildKnowledge/commitRecognition; error property knowledgeError, init optionalindexDirectory. Receiptmetadata localcachemayguardchangedassetbytes withoutmanifestchange, failclosed missing/corrupt, separatefromportableauthordata.

### Assignment knowledge-ui

**Goal:** User structuredsearch/exact-open, explicitboundedlocalOCR withlanguagechoiceandvisibleoutcomes.
**Context:** Approved5/6 continuation-v1; Core/engineAPIstabilized, storewriteractive onlyCore. Priorpanel/navigation/composerpreserved.
**Constraints:** OnlylistedApp/newtestsfiles; noAgentPanel/agent/Core/engine/localization/projectwrites. No build/testexecution/sim/provider/commits/delegation. ReadSwiftUIpatterns, Beconcreteconcise, staleUIguardsafterawait.
**Done when:** Searchbrowsing/fallback/coverage/cursor/rebuild andOCRfinishInk+save/snapshot/commit/outcomecancel integrated, targetedtestsauthored, stringkeyssentroot,diff/sizeandownershipreleased4fields.

Primitive-v1 compile/runtime:12tests2suitesPASS0.178sec in frozenharness, log `/tmp/yohaku-handwriting-validation/core-primitive-v1/test-runtime.log`; sandbox modulecache failure firstattempt then taskcache/escalated success. Originalsourceuntouched. UIwriteruses workspace.store internal, noAgentPanelownership. Store adds knowledgeDocument(path)->LoadedDocument with exactsavedrevision to preserveexisting notes.read/writeproposalbookkeeping withoutrepair.

### Assignment knowledge-agent

**Goal:** Boundedsharedindexagentsearch/read/image andtrustedpersistentexactcitations.
**Context:** Approved10/continuation-v1 VALID; Core/engineAPIready, storeAPIstabilized; noactualmodel/providerneededforverification. Existingnotes.readrevisionmustpreserve.
**Constraints:** Onlylistedpaths; noWorkspaceModel/View/Editor/Coreindex/store/enginewrites. Preservecomposer/panel/navigation andexistingtools/proposals. No build/testexecution/sim/network/provider/commits/delegation. Beconcreteconcise, sourceIDsmustbeissuedbyruntime.
**Done when:** ToolJSONlimits/cursors/coverage/read/snapshotimage, old/newchatCodable, linkresolverrejectsunknown/stale, focusedtestsauthored,diff/size/stringssentroot andownershipreleased4fields.

### Assignment snapshot-identity

**Goal:** HashencodedsourceIdentity into snapshot.fingerprint fornonfragmentcitationvalidation.
**Context:** Storecandidate470lines8testsauthoredreleased; AgentneedsidentityguardwithoutpublicinodeAPI. NochangeglobalSourceFP or publiccontracts.
**Constraints:** OnlyKnowledgeSnapshot.swift onehashinput, nootherfiles/checkruns/delegation. Beconcreteconcise.
**Done when:** fingerprintbindsidentity, scopedwhitespacecheck, return4fieldsreleasebeforecorefreeze.

Storecandidatev1 ready470lines8tests, knowledgeDocument exactdiskrevision retained. Snapshotidentityhashone-linefollowup accepted. UIcandidatev1 ready~500lines3workflow+2UItests, sourceownershipreleased. Frozenharness refreshed ONLY released VaultStore/KnowledgeVault/KnowledgeSnapshot plusnewStoretests; Documents stays primitive-v1 to avoid activecitationwriter. Coreverification nextcovers20tests/3new suites.

Integrationreviewv1 FINDINGS2P2: indexmustpreservelink-cardcontentsearch; DBfallbackmustusesafesnapshotnotordinaryload. OptionalFTSliteralmatchingunchangedretained, noexpansionwordbagsearch. Rootacceptsfixes, storeauthorownsits3pathsagain; otherwritersreleased. Corestore20tests3suitesPASS0.360sec; module/link worksfrozen. English47newkeysaddedplutillintOK. Newagentcandidate~440lines8testsauthoredreadybutreviewpending.

### Assignment store-regression-fix

**Goal:** Fixonlyreview2P2: objectcontentsearchparityandsafelegacyfallback.
**Context:** Reviewv1 accepted; priorstorev1release, roottransferssame3paths. Appfallbackcallstore.searchstayssame.
**Constraints:** Indexallobject.contentasrawwithsamepage/rect(legacyparity); VaultStore.searchusesknowledgeSnapshotrawreader insteadloadforcontent, retainsfilename/empty. NoApp/indexDTOchanges/buildtest/sim/commits/delegation. Beconcreteconcise.
**Done when:** Focusedregressiontestsauthored,diffcheck/APIunchanged, source/diffandrelease4fields.

Storev2 fixesacceptedrootinspection: allobjectcontent raw-indexed, legacysearch usesknowledgeSnapshot rawreader. +2tests, frozenharnessrefreshed3releasedCorefiles+storetests;22targetedtestsnext. Agentreviewv1 oneP2: safeimageobjects mustprecedeink; registry/persistence/toolboundsotherwiseclear. RootassignssmalllayerfixwithadditiverenderincludeTextObjects defaultfalse toagentauthor; no changeOCRcompositebydefault.

### Assignment agent-render-fix

**Goal:** Safeagentimage preserves objectarrayorderbelowink.
**Context:** Agentv1reviewoneP2; engine/agentwritersreleased. Allowedadditiveengine render includeTextObjects=false default, wrapper true.
**Constraints:** Onlylisted3paths; noCore/Docs/App/Packagewrites, nootheroptionalfeatures/build/test/sim/provider/commits/delegation. Beconcreteconcise.
**Done when:** Samecrop/capturedbytes/pixellimits; cards/imagesinobjectorder,inklast; focusedoverlapfixtureauthored,diff/sizeandrelease4fields.

Core-store-v2 actual22tests3suitesPASS0.728sec `/tmp/yohaku-handwriting-validation/core-store-v2/test.log`. OriginalDocumentsnewoptionalcitationscompiledinfrozenCore. NoApp/engine/UIpassyet. RootassignssmallUIproofhelperbeforeappcheck: pageordinal/title insteadUUID andsavePNGatsearch/recognitionstates, noassertionweakening.

### Assignment ui-proof

**Goal:** Human-readablepage label anddurableUIvisualevidence.
**Context:** UIv1reviewclear, actualruntimepending; originalwriterreleased.
**Constraints:** Onlytwofiles, noassertionchanges/build/test/sim/commits/delegation. Usepageindex/title notrawUUID, saveapppngtotemp+printpath. Beconcreteconcise.
**Done when:** TwoPNGcapturepoints+friendlypagelabel, scopedcheckandrelease4fields.

Agentlayerfixacceptedforruntimeafterrootinspection: renderincludeTextObjects=false defaultOCR, trueforagent; originalobjectsordertheninklast; addedpixeloverlaptest, allwritersreleasedexceptsmallUIproof. AppverifiermaygenerateprojectthenwaitrootGO beforecompileruntilUIproofrelease.

### Assignment knowledge-app-check

**Goal:** Actualapp/engine/tool/workflow/localizationbuildtestsandiPadUI2proofwithPNG.
**Context:** NewCore22PASS/3suites, source+agentreviewblockersfixed, UIproofonlywriter. Projectxcodegenbeforebuild; warmtaskderivedcache.
**Constraints:** Projectgenerationandtaskcache/iPad/logsonly; noappsource/testfixes/fullsuite/rotation/otherdevices/provider/commits/delegation. WaitrootGOtocompile, boundedpolls/escalationcacheifneeded. Beconcreteconcise counts/errors/artifacts.
**Done when:** Targetedsuitesand2newUIresults,savedPNG/logs, actualqualitylimitsseparate, alltaskprocessesreleased4fields.

App-v1 generatedprojectsuccess, compilerstoppedbeforetests: AgentSession.swift261:62 actorinitreadsMainActorDocumentSession.store. NoUI/runtime/newPNG, verifierconfirmedCLI/xcodebuild/runnerstopped. Allsourcewritersotherwiseaccepted. Rootassignsminimalruntimeinitisolationfix, thenSAMEselected6unit+2UI checks.

### Assignment agent-compile-fix

**Goal:** CompileNotesToolRuntimeinitwithoutcrossingMainActorunsafely.
**Context:** Exactapp-v1error261:62, all3constructorsMainActor; runtimeactorremainserialized.
**Constraints:** OnlyAgentSession.swift, minimalinitisolation/storecapturefix noAPIexpansionifnotneeded. No builds/tests/sim/commits/delegation. Beconcreteconcise.
**Done when:** Sourcefix,diffcheck,release4fieldsforapp-v2rerun.

App-v2GO: minimal @MainActorNotesToolRuntime.init fixaccepted(1line), authorreleased. Generatedprojectunchangedfilenamewiring; rootdiffcheckclean. VerifierrunsSAME6unitsuites+HandwritingSearchUITests2. Allsourcesfrozen, rootdocs/localizationonly.

App-v2 builtproductmodulesbuttestcompilerstoppedon ambiguous .infinity in HandwritingRecognitionTests.swift71. Verifierconfirmedalltaskprocessesstopped, otherworktreecompileruntouched. RoottrivialmechanicalqualificationCGFloat.infinity applied(1token), diffcheckPASS; noassertionchange. App-v3SAMEchecksGO, allsourcesfrozen.

App-v3actual:27total26pass1fail0skip;25unit6suites24pass1fail, UI2/2PASS. VisionJA/RU/EN3parametercasesPASS2.579sec; geometry/cancel/invalidassets/blank PASS. Sourcequery+highlightUI12.142sec, OCRlanguage/empty/dismiss25.172sec. Rootviewed2PNGs andconfirmedlayout. Logs/PNGsunder `/tmp/yohaku-handwriting-validation/app-v3/`. OnlyfailurecursoropaqueJSONdifferentkeyorder, decodedvaluesequal(cursor-failure.json). Alltaskprocessesstopped.

Rootsmallconfigfixencoder.sortedKeys (deterministiccursor/payload, noassertionchange), friendlysourcepageordinalinsearchrow insteadUUIDprefix. diffcheckPASS. App-v4GOONLY9agenttests+1searchUIaffected; noall27repeat, other17unchangedpassedscenariosretain evidence.


## Итог локального распознавания и поиска — 2026-10-17

В рабочей копии реализованы этапы 4/5/6/10: локальный SQLite/FTS индекс с многоязычной токенизацией, единый поиск пользователя и агента, явное Vision-распознавание страницы либо выбранной области и сохраняемые точные ссылки из ответов. Пользователь выбирает японский, русский или английский язык. Японский режим также допускает английский, русский — английский; единый JA-first запрос пропускал кириллицу в диагностике, поэтому смешанное автоматическое определение не обещается.

Распознавание запускается кнопкой редактора после завершения штриха и сохранения. Оно использует только ограниченный снимок доступных локальных файлов; отсутствующие файлы, неподдерживаемый язык, ошибка и пустой текст различаются. Статус частичного OCR не объявляет всю тетрадь обработанной. Изменение/удаление источника отклоняет старый результат, локальные receipts проверяют также заменённые assets. Индекс согласуется с сохранением, внешним обновлением, переименованием и удалением; резервный поиск тоже использует безопасный raw reader. Предыдущая iPad-панель, нижний компоузер и точная навигация сохранены.

Агент получает тот же индекс, ограниченные фрагменты и снимки выбранной области. Только выданные инструментами ссылки сохраняются в ответе; открытие проверяет актуальность источника и использует существующий переход с подсветкой. Старые чаты декодируются, пользовательские предложения изменений сохраняют прежний revision-контракт. Локальные OCR/search не обращаются к выбранному AI-провайдеру.

Проверки и доказательства:

- StudyCore: 22 теста в трёх целевых наборах прошли. Изолированная копия точного кандидата, `/tmp/yohaku-handwriting-validation/core-store-v2/test.log`.
- iPad Pro 11 M5, Simulator 26.3.1: суммарно подтверждены 25 unit-тестов в шести наборах и оба UI-сценария. Первый runtime-кандидат дал 24/25 unit и 2/2 UI; единственный сбой выявил разный порядок JSON-полей в эквивалентных курсорах. После канонической сериализации без изменения теста повторно прошли все 9 затронутых агентских тестов и поиск UI (10/10). Остальные неизменённые 16 unit и OCR UI используют уже полученное доказательство, полного повторения не было.
- Реальные Vision-запросы на печатных JA/RU/EN образцах прошли для всех трёх языков; также прошли координаты, ограничение растра, пустой ответ, повреждённые/отсутствующие assets и отмена. Это проверка интеграции API, а не качества рукописи.
- UI подтвердил поиск японского текста и переход к подсвеченной исходной области, явный выбор языка, пустой OCR-результат, закрытие и повторное открытие. Root визуально проверил оба состояния. Финальный поиск: `/tmp/yohaku-handwriting-validation/app-v4/knowledge-search-results.png`; окно OCR: `/tmp/yohaku-handwriting-validation/app-v3/handwriting-empty-result.png`.
- Логи приложения и native stdout: `/tmp/yohaku-handwriting-validation/app-v3/` и `app-v4/`. Проект перегенерирован, английская локализация и diff проверены. Независимое ревью закрыло три P2: поиск link-card, безопасный fallback и порядок объектов/штрихов в снимке агента. Исправлены две ошибки компиляции — actor init и тип тестового infinity.

Ограничения: реальный корпус рукописи JA/RU/EN, CER/recall и физический iPad/Apple Pencil/iCloud ещё не проверены. Автоматический backfill/полное покрытие infinity (7/8) до этой проверки не включены; локальный запуск выбранной области работает. Граф, содержание и переносимые авторские исправления остаются отдельными этапами. В этом продолжении не проверялись поворот, Split View, iPhone и Catalyst. Вызовов реального провайдера, коммитов, публикации PR и релиза не было.

Все исполнители вернули файлы, все процессы компиляции/тестов/приложения и сборщики этой задачи остановлены. Соседний daily-study план и чужие worktrees/процессы не менялись. Следующий шаг для автоматического распознавания — получить представительный корпус реальной рукописи и зафиксировать порог качества; для отдельного UX содержания доступен этап3.


## Интеграция в main — 2026-10-18

Пользователь прямо поручил влить `codex/ipad-agent-regions-20261017` в main, разрешить конфликты, проверить работу и запушить. Кандидат объединяет main `d57ec34` и исходный коммит ветки `4db063e`, сохраняя обе истории. Работа выполняется в существующей изолированной worktree, интеграционная ветка `codex/integrate-ipad-agent-regions`.

Решения конфликтов:

- DocumentEditor сохраняет отдельные меню подготовки учебных материалов и локального OCR, оба состояния sheet и блокировку canvas при открытом диалоге.
- PencilSurface объединяет одноразовую навигацию к источнику с `selectionIncludesImage`, не меняя выбор между запросом агенту и подготовкой учебных материалов.
- WorkspaceModel сохраняет lesson/material stores и синхронную отмену старого контекста до первого await; сбрасывает поиск/навигацию и повторно проверяет контекст после согласования индекса.
- WorkspaceView переводит старую ссылку `showFlashcards` на актуальное `studyDestination` для iPad-навигации. Проект перегенерирован XcodeGen; актуальный полный personal-daily-study план из main сохранён.

Проверки текущего кандидата: StudyCore47/47; полный YohakuTests177/177 функций,217caseevents,0ошибок/пропусков,invocationFinished. Логи `/tmp/yohaku-ipad-merge-core.log`, `/tmp/yohaku-ipad-merge-unit-v3.log` и соответствующий JSONL. Первая сборка выявила старую копию StudyCore.swiftmodule, затенявшую новый framework; только этот артефакт task-owned derived data перенесён в резервную папку /tmp. Повторная сборка выявила и закрыла оставшуюся старую ссылку навигации.

UI: первый iPad11 прогон6/8, ошибки поворота и прокрутки полной страницы сохранены в `/tmp/yohaku-ipad-merge-ui-ipad.log`. На другом iPad13 поворот с сохранением черновика/клавиатуры и переход к Today прошли (`ui-ipad-v2`). Известный независимый сбой поворота iPad11 не устраняется изменением production-кода. На iPhone прошли все8 выбранных сценариев (`ui-phone`,invocationFinished), включая полную страницу, агента, напоминания, ручную практику/квиз и восстановление занятия. Изменения теста страницы ограничены прокруткой внутри реальной Form и выводом нужного контрола перед действием; проверки расшифровки, происхождения цитаты и принятия карточки сохранены. Финальный iPad-page прогон прошёл после адресации верхней активной Form: `/tmp/yohaku-ipad-merge-ui-page-v5.log` и `-results.jsonl`,1/1,invocationFinished. Расшифровка, повторное подтверждение после правки, цитата, сохранение и метка происхождения в редакторе карточки проверены. Предыдущие UI-ошибки и диагностика сохранены; assertions не удалялись.

Снимки доказательств сохранены в `/tmp/yohaku-ipad-merge-proof/`. Физический Pencil/iCloud, реальный AI-провайдер, автоматический OCR-backfill и дальнейшие этапы графа/содержания не входят в эту интеграцию.


### Итог интеграционной проверки

- StudyCore47/47 и полный YohakuTests177/177 функций (217caseevents),0ошибок/пропусков. После этого production-код не менялся; последующие исправления ограничены UI-harness прокрутки.
- Подтверждены16 различных UI-сценариев:9 на iPad и8 на iPhone, с одним общим сценарием полной страницы. Сводка собирается из шести успешных случаев `ui-ipad`, двух успешных `ui-ipad-v2`, финального `ui-page-v5` и восьми успешных `ui-phone`. Все эти invocation завершены. Оба исходных iPad-сбоя имеют финальное положительное покрытие: поворот на iPad13 и полная страница с активной Form. У iPad11 сохранено отдельное свидетельство инфраструктурного ограничения ориентации.
- Финальная сборка Mac Catalyst прошла: `/tmp/yohaku-ipad-merge-catalyst.log`, `CODE_SIGNING_ALLOWED=NO`, generic Mac Catalyst destination. Запуск Catalyst не выполнялся. Остались предупреждения deprecated UITextItemInteraction и избыточного await, ошибок сборки нет.
- XcodeGen, исходный интегрированный diff и проверки отсутствия conflict markers/whitespace пройдены. Текущий main повторно fetched и совпадает с базой `d57ec34`; исходная ветка остаётся на `4db063e`. Слияние и обычный push прямо авторизованы пользователем; дополнительных продуктовых этапов в merge не добавлено.

Готовый merge сохраняет весь актуальный daily-study сценарий, исходную историю ветки агента и результаты локального OCR/search. Физический Pencil/iCloud, узкий Split View и вызовы реального провайдера этой проверкой не подтверждаются. Дальнейшие этапы исходного плана остаются отдельной работой.
