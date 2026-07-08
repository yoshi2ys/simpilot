import XCTest
@testable import simpilot

final class ScenarioParserTests: XCTestCase {

    // MARK: - A19: empty scalar actions are rejected, not posted as empty

    func testEmptyScalarActionThrows() throws {
        let yaml = try YAMLParser.parse("""
        name: T
        scenarios:
          - name: S
            steps:
              - tap:
        """)
        XCTAssertThrowsError(try ScenarioParser.parse(yaml)) { error in
            XCTAssertTrue(error is ScenarioParseError)
        }
    }

    func testEmptyRequireScalarActionThrows() throws {
        let yaml = try YAMLParser.parse("""
        name: T
        scenarios:
          - name: S
            steps:
              - launch:
        """)
        XCTAssertThrowsError(try ScenarioParser.parse(yaml)) { error in
            guard let e = error as? ScenarioParseError else { return XCTFail("expected ScenarioParseError") }
            XCTAssertTrue(e.description.contains("launch"))
        }
    }

    /// A23/A19 gap: `{query: ""}` in the mapping form must also be rejected, not
    /// just the bare-scalar form.
    func testEmptyQueryInMappingFormThrows() throws {
        let yaml = try YAMLParser.parse("""
        name: T
        scenarios:
          - name: S
            steps:
              - launch:
                  query: ""
        """)
        XCTAssertThrowsError(try ScenarioParser.parse(yaml))
    }

    /// Regression guard: `type` is exempt from the empty-value rejection — a
    /// whitespace-only value is a legitimate thing to type.
    func testTypeAllowsWhitespaceOnlyText() throws {
        let yaml = try YAMLParser.parse("""
        name: T
        scenarios:
          - name: S
            steps:
              - type: " "
        """)
        let file = try ScenarioParser.parse(yaml)
        guard case .type(let text, _, _) = file.scenarios[0].steps[0].action else {
            return XCTFail("expected type action")
        }
        XCTAssertEqual(text, " ")
    }

    // MARK: - A20: unknown/typo fields are rejected, not silently dropped

    func testUnknownFieldInActionThrows() throws {
        let yaml = try YAMLParser.parse("""
        name: T
        scenarios:
          - name: S
            steps:
              - tap:
                  query: General
                  timout: 5
        """)
        XCTAssertThrowsError(try ScenarioParser.parse(yaml)) { error in
            guard let e = error as? ScenarioParseError else { return XCTFail("expected ScenarioParseError") }
            XCTAssertTrue(e.description.contains("timout"))
        }
    }

    func testKnownFieldsAreAccepted() throws {
        let yaml = try YAMLParser.parse("""
        name: T
        scenarios:
          - name: S
            steps:
              - tap:
                  query: General
                  wait_until: hittable
                  timeout: 5
        """)
        XCTAssertNoThrow(try ScenarioParser.parse(yaml))
    }

    // MARK: - Minimal valid scenario

    func testMinimalScenario() throws {
        let yaml = try YAMLParser.parse("""
        name: Test
        scenarios:
          - name: S1
            steps:
              - tap: General
        """)
        let file = try ScenarioParser.parse(yaml)
        XCTAssertEqual(file.name, "Test")
        XCTAssertEqual(file.scenarios.count, 1)
        XCTAssertEqual(file.scenarios[0].name, "S1")
        XCTAssertEqual(file.scenarios[0].steps.count, 1)

        if case .tap(let q, let w, let t) = file.scenarios[0].steps[0].action {
            XCTAssertEqual(q, "General")
            XCTAssertNil(w)
            XCTAssertNil(t)
        } else {
            XCTFail("Expected tap action")
        }
    }

    // MARK: - Config defaults

    func testDefaultConfig() throws {
        let yaml = try YAMLParser.parse("""
        name: Test
        scenarios:
          - name: S1
            steps:
              - sleep: 1
        """)
        let file = try ScenarioParser.parse(yaml)
        XCTAssertEqual(file.config.timeout, 5)
        XCTAssertTrue(file.config.stopOnFailure)
        XCTAssertTrue(file.config.screenshotOnFailure)
        XCTAssertEqual(file.config.screenshotDir, "/tmp/simpilot-failures")
    }

