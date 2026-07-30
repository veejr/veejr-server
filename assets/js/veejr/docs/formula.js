// Spreadsheet formula evaluation: tokenizer, parser, evaluator, and the
// dependency-ordered recalculation pass.
//
// Deliberately an interpreter rather than anything built on `eval` or
// `new Function`. The production Content-Security-Policy pins `script-src` to
// 'self' with no 'unsafe-eval', so a formula compiled into JavaScript would
// not run in the browser at all — and would have handed a spreadsheet cell the
// ability to execute code, which is not something a notes app should offer.
//
// No DOM access, so this is straightforward to test; see test/js/formula.test.mjs.

export const ERRORS = {
  div0: "#DIV/0!",
  value: "#VALUE!",
  ref: "#REF!",
  name: "#NAME?",
  circular: "#CIRCULAR",
  na: "#N/A",
  parse: "#ERROR!",
}

export function isError(value) {
  return !!value && typeof value === "object" && typeof value.err === "string"
}

function err(code) {
  return {err: code}
}

// ---------------------------------------------------------------------------
// Cell references
// ---------------------------------------------------------------------------

const REF_PATTERN = /^\$?([A-Z]+)\$?([1-9][0-9]*)$/

export function columnToIndex(letters) {
  let index = 0
  for (const character of letters) index = index * 26 + (character.charCodeAt(0) - 64)
  return index - 1
}

export function indexToColumn(index) {
  let letters = ""
  let remaining = index + 1
  while (remaining > 0) {
    const remainder = (remaining - 1) % 26
    letters = String.fromCharCode(65 + remainder) + letters
    remaining = Math.floor((remaining - 1) / 26)
  }
  return letters
}

export function parseRef(text) {
  const match = REF_PATTERN.exec(String(text).toUpperCase())
  if (!match) return null
  return {col: columnToIndex(match[1]), row: Number(match[2]) - 1}
}

export function refName(col, row) {
  return `${indexToColumn(col)}${row + 1}`
}

// Normalizes "$b$2" to "B2" so a cell is keyed one way no matter how it was
// written, which is what lets the dependency graph compare references.
export function normalizeRef(text) {
  const ref = parseRef(text)
  return ref ? refName(ref.col, ref.row) : null
}

export function expandRange(from, to) {
  const start = parseRef(from)
  const end = parseRef(to)
  if (!start || !end) return []

  const refs = []
  const [top, bottom] = [Math.min(start.row, end.row), Math.max(start.row, end.row)]
  const [left, right] = [Math.min(start.col, end.col), Math.max(start.col, end.col)]

  // Guard against A1:ZZ100000 turning one keystroke into a million lookups.
  if ((bottom - top + 1) * (right - left + 1) > MAX_RANGE_CELLS) return null

  for (let row = top; row <= bottom; row++) {
    for (let col = left; col <= right; col++) refs.push(refName(col, row))
  }
  return refs
}

const MAX_RANGE_CELLS = 20000

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

const OPERATORS = ["<=", ">=", "<>", "+", "-", "*", "/", "^", "&", "=", "<", ">"]

