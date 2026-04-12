import XCTest
@testable import simpilot

final class YAMLParserTests: XCTestCase {

    // MARK: - Scalar

    func testPlainScalar() throws {
        let result = try YAMLParser.parse("hello")
        XCTAssertEqual(result, .scalar("hello"))
    }

    func testQuotedScalar() throws {
        let result = try YAMLParser.parse("\"hello world\"")
        XCTAssertEqual(result, .scalar("hello world"))
    }

    func testSingleQuotedScalar() throws {
        let result = try YAMLParser.parse("'hello world'")
        XCTAssertEqual(result, .scalar("hello world"))
    }

    // MARK: - Mapping

    func testSimpleMapping() throws {
        let yaml = """
        name: test
        value: 42
        """
        let result = try YAMLParser.parse(yaml)
        XCTAssertEqual(result, .mapping([
            ("name", .scalar("test")),
            ("value", .scalar("42")),
        ]))
    }

    func testNestedMapping() throws {
        let yaml = """
        config:
          timeout: 5
          retry: true
        """
        let result = try YAMLParser.parse(yaml)
        XCTAssertEqual(result, .mapping([
            ("config", .mapping([
                ("timeout", .scalar("5")),
                ("retry", .scalar("true")),
            ]))
        ]))
    }

    func testMappingWithQuotedValues() throws {
        let yaml = """
        name: "hello world"
        label: 'test value'
        """
        let result = try YAMLParser.parse(yaml)
        XCTAssertEqual(result, .mapping([
            ("name", .scalar("hello world")),
            ("label", .scalar("test value")),
        ]))
    }

    func testEmptyMappingValue() throws {
        let yaml = "key:"
        let result = try YAMLParser.parse(yaml)
        XCTAssertEqual(result, .mapping([("key", .scalar(""))]))
    }

    // MARK: - Sequence

    func testSimpleSequence() throws {
        let yaml = """
        - alpha
        - beta
        - gamma
        """
        let result = try YAMLParser.parse(yaml)
        XCTAssertEqual(result, .sequence([
            .scalar("alpha"),
            .scalar("beta"),
            .scalar("gamma"),
        ]))
    }

    func testSequenceOfMappings() throws {
        let yaml = """
        - name: Alice
          age: 30
        - name: Bob
          age: 25
        """
        let result = try YAMLParser.parse(yaml)
        XCTAssertEqual(result, .sequence([
            .mapping([("name", .scalar("Alice")), ("age", .scalar("30"))]),
            .mapping([("name", .scalar("Bob")), ("age", .scalar("25"))]),
        ]))
    }

    // MARK: - Mapping with sequence value

    func testMappingContainingSequence() throws {
        let yaml = """
        items:
          - one
          - two
          - three
        """
        let result = try YAMLParser.parse(yaml)
        XCTAssertEqual(result, .mapping([
            ("items", .sequence([
                .scalar("one"),
                .scalar("two"),
                .scalar("three"),
            ]))
        ]))
    }

    // MARK: - Comments

    func testCommentsAreStripped() throws {
        let yaml = """
        # top-level comment
        name: test  # inline comment
        value: 42
        """
        let result = try YAMLParser.parse(yaml)
        XCTAssertEqual(result, .mapping([
            ("name", .scalar("test")),
            ("value", .scalar("42")),
        ]))
    }

    func testHashInQuotesIsPreserved() throws {
        let yaml = """
        label: "hello # world"
        """
        let result = try YAMLParser.parse(yaml)
        XCTAssertEqual(result, .mapping([
            ("label", .scalar("hello # world")),
        ]))
    }

    // MARK: - Blank lines

    func testBlankLinesAreIgnored() throws {
        let yaml = """
        name: test

        value: 42

        """
        let result = try YAMLParser.parse(yaml)
        XCTAssertEqual(result, .mapping([
            ("name", .scalar("test")),
            ("value", .scalar("42")),
        ]))
    }

    // MARK: - Empty input

    func testEmptyInput() throws {
        let result = try YAMLParser.parse("")
        XCTAssertEqual(result, .mapping([]))
    }

    func testOnlyComments() throws {
        let result = try YAMLParser.parse("# just a comment\n# another")
        XCTAssertEqual(result, .mapping([]))
    }

    // MARK: - Convenience accessors

    func testSubscriptOnMapping() throws {
        let yaml = try YAMLParser.parse("name: test\nvalue: 42")
        XCTAssertEqual(yaml["name"]?.stringValue, "test")
        XCTAssertEqual(yaml["value"]?.stringValue, "42")
        XCTAssertNil(yaml["missing"])
    }

    func testSubscriptOnNonMapping() throws {
        let yaml = try YAMLParser.parse("hello")
        XCTAssertNil(yaml["anything"])
    }

    // MARK: - Scenario-like structure

    func testFullScenarioStructure() throws {
        let yaml = """
        name: Settings Test
        config:
          timeout: 5
          stop_on_failure: true
        variables:
          app: com.apple.Preferences
        scenarios:
          - name: Navigate
            steps:
              - launch: com.apple.Preferences
              - tap: General
              - assert:
                  predicate: exists
                  query: "text:About"
        """
        let result = try YAMLParser.parse(yaml)

        XCTAssertEqual(result["name"]?.stringValue, "Settings Test")
        XCTAssertEqual(result["config"]?["timeout"]?.stringValue, "5")
        XCTAssertEqual(result["config"]?["stop_on_failure"]?.stringValue, "true")
        XCTAssertEqual(result["variables"]?["app"]?.stringValue, "com.apple.Preferences")

        let scenarios = result["scenarios"]?.sequenceValue
        XCTAssertEqual(scenarios?.count, 1)

        let steps = scenarios?.first?["steps"]?.sequenceValue
        XCTAssertEqual(steps?.count, 3)

        // First step: launch
        let launchStep = steps?[0]
        XCTAssertEqual(launchStep?["launch"]?.stringValue, "com.apple.Preferences")

        // Second step: tap (scalar)
        let tapStep = steps?[1]
        XCTAssertEqual(tapStep?["tap"]?.stringValue, "General")

        // Third step: assert (mapping)
        let assertStep = steps?[2]
        XCTAssertEqual(assertStep?["assert"]?["predicate"]?.stringValue, "exists")
        XCTAssertEqual(assertStep?["assert"]?["query"]?.stringValue, "text:About")
    }

    // MARK: - Colon in values

    func testColonInQuotedKey() throws {
        let yaml = """
        query: "text:About"
        """
        let result = try YAMLParser.parse(yaml)
        XCTAssertEqual(result["query"]?.stringValue, "text:About")
    }
}
