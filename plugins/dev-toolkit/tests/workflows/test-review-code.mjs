// Стенд-заглушка для workflows/review-code.js: моки agent/parallel/pipeline, сценарии отказов.
import { readFileSync } from 'node:fs'
import assert from 'node:assert/strict'

const SRC = readFileSync(new URL("../../workflows/review-code.js", import.meta.url), 'utf8').replace('export const meta', 'const meta')
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

/** Запускает скрипт с подставленным поведением агентов; возвращает результат и журнал вызовов. */
async function runScript(args, behave) {
  const calls = []
  const agent = async (prompt, opts) => {
    calls.push({ prompt, opts })
    return behave(prompt, opts, calls)
  }
  const parallel = (thunks) => Promise.all(thunks.map((t) => t().catch(() => null)))
  const pipeline = async (items, ...stages) =>
    Promise.all(
      items.map(async (it, i) => {
        try {
          let r = it
          for (const s of stages) r = await s(r, it, i)
          return r
        } catch {
          return null
        }
      }),
    )
  const fn = new AsyncFunction('agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow', SRC)
  const result = await fn(agent, parallel, pipeline, () => {}, () => {}, args, { total: null }, null)
  return { result, calls }
}

const mkAngles = (n, split) => {
  const out = []
  for (let i = 1; i <= n; i++) {
    if (i === 2 && split) {
      out.push({ n: 2, title: 'аудит удалённого', brief: 'b' }, { n: 2, title: 'история', brief: 'b' })
    } else out.push({ n: i, title: `угол-${i}`, brief: 'brief' })
  }
  return out
}
const base = (level, pass, split) => ({
  level,
  pass,
  context: 'DIFF',
  finderRules: 'RULES',
  verifyProtocol: 'PROTO',
  sweepBrief: 'SWEEP',
  files: ['src/a.php', 'src/b.php'],
  angles: mkAngles({ medium: 3, high: 5, xhigh: 9, max: 9 }[level], split),
})
const cand = (file, line, summary, security = false) => ({
  file, line, summary, failure_scenario: 'fs', category: 'correctness', security,
})
const idsOf = (prompt) => [...prompt.matchAll(/- id: (\S+)/g)].map((m) => m[1])
const isFinder = (o) => o.label.startsWith('угол')
const checkSums = (a) => {
  assert.equal(a.byRole.angles + a.byRole.restarts + a.byRole.verifiers + a.byRole.sweep, a.total, 'сумма ролей')
  assert.equal(a.byModel.opus.count + a.byModel.sonnet.count + a.byModel.default.count, a.total, 'сумма корзин')
}

// 1. high pass=1: угол 3 падает один раз; одна локация от двух углов → один верификатор.
{
  let angle3Fails = 1
  const { result, calls } = await runScript(base('high', 1), (p, o) => {
    if (isFinder(o)) {
      if (o.label.startsWith('угол 3') && angle3Fails-- > 0) return null
      if (o.label.startsWith('угол 1')) return { candidates: [cand('/abs/repo/src/a.php', 10, 'баг A')], suppressed: [] }
      if (o.label.startsWith('угол 4')) return { candidates: [cand('src\\a.php', 10, 'баг B'), cand('src/a.php', 10, 'Баг A')], suppressed: [{ file: 'src/a.php', line: 10, rule: 'R' }, { file: 'src/b.php', line: 5, rule: 'R' }] }
      return { candidates: [], suppressed: [{ file: 'src/b.php', line: 5, rule: 'R' }] }
    }
    return { verdicts: idsOf(p).map((id, i) => ({ id, verdict: i === 0 ? 'CONFIRMED' : 'REFUTED', evidence: 'e', security: false })) }
  })
  const finders = calls.filter((c) => isFinder(c.opts))
  assert.equal(finders.length, 6)
  for (const f of finders) {
    assert.equal(f.opts.model, f.opts.label.startsWith('угол 5') ? undefined : 'opus', f.opts.label)
    assert.equal(f.opts.agentType, 'general-purpose')
  }
  const verifiers = calls.filter((c) => !isFinder(c.opts))
  assert.equal(verifiers.length, 1, 'одна локация — один верификатор')
  assert.equal(verifiers[0].opts.model, undefined)
  assert.equal(idsOf(verifiers[0].prompt).length, 2, 'точный дубль «Баг A» отсеян')
  assert.equal(result.mode, 'полный')
  assert.deepEqual(result.agents.byRole, { angles: 5, restarts: 1, verifiers: 1, sweep: 0 })
  assert.equal(result.survivors.length, 1)
  assert.equal(result.survivors[0].file, 'src/a.php')
  assert.equal(result.survivors[0].verdict, 'CONFIRMED')
  assert.equal(result.refuted.length, 1)
  assert.equal(result.suppressed.length, 1, 'src/a.php:10 передан в обычный список → не подавлен; b.php:5 — одна локация')
  assert.deepEqual(result.suppressed[0].by.length, 4)
  checkSums(result.agents)
  console.log('ok 1 high pass=1')
}

// 2. high pass=2: sonnet; угол 4 отказывает дважды → деградированный.
{
  const { result, calls } = await runScript(base('high', 2), (p, o) => {
    if (isFinder(o)) return o.label.startsWith('угол 4') ? null : { candidates: [], suppressed: [] }
    return { verdicts: [] }
  })
  for (const f of calls) assert.equal(f.opts.model, f.opts.label.startsWith('угол 5') ? undefined : 'sonnet', f.opts.label)
  assert.equal(result.mode, 'деградированный')
  assert.deepEqual(result.failedAngles, [{ n: 4, title: 'угол-4', model: 'sonnet' }])
  assert.equal(result.agents.total, 6)
  assert.equal(result.agents.byModel.sonnet.count, 5)
  checkSums(result.agents)
  console.log('ok 2 high pass=2, второй отказ угла')
}

