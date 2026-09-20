export const meta = {
  name: 'review-code-pipeline',
  description: 'Конвейер скилла review-code: параллельные углы поиска, верификация по локациям, sweep',
  whenToUse:
    'Запускается скиллом dev-toolkit:review-code на уровнях medium…max; args собирает скилл (фаза 0), напрямую не вызывать',
  phases: [
    { title: 'Поиск', detail: 'углы поиска параллельно, перезапуск отказавшего угла один раз' },
    { title: 'Верификация', detail: 'один верификатор на локацию; на max — три линзы' },
    { title: 'Sweep', detail: 'только xhigh/max: поиск пропусков и верификация его кандидатов' },
    { title: 'Сводка', detail: 'подсчёт голосов и агентов, возврат результата скиллу' },
  ],
}

// Механика оркестрации скилла review-code (dev-toolkit ≥ 2.0.0). Тексты правил — ракурсы углов,
// skip-list, инварианты, протокол верификации — в скрипте НЕ дублируются: их собирает скилл из
// своего SKILL.md и правил проекта и передаёт через args. Здесь только то, что обязано быть
// детерминированным: состав агентов, модель по роли и проходу, перезапуски, группировка по
// локации, подсчёт голосов, счётчики для сводки. Date.now()/Math.random() не использовать —
// ломают resume; время меряет сессия.

// Механика уровней — зеркало «Таблицы уровней» SKILL.md (углы, потолок кандидатов, протокол, sweep).
const LEVELS = {
  medium: { angles: 3, cap: 6, protocol: 'skeptic', sweep: false },
  high: { angles: 5, cap: 6, protocol: 'recall', sweep: false },
  xhigh: { angles: 9, cap: 8, protocol: 'recall', sweep: true },
  max: { angles: 9, cap: 8, protocol: 'lenses', sweep: true },
}
const LENSES = ['корректность', 'безопасность', 'воспроизводимость']
const SECURITY_ANGLE = 5
const SWEEP_CAP = 8
// Порог числа локаций, после которого локации одного файла объединяются под одного верификатора
// (фаза 2 SKILL.md), и потолок кандидатов на такого верификатора.
const MERGE_THRESHOLD = 8
const MERGE_MAX = 4

const CANDIDATES_SCHEMA = {
  type: 'object',
  properties: {
    candidates: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string', description: 'repo-relative путь, точно как в списке изменённых файлов' },
          line: { type: 'integer' },
          summary: { type: 'string', description: 'одно предложение' },
          failure_scenario: { type: 'string', description: 'наблюдаемое последствие либо конкретная цена' },
          category: { type: 'string', description: 'kebab-case слаг категории' },
          security: { type: 'boolean', description: 'true, если это security-находка, флаг инварианта 1 или утечка секрета' },
          skip_note: { type: 'string', description: 'только на max: «под skip-list: <цитата правила>», иначе пусто' },
        },
        required: ['file', 'line', 'summary', 'failure_scenario', 'category', 'security'],
      },
    },
    suppressed: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          rule: { type: 'string', description: 'дословная цитата правила skip-list' },
        },
        required: ['file', 'line', 'rule'],
      },
    },
  },
  required: ['candidates', 'suppressed'],
}

const VERDICTS_SCHEMA = {
  type: 'object',
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string', description: 'id кандидата из задания' },
          verdict: { type: 'string', enum: ['CONFIRMED', 'PLAUSIBLE', 'REFUTED', 'SUPPRESSED'] },
          evidence: { type: 'string', description: 'доказательство-цитата из кода; для SUPPRESSED — цитата правила skip-list' },
          security: { type: 'boolean', description: 'true, если считаешь кандидата security-находкой' },
        },
        required: ['id', 'verdict', 'evidence', 'security'],
      },
    },
  },
  required: ['verdicts'],
}

// ---------- проверка args ----------