export function tokenize(source) {
  const tokens = []
  const text = String(source)
  let index = 0

  while (index < text.length) {
    const character = text[index]

    if (character === " " || character === "\t" || character === "\n") {
      index++
      continue
    }

    if (character === '"') {
      let value = ""
      index++
      while (index < text.length) {
        // Excel-style escaping: "" inside a string is one quote.
        if (text[index] === '"' && text[index + 1] === '"') {
          value += '"'
          index += 2
          continue
        }
        if (text[index] === '"') break
        value += text[index]
        index++
      }
      if (text[index] !== '"') throw new SyntaxError("unterminated string")
      index++
      tokens.push({type: "string", value})
      continue
    }

    if (/[0-9]/.test(character) || (character === "." && /[0-9]/.test(text[index + 1] || ""))) {
      let raw = ""
      while (index < text.length && /[0-9.]/.test(text[index])) raw += text[index++]
      // Exponent form: 1e-3.
      if (/[eE]/.test(text[index] || "") && /[0-9+\-]/.test(text[index + 1] || "")) {
        raw += text[index++]
        if (/[+\-]/.test(text[index])) raw += text[index++]
        while (index < text.length && /[0-9]/.test(text[index])) raw += text[index++]
      }
      const value = Number(raw)
      if (Number.isNaN(value)) throw new SyntaxError(`bad number: ${raw}`)
      tokens.push({type: "number", value})
      continue
    }

    if (/[A-Za-z_$]/.test(character)) {
      let raw = ""
      while (index < text.length && /[A-Za-z0-9_$.]/.test(text[index])) raw += text[index++]
      const upper = raw.toUpperCase()

      if (text[index] === "(") {
        tokens.push({type: "function", value: upper})
        continue
      }
      if (upper === "TRUE" || upper === "FALSE") {
        tokens.push({type: "boolean", value: upper === "TRUE"})
        continue
      }
      if (REF_PATTERN.test(upper)) {
        tokens.push({type: "ref", value: upper})
        continue
      }
      // A bare word that is not a function call or a reference — #NAME? at
      // evaluation time rather than a syntax error, matching spreadsheet habit.
      tokens.push({type: "name", value: upper})
      continue
    }

    const operator = OPERATORS.find((candidate) => text.startsWith(candidate, index))
    if (operator) {
      tokens.push({type: "operator", value: operator})
      index += operator.length
      continue
    }

    if (character === "(" || character === ")" || character === "," || character === ":") {
      tokens.push({type: character, value: character})
      index++
      continue
    }

    if (character === ";") {
      // Locales that separate arguments with a semicolon.
      tokens.push({type: ",", value: ","})
      index++
      continue
    }

    throw new SyntaxError(`unexpected character: ${character}`)
  }

  return tokens
}

// ---------------------------------------------------------------------------
// Parser — precedence climbing
// ---------------------------------------------------------------------------

const PRECEDENCE = {
  "=": 1, "<>": 1, "<": 1, ">": 1, "<=": 1, ">=": 1,
  "&": 2,
  "+": 3, "-": 3,
  "*": 4, "/": 4,
  "^": 5,
}

export function parse(tokens) {
  let position = 0

  const peek = () => tokens[position]
  const next = () => tokens[position++]

  function parseExpression(minPrecedence = 0) {
    let left = parseUnary()

    while (peek()?.type === "operator" && PRECEDENCE[peek().value] > minPrecedence) {
      const operator = next().value
      // ^ is right-associative; everything else binds left.
      const nextMin = operator === "^" ? PRECEDENCE[operator] - 1 : PRECEDENCE[operator]
      const right = parseExpression(nextMin)
      left = {type: "binary", operator, left, right}
    }

    return left
  }

  function parseUnary() {
    const token = peek()
    if (token?.type === "operator" && (token.value === "-" || token.value === "+")) {
      next()
      return {type: "unary", operator: token.value, operand: parseUnary()}
    }
    return parsePrimary()
  }

  function parsePrimary() {
    const token = next()
    if (!token) throw new SyntaxError("unexpected end of formula")

    switch (token.type) {
      case "number":
      case "string":
      case "boolean":
        return {type: "literal", value: token.value}

      case "name":
        return {type: "name", value: token.value}

      case "ref": {
        if (peek()?.type === ":") {
          next()
          const end = next()
          if (!end || end.type !== "ref") throw new SyntaxError("bad range")
          return {type: "range", from: token.value, to: end.value}
        }
        return {type: "ref", value: token.value}
      }

      case "function": {
        if (next()?.type !== "(") throw new SyntaxError("expected (")
        const args = []
        if (peek()?.type === ")") {
          next()
        } else {
          for (;;) {
            args.push(parseExpression())
            const separator = next()
            if (separator?.type === ")") break
            if (separator?.type !== ",") throw new SyntaxError("expected , or )")
          }
        }
        return {type: "call", name: token.value, args}
      }

      case "(": {
        const inner = parseExpression()
        if (next()?.type !== ")") throw new SyntaxError("expected )")
        return inner
      }

      default:
        throw new SyntaxError(`unexpected token: ${token.value}`)
    }
  }

  const ast = parseExpression()
  if (position < tokens.length) throw new SyntaxError("trailing input")
  return ast
}

