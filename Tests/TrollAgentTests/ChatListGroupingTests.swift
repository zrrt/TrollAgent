import XCTest
@testable import TrollAgent

/// v7.2.3-fix20：连续工具折叠分组回归基线
final class ChatListGroupingTests: XCTestCase {

    private func toolMsg(_ id: String, running: Bool = false, duration: Double? = nil) -> ChatMessage {
        var m = ChatMessage(role: "tool", content: "", toolCallId: id, toolName: "shell.exec")
        m.id = UUID()
        m.isRunning = running
        m.toolDuration = duration
        return m
    }

    private func textMsg() -> ChatMessage {
        ChatMessage(role: "assistant", content: "解说")
    }

    func testSingleToolNotCollapsed() {
        let msgs = [textMsg(), toolMsg("t1"), textMsg()]
        let items = ChatListGrouping.group(msgs)
        XCTAssertEqual(items.count, 3)
        if case .msg = items[0] {} else { XCTFail("应为 msg") }
        if case .msg = items[1] {} else { XCTFail("单工具不折叠") }
        if case .msg = items[2] {} else { XCTFail("应为 msg") }
    }

    func testConsecutiveToolsCollapsed() {
        let msgs = [textMsg(), toolMsg("t1"), toolMsg("t2"), toolMsg("t3"), textMsg()]
        let items = ChatListGrouping.group(msgs)
        XCTAssertEqual(items.count, 3)
        if case .tools(let run) = items[1] {
            XCTAssertEqual(run.count, 3)
        } else {
            XCTFail("连续 3 工具应折叠成组")
        }
    }

    func testRunningToolNotCollapsed() {
        // 流式过程中 running 工具不折叠；完成后才折叠
        let msgs = [toolMsg("t1", running: true), toolMsg("t2"), textMsg()]
        let items = ChatListGrouping.group(msgs)
        XCTAssertEqual(items.count, 3)
        if case .tools = items[0] { XCTFail("running 不折叠") }
        if case .msg = items[0] {} else { XCTFail("应为 msg") }
    }

    func testTwoSeparatedRunsBothCollapsed() {
        let msgs = [toolMsg("a1"), toolMsg("a2"), textMsg(), toolMsg("b1"), toolMsg("b2"), toolMsg("b3")]
        let items = ChatListGrouping.group(msgs)
        XCTAssertEqual(items.count, 3)
        if case .tools(let r1) = items[0] { XCTAssertEqual(r1.count, 2) } else { XCTFail() }
        if case .msg = items[1] {} else { XCTFail() }
        if case .tools(let r2) = items[2] { XCTAssertEqual(r2.count, 3) } else { XCTFail() }
    }

    func testTotalDurationSum() {
        let msgs = [toolMsg("t1", duration: 1.2), toolMsg("t2", duration: 0.8), toolMsg("t3", duration: 2.0)]
        let item = ChatListGrouping.Item.tools(msgs)
        XCTAssertEqual(item.totalDuration ?? 0, 4.0, accuracy: 0.001)
    }

    func testGroupIDStable() {
        // 同一批消息实例多次分组 → 组 id 稳定（首条 UUID）
        let msgs = [toolMsg("t1"), toolMsg("t2")]
        let g1 = ChatListGrouping.group([textMsg()] + msgs)[1]
        let g2 = ChatListGrouping.group([textMsg()] + msgs)[1]
        XCTAssertEqual(g1.id, g2.id)
    }

    func testGroupIDStableAcrossWaveGrowth() {
        // 并发波增量完成：A → A+B → A+B+C，组 id 不应随条数变化（展开状态保持）
        let a = toolMsg("a1")
        let b = toolMsg("b2")
        let c = toolMsg("c3")
        let gAB = ChatListGrouping.group([textMsg()] + [a, b])[1]
        let gABC = ChatListGrouping.group([textMsg()] + [a, b, c])[1]
        XCTAssertEqual(gAB.id, gABC.id)
    }
}
