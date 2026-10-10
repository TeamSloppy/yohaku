# StudyCanvas size maintenance

The file context menu offers **Уменьшить размер…**. Analysis lists the original
size, retained size and obsolete drawing count. **Подготовить копии** creates a
full original and a verified compact package in local Application Support under
`Yohaku/CanvasBackups/<operation-id>/`. Preparation leaves the vault untouched.
The original backup can be exported from the sheet.

**Уменьшить размер** is a separate action. For an iCloud vault it requires the
user to confirm that other devices have synchronized and closed Yohaku. The
current document must have finished uploading, and conflicts must be resolved.
The sheet rechecks the source after saving any open session. If it changed since
analysis, run analysis again. No automatic cleanup runs at launch or after save.

## Retention and validation

- Only unreferenced `assets/*.drawing` snapshots are removed from the compact
  copy. Images, unknown files, recovery pages and separate recovered documents
  remain intact.
- Current references, Undo/Redo and the active editing group are retained. Raw
  JSON is scanned for additional asset references from schema-1 clients. The
  manifest is copied byte-for-byte; page/document identities and revisions stay
  unchanged.
- Missing assets, unreadable current PencilKit drawings, unsupported schemas,
  cloud conflicts, symlinks and incomplete downloads block the operation.
- File names, sizes and streaming SHA-256 digests form the analysis fingerprint.
  A changed manifest or asset invalidates preparation/application. Backup and
  retained bytes are verified before replacement; the applied package is checked
  afterwards. Backups must be local and outside the vault.
- Replacement uses `NSFileCoordinator` and `FileManager.replaceItemAt`, with a
  temporary item replacement directory on the destination volume. Both full
  original and compact copies remain in local backup storage afterwards.

## Read-only and preparation CLI

The macOS SwiftPM executable accepts only `analyze` and `prepare`. It has no
command that replaces or deletes original files, and does not call the vault's
normal list/prepare routines (which can enforce deletion markers).

```sh
swift run --package-path Packages/StudyKit --scratch-path /tmp/yohaku-canvas-maintenance-cli yohaku-canvas-maintenance analyze "/path/to/vault"
swift run --package-path Packages/StudyKit --scratch-path /tmp/yohaku-canvas-maintenance-cli yohaku-canvas-maintenance prepare "/path/to/vault" "/local/backup/directory"
```

Preparation writes `prepared-copies.json` and one `report.json` per operation,
alongside `Original/` and `Compact/` packages. Bulk analysis and skipped-file errors
are written to `analysis.json` and `errors.json`; one damaged document does not
stop preparation of the others. The process exits with failure if any document
could not be analyzed/prepared. Backups are intentionally retained;
there is no scheduled expiry or automatic purge.

Unit checks cover byte preservation, Undo/Redo, missing/corrupt drawings, stale
source plans, tampered backups, unknown JSON references, recovery pages and
symlink rejection. A Simulator UI test covers preview → prepare → explicit apply.
Real multi-device iCloud propagation requires physical-device validation.
