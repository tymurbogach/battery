const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

test("probe source accepts only documented exit codes", () => {
  assert.equal(Model.probeSourceFromExit(0), "ac")
  assert.equal(Model.probeSourceFromExit(1), "battery")
  assert.equal(Model.probeSourceFromExit(2), "")
  assert.equal(Model.probeSourceFromExit(127), "")
})

test("effective source preserves UPower fallback when the probe is unknown", () => {
  assert.equal(Model.effectiveSource("", "ac"), "ac")
  assert.equal(Model.effectiveSource("battery", "ac"), "battery")
})

test("parse helpers reject malformed values", () => {
  assert.equal(Model.parseGdbusBoolean("invalid"), null)
  assert.equal(Model.parseWattsRate("NaN"), null)
  assert.equal(Model.finiteFraction("Infinity"), null)
})

test("drain history retains zero watts and bounds its window", () => {
  const samples = Model.appendDrainSample([], 0, 100, 600)
  assert.deepEqual(samples, [{ t: 100, w: 0 }])

  const pruned = Model.appendDrainSample(samples, 10, 701, 600)
  assert.deepEqual(pruned, [{ t: 701, w: 10 }])
})

test("profiles preserve their active item and selection bounds", () => {
  const parsed = Model.parseProfiles("balanced\t1\nperformance\t0\n", 8)
  assert.deepEqual(parsed, {
    profiles: ["balanced", "performance"],
    activeProfile: "balanced",
    profileIndex: 1
  })
})