export function parseFormula(source) {
  const body = String(source).replace(/^\s*=/, "")
  return parse(tokenize(body))
}

// Every cell this formula reads, for the dependency graph. Ranges expand so a
// SUM over a column re-runs when any cell in it changes.
export function referencedCells(ast) {
  const refs = new Set()

  const walk = (node) => {
    if (!node || typeof node !== "object") return
    switch (node.type) {
      case "ref":
        refs.add(normalizeRef(node.value))
        break
      case "range":
        for (const ref of expandRange(node.from, node.to) || []) refs.add(ref)
        break
      case "binary":
        walk(node.left)
        walk(node.right)
        break
      case "unary":
        walk(node.operand)
        break
      case "call":
        node.args.forEach(walk)
        break
    }
  }

  walk(ast)
  return [...refs]
}

// ---------------------------------------------------------------------------
// Coercion
// ---------------------------------------------------------------------------

export function toNumber(value) {
  if (value === null || value === undefined || value === "") return 0
  if (typeof value === "number") return Number.isFinite(value) ? value : err(ERRORS.value)
  if (typeof value === "boolean") return value ? 1 : 0
  if (isError(value)) return value
  const parsed = Number(String(value).trim())
  return Number.isNaN(parsed) ? err(ERRORS.value) : parsed
}

export function toText(value) {
  if (value === null || value === undefined) return ""
  if (isError(value)) return value.err
  if (typeof value === "boolean") return value ? "TRUE" : "FALSE"
  return String(value)
}

export function toBoolean(value) {
  if (isError(value)) return value
  if (typeof value === "boolean") return value
  if (value === null || value === undefined || value === "") return false
  const asNumber = toNumber(value)
  return isError(asNumber) ? !!value : asNumber !== 0
}

// ---------------------------------------------------------------------------
// Functions
// ---------------------------------------------------------------------------

// Flattens arguments, dropping blanks — how SUM and friends treat empty cells.
function numbers(args) {
  const out = []
  for (const value of args.flat()) {
    if (value === null || value === undefined || value === "") continue
    if (isError(value)) return value
    if (typeof value === "boolean") continue
    const asNumber = toNumber(value)
    if (isError(asNumber)) return asNumber
    out.push(asNumber)
  }
  return out
}

function numeric(fn) {
  return (args) => {
    const values = numbers(args)
    if (isError(values)) return values
    return fn(values)
  }
}

function single(fn) {
  return (args) => {
    const value = toNumber(args.flat()[0])
    if (isError(value)) return value
    const result = fn(value)
    return Number.isFinite(result) ? result : err(ERRORS.value)
  }
}

const sum = (values) => values.reduce((total, value) => total + value, 0)

