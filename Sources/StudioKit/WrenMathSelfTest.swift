import Foundation
import simd

/// Verification for the `math` module. Every check runs the real Wren, because the
/// module is Wren source — a Swift reimplementation of the same arithmetic would
/// prove nothing about what scripts actually see.
enum WrenMathSelfTest {

    static func run(check: Checker) {
        testModuleLoads(check)
        testRanges(check)
        testAngles(check)
        testRepeating(check)
        testLists(check)
        testEasing(check)
        testRandom(check)
        testNoise(check)
        testVectorAdditions(check)
    }

    // MARK: - Harness

    /// Runs a script and returns everything it printed.
    private static func run(_ source: String) -> (output: [String], errors: [String]) {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        var script = ScriptObject()
        script.name = "MathTest"
        script.language = .wren
        script.source = source
        model.scripts = [script]

        let console = ScriptConsole()
        let runtime = ScriptRuntime(model: model, console: console)
        runtime.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return (console.lines.filter { $0.kind == .output }.map(\.text),
                console.lines.filter { $0.kind == .error }.map(\.text))
    }

    /// Evaluates expressions and reports which ones were not true.
    private static func assertAll(_ check: Checker, _ label: String,
                                  imports: String = "import \"math\" for Math",
                                  _ expressions: [String]) {
        var body = imports + "\n"
        for expression in expressions {
            let label = expression
                .replacingOccurrences(of: "\"", with: "'")
                .replacingOccurrences(of: "%", with: " mod ")   // % starts an interpolation
            body += "System.print((\(expression)) ? \"ok\" : \"FAILED: \(label)\")\n"
        }
        let result = run(body)
        let failures = result.output.filter { $0.hasPrefix("FAILED") }
        check(label, result.errors.isEmpty && failures.isEmpty,
              "\((result.errors + failures).prefix(3).joined(separator: " | "))")
    }

    // MARK: - Tests

    private static func testModuleLoads(_ check: Checker) {
        print("\nWren math: loading")
        let result = run("""
        import "math" for Math, Ease, Rand, Noise
        System.print(Math.pi)
        System.print(Ease.linear(0.5))
        """)
        check("the module compiles and imports", result.errors.isEmpty, "\(result.errors)")
        check("constants are readable",
              result.output.first?.hasPrefix("3.14159") ?? false, "\(result.output)")
        check("every class is exported", result.output.count == 2, "\(result.output)")

        // Wren's own optional random module is still reachable alongside it.
        let optional = run("""
        import "random" for Random
        var r = Random.new(42)
        System.print(r.int(10) >= 0)
        """)
        check("Wren's built-in random module still works",
              optional.errors.isEmpty && optional.output == ["true"],
              "\(optional.errors) \(optional.output)")
    }

    private static func testRanges(_ check: Checker) {
        print("\nWren math: ranges")
        assertAll(check, "clamping and interpolation", [
            "Math.clamp(5, 0, 1) == 1",
            "Math.clamp(-5, 0, 1) == 0",
            "Math.clamp(0.5, 0, 1) == 0.5",
            "Math.saturate(2) == 1",
            "Math.lerp(0, 10, 0.25) == 2.5",
            "Math.lerp(10, 20, 0) == 10",
            "Math.lerp(10, 20, 1) == 20",
            "Math.lerp(0, 10, 2) == 20",
            "Math.lerpClamped(0, 10, 2) == 10",
            "Math.inverseLerp(10, 20, 15) == 0.5",
            "Math.inverseLerp(5, 5, 5) == 0",
            "Math.remap(5, 0, 10, 100, 200) == 150",
            "Math.remapClamped(50, 0, 10, 100, 200) == 200",
            "Math.step(0.5, 0.4) == 0",
            "Math.step(0.5, 0.6) == 1"
        ])

        assertAll(check, "smoothstep", [
            "Math.smoothstep(0, 1, 0) == 0",
            "Math.smoothstep(0, 1, 1) == 1",
            "Math.smoothstep(0, 1, 0.5) == 0.5",
            "Math.smoothstep(0, 1, -3) == 0",
            "Math.smoothstep(0, 1, 9) == 1",
            // Eased, so it lags a straight line in the first half.
            "Math.smoothstep(0, 1, 0.25) < 0.25",
            "Math.smoothstep(0, 1, 0.75) > 0.75",
            "Math.smootherstep(0, 1, 0.5) == 0.5",
            "Math.smootherstep(0, 1, 0.25) < Math.smoothstep(0, 1, 0.25)"
        ])

        assertAll(check, "signs and comparisons", [
            "Math.sign(-4) == -1",
            "Math.sign(0) == 0",
            "Math.sign(9) == 1",
            "Math.approximately(0.1 + 0.2, 0.3)",
            "!Math.approximately(0.1, 0.2)",
            "Math.approximately(1, 1.4, 0.5)"
        ])
    }

