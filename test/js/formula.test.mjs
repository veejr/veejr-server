// Formula engine: tokenizer, parser, evaluator, and recalculation order.
//
// This is the part of the spreadsheet that has to be right — a wrong SUM is
// worse than a missing one, because nothing tells you it is wrong.

import {test} from "node:test"
import assert from "node:assert/strict"

import {
  ERRORS,
  columnToIndex,
  evaluate,
  expandRange,
  formatValue,
  indexToColumn,
  isError,
  literalValue,
  normalizeRef,
  parseFormula,
  recalculate,
  referencedCells,
  tokenize,
} from "../../assets/js/veejr/docs/formula.js"

// A sheet literal, so the tests read like a spreadsheet rather than a fixture.
function sheet(cells) {
  const source = {}
  for (const [ref, value] of Object.entries(cells)) {
    source[ref] = typeof value === "string" && value.startsWith("=") ? {f: value} : {v: value}
  }
  return recalculate(source)
}

const valueAt = (cells, ref) => formatValue(sheet(cells).get(ref))

test("column letters round-trip past Z", () => {
  assert.equal(columnToIndex("A"), 0)
  assert.equal(columnToIndex("Z"), 25)
  assert.equal(columnToIndex("AA"), 26)
  assert.equal(columnToIndex("AZ"), 51)
  assert.equal(indexToColumn(0), "A")
  assert.equal(indexToColumn(26), "AA")
  assert.equal(indexToColumn(51), "AZ")

  for (const index of [0, 1, 25, 26, 27, 100, 701, 702]) {
    assert.equal(columnToIndex(indexToColumn(index)), index)
  }
})

test("absolute and lower-case references normalize to one key", () => {
  assert.equal(normalizeRef("$B$2"), "B2")
  assert.equal(normalizeRef("b2"), "B2")
  assert.equal(normalizeRef("B$2"), "B2")
  assert.equal(normalizeRef("B0"), null)
  assert.equal(normalizeRef("hello"), null)
})

test("ranges expand in row-major order and refuse absurd sizes", () => {
  assert.deepEqual(expandRange("A1", "B2"), ["A1", "B1", "A2", "B2"])
  // Reversed corners describe the same rectangle.
  assert.deepEqual(expandRange("B2", "A1"), ["A1", "B1", "A2", "B2"])
  assert.equal(expandRange("A1", "ZZ100000"), null)
})

test("tokenizer handles strings, numbers, and operators", () => {
  assert.deepEqual(tokenize('"a""b"'), [{type: "string", value: 'a"b'}])
  assert.deepEqual(tokenize("1e-3"), [{type: "number", value: 0.001}])
  assert.deepEqual(tokenize("<="), [{type: "operator", value: "<="}])
  assert.throws(() => tokenize('"unterminated'), SyntaxError)
})

test("arithmetic follows precedence and associativity", () => {
  assert.equal(valueAt({A1: "=1+2*3"}, "A1"), "7")
  assert.equal(valueAt({A1: "=(1+2)*3"}, "A1"), "9")
  assert.equal(valueAt({A1: "=2^3^2"}, "A1"), "512") // right-associative
  assert.equal(valueAt({A1: "=-2^2"}, "A1"), "4") // unary binds tighter here
  assert.equal(valueAt({A1: "=10/4"}, "A1"), "2.5")
})

test("division by zero is an error value, not Infinity", () => {
  assert.equal(valueAt({A1: "=1/0"}, "A1"), ERRORS.div0)
  assert.equal(valueAt({A1: 0, B1: "=10/A1"}, "B1"), ERRORS.div0)
})

test("SUM ignores blanks and text-free cells", () => {
  const cells = {A1: 1, A2: 2, A3: "", A4: 3}
  assert.equal(valueAt({...cells, B1: "=SUM(A1:A4)"}, "B1"), "6")
  assert.equal(valueAt({...cells, B1: "=COUNT(A1:A4)"}, "B1"), "3")
  assert.equal(valueAt({...cells, B1: "=AVERAGE(A1:A4)"}, "B1"), "2")
})

test("text in a numeric range surfaces as #VALUE!", () => {
  assert.equal(valueAt({A1: 1, A2: "apples", B1: "=SUM(A1:A2)"}, "B1"), ERRORS.value)
})

test("IF returns the branch it selected, even when the other would error", () => {
  assert.equal(valueAt({A1: 0, B1: '=IF(A1=0,"zero",1/A1)'}, "B1"), "zero")
  assert.equal(valueAt({A1: 4, B1: "=IF(A1>2,A1*2,0)"}, "B1"), "8")
})