// 3. max: расщепление угла 2, линзы, skip-list, security-исключение, отказ sweep.
{
  const { result, calls } = await runScript(base('max', 1, true), (p, o) => {
    if (o.label === 'sweep-finder' || o.label.startsWith('sweep-finder')) return null
    if (isFinder(o)) {
      if (o.label.startsWith('угол 1')) {
        return { candidates: [cand('src/a.php', 1, 'A'), cand('src/a.php', 50, 'B'), cand('src/b.php', 7, 'C', true), cand('src/b.php', 90, 'D')], suppressed: [] }
      }
      return { candidates: [], suppressed: [] }
    }
    const lens = o.label
    return {
      verdicts: idsOf(p).map((id) => {
        if (p.includes('summary: A')) return { id, verdict: lens.includes('корректность') ? 'PLAUSIBLE' : 'REFUTED', evidence: 'e', security: false }
        if (p.includes('summary: B') || p.includes('summary: C')) return { id, verdict: lens.includes('корректность') ? 'CONFIRMED' : 'SUPPRESSED', evidence: 'правило', security: false }
        return { id, verdict: lens.includes('безопасность') ? 'REFUTED' : 'CONFIRMED', evidence: 'e', security: false }
      }),
    }
  })
  assert.equal(calls.filter((c) => isFinder(c.opts)).length, 10, '9 углов + половина угла 2')
  assert.equal(calls.filter((c) => c.opts.label.startsWith('линза')).length, 12)
  assert.equal(result.refuted.length, 1)
  assert.equal(result.refuted[0].summary, 'A')
  assert.deepEqual(result.suppressed.map((s) => `${s.file}:${s.line}`), ['src/a.php:50'])
  const byS = Object.fromEntries(result.survivors.map((s) => [s.summary, s.verdict]))
  assert.deepEqual(byS, { C: 'CONFIRMED', D: 'PLAUSIBLE' }, 'C — security, SUPPRESSED не засчитан; D — один REFUTED не убивает')
  assert.equal(result.sweep, 'не отработал')
  assert.equal(result.mode, 'деградированный')
  assert.ok(result.degraded.some((d) => d.includes('sweep')))
  assert.deepEqual(result.agents.byRole, { angles: 10, restarts: 1, verifiers: 12, sweep: 1 })
  checkSums(result.agents)
  console.log('ok 3 max: линзы, skip-list, отказ sweep')
}

// 4. xhigh: >8 локаций → соседние объединяются; sweep даёт кандидата, он верифицируется; отказ верификатора.
{
  const { result, calls } = await runScript(base('xhigh', 1), (p, o) => {
    if (o.label === 'sweep-finder') return { candidates: [cand('src/b.php', 300, 'S')], suppressed: [] }
    if (isFinder(o)) {
      if (o.label.startsWith('угол 1')) return { candidates: [1, 3, 5, 100, 200, 300, 400, 500].map((l) => cand('src/a.php', l, `a${l}`)), suppressed: [] }
      if (o.label.startsWith('угол 6')) return { candidates: [cand('src/b.php', 1, 'b1'), cand('src/b.php', 40, 'b40')], suppressed: [] }
      return { candidates: [], suppressed: [] }
    }
    if (o.label.includes('src/b.php:1-40')) return null
    return { verdicts: idsOf(p).map((id) => ({ id, verdict: 'PLAUSIBLE', evidence: 'e', security: false })) }
  })
  const v = calls.filter((c) => c.opts.label.startsWith('верификатор'))
  assert.ok(v.some((c) => c.opts.label.includes('src/a.php:1-100')), 'локации файла объединены по 4 кандидата')
  assert.ok(v.some((c) => c.opts.label.includes('src/a.php:200-500')))
  assert.equal(result.survivors.length, 11)
  assert.equal(result.survivors.filter((s) => s.unverified).length, 2, 'группа b.php:1-40 осталась без голосов')
  assert.equal(result.mode, 'деградированный')
  assert.ok(result.sweep.startsWith('отработал'))
  checkSums(result.agents)
  console.log('ok 4 xhigh: объединение локаций, sweep, отказ верификатора')
}

// 5. Некорректные args.
for (const [name, mut] of [
  ['уровень low', (a) => { a.level = 'low' }],
  ['pass=0', (a) => { a.pass = 0 }],
  ['нет угла 5', (a) => { a.angles = a.angles.filter((x) => x.n !== 5) }],
  ['лишний угол', (a) => { a.angles.push({ n: 6, title: 't', brief: 'b' }) }],
  ['дубль угла 3', (a) => { a.angles.push({ n: 3, title: 't', brief: 'b' }) }],
  ['нет context', (a) => { a.context = '' }],
  ['нет files', (a) => { a.files = [] }],
]) {
  const a = base('high', 1)
  mut(a)
  await assert.rejects(runScript(a, () => null), undefined, name)
}
{
  const a = base('xhigh', 1, true)
  await assert.rejects(runScript(a, () => null), undefined, 'расщепление вне max')
}
console.log('ok 5 проверка args')