    private static func testAngles(_ check: Checker) {
        print("\nWren math: angles")
        assertAll(check, "conversion", [
            "Math.approximately(Math.degrees(Math.pi), 180)",
            "Math.approximately(Math.radians(180), Math.pi)",
            "Math.approximately(Math.radians(Math.degrees(1.234)), 1.234)"
        ])

        assertAll(check, "wrapping and shortest turns", [
            "Math.wrapAngle(0) == 0",
            "Math.wrapAngle(180) == -180",
            "Math.wrapAngle(190) == -170",
            "Math.wrapAngle(-190) == 170",
            "Math.wrapAngle(720) == 0",
            "Math.approximately(Math.wrapAngle(365), 5)",
            // The whole point: 350 to 10 is a 20 degree turn, not 340.
            "Math.deltaAngle(350, 10) == 20",
            "Math.deltaAngle(10, 350) == -20",
            "Math.deltaAngle(0, 90) == 90",
            "Math.moveTowardsAngle(350, 10, 5) == 355",
            "Math.moveTowardsAngle(350, 10, 90) == 10"
        ])
    }

    private static func testRepeating(_ check: Checker) {
        print("\nWren math: repeating")
        assertAll(check, "wrap keeps the result positive", [
            "Math.wrap(7, 5) == 2",
            "Math.wrap(5, 5) == 0",
            "Math.wrap(-1, 5) == 4",
            "Math.wrap(-6, 5) == 4",
            "Math.wrap(3, 0) == 0",
            // Which is exactly where % differs.
            "(-1 % 5) != Math.wrap(-1, 5)"
        ])

        assertAll(check, "pingPong bounces", [
            "Math.pingPong(0, 10) == 0",
            "Math.pingPong(5, 10) == 5",
            "Math.pingPong(10, 10) == 10",
            "Math.pingPong(15, 10) == 5",
            "Math.pingPong(20, 10) == 0",
            "Math.pingPong(25, 10) == 5"
        ])

        assertAll(check, "moveTowards and snap", [
            "Math.moveTowards(0, 10, 3) == 3",
            "Math.moveTowards(0, 10, 100) == 10",
            "Math.moveTowards(10, 0, 3) == 7",
            "Math.moveTowards(5, 5, 1) == 5",
            "Math.snap(1.4, 1) == 1",
            "Math.snap(1.6, 1) == 2",
            "Math.snap(2.3, 0.5) == 2.5",
            "Math.snap(7, 0) == 7"
        ])
    }

    private static func testLists(_ check: Checker) {
        print("\nWren math: lists")
        assertAll(check, "aggregates", [
            "Math.minOf([3, 1, 2]) == 1",
            "Math.maxOf([3, 1, 2]) == 3",
            "Math.sum([1, 2, 3, 4]) == 10",
            "Math.average([2, 4, 6]) == 4",
            "Math.minOf([]) == 0",
            "Math.sum([]) == 0",
            "Math.average([]) == 0",
            "Math.minOf([-5]) == -5"
        ])
    }