test("string functions and concatenation", () => {
  assert.equal(valueAt({A1: "veejr", B1: "=UPPER(A1)"}, "B1"), "VEEJR")
  assert.equal(valueAt({A1: "veejr", B1: '=A1&" rocks"'}, "B1"), "veejr rocks")
  assert.equal(valueAt({A1: "  a  b  ", B1: "=TRIM(A1)"}, "B1"), "a b")
  assert.equal(valueAt({A1: "abcdef", B1: "=MID(A1,2,3)"}, "B1"), "bcd")
  assert.equal(valueAt({A1: "abcdef", B1: "=RIGHT(A1,2)"}, "B1"), "ef")
  assert.equal(valueAt({A1: "abcdef", B1: "=RIGHT(A1,0)"}, "B1"), "")
})

test("COUNTIF and SUMIF accept comparison criteria", () => {
  const cells = {A1: 5, A2: 15, A3: 25, B1: 1, B2: 2, B3: 3}
  assert.equal(valueAt({...cells, C1: '=COUNTIF(A1:A3,">10")'}, "C1"), "2")
  assert.equal(valueAt({...cells, C1: '=SUMIF(A1:A3,">10",B1:B3)'}, "C1"), "5")
  assert.equal(valueAt({A1: "done", A2: "todo", C1: '=COUNTIF(A1:A2,"done")'}, "C1"), "1")
})

test("an unknown function is #NAME? rather than a crash", () => {
  assert.equal(valueAt({A1: "=NOTAFUNCTION(1)"}, "A1"), ERRORS.name)
  assert.equal(valueAt({A1: "=SUM(1,"}, "A1"), ERRORS.parse)
})

test("recalculation runs in dependency order regardless of insertion order", () => {
  // C1 is defined before the cells it depends on.
  const values = sheet({C1: "=B1*2", B1: "=A1+1", A1: 5})
  assert.equal(formatValue(values.get("B1")), "6")
  assert.equal(formatValue(values.get("C1")), "12")
})

test("reference cycles report #CIRCULAR instead of hanging", () => {
  const direct = sheet({A1: "=A1"})
  assert.equal(formatValue(direct.get("A1")), ERRORS.circular)

  const indirect = sheet({A1: "=B1", B1: "=C1", C1: "=A1"})
  for (const ref of ["A1", "B1", "C1"]) {
    assert.equal(formatValue(indirect.get(ref)), ERRORS.circular)
  }

  // A cell that merely reads a cycle is also unresolvable, but the rest of
  // the sheet must still compute.
  const mixed = sheet({A1: "=B1", B1: "=A1", D1: 2, E1: "=D1*3"})
  assert.equal(formatValue(mixed.get("E1")), "6")
})

test("a deep dependency chain does not overflow the stack", () => {
  const cells = {A1: {v: 1}}
  for (let row = 2; row <= 5000; row++) cells[`A${row}`] = {f: `=A${row - 1}+1`}
  const values = recalculate(cells)
  assert.equal(formatValue(values.get("A5000")), "5000")
})

test("empty cells read as zero in arithmetic and blank in text", () => {
  assert.equal(valueAt({A1: "=Z9+1"}, "A1"), "1")
  assert.equal(valueAt({A1: '=Z9&"x"'}, "A1"), "x")
})

test("typed input is coerced the way a spreadsheet coerces it", () => {
  assert.equal(literalValue("42"), 42)
  assert.equal(literalValue("1,234"), 1234)
  assert.equal(literalValue("0042"), 42)
  assert.equal(literalValue("3.5kg"), "3.5kg")
  assert.equal(literalValue(""), "")
  assert.equal(literalValue("2026-07-30"), "2026-07-30")
})

test("floating point noise is not shown to the user", () => {
  assert.equal(valueAt({A1: "=0.1+0.2"}, "A1"), "0.3")
  assert.equal(valueAt({A1: "=1/3"}, "A1"), "0.333333333333")
})

test("referencedCells lists dependencies including whole ranges", () => {
  const ast = parseFormula("=SUM(A1:A3)+$B$7")
  assert.deepEqual(referencedCells(ast).sort(), ["A1", "A2", "A3", "B7"])
})

test("evaluate reports #REF! for a range too large to expand", () => {
  const ast = parseFormula("=SUM(A1:ZZ100000)")
  assert.ok(isError(evaluate(ast, () => 0)))
})
