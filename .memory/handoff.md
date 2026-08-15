# Сводка сессии

**Дата:** 2026-08-15 12:48 · **Режим:** детальный · **Сценарий:** 2 (завершён пункт плана)
**Память:** пропущено: отдельной долговременной user-memory дельты нет; устойчивые deployment-факты записаны в код, operations docs, DevLog и постоянную Hermes KB
**Синк скиллов:** прогнан на уровне workspace: канон `c89bc11`, проектный manifest обновлён, копия `hermes-expert` освежена целиком
**Объём скиллов:** проектный сторож: 2 скилла, чисто 2, L1 нет
**Документация кода:** прогнан: `README.md` и `docs/operations.md` соответствуют фактическим backup, rollback и CI/CD contracts
**База знаний:** прогнан: стабильные Hermes/tooling/provider facts разнесены по владельцам в Obsidian KB
**Инструкции:** прогнан на уровне workspace: Stage 1-7 закрыты, brain направляет сначала в repository-local handoff
**Воркспейс:** прогнан: карта видит оба вложенных репозитория, дерево полное, дрейфа нет

## 1. Резюме

В этом репозитории закрыты defect follow-up Stage 6 и весь Stage 7. Backup исправлен и live-проверен: воспроизводимый `home/.cache` исключён узко и симметрично из архива и source count, критичное state сохранено, SQLite integrity и off-host checksum подтверждены. Rollback/forward rehearsal прошёл после исключения точного transient gateway-lock path из durable inventory.

CI/CD добавлен и доказан production run. CI имеет только `contents: read`; deploy запускается вручную из `main`, проходит credential-free preflight, ждёт approval protected `production` environment и вызывает на VPS только exact root-owned gateway через locked forced-command identity. Gateway перепроверяет SHA против текущего `origin/main`, делает backup, атомарно активирует release, запускает deploy и независимый supervisor-aware verify.

Продуктовые изменения уже закоммичены и опубликованы. До записи этого файла repository был clean и совпадал с `origin/main` на `688e011`. Текущая единственная грязь — новый `.memory/handoff.md`. Следующий продуктовый этап не integration, а Stage 8 public release readiness.

## 2. Этапы

**Этап 1: backup fix.** `scripts/backup.sh` перестал пытаться разыменовать host-broken uv-cache links, не ослабляя backup остального state. Live archive: 879 regular files, cache отсутствует, critical state и три SQLite DB проверены.

**Этап 2: rollback hardening.** Transient `.local/state/hermes/gateway-locks` исключён из durable inventory. Live repeat откатил image, сохранил 614 durable-файлов и успешно вернул текущий pinned image.

**Этап 3: CI/CD implementation.** Добавлены `.github/workflows/ci.yml`, `.github/workflows/deploy.yml`, `scripts/ci-deploy-gateway.sh`, `scripts/ci-deploy-force.sh`, `scripts/bootstrap-ci-deploy.sh` и `tests/cicd/run.sh`.

**Этап 4: controlled rollout.** CI run `31872275241` и deploy run `31872399497` завершились успешно; активирован release `20260815T074040Z-d3ee4f2`. Evidence: `validate,backup,deploy,verify`, verdict `success`, backup 880 regular files, restart count 0, no ports, stable supervisor PID, healthy neighbours.

**Этап 5: documentation.** Public README и operations guide описывают только доказанный contract: manual protected deployment, least privilege, failure semantics, backup and rollback boundaries.

## 3. Технические изменения

- `scripts/backup.sh`: exact cache exclusion без потери разыменования остального state.
- `scripts/rollback.sh` и lifecycle tests: durable inventory не включает transient gateway locks.
- `.github/workflows/ci.yml`: PR/push checks, immutable dependencies, без production environment.
- `.github/workflows/deploy.yml`: manual `main`, exact SHA, preflight до environment approval.
- `scripts/ci-deploy-{force,gateway}.sh`: bounded protocol, current-main verification, serialized atomic rollout and recovery.
- `scripts/bootstrap-ci-deploy.sh`: locked account, exact sudoers, root-owned control plane, idempotent `0700` data/backup roots.
- `tests/cicd/run.sh`: protocol, workflow policy, archive, lock, retention, rollback and bootstrap fixtures.
- `README.md`, `docs/operations.md`: observed delivery and operational contract.

Git: `main`, `origin/main` существует; 0 unpushed commits. После записи handoff грязен один путь: `.memory/handoff.md`.

## 4. Проблемы и решения

**Broken cache links ломали корректный fail-closed backup.** Не отключали `tar -h` глобально; исключили только reproducible cache из обеих сторон proof.

**Transient lock выглядел как потеря durable data при rollback.** Уточнили семантическую границу inventory вместо игнорирования произвольных исчезновений.

**ShellCheck с runner был mutable.** Переведён на digest-pinned image.

**Bootstrap не исправлял permissive existing roots.** Теперь повторный запуск проверяет path type/boundary и каждый раз закрепляет owner/mode.

## 5. Состояние и следующие шаги

**Готово:** implementation Stage 1-7 опубликована; production lifecycle, backup, rollback и environment-gated CI/CD доказаны.

**Осталось:** Stage 8 public release readiness.

1. Просканировать working tree и полную history на secrets, включая поиск по фактическим private values без вывода значений.
2. Проверить public surface на topology, local paths, usernames и соседние services.
3. Проверить clean-clone reproducibility и documented prerequisites.
4. Исправить только подтверждённые disclosures/portability defects, прогнать repository checks.
5. Получить отдельное разрешение пользователя на release/publication action.

Точка остановки: продуктовый repository чист на `688e011`; новый handoff — единственная незакоммиченная запись. Stage 8 ещё не заведён как implementation plan.

## 6. Стартовое задание следующей сессии

Продолжаем `hermes-deploy` со Stage 8 public release readiness. Контекст: production deployment уже безопасно автоматизирован и доказан; задача теперь не менять VPS, а проверить публичную поставку и всю Git history перед широким использованием.

Ключевые файлы: `README.md` и `docs/` — public claims; `.github/workflows/` — trust boundary; `scripts/bootstrap-ci-deploy.sh` и `scripts/ci-deploy-gateway.sh` — host control plane; `tests/cicd/run.sh` — acceptance proof. Проектный roadmap находится в соседнем private repo `apps/docs-hermes-deploy/plans/HLD.md`.

Задачи на старт: создать audit checklist Stage 8; выполнить history/tree secret scan; проверить topology anonymization; выдать evidence-backed release verdict.

## 7. Архитектурные решения

- Production deploy остаётся manual and environment-gated.
- Deploy identity никогда не становится shell/Docker identity.
- Gateway принимает только exact current-main SHA и сам строит release из Git tree.
- Code/image rollback не восстанавливает state; restore остаётся отдельной destructive operation.
- Runtime state и backups не входят в delivery.
- Новые tools/MCP не входят в этот repository до отдельного одобренного stage.

## 8. Среднесрочный план

После Stage 8 repository может получить release verdict. Интеграции Vault/Tavily/FAL/Groq/GitHub остаются отдельными future stages и в первую очередь меняют runtime config/state, а не public deployment bundle. Риски Stage 8: секрет в истории, приватная topology в docs/tests, скрытая зависимость от локальной среды и преждевременная публикация без user approval.