export const FUNCTIONS = {
  SUM: numeric(sum),
  PRODUCT: numeric((values) => values.reduce((total, value) => total * value, 1)),
  AVERAGE: numeric((values) => (values.length ? sum(values) / values.length : err(ERRORS.div0))),
  MIN: numeric((values) => (values.length ? Math.min(...values) : 0)),
  MAX: numeric((values) => (values.length ? Math.max(...values) : 0)),
  MEDIAN: numeric((values) => {
    if (!values.length) return err(ERRORS.na)
    const sorted = [...values].sort((a, b) => a - b)
    const middle = Math.floor(sorted.length / 2)
    return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
  }),
  COUNT: (args) => args.flat().filter((value) => !isError(value) && !isError(toNumber(value)) && value !== "" && value !== null && value !== undefined).length,
  COUNTA: (args) => args.flat().filter((value) => value !== "" && value !== null && value !== undefined).length,
  ABS: single(Math.abs),
  SQRT: single((value) => (value < 0 ? NaN : Math.sqrt(value))),
  INT: single(Math.floor),
  SIGN: single(Math.sign),
  ROUND: (args) => {
    const [value, digits = 0] = args.flat()
    const number = toNumber(value)
    const places = toNumber(digits)
    if (isError(number)) return number
    if (isError(places)) return places
    const factor = 10 ** Math.trunc(places)
    return Math.round(number * factor) / factor
  },
  POWER: (args) => {
    const [base, exponent] = args.flat()
    const a = toNumber(base)
    const b = toNumber(exponent)
    if (isError(a)) return a
    if (isError(b)) return b
    const result = a ** b
    return Number.isFinite(result) ? result : err(ERRORS.value)
  },
  MOD: (args) => {
    const [value, divisor] = args.flat()
    const a = toNumber(value)
    const b = toNumber(divisor)
    if (isError(a)) return a
    if (isError(b)) return b
    return b === 0 ? err(ERRORS.div0) : a - b * Math.floor(a / b)
  },
  IF: (args) => {
    const condition = toBoolean(args[0]?.flat ? args[0].flat()[0] : args[0])
    if (isError(condition)) return condition
    const branch = condition ? args[1] : args[2]
    const value = Array.isArray(branch) ? branch.flat()[0] : branch
    return value === undefined ? condition : value
  },
  AND: (args) => {
    for (const value of args.flat()) {
      const asBoolean = toBoolean(value)
      if (isError(asBoolean)) return asBoolean
      if (!asBoolean) return false
    }
    return true
  },
  OR: (args) => {
    for (const value of args.flat()) {
      const asBoolean = toBoolean(value)
      if (isError(asBoolean)) return asBoolean
      if (asBoolean) return true
    }
    return false
  },
  NOT: (args) => {
    const value = toBoolean(args.flat()[0])
    return isError(value) ? value : !value
  },
  CONCAT: (args) => args.flat().map(toText).join(""),
  CONCATENATE: (args) => args.flat().map(toText).join(""),
  LEN: (args) => toText(args.flat()[0]).length,
  UPPER: (args) => toText(args.flat()[0]).toUpperCase(),
  LOWER: (args) => toText(args.flat()[0]).toLowerCase(),
  TRIM: (args) => toText(args.flat()[0]).trim().replace(/\s+/g, " "),
  LEFT: (args) => {
    const [value, count = 1] = args.flat()
    const length = toNumber(count)
    return isError(length) ? length : toText(value).slice(0, Math.max(0, Math.trunc(length)))
  },
  RIGHT: (args) => {
    const [value, count = 1] = args.flat()
    const length = toNumber(count)
    if (isError(length)) return length
    const size = Math.max(0, Math.trunc(length))
    return size === 0 ? "" : toText(value).slice(-size)
  },
  MID: (args) => {
    const [value, start, count] = args.flat()
    const from = toNumber(start)
    const length = toNumber(count)
    if (isError(from)) return from
    if (isError(length)) return length
    const begin = Math.max(0, Math.trunc(from) - 1)
    return toText(value).slice(begin, begin + Math.max(0, Math.trunc(length)))
  },
  ROUNDUP: (args) => {
    const [value, digits = 0] = args.flat()
    const number = toNumber(value)
    if (isError(number)) return number
    const factor = 10 ** Math.trunc(toNumber(digits) || 0)
    return Math.ceil(number * factor) / factor
  },
  ROUNDDOWN: (args) => {
    const [value, digits = 0] = args.flat()
    const number = toNumber(value)
    if (isError(number)) return number
    const factor = 10 ** Math.trunc(toNumber(digits) || 0)
    return Math.floor(number * factor) / factor
  },
  COUNTIF: (args) => {
    const values = Array.isArray(args[0]) ? args[0].flat() : [args[0]]
    const criterion = Array.isArray(args[1]) ? args[1].flat()[0] : args[1]
    return values.filter((value) => matchesCriterion(value, criterion)).length
  },
  SUMIF: (args) => {
    const values = Array.isArray(args[0]) ? args[0].flat() : [args[0]]
    const criterion = Array.isArray(args[1]) ? args[1].flat()[0] : args[1]
    const targets = Array.isArray(args[2]) ? args[2].flat() : values
    const matched = values
      .map((value, index) => (matchesCriterion(value, criterion) ? targets[index] : null))
      .filter((value) => value !== null && value !== undefined && value !== "")
    const totals = numbers([matched])
    return isError(totals) ? totals : sum(totals)
  },
  TODAY: () => new Date().toISOString().slice(0, 10),
  NOW: () => new Date().toISOString().slice(0, 19).replace("T", " "),
}