    func testConfigOverrides() throws {
        let yaml = try YAMLParser.parse("""
        name: Test
        config:
          timeout: 10
          stop_on_failure: false
          screenshot_on_failure: false
          screenshot_dir: /tmp/custom
        scenarios:
          - name: S1
            steps:
              - sleep: 1
        """)
        let file = try ScenarioParser.parse(yaml)
        XCTAssertEqual(file.config.timeout, 10)
        XCTAssertFalse(file.config.stopOnFailure)
        XCTAssertFalse(file.config.screenshotOnFailure)
        XCTAssertEqual(file.config.screenshotDir, "/tmp/custom")
    }

    // MARK: - Variable substitution

    func testVariableSubstitution() throws {
        let yaml = try YAMLParser.parse("""
        name: Test
        variables:
          app: com.apple.Preferences
        scenarios:
          - name: S1
            steps:
              - launch: ${app}
        """)
        let file = try ScenarioParser.parse(yaml)
        if case .launch(let bundleId) = file.scenarios[0].steps[0].action {
            XCTAssertEqual(bundleId, "com.apple.Preferences")
        } else {
            XCTFail("Expected launch action")
        }
    }

    func testCLIVarsOverrideYAMLVars() throws {
        let yaml = try YAMLParser.parse("""
        name: Test
        variables:
          app: com.apple.Preferences
        scenarios:
          - name: S1
            steps:
              - launch: ${app}
        """)
        let file = try ScenarioParser.parse(yaml, cliVars: ["app": "com.example.App"])
        if case .launch(let bundleId) = file.scenarios[0].steps[0].action {
            XCTAssertEqual(bundleId, "com.example.App")
        } else {
            XCTFail("Expected launch action")
        }
    }

    func testEnvVariableSubstitution() throws {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let result = ScenarioParser.substitute("${env.HOME}/test", variables: [:])
        XCTAssertEqual(result, "\(home)/test")
    }

    // MARK: - Step parsing

    func testAllScalarStepTypes() throws {
        let yaml = try YAMLParser.parse("""
        name: Test
        scenarios:
          - name: S1
            steps:
              - launch: com.apple.Preferences
              - terminate: com.apple.Preferences
              - activate: com.apple.Preferences
              - tap: General
              - doubletap: Edit
              - swipe: up
              - scroll_to: Privacy
              - sleep: 2
        """)
        let file = try ScenarioParser.parse(yaml)
        let steps = file.scenarios[0].steps

        if case .launch(let id) = steps[0].action { XCTAssertEqual(id, "com.apple.Preferences") }
        else { XCTFail("Expected launch") }

        if case .terminate(let id) = steps[1].action { XCTAssertEqual(id, "com.apple.Preferences") }
        else { XCTFail("Expected terminate") }

        if case .activate(let id) = steps[2].action { XCTAssertEqual(id, "com.apple.Preferences") }
        else { XCTFail("Expected activate") }

        if case .tap(let q, _, _) = steps[3].action { XCTAssertEqual(q, "General") }
        else { XCTFail("Expected tap") }

        if case .doubletap(let q) = steps[4].action { XCTAssertEqual(q, "Edit") }
        else { XCTFail("Expected doubletap") }

        if case .swipe(let d, _, _) = steps[5].action { XCTAssertEqual(d, "up") }
        else { XCTFail("Expected swipe") }

        if case .scrollTo(let q, _, _) = steps[6].action { XCTAssertEqual(q, "Privacy") }
        else { XCTFail("Expected scrollTo") }

        if case .sleep(let s) = steps[7].action { XCTAssertEqual(s, 2) }
        else { XCTFail("Expected sleep") }
    }