    private static func testEasing(_ check: Checker) {
        print("\nWren math: easing")
        // Every curve must start at 0 and end at 1, or it cannot be used for a blend.
        let curves = ["linear", "inSine", "outSine", "inOutSine", "inQuad", "outQuad",
                      "inOutQuad", "inCubic", "outCubic", "inOutCubic", "inQuart",
                      "outQuart", "inExpo", "outExpo", "inCirc", "outCirc",
                      "outElastic", "outBounce", "inBounce"]
        var expressions: [String] = []
        for curve in curves {
            expressions.append("Math.approximately(Ease.\(curve)(0), 0, 0.0001)")
            expressions.append("Math.approximately(Ease.\(curve)(1), 1, 0.0001)")
        }
        assertAll(check, "every curve runs from 0 to 1",
                  imports: "import \"math\" for Math, Ease", expressions)

        assertAll(check, "curves have the right shape",
                  imports: "import \"math\" for Math, Ease", [
            "Ease.inQuad(0.5) < 0.5",          // slow start
            "Ease.outQuad(0.5) > 0.5",         // fast start
            "Math.approximately(Ease.inOutQuad(0.5), 0.5)",
            "Ease.inCubic(0.5) < Ease.inQuad(0.5)",
            "Ease.outBack(0.8) > 1",           // overshoots before settling
            "Ease.linear(0.37) == 0.37"
        ])

        // Monotonic curves should never go backwards.
        assertAll(check, "monotonic curves never reverse",
                  imports: "import \"math\" for Math, Ease", [
            "(1...20).all { |i| Ease.inQuad(i / 20) >= Ease.inQuad((i - 1) / 20) }",
            "(1...20).all { |i| Ease.outCubic(i / 20) >= Ease.outCubic((i - 1) / 20) }",
            "(1...20).all { |i| Ease.inOutSine(i / 20) >= Ease.inOutSine((i - 1) / 20) }"
        ])
    }

    private static func testRandom(_ check: Checker) {
        print("\nWren math: random")
        // The same seed has to give the same world.
        let repeatable = run("""
        import "math" for Rand
        Rand.seed(1234)
        var first = [Rand.float, Rand.int(100), Rand.float(-5, 5)]
        Rand.seed(1234)
        var second = [Rand.float, Rand.int(100), Rand.float(-5, 5)]
        System.print(first.toString == second.toString)
        Rand.seed(9999)
        var third = [Rand.float, Rand.int(100), Rand.float(-5, 5)]
        System.print(first.toString != third.toString)
        """)
        check("the same seed repeats exactly", repeatable.output.first == "true",
              "\(repeatable.output) \(repeatable.errors)")
        check("a different seed differs", repeatable.output.count > 1 && repeatable.output[1] == "true",
              "\(repeatable.output)")

        assertAll(check, "values land in range",
                  imports: "import \"math\" for Math, Rand\nRand.seed(7)", [
            "(1..200).all { |i| Rand.float >= 0 }",
            "(1..200).all { |i| Rand.float < 1 }",
            "(1..200).all { |i| Rand.float(10) < 10 }",
            "(1..200).all { |i| Rand.float(-3, 3) >= -3 }",
            "(1..200).all { |i| Rand.float(-3, 3) < 3 }",
            "(1..200).all { |i| Rand.int(5) >= 0 }",
            "(1..200).all { |i| Rand.int(5) <= 4 }",
            "(1..200).all { |i| Rand.int(10, 20) >= 10 }",
            "(1..200).all { |i| Rand.int(10, 20) <= 19 }",
            "(1..200).all { |i| Rand.angle < 360 }",
            "(1..50).all { |i| Rand.int(1) == 0 }"
        ])

        // A generator that always returns the same thing would pass range checks.
        let spread = run("""
        import "math" for Rand
        Rand.seed(5)
        var buckets = [0, 0, 0, 0]
        for (i in 1..400) {
          var b = Rand.int(4)
          buckets[b] = buckets[b] + 1
        }
        System.print(buckets.all { |c| c > 40 })
        System.print(buckets.reduce { |a, b| a + b } == 400)
        """)
        check("values are spread across the range, not stuck",
              spread.output.first == "true", "\(spread.output) \(spread.errors)")
        check("every draw is accounted for",
              spread.output.count > 1 && spread.output[1] == "true", "\(spread.output)")

        let helpers = run("""
        import "math" for Rand
        import "studio" for Vec3
        Rand.seed(3)
        System.print(Rand.pick([]) == null)
        System.print([1, 2, 3].contains(Rand.pick([1, 2, 3])))
        var list = [1, 2, 3, 4, 5]
        var shuffled = Rand.shuffle(list)
        System.print(shuffled.count == 5)
        System.print((1..5).all { |n| shuffled.contains(n) })
        var d = Rand.direction
        System.print((d.length - 1).abs < 0.0001)
        var inside = Rand.insideSphere(10)
        System.print(inside.length <= 10.0001)
        System.print(Rand.bool is Bool)
        """)
        check("pick on an empty list is null", helpers.output.first == "true", "\(helpers.output)")
        check("pick returns a member", helpers.output.count > 1 && helpers.output[1] == "true")
        check("shuffle keeps every element",
              helpers.output.count > 3 && helpers.output[2] == "true" && helpers.output[3] == "true",
              "\(helpers.output)")
        check("a random direction is a unit vector",
              helpers.output.count > 4 && helpers.output[4] == "true", "\(helpers.output)")
        check("insideSphere stays inside the radius",
              helpers.output.count > 5 && helpers.output[5] == "true", "\(helpers.output)")
        check("bool is a boolean",
              helpers.output.count > 6 && helpers.output[6] == "true", "\(helpers.output)")
        check("no errors from the helpers", helpers.errors.isEmpty, "\(helpers.errors)")
    }