const input = args || {}
const level = input.level
const cfg = LEVELS[level]
if (!cfg) {
  throw new Error(`args.level: ожидается medium|high|xhigh|max, получено «${level}»`)
}
const pass = input.pass === undefined ? 1 : input.pass
if (!Number.isInteger(pass) || pass < 1) {
  throw new Error(`args.pass: ожидается целое ≥ 1, получено «${input.pass}»`)
}
for (const key of ['context', 'finderRules', 'verifyProtocol']) {
  if (typeof input[key] !== 'string' || !input[key].trim()) {
    throw new Error(`args.${key}: обязательная непустая строка`)
  }
}
if (cfg.sweep && (typeof input.sweepBrief !== 'string' || !input.sweepBrief.trim())) {
  throw new Error('args.sweepBrief: обязателен на xhigh/max')
}
const files = Array.isArray(input.files) ? input.files : []
if (!files.length) {
  throw new Error('args.files: обязательный непустой список изменённых файлов (repo-relative)')
}
const angles = Array.isArray(input.angles) ? input.angles : []
const angleNumbers = [...new Set(angles.map((a) => a.n))].sort((a, b) => a - b)
const expectedNumbers = Array.from({ length: cfg.angles }, (_, i) => i + 1)
if (angleNumbers.join(',') !== expectedNumbers.join(',')) {
  // «N углов» не должно маскировать непокрытый ракурс — состав углов сверяется с уровнем жёстко.
  throw new Error(
    `args.angles: для уровня ${level} нужны углы ${expectedNumbers.join(',')}, получены ${angleNumbers.join(',') || 'нет'}`,
  )
}
for (const a of angles) {
  if (typeof a.title !== 'string' || typeof a.brief !== 'string' || !a.brief.trim()) {
    throw new Error(`args.angles: у угла ${a.n} нет title/brief`)
  }
}
const halves = angles.filter((a) => a.n === 2).length
if (angles.length !== cfg.angles + (halves === 2 ? 1 : 0) || (halves === 2 && level !== 'max')) {
  throw new Error('args.angles: дубли углов недопустимы; две записи допустимы только у угла 2 на max (расщепление)')
}

// ---------- учёт агентов ----------

const stats = {
  total: 0,
  byRole: { angles: 0, restarts: 0, verifiers: 0, sweep: 0 },
  byModel: { opus: {}, sonnet: {}, default: {} },
}
const notes = []
const degraded = []

/**
 * Модель агента по правилу «Модель субагентов»: только роль и номер прохода.
 *
 * @param {boolean} cheapRole true — finder-угол (кроме угла 5) или sweep; false — угол 5, верификатор, линза.
 * @returns {string|undefined} значение opts.model либо undefined («model не передавать»).
 */
function modelFor(cheapRole) {
  if (!cheapRole) return undefined
  return pass === 1 ? 'opus' : 'sonnet'
}

/**
 * Запускает агента и учитывает его в обеих разбивках сводки (по ролям и по корзинам моделей).
 *
 * @param {string} prompt промпт агента.
 * @param {{label: string, phase: string, schema: object, model: (string|undefined)}} opts параметры agent().
 * @param {string} role роль для разбивки по ролям: angles | restarts | verifiers | sweep.
 * @param {string} roleName человекочитаемая роль для корзины модели.
 * @returns {Promise<object|null>} структурированный результат либо null при отказе агента.
 */
async function run(prompt, opts, role, roleName) {
  stats.total += 1
  stats.byRole[role] += 1
  const bucket = stats.byModel[opts.model || 'default']
  bucket[roleName] = (bucket[roleName] || 0) + 1
  const agentOpts = { label: opts.label, phase: opts.phase, schema: opts.schema, agentType: 'general-purpose' }
  if (opts.model) agentOpts.model = opts.model
  try {
    return (await agent(prompt, agentOpts)) || null
  } catch (e) {
    log(`агент «${opts.label}» упал: ${e && e.message ? e.message : e}`)
    return null
  }
}

/**
 * Запуск с одним перезапуском при отказе — на той же модели (правило «Отказ угла — не молчать»).
 *
 * @param {string} prompt промпт агента.
 * @param {object} opts параметры, как у run().
 * @param {string} role роль первого запуска.
 * @param {string} roleName роль для корзины модели.
 * @returns {Promise<object|null>} результат либо null, если отказали оба запуска.
 */