// Supports the "> 10" / "<>done" comparison forms as well as a plain value.
function matchesCriterion(value, criterion) {
  const text = toText(criterion).trim()
  const comparison = /^(<=|>=|<>|<|>|=)(.*)$/.exec(text)

  if (!comparison) {
    const asNumber = Number(text)
    if (!Number.isNaN(asNumber) && text !== "") return toNumber(value) === asNumber
    return toText(value).toLowerCase() === text.toLowerCase()
  }

  const [, operator, rawTarget] = comparison
  const target = rawTarget.trim()
  const targetNumber = Number(target)
  const comparable = Number.isNaN(targetNumber) || target === ""
  const left = comparable ? toText(value).toLowerCase() : toNumber(value)
  const right = comparable ? target.toLowerCase() : targetNumber
  if (isError(left)) return false

  switch (operator) {
    case "=": return left === right
    case "<>": return left !== right
    case "<": return left < right
    case ">": return left > right
    case "<=": return left <= right
    case ">=": return left >= right
    default: return false
  }
}

// ---------------------------------------------------------------------------
// Evaluator
// ---------------------------------------------------------------------------

// `lookup(ref)` returns an already-computed value for a cell. Recalculation
// evaluates in dependency order, so a formula never has to recurse.
export function evaluate(node, lookup) {
  switch (node.type) {
    case "literal":
      return node.value

    case "name":
      return err(ERRORS.name)

    case "ref": {
      const ref = normalizeRef(node.value)
      return ref ? lookup(ref) : err(ERRORS.ref)
    }

    case "range": {
      const refs = expandRange(node.from, node.to)
      if (refs === null) return err(ERRORS.ref)
      const values = refs.map(lookup)
      const failure = values.find(isError)
      return failure || values
    }

    case "unary": {
      const value = toNumber(evaluate(node.operand, lookup))
      if (isError(value)) return value
      return node.operator === "-" ? -value : value
    }

    case "binary":
      return evaluateBinary(node, lookup)

    case "call": {
      const fn = FUNCTIONS[node.name]
      if (!fn) return err(ERRORS.name)
      const args = node.args.map((argument) => evaluate(argument, lookup))
      const failure = args.find((value) => isError(value) && !Array.isArray(value))
      // IF must be able to return a branch even when the other branch errors,
      // so it inspects its own arguments instead of short-circuiting here.
      if (failure && node.name !== "IF") return failure
      return fn(args)
    }

    default:
      return err(ERRORS.parse)
  }
}

function evaluateBinary(node, lookup) {
  const left = evaluate(node.left, lookup)
  const right = evaluate(node.right, lookup)
  if (isError(left)) return left
  if (isError(right)) return right

  const first = Array.isArray(left) ? left[0] : left
  const second = Array.isArray(right) ? right[0] : right

  if (node.operator === "&") return toText(first) + toText(second)

  if (["=", "<>", "<", ">", "<=", ">="].includes(node.operator)) {
    const bothNumeric = !isError(toNumber(first)) && !isError(toNumber(second)) &&
      typeof first !== "string" && typeof second !== "string"
    const a = bothNumeric ? toNumber(first) : toText(first).toLowerCase()
    const b = bothNumeric ? toNumber(second) : toText(second).toLowerCase()

    switch (node.operator) {
      case "=": return a === b
      case "<>": return a !== b
      case "<": return a < b
      case ">": return a > b
      case "<=": return a <= b
      case ">=": return a >= b
    }
  }

  const a = toNumber(first)
  const b = toNumber(second)
  if (isError(a)) return a
  if (isError(b)) return b

  switch (node.operator) {
    case "+": return a + b
    case "-": return a - b
    case "*": return a * b
    case "/": return b === 0 ? err(ERRORS.div0) : a / b
    case "^": {
      const result = a ** b
      return Number.isFinite(result) ? result : err(ERRORS.value)
    }
    default: return err(ERRORS.parse)
  }
}