    private static func testNoise(_ check: Checker) {
        print("\nWren math: noise")
        let result = run("""
        import "math" for Noise, Math
        Noise.seed(0)

        // Same input, same output — otherwise terrain would boil every frame.
        System.print(Noise.value(3.7, 2.1) == Noise.value(3.7, 2.1))

        // In range.
        var inRange = true
        var smooth = true
        var previous = Noise.value(0, 0)
        var x = 0
        while (x < 200) {
          var v = Noise.value(x / 20, x / 33)
          if (v < 0 || v > 1) inRange = false
          x = x + 1
        }
        System.print(inRange)

        // Neighbouring samples are close: that is what makes it noise and not hash.
        var jumpy = false
        var i = 0
        while (i < 100) {
          var a = Noise.value(i / 50, 0)
          var b = Noise.value((i + 1) / 50, 0)
          if ((a - b).abs > 0.35) jumpy = true
          i = i + 1
        }
        System.print(!jumpy)

        // But it does vary — a constant would pass everything above.
        var lo = 1
        var hi = 0
        var j = 0
        while (j < 200) {
          var v = Noise.value(j / 7.0, j / 11.0)
          if (v < lo) lo = v
          if (v > hi) hi = v
          j = j + 1
        }
        System.print(hi - lo > 0.4)

        System.print(Noise.fbm(1.5, 2.5) >= 0 && Noise.fbm(1.5, 2.5) <= 1)
        System.print(Noise.fbm(1.5, 2.5, 6) == Noise.fbm(1.5, 2.5, 6))
        System.print(Noise.value(1.0) == Noise.value(1.0, 0))
        """)
        check("noise is deterministic", result.output.first == "true",
              "\(result.output) \(result.errors)")
        check("noise stays within 0 and 1",
              result.output.count > 1 && result.output[1] == "true", "\(result.output)")
        check("noise is smooth between samples",
              result.output.count > 2 && result.output[2] == "true", "\(result.output)")
        check("noise actually varies",
              result.output.count > 3 && result.output[3] == "true", "\(result.output)")
        check("fbm stays in range",
              result.output.count > 4 && result.output[4] == "true", "\(result.output)")
        check("fbm is deterministic",
              result.output.count > 5 && result.output[5] == "true", "\(result.output)")
        check("the 1D form matches the 2D form at y = 0",
              result.output.count > 6 && result.output[6] == "true", "\(result.output)")

        let seeded = run("""
        import "math" for Noise
        Noise.seed(1)
        var a = Noise.value(2.5, 2.5)
        Noise.seed(2)
        var b = Noise.value(2.5, 2.5)
        System.print(a != b)
        """)
        check("seeding changes the field", seeded.output.first == "true",
              "\(seeded.output) \(seeded.errors)")
    }

