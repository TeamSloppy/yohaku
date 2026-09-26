# Происхождение компонентов

- Kanji alive example pronunciation audio and language data: https://github.com/kanjialive/kanji-data-media, Creative Commons Attribution 4.0 International. Kanji alive project site: https://kanjialive.com/.

- AnyLanguageModel: https://github.com/mattt/AnyLanguageModel, revision `701d7e61db7b59db9092f2db62b1567144835b3b`, Apache-2.0. SwiftPM сохраняет исходные лицензии зависимостей.
- `NotesToolRuntime` использует подход из Sloppy `Sources/PluginSDK/SloppyToolExecutionDelegate.swift`: перехват native tool calls, возврат `Transcript.Segment`, остановка циклов. Реализация адаптирована для iPad и не импортирует Sloppy, его Protocols, сервер или CLI.
- Выделение прямоугольной области и карточка вопроса основаны на сценарии Sloppy ClientNative `CanvasWorkspaceEditorView.swift`. Координаты, композитный рендер и хранение реализованы заново для PencilKit.
- AdaCanvasProbe использует локальный AdaEngine только в отдельном проекте прототипа. Основное приложение от AdaEngine не зависит.

Исходные репозитории AdaEngine и Sloppy не изменяются.

Локальный `SmolLanguageModel` реализует provider API AnyLanguageModel; преобразование `Transcript` следует его публичным типам. `SmolVisionProcessor` использует MLXVLM preprocessing и chat-template API, а управление native-задачей следует контракту `MLXLMCommon.generateTask` (mlx-swift-lm 2.31.3, MIT). Эти адаптеры живут в StudyIntelligence; исходники зависимостей и скачанные модели не патчатся.

## Sloppy inference integration

The Sloppy inference v1 client and typed tool-execution loop in `StudyIntelligence/NetworkLanguageModel.swift` are adapted from the local Sloppy project. Codex device authorization follows its existing OpenAI OAuth integration. Sloppy is licensed under AGPL-3.0-only; see the Sloppy repository for its license.