// ---------------------------------------------------------------------------
// Recalculation
// ---------------------------------------------------------------------------

// A literal cell value, coerced the way a spreadsheet coerces typed input:
// something that looks like a number becomes one.
export function literalValue(raw) {
  if (raw === null || raw === undefined) return ""
  if (typeof raw === "number" || typeof raw === "boolean") return raw
  const text = String(raw)
  if (text.trim() === "") return ""
  const asNumber = Number(text.replace(/,/g, ""))
  if (!Number.isNaN(asNumber) && /^[\s\-+]?[\d,]*\.?\d+([eE][+\-]?\d+)?\s*$/.test(text)) {
    return asNumber
  }
  return text
}

export function isFormula(cell) {
  return !!cell && typeof cell === "object" && typeof cell.f === "string"
}

/**
 * Computes every cell's value in dependency order.
 *
 * `cells` maps a normalized ref ("B2") to either `{v: literal}` or
 * `{f: "=SUM(A1:A9)"}`. Returns a Map of ref to computed value; cells taking
 * part in a reference cycle get #CIRCULAR rather than hanging or overflowing
 * the stack.
 */
export function recalculate(cells) {
  const values = new Map()
  const parsed = new Map()
  const dependencies = new Map()

  for (const [key, cell] of Object.entries(cells || {})) {
    const ref = normalizeRef(key)
    if (!ref) continue

    if (isFormula(cell)) {
      try {
        const ast = parseFormula(cell.f)
        parsed.set(ref, ast)
        dependencies.set(ref, referencedCells(ast))
      } catch (_error) {
        values.set(ref, err(ERRORS.parse))
      }
    } else {
      values.set(ref, literalValue(cell?.v))
    }
  }

  // Kahn's algorithm over "formula depends on cell": anything left with
  // unresolved dependencies at the end is in (or downstream of) a cycle.
  const dependents = new Map()
  const pending = new Map()

  for (const [ref, refs] of dependencies) {
    const unresolved = refs.filter((dependency) => parsed.has(dependency))
    pending.set(ref, unresolved.length)
    for (const dependency of unresolved) {
      if (!dependents.has(dependency)) dependents.set(dependency, [])
      dependents.get(dependency).push(ref)
    }
  }

  const lookup = (ref) => (values.has(ref) ? values.get(ref) : "")
  const ready = [...pending.entries()].filter(([, count]) => count === 0).map(([ref]) => ref)

  while (ready.length) {
    const ref = ready.shift()
    values.set(ref, evaluate(parsed.get(ref), lookup))
    pending.delete(ref)

    for (const dependent of dependents.get(ref) || []) {
      const remaining = (pending.get(dependent) ?? 0) - 1
      pending.set(dependent, remaining)
      if (remaining === 0) ready.push(dependent)
    }
  }

  for (const ref of pending.keys()) values.set(ref, err(ERRORS.circular))

  return values
}

// What a cell shows once computed. Errors show their code; numbers lose
// floating-point noise (0.1 + 0.2 should read as 0.3, not 0.30000000000000004).
export function formatValue(value) {
  if (value === null || value === undefined) return ""
  if (isError(value)) return value.err
  if (Array.isArray(value)) return formatValue(value[0])
  if (typeof value === "boolean") return value ? "TRUE" : "FALSE"
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return ERRORS.value
    if (Number.isInteger(value)) return String(value)
    return String(Number(value.toPrecision(12)))
  }
  return String(value)
}