    private static func testVectorAdditions(_ check: Checker) {
        print("\nWren math: vectors")
        assertAll(check, "lengths and distances",
                  imports: "import \"math\" for Math\nimport \"studio\" for Vec3", [
            "Vec3.new(3, 4, 0).lengthSquared == 25",
            "Vec3.new(0, 0, 0).distanceTo(Vec3.new(3, 4, 0)) == 5",
            "Vec3.distance(Vec3.new(1, 0, 0), Vec3.new(4, 4, 0)) == 5",
            "Vec3.new(-1, 2, -3).abs == Vec3.new(1, 2, 3)",
            "Vec3.new(1.6, 1.4, -1.6).round == Vec3.new(2, 1, -2)",
            "Vec3.new(1.6, 1.4, 1.9).floor == Vec3.new(1, 1, 1)"
        ])

        assertAll(check, "component operations",
                  imports: "import \"math\" for Math\nimport \"studio\" for Vec3", [
            "Vec3.new(2, 3, 4).scaled(Vec3.new(2, 2, 2)) == Vec3.new(4, 6, 8)",
            "Vec3.new(1, 5, 3).min(Vec3.new(4, 2, 3)) == Vec3.new(1, 2, 3)",
            "Vec3.new(1, 5, 3).max(Vec3.new(4, 2, 3)) == Vec3.new(4, 5, 3)",
            "Vec3.new(1, 2, 3).withY(9) == Vec3.new(1, 9, 3)",
            "Vec3.new(1, 2, 3).largestComponent == 3",
            "Vec3.new(1, 2, 3).sum == 6"
        ])

        assertAll(check, "directions",
                  imports: "import \"math\" for Math\nimport \"studio\" for Vec3", [
            // Bouncing off a floor flips only the vertical part.
            "Vec3.new(1, -1, 0).reflect(Vec3.up) == Vec3.new(1, 1, 0)",
            "Vec3.new(3, 4, 0).project(Vec3.new(1, 0, 0)) == Vec3.new(3, 0, 0)",
            "Math.approximately(Vec3.new(1, 0, 0).angleTo(Vec3.new(0, 1, 0)), 90, 0.001)",
            "Math.approximately(Vec3.new(1, 0, 0).angleTo(Vec3.new(1, 0, 0)), 0, 0.001)",
            "Math.approximately(Vec3.new(1, 0, 0).angleTo(Vec3.new(-1, 0, 0)), 180, 0.001)",
            // A quarter turn about Y takes +X to -Z.
            "Vec3.new(1, 0, 0).rotatedY(90).distanceTo(Vec3.new(0, 0, -1)) < 0.0001",
            "Vec3.new(1, 0, 0).rotatedY(360).distanceTo(Vec3.new(1, 0, 0)) < 0.0001",
            "Vec3.onCircleY(0, 5).distanceTo(Vec3.new(5, 0, 0)) < 0.0001",
            "Math.approximately(Vec3.onCircleY(37, 4).length, 4, 0.0001)",
            "Vec3.onCircleY(90, 1).distanceTo(Vec3.new(1, 0, 0).rotatedY(90)) < 0.0001"
        ])

        // The script helper has to agree with what actually rotating a part does,
        // or a script that positions something and then turns it will disagree
        // with itself.
        for angle in [Float(37), 90, 145, -60] {
            let expected = simd_quatf(angle: angle * .pi / 180, axis: Vec3(0, 1, 0))
                .act(Vec3(1, 0, 0))
            let result = run("""
            import "studio" for Vec3
            var v = Vec3.new(1, 0, 0).rotatedY(\(angle))
            System.print("%(v.x) %(v.y) %(v.z)")
            """)
            let pieces = (result.output.first ?? "").split(separator: " ").compactMap { Float($0) }
            check("rotatedY(\(Int(angle))) matches a part's Y rotation",
                  pieces.count == 3
                      && abs(pieces[0] - expected.x) < 0.001
                      && abs(pieces[2] - expected.z) < 0.001,
                  "wren \(pieces) vs simd \(expected)")
        }
    }
}
