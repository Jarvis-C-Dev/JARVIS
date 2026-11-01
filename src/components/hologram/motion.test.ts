import { describe, expect, it } from "vitest";
import { energyFor, sparkle } from "./motion";

const samples = (m: Parameters<typeof energyFor>[0]) =>
  Array.from({ length: 600 }, (_, i) => energyFor(m, i / 60));

describe("energyFor", () => {
  it("stays in 0..1 for every state at every moment", () => {
    for (const m of ["none", "pulse", "spin", "breathe", "wave"] as const) {
      for (const e of samples(m)) {
        expect(e).toBeGreaterThanOrEqual(0);
        expect(e).toBeLessThanOrEqual(1);
      }
    }
  });
  it("idle is exactly still", () => {
    expect(samples("none").every((e) => e === 0)).toBe(true);
  });
  it("speaking jolts: wide swings, hard kicks, and it does not repeat in a short loop", () => {
    const e = samples("wave");
    expect(Math.max(...e) - Math.min(...e)).toBeGreaterThan(0.6);
    // Frame-to-frame jumps exist (a kick), unlike the calm listening beat.
    const jump = (xs: number[]) =>
      Math.max(...xs.slice(1).map((x, i) => Math.abs(x - xs[i])));
    expect(jump(e)).toBeGreaterThan(0.1);
    expect(jump(samples("pulse"))).toBeLessThan(0.1);
    expect(new Set(e.map((x) => x.toFixed(3))).size).toBeGreaterThan(300);
  });
  it("speaking is livelier on average than listening", () => {
    const mean = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;
    expect(mean(samples("wave"))).toBeGreaterThan(mean(samples("pulse")));
  });
  it("is deterministic", () => {
    expect(energyFor("wave", 3.14)).toBe(energyFor("wave", 3.14));
  });
});

describe("sparkle", () => {
  it("is in 0..1 and differs between sparks", () => {
    for (let s = 0; s < 50; s++) {
      const v = sparkle(s, 1.23);
      expect(v).toBeGreaterThanOrEqual(0);
      expect(v).toBeLessThanOrEqual(1);
    }
    expect(sparkle(1, 2)).not.toBe(sparkle(2, 2));
  });
});