    func testMappingStepTypes() throws {
        let yaml = try YAMLParser.parse("""
        name: Test
        scenarios:
          - name: S1
            steps:
              - tap:
                  query: General
                  timeout: 3
              - type:
                  text: hello
                  into: "textField:Email"
                  method: paste
              - assert:
                  predicate: exists
                  query: "text:About"
                  timeout: 5
              - wait:
                  query: spinner
                  timeout: 10
                  gone: true
              - screenshot:
                  file: /tmp/s.png
                  scale: native
                  format: jpeg
                  quality: 80
        """)
        let file = try ScenarioParser.parse(yaml)
        let steps = file.scenarios[0].steps

        if case .tap(let q, _, let t) = steps[0].action {
            XCTAssertEqual(q, "General")
            XCTAssertEqual(t, 3)
        } else { XCTFail("Expected tap") }

        if case .type(let text, let into, let method) = steps[1].action {
            XCTAssertEqual(text, "hello")
            XCTAssertEqual(into, "textField:Email")
            XCTAssertEqual(method, "paste")
        } else { XCTFail("Expected type") }

        if case .assert(let p, let q, _, let t) = steps[2].action {
            XCTAssertEqual(p, "exists")
            XCTAssertEqual(q, "text:About")
            XCTAssertEqual(t, 5)
        } else { XCTFail("Expected assert") }

        if case .wait(let q, let t, let g) = steps[3].action {
            XCTAssertEqual(q, "spinner")
            XCTAssertEqual(t, 10)
            XCTAssertTrue(g)
        } else { XCTFail("Expected wait") }

        if case .screenshot(let f, let s, _, let fmt, let qual) = steps[4].action {
            XCTAssertEqual(f, "/tmp/s.png")
            XCTAssertEqual(s, "native")
            XCTAssertEqual(fmt, "jpeg")
            XCTAssertEqual(qual, 80)
        } else { XCTFail("Expected screenshot") }
    }

    // MARK: - Error cases

    func testMissingScenariosThrows() throws {
        let yaml = try YAMLParser.parse("name: Test")
        XCTAssertThrowsError(try ScenarioParser.parse(yaml)) { error in
            XCTAssertTrue("\(error)".contains("missing 'scenarios'"))
        }
    }

    func testUnknownStepTypeThrows() throws {
        let yaml = try YAMLParser.parse("""
        name: Test
        scenarios:
          - name: S1
            steps:
              - fly: away
        """)
        XCTAssertThrowsError(try ScenarioParser.parse(yaml)) { error in
            XCTAssertTrue("\(error)".contains("unknown step type 'fly'"))
        }
    }

    func testConfigNonMappingThrows() throws {
        // Scalar config
        let yaml1 = try YAMLParser.parse("""
        name: Test
        config: foo
        scenarios:
          - name: S1
            steps:
              - sleep: 1
        """)
        XCTAssertThrowsError(try ScenarioParser.parse(yaml1)) { error in
            XCTAssertTrue("\(error)".contains("config must be a mapping"))
        }

        // Sequence config
        let yaml2 = try YAMLParser.parse("""
        name: Test
        config:
          - item1
          - item2
        scenarios:
          - name: S1
            steps:
              - sleep: 1
        """)
        XCTAssertThrowsError(try ScenarioParser.parse(yaml2)) { error in
            XCTAssertTrue("\(error)".contains("config must be a mapping"))
        }
    }

    func testStepMultipleActionKeysThrows() throws {
        let yaml = try YAMLParser.parse("""
        name: Test
        scenarios:
          - name: S1
            steps:
              - tap: General
                type: hello
        """)
        XCTAssertThrowsError(try ScenarioParser.parse(yaml)) { error in
            XCTAssertTrue("\(error)".contains("exactly one action key"))
        }
    }

    func testMalformedStepErrorIncludesStepNumber() throws {
        let yaml = try YAMLParser.parse("""
        name: Test
        scenarios:
          - name: S1
            steps:
              - fly: away
        """)
        XCTAssertThrowsError(try ScenarioParser.parse(yaml)) { error in
            XCTAssertTrue("\(error)".contains("step 1:"), "Expected 'step 1:' prefix, got: \(error)")
        }
    }

    // MARK: - CLI var parsing

    func testParseCLIVars() {
        let vars = ScenarioParser.parseCLIVars("app=com.example.App,timeout=10")
        XCTAssertEqual(vars["app"], "com.example.App")
        XCTAssertEqual(vars["timeout"], "10")
    }

    func testParseCLIVarsWithSpaces() {
        let vars = ScenarioParser.parseCLIVars("app = com.example.App , timeout = 10")
        XCTAssertEqual(vars["app"], "com.example.App")
        XCTAssertEqual(vars["timeout"], "10")
    }

    func testParseCLIVarsEmpty() {
        let vars = ScenarioParser.parseCLIVars("")
        XCTAssertTrue(vars.isEmpty)
    }
}