async function runWithRestart(prompt, opts, role, roleName) {
  const first = await run(prompt, opts, role, roleName)
  if (first) return first
  log(`«${opts.label}» не дал структурного результата — перезапуск`)
  return run(prompt, { ...opts, label: `${opts.label} · перезапуск` }, 'restarts', `${roleName} (перезапуск)`)
}

// ---------- нормализация и группировка ----------

/**
 * Приводит путь кандидата к repo-relative виду из списка изменённых файлов.
 *
 * @param {string} raw путь, как его вернул агент (может быть абсолютным или с обратными слэшами).
 * @returns {string} путь из args.files, если опознан по суффиксу, иначе очищенный исходный.
 */
function normalizePath(raw) {
  const p = String(raw).replace(/\\/g, '/').replace(/^\.\//, '')
  if (files.includes(p)) return p
  const bySuffix = files.filter((f) => p.endsWith(`/${f}`))
  return bySuffix.length === 1 ? bySuffix[0] : p
}

const locKey = (c) => `${c.file}:${c.line}`

/**
 * Группирует кандидатов по локации; при большом числе локаций объединяет локации одного файла.
 *
 * @param {Array<object>} candidates кандидаты с нормализованными путями и присвоенными id.
 * @returns {Array<{key: string, candidates: Array<object>}>} группы в детерминированном порядке.
 */
function groupByLocation(candidates) {
  const map = new Map()
  for (const c of candidates) {
    const k = locKey(c)
    if (!map.has(k)) map.set(k, { file: c.file, line: c.line, candidates: [] })
    map.get(k).candidates.push(c)
  }
  const locs = [...map.values()].sort((a, b) => (a.file === b.file ? a.line - b.line : a.file < b.file ? -1 : 1))
  if (locs.length <= MERGE_THRESHOLD) {
    return locs.map((l) => ({ key: `${l.file}:${l.line}`, candidates: l.candidates }))
  }
  // Локаций много: один верификатор на файл, но не больше MERGE_MAX кандидатов на верификатора —
  // иначе внимание размывается; порядок по строкам сохраняет соседние локации вместе.
  const groups = []
  for (const l of locs) {
    const last = groups[groups.length - 1]
    if (last && last.file === l.file && last.candidates.length + l.candidates.length <= MERGE_MAX) {
      last.candidates.push(...l.candidates)
      last.key = `${last.file}:${last.firstLine}-${l.line}`
    } else {
      groups.push({ file: l.file, firstLine: l.line, key: `${l.file}:${l.line}`, candidates: [...l.candidates] })
    }
  }
  return groups.map((g) => ({ key: g.key, candidates: g.candidates }))
}

// ---------- промпты ----------

const OUTPUT_RULE =
  'Ответ — только структурированный результат по схеме. Поле `security` ставь true, если кандидат — ' +
  'security-находка, флаг сквозного инварианта 1 или утечка секрета.'

/**
 * Промпт finder-угла.
 *
 * @param {{n: number, title: string, brief: string}} angle ракурс угла из args.angles.
 * @returns {string} детерминированный текст промпта.
 */
function finderPrompt(angle) {
  return [
    `Ты — finder-угол ${angle.n} «${angle.title}» многоуглового code review. Уровень: ${level}, проход: ${pass}.`,
    `## Твой ракурс\n${angle.brief}`,
    `## Правила finder'а\n${input.finderRules}`,
    `Потолок: не больше ${cfg.cap} кандидатов. Ничего не нашлось — верни пустые списки, не выдумывай.`,
    OUTPUT_RULE,
    `## Входные данные\n${input.context}`,
  ].join('\n\n')
}

/**
 * Промпт верификатора (или одной линзы на max) для группы кандидатов одной локации.
 *
 * @param {{key: string, candidates: Array<object>}} group группа кандидатов.
 * @param {string|null} lens название линзы на max, иначе null.
 * @returns {string} детерминированный текст промпта.
 */
function verifierPrompt(group, lens) {
  const list = group.candidates
    .map(
      (c) =>
        `- id: ${c.id}\n  локация: ${c.file}:${c.line}\n  summary: ${c.summary}\n  failure_scenario: ${c.failure_scenario}` +
        (c.skip_note ? `\n  пометка finder'а: ${c.skip_note}` : ''),
    )
    .join('\n')
  return [
    `Ты — независимый верификатор кандидатов code review по локации ${group.key}. Уровень: ${level}, проход: ${pass}.` +
      (lens ? ` Твоя линза: **${lens}** — суди кандидатов именно с этой стороны.` : ''),
    `## Протокол верификации\n${input.verifyProtocol}`,
    'Верни вердикт по КАЖДОМУ кандидату из списка (по его id) с доказательством-цитатой из кода, а не мнением.',
    `## Кандидаты\n${list}`,
    `## Входные данные\n${input.context}`,
  ].join('\n\n')
}

/**
 * Промпт sweep-finder'а.
 *
 * @param {Array<object>} survivors выжившие находки на момент запуска sweep.
 * @returns {string} детерминированный текст промпта.
 */
function sweepPrompt(survivors) {
  const list = survivors.length
    ? survivors.map((s) => `- ${s.file}:${s.line} — ${s.summary}`).join('\n')
    : '(выживших находок нет)'
  return [
    `Ты — sweep-finder многоуглового code review. Уровень: ${level}, проход: ${pass}.`,
    `## Задача\n${input.sweepBrief}`,
    `## Уже найдено и верифицировано (не перепроверять и не пере-доказывать)\n${list}`,
    `## Правила finder'а\n${input.finderRules}`,
    `Потолок: не больше ${SWEEP_CAP} новых кандидатов. Нового нет — верни пустые списки, не добивай до квоты.`,
    OUTPUT_RULE,
    `## Входные данные\n${input.context}`,
  ].join('\n\n')
}

// ---------- верификация ----------

/**
 * Сводит голоса по одному кандидату в исход: выжил / опровергнут / снят по skip-list.
 * Голоса SUPPRESSED и REFUTED не складываются; для security-кандидата SUPPRESSED не засчитывается.
 *
 * @param {object} c кандидат.
 * @param {Array<{lens: (string|null), verdict: string, evidence: string, security: boolean}>} votes голоса.
 * @param {number} voters число отработавших верификаторов (линз) группы.
 * @returns {{outcome: string, verdict: (string|undefined), rule: (string|undefined), security: boolean}} исход.
 */
function tally(c, votes, voters) {
  const security = Boolean(c.security) || votes.some((v) => v.security)
  const count = (name) => votes.filter((v) => v.verdict === name).length
  const majority = cfg.protocol === 'lenses' ? 2 : 1
  if (count('REFUTED') >= majority) return { outcome: 'refuted', security }
  if (!security && count('SUPPRESSED') >= majority) {
    return { outcome: 'suppressed', rule: votes.find((v) => v.verdict === 'SUPPRESSED').evidence, security }
  }
  // PLAUSIBLE — вердикт по умолчанию: и при разногласии линз, и когда голос не получен.
  const confirmed = voters > 0 && count('CONFIRMED') >= 1 && count('REFUTED') === 0
  return { outcome: 'survived', verdict: confirmed ? 'CONFIRMED' : 'PLAUSIBLE', security }
}

/**
 * Верифицирует одну группу кандидатов: один верификатор, на max — три линзы параллельно.
 *
 * @param {{key: string, candidates: Array<object>}} group группа кандидатов одной локации.
 * @param {string} phaseTitle фаза прогресса, к которой отнести агентов.
 * @returns {Promise<Array<object>>} кандидаты группы с полями outcome/verdict/votes.
 */
async function verifyGroup(group, phaseTitle) {
  const lenses = cfg.protocol === 'lenses' ? LENSES : [null]
  const replies = await Promise.all(
    lenses.map((lens) =>
      runWithRestart(
        verifierPrompt(group, lens),
        {
          label: lens ? `линза «${lens}» · ${group.key}` : `верификатор · ${group.key}`,
          phase: phaseTitle,
          schema: VERDICTS_SCHEMA,
          model: modelFor(false),
        },
        'verifiers',
        lens ? 'линзы max' : 'верификаторы',
      ).then((r) => ({ lens, reply: r })),
    ),
  )
  const voters = replies.filter((r) => r.reply).length
  if (voters < lenses.length) {
    const missed = replies.filter((r) => !r.reply).map((r) => r.lens || 'верификатор')
    degraded.push(`верификация локации ${group.key} неполная: не отработал(и) ${missed.join(', ')}`)
  }
  return group.candidates.map((c) => {
    const votes = []
    for (const { lens, reply } of replies) {
      if (!reply) continue
      const v = (reply.verdicts || []).find((x) => x.id === c.id)
      if (v) votes.push({ lens, verdict: v.verdict, evidence: v.evidence, security: Boolean(v.security) })
      else notes.push(`${lens ? `линза «${lens}»` : 'верификатор'} не вернул вердикт по ${c.id} (${locKey(c)}) — учтён как отсутствующий голос`)
    }
    return { ...c, votes, unverified: votes.length === 0, ...tally(c, votes, voters) }
  })
}

/**
 * Прогоняет пул кандидатов через верификацию: группировка по локации, pipeline по группам.
 *
 * @param {Array<object>} candidates кандидаты с id.
 * @param {string} phaseTitle фаза прогресса.
 * @returns {Promise<Array<object>>} плоский список кандидатов с исходами.
 */
async function verifyAll(candidates, phaseTitle) {
  if (!candidates.length) return []
  const groups = groupByLocation(candidates)
  const verified = await pipeline(groups, (g) => verifyGroup(g, phaseTitle))
  verified.forEach((res, i) => {
    if (!res) degraded.push(`верификация локации ${groups[i].key} упала целиком`)
  })
  return verified.flatMap((res, i) =>
    res || groups[i].candidates.map((c) => ({ ...c, votes: [], unverified: true, outcome: 'survived', verdict: 'PLAUSIBLE', security: Boolean(c.security) })),
  )
}

/**
 * Принимает ответ finder'а: потолок, нормализация путей, id, отсев точных дублей.
 *
 * @param {object} reply ответ по CANDIDATES_SCHEMA.
 * @param {string} source метка источника (угол/sweep) — попадает в находку и в id.
 * @param {number} cap потолок кандидатов.
 * @param {Set<string>} seen ключи уже принятых кандидатов (локация + summary).
 * @returns {{candidates: Array<object>, suppressed: Array<object>}} принятые кандидаты и подавленные локации.
 */
function accept(reply, source, cap, seen) {
  const raw = reply.candidates || []
  if (raw.length > cap) notes.push(`${source}: возвращено ${raw.length} кандидатов, сверх потолка ${cap} отброшено ${raw.length - cap}`)
  const out = []
  raw.slice(0, cap).forEach((c, i) => {
    const cand = { ...c, file: normalizePath(c.file), source, id: `${source}#${i + 1}` }
    const k = `${locKey(cand)}|${cand.summary.trim().toLowerCase()}`
    if (seen.has(k)) return
    seen.add(k)
    out.push(cand)
  })
  const suppressed = (reply.suppressed || []).map((s) => ({ ...s, file: normalizePath(s.file), by: source }))
  return { candidates: out, suppressed }
}

// ---------- фаза 1: поиск ----------

phase('Поиск')
const orderedAngles = [...angles].sort((a, b) => a.n - b.n)
const finderReplies = await parallel(
  orderedAngles.map((angle, idx) => () => {
    const half = halves === 2 && angle.n === 2 ? `.${orderedAngles.slice(0, idx).filter((a) => a.n === 2).length + 1}` : ''
    const cheap = angle.n !== SECURITY_ANGLE
    return runWithRestart(
      finderPrompt(angle),
      { label: `угол ${angle.n}${half} · ${angle.title}`, phase: 'Поиск', schema: CANDIDATES_SCHEMA, model: modelFor(cheap) },
      'angles',
      cheap ? 'finder-углы' : 'угол 5 (security)',
    )
  }),
)

const seen = new Set()
const failedAngles = []
let pool = []
let suppressedRaw = []
orderedAngles.forEach((angle, idx) => {
  const reply = finderReplies[idx]
  if (!reply) {
    failedAngles.push({ n: angle.n, title: angle.title, model: modelFor(angle.n !== SECURITY_ANGLE) || null })
    degraded.push(`угол ${angle.n} «${angle.title}» не отработал дважды`)
    return
  }
  const got = accept(reply, `угол${angle.n}${halves === 2 && angle.n === 2 ? `-${idx}` : ''}`, cfg.cap, seen)
  pool = pool.concat(got.candidates)
  suppressedRaw = suppressedRaw.concat(got.suppressed)
})
if (level === 'max' && suppressedRaw.length) {
  notes.push(`на max finder'ы не подавляют сами, но вернули suppressed по ${suppressedRaw.length} локациям — проверить вручную`)
}
log(`поиск: кандидатов ${pool.length}, отказавших углов ${failedAngles.length}`)

// ---------- фаза 2: верификация ----------

phase('Верификация')
let judged = await verifyAll(pool, 'Верификация')

// ---------- фаза 2.5: sweep ----------

let sweep = 'не предусмотрен уровнем'
if (cfg.sweep) {
  phase('Sweep')
  const survivorsNow = judged.filter((c) => c.outcome === 'survived')
  const reply = await runWithRestart(
    sweepPrompt(survivorsNow),
    { label: 'sweep-finder', phase: 'Sweep', schema: CANDIDATES_SCHEMA, model: modelFor(true) },
    'sweep',
    'sweep-finder',
  )
  if (!reply) {
    sweep = 'не отработал'
    degraded.push('sweep не отработал дважды — страховки от пропусков фазы 1 не было')
  } else {
    const got = accept(reply, 'sweep', SWEEP_CAP, seen)
    suppressedRaw = suppressedRaw.concat(got.suppressed)
    sweep = `отработал, новых кандидатов: ${got.candidates.length}`
    judged = judged.concat(await verifyAll(got.candidates, 'Sweep'))
  }
}

// ---------- фаза 3: сводка ----------

phase('Сводка')
const survivors = judged
  .filter((c) => c.outcome === 'survived')
  .map(({ id, outcome, rule, ...rest }) => rest)
const refuted = judged.filter((c) => c.outcome === 'refuted').map((c) => ({ file: c.file, line: c.line, summary: c.summary, source: c.source }))

// Подавленное считается по локациям; локация, которую хоть один finder передал в обычный список, —
// не подавлена (пункт 1 skip-list): её судьбу решила верификация.
const poolLocations = new Set(judged.map(locKey))
const suppressedMap = new Map()
for (const s of suppressedRaw) {
  const k = locKey(s)
  if (poolLocations.has(k)) continue
  if (!suppressedMap.has(k)) suppressedMap.set(k, { file: s.file, line: s.line, rule: s.rule, by: [s.by] })
  else suppressedMap.get(k).by.push(s.by)
}
for (const c of judged.filter((x) => x.outcome === 'suppressed')) {
  const k = locKey(c)
  if (!suppressedMap.has(k)) suppressedMap.set(k, { file: c.file, line: c.line, rule: c.rule, by: ['верификация'] })
}

const bucketText = (b) => Object.entries(b).map(([role, n]) => `${role} — ${n}`)
const bucketTotal = (b) => Object.values(b).reduce((a, n) => a + n, 0)
const unverified = survivors.filter((s) => s.unverified).length
if (unverified) degraded.push(`без единого голоса верификации оставлено кандидатов: ${unverified} (вердикт PLAUSIBLE по умолчанию)`)

log(`итог: выжило ${survivors.length}, опровергнуто ${refuted.length}, подавлено локаций ${suppressedMap.size}, агентов ${stats.total}`)

return {
  level,
  pass,
  mode: degraded.length ? 'деградированный' : 'полный',
  degraded,
  survivors,
  refuted,
  suppressed: [...suppressedMap.values()],
  failedAngles,
  sweep,
  agents: {
    total: stats.total,
    byRole: stats.byRole,
    byModel: {
      opus: { count: bucketTotal(stats.byModel.opus), roles: bucketText(stats.byModel.opus) },
      sonnet: { count: bucketTotal(stats.byModel.sonnet), roles: bucketText(stats.byModel.sonnet) },
      default: { count: bucketTotal(stats.byModel.default), roles: bucketText(stats.byModel.default) },
    },
  },
  notes,
}
