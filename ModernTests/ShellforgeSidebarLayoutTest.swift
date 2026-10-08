//
//  ShellforgeSidebarLayoutTest.swift
//  Shellforge
//
//  The Shellforge sidebar takes a column at the window's left edge; everything iTerm2 lays out
//  (tab view, tab bar, status bar, toolbelt) shares what is left, exactly as it would in a window
//  that much narrower.
//

import XCTest
@testable import iTerm2SharedARC

final class ShellforgeSidebarLayoutTest: XCTestCase {
    private func inputs(sidebar: CGFloat, toolbelt: Bool = false) -> iTermLayoutInputs {
        var inputs = iTermLayoutInputs()
        inputs.contentViewWidth = 800
        inputs.contentViewHeight = 600
        inputs.tabBarHeight = 28
        inputs.toolbeltWidth = 200
        inputs.shouldShowToolbelt = toolbelt
        inputs.tabBarVisible = true
        inputs.tabPosition = kLayoutTabPositionTop
        inputs.divisionViewHeight = 1
        inputs.leftPanelWidth = sidebar
        return inputs
    }

    func testWithoutASidebarNothingMoves() {
        let outputs = iTermLayoutCalculator.calculateLayout(with: inputs(sidebar: 0))
        XCTAssertEqual(outputs.tabViewFrame.minX, 0)
        XCTAssertEqual(outputs.tabViewFrame.width, 800)
        XCTAssertEqual(outputs.leftPanelFrame, .zero)
    }

    func testTheSidebarTakesTheLeftColumnAtFullHeight() {
        let outputs = iTermLayoutCalculator.calculateLayout(with: inputs(sidebar: 240))
        XCTAssertEqual(outputs.leftPanelFrame, CGRect(x: 0, y: 0, width: 240, height: 600))
    }

    func testTheTabViewAndTabBarStartWhereTheSidebarEnds() {
        let outputs = iTermLayoutCalculator.calculateLayout(with: inputs(sidebar: 240))
        XCTAssertEqual(outputs.tabViewFrame.minX, 240)
        XCTAssertEqual(outputs.tabViewFrame.width, 560)
        XCTAssertEqual(outputs.tabBarFrame.minX, 240)
    }

    func testTheToolbeltStaysAtTheRightEdge() {
        let outputs = iTermLayoutCalculator.calculateLayout(with: inputs(sidebar: 240, toolbelt: true))
        XCTAssertEqual(outputs.toolbeltFrame.maxX, 800)
        XCTAssertEqual(outputs.tabViewFrame.width, 800 - 240 - 200)
    }
}
